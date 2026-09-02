//! Snapshot and restore, driven against a plain record of what each snapshot
//! should hold.
//!
//! An actor's state lives in one refcounted box (ADR-0060). Taking a snapshot
//! copies no bytes at all: it bumps a count on every box, so a version is
//! shared until something writes, and a write clones the box it is about to
//! touch and leaves the shared one alone. Restoring rebuilds the live cells from
//! a snapshot's boxes.
//!
//! That is a lot of sharing to get right, and getting it wrong is quiet. A write
//! that forgets to clone corrupts a snapshot nobody has restored yet; a restore
//! that takes a box without retaining it frees state something else still names;
//! a count that never falls leaks. None of those crashes at the moment it
//! happens.
//!
//! So this keeps its own record: a plain integer per actor, and per snapshot the
//! integers as they stood when it was taken. The fuzzer writes the sequence of
//! spawns, increments, snapshots, and restores; the record says what every actor
//! should read back; and disagreement is a bug in the boxes. That covers the two
//! failure modes worth the most — a snapshot that moved when it should not have,
//! and a restore that landed somewhere other than where it was taken.
//!
//! Leaks and double frees are caught underneath by the testing allocator, which
//! is what turns a wrong refcount from a silent condition into a failure.

const std = @import("std");
const glowcap = @import("glowcap");

const actors = glowcap.actors;
const model = glowcap.ocapn.model;

/// Inputs the fuzzer found here, replayed by the ordinary suite so a bug it
/// caught cannot come back quietly. `zig build fuzz` prints what to add when it
/// finds one.
const regression_seeds = [_][]const u8{};

/// How many operations one program runs.
const max_ops = 64;
/// How many actors one program may spawn. Small, so snapshots and restores keep
/// meeting the same actors rather than a fresh one each time.
const max_actors = 4;
/// How many snapshots are held at once. More than one, because a restore has to
/// leave the others untouched.
const kept_snapshots = 3;

/// The draws that select each operation. Named so the switch and the seed
/// cannot drift apart, which is exactly how the first seed here stopped
/// describing its own program.
const op_write: u8 = 0;
const op_snapshot: u8 = 2;
const op_restore: u8 = 3;

/// Every shape and the seed builder, shared with the other targets.
const corpus = @import("../support/corpus_seeds.zig");

/// An actor that can be cloned, so it can be snapshotted.
const Counter = struct {
    n: i64,

    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "bump")) {
            self.n += 1;
            return .{ .void = {} };
        }
        return error.NoSuchMethod;
    }

    pub fn clone(self: *const Counter, allocator: std.mem.Allocator) std.mem.Allocator.Error!Counter {
        _ = allocator;
        return .{ .n = self.n };
    }
};

/// A snapshot, and what every actor held when it was taken.
const Kept = struct {
    snap: actors.Snapshot,
    expected: [max_actors]i64,
};

fn vatOne(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;

    var vat = actors.Vat.init(gpa);
    defer vat.deinit();

    // The actors exist before the program starts. Spawning them from a draw
    // meant most early operations found nothing to act on and returned, so the
    // search spent its budget getting to a vat worth attacking rather than
    // attacking one. Nothing spawns after this, so every snapshot describes the
    // same set of actors.
    var refs: [max_actors]actors.Ref = undefined;
    var expected: [max_actors]i64 = @splat(0);
    for (&refs) |*ref| ref.* = vat.spawn(Counter, .{ .n = 0 }) catch return;

    var kept: [kept_snapshots]?Kept = @splat(null);
    defer for (&kept) |*slot| {
        if (slot.*) |*k| k.snap.deinit();
    };

    var ops: usize = 0;
    while (ops < max_ops and !smith.eos()) : (ops += 1) {
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            // Write, twice as often as anything else: a mutation is what forces
            // copy-on-write, and every other operation is only interesting
            // because a mutation happened between them.
            op_write, 1 => {
                const which = smith.valueRangeAtMost(u8, 0, max_actors - 1);
                _ = vat.near(refs[which], .{ .verb = "bump" }) catch continue;
                expected[which] += 1;
            },
            // Take a snapshot, remembering what everything held.
            op_snapshot => {
                const slot = smith.valueRangeAtMost(u8, 0, kept_snapshots - 1);
                const snap = vat.snapshot() catch continue;
                if (kept[slot]) |*old| old.snap.deinit();
                kept[slot] = .{ .snap = snap, .expected = expected };
            },
            // Restore, and expect to land exactly where that snapshot was taken.
            op_restore => {
                const slot = smith.valueRangeAtMost(u8, 0, kept_snapshots - 1);
                const k = if (kept[slot]) |*k| k else continue;
                vat.restore(&k.snap) catch continue;
                expected = k.expected;
            },
            else => {},
        }

        // Every actor reads back what the record says it should. A read that
        // errors is not skipped: a restore that left a cell unreadable is
        // exactly the failure this target exists to find, and swallowing it
        // would hide the one outcome worth catching.
        for (0..max_actors) |i| {
            const got = try vat.near(refs[i], .{ .verb = "get" });
            try std.testing.expectEqual(expected[i], got.integer);
        }
    }

    // Every snapshot still describes the moment it was taken. A write that
    // failed to clone a shared box passes every check above, because the live
    // side is self-consistent; it only shows when an older snapshot is restored
    // and has moved.
    for (&kept) |*slot| {
        if (slot.*) |*k| {
            try vat.restore(&k.snap);
            for (0..max_actors) |i| {
                const got = try vat.near(refs[i], .{ .verb = "get" });
                try std.testing.expectEqual(k.expected[i], got.integer);
            }
        }
    }
}

test "fuzz: every snapshot still describes the moment it was taken" {
    // The machinery has to work before a clean run means anything. Write,
    // snapshot, write again, restore: if copy-on-write did not clone the box the
    // snapshot holds, the restore lands on the newer value and this fails.
    {
        var vat = actors.Vat.init(std.testing.allocator);
        defer vat.deinit();
        const counter = try vat.spawn(Counter, .{ .n = 0 });
        _ = try vat.near(counter, .{ .verb = "bump" });

        var snap = try vat.snapshot();
        defer snap.deinit();

        _ = try vat.near(counter, .{ .verb = "bump" });
        try std.testing.expectEqual(@as(i64, 2), (try vat.near(counter, .{ .verb = "get" })).integer);

        try vat.restore(&snap);
        try std.testing.expectEqual(@as(i64, 1), (try vat.near(counter, .{ .verb = "get" })).integer);

        // And the snapshot is reusable: a restore must not consume it.
        _ = try vat.near(counter, .{ .verb = "bump" });
        try vat.restore(&snap);
        try std.testing.expectEqual(@as(i64, 1), (try vat.near(counter, .{ .verb = "get" })).integer);
    }

    // Write, snapshot, write again, restore: the shape where a later write has
    // to clone a box a snapshot is holding. Built rather than hand-counted,
    // because the first version of this seed ran five writes and no snapshot at
    // all while its comment said otherwise.
    const seed = corpus.program(&.{
        &.{ op_write, 0 },
        &.{ op_snapshot, 0 },
        &.{ op_write, 0 },
        &.{ op_restore, 0 },
    });

    // And it has to encode that program, not merely look like it.
    {
        var reader: std.testing.Smith = .{ .in = seed };
        for ([_]u8{ op_write, op_snapshot, op_write, op_restore }) |want| {
            try std.testing.expect(!reader.eos());
            try std.testing.expectEqual(want, reader.valueRangeAtMost(u8, 0, 3));
            _ = reader.valueRangeAtMost(u8, 0, 3);
        }
    }

    try std.testing.fuzz({}, vatOne, .{ .corpus = &(.{seed} ++ regression_seeds) });
}
