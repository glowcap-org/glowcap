//! Host vows and resolver pairs: the read side every asynchronous host verb
//! returns, and the settle machinery behind it.
//!
//! One of `host.zig`'s responsibilities, kept beside it rather than in it. The
//! `Host` still owns the state — the vow map, the resolver index, the id
//! sources — and still presents the `vow*`, `deferTurn`, and `resolver*`
//! verbs as its own through decl aliases, so a caller reads one `Host`
//! surface. What lives here is the row lifecycle those verbs share: mint,
//! listener chaining, retire-on-settle, and the queued completion for an
//! embedder that only drains the action queue.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const value_mod = @import("value.zig");

const host_mod = @import("host.zig");
const host_pump = @import("host/pump.zig");
const vocab = @import("vocab.zig");
const completion = @import("vows/completion.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;

pub fn ensureFreshVowId(self: *Host) !void {
    if (self.next_vow == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
}

fn ensureFreshResolverId(self: *Host) !void {
    if (self.next_resolver == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
}
const asFarRef = host_mod.asFarRef;

/// One live host vow. The row holds the vow's single vat listener slot
/// from mint (`fire`), so settlement always retires the row. An
/// in-process listener chains through `inner`, set once by `vowOn`, and
/// hears the resolution borrowed (zero-copy); a vow with no listener
/// settles as a queued `settled`/`failed` completion instead, so an
/// embedder that only drains the action queue still hears every outcome.
pub const VowRow = struct {
    host: *Host,
    /// The session the vow rides, or null for a resolver row (ADR-0102).
    /// Session-scoped vow verbs refuse a resolver row (`SessionlessVow`). Its
    /// resolver settle normally retires it; teardown of the session whose
    /// answer it carries breaks and retires it before freeing that Port.
    peer_handle: ?engine.PeerHandle,
    id: u64,
    vow: actors.Vow,
    kind: Kind = .plain,
    inner: ?actors.Listener = null,
    /// The session whose turn deferred its answer onto this resolver vow
    /// (ADR-0102), recorded by `deferTurn` so the settle can mark it
    /// dirty — a resolver settle is the one vat settle that runs outside
    /// any `feed`, so nothing else would encode the resolved answer.
    /// Distinct from `peer_handle` on purpose: the row itself is sessionless, but
    /// this owner makes teardown cancel the deferred answer and its pending
    /// operation before the Port it would resolve through is freed.
    forwarded_peer: ?engine.PeerHandle = null,

    /// What settlement does to the resolution before it is dispatched: a
    /// `fetch` vow's fulfilled far capability is enrolled under a
    /// node-unique route first (ADR-0069).
    const Kind = enum { plain, fetch };

    /// The retire listener installed at mint.
    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const row: *VowRow = @ptrCast(@alignCast(ctx.?));
        settleRow(row.host, row, resolution);
    }
};

pub const ResolverIndexEntry = struct { vow_id: u64, vat_resolver: u64 };
const ResolvedVow = struct { row: *VowRow, session: *HostSession };

const Projection = union(enum) { index: i64, untag: []const u8, get: []const u8 };

/// Every fallible resource needed to publish one Host vow after its semantic
/// operation commits. The row and both queue capacities are Host-owned; the
/// typed listener reservation belongs to the Vat/Port settlement namespace.
pub const VowReservation = struct {
    row: *VowRow,
    listener: actors.ListenerReservation,
};

/// Register a one-shot in-process listener on a host vow, which hears
/// the resolution borrowed (zero-copy) and keeps that vow's settlement
/// off the action queue. A settled vow's row is already retired, so a
/// settled id and an unknown id refuse alike with `NoSuchVow` — register
/// before the feed that can settle it (an embedder that drains the
/// action queue instead has no such window: the completion waits on the
/// queue). A second listener on a live row is refused `AlreadyListening`.
pub fn vowOn(self: *Host, vow_id: u64, listener: actors.Listener) !void {
    const resolved = try resolveVowSession(self, vow_id);
    if (resolved.row.inner != null) return actors.Error.AlreadyListening;
    resolved.row.inner = listener;
}

/// Owning session for a still-live vow, used by adapters to lower opaque
/// Host references in a pipelined send before entering the wire surface.
pub fn vowSession(self: *Host, vow_id: u64) !*HostSession {
    return (try resolveVowSession(self, vow_id)).session;
}

/// Atomically mint the resolver authority and defer `turn` onto its vow. Every
/// Host/Vat row and the forward listener are reserved before either side is
/// published, so refusal leaves no resolver and no forwarded effect behind.
pub fn deferTurn(self: *Host, session: *HostSession, turn: *actors.Turn) !u64 {
    self.assertOwner();
    try self.admitApplicationOperation();
    if (session.host != self or self.sessions.get(session.peer_handle) != session)
        return HostError.ForeignTurn;
    if (turn.vat != &self.vat) return HostError.ForeignTurn;
    switch (turn.origin) {
        .local => return actors.Error.NotLocal,
        .served => |answer| if (answer == null) return HostError.NoAnswer,
    }
    if (turn.port != &session.served.port or
        turn.ingress != session.served.port.ingress)
        return HostError.ForeignTurn;
    try self.admitSessionOperation(session);
    try ensureFreshVowId(self);
    try ensureFreshResolverId(self);
    const row = try reserveVowRow(self, null, .plain, self.next_vow);
    errdefer self.allocator.destroy(row);
    try self.resolver_index.ensureUnusedCapacity(self.allocator, 1);
    const vat_reservation = try self.vat.reserveResolverPair();
    const forward_reservation = try turn.reserveForwardVow(.local);

    const pair = self.vat.spawnReservedVow(vat_reservation);
    row.vow = pair.vow;
    self.vows.putAssumeCapacity(row.id, row);
    self.next_vow += 1;
    const resolver_id = self.next_resolver;
    self.next_resolver += 1;
    self.resolver_index.putAssumeCapacity(resolver_id, .{
        .vow_id = row.id,
        .vat_resolver = pair.resolver,
    });
    turn.forwardReservedVow(forward_reservation, pair.vow);
    row.forwarded_peer = session.peer_handle;
    self.beginSessionOperation(session);
    return resolver_id;
}

/// Settle a resolver vow fulfilled (ADR-0102). Top-level: the settle
/// runs the deferred answers' listeners and pumps every session they
/// dirtied, so it refuses from inside a callback (`ReenteredHost`) — the
/// worker's completion re-enters between events, on the owning thread.
/// A successful settle consumes the resolver, so a second settle and an
/// unknown id refuse alike (`AlreadySettled`). Preparation failure leaves the
/// same resolver authority live for retry. `value` must be capability-free —
/// plain data is the off-turn contract; an answer that carries authority takes
/// the existing forward-to-send path instead.
pub fn resolverFulfill(self: *Host, resolver_id: u64, value: model.Argument) !void {
    try self.refuseReentry();
    if (!model.argumentIsPlainData(&value)) return HostError.ForeignArgument;
    try settleResolverRow(self, resolver_id, .{ .fulfilled = value });
}

/// Settle a resolver vow broken (ADR-0102); `reason` is borrowed for the
/// call. The same contract as `resolverFulfill`.
pub fn resolverBreak(self: *Host, resolver_id: u64, reason: []const u8) !void {
    try self.refuseReentry();
    try settleResolverRow(self, resolver_id, .{ .broken = reason });
}

/// Promise pipelining: eventual-send `msg` to a host vow before it
/// resolves, minting a new vow for this call's own answer. A local vow has
/// no wire answer to pipeline against (`NotPipelineable`).
pub fn vowSend(self: *Host, vow_id: u64, msg: actors.Message) !u64 {
    return vowSendWithProgress(self, vow_id, msg, true);
}

/// `vowSend` with progress deferred until the caller has installed `vowOn`
/// for the newly committed result.
pub fn queueVowSend(self: *Host, vow_id: u64, msg: actors.Message) !u64 {
    return vowSendWithProgress(self, vow_id, msg, false);
}

/// Owning-tier pipelined send. Resolve the vow's home before lowering opaque
/// values, so every capability argument is projected on the session that will
/// carry the deliver.
pub fn vowSendValues(
    self: *Host,
    vow_id: u64,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !u64 {
    return vowSendValuesWithProgress(self, vow_id, verb, values, arena, true);
}

/// `vowSendValues` with progress deferred until its caller installs a waiter.
pub fn queueVowSendValues(
    self: *Host,
    vow_id: u64,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !u64 {
    return vowSendValuesWithProgress(self, vow_id, verb, values, arena, false);
}

fn vowSendValuesWithProgress(
    self: *Host,
    vow_id: u64,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    drive_now: bool,
) !u64 {
    try self.admitApplicationOperation();
    const resolved = try resolveVowSession(self, vow_id);
    try self.admitSessionOperation(resolved.session);
    try self.checkOutboundAdmission(resolved.session);
    var prepared = try self.prepareValues(resolved.session, arena, values);
    defer prepared.deinit();
    const id = try commitVowSend(self, resolved, .{ .verb = verb, .args = prepared.values }, drive_now);
    _ = prepared.commit();
    return id;
}

fn vowSendWithProgress(self: *Host, vow_id: u64, msg: actors.Message, drive_now: bool) !u64 {
    try self.admitApplicationOperation();
    const resolved = try resolveVowSession(self, vow_id);
    try self.admitSessionOperation(resolved.session);
    try self.checkOutboundAdmission(resolved.session);
    return commitVowSend(self, resolved, msg, drive_now);
}

fn commitVowSend(
    self: *Host,
    resolved: ResolvedVow,
    msg: actors.Message,
    drive_now: bool,
) !u64 {
    const reservation = try reserveVow(self, resolved.session, .far, .plain);
    var reservation_live = true;
    errdefer if (reservation_live) cancelVowReservation(self, reservation);
    const vow = try resolved.session.served.sendToAnswer(&self.vat, resolved.row.vow, msg);
    const id = commitVow(self, resolved.session, reservation, vow);
    reservation_live = false;
    if (drive_now)
        host_pump.finishCommittedVow(self, resolved.session)
    else
        host_pump.markDirty(self, resolved.session.peer_handle);
    return id;
}

/// Pipeline an `op:index` projection against a far host vow, minting a new
/// vow for the projected element.
pub fn vowIndex(self: *Host, vow_id: u64, index: i64) !u64 {
    return vowProjection(self, vow_id, .{ .index = index });
}

/// Pipeline an `op:untag` projection against a far host vow, minting a new
/// vow for the unwrapped payload.
pub fn vowUntag(self: *Host, vow_id: u64, tag: []const u8) !u64 {
    return vowProjection(self, vow_id, .{ .untag = tag });
}

/// Pipeline an `op:get` projection against a far host vow, minting a new
/// vow for the named Struct field (ADR-0050).
pub fn vowGet(self: *Host, vow_id: u64, field: []const u8) !u64 {
    return vowProjection(self, vow_id, .{ .get = field });
}

/// Reserve a Host row and the exact Vat/Port listener slot before an operation
/// that creates a vow becomes visible. Once this succeeds, `commitVow` is
/// allocation-free and cannot turn a committed send into a retryable OOM.
pub fn reserveVow(
    self: *Host,
    session: *HostSession,
    location: actors.VowLocation,
    kind: VowRow.Kind,
) !VowReservation {
    try ensureFreshVowId(self);
    return reserveVowAt(self, session, location, kind, self.next_vow);
}

/// Explicit-id reservation for a continuation whose public vow id was minted
/// before its eventual session existed (sturdyref select-or-dial).
pub fn reserveVowAt(
    self: *Host,
    session: *HostSession,
    location: actors.VowLocation,
    kind: VowRow.Kind,
    id: u64,
) !VowReservation {
    const row = try reserveVowRow(self, session, kind, id);
    errdefer self.allocator.destroy(row);
    const listener = try session.served.port.reserveListener(&self.vat, location);
    return .{ .row = row, .listener = listener };
}

/// Release the only owned resource in an uncommitted reservation. Reserved
/// map/FIFO capacity is intentionally retained for the next operation.
pub fn cancelVowReservation(self: *Host, reservation: VowReservation) void {
    self.allocator.destroy(reservation.row);
}

/// Mint a Host vow whose producing operation is admitted now but cannot be
/// attached to its eventual session yet. Inline handoff sends use this while
/// redemption is pending. The row is fully observable to `vowOn` immediately;
/// its producer later settles it through `fireVow` and may transfer its
/// session ownership with `moveDeferredVow` before that settlement.
pub fn mintDeferredVow(self: *Host, session: *HostSession) !u64 {
    try ensureFreshVowId(self);
    const id = self.next_vow;
    const row = try reserveVowRow(self, session, .plain, id);
    row.vow = .{ .local = id };
    self.vows.putAssumeCapacity(id, row);
    self.next_vow += 1;
    self.beginSessionOperation(session);
    return id;
}

/// Transfer one admitted deferred producer from the session on which the
/// caller learned the promise to the session that now owns its real send.
pub fn moveDeferredVow(self: *Host, vow_id: u64, target: *HostSession) void {
    const row = self.vows.get(vow_id) orelse return;
    const source_peer = row.peer_handle orelse unreachable;
    if (source_peer == target.peer_handle) return;
    if (self.sessions.get(source_peer)) |source| self.finishSessionOperation(source);
    self.beginSessionOperation(target);
    row.peer_handle = target.peer_handle;
}

/// Attach a pre-minted deferred Host vow directly to the real Vat/Port vow.
/// The existing `VowRow` is both public identity and listener context, so a
/// separate forwarding allocation would duplicate the same ownership.
pub fn attachDeferredVow(
    self: *Host,
    vow_id: u64,
    target: *HostSession,
    listener: actors.ListenerReservation,
    vow: actors.Vow,
) void {
    moveDeferredVow(self, vow_id, target);
    const row = self.vows.get(vow_id) orelse unreachable;
    row.vow = vow;
    target.served.port.onReserved(&self.vat, listener, vow, .{ .ctx = row, .func = VowRow.fire });
}

/// Publish a vow using only resources reserved before its semantic operation.
pub fn commitVow(
    self: *Host,
    session: *HostSession,
    reservation: VowReservation,
    vow: actors.Vow,
) u64 {
    const id = commitVowWithListener(
        self,
        session,
        reservation,
        vow,
        .{ .ctx = reservation.row, .func = VowRow.fire },
    );
    std.debug.assert(id == self.next_vow);
    self.next_vow += 1;
    return id;
}

/// Explicit-listener commit for Host-core bridges whose terminal callback does
/// more than retire and queue the raw resolution. The id counter is deliberately
/// unchanged; the continuation decides whether its id is fresh or pre-minted.
pub fn commitVowWithListener(
    self: *Host,
    session: *HostSession,
    reservation: VowReservation,
    vow: actors.Vow,
    listener: actors.Listener,
) u64 {
    const row = reservation.row;
    row.vow = vow;
    session.served.port.onReserved(&self.vat, reservation.listener, vow, listener);
    self.vows.putAssumeCapacity(row.id, row);
    self.beginSessionOperation(session);
    return row.id;
}

/// Resolver-pair row construction. Resolver vows already exist before the
/// Host publishes them, but no operation can settle them until their resolver
/// is returned, so this local helper may install after row reservation.
fn createVowRow(self: *Host, session: ?*HostSession, vow: actors.Vow, kind: VowRow.Kind, id: u64) !*VowRow {
    const row = try reserveVowRow(self, session, kind, id);
    row.vow = vow;
    return row;
}

fn reserveVowRow(self: *Host, session: ?*HostSession, kind: VowRow.Kind, id: u64) !*VowRow {
    const row = try self.allocator.create(VowRow);
    errdefer self.allocator.destroy(row);
    row.* = .{
        .host = self,
        .peer_handle = if (session) |s| s.peer_handle else null,
        .id = id,
        .vow = undefined,
        .kind = kind,
    };
    try self.vows.ensureUnusedCapacity(self.allocator, 1);
    // A session vow can settle onto the embedder action queue. Resolver rows
    // settle through their holder and reserve no queue slot they cannot use.
    if (session != null) try self.reserveActions(1);
    return row;
}

/// Retire a vow row with its resolution: remove and free the row first —
/// every later verb on the id refuses `NoSuchVow` — then route the
/// outcome. An `inner` listener hears the resolution borrowed, exactly
/// the `actors.Listener` contract; with no listener the outcome is
/// queued as an owned `settled`/`failed` completion.
fn settleRow(self: *Host, row: *VowRow, resolution: actors.Resolution) void {
    const inner = row.inner;
    const kind = row.kind;
    const maybe_peer = row.peer_handle;
    const id = row.id;
    std.debug.assert(self.vows.remove(id));
    if (maybe_peer) |peer_handle| {
        if (self.sessions.get(peer_handle)) |session| self.finishSessionOperation(session);
    }
    self.allocator.destroy(row);
    // A resolver row (ADR-0102) has no session and never queues a
    // completion: the settle is the resolver holder's own act, so it
    // already knows the outcome. Defensive — the resolver verbs retire
    // their row before the vat settles, so no fire reaches here.
    const peer_handle = maybe_peer orelse {
        if (inner) |listener| listener.func(listener.ctx, resolution);
        return;
    };
    const routed = if (kind == .fetch) enrollFetched(self, peer_handle, resolution) else resolution;
    if (inner) |listener| {
        listener.func(listener.ctx, routed);
        return;
    }
    completion.queueVowCompletion(self, peer_handle, id, routed);
}

/// Settle a vow by id — the enliven bridge's path to the shared retire
/// logic. A row already gone (the session was released and dropped
/// its rows) has no one to tell.
/// `pub` for the Host-core siblings, not for embedders: splitting a Zig
/// struct across files needs the callee visible. Host-core internal.
pub fn fireVow(self: *Host, vow_id: u64, resolution: actors.Resolution) void {
    const row = self.vows.get(vow_id) orelse return;
    settleRow(self, row, resolution);
}

fn vowProjection(self: *Host, vow_id: u64, projection: Projection) !u64 {
    try self.admitApplicationOperation();
    const resolved = try resolveVowSession(self, vow_id);
    try self.admitSessionOperation(resolved.session);
    const source = switch (resolved.row.vow) {
        .far => |answer| answer,
        // A local vow has no wire answer to project against.
        .local => return vocab.Error.NotPipelineable,
    };
    try self.checkOutboundAdmission(resolved.session);
    const reservation = try reserveVow(self, resolved.session, .far, .plain);
    var reservation_live = true;
    errdefer if (reservation_live) cancelVowReservation(self, reservation);
    const peer = resolved.session.served.port.peer;
    const answer = model.AnswerPosition.from(try peer.allocateAnswer());
    const receiver: model.Reference = .{ .promise = .{ .answer_position = source } };
    switch (projection) {
        .index => |index| try peer.sendCopying(.{ .index = .{
            .receiver = receiver,
            .index = .{ .integer = index },
            .answer = answer,
        } }),
        .untag => |tag| try peer.sendCopying(.{ .untag = .{ .receiver = receiver, .tag = tag, .answer = answer } }),
        .get => |field| try peer.sendCopying(.{ .get = .{ .receiver = receiver, .field = field, .answer = answer } }),
    }
    const id = commitVow(self, resolved.session, reservation, .{ .far = answer });
    reservation_live = false;
    host_pump.finishCommittedVow(self, resolved.session);
    return id;
}

/// The live session and row a latch-legal vow verb operates on: assert the
/// owner, resolve the vow's row and its session, and refuse a settled or
/// unknown vow (its row already retired) or a dead session alike with
/// `NoSuchVow`. `vowOn`, `vowSend`, and `vowProjection` share this prelude
/// and differ only in the body that follows.
fn resolveVowSession(self: *Host, vow_id: u64) HostError!ResolvedVow {
    self.assertOwner();
    const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
    const peer_handle = row.peer_handle orelse return HostError.SessionlessVow;
    const session = self.sessions.get(peer_handle) orelse return HostError.NoSuchVow;
    try self.checkSession(session);
    return .{ .row = row, .session = session };
}

fn settleResolverRow(self: *Host, resolver_id: u64, resolution: actors.Resolution) !void {
    const entry = self.resolver_index.get(resolver_id) orelse return actors.Error.AlreadySettled;
    const row = self.vows.get(entry.vow_id) orelse unreachable; // index row implies vow row
    const forwarded_peer = row.forwarded_peer;
    switch (resolution) {
        .fulfilled => |value| try self.vat.fulfillVow(entry.vat_resolver, value),
        .broken => |reason| try self.vat.breakVow(entry.vat_resolver, reason),
        .give => unreachable, // no resolver verb spells a give
    }
    // The Vat settle is committed and allocation-free from this point. Retire
    // both Host indexes only after it succeeds, so preparation OOM leaves the
    // same public resolver retryable.
    std.debug.assert(self.resolver_index.remove(resolver_id));
    std.debug.assert(self.vows.remove(entry.vow_id));
    self.allocator.destroy(row);
    // This settle runs outside any feed, so the deferred answer's session
    // is encoded here or not at all.
    if (forwarded_peer) |peer_handle| {
        const session = self.sessions.get(peer_handle) orelse return;
        self.finishSessionOperation(session);
        host_pump.markDirty(self, peer_handle);
        host_pump.finishCommittedWork(self, session);
    }
}

/// The fetch settlement mapping: enroll a fulfilled far capability under
/// a node-unique route *before* the outcome is dispatched, so a reply
/// that immediately re-gifts it routes to the right exporter. A
/// reference already carrying the explicit routed arm (an auto-redeemed give)
/// passes through unwrapped — enrolling a route
/// would double-wrap it into a reference no session can lower. An
/// unenrollable capability would mis-route a later re-gift, so it fails
/// loud as a break rather than surfacing half-usable.
fn enrollFetched(self: *Host, peer_handle: engine.PeerHandle, resolution: actors.Resolution) actors.Resolution {
    if (resolution == .fulfilled and resolution.fulfilled == .reference and
        resolution.fulfilled.reference == .routed) return resolution;
    if (resolution == .fulfilled) if (asFarRef(resolution.fulfilled)) |far| {
        const route = self.node.enrollForeign(peer_handle, .{ .far = far }) catch |err| {
            return .{ .broken = @errorName(err) };
        };
        return .{ .fulfilled = .{ .reference = route } };
    };
    return resolution;
}

/// Retire every pending-work edge owned by a session before its Port is freed.
/// Resolver rows are sessionless storage but carry one deferred answer for
/// `forwarded_peer`; break their Vat vow while the Port is alive, then consume
/// both Host indexes and the session operation. Ordinary session vows have
/// already fired through `breakFarVows` when possible; any remaining rows are
/// removed here. Removal invalidates each iterator, so both scans collect a
/// bounded stack batch and remove between scans.
pub fn dropVowRows(self: *Host, session: *HostSession, reason: []const u8) void {
    const peer_handle = session.peer_handle;
    var doomed: [64]u64 = undefined;

    while (true) {
        var n: usize = 0;
        var resolvers = self.resolver_index.iterator();
        while (resolvers.next()) |entry| {
            const row = self.vows.get(entry.value_ptr.vow_id) orelse unreachable;
            if (row.forwarded_peer != peer_handle) continue;
            doomed[n] = entry.key_ptr.*;
            n += 1;
            if (n == doomed.len) break;
        }
        if (n == 0) break;
        for (doomed[0..n]) |resolver_id| {
            const entry = self.resolver_index.get(resolver_id) orelse unreachable;
            const row = self.vows.get(entry.vow_id) orelse unreachable;
            std.debug.assert(row.forwarded_peer == peer_handle);
            self.vat.breakVow(entry.vat_resolver, reason) catch unreachable;
            std.debug.assert(self.resolver_index.remove(resolver_id));
            std.debug.assert(self.vows.remove(entry.vow_id));
            self.finishSessionOperation(session);
            self.allocator.destroy(row);
        }
    }

    while (true) {
        var n: usize = 0;
        var it = self.vows.iterator();
        while (it.next()) |entry| {
            const row_peer = entry.value_ptr.*.peer_handle orelse continue;
            if (row_peer != peer_handle) continue;
            doomed[n] = entry.key_ptr.*;
            n += 1;
            if (n == doomed.len) break;
        }
        if (n == 0) return;
        for (doomed[0..n]) |id| {
            const row = self.vows.fetchRemove(id) orelse unreachable;
            self.finishSessionOperation(session);
            self.allocator.destroy(row.value);
        }
    }
}
