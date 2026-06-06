//! Frame ownership, in miniature.
//!
//! The smallest taste of the library surface: allocate some bytes, hand them to
//! an owned `Frame`, take a borrowed `FrameView` over them, and clean up. No
//! session, no peer — just the ownership primitive everything else moves around.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const storage = try allocator.alloc(u8, 3);
    storage[0] = 0xca;
    storage[1] = 0xfe;
    storage[2] = 0x00;

    var frame = try pancake.foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
    defer frame.deinit();

    const view = frame.view();
    std.debug.print(
        "shape={s} bytes={d}\n",
        .{ @tagName(view.shape), view.bytes.len },
    );
}
