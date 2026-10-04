//! Receipt decoding owns containers and refuses malformed inputs before effects.
//! Validated against omitted partial-container cleanup (truncation leaks and
//! allocation-failure imbalance) and acceptance of a missing record terminator.
//! This enumerates one nested value, not arbitrary wire inputs or capability
//! restoration: custody refusal is exercised separately below.
const std = @import("std");
const g = @import("glowcap");
const Codec = g.loam.access.records.ValueRecord;
const Value = g.driver.core.Value;
const Context = struct {
    pub fn id(_: *@This(), _: g.driver.core.Capability) g.loam.core.ObjectId {
        unreachable;
    }
    pub fn restore(_: *@This(), _: g.loam.core.ObjectId) !g.driver.core.Capability {
        return error.UndeclaredCapability;
    }
};

test "loam mutation receipt value decoding releases nested allocations on truncation and allocation failure" {
    const a = std.testing.allocator;
    var context: Context = .{};
    const value: Value = .{ .list = &.{ .{ .integer = -9 }, .{ .float64 = -0.0 }, .{ .boolean = true }, .{ .void = {} }, .{ .bytes = "a" }, .{ .string = "b" }, .{ .symbol = "c" }, .{ .keyword = "d" }, .{ .@"error" = .{ .message = "refused" } }, .{ .big_integer = .{ .negative = true, .digits = "123456789012345678901" } }, .{ .set = &.{.{ .integer = 2 }} }, .{ .tagged = .{ .tag = "x", .value = &.{.{ .string = "y" }} } }, .{ .@"struct" = &.{.{ .key = "z", .value = .{ .list = &.{.{ .boolean = false }} } }} } } };
    const encoded = try Codec.encode(a, value, &context);
    defer a.free(encoded);
    const decoded = try Codec.decode(Value, a, encoded, &context);
    defer Codec.free(a, decoded);
    const again = try Codec.encode(a, decoded, &context);
    defer a.free(again);
    try std.testing.expectEqualStrings(encoded, again);
    for (0..encoded.len) |length| {
        if (Codec.decode(Value, a, encoded[0..length], &context)) |partial| {
            Codec.free(a, partial);
            return error.AcceptedTruncation;
        } else |_| {}
    }
    for (0..16) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        if (Codec.decode(Value, failing.allocator(), encoded, &context)) |copy| {
            Codec.free(failing.allocator(), copy);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            return;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    return error.NoProgress;
}

test "loam mutation receipt value decoder rejects oversized counts scalar lengths and missing capability custody" {
    var context: Context = .{};
    for ([_][]const u8{ "<4'list18446744073709551615+>", "<7'integer1:x>", "<7'float641:x>", "<7'unknown>" }) |invalid| {
        try std.testing.expectError(error.InvalidRecord, Codec.decode(Value, std.testing.allocator, invalid, &context));
    }
    var id: g.loam.core.ObjectId = .{ .store = @fromBackingInt(3), .incarnation = 1, .sequence = 1 };
    const bytes = try std.fmt.allocPrint(std.testing.allocator, "<10'capability33:{s}>", .{id.key()});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.UndeclaredCapability, Codec.decode(Value, std.testing.allocator, bytes, &context));
}
