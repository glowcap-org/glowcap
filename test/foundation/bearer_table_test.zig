//! A bearer table keeps its equality whole: a candidate that shares a prefix
//! with a stored key is as unequal as one that shares nothing. The table
//! stores no secret, so every verb hashes under the word its owner passes.

const std = @import("std");
const glowcap = @import("glowcap");
const bearer_table = glowcap.foundation.bearer_table;

const stored = "glowcap-durable-1-00112233445566778899aabbccddeeff";
const secret: u64 = 7;

test "a bearer table finds the exact key and nothing near it" {
    const allocator = std.testing.allocator;
    var table: bearer_table.Table(u32) = .empty;
    defer table.deinit(allocator);
    try table.putNoClobber(secret, allocator, stored, 7);

    try std.testing.expectEqual(@as(?u32, 7), table.get(secret, stored));
    // The same length with the last byte changed.
    try std.testing.expectEqual(@as(?u32, null), table.get(secret, "glowcap-durable-1-00112233445566778899aabbccddeefe"));
    // A prefix of the key, and the key with a byte appended.
    try std.testing.expectEqual(@as(?u32, null), table.get(secret, stored[0 .. stored.len - 2]));
    try std.testing.expectEqual(@as(?u32, null), table.get(secret, stored ++ "0"));
    try std.testing.expectEqual(@as(?u32, null), table.get(secret, ""));
}

test "the bearer context agrees with plain equality on every pair" {
    const ctx = bearer_table.Context.keyed(secret);
    const keys = [_][]const u8{ "", "a", "b", "ab", "ba", "abc", "abd", "glowcap-durable-1-" };
    for (keys) |a| for (keys) |b| {
        try std.testing.expectEqual(std.mem.eql(u8, a, b), ctx.eql(a, b));
        if (ctx.eql(a, b)) try std.testing.expectEqual(ctx.hash(a), ctx.hash(b));
    };
}

test "two secrets hash the same name to different values" {
    // The hash is what keeps a peer from choosing names that share a bucket,
    // so it must follow the secret and not only the name.
    const a = bearer_table.Context.keyed(1);
    const b = bearer_table.Context.keyed(2);
    try std.testing.expect(a.hash("swissnum") != b.hash("swissnum"));
    try std.testing.expectEqual(a.hash("swissnum"), bearer_table.Context.keyed(1).hash("swissnum"));
}

test "a table adds no word to its owner" {
    // The owner holds the secret once; the table is the standard map alone.
    try std.testing.expectEqual(@sizeOf(bearer_table.Table(u32).Inner), @sizeOf(bearer_table.Table(u32)));
}
