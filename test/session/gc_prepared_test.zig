//! The prepared-commit record path allocates nothing, whatever a message
//! names. `recordSend`'s GC re-verification folds pending totals through a
//! fixed stack tier and spills to the heap past it — the right cost for a
//! caller with no proof, and exactly the arm a prepare/commit pair's commit
//! cannot answer: its reservations are spent and an allocator refusal there
//! used to land on `catch unreachable`. These cases hold both halves: the
//! prepared path touches the allocator zero times past the fold's tier, and
//! the checked path demonstrably spills on the same message.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

/// More distinct positions than the GC fold's stack tier holds, so the
/// checked path must spill and the prepared path must not care.
const positions_past_the_fold = 10;

test "a prepared gc release records without touching the allocator" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    var s = session.Session.init(counting.allocator());
    defer s.deinit();

    var positions: [positions_past_the_fold]u64 = undefined;
    var deltas: [positions_past_the_fold]u64 = undefined;
    for (&positions, &deltas, 0..) |*pos, *delta, i| {
        pos.* = 3 + i;
        delta.* = 1;
        try s.registerImport(.from(pos.*));
    }

    const before = counting.allocs;
    s.recordPreparedSend(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
    try std.testing.expectEqual(before, counting.allocs);
    for (positions) |pos| {
        try std.testing.expectEqual(@as(u64, 0), s.importRefcount(.from(pos)));
    }
}

test "the checked path spills its fold on the same message, which is its right" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    var s = session.Session.init(counting.allocator());
    defer s.deinit();

    var positions: [positions_past_the_fold]u64 = undefined;
    var deltas: [positions_past_the_fold]u64 = undefined;
    for (&positions, &deltas, 0..) |*pos, *delta, i| {
        pos.* = 3 + i;
        delta.* = 1;
        try s.registerImport(.from(pos.*));
    }

    const before = counting.allocs;
    try s.recordSend(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
    try std.testing.expect(counting.allocs > before);
}
