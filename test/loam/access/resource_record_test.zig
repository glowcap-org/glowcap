//! the access module's first persistent record grammar has a fixed golden representation,
//! bounded decoding, and explicit ownership. This is not owner restoration.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.loam.access.core;
const Record = glowcap.loam.access.records.ResourceRecord;
const owner: core.OwnerId = @fromBackingInt(std.mem.readInt(u128, "0123456789abcdef", .big));
const sample: Record = .{
    .revision = @fromBackingInt(9),
    .resource = .{
        .id = .{ .owner = owner, .slot = 3, .generation = 4 },
        .kind = @fromBackingInt(7),
        .parent = null,
    },
};
const golden = "<15'access:resource1+9+16:0123456789abcdef3+4+7+f>";

test "access resource record uses versioned canonical Syrup with owned scalar decode" {
    const encoded = try sample.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(golden, encoded);
    try std.testing.expectEqualDeep(sample, try Record.decode(golden));
    const bytes = try std.testing.allocator.dupe(u8, encoded);
    const decoded = try Record.decode(bytes);
    @memset(bytes, 0);
    std.testing.allocator.free(bytes);
    try std.testing.expectEqualDeep(sample, decoded);
    var nested = sample;
    nested.resource.parent = .{ .owner = owner, .slot = 1, .generation = 2 };
    const parent_bytes = try nested.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(parent_bytes);
    try std.testing.expectEqualStrings("<15'access:resource1+9+16:0123456789abcdef3+4+7+[16:0123456789abcdef1+2+]>", parent_bytes);
    try std.testing.expectEqualDeep(nested, try Record.decode(parent_bytes));
}

test "access resource record rejects malformed versions lengths identities and trailing data" {
    try std.testing.expectError(error.UnsupportedVersion, Record.decode("<15'access:resource2+9+16:0123456789abcdef3+4+7+f>"));
    try std.testing.expectError(error.MalformedRecord, Record.decode("<15'access:resource01+9+16:0123456789abcdef3+4+7+f>"));
    try std.testing.expectError(error.MalformedRecord, Record.decode(golden ++ "f"));
    try std.testing.expectError(error.MalformedRecord, Record.decode("<15'access:resource1+9+184467440737095516160:>"));
    try std.testing.expectError(error.InvalidRecord, Record.decode("<15'access:resource1+9+15:0123456789abcde3+4+7+f>"));
    try std.testing.expectError(error.InvalidRecord, Record.decode("<15'access:resource1+9+16:0123456789abcdef4294967296+4+7+f>"));
    try std.testing.expectError(error.InvalidRecord, Record.decode("<15'access:resource1+9+16:0123456789abcdef3+0+7+f>"));
    try std.testing.expectError(error.MalformedRecord, Record.decode("<15'access:resource1+9+16:0123456789abcdef3+4+7+t>"));
    try std.testing.expectError(error.InvalidRecord, Record.decode("<15'access:resource1+9+16:0123456789abcdef3+4+7+[16:0123456789abcdef3+4+]>"));
    var oversized: [Record.max_encoded_bytes + 1]u8 = undefined;
    @memset(&oversized, '0');
    try std.testing.expectError(error.RecordTooLarge, Record.decode(&oversized));
    for (0..golden.len) |length| try std.testing.expectError(error.MalformedRecord, Record.decode(golden[0..length]));
}

test "access resource record bounds cover maximum scalars and encoder failure is owned" {
    var maximal = sample;
    maximal.revision = @fromBackingInt(std.math.maxInt(u64));
    maximal.resource.id.owner = @fromBackingInt(std.math.maxInt(u128));
    maximal.resource.id.slot = std.math.maxInt(u32);
    maximal.resource.id.generation = std.math.maxInt(u64);
    maximal.resource.kind = @fromBackingInt(std.math.maxInt(u64));
    maximal.resource.parent = maximal.resource.id;
    maximal.resource.parent.?.slot -= 1;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const encoded = try maximal.encodeAlloc(failing.allocator());
    defer failing.allocator().free(encoded);
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expect(encoded.len <= Record.max_encoded_bytes);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqualDeep(maximal, try Record.decode(encoded));
    try std.testing.expectError(error.OutOfMemory, sample.encodeAlloc(failing.allocator()));
    maximal.resource.parent = maximal.resource.id;
    try std.testing.expectError(error.InvalidRecord, maximal.encodeAlloc(failing.allocator()));
}
