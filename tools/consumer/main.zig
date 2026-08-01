//! The downstream consumer's whole program: import pancake, touch the surface
//! the README's Quick Start touches, and exit. It never opens a socket — the
//! claim under test is that the package resolves and the library compiles for
//! someone who fetched it, not that loopback works (the suite covers that).

const std = @import("std");
const pancake = @import("pancake");

pub fn main() !void {
    // Reach the types the README's first code block names, so a consumer-side
    // break in the public surface fails this build rather than their build.
    const opts: pancake.driver.SessionOptions = .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    };
    std.mem.doNotOptimizeAway(&opts);

    const bytes = try std.heap.page_allocator.dupe(u8, "pancake");
    var frame = try pancake.foundation.Frame.initOwned(std.heap.page_allocator, bytes, .byte, .of(u8));
    defer frame.deinit();
    std.mem.doNotOptimizeAway(frame.bytes().len);
}
