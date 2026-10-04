//! Resource identity, lifecycle and child-index metadata have a canonical bounded codec.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.loam.access.core;
const Record = glowcap.loam.access.records.ResourceRecord;
const f = @import("owner_fixture.zig");
const object: f.loam.core.ObjectId = .{ .store = f.store_id, .incarnation = 1, .sequence = 1 };
const owner: core.OwnerId = @fromBackingInt(std.mem.readInt(u128, "0123456789abcdef", .big));
const sample: Record = .{
    .revision = @fromBackingInt(9),
    .resource = .{
        .id = .{ .owner = owner, .slot = 3, .generation = 4 },
        .kind = @fromBackingInt(7),
        .parent = null,
    },
};
fn decode(bytes: []const u8) !Record {
    // Scalar fixtures declare the one parent edge whenever the payload does.
    const parent = std.mem.indexOf(u8, bytes, "[") != null;
    return decodeEdges(bytes, if (parent) &.{.{ .target = object }} else &.{});
}
fn decodeEdges(payload: []const u8, edges: []const f.loam.core.Edge) !Record {
    const encoded = try (f.loam.core.Record{ .id = object, .revision = 1, .schema = f.loam.access.records.profile.resource, .payload = payload, .edges = edges }).encodeAlloc(std.testing.allocator, f.limits.records, &f.schemas);
    defer std.testing.allocator.free(encoded);
    return Record.decode(try f.loam.core.RecordView.decode(encoded, f.limits.records, &f.schemas));
}
const golden = "<15'access:resource1+9+16:0123456789abcdef3+4+7+ftf0+0+0+0+0+0+>";

test "access resource record uses versioned canonical Syrup with owned scalar decode" {
    const encoded = try sample.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(golden, encoded);
    try std.testing.expectEqualDeep(sample, try decode(golden));
    const bytes = try std.testing.allocator.dupe(u8, encoded);
    const decoded = try decode(bytes);
    @memset(bytes, 0);
    std.testing.allocator.free(bytes);
    try std.testing.expectEqualDeep(sample, decoded);
    var nested = sample;
    nested.resource.parent = .{ .owner = owner, .slot = 1, .generation = 2 };
    const parent_bytes = try nested.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(parent_bytes);
    try std.testing.expectEqualStrings("<15'access:resource1+9+16:0123456789abcdef3+4+7+[16:0123456789abcdef1+2+]tf0+0+0+0+0+0+>", parent_bytes);
    try std.testing.expectEqualDeep(nested, try decode(parent_bytes));
}

test "access resource record rejects malformed versions lengths identities and trailing data" {
    try std.testing.expectError(error.UnsupportedVersion, decode("<15'access:resource2+9+16:0123456789abcdef3+4+7+ftf0+0+0+0+0+0+>"));
    try std.testing.expectError(error.MalformedRecord, decode("<15'access:resource01+9+16:0123456789abcdef3+4+7+ftf0+0+0+0+0+0+>"));
    try std.testing.expectError(error.MalformedRecord, decode(golden ++ "f"));
    try std.testing.expectError(error.MalformedRecord, decode("<15'access:resource1+9+184467440737095516160:>"));
    try std.testing.expectError(error.InvalidRecord, decode("<15'access:resource1+9+15:0123456789abcde3+4+7+ftf0+0+0+0+0+0+>"));
    try std.testing.expectError(error.InvalidRecord, decode("<15'access:resource1+9+16:0123456789abcdef4294967296+4+7+ftf0+0+0+0+0+0+>"));
    try std.testing.expectError(error.InvalidRecord, decode("<15'access:resource1+9+16:0123456789abcdef3+0+7+ftf0+0+0+0+0+0+>"));
    try std.testing.expectError(error.MalformedRecord, decode("<15'access:resource1+9+16:0123456789abcdef3+4+7+t>"));
    try std.testing.expectError(error.InvalidRecord, decode("<15'access:resource1+9+16:0123456789abcdef3+4+7+[16:0123456789abcdef3+4+]tf0+0+0+0+0+0+>"));
    var oversized: [Record.max_encoded_bytes + 1]u8 = undefined;
    @memset(&oversized, '0');
    try std.testing.expectError(error.RecordTooLarge, decode(&oversized));
    for (0..golden.len) |length| try std.testing.expectError(error.MalformedRecord, decode(golden[0..length]));
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
    const stamp: @import("glowcap").loam.access.records.ChangeStamp = .{ .revision = std.math.maxInt(u64), .position = std.math.maxInt(u64) };
    maximal.placement = stamp;
    maximal.subtree = stamp;
    maximal.content = stamp;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const encoded = try maximal.encodeAlloc(failing.allocator());
    defer failing.allocator().free(encoded);
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expect(encoded.len <= Record.max_encoded_bytes);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqualDeep(maximal, try decode(encoded));
    try std.testing.expectError(error.OutOfMemory, sample.encodeAlloc(failing.allocator()));
    maximal.resource.parent = maximal.resource.id;
    try std.testing.expectError(error.InvalidRecord, maximal.encodeAlloc(failing.allocator()));
}

test "access resource record follows strong child custody and refuses missing weak or extra edges" {
    var nested = sample;
    nested.resource.parent = .{ .owner = owner, .slot = 1, .generation = 2 };
    var child = object;
    child.sequence = 2;
    nested.children = child;
    const bytes = try nested.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var edges: [2]f.loam.core.Edge = undefined;
    try std.testing.expectEqualDeep(nested, try decodeEdges(bytes, try nested.edges(object, &edges)));
    try std.testing.expectError(error.InvalidRecord, decodeEdges(bytes, &.{}));
    try std.testing.expectError(error.InvalidRecord, decodeEdges(bytes, edges[0..1]));
    edges[1].strength = .weak;
    try std.testing.expectError(error.InvalidRecord, decodeEdges(bytes, &edges));
    edges[1].strength = .strong;
    edges[0].strength = .weak;
    try std.testing.expectError(error.InvalidRecord, decodeEdges(bytes, &edges));
    try std.testing.expectError(error.InvalidRecord, decodeEdges(golden, edges[1..]));
    try std.testing.expectError(error.InvalidRecord, nested.edges(null, &edges));
}
