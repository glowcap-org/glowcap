//! SIGINT/SIGTERM drain for CLI services and finite product operations.
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

/// Drain a finite operation on INT/TERM. The operation owns its cleanup and
/// returns only caller-scoped data; cancellation waits for that cleanup and
/// observes the operation's actual result, including completion racing a signal.
pub fn interruptible(comptime Payload: type, io: std.Io, comptime operation: anytype, args: std.meta.ArgsTuple(@TypeOf(operation))) anyerror!Payload {
    install();
    const Event = union(enum) { finished: anyerror!Payload, stopped: std.Io.Cancelable!void };
    var buffer: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.stopped, waitForStop, .{io});
    try select.concurrent(.finished, operation, args);
    switch (try select.await()) {
        .finished => |result| return result,
        .stopped => |result| {
            try result;
            while (select.cancel()) |event| switch (event) {
                .finished => |finished| return finished,
                .stopped => {},
            };
            unreachable; // The operation publishes exactly one result.
        },
    }
}

fn waitForStop(io: std.Io) std.Io.Cancelable!void {
    while (!stopRequested()) try std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake);
}

/// Test-only: clear the stop latch so hermetic cases can re-arm.
pub fn resetForTest() void {
    g_stop.store(false, .release);
}
