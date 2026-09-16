//! Descriptor parsing owns bounded selections and rejects role/edge corruption.
const std = @import("std");
const c = @import("capability_fixture.zig");
const f = c.f;
const a = c.a;
const records = f.loam.access.records;
const Descriptor = records.CapabilityRecord;
const object: f.loam.core.ObjectId = .{ .store = f.store_id, .incarnation = 1, .sequence = 1 };

fn encode(payload: []const u8, edges: []const f.loam.core.Edge) ![]u8 {
    const row: f.loam.core.Record = .{ .id = object, .revision = 1, .schema = records.profile.capability, .payload = payload, .edges = edges };
    return row.encodeAlloc(a, f.limits.records, &f.schemas);
}
fn view(bytes: []const u8) !f.loam.core.RecordView {
    return f.loam.core.RecordView.decode(bytes, f.limits.records, &f.schemas);
}

test "access capability descriptors bound selected controls and refuse malformed records" {
    var selected: [c.core.max_scope_objects]c.core.ResourceId = undefined;
    for (&selected, 0..) |*id, i| id.* = .{ .owner = @fromBackingInt(71), .slot = @intCast(i), .generation = 1 };
    const ceiling = try f.vocabulary.terms(.{ .objects = &selected }, &.{f.vocabulary.read}, 100);
    var descriptor: Descriptor = .{ .owner = object, .grant_object = object, .grant = .{ .owner = @fromBackingInt(71), .slot = 0, .generation = 1 }, .role = .control, .powers = .{ .policy_ceiling = ceiling, .resume_access = true } };
    const payload = try descriptor.encodeAlloc(a);
    defer a.free(payload);
    const bytes = try encode(payload, &descriptor.edges());
    defer a.free(bytes);
    var failing = std.testing.FailingAllocator.init(a, .{});
    var decoded = try Descriptor.decodeOwned(failing.allocator(), try view(bytes));
    defer decoded.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expectEqualDeep(descriptor, decoded.value);
    descriptor.role = .use;
    try std.testing.expectError(error.InvalidRecord, descriptor.encodeAlloc(a));
    var weak_edges = descriptor.edges();
    weak_edges[1].strength = .weak;
    const weak = try encode(payload, &weak_edges);
    defer a.free(weak);
    try std.testing.expectError(error.InvalidRecord, Descriptor.decodeOwned(a, try view(weak)));
    const missing = try encode(payload, weak_edges[0..1]);
    defer a.free(missing);
    try std.testing.expectError(error.InvalidRecord, Descriptor.decodeOwned(a, try view(missing)));
    // Scalar descriptor truncation exercises every grammar boundary cheaply.
    descriptor.powers = .{};
    const scalar = try descriptor.encodeAlloc(a);
    defer a.free(scalar);
    for (0..scalar.len) |length| {
        const truncated = try encode(scalar[0..length], &descriptor.edges());
        defer a.free(truncated);
        if (Descriptor.decodeOwned(a, try view(truncated))) |value| {
            var owned = value;
            owned.deinit(a);
            return error.AcceptedTruncation;
        } else |_| {}
    }
}

test "access stored capability refuses a substituted grant retention edge" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    var caps = try c.storage.Capabilities.init(a, store, .{});
    defer caps.deinit() catch unreachable;
    const id = try c.descriptor(&caps, backend, owner, grant, null, true);
    const lease = try c.load(store, backend, id);
    const row = try store.currentView(lease);
    var descriptor = try Descriptor.decodeOwned(a, row);
    defer descriptor.deinit(a);
    descriptor.value.grant_object = owner;
    try store.begin();
    try store.putCopying(.{ .id = id, .revision = 0, .schema = row.schema, .payload = row.payload, .edges = &descriptor.value.edges(), .rooted = true }, row.revision);
    try store.release(lease);
    try f.commit(store, backend);
    const held = try c.use(&caps, backend, id);
    defer held.release();
    const operation = try held.begin(4);
    defer operation.deinit() catch unreachable;
    try std.testing.expectError(error.InvalidRecord, c.require(operation, backend, resource, .{ .permissions = &.{f.vocabulary.read} }));
}
