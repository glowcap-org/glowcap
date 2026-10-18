//! Persistent grants retain exact terms. Allocation, shape, and event grammar
//! are bounded independently of current graph and policy interpretation.
const std = @import("std");
const access = @import("glowcap").loam.access;
const core = access.core;
const Record = access.records.GrantRecord;
const a = std.testing.allocator;
const wide = "0123456789abcdef";
const owner: core.OwnerId = @fromBackingInt(std.mem.readInt(u128, wide, .big));
const resource: core.ResourceId = .{ .owner = owner, .slot = 3, .generation = 1 };
const terms: core.Terms = .{ .scope = .{ .object = resource }, .policy = .{
    .schema = @fromBackingInt(std.mem.readInt(u128, wide, .big)),
    .permissions = 1,
} };
const sample: Record = .{ .grant = .{
    .id = .{ .owner = owner, .slot = 0, .generation = 1 },
    .revision = @fromBackingInt(2),
    .parent = null,
    .ceiling = terms,
    .configured = terms,
    .status = .active,
    .delegation_depth = 2,
    .child_count = 0,
} };
const term_bytes = "[[6'object16:0123456789abcdef3+1+]16:0123456789abcdef1+[ffffffffffffffff]]";
const golden = "<12'access:grant2+16:0123456789abcdef0+1+2+f" ++ term_bytes ++ term_bytes ++ "6'active2+0+0:0+0+0+0+0+0+f>";

test "access grant record canonical scalar grammar has no decode allocations" {
    var scratch: Record = undefined;
    const encoded = try sample.encodeAlloc(a);
    defer a.free(encoded);
    try std.testing.expectEqualStrings(golden, encoded);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var decoded: Record = undefined;
    try decoded.decodeOwned(failing.allocator(), encoded);
    defer decoded.deinit(failing.allocator());
    try std.testing.expectEqualDeep(sample, decoded);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    for (0..golden.len) |length| {
        try std.testing.expectError(error.MalformedRecord, scratch.decodeOwned(a, golden[0..length]));
    }
    try std.testing.expectError(error.MalformedRecord, scratch.decodeOwned(a, golden ++ "f"));
    try std.testing.expectError(error.UnsupportedVersion, scratch.decodeOwned(a, "<12'access:grant1+>"));
    try std.testing.expectError(error.MalformedRecord, scratch.decodeOwned(a, "<12'access:grant01+>"));
    var oversized: [Record.max_encoded_bytes + 1]u8 = undefined;
    @memset(&oversized, 0);
    try std.testing.expectError(error.RecordTooLarge, scratch.decodeOwned(a, &oversized));
}

fn selectedRoundTrip(allocator: std.mem.Allocator) !void {
    var selected = sample;
    selected.grant.ceiling.scope = .{ .objects = &.{resource} };
    selected.grant.configured.scope = .{ .objects = &.{resource} };
    const encoded = try selected.encodeAlloc(allocator);
    defer allocator.free(encoded);
    var decoded: Record = undefined;
    try decoded.decodeOwned(allocator, encoded);
    defer decoded.deinit(allocator);
    @memset(encoded, 0);
    try std.testing.expectEqualDeep(selected, decoded);
}

test "access grant selected scopes own exact copies and unwind every allocation failure" {
    var scratch: Record = undefined;
    try std.testing.checkAllAllocationFailures(a, selectedRoundTrip, .{});
    var selected = sample;
    selected.grant.ceiling.scope = .{ .objects = &.{resource} };
    selected.grant.configured.scope = .{ .objects = &.{resource} };
    const encoded = try selected.encodeAlloc(a);
    defer a.free(encoded);
    for (0..encoded.len) |length| {
        try std.testing.expectError(error.MalformedRecord, scratch.decodeOwned(a, encoded[0..length]));
    }
    var failing = std.testing.FailingAllocator.init(a, .{});
    var decoded: Record = undefined;
    try decoded.decodeOwned(failing.allocator(), encoded);
    defer decoded.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(core.ResourceId)), failing.allocated_bytes);
}

test "access grant record rejects oversized duplicate foreign and invalid structural fields" {
    var scratch: Record = undefined;
    var invalid = sample;
    invalid.grant.parent = invalid.grant.id;
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
    invalid = sample;
    invalid.grant.configured.scope = .{ .objects = &.{ resource, resource } };
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
    invalid = sample;
    invalid.grant.configured.scope.object.owner = @fromBackingInt(99);
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
    invalid = sample;
    invalid.grant.ceiling.policy.schema = @fromBackingInt(99);
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
    try std.testing.expectError(error.InvalidRecord, scratch.decodeOwned(a, "<12'access:grant2+16:0123456789abcdef0+1+2+f[[7'objects257+"));
    try std.testing.expectError(error.InvalidRecord, scratch.decodeOwned(a, "<12'access:grant2+16:0123456789abcdef0+0+"));
    const bad_selection = "[[7'objects2+16:0123456789abcdef3+1+16:0123456789abcdef3+1+]16:0123456789abcdef1+[ffffffffffffffff]]";
    try std.testing.expectError(error.InvalidRecord, scratch.decodeOwned(a, "<12'access:grant2+16:0123456789abcdef0+1+2+f" ++ bad_selection));
}

test "access grant maximum selections and integers fit the encoded bound" {
    var ids: [core.max_scope_objects]core.ResourceId = undefined;
    for (&ids, 0..) |*id, i| id.* = .{ .owner = @fromBackingInt(std.math.maxInt(u128)), .slot = std.math.maxInt(u32) - @as(u32, @intCast(ids.len - i)), .generation = std.math.maxInt(u64) };
    var maximal = sample;
    maximal.grant.id.owner = ids[0].owner;
    maximal.grant.id.slot = std.math.maxInt(u32);
    maximal.grant.id.generation = std.math.maxInt(u64);
    maximal.grant.parent = maximal.grant.id;
    maximal.grant.parent.?.slot -= 1;
    maximal.grant.ceiling.scope = .{ .objects = &ids };
    maximal.grant.ceiling.policy.permissions = std.math.maxInt(u64);
    maximal.grant.ceiling.policy.bounds = @splat(std.math.maxInt(u64));
    maximal.grant.ceiling.policy.bound_mask = std.math.maxInt(u16);
    maximal.grant.configured = maximal.grant.ceiling;
    maximal.grant.revision = @fromBackingInt(std.math.maxInt(u64));
    maximal.grant.delegation_depth = std.math.maxInt(u16);
    maximal.grant.child_count = std.math.maxInt(u32);
    const encoded = try maximal.encodeAlloc(a);
    defer a.free(encoded);
    try std.testing.expect(encoded.len <= Record.max_encoded_bytes);
    var decoded: Record = undefined;
    try decoded.decodeOwned(a, encoded);
    defer decoded.deinit(a);
    try std.testing.expectEqualDeep(maximal, decoded);
    maximal.grant.configured.scope = .{ .owned_subtree = ids[0] };
    const subtree = try maximal.encodeAlloc(a);
    defer a.free(subtree);
    var other: Record = undefined;
    try other.decodeOwned(a, subtree);
    defer other.deinit(a);
    try std.testing.expectEqualDeep(maximal, other);
}
