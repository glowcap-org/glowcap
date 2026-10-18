//! The rows a message-scoped record holds in place, and the spill past them.

const std = @import("std");
const glowcap = @import("glowcap");
const foundation = glowcap.foundation;
const inline_rows = foundation.inline_rows;
const identity_hash = foundation.identity_hash;

const Position = enum(u64) { _ };

fn position(n: u64) Position {
    return @fromBackingInt(n);
}

test "a list keeps its first rows in place and allocates nothing for them" {
    var refusing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var list: inline_rows.List(u64, 3) = .empty;
    defer list.deinit(refusing.allocator());
    try list.append(refusing.allocator(), 7);
    try list.append(refusing.allocator(), 3);
    try list.append(refusing.allocator(), 9);
    try std.testing.expectEqualSlices(u64, &.{ 7, 3, 9 }, list.items());
    // The fourth row needs the allocator, and a refusal leaves the held rows.
    try std.testing.expectError(error.OutOfMemory, list.append(refusing.allocator(), 1));
    try std.testing.expectEqualSlices(u64, &.{ 7, 3, 9 }, list.items());
    try std.testing.expectEqual(@as(usize, 3), list.count());
}

test "a list that spills keeps its order and keeps growing" {
    const allocator = std.testing.allocator;
    var list: inline_rows.List(u64, 2) = .empty;
    defer list.deinit(allocator);
    var i: u64 = 0;
    while (i < 20) : (i += 1) try list.append(allocator, i * 3);
    try std.testing.expectEqual(@as(usize, 20), list.count());
    for (list.items(), 0..) |item, index| try std.testing.expectEqual(index * 3, item);
}

test "a list reserved ahead takes its rows without the allocator" {
    const allocator = std.testing.allocator;
    var list: inline_rows.List(u64, 2) = .empty;
    defer list.deinit(allocator);
    try list.ensureUnusedCapacity(allocator, 2);
    try std.testing.expect(!list.spilled);
    list.appendAssumeCapacity(1);
    list.appendAssumeCapacity(2);
    try list.ensureUnusedCapacity(allocator, 3);
    try std.testing.expect(list.spilled);
    list.appendAssumeCapacity(3);
    list.appendAssumeCapacity(4);
    list.appendAssumeCapacity(5);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, list.items());
}

test "a table folds repeats in place and finds every row after it spills" {
    const allocator = std.testing.allocator;
    var table: inline_rows.Table(Position, u64, 3, .wire) = .keyed(identity_hash.multiplierFromSeed(0x51ab_9c0e_27d4_6f31));
    defer table.deinit(allocator);
    // Repeats fold into one row while the rows are held in place.
    const keys = [_]u64{ 5, 9, 5, 9, 5 };
    for (keys) |key| {
        const row = try table.getOrPut(allocator, position(key));
        if (!row.found_existing) row.value_ptr.* = 0;
        row.value_ptr.* += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), table.count());
    try std.testing.expectEqual(@as(u64, 3), table.getPtr(position(5)).?.*);
    try std.testing.expect(!table.spilled);
    // Two more distinct keys cross the held capacity. Rows added before and
    // after the spill are found, and a repeat still folds.
    var key: u64 = 100;
    while (key < 110) : (key += 1) {
        const row = try table.getOrPut(allocator, position(key));
        try std.testing.expect(!row.found_existing);
        row.value_ptr.* = key;
    }
    try std.testing.expect(table.spilled);
    try std.testing.expectEqual(@as(usize, 12), table.count());
    try std.testing.expectEqual(@as(u64, 2), table.getPtr(position(9)).?.*);
    try std.testing.expectEqual(@as(u64, 107), table.getPtr(position(107)).?.*);
    try std.testing.expect((try table.getOrPut(allocator, position(5))).found_existing);
    try std.testing.expect(!table.contains(position(6)));
}

test "a table's iterator visits each row once, held or spilled" {
    const allocator = std.testing.allocator;
    var table: inline_rows.Table(u64, u64, 4, .local) = .empty;
    defer table.deinit(allocator);
    var expected: u64 = 0;
    var n: u64 = 1;
    while (n <= 3) : (n += 1) {
        (try table.getOrPut(allocator, n)).value_ptr.* = n * 10;
        expected += n * 10;
    }
    var sum: u64 = 0;
    var it = table.iterator();
    while (it.next()) |entry| sum += entry.value_ptr.*;
    try std.testing.expectEqual(expected, sum);
    while (n <= 12) : (n += 1) {
        (try table.getOrPut(allocator, n)).value_ptr.* = n * 10;
        expected += n * 10;
    }
    try std.testing.expect(table.spilled);
    sum = 0;
    var seen: usize = 0;
    it = table.iterator();
    while (it.next()) |entry| {
        sum += entry.value_ptr.*;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), seen);
    try std.testing.expectEqual(expected, sum);
}

test "a table reserved ahead takes its rows without the allocator, and a refused spill keeps them" {
    var refusing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var table: inline_rows.Table(u64, void, 2, .local) = .empty;
    defer table.deinit(refusing.allocator());
    try table.ensureUnusedCapacity(refusing.allocator(), 2);
    _ = table.getOrPutAssumeCapacity(1);
    _ = table.getOrPutAssumeCapacity(2);
    try std.testing.expect(table.getOrPutAssumeCapacity(1).found_existing);
    try std.testing.expectError(error.OutOfMemory, table.ensureUnusedCapacity(refusing.allocator(), 1));
    try std.testing.expectError(error.OutOfMemory, table.getOrPut(refusing.allocator(), 3));
    try std.testing.expect(!table.spilled);
    try std.testing.expectEqual(@as(usize, 2), table.count());
    try std.testing.expect(table.contains(2));
}

/// A key of several words, shaped like a resolver purpose: an arm and two
/// positions.
const Composite = union(enum) {
    one: u64,
    two: struct { a: u64, b: u64 },

    pub fn identityWords(self: Composite) [3]u64 {
        return switch (self) {
            .one => |n| .{ 0, n, 0 },
            .two => |pair| .{ 1, pair.a, pair.b },
        };
    }
};

test "a composite key is one key exactly when its words are equal" {
    const a: Composite = .{ .two = .{ .a = 4, .b = 9 } };
    const same: Composite = .{ .two = .{ .a = 4, .b = 9 } };
    const swapped: Composite = .{ .two = .{ .a = 9, .b = 4 } };
    const other_arm: Composite = .{ .one = 4 };
    try std.testing.expect(identity_hash.eql(a, same));
    try std.testing.expect(!identity_hash.eql(a, swapped));
    try std.testing.expect(!identity_hash.eql(a, other_arm));
    try std.testing.expectEqual(identity_hash.hash(a), identity_hash.hash(same));
    try std.testing.expect(identity_hash.hash(a) != identity_hash.hash(swapped));
    try std.testing.expect(identity_hash.hash(a) != identity_hash.hash(other_arm));
    const secret = identity_hash.multiplierFromSeed(0x7a3f_19e4_c2b8_5d60);
    try std.testing.expectEqual(identity_hash.wireHash(a, secret), identity_hash.wireHash(same, secret));
    try std.testing.expect(identity_hash.wireHash(a, secret) != identity_hash.wireHash(swapped, secret));
    try std.testing.expect(identity_hash.wireHash(a, secret) != identity_hash.wireHash(a, identity_hash.default_multiplier));
    // A one-word key hashes as it always has.
    try std.testing.expectEqual(@as(u64, 42) *% identity_hash.default_multiplier, identity_hash.hash(@as(u64, 42)));
}

test "the words of a key are a key that hashes and compares as the key does" {
    const a: Composite = .{ .two = .{ .a = 4, .b = 9 } };
    const swapped: Composite = .{ .two = .{ .a = 9, .b = 4 } };
    const a_words = identity_hash.words(a);
    try std.testing.expect(identity_hash.eql(a_words, identity_hash.words(a)));
    try std.testing.expect(!identity_hash.eql(a_words, identity_hash.words(swapped)));
    try std.testing.expectEqual(identity_hash.hash(a), identity_hash.hash(a_words));
    const secret = identity_hash.multiplierFromSeed(0x7a3f_19e4_c2b8_5d60);
    try std.testing.expectEqual(identity_hash.wireHash(a, secret), identity_hash.wireHash(a_words, secret));
    // A one-word key's words are the one word it folds to.
    try std.testing.expectEqual(identity_hash.hash(@as(u64, 42)), identity_hash.hash([1]u64{42}));

    var table: identity_hash.Map(identity_hash.Words(Composite), u8) = .empty;
    defer table.deinit(std.testing.allocator);
    try table.put(std.testing.allocator, a_words, 1);
    try std.testing.expectEqual(@as(?u8, 1), table.get(identity_hash.words(a)));
    try std.testing.expect(table.get(identity_hash.words(swapped)) == null);
}

test "a composite key finds its rows in both maps" {
    const allocator = std.testing.allocator;
    var local: identity_hash.Map(Composite, u32) = .empty;
    defer local.deinit(allocator);
    var wire: identity_hash.WireMap(Composite, u32) = .keyed(identity_hash.multiplierFromSeed(0x3b9d_72e1_55a0_c8f4));
    defer wire.deinit(allocator);
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        try local.put(allocator, .{ .two = .{ .a = i, .b = i + 1 } }, @intCast(i));
        try wire.put(allocator, .{ .two = .{ .a = i, .b = i + 1 } }, @intCast(i));
        try local.put(allocator, .{ .one = i }, @intCast(1000 + i));
        try wire.put(allocator, .{ .one = i }, @intCast(1000 + i));
    }
    try std.testing.expectEqual(@as(usize, 1000), local.count());
    try std.testing.expectEqual(@as(usize, 1000), wire.count());
    try std.testing.expectEqual(@as(u32, 250), local.get(.{ .two = .{ .a = 250, .b = 251 } }).?);
    try std.testing.expectEqual(@as(u32, 1250), wire.get(.{ .one = 250 }).?);
    try std.testing.expect(local.get(.{ .two = .{ .a = 251, .b = 250 } }) == null);
    try std.testing.expect(wire.get(.{ .two = .{ .a = 251, .b = 250 } }) == null);
    try std.testing.expect(wire.remove(.{ .one = 250 }));
    try std.testing.expect(wire.get(.{ .one = 250 }) == null);
}

test "a reservation on a spilled list counts the rows the heap already holds" {
    const allocator = std.testing.allocator;
    var list: inline_rows.List(u64, 2) = .empty;
    defer list.deinit(allocator);
    try list.ensureUnusedCapacity(allocator, 3);
    try std.testing.expect(list.spilled);
    list.appendAssumeCapacity(1);
    list.appendAssumeCapacity(2);
    list.appendAssumeCapacity(3);
    // The heap is full. A second reservation reserves past its rows, not
    // past the (empty) held rows.
    try list.ensureUnusedCapacity(allocator, 1);
    list.appendAssumeCapacity(4);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, list.items());
}

test "a reservation on a spilled table counts the rows the heap already holds" {
    const allocator = std.testing.allocator;
    var table: inline_rows.Table(Position, u32, 2, .wire) = .keyed(identity_hash.multiplierFromSeed(0x51ab_9c0e_27d4_6f31));
    defer table.deinit(allocator);
    try table.ensureUnusedCapacity(allocator, 3);
    try std.testing.expect(table.spilled);
    table.getOrPutAssumeCapacity(position(1)).value_ptr.* = 1;
    table.getOrPutAssumeCapacity(position(2)).value_ptr.* = 2;
    table.getOrPutAssumeCapacity(position(3)).value_ptr.* = 3;
    try table.ensureUnusedCapacity(allocator, 1);
    table.getOrPutAssumeCapacity(position(4)).value_ptr.* = 4;
    try std.testing.expectEqual(@as(usize, 4), table.count());
    try std.testing.expectEqual(@as(u32, 4), table.getPtr(position(4)).?.*);
}

test "inline list reservation overflow preserves rows and permits retry" {
    const allocator = std.testing.allocator;
    inline for (.{ 0, 1, 2 }) |capacity| {
        var list: inline_rows.List(u64, capacity) = .empty;
        defer list.deinit(allocator);
        try list.ensureUnusedCapacity(allocator, 0);
        try list.append(allocator, 7);
        const before = list.items().ptr;
        try std.testing.expectError(error.OutOfMemory, list.ensureUnusedCapacity(allocator, std.math.maxInt(usize)));
        try std.testing.expectEqualSlices(u64, &.{7}, list.items());
        try std.testing.expectEqual(before, list.items().ptr);
        try list.ensureUnusedCapacity(allocator, 1);
        list.appendAssumeCapacity(9);
        try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, list.items());
    }
}

test "inline table oversized reservations preserve rows and permit retry" {
    const allocator = std.testing.allocator;
    inline for (.{ .local, .wire }) |provenance| {
        inline for (.{ 0, 1, 2 }) |capacity| {
            var table: inline_rows.Table(u64, u64, capacity, provenance) = if (provenance == .local) .empty else .keyed(identity_hash.default_multiplier);
            defer table.deinit(allocator);
            try table.ensureUnusedCapacity(allocator, 0);
            var it = table.iterator();
            try std.testing.expect(it.next() == null);
            try std.testing.expect(!table.contains(1));
            try std.testing.expectError(error.OutOfMemory, table.ensureUnusedCapacity(allocator, std.math.maxInt(usize)));
            try std.testing.expect(!table.spilled);
            (try table.getOrPut(allocator, 1)).value_ptr.* = 7;
            const before = table.getPtr(1).?;
            for ([_]usize{ std.math.maxInt(usize), std.math.maxInt(u32), std.math.maxInt(u32) - 1 }) |additional| {
                try std.testing.expectError(error.OutOfMemory, table.ensureUnusedCapacity(allocator, additional));
                try std.testing.expectEqual(@as(usize, 1), table.count());
                try std.testing.expectEqual(@as(u64, 7), table.getPtr(1).?.*);
                try std.testing.expectEqual(before, table.getPtr(1).?);
            }
            try table.ensureUnusedCapacity(allocator, 1);
            table.getOrPutAssumeCapacity(2).value_ptr.* = 9;
            try std.testing.expectEqual(@as(usize, 2), table.count());
            try std.testing.expectEqual(@as(u64, 9), table.getPtr(2).?.*);
            it = table.iterator();
            var sum: u64 = 0;
            while (it.next()) |entry| sum += entry.value_ptr.*;
            try std.testing.expectEqual(@as(u64, 16), sum);
        }
    }
}
