//! The downstream consumer imports glowcap and, when selected, the optional
//! transport and storage modules. Touch the surface the README's Quick Start and
//! the Start page's tabs touch, and exit. It never opens a socket, the claim
//! under test is that the package resolves and the library compiles and links
//! for someone who fetched it, not that loopback works (the suite covers that).

const std = @import("std");
const glowcap = @import("glowcap");

pub fn main() !void {
    // Reach the types the README's first code block names, so a consumer-side
    // break in the public surface fails this build rather than their build.
    const opts: glowcap.driver.SessionOptions = .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    };
    std.mem.doNotOptimizeAway(&opts);

    const options = @import("options");
    if (options.optional or options.iroh or options.webrtc) @import("optional.zig").exercise();

    const bytes = try std.heap.page_allocator.dupe(u8, "glowcap");
    var frame = try glowcap.foundation.Frame.initOwned(std.heap.page_allocator, bytes, .byte, .of(u8));
    defer frame.deinit();
    std.mem.doNotOptimizeAway(frame.bytes().len);
}
