//! The embedder-facing host action queue: the payload shapes, how their
//! owned bytes are released, and the queue verbs themselves — the borrowed
//! and owned pops, the reservation ceiling, and the drain-resume. `Host`
//! owns the FIFO storage; this module owns everything done to it.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("host.zig");
const host_pump = @import("host_pump.zig");
const sessions_mod = @import("sessions.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;

/// What the embedder must do next. `Host.nextAction` pops borrowed: a
/// completion's value views are host-owned and stay valid until the next
/// `Host.nextAction` call, which frees them — the same borrow contract
/// `engine.Node.nextAction` carries for node-level actions. `Host.takeAction`
/// pops owned instead: the caller adopts the payload and frees it with
/// `Host.freeAction` (or moves it into a durable owner first).
///
/// `dial` carries only the pending ticket; the dial view lives on the node
/// pending row (`Host.pendingDial` / C `pancake_host_pending_dial`).
pub const HostAction = union(enum) {
    /// Dial the exporter named by this ticket's active pending-dial view with
    /// this host's identity, then report `exporterDialed(ticket, conn)` — or
    /// `dialFailed(ticket, reason)` if the path refuses. A failed path may
    /// produce another DIAL for the same ticket; the Host/Node owns that
    /// fallback and the embedder does not select alternatives.
    dial: struct { ticket: engine.Node.PendingId },
    /// Outbound frames may be ready on this session: drain
    /// `Conn.takeOutbound` until empty and write them.
    flush: engine.PeerId,
    /// The host is done with this session: flush any queued terminal frame,
    /// then tear its transport down and release it. This covers condemned
    /// sessions and exporter sessions opened solely for a failed handoff
    /// redemption. Without this action a byte-fed embedder has no way to
    /// learn a session died inside the pump; `condemned` alone only refuses
    /// future verbs.
    close: engine.PeerId,
    /// Draw 32 bytes of gift-id entropy and feed them back through
    /// `provideGiftId(ticket, bytes)`. Entropy is a host effect like dialing;
    /// the sans-io host never generates it.
    need_gift_id: struct { ticket: u64 },
    /// A host vow with no in-process listener settled fulfilled: `value` is a
    /// deep clone the host owns, valid until the next `nextAction` call,
    /// which frees it. Route it to whatever awaits the vow. `peer_id` is the
    /// session the value belongs to, and is never absent: a fulfilled value
    /// may carry a capability, which only its own session can project.
    settled: struct { peer_id: engine.PeerId, vow_id: u64, value: model.Argument },
    /// A host vow with no in-process listener settled broken: `message` is
    /// host-owned with the same until-next-`nextAction` lifetime (empty when
    /// the break carried no reason, or when retaining one failed). `peer_id`
    /// is null when the vow rode no session at all — a select-or-dial enliven
    /// whose dial never opened one (ADR-0098). A break carries no value, so
    /// every drain routes it by `vow_id` alone.
    failed: struct { peer_id: ?engine.PeerId, vow_id: u64, message: []const u8 },
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
        .failed => |f| if (f.message.len != 0) allocator.free(f.message),
        .dial, .flush, .close, .need_gift_id, .resume_work => {},
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
        return self.last_action orelse unreachable;
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
    if (self.retry_last_action)
        return self.last_action orelse unreachable;
    try resumeWorkForActionDrain(self);
    return self.actions.peek();
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
/// executor failed. These ticket-only arms are idempotent: if the first attempt
/// committed before its tail failed, the retried ticket is stale and resumes
/// cleanup; if it did not commit, the Node still owns the pending row. Popping
/// left one physical slot, so this append cannot allocate.
pub fn retryEffect(self: *Host, action: HostAction) void {
    switch (action) {
        .dial, .need_gift_id => self.actions.pushReserved(action),
        else => unreachable,
    }
}

/// The one FIFO pop under both action verbs: compact the dead prefix past
/// the threshold and hand out the front row, owning nothing.
pub fn popAction(self: *Host) ?HostAction {
    const action = self.actions.pop(self.allocator) orelse return null;
    switch (action) {
        .flush => |peer_id| {
            if (self.sessions.get(peer_id)) |session|
                session.flush_action_pending = false;
        },
        .close => |peer_id| {
            if (self.sessions.get(peer_id)) |session|
                session.close_action_pending = false;
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
    host_pump.finishVerb(self) catch |err| switch (err) {
        error.OutOfMemory => return HostError.OutOfMemory,
        // `drainWork` requeued the dirty session and published its deduplicated
        // FLUSH wake before returning. Continue into `popAction` so the
        // embedder can drain the bytes that make this pressure actionable;
        // condemning every session here would turn normal flow control into a
        // Host-wide protocol failure.
        error.OutboundBackpressure => return,
        else => sessions_mod.condemnRemainingSessions(self, "host action cleanup failed"),
    };
}

/// Reserve action-queue capacity for every irreversible notification the
/// host has already promised, plus the `extra` slots this caller is about
/// to owe. The one owner of that ceiling.
///
/// The promises, and why each is a slot: every live vow settles exactly
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
        self.vows.count() + self.pending_enlivens.items.len + 2 * self.sessions.count() + extra,
    );
}

/// Test seam: session-tagged embedder FIFO dedupe (flush/close).
pub fn testingQueueUniqueSessionAction(self: *Host, comptime tag: host_pump.UniqueSessionActionTag, peer_id: engine.PeerId) !void {
    try host_pump.testingQueueUniqueSessionAction(self, tag, peer_id);
}
