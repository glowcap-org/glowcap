//! Host vows and resolver pairs: the read side every asynchronous host verb
//! returns, and the reservation/attachment machinery behind it.
//!
//! One of `host.zig`'s responsibilities, kept in a sibling file. The
//! `Host` owns the state (the vow map, the resolver index, the id
//! sources) and presents the `vow*`, `deferTurn`, and `resolver*`
//! verbs through decl aliases, so a caller reads one `Host`
//! surface. This file holds the operation side of that lifecycle: mint,
//! listener attachment, eventual sends, and projections. `vows/settlement.zig`
//! owns the row's one terminal transition and completion dispatch.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const value_mod = @import("value.zig");

const host_mod = @import("host.zig");
const host_pump = @import("host/pump.zig");
const vocab = @import("vocab.zig");
const settlement = @import("vows/settlement.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;

/// The public vow id the next committed operation spends.
pub fn peekVowId(self: *const Host) error{CapabilitySpaceExhausted}!u64 {
    return self.vow_ids.peek() orelse error.CapabilitySpaceExhausted;
}

const VowRow = settlement.VowRow;
const AnswerRelease = settlement.AnswerRelease;
const PendingCancel = settlement.PendingCancel;

pub const ResolverIndexEntry = struct { vow_id: u64, vat_resolver: u64 };
const ResolvedVow = struct { row: *VowRow, session: *HostSession };

const Projection = union(enum) { index: i64, untag: []const u8, get: []const u8 };

/// Owns one unpublished Host vow until its semantic operation commits.
/// Rollback cancels observer-release capacity before freeing the row. Listener
/// and map reservations are capacity only and remain available for the retry.
/// This owner stays on the producer's stack, adding no Host or wire state.
pub const VowReservation = struct {
    const Transfer = struct { row: *VowRow, listener: actors.ListenerReservation };

    host: *Host,
    session: *HostSession,
    unpublished: ?*VowRow,
    listener: actors.ListenerReservation,

    pub fn deinit(self: *VowReservation) void {
        const row = self.unpublished orelse return;
        settlement.cancelObserverRelease(row, self.session);
        self.host.allocator.destroy(row);
        self.unpublished = null;
    }

    /// Borrow the row while installing its recipient, before publication.
    pub fn getRow(self: *const VowReservation) *VowRow {
        return self.unpublished orelse unreachable;
    }

    /// Transfer both reservations to a shared-enliven group. The group owns
    /// publication and uses its own terminal listener rather than VowRow.fire.
    pub fn take(self: *VowReservation) Transfer {
        const result: Transfer = .{ .row = self.getRow(), .listener = self.listener };
        self.unpublished = null;
        return result;
    }

    /// Publish using only resources reserved before the operation committed.
    /// Disarming this owner is part of the infallible ownership transfer.
    pub fn commit(self: *VowReservation, vow: actors.Vow) u64 {
        const transferred = self.take();
        const row_value = transferred.row;
        const host = self.host;
        row_value.vow = vow;
        const installed: actors.Listener = .{ .ctx = row_value, .func = VowRow.fire };
        row_value.pending_cancel = .{ .row_listener = installed };
        _ = settlement.claimPeerVisibleAnswer(row_value, self.session);
        self.session.served.port.onReserved(&host.vat, transferred.listener, vow, installed);
        publishRow(host, row_value);
        host.beginSessionOperation(self.session);
        host.vow_ids.commit(row_value.id);
        return row_value.id;
    }
};

/// Register a one-shot in-process listener on a host vow. The listener hears
/// the resolution borrowed (zero-copy) and keeps settlement off the action
/// queue. A remote answer reserves its eventual `op:gc-answer` carrier here,
/// before the callback can make settlement infallible. A second listener on a
/// pending row is refused `AlreadyListening`. A completed public vow is
/// refused `AlreadySettled` but remains a valid pipeline target until release.
pub fn vowOn(self: *Host, vow_id: u64, listener: actors.Listener) !void {
    const resolved = try resolveVowSession(self, vow_id);
    if (resolved.row.settled) return error.AlreadySettled;
    if (resolved.row.inner != null) return error.AlreadyListening;
    if (resolved.row.answer_release == .peer_visible)
        resolved.row.observer_release = try resolved.session.served.port.peer.reserveAnswerRelease();
    resolved.row.inner = listener;
}

/// Prepare the same observer-owned release when a deferred vow acquires its
/// real remote answer only after `vowOn` has already installed the observer.
pub fn reserveDeferredObserverRelease(
    self: *Host,
    vow_id: u64,
    target: *HostSession,
) !?engine.Peer.PendingReservation {
    const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
    if (row.inner == null) return null;
    const reservation = try target.served.port.peer.reserveAnswerRelease();
    return reservation;
}

/// Owning session for a still-live vow, used by adapters to lower opaque
/// Host references in a pipelined send before entering the wire surface.
pub fn vowSession(self: *Host, vow_id: u64) !*HostSession {
    return (try resolveVowSession(self, vow_id)).session;
}

/// Number of Host vow rows whose producer can still settle. Settled public
/// handles remain in `vows` until release but are not close work and reserve no
/// future completion slot.
pub fn pendingVowCount(self: *const Host) usize {
    return @intCast(self.pending_vow_count);
}

/// Host-core row publication seam. Producers reserve first, then publish only
/// after the operation that can settle the row has committed.
pub fn publishRow(self: *Host, row: *VowRow) void {
    std.debug.assert(!row.settled);
    std.debug.assert(!self.vows.contains(row.id));
    std.debug.assert(self.pending_vow_count != std.math.maxInt(u32));
    self.vows.putAssumeCapacity(row.id, row);
    self.pending_vow_count += 1;
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

/// Fire-and-forget eventual-send through a remote Host vow. This is the
/// no-answer sibling of `vowSendValues`: it allocates no answer position and
/// publishes no Host vow.
pub fn vowTellValues(
    self: *Host,
    vow_id: u64,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
) !void {
    const resolved = try admitVowVerb(self, vow_id);
    var prepared = try self.prepareValues(resolved.session, arena, values);
    defer prepared.deinit();
    try resolved.session.served.tellToAnswer(
        &self.vat,
        .{ .far = try pipelineAnswer(resolved.row) },
        .{ .verb = verb, .args = prepared.values },
    );
    _ = prepared.commit();
    self.node.exporterApplicationOwned(resolved.session.peer_handle);
    try host_pump.dirtyThenPump(self, resolved.session.peer_handle);
}

fn vowSendValuesWithProgress(
    self: *Host,
    vow_id: u64,
    verb: []const u8,
    values: []const value_mod.Value,
    arena: std.mem.Allocator,
    drive_now: bool,
) !u64 {
    const resolved = try admitVowVerb(self, vow_id);
    var prepared = try self.prepareValues(resolved.session, arena, values);
    defer prepared.deinit();
    const id = try commitVowSend(self, resolved, .{ .verb = verb, .args = prepared.values }, drive_now);
    _ = prepared.commit();
    return id;
}

fn vowSendWithProgress(self: *Host, vow_id: u64, msg: actors.Message, drive_now: bool) !u64 {
    const resolved = try admitVowVerb(self, vow_id);
    return commitVowSend(self, resolved, msg, drive_now);
}

fn commitVowSend(
    self: *Host,
    resolved: ResolvedVow,
    msg: actors.Message,
    drive_now: bool,
) !u64 {
    const source = try pipelineAnswer(resolved.row);
    var reservation = try reserveVow(self, resolved.session, .far, .plain, .peer_visible);
    defer reservation.deinit();
    const vow = try resolved.session.served.sendToAnswer(&self.vat, .{ .far = source }, msg);
    const id = reservation.commit(vow);
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
/// vow for the named Struct field (ADR-0004).
pub fn vowGet(self: *Host, vow_id: u64, field: []const u8) !u64 {
    return vowProjection(self, vow_id, .{ .get = field });
}

/// Reserve a Host row and the exact Vat/Port listener slot before an operation
/// that creates a vow becomes visible. Once this succeeds,
/// `VowReservation.commit` is allocation-free and cannot turn a committed send
/// into a retryable OOM.
pub fn reserveVow(
    self: *Host,
    session: *HostSession,
    location: actors.VowLocation,
    kind: VowRow.Kind,
    answer_release: AnswerRelease,
) !VowReservation {
    return reserveVowAt(self, session, location, kind, answer_release, try peekVowId(self));
}

/// Explicit-id reservation for a continuation whose public vow id was minted
/// before its eventual session existed (sturdyref select-or-dial).
pub fn reserveVowAt(
    self: *Host,
    session: *HostSession,
    location: actors.VowLocation,
    kind: VowRow.Kind,
    answer_release: AnswerRelease,
    id: u64,
) !VowReservation {
    const row = try reserveRow(self, session, kind, answer_release, id);
    errdefer self.allocator.destroy(row);
    const listener = try session.served.port.reserveListener(&self.vat, location);
    return .{ .host = self, .session = session, .unpublished = row, .listener = listener };
}

/// Mint a Host vow whose producing operation is admitted now but cannot be
/// attached to its eventual session yet. Inline handoff sends use this while
/// redemption is pending. The row is fully observable to `vowOn` immediately.
/// Its producer later settles it through `fireVow` and may transfer its
/// session ownership with `moveDeferredVow` before that settlement.
pub fn mintDeferredVow(
    self: *Host,
    session: *HostSession,
    pending_cancel: PendingCancel.Fallible,
) !u64 {
    const id = try peekVowId(self);
    const row = try reserveRow(self, session, .plain, .none, id);
    row.vow = .{ .local = id };
    row.pending_cancel = .{ .fallible_no_answer = pending_cancel };
    publishRow(self, row);
    self.vow_ids.commit(id);
    self.beginSessionOperation(session);
    return id;
}

/// Transfer one admitted deferred producer from the session on which the
/// caller learned the promise to the session that now owns its real send.
pub fn moveDeferredVow(self: *Host, vow_id: u64, target: *HostSession) void {
    const row = self.vows.get(vow_id) orelse return;
    const source_peer = row.peer() orelse unreachable;
    if (source_peer == target.peer_handle) return;
    if (self.sessions.get(source_peer)) |source| self.finishSessionOperation(source);
    self.beginSessionOperation(target);
    row.owner = .{ .session = target.peer_handle };
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
    answer_release: AnswerRelease,
    observer_release: ?engine.Peer.PendingReservation,
) void {
    moveDeferredVow(self, vow_id, target);
    const row = self.vows.get(vow_id) orelse unreachable;
    row.vow = vow;
    row.answer_release = answer_release;
    std.debug.assert(observer_release == null or answer_release == .peer_visible);
    std.debug.assert(observer_release == null or row.inner != null);
    row.observer_release = observer_release;
    const installed: actors.Listener = .{ .ctx = row, .func = VowRow.fire };
    row.pending_cancel = .{ .row_listener = installed };
    _ = settlement.claimPeerVisibleAnswer(row, target);
    target.served.port.onReserved(&self.vat, listener, vow, installed);
}

/// Reserve one unpublished row for a Host-core producer.
pub fn reserveRow(
    self: *Host,
    session: ?*HostSession,
    kind: VowRow.Kind,
    answer_release: AnswerRelease,
    id: u64,
) !*VowRow {
    if (self.pending_vow_count == std.math.maxInt(u32))
        return error.CapabilitySpaceExhausted;
    const row = try self.allocator.create(VowRow);
    errdefer self.allocator.destroy(row);
    row.* = .{
        .host = self,
        .owner = if (session) |s| .{ .session = s.peer_handle } else .resolver,
        .id = id,
        .vow = undefined,
        .kind = kind,
        .answer_release = answer_release,
    };
    try self.vows.ensureUnusedCapacity(self.allocator, 1);
    // A session vow can settle onto the embedder action queue. Resolver rows
    // settle through their holder and reserve no queue slot they cannot use.
    if (session != null) try self.reserveActions(1);
    return row;
}

fn vowProjection(self: *Host, vow_id: u64, projection: Projection) !u64 {
    try self.admitApplicationOperation();
    const resolved = try resolveVowSession(self, vow_id);
    try self.admitSessionOperation(resolved.session);
    const source = try pipelineAnswer(resolved.row);
    try self.checkOutboundAdmission(resolved.session);
    var reservation = try reserveVow(self, resolved.session, .far, .plain, .peer_visible);
    defer reservation.deinit();
    const peer = resolved.session.served.port.peer;
    const answer = try peer.allocateAnswer();
    const receiver: model.Reference = .{ .promise = .{ .answer_position = source.position } };
    switch (projection) {
        .index => |index| try peer.sendBorrowed(.{ .index = .{
            .receiver = receiver,
            .index = .{ .integer = index },
            .answer = answer.position,
        } }),
        .untag => |tag| try peer.sendBorrowed(.{ .untag = .{ .receiver = receiver, .tag = tag, .answer = answer.position } }),
        .get => |field| try peer.sendBorrowed(.{ .get = .{ .receiver = receiver, .field = field, .answer = answer.position } }),
    }
    const id = reservation.commit(.{ .far = answer });
    host_pump.finishCommittedVow(self, resolved.session);
    return id;
}

fn pipelineAnswer(row: *const VowRow) !engine.OutboundAnswerTarget {
    if (row.answer_release != .peer_visible and row.answer_release != .shared_peer_visible) return error.NotPipelineable;
    return switch (row.vow) {
        .far => |answer| answer,
        .local => return error.NotPipelineable,
    };
}

/// The live session and row a latch-legal vow verb operates on: assert the
/// owner, resolve the vow's row and its session, and refuse a released or
/// unknown vow or a dead session alike with `NoSuchVow`. Settled embedder rows
/// remain valid pipeline targets until explicit release.
/// `vowOn`, `vowSend`, and `vowProjection` share this prelude
/// and differ only in the body that follows.
/// Admit an application verb addressed through a vow: the Host, the session
/// the vow resolved through, and that session's outbound.
fn admitVowVerb(self: *Host, vow_id: u64) !ResolvedVow {
    try self.admitApplicationOperation();
    const resolved = try resolveVowSession(self, vow_id);
    try self.admitSessionOperation(resolved.session);
    try self.checkOutboundAdmission(resolved.session);
    return resolved;
}

fn resolveVowSession(self: *Host, vow_id: u64) HostError!ResolvedVow {
    self.assertOwner();
    const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
    const peer_handle = row.peer() orelse return HostError.SessionlessVow;
    const session = self.sessions.get(peer_handle) orelse return HostError.NoSuchVow;
    try self.checkSession(session);
    return .{ .row = row, .session = session };
}
