//! The dense slab behind the session's own-side tables: a freed position is
//! the next one minted, an abandoned reservation returns, a withheld position
//! never comes back, and an explicit index threads the slots below it free.

const std = @import("std");
const glowcap = @import("glowcap");

const Slab = glowcap.ocapn.session.PositionSlab(u64);

test "a released slot is minted again before the vector grows" {
    const allocator = std.testing.allocator;
    var slab: Slab = .empty;
    defer slab.deinit(allocator);

    const first = try slab.reserve(allocator, 1);
    slab.install(first, 10);
    const second = try slab.reserve(allocator, 2);
    slab.install(second, 20);
    try std.testing.expectEqual(@as(u32, 0), first);
    try std.testing.expectEqual(@as(u32, 1), second);
    try std.testing.expectEqual(@as(usize, 2), slab.len());

    slab.remove(first);
    try std.testing.expectEqual(@as(usize, 1), slab.len());
    try std.testing.expectEqual(@as(usize, 2), slab.capacityUsed());
    try std.testing.expect(!slab.contains(first));
    try std.testing.expectEqual(first, slab.nextIndex());

    const third = try slab.reserve(allocator, 3);
    try std.testing.expectEqual(first, third);
    try std.testing.expectEqual(@as(?u64, 3), slab.reservedStamp(third));
    try std.testing.expect(!slab.contains(third));
    slab.install(third, 30);
    try std.testing.expectEqual(@as(u64, 30), slab.getPtr(third).?.*);
    try std.testing.expectEqual(@as(?u64, null), slab.reservedStamp(third));
    try std.testing.expectEqual(@as(u32, 2), slab.nextIndex());
}

test "the free list hands out the last released slot first" {
    const allocator = std.testing.allocator;
    var slab: Slab = .empty;
    defer slab.deinit(allocator);
    for (0..3) |n| slab.install(try slab.reserve(allocator, n), n);

    slab.remove(0);
    slab.remove(2);
    try std.testing.expectEqual(@as(u32, 2), try slab.reserve(allocator, 9));
    try std.testing.expectEqual(@as(u32, 0), try slab.reserve(allocator, 9));
    try std.testing.expectEqual(@as(u32, 3), try slab.reserve(allocator, 9));
    try std.testing.expectEqual(@as(usize, 4), slab.capacityUsed());
}

test "an abandoned reservation returns its slot without a row" {
    const allocator = std.testing.allocator;
    var slab: Slab = .empty;
    defer slab.deinit(allocator);

    const minted = try slab.reserve(allocator, 7);
    try std.testing.expectEqual(@as(?u64, 7), slab.reservedStamp(minted));
    slab.abandon(minted);
    try std.testing.expectEqual(@as(?u64, null), slab.reservedStamp(minted));
    try std.testing.expectEqual(@as(usize, 0), slab.len());
    try std.testing.expectEqual(minted, slab.nextIndex());
    try std.testing.expectEqual(minted, try slab.reserve(allocator, 8));
}

test "a withheld slot is never minted again" {
    const allocator = std.testing.allocator;
    var slab: Slab = .empty;
    defer slab.deinit(allocator);
    slab.install(try slab.reserve(allocator, 1), 10);
    slab.install(try slab.reserve(allocator, 2), 20);

    slab.withhold(0);
    try std.testing.expectEqual(@as(usize, 1), slab.len());
    try std.testing.expect(!slab.contains(0));
    try std.testing.expect(!slab.installable(0));
    try std.testing.expectEqual(@as(u32, 2), slab.nextIndex());

    slab.remove(1);
    try std.testing.expectEqual(@as(u32, 1), try slab.reserve(allocator, 3));
    try std.testing.expectEqual(@as(u32, 2), try slab.reserve(allocator, 4));
    try std.testing.expect(!slab.contains(0));
}

test "growing to an explicit index threads the slots below it free" {
    const allocator = std.testing.allocator;
    var slab: Slab = .empty;
    defer slab.deinit(allocator);

    try slab.installAt(allocator, 4, 40);
    try std.testing.expectEqual(@as(usize, 5), slab.capacityUsed());
    try std.testing.expectEqual(@as(usize, 1), slab.len());
    try std.testing.expect(slab.installable(2));

    // The grown slots are free, most recently threaded first, and the vector
    // grows only once they are spent.
    try std.testing.expectEqual(@as(u32, 3), try slab.reserve(allocator, 1));
    try std.testing.expectEqual(@as(u32, 2), try slab.reserve(allocator, 1));
    try std.testing.expectEqual(@as(u32, 1), try slab.reserve(allocator, 1));
    try std.testing.expectEqual(@as(u32, 0), try slab.reserve(allocator, 1));
    try std.testing.expectEqual(@as(u32, 5), try slab.reserve(allocator, 1));
}

test "the iterator visits live rows in index order and nothing else" {
    const allocator = std.testing.allocator;
    var slab: Slab = .empty;
    defer slab.deinit(allocator);
    for (0..5) |n| slab.install(try slab.reserve(allocator, n), n * 10);
    slab.remove(1);
    slab.withhold(2);
    _ = try slab.reserve(allocator, 9); // index 1, reserved and not yet live status-allow: pending state or quoted runtime label

    var it = slab.iterator();
    const first = it.next().?;
    try std.testing.expectEqual(@as(u32, 0), first.index);
    try std.testing.expectEqual(@as(u64, 0), first.row.*);
    const second = it.next().?;
    try std.testing.expectEqual(@as(u32, 3), second.index);
    try std.testing.expectEqual(@as(u64, 30), second.row.*);
    const third = it.next().?;
    try std.testing.expectEqual(@as(u32, 4), third.index);
    try std.testing.expect(it.next() == null);
}
