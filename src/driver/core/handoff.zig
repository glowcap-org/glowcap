//! Third-party handoff for the byte-fed host core: the node-service
//! callbacks that project, capture, and release local gift targets, the
//! embedder's dial-ticket seam (`pendingDial` / `exporterDialed` /
//! `dialFailed` / `provideGiftId`), and the give verbs (`acceptGive` /
//! `setExporterLocation`).
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
const host_pump = @import("host_pump.zig");
const enliven_mod = @import("enliven.zig");
const capability = @import("capability.zig");
const sessions_mod = @import("sessions.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const resolvePublishedTarget = @import("publish.zig").resolvePublishedTarget;

fn captureGiftTarget(ctx: ?*anyopaque, scope: engine.PeerId, export_position: model.ExportPosition) ?u64 {
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

fn projectGiftTarget(ctx: ?*anyopaque, scope: engine.PeerId, target: u64) !engine.bootstrap.ProjectedLocalTarget {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return error.UnknownCapability;
    if (!session.host.vat.hasActor(target)) return actors.Error.NoSuchActor;
    const projection = try session.served.port.prepareProjection(&host.vat, .{ .local = target });
    return .{
        .export_position = projection.near.export_position,
        .created = projection.created,
    };
}

fn rollbackGiftTarget(ctx: ?*anyopaque, scope: engine.PeerId, target: u64, projected: engine.bootstrap.ProjectedLocalTarget) void {
    if (!projected.created) return;
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return;
    session.served.port.rollbackExport(&host.vat, .{ .local = target }, projected.export_position.int());
}

fn resolveGifterSession(ctx: ?*anyopaque, gifter_side: [32]u8, session_name: []const u8) ?engine.bootstrap.GifterSession {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const peer_id = host.partner_by_side.get(gifter_side) orelse return null;
    const session = sessions_mod.liveIndexedSession(host, peer_id) orelse return null;
    if (!session.sessionOpen()) return null;
    const peer = session.served.port.peer;
    if (!peer.verify_partner_handshake) return null;
    const key = engine.bootstrap.gifterKeyForSession(&peer.session_state, gifter_side, session_name) orelse return null;
    return .{ .peer_id = peer_id, .key = key, .gifts = peer.giftRegistry() };
}

/// Register the Host's publication and handoff callbacks on its node. The
/// callbacks are file-private on purpose — they are this seam's business —
/// and `sessions.zig` calls this at mint rather than reaching for them.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn wireNodeServices(self: *Host) void {
    self.node.setLocalObjectProjection(.{
        .ctx = self,
        .resolve_name = resolvePublishedTarget,
        .capture = captureGiftTarget,
        .project = projectGiftTarget,
        .rollback = rollbackGiftTarget,
        .release_target = releaseGiftTarget,
    });
    self.node.setGifterSessionResolver(.{ .ctx = self, .resolve = resolveGifterSession });
}

/// Borrow the in-flight pending dial for `ticket`, or null if settled.
/// Same contract as `Node.pendingDial`.
pub fn pendingDial(self: *const Host, ticket: engine.Node.PendingId) ?engine.Node.PendingDialView {
    switch (self.lifecyclePhase()) {
        .active, .finishing => {},
        .terminating, .closed => return null,
    }
    return self.node.pendingDial(ticket);
}

/// Finish a ticketed Node effect after its row was consumed. Outbound
/// backpressure is already represented by the dirty session's FLUSH action,
/// so surfacing WOULD_BLOCK here would invite an invalid retry of an effect
/// that committed. Allocation failure remains visible: the ticket verbs are
/// idempotent on a stale ticket, which lets the embedder retry only to resume
/// host cleanup once memory is available.
fn finishCommittedEffect(self: *Host) !void {
    host_pump.finishVerb(self) catch |err| switch (err) {
        error.OutboundBackpressure => return,
        else => return err,
    };
}

/// Report a `dial` action's success: `session` is an `openPendingDial`
/// against that ticket's pending locator, driven to an open session. The
/// node withdraws every give waiting on the ticket; the withdraws and
/// their flushes pump inside this call. A stale ticket is a no-op.
pub fn exporterDialed(self: *Host, ticket: engine.Node.PendingId, session: *HostSession) !void {
    try self.refuseReentry();
    try self.checkSession(session);
    try self.node.exporterDialed(ticket, session.peer_id);
    // Enlivens parked on this ticket continue over the opened session,
    // each settling its pre-minted vow; their fetch frames ride the same
    // finish pump the withdraws do.
    enliven_mod.settleParkedEnlivens(self, ticket, session, "");
    try finishCommittedEffect(self);
}

/// Report a `dial` action's failure. A failed path may leave the ticket live
/// and queue another dial; parked select-or-dial operations therefore settle
/// only when Node reports exhaustion. A stale ticket is a no-op.
pub fn dialFailed(self: *Host, ticket: engine.Node.PendingId, reason: []const u8) !void {
    try self.refuseReentry();
    const outcome = try self.node.dialFailed(ticket, reason);
    if (outcome == .exhausted)
        enliven_mod.settleParkedEnlivens(self, ticket, null, reason);
    try finishCommittedEffect(self);
}

/// A `cancel_dial` executor has interrupted and joined the physical dial it
/// owned. Terminal Host completion remains pending until this report arrives.
pub fn dialCancelled(self: *Host, ticket: engine.Node.PendingId) !void {
    try self.refuseReentry();
    self.node.dialCancelled(ticket);
    try finishCommittedEffect(self);
}

/// Answer a `need_gift_id` action with 32 host-drawn bytes: the node
/// originates the claimed handoff and this call flushes its legs,
/// exporter first. A stale ticket is a no-op.
pub fn provideGiftId(self: *Host, ticket: u64, gift_id: []const u8) !void {
    try self.refuseReentry();
    try self.node.provideGiftId(ticket, gift_id);
    try finishCommittedEffect(self);
}

/// Report that the embedder could not answer a `need_gift_id` action. The
/// pending handoff settles broken rather than retaining an action ticket no
/// runtime can complete. A stale ticket is a no-op.
pub fn giftIdFailed(self: *Host, ticket: u64) !void {
    try self.refuseReentry();
    try self.node.giftIdFailed(ticket);
    try finishCommittedEffect(self);
}

/// Redeem a `desc:handoff-give` this recipient `session` received outside
/// the auto-redeem path — a give delivered to an application object rather
/// than surfaced as the `op:resolve` `hostBeforeServe` claims — by dialing
/// the exporter `exporter_locator` names and withdrawing the gift under the
/// host identity, settling `answer` with the redeemed capability. This is
/// the same node redeem the before-serve hook runs for an inbound
/// give-as-resolve (ADR-0009), exposed for an embedder whose protocol
/// carries gives another way — the OCapN conformance greeter delivers the
/// give as a plain argument. Running it as a host verb (not a raw
/// `node.acceptGive`) is what moves the queued dial onto the embedder's
/// action queue; a bare node call strands it. Top-level: refused from
/// inside a callback.
pub fn acceptGive(self: *Host, session: *HostSession, answer: u64, give: []const u8, exporter_locator: []const u8) !void {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    try self.node.acceptGive(session.peer_id, answer, give, exporter_locator);
    try finishCommittedEffect(self);
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
    try self.node.setExporterLocation(session.peer_id, location);
}
