//! Deterministic `driver_core.Host` construction for sans-I/O tests.
//!
//! Production embedders must draw a fresh session root at their entropy
//! boundary. Tests need repeatability instead, so this helper derives a root
//! in a separate domain from the fixture's durable seed.

const std = @import("std");
const pancake = @import("pancake");

const Host = pancake.driver.core.Host;
const crypto = pancake.foundation.crypto;

pub fn init(
    allocator: std.mem.Allocator,
    durable_seed: [crypto.SEED_BYTES]u8,
    options: Host.Options,
) Host {
    var root: [crypto.SEED_BYTES]u8 = undefined;
    var hasher = std.crypto.hash.Blake3.initKdf("pancake deterministic test session root v1", .{});
    hasher.update(&durable_seed);
    hasher.final(&root);
    return Host.init(allocator, durable_seed, root, options) catch unreachable;
}

pub fn initWithRoot(
    allocator: std.mem.Allocator,
    durable_seed: [crypto.SEED_BYTES]u8,
    session_seed_root: [crypto.SEED_BYTES]u8,
    options: Host.Options,
) Host {
    return Host.init(allocator, durable_seed, session_seed_root, options) catch unreachable;
}
