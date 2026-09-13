//! Small `poll(2)` helpers shared by blocking net residents and readiness
//! backends. Raw OS waits stay behind one net-layer seam, so residents do not
//! each decide which wait errors are transport state.

const std = @import("std");

pub fn wait(fds: []std.posix.pollfd, timeout_ms: i32) !usize {
    return std.posix.poll(fds, timeout_ms);
}

/// Wait once, returning `SignalInterrupt` instead of restarting the full
/// timeout. A caller that owns an absolute deadline can then recompute the
/// remaining wait before trying again.
pub fn waitInterruptible(fds: []std.posix.pollfd, timeout_ms: i32) !usize {
    std.debug.assert(timeout_ms >= 0);
    const timeout: std.posix.timespec = .{
        .sec = @divTrunc(timeout_ms, 1000),
        .nsec = @as(isize, @mod(timeout_ms, 1000)) * std.time.ns_per_ms,
    };
    return std.posix.ppoll(fds, &timeout, null);
}
