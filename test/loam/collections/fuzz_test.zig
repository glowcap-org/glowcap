//! The persistent map, driven against a plain one to see where they disagree.
//!
//! This map is a refcounted trie with structural sharing (ADR-0015). A `put`
//! rebuilds the path to the changed leaf and hands every untouched subtree to
//! the new version by bumping a count, so a node is shared by however many
//! versions still name it and freed exactly when the last one lets go. That is
//! a lot of bookkeeping to get right, and getting it wrong does not crash: it
//! frees a node another version is still reading, or never frees one at all.
//!
//! The fuzzer writes the sequence of puts, removes, and lookups. A plain
//! array tracks the value of each key in the bounded input space. Every new
//! map is checked against it. Older map versions are kept alive and checked
//! against a copy of the array after later writes have shared their paths.
//!
//! Leaks and double frees are caught underneath by the testing allocator, which
//! is what turns "the counts are wrong" from a silent condition into a failure.

const std = @import("std");
const persistent = @import("loam_collections");

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

/// How many operations one sequence runs.
const max_ops = 96;
/// How many versions are kept alive at once. Enough for later writes to share
/// structure with several older ones, which is when a refcount slip shows.
const kept_versions = 4;
/// Keys are drawn from a small space so puts and removes collide and a trie
/// rebuilds paths rather than only growing.
const key_space = 64;

/// The draws that select each operation. Named so the switch and the seed
/// cannot drift apart.
const op_put: u8 = 0;
const op_erase: u8 = 2;
const op_keep: u8 = 3;

/// The seed builder, shared with the other program-driven targets.
const corpus = @import("../../support/corpus_seeds.zig");

const Map = persistent.PersistentMap(u32);
const Reference = [key_space]?u32;

const Kept = struct { map: Map, expected: Reference };

fn expectVersion(map: Map, expected: *const Reference) !void {
    var count: usize = 0;
    for (expected, 0..) |value, key| {
        count += @intFromBool(value != null);
        try std.testing.expectEqual(value != null, map.contains(key));
        try std.testing.expectEqual(value, map.get(key));
    }
    try std.testing.expectEqual(count, map.len());
}

fn mapOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;

    // Exactly one owner per version. The newest is ours until a slot takes it,
    // and then the slot frees it: two owners would be a double free, and none
    // would be a leak, and the allocator underneath reports either.
    var live = Map.init(gpa);
    var live_owned = true;
    var kept: [kept_versions]?Kept = @splat(null);
    defer {
        if (live_owned) live.deinit();
        for (&kept) |*slot| if (slot.*) |*version| version.map.deinit();
    }

    var reference: Reference = @splat(null);
    var ops: usize = 0;
    while (ops < max_ops and !smith.eos()) : (ops += 1) {
        const key = smith.valueRangeAtMost(u8, 0, key_space - 1);
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            // Write. Both sides take it, or neither does.
            op_put, 1 => {
                const value = smith.value(u32);
                const next = try live.put(key, value);
                if (live_owned) live.deinit();
                live = next;
                live_owned = true;
                reference[key] = value;
            },
            // Erase. Removing a key that is not there is a legitimate no-op on
            // both sides.
            op_erase => {
                const next = try live.remove(key);
                if (live_owned) live.deinit();
                live = next;
                live_owned = true;
                reference[key] = null;
            },
            // Hand the current version to a slot, which keeps it alive while
            // later writes are built on top. That is what makes those writes
            // share structure instead of owning everything they touch.
            op_keep => {
                if (!live_owned) continue; // already kept; one owner only
                const slot = smith.valueRangeAtMost(u8, 0, kept_versions - 1);
                if (kept[slot]) |*old| old.map.deinit();
                kept[slot] = .{ .map = live, .expected = reference };
                live_owned = false;
            },
            else => {},
        }

        try expectVersion(live, &reference);
    }

    // A later write must leave every retained version as it was.
    for (&kept) |*slot| if (slot.*) |*version|
        try expectVersion(version.map, &version.expected);
}

test "fuzz: the persistent map answers like a plain one, and old versions keep their contents" {
    // Write, keep the version, then write to a different key.
    const seed = corpus.program(&.{
        &.{ 0, op_put, 17 },
        &.{ 0, op_keep, 0 },
        &.{ 1, op_put, 23 },
    });
    var reader: std.testing.Smith = .{ .in = seed };
    for ([_]u8{ 0, 0, 1 }, [_]u8{ op_put, op_keep, op_put }) |key, op| {
        try std.testing.expect(!reader.eos());
        try std.testing.expectEqual(key, reader.valueRangeAtMost(u8, 0, key_space - 1));
        try std.testing.expectEqual(op, reader.valueRangeAtMost(u8, 0, 3));
        if (op == op_keep) {
            try std.testing.expectEqual(@as(u8, 0), reader.valueRangeAtMost(u8, 0, kept_versions - 1));
        } else {
            try std.testing.expectEqual(@as(u32, if (key == 0) 17 else 23), reader.value(u32));
        }
    }

    try std.testing.fuzz({}, mapOne, .{ .corpus = &(.{seed} ++ regression_seeds) });
}
