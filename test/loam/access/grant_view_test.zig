//! Faulting grant sources exercise the same authority rules as the ledger.
//! Removing reply-version validation, or the pending-demand reset, each fails
//! its own intended assertion. The source counts loans and releases, so an
//! evaluation that leaves a record borrowed fails here.
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
    try std.testing.expectEqual(@as(?u64, 42), snapshot.active.effective.bound(0));
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
    try source.settled();
}

test "access grant views lend one record at a time and refuse a reentrant lookup" {
    var graph = try f.graphInit(a);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var source = Source.init(&graph, try f.terms(.{ .object = resource }, &.{f.read}, null));
    var grants = source.view();
    const child = try grants.borrow(id(1));
    try std.testing.expectEqual(@as(u16, 1), child.delegation_depth);
    try std.testing.expectError(error.RecordHeld, grants.borrow(id(0)));
    try std.testing.expectError(error.RecordHeld, grants.effectiveStatus(id(1)));
    try std.testing.expectEqual(@as(usize, 1), source.lent);
    grants.release();
    try source.settled();
    // A walk that stops early still returns its record.
    var path = grants.ancestry(id(1));
    try std.testing.expect((try path.next()) != null);
    try std.testing.expectError(error.RecordHeld, grants.borrow(id(0)));
    path.close();
    path.close();
    try source.settled();
    try std.testing.expectEqual(.active, try grants.effectiveStatus(id(1)));
    try source.settled();
    // A record the view rejects as malformed is not left on loan.
    source.rows[0].parent = id(0);
    try std.testing.expectError(error.InvalidRecord, grants.borrow(id(0)));
    try source.settled();
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
    lent: usize = 0,
    released: usize = 0,
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
        return View.init(self.version, 2, .{ .context = self, .lend = lend, .release = release });
    }

    /// Every loan was returned.
    fn settled(self: *const Source) !void {
        try std.testing.expectEqual(self.lent, self.released);
    }

    fn lend(context: *const anyopaque, requested: core.GrantId) View.SourceError!View.Reply {
        const self: *Source = @ptrCast(@alignCast(@constCast(context)));
        self.calls += 1;
        if (self.lent != self.released) return error.RecordHeld;
        if (self.recovery) return error.RecoveryRequired;
        if (self.change_on_call == self.calls) self.version.revisions.grants = @fromBackingInt(3);
        if (requested.slot >= self.rows.len) return .{ .version = self.version, .value = .{ .absent = .unknown } };
        if (!self.loaded[requested.slot]) return .{ .version = self.version, .value = .unloaded };
        if (self.absent == requested.slot or requested.generation != 1) return .{ .version = self.version, .value = .{ .absent = .gone } };
        self.lent += 1;
        return .{ .version = self.version, .value = .{ .present = &self.rows[requested.slot] } };
    }

    fn release(context: *const anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(@constCast(context)));
        self.released += 1;
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
    try source.settled();
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
        try std.testing.expectError(error.RevisionConflict, grants.borrow(id(0)));
        try std.testing.expect(grants.missing == null);
    }
    var source = Source.init(&graph, terms);
    var grants = source.view();
    source.absent = 0;
    try std.testing.expectError(error.Gone, grants.effectiveStatus(id(1)));
    try std.testing.expectError(error.UnknownGrant, grants.borrow(id(9)));
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
    try std.testing.expectError(error.InvalidRecord, grants.borrow(id(0)));
    source.rows[0].revision = @fromBackingInt(2);
    source.rows[0].id = id(1);
    try std.testing.expectError(error.InvalidRecord, grants.borrow(id(0)));
    try source.settled();
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
    try source.settled();
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
    changes.release(&grants);
    try source.settled();
    try std.testing.expectEqual(@as(?core.Revision, null), changes.expected);
    try std.testing.expectEqual(@as(core.Revision, @fromBackingInt(2)), changes.parent.?.expected);
    try std.testing.expectEqual(@as(u32, 1), changes.parent.?.child_count);
    try std.testing.expectEqual(@as(u32, 0), source.rows[1].child_count);
    try std.testing.expectEqualDeep(changes.record.parent, changes.event.kind.issued);
    try std.testing.expectEqual(changes.record.revision, changes.event.version.grants);
    try std.testing.expectEqual(changes.record.revision, changes.parent.?.revision);
    var pause = (try Plan.prepareCopying(failing.allocator(), &grants, &resources, &policy, 4, null, .{ .pause = id(0) })).?;
    defer pause.deinit(failing.allocator());
    const paused = try pause.changes(&grants);
    // An edit keeps the current row on loan until the caller is done with it.
    try std.testing.expect(paused.borrowed);
    try std.testing.expectError(error.RecordHeld, grants.borrow(id(1)));
    paused.release(&grants);
    try source.settled();
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
    try source.settled();
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
    try source.settled();
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
    try source.settled();
}
