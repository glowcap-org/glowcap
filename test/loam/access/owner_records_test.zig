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
    invalid.next_resource = 1;
    try std.testing.expectError(error.InvalidRecord, invalid.encodeAlloc(a));
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
