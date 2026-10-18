//! Scope support covers heterogeneous selections and future owned descendants.
//! The shared model refuses unsupported terms and checks each exact effect.
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const a = std.testing.allocator;
const room: core.KindId = @fromBackingInt(1);
const message: core.KindId = @fromBackingInt(2);
const file: core.KindId = @fromBackingInt(3);
const unknown: core.KindId = @fromBackingInt(4);
const rules = [_]core.Policy.KindRule{
    .{ .kind = room, .permissions = 1, .subtree_permissions = 3 },
    .{ .kind = message, .permissions = 2, .subtree_permissions = 2 },
    .{ .kind = file, .permissions = 1, .subtree_permissions = 1 },
};
const descriptor: core.Policy.Descriptor = .{ .id = f.descriptor.id, .permissions = &.{ f.read, f.post }, .kinds = &rules };

fn terms(scope: core.Scope, mask: u64) core.Terms {
    return .{ .scope = scope, .policy = .{ .schema = descriptor.id, .permissions = mask } };
}

test "access applicability validates strict declarations and dependency closure" {
    var policy = try core.Policy.init(descriptor);
    try std.testing.expectError(error.UnknownKind, policy.supported(unknown, false));
    try std.testing.expectEqual(@as(u64, 0), try f.structural_policy.supported(unknown, false));
    try std.testing.expectError(error.UnknownPermission, policy.setKinds(&.{.{ .kind = room, .permissions = 4, .subtree_permissions = 4 }}));
    try std.testing.expectError(error.InvalidKindRule, policy.setKinds(&.{.{ .kind = room, .permissions = 3, .subtree_permissions = 1 }}));
    try std.testing.expectError(error.NonCanonicalSchema, policy.setKinds(&.{ rules[1], rules[0] }));
    try std.testing.expectError(error.NonCanonicalSchema, policy.setKinds(&.{ rules[0], rules[0] }));
    // Every refusal left the declared rules in place.
    try std.testing.expectEqualSlices(core.Policy.KindRule, &rules, policy.kind_rules[0..policy.kind_count]);
    var dependent = descriptor;
    dependent.dependencies = &.{.{ .permission = f.post, .required = f.read }};
    try std.testing.expectError(error.MissingPrerequisite, core.Policy.init(dependent));
    var masks: [64]u64 = @splat(0);
    masks[1] = 1;
    // The kind rules already set select `post` without `read`.
    try std.testing.expectError(error.MissingPrerequisite, policy.setPrerequisiteMasks(&masks));
    var too_many: [core.Policy.max_kinds + 1]core.Policy.KindRule = undefined;
    @memset(&too_many, rules[0]);
    try std.testing.expectError(error.PolicyLimit, policy.setKinds(&too_many));
    try policy.check();
    policy.permission_count = core.Policy.max_permissions + 1;
    try std.testing.expectError(error.PolicyLimit, policy.check());
}

test "access applicability admits future descendants and projects each exact target" {
    const policy = try core.Policy.init(descriptor);
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &policy, room, null);
    var ledger = try core.GrantLedger.init(a, &graph, descriptor, .{ .capacity = 8 });
    defer ledger.deinit() catch unreachable;
    // The subtree can carry message authority before any message exists.
    const parent = (try ledger.issueRootCopying(ledger.version(), f.issue(terms(.{ .owned_subtree = root }, 3), 2))).grant;
    const child = try graph.create(graph.revision(), &policy, message, root);
    try ledger.require(parent, child, .{ .permissions = &.{f.post} });
    try std.testing.expectError(error.InapplicablePermission, ledger.require(parent, root, .{ .permissions = &.{f.post} }));
    var resources = graph.readView();
    var grants = ledger.readView();
    try std.testing.expectEqual(@as(u64, 1), (try grants.describe(&resources, &policy, parent, root)).active.effective.permissions);
    try std.testing.expectEqual(@as(u64, 2), (try grants.describe(&resources, &policy, parent, child)).active.effective.permissions);
    const exact = (try ledger.deriveCopying(ledger.version(), parent, f.issue(terms(.{ .object = child }, 2), 0))).grant;
    try ledger.require(exact, child, .{ .permissions = &.{f.post} });
    const selected = terms(.{ .objects = &.{ root, child } }, 3);
    const mixed = (try ledger.issueRootCopying(ledger.version(), f.issue(selected, 0))).grant;
    try ledger.require(mixed, root, .{ .permissions = &.{f.read} });
    try ledger.require(mixed, child, .{ .permissions = &.{f.post} });
    try std.testing.expectError(error.InapplicablePermission, ledger.require(mixed, child, .{ .permissions = &.{f.read} }));
}

test "access applicability refuses direct grant and control edits without changing state" {
    const policy = try core.Policy.init(descriptor);
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &policy, room, null);
    var ledger = try core.GrantLedger.init(a, &graph, descriptor, .{ .capacity = 4 });
    defer ledger.deinit() catch unreachable;
    const invalid = terms(.{ .object = root }, 3);
    const before = ledger.version();
    try std.testing.expectError(error.InapplicablePermission, ledger.issueRootCopying(before, f.issue(invalid, 1)));
    try std.testing.expectEqualDeep(before, ledger.version());
    const full = terms(.{ .owned_subtree = root }, 3);
    const parent = (try ledger.issueRootCopying(before, f.issue(full, 2))).grant;
    const current = ledger.version();
    try std.testing.expectError(error.InapplicablePermission, ledger.deriveCopying(current, parent, f.issue(invalid, 0)));
    try std.testing.expectError(error.InapplicablePermission, ledger.setPolicyCopying(current, parent, invalid));
    var resources = graph.readView();
    const powers: core.Control.Powers = .{ .policy_ceiling = full };
    const malformed: core.Control.Powers = .{ .policy_ceiling = invalid };
    try std.testing.expectError(error.InapplicablePermission, core.Control.validate(&resources, &policy, full, malformed));
    try std.testing.expectError(error.InapplicablePermission, core.Control.attenuate(&resources, &policy, powers, malformed));
    try std.testing.expectError(error.InapplicablePermission, core.Control.command(&resources, &policy, parent, powers, .{ .set_policy = invalid }));
    try std.testing.expectEqualDeep(current, ledger.version());
}

test "access applicability refuses unknown and incompatible placements atomically" {
    const policy = try core.Policy.init(descriptor);
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &policy, room, null);
    const target = try graph.create(graph.revision(), &policy, file, null);
    const child = try graph.create(graph.revision(), &policy, message, root);
    const before = graph.revision();
    const count = graph.count();
    try std.testing.expectError(error.UnknownKind, graph.create(before, &policy, unknown, null));
    try std.testing.expectError(error.InvalidPlacement, graph.create(before, &policy, message, target));
    try std.testing.expectError(error.InvalidPlacement, graph.reparent(before, &policy, child, target));
    try std.testing.expectEqual(before, graph.revision());
    try std.testing.expectEqual(count, graph.count());
    try std.testing.expect((try graph.get(child)).parent.?.eql(root));
}

fn append(store: *@import("owner_fixture.zig").loam.core.Store, backend: anytype, owner: @import("owner_fixture.zig").loam.core.ObjectId, kind: core.KindId, parent: ?core.ResourceId) !core.ResourceId {
    const stored = @import("owner_fixture.zig");
    var read: stored.storage.Read = undefined;
    try read.init(a, store, owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try stored.pump(&read, backend);
    var pending = try stored.storage.Append.init(&read, .resource);
    defer pending.deinit() catch unreachable;
    _ = try stored.pump(&pending, backend);
    try store.begin();
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    const resource = try stored.stageResource(&pending, &read, backend, kind, parent);
    try stored.commit(store, backend);
    return resource;
}

test "access applicability preserves persisted placement rules after cold reload" {
    const stored = @import("owner_fixture.zig");
    const resource = @import("resource_fixture.zig");
    var fixture = try stored.Fixture.init(a, stored.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    try store.begin();
    const owner = try stored.storage.stage.createOwner(store, @fromBackingInt(81), try core.Policy.init(descriptor), .{});
    try stored.commit(store, backend);
    const root = try append(store, backend, owner, room, null);
    const target = try append(store, backend, owner, file, null);
    const child = try append(store, backend, owner, message, root);
    try store.deinit();
    try backend.close();
    store.* = try stored.loam.core.Store.init(a, try backend.open(), &stored.schemas, stored.limits);
    const before = store.metadata.revision;
    const count = store.count;
    try std.testing.expectError(error.UnknownKind, append(store, backend, owner, unknown, null));
    try std.testing.expectError(error.InvalidPlacement, append(store, backend, owner, message, target));
    try std.testing.expectError(error.InvalidPlacement, resource.change(store, backend, owner, child, .{ .move = target }));
    try std.testing.expectEqual(before, store.metadata.revision);
    try std.testing.expectEqual(count, store.count);
    try std.testing.expectEqual(.idle, store.phase);
    const destination = try append(store, backend, owner, room, null);
    _ = try append(store, backend, owner, message, destination);
    try std.testing.expect(try resource.change(store, backend, owner, child, .{ .move = destination }));
    store.evict();
    var read: stored.storage.Read = undefined;
    try read.init(a, store, owner, 6, null);
    defer read.deinit() catch unreachable;
    _ = try stored.pump(&read, backend);
    for (0..128) |_| {
        var resources = try read.resourceView();
        const current = resources.get(child) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try stored.pump(&read, backend);
            continue;
        };
        try std.testing.expect(current.parent.?.eql(destination));
        return;
    }
    return error.NoProgress;
}
