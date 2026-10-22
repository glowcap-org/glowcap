//! One `k/n` slice of an ordered family of checks. A family that keeps growing
//! outgrows any single deadline, so CI runs it as `n` gates, each under its own
//! deadline, and adds a shard when one gate's headroom warning fires. The build
//! graph and the fuzz driver both select through this one type.

const std = @import("std");

/// The `index`th of `count` interleaved slices, both 1-based. Interleaving
/// keeps neighbors in name order, which tend to share a cost, in different
/// shards.
pub const Shard = struct {
    index: u32 = 1,
    count: u32 = 1,

    /// Parse `k/n` with `1 <= k <= n`, or return null.
    pub fn parse(text: []const u8) ?Shard {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
        const index = std.fmt.parseInt(u32, text[0..slash], 10) catch return null;
        const count = std.fmt.parseInt(u32, text[slash + 1 ..], 10) catch return null;
        if (count == 0 or index == 0 or index > count) return null;
        return .{ .index = index, .count = count };
    }

    /// Whether the item at 0-based `position` in the family belongs here.
    pub fn selects(self: Shard, position: usize) bool {
        return position % self.count == self.index - 1;
    }
};

test "a shard parses only a 1-based index within its count" {
    try std.testing.expectEqual(Shard{ .index = 2, .count = 4 }, Shard.parse("2/4").?);
    try std.testing.expect(Shard.parse("0/4") == null);
    try std.testing.expect(Shard.parse("5/4") == null);
    try std.testing.expect(Shard.parse("1/0") == null);
    try std.testing.expect(Shard.parse("1-2") == null);
    try std.testing.expect(Shard.parse("/2") == null);
}

test "the shards of a family select every item exactly once" {
    const count = 3;
    for (0..7) |position| {
        var owners: usize = 0;
        for (1..count + 1) |index| {
            if ((Shard{ .index = @intCast(index), .count = count }).selects(position)) owners += 1;
        }
        try std.testing.expectEqual(1, owners);
    }
}
