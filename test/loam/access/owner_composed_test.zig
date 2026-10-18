//! Composed resource and grant changes land, fail, abort, and recover as one
//! transaction on a managed owner.
const std = @import("std");
const f = @import("owner_fixture.zig");
const storage = f.storage;
const core = f.core;
const a = std.testing.allocator;
const req: core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };

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
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 7, null);
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
    child_append.grant_parent = child_plan.delta.issue.parent;
    _ = try f.pump(&child_append, backend);
    const derived = try storage.stage.grant(&read, &child_plan, &child_append);
    try child_append.deinit();
    try f.commit(store, backend);

    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(1)), issued.change.version.grants);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), derived.change.version.grants);
    var verify: storage.Read = undefined;
    try verify.init(a, store, owner, 7, null);
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
    {
        const row = try grants.borrow(issued.change.grant);
        defer grants.release();
        try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), row.revision);
        try std.testing.expectEqual(@as(u32, 1), row.child_count);
    }
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), (try grants.borrow(derived.change.grant)).revision);
    grants.release();
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
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    // Warm the committed scalar cache before this transaction stages a
    // selected policy. The following pause must observe that proposal.
    try f.require(&read, backend, issued.grant, message, req);
    const narrower = try f.vocabulary.terms(.{ .objects = &.{message} }, &.{f.vocabulary.post}, null);
    var policy_plan = (try f.prepare(&read, backend, .{ .set_policy = .{ .grant = issued.grant, .terms = narrower } })).?;
    defer policy_plan.deinit(a);
    const narrowed = storage.stage.grant(&read, &policy_plan, null) catch |err| {
        return err;
    };
    var proposed = try read.grantView();
    const proposal = try proposed.borrow(issued.grant);
    try std.testing.expectEqualSlices(core.ResourceId, &.{message}, proposal.configured.scope.objects);
    proposed.release();
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
    var verify: storage.Read = undefined;
    try verify.init(a, store, owner, 6, null);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(3)), verify.header.version.grants);
    try std.testing.expectError(error.Paused, f.require(&verify, backend, issued.grant, message, req));
    var grants = try verify.grantView();
    const row = try grants.borrow(issued.grant);
    defer grants.release();
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
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 7, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    const message_terms = try f.vocabulary.terms(.{ .objects = &.{message} }, &.{f.vocabulary.read}, null);
    var first_plan = (try f.prepare(&read, backend, .{ .derive = .{ .parent = parent.grant, .request = f.vocabulary.issue(message_terms, 0) } })).?;
    defer first_plan.deinit(a);
    var first_append = try storage.Append.init(&read, .grant);
    first_append.grant_parent = first_plan.delta.issue.parent;
    _ = try f.pump(&first_append, backend);
    const first = try storage.stage.grant(&read, &first_plan, &first_append);
    try first_append.deinit();
    const root_terms = try f.vocabulary.terms(.{ .objects = &.{root} }, &.{f.vocabulary.read}, null);
    var second_plan = (try f.prepare(&read, backend, .{ .derive = .{ .parent = parent.grant, .request = f.vocabulary.issue(root_terms, 0) } })).?;
    defer second_plan.deinit(a);
    var second_append = try storage.Append.init(&read, .grant);
    second_append.grant_parent = second_plan.delta.issue.parent;
    _ = try f.pump(&second_append, backend);
    const second = try storage.stage.grant(&read, &second_plan, &second_append);
    try second_append.deinit();
    try f.commit(store, backend);

    var verify: storage.Read = undefined;
    try verify.init(a, store, owner, 7, null);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try f.require(&verify, backend, first.change.grant, message, req);
    try f.require(&verify, backend, second.change.grant, root, req);
    try std.testing.expectError(error.OutOfScope, f.require(&verify, backend, first.change.grant, root, req));
    var grants = try verify.grantView();
    const parent_row = try grants.borrow(parent.grant);
    defer grants.release();
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
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 6, null);
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
    var verify: storage.Read = undefined;
    try verify.init(a, store, owner, 6, null);
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
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 7, null);
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

    var verify: storage.Read = undefined;
    try verify.init(a, store, owner, 6, null);
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
    var read: storage.Read = undefined;
    try read.init(a, store, owner, 7, null);
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

    var verify: storage.Read = undefined;
    try verify.init(a, store, owner, 6, null);
    defer verify.deinit() catch unreachable;
    _ = try f.pump(&verify, backend);
    try std.testing.expectEqual(@as(u64, 2), verify.header.next_resource);
    try std.testing.expectEqual(@as(u64, 1), verify.header.next_grant);
    try f.require(&verify, backend, issued.change.grant, message, req);
}
