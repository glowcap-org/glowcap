//! Close policy for the byte-fed Host core: owner admission seals, finite
//! deadline expiry, cancellation escalation, per-session close progression,
//! and the quiescence transition to terminal state.
//!
//! One of `host.zig`'s responsibilities, kept in its own file. The `Host` owns
//! every lifecycle field and presents these functions as its own methods
//! through the alias table in `host.zig`. Adapters only start close, advance
//! time, and observe the resulting state.

const std = @import("std");
const builtin = @import("builtin");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const close_mod = @import("../close.zig");
const host_pump = @import("pump.zig");
const sessions_mod = @import("../sessions.zig");
const enliven_mod = @import("../enliven.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;

/// Application-owner lifecycle. CapTP session protocol state remains
/// authoritative in each session and is not represented here.
pub const LifecyclePhase = enum {
    active,
    finishing,
    terminating,
    closed,

    /// Whether the Host still admits work: active, or finishing what it
    /// admitted.
    pub fn serving(self: LifecyclePhase) bool {
        return switch (self) {
            .active, .finishing => true,
            .terminating, .closed => false,
        };
    }
};

/// Inline Host lifecycle state. `pub` is cross-file visibility for the Host
/// aggregate. Consumers reach only `Host.LifecyclePhase`.
pub const Lifecycle = union(LifecyclePhase) {
    active: void,
    finishing: ?i64,
    terminating: struct {
        abort_kind: model.AbortKind,
        sessions_started: bool = false,
        timed_out: bool,
    },
    closed: struct { timed_out: bool },
};

/// Finite close timing is sparse Host state: active and unbounded sessions pay
/// no per-shell deadline. Cross-file visibility is for the aggregate field.
pub const SessionCloseTiming = union(enum) {
    deadline_ms: i64,
    timed_out,
};

/// Seal application admission and begin terminal Host close. Finish waits for
/// already-admitted vows, deferred answers, and actions. Cancel moves directly
/// to terminal session shutdown. A later cancel escalates finish. Recording the
/// barrier is legal under the callback latch. The enclosing verb's `finishVerb`
/// remains the only driver of queued work and teardown.
pub fn beginClose(self: *Host, pending: close_mod.PendingWork, now_ms: i64) void {
    self.assertOwner();
    // Time already elapsed under the first request is authoritative. Apply its
    // deadline before a repeated cancel can otherwise erase timeout.
    _ = expireCloseAt(self, now_ms);
    switch (self.lifecycle) {
        .active => switch (pending) {
            .cancel => startTermination(self, .normal_shutdown, false),
            .finish => |budget| self.lifecycle = .{ .finishing = close_mod.deadlineFor(budget, now_ms) },
        },
        .finishing => if (pending == .cancel) startTermination(self, .normal_shutdown, false),
        .terminating, .closed => return,
    }
    _ = expireCloseAt(self, now_ms);
}

fn startTermination(self: *Host, abort_kind: model.AbortKind, timed_out: bool) void {
    self.lifecycle = .{ .terminating = .{
        .abort_kind = abort_kind,
        .timed_out = timed_out,
    } };
    // Every in-flight dial vacated one queue slot when its action was
    // delivered, so its cancellation command can reuse that reserved capacity
    // without making terminal close fallible.
    var cancellations = self.node.requestDialCancellations();
    while (cancellations.next()) |cancellation|
        self.actions.pushReserved(.{ .cancel_dial = .{
            .ticket = cancellation.pending,
            .route_index = cancellation.route_index,
        } });
    self.node.cancelPendingGifts();
}

fn driveClose(self: *Host) void {
    host_pump.finishVerb(self) catch |err| switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => return,
        else => {
            switch (self.lifecycle) {
                .terminating => |*terminal| terminal.abort_kind = .other,
                else => startTermination(self, .other, false),
            }
            _ = advanceCloseLifecycle(self);
        },
    };
}

/// Apply the caller's monotonic time to the Host close policy. Expiry is a
/// core-owned monotonic escalation. The caller performs no policy branch.
pub fn progressClose(self: *Host, now_ms: i64) HostError!void {
    try self.refuseReentry();
    try progressCloseAt(self, now_ms);
}

fn progressCloseAt(self: *Host, now_ms: i64) HostError!void {
    _ = expireCloseAt(self, now_ms);
    switch (lifecyclePhase(self)) {
        .active, .closed => {},
        .finishing, .terminating => driveClose(self),
    }
}

fn expireCloseAt(self: *Host, now_ms: i64) bool {
    const deadline = switch (self.lifecycle) {
        .finishing => |deadline| deadline orelse return false,
        else => return false,
    };
    if (now_ms < deadline) return false;
    startTermination(self, .normal_shutdown, true);
    return true;
}

fn closeDeadline(self: *const Host) ?i64 {
    return switch (self.lifecycle) {
        .finishing => |deadline| deadline,
        else => null,
    };
}

pub fn closeOutcome(self: *const Host, completion_reached: bool) close_mod.CloseOutcome {
    if (!completion_reached) return .pending;
    const timed_out = switch (self.lifecycle) {
        .terminating => |terminal| terminal.timed_out,
        .closed => |closed| closed.timed_out,
        .active, .finishing => return .pending,
    };
    return if (timed_out) .timed_out else .closed;
}

/// Seal one session's application admission and begin its terminal close.
/// Finish keeps protocol ingress live until the session's admitted operations
/// retire. Cancel commits the terminal verdict immediately.
pub fn beginSessionClose(
    self: *Host,
    session: *HostSession,
    pending: close_mod.PendingWork,
    now_ms: i64,
) !void {
    self.assertOwner();
    try self.checkOwnedSession(session);
    // As for Host close, expiry belongs to the first finish request and must
    // win over a later cancel arriving at or after its deadline.
    expireSessionCloseAt(self, session, now_ms);
    switch (session.lifecyclePhase()) {
        .active => switch (pending) {
            .cancel => startSessionCancellation(self, session),
            .finish => |budget| {
                if (close_mod.deadlineFor(budget, now_ms)) |deadline| {
                    try self.session_close_timing.ensureUnusedCapacity(self.allocator, 1);
                    self.session_close_timing.putAssumeCapacity(session.peer_handle, .{ .deadline_ms = deadline });
                    noteSessionCloseDeadline(self, deadline);
                }
                session.control.phase = .finishing;
                if (session.pendingOperations() == 0) host_pump.markDirty(self, session.peer_handle);
            },
        },
        .finishing => if (pending == .cancel)
            startSessionCancellation(self, session),
        .cancel_pending, .terminating => return,
    }
}

fn expireSessionCloseAt(self: *Host, session: *HostSession, now_ms: i64) void {
    if (session.lifecyclePhase() != .finishing) return;
    const timing = self.session_close_timing.getPtr(session.peer_handle) orelse return;
    const deadline = switch (timing.*) {
        .deadline_ms => |deadline| deadline,
        .timed_out => return,
    };
    if (now_ms < deadline) return;
    timing.* = .timed_out;
    startSessionCancellation(self, session);
}

/// Commit a terminal owner verdict while a behavior callback may still be
/// running. The deferred work row makes `finishVerb` the only place that
/// condemns the session, breaks vows, cancels ingress, and queues effects.
fn startSessionCancellation(self: *Host, session: *HostSession) void {
    session.control.phase = .cancel_pending;
    host_pump.scheduleDeferredSessionWork(self, session.peer_handle);
}

fn noteSessionCloseDeadline(self: *Host, deadline: i64) void {
    if (self.next_session_close_deadline_ms == null or deadline < self.next_session_close_deadline_ms.?)
        self.next_session_close_deadline_ms = deadline;
}

fn nextSessionCloseDeadline(self: *const Host) ?i64 {
    return self.next_session_close_deadline_ms;
}

fn refreshSessionCloseDeadline(self: *Host) void {
    self.next_session_close_deadline_ms = null;
    var timings = self.session_close_timing.valueIterator();
    while (timings.next()) |timing| switch (timing.*) {
        .deadline_ms => |deadline| noteSessionCloseDeadline(self, deadline),
        .timed_out => {},
    };
}

fn removedDeadline(self: *Host, timing: SessionCloseTiming) void {
    const deadline = switch (timing) {
        .deadline_ms => |deadline| deadline,
        .timed_out => return,
    };
    if (self.next_session_close_deadline_ms == deadline)
        refreshSessionCloseDeadline(self);
}

/// Drop any close timing when its session shell dies, keeping the nearest
/// timer cache derived from the remaining authoritative rows.
pub fn removeSessionCloseTiming(self: *Host, peer_handle: engine.PeerHandle) void {
    const removed = self.session_close_timing.fetchRemove(peer_handle) orelse return;
    removedDeadline(self, removed.value);
}

/// Milliseconds until the nearest finite Host or session close deadline. `-1`
/// means no timer can advance close. Zero means progress is due now. Keeping
/// the selection and clamp here lets every adapter project the same close
/// policy without reconstructing it from separate observations.
pub fn closeWaitMs(self: *const Host, now_ms: i64) i64 {
    var nearest = closeDeadline(self);
    if (nextSessionCloseDeadline(self)) |deadline| {
        if (nearest == null or deadline < nearest.?) nearest = deadline;
    }
    const deadline = nearest orelse return -1;
    if (deadline <= now_ms) return 0;
    return std.math.sub(i64, deadline, now_ms) catch std.math.maxInt(i64);
}

/// Expire every finite session close whose shared deadline has arrived. The
/// nearest-deadline cache makes this O(1) on ordinary drive turns.
pub fn progressSessionCloses(self: *Host, now_ms: i64) !void {
    try self.refuseReentry();
    try progressSessionClosesAt(self, now_ms);
}

fn progressSessionClosesAt(self: *Host, now_ms: i64) !void {
    if (self.next_session_close_deadline_ms) |nearest| {
        if (now_ms >= nearest) {
            self.next_session_close_deadline_ms = null;
            var it = self.session_close_timing.iterator();
            while (it.next()) |entry| {
                const deadline = switch (entry.value_ptr.*) {
                    .deadline_ms => |deadline| deadline,
                    .timed_out => continue,
                };
                const session = self.sessions.get(entry.key_ptr.*) orelse continue;
                if (session.lifecyclePhase() != .finishing) continue;
                if (now_ms >= deadline) {
                    entry.value_ptr.* = .timed_out;
                    startSessionCancellation(self, session);
                } else {
                    noteSessionCloseDeadline(self, deadline);
                }
            }
        }
    }
    // A failed close drive leaves its work in the core-owned queues. Retry from
    // that authoritative state; adapters must not infer or recreate the missing
    // transition after OutOfMemory or backpressure.
    if (host_pump.hasInternalWork(self)) host_pump.finishVerb(self) catch |err| switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => {},
        else => sessions_mod.condemnRemainingSessions(self, "session close cleanup failed"),
    };
}

pub fn sessionCloseOutcome(
    self: *const Host,
    session: *const HostSession,
    completion_reached: bool,
) close_mod.CloseOutcome {
    if (!completion_reached or session.lifecyclePhase() != .terminating) return .pending;
    const timed_out = if (self.session_close_timing.get(session.peer_handle)) |timing|
        timing == .timed_out
    else
        false;
    return if (timed_out) .timed_out else .closed;
}

/// Whether the byte-fed terminal CLOSE action has crossed its retryable
/// delivery boundary. Transport-owning adapters use their actual wire fact
/// instead. This exists so C projection does not infer queue state.
pub fn sessionCloseActionDelivered(self: *const Host, session: *const HostSession) bool {
    if (!session.isTerminating() or session.control.close_action_pending) return false;
    if (self.retry_last_action) {
        const action = self.last_action orelse unreachable;
        if (action == .close and action.close == session.peer_handle) return false;
    }
    return true;
}

/// Enter terminal session lifecycle through one mutation authority. A normal
/// terminal path discards a live deadline. Timeout has already replaced that
/// row with its sticky result and keeps it through release.
pub fn markSessionTerminating(self: *Host, session: *HostSession) void {
    if (self.publication_lookup) |lookup| lookup.cancel(lookup.context, .{ .origin = .{ .peer = session.peer_handle } });
    if (self.session_close_timing.get(session.peer_handle)) |timing| {
        if (timing == .deadline_ms) {
            const removed = self.session_close_timing.fetchRemove(session.peer_handle) orelse unreachable;
            removedDeadline(self, removed.value);
        }
    }
    session.control.phase = .terminating;
    self.finishSessionOpen(session);
}

pub fn lifecyclePhase(self: *const Host) Host.LifecyclePhase {
    return std.meta.activeTag(self.lifecycle);
}

/// Advance close at a Host quiescence boundary. Module-visible for the pump
/// sibling. An embedder starts close and observes `lifecyclePhase`.
pub fn advanceCloseLifecycle(self: *Host) bool {
    const phase = lifecyclePhase(self);
    if (phase == .active or phase == .closed) return false;
    if (phase == .finishing) {
        const pending_flush = self.pending_flush.peek() != null;
        if (self.pending_operations != 0 or
            self.pendingVowCount() != 0 or
            self.pending_enliven_count != 0 or
            self.node.pendingDialCount() != 0 or
            self.node.pendingGiftEffects() != 0 or
            self.actions.peek() != null or
            self.retry_last_action or
            pending_flush)
        {
            return false;
        }
        startTermination(self, .graceful_shutdown, false);
    }

    @import("local_delivery.zig").cancel(self);
    var started_terminal = false;
    const terminal = &self.lifecycle.terminating;
    if (!terminal.sessions_started) {
        terminal.sessions_started = true;
        started_terminal = true;
        if (self.publication_lookup) |lookup| lookup.cancel(lookup.context, .{ .local_shutdown = "host closing" });
        enliven_mod.cancelParkedEnlivens(self, "host closing");
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |session|
            host_pump.condemnAndClose(self, session.*, terminal.abort_kind, "host closing");
    }
    const pending_flush = self.pending_flush.peek() != null;
    if (self.actions.peek() == null and
        !self.retry_last_action and
        !pending_flush and
        self.pending_enliven_count == 0 and
        self.node.pendingDialCount() == 0)
    {
        const timed_out = terminal.timed_out;
        self.lifecycle = .{ .closed = .{ .timed_out = timed_out } };
    }
    return started_terminal;
}

pub const testing = if (builtin.is_test) struct {
    pub fn startAbnormalTermination(self: *Host) void {
        startTermination(self, .other, false);
    }
} else struct {};
