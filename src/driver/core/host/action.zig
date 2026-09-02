//! The embedder-facing host action queue: the payload shapes, how their
//! owned bytes are released, and the queue verbs themselves — the borrowed
//! and owned pops, the reservation ceiling, and the drain-resume. `Host`
//! owns the FIFO storage; this module owns everything done to it.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const host_pump = @import("pump.zig");
const pump_schedule = @import("pump/schedule.zig");
const sessions_mod = @import("../sessions.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;

/// Why an unobserved Host vow failed. This is settled where session lifecycle
/// is authoritative so adapters only project the result into their error type.
pub const VowFailure = enum {
    broken,
    closed,
};

/// Host-owned failure detail, with an allocation-free diagnostic when copying
/// the original reason itself fails. The ownership bit belongs to the action
/// payload layer: consumers always see useful text, while teardown frees only
/// storage the Host allocator actually produced.
pub const RetainedFailureMessage = struct {
    bytes: []const u8,
    owned: bool,
};

pub const failure_detail_allocation_message = "failure detail unavailable: allocation failed";

pub fn retainFailureMessage(allocator: std.mem.Allocator, message: []const u8) RetainedFailureMessage {
    const owned = allocator.dupe(u8, message) catch return .{
        .bytes = failure_detail_allocation_message,
        .owned = false,
    };
    return .{ .bytes = owned, .owned = true };
}

/// What the embedder must do next. `Host.nextAction` pops borrowed: a
/// completion's value views are host-owned and stay valid until the next
/// `Host.nextAction` call, which frees them — the same borrow contract
/// `engine.Node.nextAction` carries for node-level actions. `Host.takeAction`
/// pops owned instead: the caller adopts the payload and frees it with
/// `Host.freeAction` (or moves it into a durable owner first).
///
/// `dial` carries the logical ticket and stable route index; the dial view
/// lives on the node pending row (`Host.pendingDial` / C
/// `glowcap_host_pending_dial`).
pub const HostAction = union(enum) {
    /// Dial the exporter named by this attempt's active pending-dial view with
    /// this host's identity, then report
    /// `exporterDialed(ticket, route_index, conn)` — or
    /// `dialFailed(ticket, route_index, reason)` if the path refuses. A failed
    /// path may produce another DIAL for the same ticket; the Host/Node owns
    /// ranking and fallback while the embedder executes only exact attempts.
    dial: struct { ticket: engine.Node.PendingId, route_index: usize },
    /// Stop one previously delivered `dial` effect. The executor interrupts
    /// and joins its physical operation, then calls `Host.dialCancelled`.
    cancel_dial: struct { ticket: engine.Node.PendingId, route_index: usize },
    /// Outbound transport packets may be ready on this session: drain
    /// `HostSession.takeTransportOutbound` until empty and write them.
    flush: engine.PeerHandle,
    /// The host is done with this session: flush any queued terminal frame,
    /// then tear its transport down and release it. This covers condemned
    /// sessions and exporter sessions opened solely for a failed handoff
    /// redemption. Without this action a byte-fed embedder has no way to
    /// learn a session died inside the pump; `condemned` alone only refuses
    /// future verbs.
    close: engine.PeerHandle,
    /// Draw 32 bytes of gift-id entropy and feed them back through
    /// `provideGiftId(ticket, bytes)`. Entropy is a host effect like dialing;
    /// the sans-io host never generates it.
    need_gift_id: struct { ticket: u64 },
    /// A host vow with no in-process listener settled fulfilled: `value` is a
    /// deep clone the host owns, valid until the next `nextAction` call,
    /// which frees it. Route it to whatever awaits the vow. `peer_handle` is the
    /// session the value belongs to, and is never absent: a fulfilled value
    /// may carry a capability, which only its own session can project.
    settled: struct { peer_handle: engine.PeerHandle, vow_id: u64, value: model.Argument },
    /// A host vow with no in-process listener settled broken: `message` is
    /// host-owned with the same until-next-`nextAction` lifetime. An empty
    /// reason stays empty; failure to retain a nonempty reason is represented
    /// by a process-static allocation diagnostic. `peer_handle`
    /// is null when the vow rode no session at all — a select-or-dial enliven
    /// whose dial never opened one (ADR-0098). A break carries no value, so
    /// every drain routes it by `vow_id` alone.
    failed: struct {
        peer_handle: ?engine.PeerHandle,
        vow_id: u64,
        failure: VowFailure,
        message: []const u8,
        message_owned: bool,
    },
    /// The finite Host scheduler yielded with internal work remaining and no
    /// ordinary action available to wake the next drain. A reactor-backed
    /// embedder returns to its scheduler before starting the next drain turn;
    /// no I/O or session belongs to this action.
    resume_work,
};

/// Free every owned byte view a `HostAction` may carry. POD arms are no-ops.
pub fn freePayload(allocator: std.mem.Allocator, action: HostAction) void {
    switch (action) {
        .settled => |s| model.freeArgument(allocator, s.value),
        .failed => |f| if (f.message_owned) allocator.free(f.message),
        .dial, .cancel_dial, .flush, .close, .need_gift_id, .resume_work => {},
    }
}

/// Pop the next embedder action, borrowed: the previous action's byte
/// views are freed here, so a popped action is valid until the next call.
/// Null when no action is pending. Top-level: refused under the callback
/// latch, where the enclosing verb is still queueing and freeing the
/// previous action would dangle views the embedder still holds.
pub fn nextAction(self: *Host) HostError!?HostAction {
    try self.refuseReentry();
    if (self.retry_last_action) {
        self.retry_last_action = false;
        const action = self.last_action orelse unreachable;
        if (action == .need_gift_id and !self.node.hasPendingGift(action.need_gift_id.ticket)) {
            self.last_action = null;
            return nextAction(self);
        }
        if (action == .dial and !self.node.beginDialEffect(action.dial.ticket, action.dial.route_index)) return null;
        return action;
    }
    try resumeWorkForActionDrain(
        self,
    );
    if (self.last_action) |last| {
        freePayload(self.allocator, last);
        self.last_action = null;
    }
    const action = popAction(
        self,
    ) orelse return null;
    self.last_action = action;
    return action;
}

/// Preserve the current borrowed pop for the next `nextAction` call. This is
/// the transactional refusal path for the C convenience pump: a non-OK arm
/// means it committed no externally visible effect, so the exact action must
/// remain first without being copied or appended behind younger rows.
pub fn retryBorrowedAction(self: *Host) bool {
    if (self.last_action == null or self.retry_last_action) return false;
    if (self.last_action.? == .dial)
        self.node.rollbackDialEffect(self.last_action.?.dial.ticket, self.last_action.?.dial.route_index);
    self.retry_last_action = true;
    return true;
}

/// Borrow the next owned-pop action without consuming it. This is the
/// preflight seam for fallible external preparation: an embedder may acquire
/// entropy or another resource first, then call `takeAction` only once that
/// preparation succeeds. The view follows the queue's lifetime and is invalid
/// after any Host mutation.
pub fn peekAction(self: *Host) HostError!?HostAction {
    try self.refuseReentry();
    if (self.retry_last_action) {
        const action = self.last_action orelse unreachable;
        if (action != .need_gift_id or self.node.hasPendingGift(action.need_gift_id.ticket)) return action;
        self.retry_last_action = false;
        self.last_action = null;
    }
    try resumeWorkForActionDrain(self);
    while (self.actions.peek()) |action| {
        if (action != .need_gift_id or self.node.hasPendingGift(action.need_gift_id.ticket)) return action;
        _ = self.actions.pop(self.allocator) orelse unreachable;
    }
    return null;
}

/// Pop the next embedder action, owned: the caller adopts the payload and
/// frees it with `freeAction` — or moves it into a durable owner first,
/// which is how `driver.Bridge` parks a completion with zero
/// copies. Leaves the `nextAction` borrow untouched, so the two pops
/// compose. Refused under the latch like `nextAction`.
pub fn takeAction(self: *Host) HostError!?HostAction {
    try self.refuseReentry();
    if (self.retry_last_action) {
        self.retry_last_action = false;
        const action = self.last_action orelse unreachable;
        self.last_action = null;
        if (action == .need_gift_id and !self.node.hasPendingGift(action.need_gift_id.ticket))
            return takeAction(self);
        if (action == .dial and !self.node.beginDialEffect(action.dial.ticket, action.dial.route_index)) return null;
        return action;
    }
    try resumeWorkForActionDrain(
        self,
    );
    return popAction(
        self,
    );
}

/// Free an action `takeAction` transferred, once its payload is consumed
/// (a moved-out payload is the new owner's to free instead).
pub fn freeAdopted(self: *Host, action: HostAction) void {
    freePayload(self.allocator, action);
}

/// Put a popped, retryable external-effect action back on the FIFO after its
/// executor refused before commit. Popping left one physical slot, so this
/// append cannot allocate.
pub fn retryEffect(self: *Host, action: HostAction) void {
    switch (action) {
        .dial => |dial| {
            self.node.rollbackDialEffect(dial.ticket, dial.route_index);
            self.actions.pushReserved(action);
        },
        .cancel_dial => self.actions.pushReserved(action),
        .need_gift_id => self.actions.pushReserved(action),
        else => unreachable,
    }
}

/// The one FIFO pop under both action verbs: compact the dead prefix past
/// the threshold and hand out the front row, owning nothing.
pub fn popAction(self: *Host) ?HostAction {
    const action = while (self.actions.pop(self.allocator)) |candidate| {
        if (candidate == .dial and
            !self.node.beginDialEffect(candidate.dial.ticket, candidate.dial.route_index)) continue;
        if (candidate == .need_gift_id and !self.node.hasPendingGift(candidate.need_gift_id.ticket)) continue;
        break candidate;
    } else return null;
    switch (action) {
        .flush => |peer_handle| {
            if (self.sessions.get(peer_handle)) |session|
                session.control.flush_action_pending = false;
        },
        .close => |peer_handle| {
            if (self.sessions.get(peer_handle)) |session|
                session.control.close_action_pending = false;
        },
        .resume_work => self.resume_action_pending = false,
        else => {},
    }
    return action;
}

pub fn resumeWorkForActionDrain(self: *Host) HostError!void {
    // External actions already wake the embedder and must leave before more
    // core work is admitted. Pumping while one is parked lets a drain grow an
    // unbounded action suffix before the reactor can honor its first effect.
    if (self.actions.peek() != null) return;
    // A refused pump stands down until the pressure could have moved (a new
    // drain pass, or the embedder taking outbound bytes). Without this, a
    // session whose refusal cannot clear inside this pass — its connection is
    // closing, so no flush the pass executes can drain it — re-feeds the pass
    // one flush wake per pump, and the drain never returns to the reactor
    // whose completions would retire that very connection.
    if (self.resume_pump_refused) return;
    host_pump.finishVerb(self) catch |err| switch (err) {
        error.OutOfMemory => return HostError.OutOfMemory,
        // `drainWork` requeued the dirty session and published its deduplicated
        // FLUSH wake before returning. Continue into `popAction` so the
        // embedder can drain the bytes that make this pressure actionable;
        // condemning every session here would turn normal flow control into a
        // Host-wide protocol failure.
        error.OutboundBackpressure => {
            self.resume_pump_refused = true;
            // Standing down preserves liveness only if the drain comes back:
            // wake it once, deduplicated, so the retry runs at the reactor's
            // cadence instead of never. The refused work is not lost either
            // way — the dirty FIFO still holds it, and a reaped or drained
            // connection is what finally moves it.
            // best-effort: a wake that cannot reserve its slot loses only the
            // wake; the next Host verb resumes the same dirty FIFO.
            pump_schedule.queueResumeAction(self) catch {};
            return;
        },
        else => sessions_mod.condemnRemainingSessions(self, "host action cleanup failed"),
    };
}

/// Reserve action-queue capacity for every irreversible notification the
/// host has already promised, plus the `extra` slots this caller is about
/// to owe. The one owner of that ceiling.
///
/// The promises, and why each is a slot: every pending vow settles exactly
/// once, through a `settled` or `failed` action, and the fire that
/// carries it is infallible by then. Every parked select-or-dial enliven
/// (ADR-0098) settles the same way, under an id its caller already holds.
/// Every live session owes at most one flush and one close notification,
/// both irreversible once a frame or a close verdict exists. A caller
/// naming `extra` is saying what it is adding on top: the action it is
/// about to push, the vow or parked enliven it is about to mint, or the
/// session whose two notifications do not exist yet.
///
/// Reserving ahead is what lets those pushes be infallible later. A
/// settled vow with no completion is unrepresentable, so the capacity has
/// to exist before the promise does.
/// `pub` for the Host-core siblings, not for embedders: splitting a Zig
/// struct across files needs the callee visible. Host-core internal.
pub fn reserveActions(self: *Host, extra: usize) !void {
    try self.actions.reserve(
        self.allocator,
        self.pendingVowCount() + self.pending_enliven_count + 2 * self.sessions.count() + extra,
    );
}
