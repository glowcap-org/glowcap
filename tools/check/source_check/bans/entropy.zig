//! Ban rows: entropy in product code comes from the caller's I/O boundary.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// A generator seeded with a constant is a generator every process shares.
/// Tests seed constants on purpose, so the scope is `src` alone.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"secret_seed_length]u8, @splat("},
        .check = "constant-entropy-seed",
        .why = "a generator seed in product code comes from `randomSecure` at the caller's I/O boundary, never a constant; model its absence as absence",
    },
};
