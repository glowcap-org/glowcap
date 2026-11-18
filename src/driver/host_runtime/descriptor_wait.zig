//! The host's one descriptor wait, shared by the operational wait
//! (`pump.waitAnySource`, non-parking branch) and the terminal signal wait
//! (`step.waitForTerminalSignal`). The caller builds the rows in
//! `extra_fd_scratch` and this owns everything after: the raw poll, the pacing
//! of a temporary kernel refusal, and the precise hard result.
//!
//! A refused poll (`SystemResources`) is paced work, not a fault. The kernel
//! gives memory back as other work finishes, so the wait rests for at most the
//! caller's bound and `actions.memory_retry_ms`, then lets the caller go round
//! again. The refusal arms one due (`descriptor_refusal_due_ms`) that holds the
//! poll off as well as the rest, so a caller that returns at once, such as a
//! zero-timeout step, makes no raw descriptor poll until the due. It still
//! reads the clock and, on the stepped face, queries the ready set (`epoll_wait`
//! or `kevent`) in zero time. It serves an already-ready resident or wake
//! before resting. Every other failure is hard: it latches (`failures.latchTerminal`)
//! and returns its exact cause.

const std = @import("std");

const net = @import("net");

const actions = @import("actions.zig");
const providers = @import("providers.zig");
const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;

const Mode = enum {
    /// Rows are the residents in rotation, then the mailbox and ready wakes.
    /// Pressure may select a ready row from the ready set.
    operational,
    /// Rows are the mailbox and ready wakes alone. Pressure only rests, and
    /// the operational set is never examined.
    terminal,
};

const Result = union(enum) {
    /// The row at this index is ready, as `net.waitAnyDescriptor` reports it.
    ready: usize,
    /// The wait ran its whole bound with nothing ready.
    timeout,
    /// The kernel refused the poll and the rest ended on the refusal's due
    /// before the bound ran out, so the caller goes round again.
    paced,
};

const Error = net.WaitError || net.readiness.QueryError;

/// Members the ready set can hold at once: every resident's readiness
/// descriptor, every `watchFd` descriptor, and the two wakes
/// (`providers.wait_signal_rows`). A late mailbox is inside that bound.
fn members(residents: usize, listeners: usize) usize {
    return residents + listeners + providers.wait_signal_rows;
}

/// Reserve the stepped face's query rows before a registration that would
/// outgrow the stack buffer publishes anything to the kernel. The blocking
/// face keeps no set.
pub fn reserveQuery(self: *HostRuntime, residents: usize, listeners: usize) !void {
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try stepped.ready_query.reserve(self.allocator, members(residents, listeners)),
    }
}

/// Wait for a row of `extra_fd_scratch` to be ready, for at most `timeout_ms`
/// (negative waits forever, zero never blocks and never rests).
///
/// A due armed by a refusal stands for the kernel as well as for the rest: while
/// it is in the future the poll is not issued at all, and the wait takes the
/// cold path of selecting from the ready set (operational only) and resting to
/// the due. At or after the due the poll runs once. It clears the due on
/// success and arms the next on a fresh refusal. A positive bound, or a live
/// due, reads the runtime clock once at entry, so the deadline the bound names
/// survives a refusal, a cold query, and a rest that returns early.
pub fn wait(self: *HostRuntime, mode: Mode, timeout_ms: i32) Error!Result {
    const rows = self.extra_fd_scratch.items.len;
    if (rows == 0) return .timeout;
    // Admission reserved these rows (`providers.reserveWaitScratch`).
    std.debug.assert(rows <= self.poll_scratch.capacity);
    self.poll_scratch.items.len = rows;
    const armed_ms = self.descriptor_refusal_due_ms;
    const started_ms: i64 = if (timeout_ms > 0 or armed_ms != null) net.clock.nowMs(self.io) else 0;
    if (armed_ms) |due_ms| if (due_ms > started_ms) return cold(self, mode, timeout_ms, started_ms, due_ms);
    const ready = net.waitAnyDescriptor(self.poll_scratch.items, timeout_ms, self.extra_fd_scratch.items) catch |err| switch (err) {
        error.SystemResources => {
            const due_ms = net.clock.nowMs(self.io) +| actions.memory_retry_ms;
            self.descriptor_refusal_due_ms = due_ms;
            return cold(self, mode, timeout_ms, started_ms, due_ms);
        },
        else => |hard| return failed(self, hard),
    };
    self.descriptor_refusal_due_ms = null;
    return if (ready) |index| .{ .ready = index } else .timeout;
}

/// A hard failure ends the wait. It latches before it surfaces, so a caller
/// that drops the result still leaves the cause on the runtime. A terminal
/// wait's cause chains behind the retained primary.
fn failed(self: *HostRuntime, cause: Error) Error {
    self.noteTerminalFailure(cause);
    return cause;
}

/// The wait under a live due: no raw descriptor poll, though a stepped
/// operational wait still queries its ready set in zero time. Only a refused syscall arms a due, so a
/// persistent shortage costs one poll per interval however often the caller
/// returns, and a due that passes during the query is left for the next wait to
/// retry. Every sleep length and every verdict comes from a fresh reading
/// against the deadline `started_ms` named, never from the bound again.
fn cold(self: *HostRuntime, mode: Mode, timeout_ms: i32, started_ms: i64, due_ms: i64) Error!Result {
    if (mode == .operational) if (try selected(self)) |index| return .{ .ready = index };
    if (timeout_ms == 0) return .timeout;
    const deadline_ms: ?i64 = if (timeout_ms > 0) started_ms +| timeout_ms else null;
    const queried_ms = net.clock.nowMs(self.io);
    const until_due = due_ms - queried_ms;
    const budget = if (deadline_ms) |deadline| deadline - queried_ms else std.math.maxInt(i64);
    if (budget <= 0) return .timeout;
    if (until_due <= 0) return .paced;
    rest(self, @intCast(@min(until_due, budget, std.math.maxInt(i32))));
    const deadline = deadline_ms orelse return .paced;
    return if (net.clock.nowMs(self.io) >= deadline) .timeout else .paced;
}

/// The first row, in rows order, the ready set reports ready now: the
/// resident rotation first, then the mailbox and ready wakes. A foreign
/// `watchFd` descriptor belongs to the embedder and is never a row. Null on
/// the blocking face, which keeps no set.
fn selected(self: *HostRuntime) Error!?usize {
    const stepped = switch (self.drive) {
        .blocking => return null,
        .stepped => |*stepped| stepped,
    };
    const total = members(self.residents.items.len, self.listener_fds.items.len);
    return stepped.ready_query.firstReady(&stepped.ready_set, total, self.extra_fd_scratch.items) catch |err| failed(self, err);
}

/// Sleep `ms` with cancellation held off for exactly that long, as the poll it
/// replaces could not be cancelled. A sleep that ends early is an early
/// return, never a failure: the caller goes round again.
fn rest(self: *HostRuntime, ms: i32) void {
    if (ms <= 0) return;
    const prior = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(prior);
    std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(ms), .awake) catch |err| switch (err) {
        // tolerant: protection is blocked, so this arm is only a contract
        // violation by a custom `Io`, and an early return costs one re-poll.
        error.Canceled => {},
    };
}
