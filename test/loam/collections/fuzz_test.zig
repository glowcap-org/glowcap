//! The persistent map, driven against a plain one to see where they disagree.
//!
//! This map is a refcounted trie with structural sharing (ADR-0061). A `put`
//! rebuilds the path to the changed leaf and hands every untouched subtree to
//! the new version by bumping a count, so a node is shared by however many
//! versions still name it and freed exactly when the last one lets go. That is
//! a lot of bookkeeping to get right, and getting it wrong does not crash: it
//! frees a node another version is still reading, or never frees one at all.
//!
//! Which is why this target is worth more than a crash check. There is a
//! reference implementation sitting in the standard library, so every operation
//! has an answer to be checked against rather than merely surviving. The fuzzer
//! writes the sequence of puts, removes, and lookups. A plain hash map says what
//! the answers should be, and any disagreement is a bug in the trie.
//!
//! One property the reference cannot model, and the one the whole design exists
//! for: an old version keeps its own contents. Versions are kept alive here
//! while later ones are built on top, and each is re-checked at the end against
//! what it held when it was made. A path copy that mutates a shared subtree in
//! place would pass every check above and fail this one.
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

/// A version kept alive, and what it held when it was made.
const Kept = struct {
    map: Map,
    /// The reference's contents at that moment, so the version can be checked
    /// again later against what it should still hold.
    expected: std.AutoHashMapUnmanaged(u64, u32),
};

/// Copy what the reference holds right now, so a kept version can be checked
/// against it later.
fn snapshotReference(
    gpa: std.mem.Allocator,
    reference: *const std.AutoHashMapUnmanaged(u64, u32),
) !std.AutoHashMapUnmanaged(u64, u32) {
    var out: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    errdefer out.deinit(gpa);
    var it = reference.iterator();
    while (it.next()) |entry| try out.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
    return out;
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
        for (&kept) |*slot| {
            if (slot.*) |*k| {
                var m = k.map;
                m.deinit();
                k.expected.deinit(gpa);
            }
        }
    }

    var reference: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer reference.deinit(gpa);

    var ops: usize = 0;
    while (ops < max_ops and !smith.eos()) : (ops += 1) {
        const key = smith.valueRangeAtMost(u8, 0, key_space - 1);
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            // Write. Both sides take it, or neither does.
            op_put, 1 => {
                const value = smith.value(u32);
                const next = live.put(key, value) catch continue;
                if (live_owned) live.deinit();
                live = next;
                live_owned = true;
                try reference.put(gpa, key, value);
            },
            // Erase. Removing a key that is not there is a legitimate no-op on
            // both sides.
            op_erase => {
                const next = live.remove(key) catch continue;
                if (live_owned) live.deinit();
                live = next;
                live_owned = true;
                _ = reference.remove(key);
            },
            // Hand the current version to a slot, which keeps it alive while
            // later writes are built on top. That is what makes those writes
            // share structure instead of owning everything they touch.
            op_keep => {
                if (!live_owned) continue; // already kept; one owner only
                const slot = smith.valueRangeAtMost(u8, 0, kept_versions - 1);
                const snapshot = snapshotReference(gpa, &reference) catch continue;
                if (kept[slot]) |*old| {
                    var m = old.map;
                    m.deinit();
                    old.expected.deinit(gpa);
                }
                kept[slot] = .{ .map = live, .expected = snapshot };
                live_owned = false;
            },
            else => {},
        }

        // Every lookup answered the same way by both.
        try std.testing.expectEqual(reference.count(), live.len());
        var probe: u64 = 0;
        while (probe < key_space) : (probe += 1) {
            try std.testing.expectEqual(reference.contains(probe), live.contains(probe));
        }
    }

    // The property the reference cannot model: an old version still holds what
    // it held. A rebuild that touched a shared subtree in place passes every
    // check above and fails here.
    for (&kept) |*slot| {
        if (slot.*) |*k| {
            try std.testing.expectEqual(k.expected.count(), k.map.len());
            var it = k.expected.iterator();
            while (it.next()) |entry| {
                try std.testing.expect(k.map.contains(entry.key_ptr.*));
                try std.testing.expectEqual(entry.value_ptr.*, k.map.get(entry.key_ptr.*).?);
            }
        }
    }
}

test "fuzz: the persistent map answers like a plain one, and old versions keep their contents" {
    // Write, keep the version, write again: the shape where a later write has to
    // share structure with an earlier version rather than own what it touches.
    // Built rather than hand-counted, because the first version of this seed
    // stopped after the keep and never reached the sharing at all.
    // Each row is that step's draws in the order the loop makes them, and this
    // loop draws the key before the operation.
    const seed = corpus.program(&.{
        &.{ 0, op_put },
        &.{ 0, op_keep },
        &.{ 1, op_put },
    });

    // And it has to encode that program, not merely look like it.
    {
        var reader: std.testing.Smith = .{ .in = seed };
        for ([_]u8{ op_put, op_keep, op_put }) |want| {
            try std.testing.expect(!reader.eos());
            _ = reader.valueRangeAtMost(u8, 0, key_space - 1);
            try std.testing.expectEqual(want, reader.valueRangeAtMost(u8, 0, 3));
        }
    }

    try std.testing.fuzz({}, mapOne, .{ .corpus = &(.{seed} ++ regression_seeds) });
}
