//! Host-wide and per-session pump steps, including terminal cleanup progress.

const std = @import("std");

const net = @import("net");
const driver_core = @import("driver_core");

const carrier = @import("carrier.zig");
const lifecycle = @import("lifecycle.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const Budget = driver_core.Budget;
const OperationFailure = @import("../operation_failure.zig").OperationFailure;
const StepGoal = lifecycle.StepGoal;

const FlagProbe = struct {
    runtime: *HostRuntime,
    session: *driver_core.HostSession,
    flag: *const bool,

    pub fn done(self: *FlagProbe) bool {
        if (!self.flag.*) return false;
        const wire = self.runtime.wires.get(self.session.peer_handle) orelse return true;
        if (wire.closed) return true;
        return wire.link.pending == null;
    }

    pub fn resumeSkip(self: *FlagProbe) ?*driver_core.HostSession {
        _ = self;
        return null;
    }
};

/// Pump until `flag` fires under the caller's bounded wait policy.
pub fn pumpUntilFlag(self: *HostRuntime, session: *driver_core.HostSession, flag: *const bool, budget: Budget) !void {
    try self.refuseReentry();
    self.enterDriver();
    defer self.leaveDriver();
    var probe = FlagProbe{ .runtime = self, .session = session, .flag = flag };
    try Internal.pumpUntilProbe(self, &probe, budget);
}

/// One bounded pump step for a view's `stepReadable`/`serve` loops: drain
/// actions, wait up to `timeout_ms`, feed one readable wire. Reports progress
/// from `session`'s perspective.
pub fn stepSession(self: *HostRuntime, session: *driver_core.HostSession, timeout_ms: i32) !?net.Progress {
    try self.refuseReentry();
    self.enterDriver();
    defer self.leaveDriver();
    // Every wait on this face applies the mailbox first; `serve` runs this one
    // rather than `pumpUntilProbe`, and a settle must not wait for whichever
    // loop the caller happened to pick.
    try Internal.applySettleMailbox(self);
    try Internal.resumeFeedTails(self, null);
    try self.drainActions();
    try Internal.advancePendingOpens(self);
    Internal.advancePendingListeners(self);
    const session_wire = self.wires.get(session.peer_handle) orelse return .closed;
    if (session_wire.closed) return .closed;
    const index = try Internal.waitAnySource(self, timeout_ms, false) orelse return null;
    const fed = try Internal.serviceResident(self, index, session);
    try self.drainActions();
    if (session_wire.closed) return .closed;
    return if (fed > 0) .{ .received = fed } else .idle;
}

/// One host-wide pump step (ADR-0112): apply the settle mailbox, drain actions,
/// wait up to `timeout_ms` for any ready source, service it, and drain again.
/// Null means the wait ended with nothing to service. `.idle` means a source
/// was serviced without a counted frame. A resident feed reports through its
/// sinks, while a wire closure surfaces through the close observer. When work
/// remains only in userland buffers, the step posts the readiness wake so a
/// parked embedder re-enters instead of stranding it.
pub fn stepAny(self: *HostRuntime, timeout_ms: i32) !?net.Progress {
    try self.refuseReentry();
    self.enterDriver();
    defer self.leaveDriver();
    return stepAnyOwned(self, timeout_ms, .none);
}

pub fn stepAnyToward(self: *HostRuntime, timeout_ms: i32, goal: StepGoal) !?net.Progress {
    self.enterDriver();
    defer self.leaveDriver();
    return stepAnyOwned(self, timeout_ms, goal);
}

pub fn stepAnyOwned(self: *HostRuntime, timeout_ms: i32, goal: StepGoal) !?net.Progress {
    if (self.terminal_failure) |failure| {
        return stepAfterTerminalFailure(self, timeout_ms, goal, failure);
    }
    self.readTurnClock();
    defer self.turn_ms = null;
    const open_wires = self.open_wire_count;
    try Internal.progressSessionCloses(self);
    try Internal.progressClose(self, .operational);
    if (self.closeOutcome() != .pending) return null;
    try Internal.applySettleMailbox(self);
    try Internal.resumeFeedTails(self, null);
    try self.drainActions();
    try Internal.advancePendingOpens(self);
    Internal.advancePendingListeners(self);
    if (self.terminal_failure) |failure| return failure.chain.cause;
    // Immediate lifecycle work can satisfy a blocking convenience. Check its
    // barrier at the one boundary after which this step may park.
    if (goal.reached(self)) return null;
    // A carrier the prelude retired inline (a resident close that completed
    // within its verb) leaves no descriptor to wake a park; the caller
    // observes the closed session now.
    if (self.open_wire_count < open_wires) return null;
    const index = try Internal.waitAnySource(self, timeout_ms, true) orelse {
        // The park may have ended on a staged operation's clamped deadline;
        // settle it now rather than a step later.
        self.readTurnClock();
        try Internal.advancePendingOpens(self);
        Internal.advancePendingListeners(self);
        try Internal.progressSessionCloses(self);
        try Internal.progressClose(self, .operational);
        nudgeIfWorkRemains(self);
        return null;
    };
    self.readTurnClock();
    _ = try Internal.serviceResident(self, index, null);
    try self.drainActions();
    try Internal.advancePendingOpens(self);
    Internal.advancePendingListeners(self);
    try Internal.progressSessionCloses(self);
    try Internal.progressClose(self, .operational);
    if (self.terminal_failure) |failure| return failure.chain.cause;
    nudgeIfWorkRemains(self);
    return .idle;
}

/// Keep core-owned close barriers executable after a provider violates its
/// contract without making another operational call through that provider.
/// Only mailbox settles, monotonic deadlines, and release callbacks remain
/// live. The wake posted by close initiation is consumed here explicitly.
/// Leaving it unread would turn accidental busy-spinning into liveness.
pub fn stepAfterTerminalFailure(self: *HostRuntime, timeout_ms: i32, goal: StepGoal, failure: OperationFailure) !?net.Progress {
    if (!terminalCleanupPending(self)) return failure.chain.cause;
    drainReadinessWake(self);
    carrier.forceClosingCarriers(self, failure);

    try Internal.applySettleMailboxWith(self, .cleanup_only);
    try Internal.progressSessionCloses(self);
    try Internal.progressClose(self, .cleanup_only);
    if (goal.reached(self) or !terminalCleanupPending(self)) return null;

    try waitForTerminalSignal(self, timeout_ms);
    drainReadinessWake(self);
    carrier.forceClosingCarriers(self, failure);
    try Internal.applySettleMailboxWith(self, .cleanup_only);
    try Internal.progressSessionCloses(self);
    try Internal.progressClose(self, .cleanup_only);
    return null;
}

fn drainReadinessWake(self: *HostRuntime) void {
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| stepped.ready_set.drainWake() catch |err| self.noteTerminalFailure(err),
    }
}

/// Park only on sources that remain legal after provider fail-stop. Wire,
/// resident, listener, and staged-open descriptors are deliberately absent.
pub fn waitForTerminalSignal(self: *HostRuntime, timeout_ms: i32) !void {
    const timeout = Internal.clampTimeoutToPendingWork(self, timeout_ms);
    if (timeout == 0) return;

    self.extra_fd_scratch.clearRetainingCapacity();
    if (self.mailbox) |mailbox|
        try self.extra_fd_scratch.append(self.allocator, mailbox.wakeFd());
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try self.extra_fd_scratch.append(self.allocator, stepped.ready_set.wakeFd()),
    }

    if (self.extra_fd_scratch.items.len == 0) {
        const sleep_ms = if (timeout < 0) std.math.maxInt(i32) else timeout;
        try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(sleep_ms), .awake);
        return;
    }
    try self.poll_scratch.resize(self.allocator, self.extra_fd_scratch.items.len);
    _ = try net.waitAnyReadable(&.{}, self.poll_scratch.items, timeout, self.extra_fd_scratch.items);
}

pub fn terminalCleanupPending(self: *HostRuntime) bool {
    switch (self.core.lifecyclePhase()) {
        .finishing, .terminating => return true,
        .closed => return false,
        .active => {},
    }
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire| {
        if (wire.*.session.lifecyclePhase() != .active) return true;
    }
    return false;
}

/// Preserve readiness when work already left the kernel's observable buffers.
/// Only a parked embedder can be stranded by such work. The blocking face
/// re-derives its wait set on every entry.
pub fn nudgeIfWorkRemains(self: *HostRuntime) void {
    const rs = switch (self.drive) {
        .blocking => return,
        .stepped => |*stepped| &stepped.ready_set,
    };
    var release = self.deferred_session_releases;
    while (release) |request| : (release = request.next) {
        const wire = self.wires.get(request.session.peer_handle);
        if (wire == null or wire.?.carrierClosed()) {
            rs.postWake() catch |err| self.noteTerminalFailure(err);
            return;
        }
    }
    var it = self.wires.valueIterator();
    while (it.next()) |wire| {
        if (wire.*.closed) continue;
        if (wire.*.session.pausedInboundPending()) {
            rs.postWake() catch |err| self.noteTerminalFailure(err);
            return;
        }
    }
}

/// The turn is ending: every resident hands its staged sends to the kernel
/// now, in one batch per resident, and before a park its re-armed receives
/// too. A stepped turn ends before the embedder's park.
pub fn flushResidents(self: *HostRuntime, after: net.multiplexed_resident.AfterTurn) void {
    for (self.residents.items) |registered| registered.resident.beforeWait(after);
}

/// The first resident at or after `start` holding a record, or null.
pub fn readyResident(self: *HostRuntime, start: usize) ?usize {
    const residents = self.residents.items.len;
    for (0..residents) |k| {
        const index = (start + k) % residents;
        if (self.residents.items[index].resident.readyPending()) return index;
    }
    return null;
}

/// Spin for the runtime's busy-poll window, or for `timeout_ms` when that
/// is shorter: reap every resident without a submit and return the first
/// that holds a record, starting the round at `start`. The time spent comes
/// off `timeout_ms`, so the park that follows keeps the caller's bound.
pub fn spinForRecords(self: *HostRuntime, start: usize, timeout_ms: *i32) ?usize {
    const residents = self.residents.items.len;
    // Spin for a short window checking for work before asking the kernel to
    // put this thread to sleep. Waking a sleeping thread costs more than the
    // spin when a reply is expected within microseconds (ADR-0215). The spin
    // is opt-in and keeps a core busy, so it pays off only for quick replies.
    var window_ns: i64 = @intCast(@min(self.opts.busy_poll_ns, std.math.maxInt(i64)));
    if (timeout_ms.* >= 0) window_ns = @min(window_ns, @as(i64, timeout_ms.*) * std.time.ns_per_ms);
    const started = net.clock.nowMonotonicNs();
    defer if (timeout_ms.* > 0) {
        const spent_ms = @divFloor(net.clock.nowMonotonicNs() - started, std.time.ns_per_ms);
        timeout_ms.* -= @intCast(@min(spent_ms, timeout_ms.*));
    };
    while (net.clock.nowMonotonicNs() - started < window_ns) {
        for (0..residents) |k| {
            const index = (start + k) % residents;
            const resident = self.residents.items[index].resident;
            resident.reap();
            if (resident.readyPending()) return index;
        }
        std.atomic.spinLoopHint();
    }
    return null;
}

/// A resident that reaped completions inside a verb holds records no
/// descriptor reports. A stepped embedder parks on the readiness descriptor
/// next, so the runtime raises it whenever a resident holds such records as
/// the outermost verb returns. The blocking face asks the same question
/// before its own park (`waitAnySource`).
pub fn publishResidentRecords(self: *HostRuntime) void {
    const rs = switch (self.drive) {
        .blocking => return,
        .stepped => |*stepped| &stepped.ready_set,
    };
    for (self.residents.items) |registered| {
        if (!registered.resident.readyPending()) continue;
        rs.postWake() catch |err| self.noteTerminalFailure(err);
        return;
    }
}

/// The longest a nonblocking embedder may park on readiness before its
/// next zero-timeout step: milliseconds until the nearest pending-work
/// deadline (the close grace, a session's close grace, a dial or listener
/// setup budget), clamped at zero, or -1 when no finite deadline is
/// pending and readiness alone advances the loop. The blocking face applies
/// the same bound inside its own park.
pub fn stepWaitMs(self: *const HostRuntime) i32 {
    return clampTimeoutToPendingWork(self, -1);
}

/// Fold `deadline` into the nearest wait: zero once it has passed.
fn noteDeadline(nearest_wait: *?i64, deadline: i64, now_ms: i64) void {
    const wait = if (deadline <= now_ms) 0 else std.math.sub(i64, deadline, now_ms) catch std.math.maxInt(i64);
    if (nearest_wait.*) |nearest| {
        if (wait < nearest) nearest_wait.* = wait;
    } else nearest_wait.* = wait;
}

/// Bound a park by the nearest pending operation deadline, so an expiry is
/// noticed by the wait that spans it rather than the next external event.
pub fn clampTimeoutToPendingWork(self: *const HostRuntime, timeout_ms: i32) i32 {
    const now_ms = self.nowMs();
    const core_wait = self.core.closeWaitMs(now_ms);
    var nearest_wait: ?i64 = if (core_wait >= 0) core_wait else null;
    for (self.pending_opens.items) |row| {
        var deadline = row.deadline_ms;
        // A retrying dial also parks until its interval elapses. The wait
        // must wake for that due even when no handshake deadline binds.
        if (row.stage == .retry_wait) {
            const due = row.stage.retry_wait.due_ms;
            deadline = if (deadline) |bound|
                (if (bound < due) bound else due)
            else
                due;
        }
        noteDeadline(&nearest_wait, deadline orelse continue, now_ms);
    }
    if (self.nearest_carrier_close_ms) |deadline| noteDeadline(&nearest_wait, deadline, now_ms);
    for (self.pending_listeners.items) |row| noteDeadline(&nearest_wait, row.deadline_ms orelse continue, now_ms);
    const wait = nearest_wait orelse return timeout_ms;
    const remaining = std.math.cast(i32, wait) orelse std.math.maxInt(i32);
    if (timeout_ms < 0) return remaining;
    return @min(timeout_ms, remaining);
}
