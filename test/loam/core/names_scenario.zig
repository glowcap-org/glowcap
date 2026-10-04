//! Exact discovery indexes commit with their records and reserve retired names.
const std = @import("std");
const loam = @import("glowcap").loam;
const core = loam.core;
const schemas = [_]core.Schema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8, .name_offset = 0 }};

fn query(store: *core.Store, name: [16]u8) core.NameLookup {
    const meta = store.metadata;
    return .{ .ticket = .{ .store = meta.store, .incarnation = meta.incarnation, .revision = meta.revision, .sequence = 1 }, .name = .{ .schema = 7, .bytes = name } };
}

pub fn exercise(comptime f: type, backend: anytype, metadata: core.Metadata) !void {
    var store = try core.Store.init(std.testing.allocator, metadata, &schemas, f.limits);
    defer store.deinit() catch unreachable;
    const name: [16]u8 = @splat(0x51);
    try store.begin();
    const id = try store.allocateId();
    var record = f.record(id, &name);
    record.rooted = true;
    try store.putCopying(record, null);
    try f.commit(&store, backend);
    const request = query(&store, name);
    try std.testing.expect(id.eql(backend.lookup(request).found));
    const revision = store.metadata.revision;

    try store.begin();
    const duplicate = try store.allocateId();
    try store.putCopying(f.record(duplicate, &name), null);
    try std.testing.expectError(error.NameCollision, f.commit(&store, backend));
    try std.testing.expectEqual(revision, store.metadata.revision);
    try std.testing.expect(id.eql(backend.lookup(query(&store, name)).found));

    try store.begin();
    record.payload = &@as([16]u8, @splat(0x52));
    try store.putCopying(record, revision);
    try std.testing.expectError(error.NameChanged, f.commit(&store, backend));
    try std.testing.expect(backend.lookup(query(&store, @splat(0x52))) == .missing);
    record.payload = &name;

    try store.begin();
    record.rooted = false;
    try store.putCopying(record, revision);
    try f.commit(&store, backend);
    try std.testing.expectEqual(error.StaleCompletion, backend.lookup(request).failed);
    try f.collect(&store, backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    // The payload is gone; the bounded index row still refuses reassignment.
    try std.testing.expect(id.eql(backend.lookup(query(&store, name)).found));
    try std.testing.expectError(error.Gone, f.load(&store, backend, id));
    try store.begin();
    const replacement = try store.allocateId();
    try store.putCopying(f.record(replacement, &name), null);
    try std.testing.expectError(error.NameCollision, f.commit(&store, backend));

    try store.begin();
    const short = try store.allocateId();
    try store.putCopying(f.record(short, "short"), null);
    try std.testing.expectError(error.InvalidRecord, f.commit(&store, backend));
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}
