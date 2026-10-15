//! A bearer table keeps its equality whole: a candidate that shares a prefix
//! with a stored key is as unequal as one that shares nothing.

const std = @import("std");
const glowcap = @import("glowcap");
const bearer_table = glowcap.foundation.bearer_table;

const stored = "glowcap-durable-1-00112233445566778899aabbccddeeff";

test "a bearer table finds the exact key and nothing near it" {
    const allocator = std.testing.allocator;
    var table: bearer_table.Table(u32) = .empty;
    defer table.deinit(allocator);
    try table.putNoClobber(allocator, stored, 7);

    try std.testing.expectEqual(@as(?u32, 7), table.get(stored));
    // The same length with the last byte changed.
    try std.testing.expectEqual(@as(?u32, null), table.get("glowcap-durable-1-00112233445566778899aabbccddeefe"));
    // A prefix of the key, and the key with a byte appended.
    try std.testing.expectEqual(@as(?u32, null), table.get(stored[0 .. stored.len - 2]));
    try std.testing.expectEqual(@as(?u32, null), table.get(stored ++ "0"));
    try std.testing.expectEqual(@as(?u32, null), table.get(""));
}

test "the bearer context agrees with plain equality on every pair" {
    const ctx = bearer_table.Context{};
    const keys = [_][]const u8{ "", "a", "b", "ab", "ba", "abc", "abd", "glowcap-durable-1-" };
    for (keys) |a| for (keys) |b| {
        try std.testing.expectEqual(std.mem.eql(u8, a, b), ctx.eql(a, b));
        if (ctx.eql(a, b)) try std.testing.expectEqual(ctx.hash(a), ctx.hash(b));
    };
}
