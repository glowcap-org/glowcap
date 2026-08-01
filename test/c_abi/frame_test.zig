const std = @import("std");

const c = @import("c_abi");

test "frame shape constants use canonical byte and word terms" {
    try std.testing.expectEqual(@as(u32, 0), c.PANCAKE_FRAME_SHAPE_BYTE);
    try std.testing.expectEqual(@as(u32, 1), c.PANCAKE_FRAME_SHAPE_WORD);
}

test "managed frame release is null safe and idempotent" {
    const Callback = struct {
        var calls: usize = 0;

        fn release(frame: *c.PancakeManagedFrame) callconv(.c) void {
            calls += 1;
            frame.bytes = null;
            frame.len = 0;
            frame.shape = c.PANCAKE_FRAME_SHAPE_BYTE;
            frame.private_data = null;
        }
    };

    var bytes = [_]u8{ 9, 8, 7 };
    var managed = c.PancakeManagedFrame{
        .bytes = bytes[0..].ptr,
        .len = bytes.len,
        .shape = c.PANCAKE_FRAME_SHAPE_BYTE,
        .release = Callback.release,
        .private_data = null,
    };

    c.pancake_managed_frame_release(&managed);
    c.pancake_managed_frame_release(&managed);
    c.pancake_managed_frame_release(null);

    try std.testing.expectEqual(@as(usize, 1), Callback.calls);
    try std.testing.expectEqual(@as(?[*]u8, null), managed.bytes);
    try std.testing.expectEqual(@as(usize, 0), managed.len);
    try std.testing.expectEqual(@as(?c.ReleaseFn, null), managed.release);
}
