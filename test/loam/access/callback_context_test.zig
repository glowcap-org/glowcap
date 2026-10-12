//! Shared hosting selects callback metadata. Descriptive names never grant access.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const resources = @import("resource_fixture.zig");
const pairs = @import("../../support/host_pair.zig");
const a = std.testing.allocator;

const Probe = struct {
    const Stamp = struct { resource: h.c.storage.Operation.BoundResource, content: h.loam.core.ObjectId, revision: u64 };
    expected: h.c.core.ResourceId,
    requirement: ?Stamp = null,
    invocations: usize = 0,
    refuse: bool = false,
    fn get(context: ?*anyopaque) *Probe {
        return @ptrCast(@alignCast(context.?));
    }
    fn behavior(self: *Probe) h.access.ContentBehavior {
        var result = h.contents[0];
        result.context = self;
        result.requirement = declare;
        result.references = references;
        result.invoke = invoke;
        result.resource = null;
        return result;
    }
    fn declare(context: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        const self = get(context);
        try std.testing.expect(input.bound_resource.id.eql(self.expected));
        try std.testing.expectEqual(.local, input.delivery);
        self.requirement = .{ .resource = input.bound_resource, .content = input.content.id, .revision = input.content.revision };
        return .{ .permissions = &.{h.f.vocabulary.read} };
    }
    fn same(self: *Probe, input: h.access.ContentInvocation) !void {
        const original = self.requirement.?;
        try std.testing.expectEqualDeep(original.resource, input.bound_resource);
        try std.testing.expect(original.content.eql(input.content.id));
        try std.testing.expectEqual(original.revision, input.content.revision);
    }
    fn references(context: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) ![]const h.loam.hosting.references.Request {
        try get(context).same(input);
        return &.{};
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, input: h.access.ContentInvocation) !h.driver.Value {
        const self = get(context);
        try self.same(input);
        self.invocations += 1;
        var path: [65]h.loam.core.ObjectId = undefined;
        const accounting = try call.accountingPath(&path);
        try std.testing.expect(accounting.len != 0);
        if (self.refuse) {
            try call.refuseCopying("rate-limited: retry-after-ms=1000; scope=join");
            return error.ApplicationRefused;
        }
        // Retain only scalar evidence; the invocation's payload borrow ends here.
        const reply = try h.contents[0].invoke(null, call, input);
        self.requirement = null;
        return reply;
    }
};

const Backend = struct {
    inner: *h.loam.Volatile,
    watched: [2]h.loam.core.ObjectId,
    counts: [2]usize = .{ 0, 0 },
    pub fn read(self: *Backend, request: h.loam.core.Read) h.loam.core.ReadResult {
        for (self.watched, 0..) |id, i| if (id.eql(request.id)) {
            self.counts[i] += 1;
        };
        return self.inner.read(request);
    }
    pub fn lookup(self: *Backend, request: h.loam.core.NameLookup) h.loam.core.NameResult {
        return self.inner.lookup(request);
    }
    pub fn commit(self: *Backend, batch: h.loam.core.Batch) h.loam.core.Outcome {
        return self.inner.commit(batch);
    }
};
fn resourceObject(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId, id: h.c.core.ResourceId) !h.loam.core.ObjectId {
    var read = try h.c.storage.Read.init(a, store, owner, 1);
    defer read.deinit() catch unreachable;
    _ = try h.f.pump(&read, backend);
    for (0..128) |_| {
        var view = try read.resourceView();
        _ = view.get(id) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try h.f.pump(&read, backend);
            continue;
        };
        return (try read.binding(.{ .resource = id })).?.object.?;
    }
    return error.NoProgress;
}

fn sourceEndpoint(store: *h.loam.core.Store, backend: anytype, data: h.Data, root: h.c.core.ResourceId) !h.loam.core.ObjectId {
    const held = try h.c.load(store, backend, data.use);
    defer store.release(held) catch unreachable;
    const endpoint = try h.loam.access.records.EndpointRecord.decode(try store.currentView(held));
    var read = try h.c.storage.Read.init(a, store, data.owner, 1);
    defer read.deinit() catch unreachable;
    try h.prepareEndpointOwner(&read, backend, 1);
    try store.begin();
    const content = try store.allocateId();
    try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = &@as([8]u8, @splat(0)), .edges = &.{.{ .target = data.use }} }, null);
    const source = try h.access.stageEndpoint(&read, a, .{ .descriptor = endpoint.descriptor, .content = .{ .resource = root, .object = content } }, true);
    try h.f.commit(store, backend);
    return source;
}

test "loam callback context follows direct and distinct local dependent resources" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const seeded = try resources.seed(&store, &backend);
    const source = try sourceEndpoint(&store, &backend, seeded.data, seeded.root);
    var host: h.Hosted = undefined;
    try host.open(&store, &backend, source, seeded.data.control, .{ .sleep_policy = .every_turn }, @splat(0x61));
    defer host.deinit();
    var probe: Probe = .{ .expected = seeded.root };
    const registrations = [_]h.access.ContentBehavior{probe.behavior()};
    host.service.contents = &registrations;
    var measured: Backend = .{ .inner = &backend, .watched = .{ try resourceObject(&store, &backend, seeded.data.owner, seeded.root), try resourceObject(&store, &backend, seeded.data.owner, seeded.leaf) } };
    store.evict();
    var direct: h.Answer = .{};
    // Caller data cannot substitute the selected endpoint's resource.
    try host.send(host.use, "get", &.{.{ .integer = seeded.leaf.slot }}, &direct);
    try host.drain(&measured);
    try std.testing.expectEqual(@as(?i64, 0), direct.number);
    try std.testing.expectEqualDeep([2]usize{ 1, 0 }, measured.counts);
    var peer = h.host_support.init(a, @splat(0x66), .{});
    defer peer.deinit();
    const pair = try pairs.openPair(&host.host, &peer, "127.0.0.1:9792");
    const shared = try host.host.callCapability(a, pair.a, host.use, "share-dependent", &.{}, 4096);
    defer shared.deinit();
    for (0..256) |_| {
        try host.host.flushSession(pair.a);
        try peer.flushSession(pair.b);
        try pairs.pumpToQuiescence(&.{pair});
        try host.drain(&backend);
        if (shared.result() != .pending) break;
    }
    try std.testing.expect(shared.result() == .ready);
    const facet = shared.result().ready.capability;
    probe.expected = seeded.leaf;
    measured.counts = .{ 0, 0 };
    store.evict();
    const selected = try host.host.callCapability(a, pair.a, facet, "get", &.{}, 4096);
    defer selected.deinit();
    for (0..256) |_| {
        try host.host.flushSession(pair.a);
        try peer.flushSession(pair.b);
        try pairs.pumpToQuiescence(&.{pair});
        try host.drain(&measured);
        if (selected.result() != .pending) break;
    }
    try std.testing.expect(selected.result() == .ready);
    try std.testing.expectEqual(@as(i64, 0), selected.result().ready.integer);
    try std.testing.expectEqual(@as(usize, 3), probe.invocations);
    // Both admission paths share their canonical row; callback context adds no
    // additional physical resource read, including the distinct selected leaf.
    try std.testing.expectEqualDeep([2]usize{ 1, 1 }, measured.counts);
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
    probe.refuse = true;
    probe.expected = seeded.root;
    var refusal: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &refusal);
    try host.drain(&measured);
    try std.testing.expect(refusal.broken);
    try std.testing.expectEqualStrings("rate-limited: retry-after-ms=1000; scope=join", refusal.reason());
}

test "loam callback context refuses retired resource generation before declaration" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var deleted: h.Answer = .{};
    try host.mutate(host.use, 1, "delete-resource", &.{}, &deleted);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), deleted.changed);
    var probe: Probe = .{ .expected = data.resource };
    const registrations = [_]h.access.ContentBehavior{probe.behavior()};
    host.service.contents = &registrations;
    store.evict();
    var refused: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &refused);
    try host.drain(&backend);
    try std.testing.expect(refused.broken);
    try std.testing.expectEqualStrings("Gone", refused.reason());
    try std.testing.expect(probe.requirement == null);
    try std.testing.expectEqual(@as(usize, 0), probe.invocations);
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
}
