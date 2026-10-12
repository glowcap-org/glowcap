//! Faulting grant sources exercise the same authority rules as the ledger.
//! Regression guards were checked by removing reply-version validation and
//! pending-demand reset separately. Each reached its intended assertion.
const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const View = core.GrantView;
const Plan = core.GrantPlan;
const a = std.testing.allocator;

test "access descriptions share admission intersection and hide inactive policy" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var resources = graph.readView();
    const policy = try core.Policy.init(f.descriptor);
    var source = Source.init(&graph, try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null));
    source.rows[0].configured = try f.terms(.{ .object = resource }, &.{f.read}, 42);
    var grants = source.view();
    const snapshot = try grants.describe(&resources, &policy, id(1), resource);
    try std.testing.expectEqual(@as(u64, 3), snapshot.active.configured.permissions);
    try std.testing.expectEqual(@as(u64, 1), snapshot.active.effective.permissions);
    try std.testing.expectEqual(@as(?u64, 42), snapshot.active.effective.bounds[0]);
    try std.testing.expectError(error.Denied, grants.require(&resources, &policy, id(1), resource, .{ .permissions = &.{f.post} }));
    try grants.require(&resources, &policy, id(1), resource, .{ .permissions = &.{f.read} });
    source.loaded[0] = false;
    try std.testing.expectError(error.RecordUnloaded, grants.describe(&resources, &policy, id(1), resource));
    source.loaded[0] = true;
    source.rows[0].status = .paused;
    try std.testing.expectEqual(.paused, try grants.describe(&resources, &policy, id(1), resource));
    source.rows[1].status = .revoked;
    try std.testing.expectEqual(.revoked, try grants.describe(&resources, &policy, id(1), resource));
    source.rows[0].status = .active;
    source.rows[1].status = .active;
    source.rows[0].configured.scope = .{ .objects = &.{} };
    try std.testing.expectEqual(.out_of_scope, try grants.describe(&resources, &policy, id(1), resource));
}

fn id(slot: u32) core.GrantId {
    return .{ .owner = @fromBackingInt(1), .slot = slot, .generation = 1 };
}

const Source = struct {
    version: View.Version,
    rows: [2]core.GrantLedger.Record,
    loaded: [2]bool = .{ true, true },
    absent: ?u32 = null,
    calls: usize = 0,
    change_on_call: ?usize = null,
    recovery: bool = false,

    fn init(graph: *core.Graph, terms: core.Terms) Source {
        const root: core.GrantLedger.Record = .{
            .id = id(0),
            .parent = null,
            .ceiling = terms,
            .configured = terms,
            .status = .active,
            .revision = @fromBackingInt(2),
            .delegation_depth = 2,
            .child_count = 1,
        };
        var child = root;
        child.id = id(1);
        child.parent = id(0);
        child.delegation_depth = 1;
        child.child_count = 0;
        return .{ .version = .{ .owner = graph.owner, .revisions = .{ .resources = graph.revision(), .grants = @fromBackingInt(2) } }, .rows = .{ root, child } };
    }

    fn view(self: *Source) View {
        return View.init(self.version, 2, self, read);
    }

    fn read(context: *const anyopaque, requested: core.GrantId) View.SourceError!View.Reply {
        const self: *Source = @ptrCast(@alignCast(@constCast(context)));
        self.calls += 1;
        if (self.recovery) return error.RecoveryRequired;
        if (self.change_on_call == self.calls) self.version.revisions.grants = @fromBackingInt(3);
        const value: @FieldType(View.Reply, "value") = if (requested.slot >= self.rows.len)
            .{ .absent = .unknown }
        else if (!self.loaded[requested.slot])
            .unloaded
        else if (self.absent == requested.slot or requested.generation != 1)
            .{ .absent = .gone }
        else
            .{ .present = self.rows[requested.slot] };
        return .{ .version = self.version, .value = value };
    }
};

test "access grant demand cannot skip unloaded or revoked ancestors" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var resources = graph.readView();
    const policy = try core.Policy.init(f.descriptor);
    var source = Source.init(&graph, try f.terms(.{ .object = resource }, &.{f.read}, null));
    source.loaded[0] = false;
    var grants = source.view();
    const requirement: core.Policy.Requirement = .{ .permissions = &.{f.read} };
    try std.testing.expectError(error.RecordUnloaded, grants.require(&resources, &policy, id(1), resource, requirement));
    try std.testing.expectEqualDeep(View.Request{ .version = source.version, .id = id(0) }, grants.missing.?);
    source.loaded[0] = true;
    try grants.require(&resources, &policy, id(1), resource, requirement);
    source.rows[0].status = .revoked;
    source.rows[0].revision = @fromBackingInt(3);
    source.version.revisions.grants = @fromBackingInt(3);
    try std.testing.expectError(error.RevisionConflict, grants.require(&resources, &policy, id(1), resource, requirement));
    grants = source.view();
    try std.testing.expectError(error.Revoked, grants.require(&resources, &policy, id(1), resource, requirement));
    source.recovery = true;
    try std.testing.expectError(error.RecoveryRequired, grants.effectiveStatus(id(1)));
}

test "access grant snapshots refuse absent stale malformed and cyclic records" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    for (0..3) |mode| {
        var source = Source.init(&graph, terms);
        var grants = source.view();
        source.version.revisions.grants = @fromBackingInt(3);
        source.loaded[0] = mode != 0;
        if (mode == 2) source.absent = 0;
        try std.testing.expectError(error.RevisionConflict, grants.get(id(0)));
        try std.testing.expect(grants.missing == null);
    }
    var source = Source.init(&graph, terms);
    var grants = source.view();
    source.absent = 0;
    try std.testing.expectError(error.Gone, grants.effectiveStatus(id(1)));
    try std.testing.expectError(error.UnknownGrant, grants.get(id(9)));
    source.absent = null;
    source.rows[0].parent = id(1);
    try std.testing.expectError(error.DepthLimit, grants.effectiveStatus(id(1)));
    try std.testing.expect(source.calls < 12);
    source.rows[0].parent = null;
    grants.max_depth = 0;
    try std.testing.expectError(error.DepthLimit, grants.effectiveStatus(id(1)));
    grants.max_depth = 1;
    try std.testing.expectEqual(.active, try grants.effectiveStatus(id(1)));
    source.rows[0].revision = @fromBackingInt(3);
    try std.testing.expectError(error.InvalidRecord, grants.get(id(0)));
    source.rows[0].revision = @fromBackingInt(2);
    source.rows[0].id = id(1);
    try std.testing.expectError(error.InvalidRecord, grants.get(id(0)));
}

test "access grant evaluation rejects revision changes during ancestry and resource moves" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const other = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, root);
    var source = Source.init(&graph, try f.terms(.{ .owned_subtree = root }, &.{f.read}, null));
    var grants = source.view();
    var resources = graph.readView();
    const policy = try core.Policy.init(f.descriptor);
    const req: core.Policy.Requirement = .{ .permissions = &.{f.read} };
    source.change_on_call = 4;
    try std.testing.expectError(error.RevisionConflict, grants.require(&resources, &policy, id(1), resource, req));
    grants = source.view();
    try grants.require(&resources, &policy, id(1), resource, req);
    try graph.reparent(graph.revision(), &structural_policy, resource, other);
    try std.testing.expectError(error.RevisionConflict, grants.require(&resources, &policy, id(1), resource, req));
    resources = graph.readView();
    try std.testing.expectError(error.RevisionConflict, grants.require(&resources, &policy, id(1), resource, req));
    source.version.revisions.resources = graph.revision();
    grants = source.view();
    try std.testing.expectError(error.OutOfScope, grants.require(&resources, &policy, id(1), resource, req));
}

test "access grant plan stages child parent and event without publishing or allocating lifecycle edits" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    var source = Source.init(&graph, terms);
    var grants = source.view();
    var resources = graph.readView();
    const policy = try core.Policy.init(f.descriptor);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var plan = (try Plan.prepareCopying(failing.allocator(), &grants, &resources, &policy, 4, id(2), .{ .derive = .{ .parent = id(1), .request = f.issue(terms, 0) } })).?;
    defer plan.deinit(failing.allocator());
    const changes = try plan.changes(&grants);
    try std.testing.expectEqual(@as(?core.Revision, null), changes.expected);
    try std.testing.expectEqual(@as(?core.Revision, @fromBackingInt(2)), changes.parent_expected);
    try std.testing.expectEqual(@as(u32, 1), changes.parent_record.?.child_count);
    try std.testing.expectEqual(@as(u32, 0), source.rows[1].child_count);
    try std.testing.expectEqualDeep(changes.record.parent, changes.event.kind.issued);
    try std.testing.expectEqual(changes.record.revision, changes.event.version.grants);
    try std.testing.expectEqual(changes.record.revision, changes.parent_record.?.revision);
    var pause = (try Plan.prepareCopying(failing.allocator(), &grants, &resources, &policy, 4, null, .{ .pause = id(0) })).?;
    defer pause.deinit(failing.allocator());
    const paused = try pause.changes(&grants);
    try std.testing.expectEqual(.active, source.rows[0].status);
    try std.testing.expectEqual(.paused, paused.record.status);
    try std.testing.expectEqualDeep(core.GrantLedger.Change.Kind{ .status_changed = .{ .before = .active, .after = .paused } }, paused.event.kind);
    source.rows[0] = paused.record;
    source.version.revisions = paused.event.version;
    try std.testing.expectError(error.RevisionConflict, plan.changes(&grants));
    grants = source.view();
    try std.testing.expectError(error.RevisionConflict, plan.changes(&grants));
    try std.testing.expectEqual(.paused, try grants.effectiveStatus(id(1)));
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "access grant preparation refuses unloaded ancestors and persisted child counts over limit" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    var source = Source.init(&graph, terms);
    var grants = source.view();
    var resources = graph.readView();
    const policy = try core.Policy.init(f.descriptor);
    source.loaded[0] = false;
    const command: core.GrantLedger.Command = .{ .derive = .{ .parent = id(1), .request = f.issue(terms, 0) } };
    try std.testing.expectError(error.RecordUnloaded, Plan.prepareCopying(a, &grants, &resources, &policy, 4, id(2), command));
    source.loaded[0] = true;
    source.rows[1].child_count = 5;
    try std.testing.expectError(error.ChildLimit, Plan.prepareCopying(a, &grants, &resources, &policy, 4, id(2), command));
    source.rows[1].child_count = 0;
    grants.max_depth = 1;
    try std.testing.expectError(error.DepthLimit, Plan.prepareCopying(a, &grants, &resources, &policy, 4, id(2), command));
}

test "access retries expose only the current grant or resource demand" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    var source = Source.init(&graph, terms);
    source.loaded[0] = false;
    var grants = source.view();
    const ColdResource = struct {
        fn read(context: *const anyopaque, _: core.ResourceId) core.ResourceView.SourceError!core.ResourceView.Reply {
            const owner: *core.Graph = @ptrCast(@alignCast(@constCast(context)));
            return .{ .version = owner.readView().version, .value = .unloaded };
        }
    };
    var resources = core.ResourceView.init(graph.readView().version, 4, &graph, ColdResource.read);
    const policy = try core.Policy.init(f.descriptor);
    const req: core.Policy.Requirement = .{ .permissions = &.{f.read} };
    try std.testing.expectError(error.RecordUnloaded, grants.require(&resources, &policy, id(1), resource, req));
    try std.testing.expect(grants.missing != null);
    try std.testing.expect(resources.missing == null);
    // Independent issuance has no ancestor lookup; it still clears the prior
    // grant demand before encountering its own unloaded scope resource.
    try std.testing.expectError(error.RecordUnloaded, Plan.prepareCopying(a, &grants, &resources, &policy, 4, id(2), .{ .issue_root = f.issue(terms, 0) }));
    try std.testing.expect(grants.missing == null);
    try std.testing.expect(resources.missing.?.id.eql(resource));
    try std.testing.expectError(error.RecordUnloaded, grants.require(&resources, &policy, id(1), resource, req));
    try std.testing.expect(resources.missing == null);
    try std.testing.expect(grants.missing.?.id.eql(id(0)));
}
