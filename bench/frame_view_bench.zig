const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const iterations: usize = 1_000_000;
    const payload = "pancake-frame-view-baseline";

    const storage = try allocator.dupe(u8, payload);
    var frame = try foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();

    var checksum: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const view = frame.view();
        checksum +%= view.bytes.len;
        checksum +%= @intFromPtr(view.bytes.ptr) & 0xff;
    }

    std.debug.print(
        "frame_view iterations={d} bytes={d} checksum={d}\n",
        .{ iterations, frame.bytes().len, checksum },
    );
}
