//! Compare the Bend model's bound decisions with the public policy operations.
const std = @import("std");
const Policy = @import("policy").Policy;

test "ordered policy bounds agree with Bend for every comparison" {
    const max = std.math.maxInt(u64);
    // Both open, open parent, open child, then child less, equal, greater.
    const cases = [_][2]?u64{ .{ null, null }, .{ max, null }, .{ null, 0 }, .{ 0, max }, .{ max, max }, .{ max, 0 } };
    var row: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer row.deinit();
    for (std.enums.values(Policy.Operator)) |op| {
        const policy = try Policy.init(.{
            .id = @fromBackingInt(1),
            .permissions = &.{},
            .constraints = &.{.{ .key = @fromBackingInt(1), .operator = op }},
        });
        try row.writer.writeAll(@tagName(op));
        for (cases) |pair| {
            const left, const right = pair;
            var child: Policy.Value = .{ .schema = policy.id, .permissions = 0 };
            var parent = child;
            child.setBound(0, left);
            parent.setBound(0, right);
            const fits = try policy.isSubsetOf(child, parent);
            const meet = (try policy.intersect(child, parent)).bound(0);
            try std.testing.expect(meet == left or meet == right);
            try row.writer.print(" {d}{d}", .{ @intFromBool(fits), @intFromBool(meet == left) });
        }
        try row.writer.writeByte('\n');
    }
    try std.testing.expectEqualStrings(@embedFile("bend_table"), row.written());
}
