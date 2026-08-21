//! SIGINT/SIGTERM drain for long-running CLI fronts (`ocapn listen`, `mcp`).
//!
//! Handlers only set a flag (async-signal-safe). Long waits must poll the flag
//! (chunked sleep, `waitAcceptable`, `stepReadable`) — Zig's threaded Io retries
//! on EINTR and treats accept-after-close `BADF` as a programmer panic, so a
//! stop path must not close a listen FD another thread is blocked in `accept` on.
const std = @import("std");

/// Poll cadence for stop watches and interruptible serve/accept loops.
pub const poll_ms: i32 = 50;

var g_stop = std.atomic.Value(bool).init(false);
var g_installed = std.atomic.Value(bool).init(false);

fn handleStop(_: std.posix.SIG) callconv(.c) void {
    g_stop.store(true, .release);
}

/// Install process-wide SIGINT/SIGTERM handlers once. Idempotent.
pub fn install() void {
    if (g_installed.swap(true, .acq_rel)) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn stopRequested() bool {
    return g_stop.load(.acquire);
}

pub fn requestStop() void {
    g_stop.store(true, .release);
}

/// Test-only: clear the stop latch so hermetic cases can re-arm.
pub fn resetForTest() void {
    g_stop.store(false, .release);
}
