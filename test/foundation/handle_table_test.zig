//! Rows a handle names by index and generation, and the stale handle that
//! must not find a later row.

const std = @import("std");
const glowcap = @import("glowcap");
const handle_table = glowcap.foundation.handle_table;

const Handle = enum(u64) { _ };

test "an owner mints handles that find their rows and a freed handle finds nothing" {
    const allocator = std.testing.allocator;
    var table: handle_table.Owner(Handle, u32) = .empty;
    defer table.deinit(allocator);
    const a = try table.mint(allocator, 10);
    const b = try table.mint(allocator, 20);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(?u32, 10), table.get(a));
    try std.testing.expectEqual(@as(?u32, 20), table.get(b));
    try std.testing.expectEqual(@as(usize, 2), table.count());
    table.getPtr(a).?.* = 11;
    try std.testing.expectEqual(@as(?u32, 11), table.get(a));
    try std.testing.expectEqual(@as(?u32, 11), table.fetchRemove(a));
    try std.testing.expect(!table.contains(a));
    try std.testing.expect(table.get(a) == null);
    try std.testing.expect(!table.remove(a));
    try std.testing.expectEqual(@as(usize, 1), table.count());
}

test "a reused row answers only to its new handle" {
    const allocator = std.testing.allocator;
    var table: handle_table.Owner(Handle, u32) = .empty;
    defer table.deinit(allocator);
    const first = try table.mint(allocator, 1);
    try std.testing.expect(table.remove(first));
    const second = try table.mint(allocator, 2);
    // The row came back from the free chain, under the next generation.
    try std.testing.expectEqual(handle_table.index(first), handle_table.index(second));
    try std.testing.expect(handle_table.generation(first) != handle_table.generation(second));
    try std.testing.expect(first != second);
    try std.testing.expect(table.get(first) == null);
    try std.testing.expectEqual(@as(?u32, 2), table.get(second));
    try std.testing.expectEqual(@as(usize, 1), table.rowCount());
}

test "a handle no owner minted names no row" {
    const allocator = std.testing.allocator;
    var table: handle_table.Owner(Handle, u32) = .empty;
    defer table.deinit(allocator);
    _ = try table.mint(allocator, 1);
    // The zero handle carries generation zero, which no minted row has, and a
    // far index has no row at all.
    try std.testing.expect(table.get(@fromBackingInt(0)) == null);
    try std.testing.expect(table.get(@fromBackingInt(999)) == null);
    try std.testing.expect(table.get(@fromBackingInt(@as(u64, 7) << 32)) == null);
}

test "the free chain hands back the most recently freed row first" {
    const allocator = std.testing.allocator;
    var table: handle_table.Owner(Handle, u32) = .empty;
    defer table.deinit(allocator);
    const a = try table.mint(allocator, 1);
    const b = try table.mint(allocator, 2);
    const c = try table.mint(allocator, 3);
    try std.testing.expect(table.remove(a));
    try std.testing.expect(table.remove(c));
    const d = try table.mint(allocator, 4);
    try std.testing.expectEqual(handle_table.index(c), handle_table.index(d));
    const e = try table.mint(allocator, 5);
    try std.testing.expectEqual(handle_table.index(a), handle_table.index(e));
    var seen: [3]u32 = undefined;
    var n: usize = 0;
    var it = table.valueIterator();
    while (it.next()) |value| : (n += 1) seen[n] = value.*;
    try std.testing.expectEqualSlices(u32, &.{ 5, 2, 4 }, &seen);
    try std.testing.expectEqual(@as(?u32, 2), table.get(b));
}

test "a mirror places its own row under another table's handle" {
    const allocator = std.testing.allocator;
    var owner: handle_table.Owner(Handle, u32) = .empty;
    defer owner.deinit(allocator);
    var mirror: handle_table.Mirror(Handle, []const u8) = .empty;
    defer mirror.deinit(allocator);
    const a = try owner.mint(allocator, 1);
    const b = try owner.mint(allocator, 2);
    try mirror.reserve(allocator, b);
    try std.testing.expect(mirror.get(a) == null);
    mirror.placeReserved(b, "b");
    try std.testing.expectEqualStrings("b", mirror.get(b).?);
    try std.testing.expectEqual(@as(usize, 1), mirror.count());
    // The owner frees and reuses the row: the mirror's row for the old status-allow: replacement state identity
    // handle is gone and the new handle finds nothing until placed.
    try std.testing.expect(owner.remove(b));
    try std.testing.expectEqualStrings("b", mirror.fetchRemove(b).?);
    const c = try owner.mint(allocator, 3);
    try std.testing.expect(mirror.get(c) == null);
    try std.testing.expect(mirror.get(b) == null);
    try mirror.reserve(allocator, c);
    mirror.placeReserved(c, "c");
    try std.testing.expect(mirror.get(b) == null);
    try std.testing.expectEqualStrings("c", mirror.get(c).?);
    mirror.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), mirror.count());
    try std.testing.expect(mirror.get(c) == null);
}

test "a mirror reserves without allocating for a row it has seen" {
    var refusing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = refusing.allocator();
    var mirror: handle_table.Mirror(Handle, u8) = .empty;
    defer mirror.deinit(std.testing.allocator);
    const h: Handle = @fromBackingInt((@as(u64, 1) << 32) | 2);
    try mirror.reserve(allocator, h);
    try std.testing.expectEqual(@as(usize, 3), mirror.rowCount());
    mirror.placeReserved(h, 9);
    try std.testing.expect(mirror.remove(h));
    try mirror.reserve(allocator, h);
    mirror.placeReserved(h, 8);
    try std.testing.expectEqual(@as(?u8, 8), mirror.get(h));
}

test "a row whose generation wraps retires, so no handle is minted twice" {
    const allocator = std.testing.allocator;
    var table: handle_table.Owner(Handle, u32) = .empty;
    defer table.deinit(allocator);
    const first = try table.mint(allocator, 1);
    try std.testing.expect(table.remove(first));
    // Spend the row's generations: the next mint hands out the last one.
    table.rows.items[handle_table.index(first)].generation = std.math.maxInt(u32);
    const last = try table.mint(allocator, 2);
    try std.testing.expectEqual(handle_table.index(first), handle_table.index(last));
    try std.testing.expect(table.remove(last));
    // The row is spent: a mint takes a new row, and every handle the spent
    // row ever carried misses, the first one included.
    const next = try table.mint(allocator, 3);
    try std.testing.expect(handle_table.index(next) != handle_table.index(first));
    try std.testing.expect(table.get(first) == null);
    try std.testing.expect(table.get(last) == null);
    try std.testing.expectEqual(@as(?u32, 3), table.get(next));
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expectEqual(@as(usize, 2), table.rowCount());
}
