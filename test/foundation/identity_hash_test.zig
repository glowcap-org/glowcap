const std = @import("std");
const glowcap = @import("glowcap");
const foundation = glowcap.foundation;

test "identity map keeps sequential keys apart and finds them again" {
    const Position = enum(u64) { _ };
    var map: foundation.identity_hash.Map(Position, u32) = .empty;
    defer map.deinit(std.testing.allocator);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) try map.put(std.testing.allocator, @fromBackingInt(@intCast(i)), @intCast(i * 2));
    try std.testing.expectEqual(@as(usize, 1000), map.count());
    try std.testing.expectEqual(@as(u32, 1998), map.get(@fromBackingInt(@intCast(999))).?);
    try std.testing.expect(map.get(@fromBackingInt(@intCast(1000))) == null);
}

test "identity array map keeps insertion order" {
    var map: foundation.identity_hash.ArrayMap(u64, void) = .empty;
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, 7, {});
    try map.put(std.testing.allocator, 3, {});
    try std.testing.expectEqualSlices(u64, &.{ 7, 3 }, map.keys());
    try std.testing.expect(map.swapRemove(7));
    try std.testing.expect(map.get(3) != null);
}

/// Keys a peer that knows `known` would craft: the first ones whose hash
/// under it lands in slot zero of a table with `bits` index bits.
fn collidingKeys(buf: []u64, known: u64, comptime bits: u6) void {
    var candidate: u64 = 1;
    for (buf) |*key| {
        while (foundation.identity_hash.wireHash(candidate, known) & ((1 << bits) - 1) != 0) candidate += 1;
        key.* = candidate;
        candidate += 1;
    }
}

fn distinctTopBuckets(keys: []const u64, multiplier: u64, comptime bits: u6) usize {
    var seen: std.StaticBitSet(1 << bits) = .empty;
    for (keys) |key| {
        const slot: usize = @truncate(foundation.identity_hash.wireHash(key, multiplier) & ((1 << bits) - 1));
        seen.set(slot);
    }
    return seen.count();
}

test "keys that collide under a known multiplier spread under a secret one" {
    const known = foundation.identity_hash.default_multiplier;
    const secret = foundation.identity_hash.multiplierFromSeed(0x7a3f_19e4_c2b8_5d60);
    var keys: [256]u64 = undefined;
    collidingKeys(&keys, known, 8);
    try std.testing.expectEqual(@as(usize, 1), distinctTopBuckets(&keys, known, 8));
    // 256 keys into 256 slots land in about 162 distinct ones at random.
    try std.testing.expect(distinctTopBuckets(&keys, secret, 8) > 120);
}

test "sequential wire keys spread under a multiplier near a small fraction" {
    // Under the secret multiplication alone, this multiplier (near 10/13 of
    // the word) would fold sequential keys onto 1,632 of 4,096 slots.
    var keys: [4096]u64 = undefined;
    for (&keys, 0..) |*key, i| key.* = i;
    try std.testing.expect(distinctTopBuckets(&keys, foundation.identity_hash.multiplierFromSeed(0xc4e2_91b7_0d5a_3f16), 12) > 2400);
    try std.testing.expect(distinctTopBuckets(&keys, foundation.identity_hash.default_multiplier, 12) > 2400);
}

test "a wire map finds its rows under its multiplier" {
    var map: foundation.identity_hash.MapOf(.wire, u64, u32) = .keyed(foundation.identity_hash.multiplierFromSeed(0x3b9d_72e1_55a0_c8f4));
    defer map.deinit(std.testing.allocator);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) try map.put(std.testing.allocator, i * 7919, @intCast(i));
    try std.testing.expectEqual(@as(u32, 999), map.get(999 * 7919).?);
    try std.testing.expect(map.get(1) == null);
    try std.testing.expect(map.remove(0));
    try std.testing.expectEqual(@as(usize, 999), map.count());
}

test "a node keys each session's wire tables from its identity" {
    var node = glowcap.ocapn.engine.Node.init(std.testing.allocator, @as([foundation.crypto.seed_bytes]u8, @splat(0x5c)));
    defer node.deinit();
    const first = try node.registerPeer(.{});
    const second = try node.registerPeer(.{});
    const a = node.peer(first).?.session_state.wire_hash_multiplier;
    const b = node.peer(second).?.session_state.wire_hash_multiplier;
    try std.testing.expect(a != foundation.identity_hash.default_multiplier);
    try std.testing.expect(a != b);
    try std.testing.expect(a & 1 == 1 and b & 1 == 1);
    try std.testing.expectEqual(a, node.peer(first).?.session_state.imports.slots.rows.multiplier);
}

test "a host's fresh salt keys a session apart from the node's handle-only multiplier" {
    var node = glowcap.ocapn.engine.Node.init(std.testing.allocator, @as([foundation.crypto.seed_bytes]u8, @splat(0x5c)));
    defer node.deinit();
    const handle = try node.registerPeer(.{});
    const peer = node.peer(handle).?;
    const keyed_by_node = peer.session_state.wire_hash_multiplier;
    peer.reposture(.{ .wire_hash_salt = 0x1234_5678_9abc_def0 });
    const salted = peer.session_state.wire_hash_multiplier;
    try std.testing.expect(salted != keyed_by_node);
    try std.testing.expect(salted & 1 == 1);
    try std.testing.expectEqual(salted, peer.session_state.imports.slots.rows.multiplier);
    try std.testing.expectEqual(salted, foundation.identity_hash.saltedMultiplier(keyed_by_node, 0x1234_5678_9abc_def0));
    // Another salt over the same registration is another secret.
    try std.testing.expect(foundation.identity_hash.saltedMultiplier(keyed_by_node, 1) != salted);
}
