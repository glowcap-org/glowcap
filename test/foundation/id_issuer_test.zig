//! The id issuer spends an id only on commit, never issues zero or the
//! counter's last value, and reports exhaustion instead of overflowing.

const std = @import("std");
const IdIssuer = @import("glowcap").foundation.id_issuer.IdIssuer;

test "an id is spent only by its commit and the last value is never issued" {
    var ids: IdIssuer = .{};
    try std.testing.expect(ids.untouched());
    const first = ids.peek().?;
    try std.testing.expectEqual(first, ids.peek().?);
    try std.testing.expect(!ids.issued(first));
    ids.commit(first);
    try std.testing.expect(ids.issued(first));
    try std.testing.expect(!ids.issued(0));
    try std.testing.expect(!ids.untouched());

    ids.next = std.math.maxInt(u64) - 1;
    ids.commit(ids.peek().?);
    try std.testing.expectEqual(@as(?u64, null), ids.peek());
    try std.testing.expect(!ids.issued(std.math.maxInt(u64)));
}
