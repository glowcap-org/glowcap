//! Compare the Bend model's bound decisions with the public policy operations.
const std = @import("std");
const Policy = @import("policy").Policy;

test "ordered policy bounds agree with Bend for every comparison" {
    const max = std.math.maxInt(u64);
    // Both open, open parent, two open child cases, then less, equal, greater.
    const cases = [_][2]?u64{ .{ null, null }, .{ max, null }, .{ null, 0 }, .{ null, max }, .{ 0, max }, .{ max, max }, .{ max, 0 } };
    const read: Policy.Key = @fromBackingInt(1);
    const fields = [_]Policy.Constraint{
        .{ .key = @fromBackingInt(10), .operator = .lower_bound },
        .{ .key = @fromBackingInt(20), .operator = .upper_bound },
    };
    try std.testing.expectEqual(std.enums.values(Policy.Operator).len, fields.len);
    const policy = try Policy.init(.{ .id = @fromBackingInt(1), .permissions = &.{read}, .constraints = &fields });
    const unrestricted = try policy.value(&.{read}, &.{});
    var row: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer row.deinit();
    for (fields, 0..) |field, slot| {
        try row.writer.writeAll(@tagName(field.operator));
        for (cases) |pair| {
            const left, const right = pair;
            var child = unrestricted;
            var parent = unrestricted;
            child.setBound(slot, left);
            parent.setBound(slot, right);
            const fits = try policy.isSubsetOf(child, parent);
            const meet = (try policy.intersect(child, parent)).bound(slot);
            try std.testing.expect(meet == left or meet == right);
            const facts: []const Policy.Bound = if (left) |value| &.{.{ .key = field.key, .value = value }} else &.{};
            const admitted = try policy.allows(parent, .{ .permissions = &.{read}, .facts = facts });
            try row.writer.print(" {d}{d}{d}", .{ @intFromBool(fits), @intFromBool(meet == left), @intFromBool(admitted) });
        }
        try row.writer.writeByte('\n');
    }
    try std.testing.expectEqualStrings(@embedFile("bend_table"), row.written());
}
