//! Owner vocabularies and sparse directory pages have bounded scalar decoding.
const std = @import("std");
const f = @import("owner_fixture.zig");
const records = f.loam.access.records;
const Page = records.DirectoryPage;
const a = std.testing.allocator;
const object: f.loam.core.ObjectId = .{ .store = f.store_id, .incarnation = 1, .sequence = 1 };

fn encode(schema: u64, payload: []const u8, edges: []const f.loam.core.Edge) ![]u8 {
    const record: f.loam.core.Record = .{ .id = object, .revision = 1, .schema = schema, .payload = payload, .edges = edges };
    return record.encodeAlloc(a, f.limits.records, &f.schemas);
}

fn view(bytes: []const u8) !f.loam.core.RecordView {
    return f.loam.core.RecordView.decode(bytes, f.limits.records, &f.schemas);
}

test "access owner dependencies round trip within the maximum descriptor budget" {
    var keys: [64]f.core.Policy.Key = undefined;
    var constraints: [16]f.core.Policy.Constraint = undefined;
    for (&keys, 0..) |*key, i| key.* = @fromBackingInt(std.math.maxInt(u64) - 63 + i);
    for (&constraints, 0..) |*field, i| field.* = .{ .key = @fromBackingInt(std.math.maxInt(u64) - 15 + i), .operator = .lower_bound };
    const vocabulary = try f.core.Policy.init(.{ .id = @fromBackingInt(std.math.maxInt(u128)), .permissions = &keys, .constraints = &constraints });
    var masks: [64]u64 = undefined;
    for (&masks, 0..) |*mask, i| mask.* = std.math.maxInt(u64) ^ (@as(u64, 1) << @intCast(i));
    const header: records.OwnerRecord = .{ .owner = @fromBackingInt(std.math.maxInt(u128)), .policy = try vocabulary.withPrerequisiteMasks(masks), .version = .{ .resources = @fromBackingInt(std.math.maxInt(u64)), .grants = @fromBackingInt(std.math.maxInt(u64)) }, .control_revision = std.math.maxInt(u64), .next_resource = records.OwnerRecord.max_slots, .next_grant = records.OwnerRecord.max_slots, .next_identity = records.OwnerRecord.max_slots, .max_grant_children = std.math.maxInt(u32) };
    const payload = try header.encodeAlloc(a);
    defer a.free(payload);
    try std.testing.expect(payload.len <= 4096);
    const encoded = try encode(records.profile.owner, payload, &.{});
    defer a.free(encoded);
    const decoded = try records.OwnerRecord.decode(try view(encoded));
    try std.testing.expectEqual(masks, decoded.policy.prerequisite_masks);
    try std.testing.expectError(error.MissingPrerequisite, decoded.policy.value(keys[0..1], &.{}));
    const all = try decoded.policy.value(&keys, &.{});
    try std.testing.expect(try decoded.policy.allows(all, .{ .permissions = keys[63..] }));
}

test "access owner refuses the prerelease vocabulary encoding without a dependency list" {
    const policy = try f.core.Policy.init(.{ .id = @fromBackingInt(1), .permissions = &.{} });
    const payload = try (records.OwnerRecord{ .owner = @fromBackingInt(71), .policy = policy }).encodeAlloc(a);
    defer a.free(payload);
    const position = std.mem.indexOf(u8, payload, "[]").?;
    const old = try a.alloc(u8, payload.len - 2);
    defer a.free(old);
    @memcpy(old[0..position], payload[0..position]);
    @memcpy(old[position..], payload[position + 2 ..]);
    const encoded = try encode(records.profile.owner, old, &.{});
    defer a.free(encoded);
    if (records.OwnerRecord.decode(try view(encoded))) |_| return error.AcceptedOldOwner else |_| {}
}

test "access owner descriptor preserves stable keys and bound operators after encoding" {
    const policy = try f.core.Policy.init(f.vocabulary.descriptor);
    const header: records.OwnerRecord = .{ .owner = @fromBackingInt(71), .policy = policy };
    const payload = try header.encodeAlloc(a);
    defer a.free(payload);
    const encoded = try encode(records.profile.owner, payload, &.{});
    defer a.free(encoded);
    const decoded = try records.OwnerRecord.decode(try view(encoded));
    const again = try decoded.encodeAlloc(a);
    defer a.free(again);
    try std.testing.expectEqualStrings(payload, again);
    const values = try decoded.policy.value(&.{f.vocabulary.read}, &.{.{ .key = f.vocabulary.history, .value = 7 }});
    try std.testing.expect(!try decoded.policy.allows(values, .{ .permissions = &.{f.vocabulary.read}, .facts = &.{.{ .key = f.vocabulary.history, .value = 6 }} }));
    var invalid = header;
    invalid.resources = object;
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
    invalid.resources = null;
    invalid.next_resource = records.OwnerRecord.max_slots + 1;
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
    for (0..payload.len) |length| {
        const truncated = try encode(records.profile.owner, payload[0..length], &.{});
        defer a.free(truncated);
        if (records.OwnerRecord.decode(try view(truncated))) |_| return error.AcceptedTruncation else |_| {}
    }
}

test "access directory bitmap ranks all digits and rejects edge count and strength corruption" {
    var page: Page = .{ .owner = @fromBackingInt(71), .family = .resource, .level = 3, .prefix = 0x12345600 };
    var i: usize = 256;
    while (i != 0) {
        i -= 1;
        var target = object;
        target.sequence = i + 1;
        page.set(@intCast(i), target);
    }
    try std.testing.expectEqual(@as(usize, 256), page.count());
    for (0..256) |digit| try std.testing.expectEqual(@as(u64, digit + 1), page.get(@intCast(digit)).?.sequence);
    page.set(0, object);
    try std.testing.expectEqual(@as(usize, 256), page.count());
    const payload = try page.encodeAlloc(a);
    defer a.free(payload);
    const bytes = try encode(records.profile.directory, payload, &page.targets);
    defer a.free(bytes);
    const decoded = try Page.decode(try view(bytes));
    try std.testing.expectEqual(page.mask, decoded.mask);
    try std.testing.expectEqualDeep(page.targets, decoded.targets);
    const wrong_count = try encode(records.profile.directory, payload, page.targets[0..255]);
    defer a.free(wrong_count);
    try std.testing.expectError(error.InvalidRecord, Page.decode(try view(wrong_count)));
    page.targets[3].strength = .weak;
    const weak = try encode(records.profile.directory, payload, &page.targets);
    defer a.free(weak);
    try std.testing.expectError(error.InvalidRecord, Page.decode(try view(weak)));
    for (0..payload.len) |length| {
        const truncated = try encode(records.profile.directory, payload[0..length], &decoded.targets);
        defer a.free(truncated);
        if (Page.decode(try view(truncated))) |_| return error.AcceptedTruncation else |_| {}
    }
}
