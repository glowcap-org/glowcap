//! Managed owners use shared authority rules through durable record indexes.
const std = @import("std");
const f = @import("owner_fixture.zig");
const storage = f.storage;
const core = f.core;
const a = std.testing.allocator;
const req: core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };

test "access owner creates resources delegates edits pauses and revokes through Loam" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const root = try f.resource(store, backend, owner, null);
    const message = try f.resource(store, backend, owner, root);
    const terms = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const issued = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 2) })).?;
    const selected = try f.vocabulary.terms(.{ .objects = &.{message} }, &.{f.vocabulary.read}, null);
    const child = (try f.change(store, backend, owner, .{ .derive = .{ .parent = issued.grant, .request = f.vocabulary.issue(selected, 0) } })).?;
    store.evict();
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectEqual(@as(u64, 2), read.header.next_resource);
        try std.testing.expectEqual(@as(u64, 2), read.header.next_grant);
        try f.require(&read, backend, child.grant, message, req);
        try std.testing.expectError(error.OutOfScope, f.require(&read, backend, child.grant, root, req));
        var grants = try read.grantView();
        try std.testing.expectEqual(@as(u32, 1), (try grants.borrow(issued.grant)).child_count);
        grants.release();
    }
    _ = try f.change(store, backend, owner, .{ .pause = issued.grant });
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectError(error.Paused, f.require(&read, backend, child.grant, message, req));
    }
    _ = try f.change(store, backend, owner, .{ .resume_access = issued.grant });
    const narrower = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.post}, null);
    _ = try f.change(store, backend, owner, .{ .set_policy = .{ .grant = issued.grant, .terms = narrower } });
    {
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 6, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectError(error.Denied, f.require(&read, backend, child.grant, message, req));
    }
    _ = try f.change(store, backend, owner, .{ .revoke = issued.grant });
    var restored: storage.Read = undefined;
    try restored.init(a, store, owner, 6, null);
    defer restored.deinit() catch unreachable;
    _ = try f.pump(&restored, backend);
    try std.testing.expectError(error.Revoked, f.require(&restored, backend, child.grant, message, req));
    try std.testing.expectError(error.Revoked, f.prepare(&restored, backend, .{ .resume_access = child.grant }));
}

test "access directory traversal progresses with two cache slots across multiple leaves" {
    var limits = f.limits;
    limits.cache_slots = 2;
    limits.max_leases = 2;
    var fixture = try f.Fixture.init(a, limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    var last: core.ResourceId = undefined;
    for (0..258) |_| last = try f.resource(&fixture.store, &fixture.backend, owner, null);
    fixture.store.evict();
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    defer read.deinit() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), try f.pump(&read, &fixture.backend));
    var resources = try read.resourceView();
    try std.testing.expectError(error.RecordUnloaded, resources.get(last));
    try std.testing.expectEqual(@as(usize, 5), try f.pump(&read, &fixture.backend));
    try std.testing.expect((try resources.get(last)).id.eql(last));
    var other = last;
    other.slot = 0;
    try std.testing.expectError(error.RecordUnloaded, resources.get(other));
    try std.testing.expectError(error.WorkingSetCapacity, read.advance());
}

test "access owner read cleanup waits for submitted work and cancellation retires its buffer" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    fixture.store.evict();
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    const request = (try read.advance()).read;
    try std.testing.expect(try read.advance() == .waiting);
    try std.testing.expectError(error.Busy, read.deinit());
    var wrong = request.ticket;
    wrong.sequence += 1;
    try std.testing.expectError(error.StaleCompletion, read.completeRead(wrong, .missing));
    try read.cancel();
    try std.testing.expectError(error.Busy, read.deinit());
    try std.testing.expectError(error.Canceled, read.completeRead(request.ticket, fixture.backend.read(request)));
    try read.deinit();
    fixture.store.evict();
    try std.testing.expectEqual(@as(usize, 0), fixture.store.cache.allocated_bytes);
}

test "access current views expire after unrelated commits and do not reuse authority snapshots" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    const resource = try f.resource(&fixture.store, &fixture.backend, owner, null);
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    var resources = try read.resourceView();
    try std.testing.expectError(error.RecordUnloaded, resources.get(resource));
    _ = try f.pump(&read, &fixture.backend);
    _ = try resources.get(resource);
    try fixture.store.begin();
    const object = try fixture.store.allocateId();
    try fixture.store.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = "unrelated" }, null);
    try f.commit(&fixture.store, &fixture.backend);
    try std.testing.expectError(error.RevisionConflict, resources.get(resource));
    try std.testing.expectError(error.RevisionConflict, read.advance());
}

test "access append retains its read owner until pending work is retired" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    _ = try f.resource(&fixture.store, &fixture.backend, owner, null);
    fixture.store.evict();
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    _ = try f.pump(&read, &fixture.backend);
    var append = try storage.Append.init(&read, .resource);
    try std.testing.expectError(error.Busy, storage.Append.init(&read, .grant));
    const request = (try append.advance()).read;
    try std.testing.expectError(error.Busy, read.deinit());
    try std.testing.expectError(error.Busy, append.deinit());
    try append.cancel();
    try std.testing.expectError(error.Canceled, append.completeRead(request.ticket, fixture.backend.read(request)));
    try append.deinit();
    try read.deinit();
}

test "access cold owner completion cannot restore a precommit authority snapshot" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    fixture.store.evict();
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    defer read.deinit() catch unreachable;
    const request = (try read.advance()).read;
    const result = fixture.backend.read(request);
    try fixture.store.begin();
    const object = try fixture.store.allocateId();
    try fixture.store.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = "concurrent" }, null);
    try f.commit(&fixture.store, &fixture.backend);
    try std.testing.expectError(error.StaleCompletion, read.completeRead(request.ticket, result));
    try std.testing.expectError(error.RevisionConflict, read.advance());
    try std.testing.expect(read.header_revision == null);
}

test "access aborted resource append leaves the durable directory and counter unchanged" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    var proposed: core.ResourceId = undefined;
    {
        var read: storage.Read = undefined;
        try read.init(a, &fixture.store, owner, 1, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, &fixture.backend);
        var append = try storage.Append.init(&read, .resource);
        defer append.deinit() catch unreachable;
        _ = try f.pump(&append, &fixture.backend);
        try f.prepareResource(&append, &read, &fixture.backend, null);
        try fixture.store.begin();
        proposed = try storage.stage.appendResource(&append, f.vocabulary.kind, null);
        try fixture.store.abort();
    }
    fixture.store.evict();
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), read.header.next_resource);
    try std.testing.expect(read.header.resources == null);
    var resources = try read.resourceView();
    try std.testing.expectError(error.RecordUnloaded, resources.get(proposed));
    _ = try f.pump(&read, &fixture.backend);
    try std.testing.expectError(error.UnknownResource, resources.get(proposed));
}

test "access loaded grant evaluation has fixed scratch and no allocator calls" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var fixture = try f.Fixture.init(failing.allocator(), f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    const resource = try f.resource(&fixture.store, &fixture.backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
    const issued = (try f.change(&fixture.store, &fixture.backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?;
    var read: storage.Read = undefined;
    try read.init(failing.allocator(), &fixture.store, owner, 3, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    try f.require(&read, &fixture.backend, issued.grant, resource, req);
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    for (0..32) |_| try f.require(&read, &fixture.backend, issued.grant, resource, req);
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expect(@sizeOf(storage.Append) <= 52 * 1024);
}

test "access grant scratch alternates scalar and selected scopes without stale authority" {
    var limits = f.limits;
    limits.cache_slots = 24;
    limits.max_leases = 24;
    var fixture = try f.Fixture.init(a, limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const root = try f.resource(store, backend, owner, null);
    const child = try f.resource(store, backend, owner, root);
    const scalar = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.read}, null);
    const selected = try f.vocabulary.terms(.{ .objects = &.{child} }, &.{f.vocabulary.read}, null);
    const parent = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(scalar, 1) })).?;
    const narrow = (try f.change(store, backend, owner, .{ .derive = .{ .parent = parent.grant, .request = f.vocabulary.issue(selected, 0) } })).?;
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try f.require(&read, backend, narrow.grant, child, req);
    var grants = try read.grantView();
    for (0..8) |_| {
        const broad = (try grants.borrow(parent.grant)).*;
        try std.testing.expectEqual(root, broad.configured.scope.owned_subtree);
        grants.release();
        try std.testing.expectEqualDeep(broad, (try grants.borrow(parent.grant)).*);
        grants.release();
        const exact = try grants.borrow(narrow.grant);
        var resources = try read.resourceView();
        _ = try resources.get(child);
        try std.testing.expectEqualSlices(core.ResourceId, &.{child}, exact.configured.scope.objects);
        grants.release();
        try std.testing.expectError(error.OutOfScope, f.require(&read, backend, narrow.grant, root, req));
    }
    // One loan per read model: a second view, the same view, and the scratch
    // all refuse until the holder releases.
    const held = try grants.borrow(narrow.grant);
    var second = try read.grantView();
    try std.testing.expectError(error.RecordHeld, second.borrow(parent.grant));
    try std.testing.expectError(error.RecordHeld, grants.borrow(parent.grant));
    try std.testing.expectError(error.RecordHeld, read.grantScratch());
    try std.testing.expectEqualSlices(core.ResourceId, &.{child}, held.configured.scope.objects);
    grants.release();
    _ = try second.borrow(parent.grant);
    second.release();
    var stale = parent.grant;
    stale.generation += 1;
    try std.testing.expectError(error.RecordUnloaded, grants.borrow(stale));
    _ = try f.pump(&read, backend);
    try std.testing.expectError(error.Gone, grants.borrow(stale));
    _ = try f.change(store, backend, owner, .{ .pause = parent.grant });
    try std.testing.expectError(error.RevisionConflict, grants.borrow(parent.grant));
}

test "access owner refuses foreign identities stale generations and unsupported working sets" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    const resource = try f.resource(&fixture.store, &fixture.backend, owner, null);
    var read: storage.Read = undefined;
    try std.testing.expectError(error.InvalidLimits, read.init(a, &fixture.store, owner, 8, null));
    try read.init(a, &fixture.store, owner, 3, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    var resources = try read.resourceView();
    var invalid = resource;
    invalid.owner = @fromBackingInt(72);
    try std.testing.expectError(error.ForeignOwner, resources.get(invalid));
    try std.testing.expect(read.demand == null);
    invalid = resource;
    invalid.generation += 1;
    try std.testing.expectError(error.RecordUnloaded, resources.get(invalid));
    _ = try f.pump(&read, &fixture.backend);
    try std.testing.expectError(error.Gone, resources.get(invalid));
    invalid = resource;
    invalid.slot += 1;
    try std.testing.expectError(error.RecordUnloaded, resources.get(invalid));
    _ = try f.pump(&read, &fixture.backend);
    try std.testing.expectError(error.UnknownResource, resources.get(invalid));
}

fn failCreation(allocator: std.mem.Allocator) !void {
    var fixture = try f.Fixture.init(allocator, f.limits);
    defer fixture.deinit();
    _ = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
}

test "access owner creation releases every failed allocation and partial batch" {
    try std.testing.checkAllAllocationFailures(a, failCreation, .{});
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    var read: storage.Read = undefined;
    try read.init(a, &fixture.store, owner, 1, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    var append = try storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    _ = try f.pump(&append, &fixture.backend);
    fixture.store.limits.staging_bytes = 256;
    try fixture.store.begin();
    const content = try fixture.store.allocateId();
    try fixture.store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = "staged content" }, null);
    try f.prepareResource(&append, &read, &fixture.backend, null);
    try std.testing.expectError(error.RecordTooLarge, storage.stage.appendResource(&append, f.vocabulary.kind, null));
    try std.testing.expectEqual(.idle, fixture.store.phase);
    try std.testing.expectEqual(@as(u64, 1), fixture.store.metadata.objects);
    try std.testing.expectEqual(@as(usize, 0), fixture.store.staged_bytes);
}

test "access directory lookup rejects foreign family level and cyclic path substitution" {
    for (0..4) |mode| {
        var fixture = try f.Fixture.init(a, f.limits);
        defer fixture.deinit();
        const store = &fixture.store;
        const backend = &fixture.backend;
        const owner = try f.create(store, backend, @fromBackingInt(71));
        const resource = try f.resource(store, backend, owner, null);
        var first: storage.Read = undefined;
        try first.init(a, store, owner, 1, null);
        _ = try f.pump(&first, backend);
        const root = first.header.resources.?;
        try first.deinit();
        const lease = switch (try store.acquire(root)) {
            .ready => |lease| lease,
            .read => |request| blk: {
                try store.completeRead(request.ticket, backend.read(request));
                break :blk (try store.acquire(root)).ready;
            },
        };
        const row = try store.currentView(lease);
        var page = try f.loam.access.records.DirectoryPage.decode(row);
        switch (mode) {
            0 => page.header.owner = @fromBackingInt(72),
            1 => page.header.family = .grant,
            2 => page.header.level = 1,
            3 => page.set(0, root),
            else => unreachable,
        }
        const payload = try page.encodeAlloc(a);
        defer a.free(payload);
        try store.begin();
        try store.putCopying(.{ .id = root, .revision = 0, .schema = row.schema, .payload = payload, .edges = page.targets[0..page.count()] }, row.revision);
        try store.release(lease);
        try f.commit(store, backend);
        var read: storage.Read = undefined;
        try read.init(a, store, owner, 1, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        var resources = try read.resourceView();
        try std.testing.expectError(error.RecordUnloaded, resources.get(resource));
        try std.testing.expectError(error.InvalidRecord, f.pump(&read, backend));
    }
}
