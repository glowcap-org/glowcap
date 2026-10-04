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
        var read = try storage.Read.init(a, store, owner, 6);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectEqual(@as(u64, 2), read.header.next_resource);
        try std.testing.expectEqual(@as(u64, 2), read.header.next_grant);
        try f.require(&read, backend, child.grant, message, req);
        try std.testing.expectError(error.OutOfScope, f.require(&read, backend, child.grant, root, req));
        var grants = try read.grantView();
        try std.testing.expectEqual(@as(u32, 1), (try grants.get(issued.grant)).child_count);
    }
    _ = try f.change(store, backend, owner, .{ .pause = issued.grant });
    {
        var read = try storage.Read.init(a, store, owner, 6);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectError(error.Paused, f.require(&read, backend, child.grant, message, req));
    }
    _ = try f.change(store, backend, owner, .{ .resume_access = issued.grant });
    const narrower = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.post}, null);
    _ = try f.change(store, backend, owner, .{ .set_policy = .{ .grant = issued.grant, .terms = narrower } });
    {
        var read = try storage.Read.init(a, store, owner, 6);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectError(error.Denied, f.require(&read, backend, child.grant, message, req));
    }
    _ = try f.change(store, backend, owner, .{ .revoke = issued.grant });
    var restored = try storage.Read.init(a, store, owner, 6);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
        var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
    var read = try storage.Read.init(failing.allocator(), &fixture.store, owner, 3);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    try f.require(&read, &fixture.backend, issued.grant, resource, req);
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    for (0..32) |_| try f.require(&read, &fixture.backend, issued.grant, resource, req);
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expect(@sizeOf(storage.Read) <= 20 * 1024);
    try std.testing.expect(@sizeOf(storage.Append) <= 52 * 1024);
}

test "access owner refuses foreign identities stale generations and unsupported working sets" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const owner = try f.create(&fixture.store, &fixture.backend, @fromBackingInt(71));
    const resource = try f.resource(&fixture.store, &fixture.backend, owner, null);
    try std.testing.expectError(error.InvalidLimits, storage.Read.init(a, &fixture.store, owner, 8));
    var read = try storage.Read.init(a, &fixture.store, owner, 3);
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
    var read = try storage.Read.init(a, &fixture.store, owner, 1);
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
        var first = try storage.Read.init(a, store, owner, 1);
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
            0 => page.owner = @fromBackingInt(72),
            1 => page.family = .grant,
            2 => page.level = 1,
            3 => page.set(0, root),
            else => unreachable,
        }
        const payload = try page.encodeAlloc(a);
        defer a.free(payload);
        try store.begin();
        try store.putCopying(.{ .id = root, .revision = 0, .schema = row.schema, .payload = payload, .edges = page.targets[0..page.count()] }, row.revision);
        try store.release(lease);
        try f.commit(store, backend);
        var read = try storage.Read.init(a, store, owner, 1);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        var resources = try read.resourceView();
        try std.testing.expectError(error.RecordUnloaded, resources.get(resource));
        try std.testing.expectError(error.InvalidRecord, f.pump(&read, backend));
    }
}

test "access composed resource and grant changes commit atomically in one transaction" {
    var wide = f.limits;
    wide.cache_slots = 24;
    wide.max_leases = 24;
    var fixture = try f.Fixture.init(a, wide);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(74));
    const root = try f.resource(store, backend, owner, null);

    // One Store transaction: a resource append, a root issuance scoping the
    // committed root and the staged resource, and a derive under that grant.
    try store.begin();
    var read = try storage.Read.init(a, store, owner, 7);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var append = try storage.Append.init(&read, .resource);
    _ = try f.pump(&append, backend);
    const message = try f.stageResource(&append, &read, backend, f.vocabulary.kind, root);
    try append.deinit();
    const terms = try f.vocabulary.terms(.{ .objects = &.{ root, message } }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    var plan = (try f.prepare(&read, backend, .{ .issue_root = f.vocabulary.issue(terms, 2) })).?;
    defer plan.deinit(a);
    var grants_append = try storage.Append.init(&read, .grant);
    _ = try f.pump(&grants_append, backend);
    const issued = try storage.stage.grant(&read, &plan, &grants_append);
    try grants_append.deinit();
    const selected = try f.vocabulary.terms(.{ .objects = &.{message} }, &.{f.vocabulary.read}, null);
    var child_plan = (try f.prepare(&read, backend, .{ .derive = .{ .parent = issued.change.grant, .request = f.vocabulary.issue(selected, 0) } })).?;
    defer child_plan.deinit(a);
    var child_append = try storage.Append.init(&read, .grant);
    _ = try f.pump(&child_append, backend);
    const derived = try storage.stage.grant(&read, &child_plan, &child_append);
    try child_append.deinit();
    try f.commit(store, backend);

    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(1)), issued.change.version.grants);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), derived.change.version.grants);
    var verify = try storage.Read.init(a, store, owner, 7);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(u64, 2), verify.header.next_resource);
    try std.testing.expectEqual(@as(u64, 2), verify.header.next_grant);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), verify.header.version.grants);
    try f.require(&verify, backend, issued.change.grant, root, req);
    try f.require(&verify, backend, issued.change.grant, message, req);
    try f.require(&verify, backend, derived.change.grant, message, req);
    try std.testing.expectError(error.OutOfScope, f.require(&verify, backend, derived.change.grant, root, req));
    var grants = try verify.grantView();
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), (try grants.get(issued.change.grant)).revision);
    try std.testing.expectEqual(@as(u32, 1), (try grants.get(issued.change.grant)).child_count);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), (try grants.get(derived.change.grant)).revision);
}

test "access composed changes to one grant sequence revisions and events on staged state" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(75));
    const root = try f.resource(store, backend, owner, null);
    const message = try f.resource(store, backend, owner, root);
    const terms = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const issued = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?;

    try store.begin();
    var read = try storage.Read.init(a, store, owner, 6);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    const narrower = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.post}, null);
    var policy_plan = (try f.prepare(&read, backend, .{ .set_policy = .{ .grant = issued.grant, .terms = narrower } })).?;
    defer policy_plan.deinit(a);
    const narrowed = storage.stage.grant(&read, &policy_plan, null) catch |err| {
        return err;
    };
    var pause_plan = (try f.prepare(&read, backend, .{ .pause = issued.grant })) orelse {
        return error.NoProgress;
    };
    defer pause_plan.deinit(a);
    const paused = storage.stage.grant(&read, &pause_plan, null) catch |err| {
        return err;
    };
    try f.commit(store, backend);

    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), narrowed.change.version.grants);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(3)), paused.change.version.grants);
    var verify = try storage.Read.init(a, store, owner, 6);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(3)), verify.header.version.grants);
    try std.testing.expectError(error.Paused, f.require(&verify, backend, issued.grant, message, req));
    var grants = try verify.grantView();
    const row = try grants.get(issued.grant);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(3)), row.revision);
    try std.testing.expectEqual(.paused, row.status);
}

test "access composed derivations under one parent compose the parent row" {
    var wide = f.limits;
    wide.cache_slots = 24;
    wide.max_leases = 24;
    var fixture = try f.Fixture.init(a, wide);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(76));
    const root = try f.resource(store, backend, owner, null);
    const message = try f.resource(store, backend, owner, root);
    const terms = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.read}, null);
    const parent = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 3) })).?;

    try store.begin();
    var read = try storage.Read.init(a, store, owner, 7);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    const message_terms = try f.vocabulary.terms(.{ .objects = &.{message} }, &.{f.vocabulary.read}, null);
    var first_plan = (try f.prepare(&read, backend, .{ .derive = .{ .parent = parent.grant, .request = f.vocabulary.issue(message_terms, 0) } })).?;
    defer first_plan.deinit(a);
    var first_append = try storage.Append.init(&read, .grant);
    _ = try f.pump(&first_append, backend);
    const first = try storage.stage.grant(&read, &first_plan, &first_append);
    try first_append.deinit();
    const root_terms = try f.vocabulary.terms(.{ .objects = &.{root} }, &.{f.vocabulary.read}, null);
    var second_plan = (try f.prepare(&read, backend, .{ .derive = .{ .parent = parent.grant, .request = f.vocabulary.issue(root_terms, 0) } })).?;
    defer second_plan.deinit(a);
    var second_append = try storage.Append.init(&read, .grant);
    _ = try f.pump(&second_append, backend);
    const second = try storage.stage.grant(&read, &second_plan, &second_append);
    try second_append.deinit();
    try f.commit(store, backend);

    var verify = try storage.Read.init(a, store, owner, 7);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try f.require(&verify, backend, first.change.grant, message, req);
    try f.require(&verify, backend, second.change.grant, root, req);
    try std.testing.expectError(error.OutOfScope, f.require(&verify, backend, first.change.grant, root, req));
    var grants = try verify.grantView();
    const parent_row = try grants.get(parent.grant);
    try std.testing.expectEqual(@as(u32, 2), parent_row.child_count);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(3)), parent_row.revision);
}

test "access stale composed preparation refuses the whole transaction without partial changes" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(77));
    const root = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const issued = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?;
    const revision_before = store.metadata.revision;

    try store.begin();
    var read = try storage.Read.init(a, store, owner, 6);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    // The second change is prepared against the committed header, before the
    // first change composes its delta into the same transaction.
    const narrower = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{f.vocabulary.post}, null);
    var stale_plan = (try f.prepare(&read, backend, .{ .set_policy = .{ .grant = issued.grant, .terms = narrower } })).?;
    defer stale_plan.deinit(a);
    var append = try storage.Append.init(&read, .resource);
    _ = try f.pump(&append, backend);
    _ = try f.stageResource(&append, &read, backend, f.vocabulary.kind, root);
    if (storage.stage.grant(&read, &stale_plan, null)) |_| {
        try append.deinit();
        try store.abort();
        return error.ExpectedConflict;
    } else |err| {
        try std.testing.expectEqual(error.RevisionConflict, err);
    }
    try append.deinit();
    try store.abort();
    try std.testing.expectEqual(revision_before, store.metadata.revision);
    var verify = try storage.Read.init(a, store, owner, 6);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(u64, 1), verify.header.next_resource);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(1)), verify.header.version.grants);
}

test "access composed transaction aborts before submission and keeps committed state" {
    var fixture = try f.Fixture.init(a, f.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(78));
    const root = try f.resource(store, backend, owner, null);

    try store.begin();
    var read = try storage.Read.init(a, store, owner, 7);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var append = try storage.Append.init(&read, .resource);
    _ = try f.pump(&append, backend);
    _ = try f.stageResource(&append, &read, backend, f.vocabulary.kind, root);
    try append.deinit();
    const terms = try f.vocabulary.terms(.{ .objects = &.{root} }, &.{f.vocabulary.read}, null);
    var plan = (try f.prepare(&read, backend, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?;
    defer plan.deinit(a);
    var grants_append = try storage.Append.init(&read, .grant);
    _ = try f.pump(&grants_append, backend);
    _ = try storage.stage.grant(&read, &plan, &grants_append);
    try grants_append.deinit();
    try store.abort();

    var verify = try storage.Read.init(a, store, owner, 6);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(u64, 1), verify.header.next_resource);
    try std.testing.expectEqual(@as(u64, 0), verify.header.next_grant);
}

test "access composed transaction recovers an unknown outcome to the committed batch" {
    var wide = f.limits;
    wide.cache_slots = 24;
    wide.max_leases = 24;
    var fixture = try f.Fixture.init(a, wide);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(79));
    const root = try f.resource(store, backend, owner, null);

    try store.begin();
    var read = try storage.Read.init(a, store, owner, 7);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var append = try storage.Append.init(&read, .resource);
    _ = try f.pump(&append, backend);
    const message = try f.stageResource(&append, &read, backend, f.vocabulary.kind, root);
    try append.deinit();
    const terms = try f.vocabulary.terms(.{ .objects = &.{ root, message } }, &.{f.vocabulary.read}, null);
    var plan = (try f.prepare(&read, backend, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?;
    defer plan.deinit(a);
    var grants_append = try storage.Append.init(&read, .grant);
    _ = try f.pump(&grants_append, backend);
    const issued = try storage.stage.grant(&read, &plan, &grants_append);
    try grants_append.deinit();
    const ticket = try store.prepare();
    const batch = try store.beginWrite(ticket);
    _ = backend.commit(batch);
    try store.completeWrite(ticket, .unknown);
    try std.testing.expectError(error.RecoveryRequired, read.advance());
    try store.resolve(ticket, try backend.recover(try store.recoveryBatch()));

    var verify = try storage.Read.init(a, store, owner, 6);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(u64, 2), verify.header.next_resource);
    try std.testing.expectEqual(@as(u64, 1), verify.header.next_grant);
    try f.require(&verify, backend, issued.change.grant, message, req);
}
