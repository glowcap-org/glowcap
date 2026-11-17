//! The shared-pool receive refusal proof, parameterized by readiness backend.
//! A refused lazy buffer growth must complete the receive once with
//! `OutOfMemory` and no borrow, grow and lease nothing, and leave no armed
//! operation. Genuine saturation must still report `recv_no_buffer` without
//! allocating, and a recycle must let the waiting read finish. The epoll
//! backend runs it on Linux and the kqueue backend on macOS.

const std = @import("std");
const glowcap = @import("glowcap");
const FailingOnce = @import("failing_once.zig").FailingOnce;

const completion = glowcap.net.completion;

/// `Backend` is a white-box backend type whose `init` takes the queue depth,
/// buffer count and buffer size, and `pendingCount` counts its armed
/// operations.
pub fn expectRefusalThenSaturationRecovery(
    comptime Backend: type,
    comptime pendingCount: fn (*const Backend) usize,
) !void {
    var failing = FailingOnce.init(std.testing.allocator, std.math.maxInt(usize));
    var backend = try Backend.init(failing.allocator(), 8, 1, 64);
    defer backend.deinit();
    const first = try glowcap.net.wake_channel.WakeChannel.open();
    defer first.deinit();
    const second = try glowcap.net.wake_channel.WakeChannel.open();
    defer second.deinit();
    var completions: [2]completion.Completion = undefined;

    // Refusal: the pool's own lazy growth is the next allocation. Nothing is
    // leased or grown, and the receive ends once with the exact cause.
    try backend.submitRecv(1, first.read);
    _ = try first.nudge();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    try std.testing.expect(failing.induced);
    try std.testing.expectEqual(@as(usize, 0), backend.buffer_pool.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), backend.buffer_pool.leasedCount());
    try std.testing.expectEqual(@as(u64, 1), completions[0].user_data);
    try std.testing.expect(completions[0].result < 0);
    try std.testing.expectEqual(error.OutOfMemory, completions[0].failure.?);
    try std.testing.expect(!completions[0].recv_no_buffer);
    try std.testing.expect(!completions[0].borrowed.active());
    try std.testing.expectEqual(@as(usize, 0), pendingCount(&backend));
    try std.testing.expectEqual(@as(usize, 0), try backend.poll(&completions, 0));

    // Memory returns: the same wire reads with a grown buffer.
    failing.fail_index = std.math.maxInt(usize);
    try backend.submitRecv(2, first.read);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&completions, 1_000));
    try std.testing.expect(completions[0].borrowed.kind == .recv);
    try std.testing.expectEqual(@as(usize, 1), backend.buffer_pool.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), backend.buffer_pool.leasedCount());

    // Genuine saturation: every buffer is leased, so the receive reports
    // starvation, grows nothing, and completes after the recycle.
    try backend.submitRecv(3, second.read);
    _ = try second.nudge();
    const refused_before = failing.alloc_index;
    var starved: [1]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&starved, 1_000));
    try std.testing.expect(starved[0].recv_no_buffer);
    try std.testing.expectEqual(@as(?anyerror, null), starved[0].failure);
    try std.testing.expectEqual(@as(usize, 1), backend.buffer_pool.items.items.len);
    try std.testing.expectEqual(refused_before, failing.alloc_index);
    backend.recycleBorrowed(completions[0]);
    try backend.submitRecv(4, second.read);
    try std.testing.expectEqual(@as(usize, 1), try backend.poll(&starved, 1_000));
    try std.testing.expect(starved[0].borrowed.kind == .recv);
    backend.recycleBorrowed(starved[0]);
}
