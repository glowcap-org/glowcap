const std = @import("std");
const linux = std.os.linux;
const uring = @import("pancake").net.uring_white_box;

test "io_uring listener cancellation waits for a target already completing" {
    try std.testing.expect(uring.cancelResolved(0));
    try std.testing.expect(uring.cancelResolved(-@as(i32, @intFromEnum(linux.E.NOENT))));
    try std.testing.expect(!uring.cancelResolved(-@as(i32, @intFromEnum(linux.E.ALREADY))));
    try std.testing.expect(!uring.cancelResolved(-@as(i32, @intFromEnum(linux.E.INVAL))));
}
