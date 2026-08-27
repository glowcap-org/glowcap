//! The downstream consumer's whole program: import pancake and the two
//! optional transport modules, touch the surface the README's Quick Start and
//! the Start page's tabs touch, and exit. It never opens a socket — the claim
//! under test is that the package resolves and the library compiles and links
//! for someone who fetched it, not that loopback works (the suite covers that).

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const native_relay = @import("native_relay");

pub fn main() !void {
    // Reach the types the README's first code block names, so a consumer-side
    // break in the public surface fails this build rather than their build.
    const opts: pancake.driver.SessionOptions = .{
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    };
    std.mem.doNotOptimizeAway(&opts);

    // The iroh and relay tabs on Start building import these two modules.
    const partner = iroh.locator("<64 lowercase hex characters from the server>");
    std.mem.doNotOptimizeAway(&partner);
    var relay: native_relay.Provider = undefined;
    std.mem.doNotOptimizeAway(&relay);

    const bytes = try std.heap.page_allocator.dupe(u8, "pancake");
    var frame = try pancake.foundation.Frame.initOwned(std.heap.page_allocator, bytes, .byte, .of(u8));
    defer frame.deinit();
    std.mem.doNotOptimizeAway(frame.bytes().len);
}
