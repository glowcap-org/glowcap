//! Third-party handoff for the byte-fed host core: the node-service
//! callbacks that project, capture, and release local gift targets, the
//! embedder's dial-ticket seam (`pendingDial` / `exporterDialed` /
//! `dialFailed` / `provideGiftId`), and the give verbs (`acceptGive`,
//! `acceptInlineGive`, and `setExporterLocation`).
//!
//! One of `host.zig`'s responsibilities, kept beside it rather than in it.
//! The `Host` still owns the state and presents each verb as its own through
//! decl aliases. The serve hooks that *claim* an inbound withdraw resolve and
//! auto-redeem an arriving give stay in `host.zig`: they compose several
//! concerns per event, and this file owns only the handoff half they call.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_pump = @import("host/pump.zig");
const capability_promise = @import("capability_promise.zig");
const enliven_mod = @import("enliven.zig");
const capability = @import("capability.zig");
const pending_dial_identity = @import("pending_dial_identity.zig");
const sessions_mod = @import("sessions.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

fn captureGiftTarget(ctx: ?*anyopaque, scope: engine.PeerHandle, export_position: model.ExportPosition) ?u64 {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return null;
    const ref = session.served.port.refForExport(export_position.int()) orelse return null;
    const actor_id = switch (ref) {
        .local => |id| id,
        .far => return null,
    };
    if (!session.host.vat.hasActor(actor_id)) return null;
    // The exact gift row roots its actor (ADR-0101); `release_target` hands
    // the root back when the row dies, and the deposit path hands it back
    // itself if the row is never admitted.
    host.vat.retainActor(actor_id);
    return actor_id;
}

fn releaseGiftTarget(ctx: ?*anyopaque, target: u64) void {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    host.vat.releaseActor(target);
}

fn projectGiftTarget(ctx: ?*anyopaque, scope: engine.PeerHandle, target: u64) !engine.bootstrap.gifts.ProjectedLocalTarget {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return error.UnknownCapability;
    if (!session.host.vat.hasActor(target)) return actors.Error.NoSuchActor;
    const projection = try session.served.port.prepareProjection(&host.vat, .{ .local = target });
    return .{
        .export_position = projection.near.export_position,
        .created = projection.created,
    };
}

fn rollbackGiftTarget(ctx: ?*anyopaque, scope: engine.PeerHandle, target: u64, projected: engine.bootstrap.gifts.ProjectedLocalTarget) void {
    if (!projected.created) return;
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return;
    session.served.port.rollbackExport(&host.vat, .{ .local = target }, projected.export_position.int());
}

fn resolveGifterSession(ctx: ?*anyopaque, gifter_side: [32]u8, session_name: []const u8) ?engine.bootstrap.gifts.GifterSession {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const peer_handle = host.partner_by_side.get(gifter_side) orelse return null;
    const session = sessions_mod.liveIndexedSession(host, peer_handle) orelse return null;
    if (!session.sessionOpen()) return null;
    const peer = session.served.port.peer;
    if (!peer.verify_partner_handshake) return null;
    const key = engine.bootstrap.gifterKeyForSession(&peer.session_state, gifter_side, session_name) orelse return null;
    return .{ .peer_handle = peer_handle, .key = key, .gifts = peer.giftRegistry() };
}

/// Register the Host's publication and handoff callbacks on its node. The
/// callbacks are file-private on purpose — they are this seam's business —
/// and `sessions.zig` calls this at mint rather than reaching for them.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn wireNodeServices(self: *Host) void {
    self.node.setLocalObjectProjection(.{
        .ctx = self,
        .resolve_fetch = @import("publication_lookup.zig").resolveFetch,
        .capture = captureGiftTarget,
        .project = projectGiftTarget,
        .rollback = rollbackGiftTarget,
        .release_target = releaseGiftTarget,
    });
    self.node.setGifterSessionResolver(.{ .ctx = self, .resolve = resolveGifterSession });
}

/// Borrow the in-flight pending dial for `ticket`, or null if settled.
/// Same contract as `Node.pendingDial`.
pub fn pendingDial(self: *const Host, ticket: engine.Node.PendingId, route_index: usize) ?engine.Node.PendingDialView {
    switch (self.lifecyclePhase()) {
        .active, .finishing => {},
        .terminating, .closed => return null,
    }
    return self.node.pendingDial(ticket, route_index);
}

/// Complete work after a Host verb commits its Node transition. Pressure
/// leaves the dirty/action queues as continuation state; it must not make the
/// caller retry an operation whose authority already moved.
fn finishCommittedEffect(self: *Host) void {
    host_pump.finishVerb(self) catch |err| switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => {},
        else => sessions_mod.condemnRemainingSessions(self, "committed host effect failed"),
    };
}

/// Report a `dial` action's success: `session` is an `openPendingDial`
/// against that ticket and route's pending locator, driven to an open session.
/// The node adopts it for every give waiting on the logical ticket. The bounded Host pump
/// advances resulting work before return; pressure stays queued for the next
/// action drain. A stale or non-running attempt is a no-op.
pub fn exporterDialed(self: *Host, ticket: engine.Node.PendingId, route_index: usize, session: *HostSession) !bool {
    try self.refuseReentry();
    try self.checkSession(session);
    const adopted = try completeExporter(self, ticket, route_index, session, .dialed);
    finishCommittedEffect(self);
    return adopted;
}

fn completeExporter(
    self: *Host,
    ticket: engine.Node.PendingId,
    route_index: usize,
    session: *HostSession,
    mode: engine.Node.ExporterCompletion,
) !bool {
    const completion = (try switch (mode) {
        .dialed => pending_dial_identity.requireDialed(self, ticket, route_index, session),
        .selected => pending_dial_identity.requireSelected(self, ticket, route_index, session),
    }) orelse return false;
    const adopted = try self.node.exporterCompleted(
        ticket,
        route_index,
        session.peer_handle,
        mode,
    );
    if (!adopted) return false;
    // Enlivens parked on this ticket continue over the opened session, each
    // settling its pre-minted vow; their fetch frames ride the same action
    // drain as the withdraws.
    enliven_mod.settleParkedEnlivens(self, ticket, .{ .opened = .{
        .session = session,
        .provenance = completion.provenance,
    } });
    return true;
}

/// Internal action-pump completion when a pending route already has a live
/// session. The enclosing pump owns the finish tail.
pub fn completeSelectedExporter(
    self: *Host,
    ticket: engine.Node.PendingId,
    route_index: usize,
    session: *HostSession,
) !bool {
    return completeExporter(self, ticket, route_index, session, .selected);
}

/// Report a `dial` action's failure. A failed path may leave the ticket live
/// and queue another dial; parked select-or-dial operations therefore settle
/// only when Node reports exhaustion. A stale or non-running attempt is a no-op.
pub fn dialFailed(self: *Host, ticket: engine.Node.PendingId, route_index: usize, reason: []const u8) !void {
    try self.refuseReentry();
    const outcome = try self.node.dialFailed(ticket, route_index, reason);
    if (outcome == .exhausted)
        enliven_mod.settleParkedEnlivens(self, ticket, .{ .failed = reason });
    finishCommittedEffect(self);
}

/// A `cancel_dial` executor has interrupted and joined the physical dial it
/// owned. Terminal Host completion remains pending until this report arrives.
pub fn dialCancelled(self: *Host, ticket: engine.Node.PendingId, route_index: usize) !void {
    try self.refuseReentry();
    self.node.dialCancelled(ticket, route_index);
    finishCommittedEffect(self);
}

/// Answer a `need_gift_id` action with 32 host-drawn bytes: the node
/// originates the claimed handoff and this call flushes its legs,
/// exporter first. A stale ticket is a no-op.
pub fn provideGiftId(self: *Host, ticket: u64, gift_id: []const u8) !void {
    try self.refuseReentry();
    try self.node.provideGiftId(ticket, gift_id);
    finishCommittedEffect(self);
}

/// Report that the embedder could not answer a `need_gift_id` action. The
/// pending handoff settles broken rather than retaining an action ticket no
/// runtime can complete. A stale ticket is a no-op.
pub fn giftIdFailed(self: *Host, ticket: u64) !void {
    try self.refuseReentry();
    try self.node.giftIdFailed(ticket);
    finishCommittedEffect(self);
}

/// Redeem a signed give that must settle the partner-owned wire `answer`.
/// Embedders use this when their protocol has already installed that answer;
/// an application-delivered inline give uses `acceptInlineGive` instead.
/// Running this as a Host verb moves a queued exporter dial onto the action
/// queue. Top-level: refused from inside a callback.
pub fn acceptGive(self: *Host, session: *HostSession, answer: u64, give: []const u8, exporter_locator: []const u8) !void {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    try self.node.acceptGive(session.peer_handle, answer, give, exporter_locator);
    finishCommittedEffect(self);
}

/// Redeem a typed `desc:handoff-give` this recipient `session` received as an
/// application value. The returned Host capability is an eventual identity:
/// it can be used immediately or released immediately when the application
/// only needed the withdrawal side effect. Its Host-owned deferred id is not a
/// wire answer position, so a plain delivered give never invents authority in
/// the partner-owned answer namespace.
///
/// This is the top-level twin of the automatic inline-Passable lift. Running
/// it as a Host verb moves a queued exporter dial onto the embedder's action
/// queue; a bare `Node.acceptInlineGive` would strand that effect. `give` is
/// borrowed for the call. Top-level: refused from inside a callback.
pub fn acceptInlineGive(self: *Host, session: *HostSession, give: model.HandoffGive) !capability.Ref {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    const lifted = try capability_promise.liftInlineGive(self, session, give);
    self.commitCapabilityLift(lifted);
    finishCommittedEffect(self);
    return lifted.ref;
}

/// Record the exporter locator to embed in gives whose exporter is `session`
/// (see `engine.Node.setExporterLocation`); `null` clears the override back
/// to the session record. The node encodes the locator to canonical Syrup
/// record bytes — a URI string is unrepresentable here.
pub fn setExporterLocation(self: *Host, session: *HostSession, location: ?model.PeerLocator) !void {
    self.assertOwner();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    try self.node.setExporterLocation(session.peer_handle, location);
}
