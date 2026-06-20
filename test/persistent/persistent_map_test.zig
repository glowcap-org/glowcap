//! Direct tests for the persistent immutable map (ADR-0061): structural sharing
//! across versions, refcount correctness, no cycles, and leak-freedom. The
//! testing allocator fails any test that leaks or double-frees, so a green run
//! is itself the proof that every shared node is freed exactly once.

const std = @import("std");
const persistent = @import("persistent");

const Map = persistent.PersistentMap(i64);

test "an empty map has no keys" {
    const allocator = std.testing.allocator;
    var empty = Map.init(allocator);
    defer empty.deinit();

    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expect(empty.get(1) == null);
    try std.testing.expect(!empty.contains(1));
}

test "put binds a key and get reads it back; overwrite keeps the count" {
    const allocator = std.testing.allocator;

    var prev = Map.init(allocator);
    var cur = try prev.put(7, 70);
    prev.deinit();
    prev = cur;

    cur = try prev.put(9, 90);
    prev.deinit();
    prev = cur;
    defer prev.deinit();

    try std.testing.expectEqual(@as(usize, 2), prev.len());
    try std.testing.expectEqual(@as(i64, 70), prev.get(7).?);
    try std.testing.expectEqual(@as(i64, 90), prev.get(9).?);

    // Overwriting an existing key does not change the count.
    var updated = try prev.put(7, 700);
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 2), updated.len());
    try std.testing.expectEqual(@as(i64, 700), updated.get(7).?);
    // The prior version is untouched.
    try std.testing.expectEqual(@as(i64, 70), prev.get(7).?);
}

test "old versions keep their values while a new version shares structure" {
    const allocator = std.testing.allocator;

    var v0 = Map.init(allocator);
    defer v0.deinit();
    var v1 = try v0.put(1, 10);
    defer v1.deinit();
    var v2 = try v1.put(2, 20);
    defer v2.deinit();
    var v3 = try v2.put(1, 11); // shadows key 1 in v3 only
    defer v3.deinit();

    // Each version reflects exactly the writes up to it, immutability holds
    // even though v1..v3 share interior nodes.
    try std.testing.expectEqual(@as(usize, 0), v0.len());

    try std.testing.expectEqual(@as(i64, 10), v1.get(1).?);
    try std.testing.expect(v1.get(2) == null);

    try std.testing.expectEqual(@as(i64, 10), v2.get(1).?);
    try std.testing.expectEqual(@as(i64, 20), v2.get(2).?);

    try std.testing.expectEqual(@as(i64, 11), v3.get(1).?);
    try std.testing.expectEqual(@as(i64, 20), v3.get(2).?);
}

test "keys that collide in low chunks push down and stay retrievable" {
    const allocator = std.testing.allocator;

    // All share chunk 0 (low 6 bits == 0), forcing the trie to push them to
    // deeper levels; the last two also share chunk 1, going deeper still.
    const keys = [_]u64{ 0, 1 << 6, 1 << 12, 1 << 60, (1 << 60) | (1 << 6) };

    var prev = Map.init(allocator);
    for (keys, 0..) |key, i| {
        const next = try prev.put(key, @intCast(i));
        prev.deinit();
        prev = next;
    }
    defer prev.deinit();

    try std.testing.expectEqual(@as(usize, keys.len), prev.len());
    for (keys, 0..) |key, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i)), prev.get(key).?);
    }
    // A near-miss key (differs only above the stored ones) is absent.
    try std.testing.expect(prev.get((1 << 60) | (1 << 12)) == null);
}

test "remove drops a key and keeps the rest" {
    const allocator = std.testing.allocator;

    var base = Map.init(allocator);
    {
        const a = try base.put(1, 10);
        base.deinit();
        base = a;
        const b = try base.put(2, 20);
        base.deinit();
        base = b;
        const c = try base.put(3, 30);
        base.deinit();
        base = c;
    }
    defer base.deinit();

    var without2 = try base.remove(2);
    defer without2.deinit();

    try std.testing.expectEqual(@as(usize, 2), without2.len());
    try std.testing.expect(without2.get(2) == null);
    try std.testing.expectEqual(@as(i64, 10), without2.get(1).?);
    try std.testing.expectEqual(@as(i64, 30), without2.get(3).?);

    // The base version still has all three: remove derived a new version.
    try std.testing.expectEqual(@as(usize, 3), base.len());
    try std.testing.expectEqual(@as(i64, 20), base.get(2).?);
}

test "removing an absent key yields an equivalent map sharing the root" {
    const allocator = std.testing.allocator;

    var base = Map.init(allocator);
    {
        const a = try base.put(5, 50);
        base.deinit();
        base = a;
    }
    defer base.deinit();

    var same = try base.remove(99); // absent
    defer same.deinit();

    try std.testing.expectEqual(@as(usize, 1), same.len());
    try std.testing.expectEqual(@as(i64, 50), same.get(5).?);
    // Both versions remain independently valid (no double free at deinit).
    try std.testing.expectEqual(@as(i64, 50), base.get(5).?);
}

test "removing the last key empties the map" {
    const allocator = std.testing.allocator;

    var one = Map.init(allocator);
    {
        const a = try one.put(42, 420);
        one.deinit();
        one = a;
    }
    defer one.deinit();

    var empty = try one.remove(42);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expect(empty.get(42) == null);

    // A put into the emptied version works again.
    var refilled = try empty.put(42, 99);
    defer refilled.deinit();
    try std.testing.expectEqual(@as(i64, 99), refilled.get(42).?);
}

test "a hundred coexisting versions share structure and free leak-free" {
    const allocator = std.testing.allocator;

    var versions: std.ArrayList(Map) = .empty;
    defer {
        for (versions.items) |*v| v.deinit();
        versions.deinit(allocator);
    }

    var cur = Map.init(allocator);
    try versions.append(allocator, cur);
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        cur = try cur.put(i, @intCast(i * i));
        try versions.append(allocator, cur);
    }

    // versions[k] holds keys 0..k-1.
    try std.testing.expectEqual(@as(usize, 0), versions.items[0].len());
    try std.testing.expectEqual(@as(usize, 50), versions.items[50].len());
    try std.testing.expect(versions.items[50].get(49) != null);
    try std.testing.expect(versions.items[50].get(50) == null);
    try std.testing.expectEqual(@as(usize, 100), versions.items[100].len());
    try std.testing.expectEqual(@as(i64, 99 * 99), versions.items[100].get(99).?);
}
