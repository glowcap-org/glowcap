const std = @import("std");
const linux = std.os.linux;
const net = @import("glowcap").net;
const uring = net.uring_white_box;

test "io_uring initialization failures identify unavailable host support at their source" {
    try std.testing.expectEqual(error.IoUringSystemOutdated, uring.initFailureFor(error.SystemOutdated));
    try std.testing.expectEqual(error.IoUringInitDenied, uring.initFailureFor(error.PermissionDenied));
    try std.testing.expectEqual(error.ArgumentsInvalid, uring.initFailureFor(error.ArgumentsInvalid));
    try std.testing.expectEqual(error.SystemResources, uring.initFailureFor(error.SystemResources));
    try std.testing.expectEqual(error.OutOfMemory, uring.initFailureFor(error.OutOfMemory));

    try std.testing.expectEqual(
        error.ProvidedBufferRingUnsupported,
        uring.bufferRingFailureFor(error.ArgumentsInvalid),
    );
    try std.testing.expectEqual(error.PermissionDenied, uring.bufferRingFailureFor(error.PermissionDenied));
    try std.testing.expectEqual(error.SystemResources, uring.bufferRingFailureFor(error.SystemResources));
    try std.testing.expectEqual(error.OutOfMemory, uring.bufferRingFailureFor(error.OutOfMemory));
}

test "io_uring finite wait returns an empty turn when interrupted" {
    const noop = struct {
        fn handle(_: std.posix.SIG) callconv(.c) void {}
    }.handle;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = noop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR1, &action, &previous);
    defer std.posix.sigaction(.USR1, &previous, null);

    const target_tid = linux.gettid();
    var waiting = std.atomic.Value(bool).init(false);
    const interrupter = try std.Thread.spawn(.{}, struct {
        fn run(target: linux.pid_t, armed: *const std.atomic.Value(bool)) void {
            while (!armed.load(.acquire)) std.atomic.spinLoopHint();
            const delay: std.posix.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            std.debug.assert(linux.errno(linux.nanosleep(&delay, null)) == .SUCCESS);
            const result = linux.tgkill(linux.getpid(), target, .USR1);
            std.debug.assert(linux.errno(result) == .SUCCESS);
        }
    }.run, .{ target_tid, &waiting });
    defer interrupter.join();

    const started = net.clock.nowMonotonicMs();
    waiting.store(true, .release);
    try std.testing.expectEqual(@as(usize, 0), try uring.waitForCompletionOnce(-1, 10_000));
    try std.testing.expect(net.clock.nowMonotonicMs() - started < 5_000);
}

test "io_uring listener cancellation waits for a target already completing" {
    try std.testing.expect(uring.cancelResolved(0));
    try std.testing.expect(uring.cancelResolved(-@as(i32, @backingInt(linux.E.NOENT))));
    try std.testing.expect(!uring.cancelResolved(-@as(i32, @backingInt(linux.E.ALREADY))));
    try std.testing.expect(!uring.cancelResolved(-@as(i32, @backingInt(linux.E.INVAL))));
}

test "io_uring dialed and accepted sockets disable Nagle" {
    const enabled = uring.dialAndAcceptSetNodelay(std.testing.allocator) catch |err| {
        if (net.linux_completion_white_box.fallbackReasonFor(err) != null)
            return error.SkipZigTest;
        return err;
    };
    try std.testing.expect(enabled);
}
