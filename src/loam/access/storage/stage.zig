//! Trusted managed changes join the caller's Loam transaction and recovery.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const read = @import("read.zig");
const Append = @import("append.zig").Append;
const record = @import("record.zig");
const history = @import("history.zig");
const putEncoded = record.putEncoded;
pub const endpoint = @import("endpoint_stage.zig").create;
pub const endpointFromOperation = @import("endpoint_stage.zig").createFromOperation;
pub const endpointAtOperation = @import("endpoint_stage.zig").stageFromOperation;
const capability_operation = @import("capability_operation.zig");

/// Retained encoded proposals, not Store allocator peak or backend metadata.
/// Application content, pages and fresh reference recipes are separate rows.
pub const ContentStagingBounds = struct { changes: usize = 0, staging_bytes: usize = 0, record_bytes: usize = 0 };

/// One content effect stamps the target and its ancestors, journals one batch,
/// updates the history root and owner, and optionally saves a mutation receipt
/// and its endpoint. Window eviction removes edges, not physical rows. Other
/// effects, resource/control edits and owner creation are separate participants.
/// This describes demand without loading records or admitting a transaction.
pub fn contentStagingSizeBound(resource_path: usize, receipt: bool) !ContentStagingBounds {
    if (resource_path == 0 or resource_path > records.ChangeBatchRecord.max_path) return error.DepthLimit;
    var bound: ContentStagingBounds = .{};
    for (records.profile.schemas) |schema| {
        const count: usize = switch (schema.id) {
            records.profile.resource => resource_path,
            records.profile.owner, records.profile.change_batch, records.profile.change_history => 1,
            records.profile.mutation, records.profile.endpoint => if (receipt) 1 else 0,
            else => 0,
        };
        if (count == 0) continue;
        const bytes = try schema.encodedSizeBound();
        bound.changes = try std.math.add(usize, bound.changes, count);
        bound.staging_bytes = try std.math.add(usize, bound.staging_bytes, try std.math.mul(usize, count, bytes));
        bound.record_bytes = @max(bound.record_bytes, bytes);
    }
    return bound;
}

/// Creates an empty owner root in the caller's staging transaction. Opening
/// failure never replaces an owner. Callers explicitly retain this reference.
pub fn createOwner(store: *loam.Store, owner: core.OwnerId, policy: core.Policy, options: Options) !loam.ObjectId {
    if (store.phase != .staging) return error.WrongPhase;
    if (options.max_resource_depth > core.max_depth or options.max_grant_depth > core.max_depth) return error.DepthLimit;
    errdefer store.abort() catch unreachable;
    const object = try store.allocateId();
    const header: records.OwnerRecord = .{ .owner = owner, .policy = policy, .max_resource_depth = options.max_resource_depth, .max_grant_depth = options.max_grant_depth, .max_grant_children = options.max_grant_children };
    try putEncoded(store, object, records.profile.owner, header, &.{}, null, .rooted);
    return object;
}
/// The deepest resource or grant tree an owner may allow.
pub const Options = struct { max_resource_depth: u32 = core.max_depth, max_grant_depth: u16 = core.max_depth, max_grant_children: u32 = 256 };

fn writable(view: *Read) !void {
    try view.prepareHistory();
    if (view.store.phase != .staging) return error.WrongPhase;
}

/// A staged or committed row plus the revision the backend must still match
/// when staging it again: this transaction's own staged proposal carries the
/// original expectation, a committed row carries its current revision.
fn rowOf(view: *Read, target: read.Target) !Read.Row {
    const binding = (try view.binding(target)) orelse return error.RecordUnloaded;
    return (try Read.rowFor(view.store, binding)) orelse return error.Gone;
}

fn loaded(view: *Read, target: read.Target) !loam.RecordView {
    return (try rowOf(view, target)).view;
}

pub fn appendResource(append: *Append, kind: core.KindId, parent: ?core.ResourceId) !core.ResourceId {
    return (try appendResourceRecord(append, kind, parent)).id;
}

/// A staged resource and the record its content's binding edge names.
pub const AppendedResource = struct { id: core.ResourceId, object: loam.ObjectId };

fn appendResourceRecord(append: *Append, kind: core.KindId, parent: ?core.ResourceId) !AppendedResource {
    const view = append.view;
    try writable(view);
    if (append.directory.family != .resource or append.directory.count != records.DirectoryPage.levels or append.directory.staged or append.directory.cancelled) return error.WrongPhase;
    if (!append.resource_ready or !std.meta.eql(append.parent, parent)) return error.NotPrepared;
    var resources = try view.resourceView();
    try view.header.policy.validatePlacement(kind, if (parent) |id| (try resources.get(id)).kind else null);
    var parent_object: ?loam.ObjectId = null;
    if (parent) |id| {
        if (resources.max_depth == 0) return error.DepthLimit;
        resources.max_depth -= 1;
        _ = try resources.isDescendant(id, id);
        parent_object = (try loaded(view, .{ .resource = id })).id;
    }
    const parent_path = if (parent) |id| try history.resourcePath(view, id) else history.ResourcePath{};
    var header = view.header;
    header.version.resources = header.version.resources.next() orelse return error.RevisionExhausted;
    const id: core.ResourceId = .{ .owner = header.owner, .slot = append.directory.slot, .generation = core.first_generation };
    // From here, a failure discards the entire shared content/access batch.
    errdefer view.store.abort() catch unreachable;
    view.transaction = view.store.ticket;
    const object = try view.store.allocateId();
    try record.putResource(view.store, object, records.ResourceRecord{ .revision = header.version.resources, .resource = .{ .id = id, .kind = kind, .parent = parent }, .placement = try history.stamp(view, @backingInt(header.version.resources)), .subtree = try history.stamp(view, @backingInt(header.version.resources)) }, parent_object, null);
    header.resources = try append.stageDirectory(object);
    const children = try append.child.?.stage(object);
    if (parent) |target| {
        const row = try rowOf(view, .{ .resource = target });
        try record.putChildren(view.store, row, children, header.version.resources);
    } else header.roots = children;
    header.next_resource += 1;
    // The view carries this transaction's composed header from here, so a
    // further managed change staged in the same transaction prepares against
    // these deltas instead of re-reading committed state.
    view.header = header;
    try history.touchResources(view, parent_path.slice(), .subtree);
    var path = parent_path;
    if (path.count == path.ids.len) return error.DepthLimit;
    std.mem.copyBackwards(core.ResourceId, path.ids[1 .. path.count + 1], path.ids[0..path.count]);
    path.ids[0] = id;
    path.count += 1;
    try history.append(view, .{ .resource = .{ .id = id, .kind = .created, .before = &.{}, .after = path.slice() } });
    try record.putOwner(view, &view.header);
    return .{ .id = id, .object = object };
}

/// Stages a prepared grant and its ancestry in the shared retained batch.
/// Issuance needs a prepared append path. Plans and this function are trusted
/// owner operations; use/control authority is admitted before calling them.
pub const StagedGrant = struct { change: core.GrantPlan.Change, object: loam.ObjectId };

pub fn grant(view: *Read, plan: *const core.GrantPlan, append: ?*Append) !StagedGrant {
    try writable(view);
    var grants = try view.grantView();
    const event_parent = if (plan.delta == .issue) plan.delta.issue.parent else blk: {
        const current = try grants.borrow(plan.grant);
        defer grants.release();
        break :blk current.parent;
    };
    var ancestors: [records.ChangeBatchRecord.max_path]core.GrantId = undefined;
    ancestors[0] = plan.grant;
    var ancestor_count: usize = 1;
    if (event_parent) |start| {
        var ancestry = grants.ancestry(start);
        defer ancestry.close();
        while (try ancestry.next()) |entry| {
            if (ancestor_count == ancestors.len) return error.DepthLimit;
            ancestors[ancestor_count] = entry.id;
            ancestor_count += 1;
        }
    }
    const changes = try plan.changes(&grants);
    defer changes.release(&grants);
    const issuing = changes.expected == null;
    if (issuing) {
        const path = append orelse return error.WrongPhase;
        if (path.view != view or path.directory.family != .grant or path.directory.count != records.DirectoryPage.levels or path.directory.staged or path.directory.cancelled or path.directory.slot != plan.grant.slot or plan.grant.generation != core.first_generation) return error.WrongPhase;
    } else if (append != null) return error.WrongPhase;
    const original = if (issuing) null else try rowOf(view, .{ .grant = plan.grant });
    // An edit's prior row is the one the plan borrowed. Policy and label
    // edits preserve its lifecycle stamp, and every edit keeps its child root.
    const prior: ?*const records.GrantRecord = if (issuing) null else view.heldRow();
    const status_stamp = if (issuing or plan.delta == .status) try history.stamp(view, @backingInt(changes.record.revision)) else prior.?.lifecycle;
    const parent = if (changes.parent) |inventory| try rowOf(view, .{ .grant = inventory.id }) else null;
    const child_root: ?loam.ObjectId = if (prior) |row| row.children else null;
    var edges: [records.GrantRecord.max_edges]loam.Edge = undefined;
    const edge_count = try grantEdges(view, plan, &changes, original, child_root, &edges);
    var header = view.header;
    header.version = changes.event.version;
    errdefer view.store.abort() catch unreachable;
    view.transaction = view.store.ticket;
    const object = if (original) |row| row.view.id else try view.store.allocateId();
    try putEncoded(view.store, object, records.profile.grant, records.GrantRecord{ .children = child_root, .grant = changes.record, .lifecycle = status_stamp, .authority = try history.stamp(view, @backingInt(header.version.grants)), .inventory = try history.stamp(view, @backingInt(header.version.grants)) }, edges[0..edge_count], if (original) |row| row.expected else null, .reachable);
    if (parent) |row| try restageParent(view, row, append, object, &changes, header);
    if (append) |path| {
        header.grants = try path.stageDirectory(object);
        header.next_grant += 1;
    }
    view.header = header;
    try history.touchGrants(view, ancestors[1..ancestor_count]);
    try history.append(view, .{ .grant = .{ .change = changes.event, .path = ancestors[0..ancestor_count] } });
    try record.putOwner(view, &view.header);
    return .{ .change = changes.event, .object = object };
}

/// The edges a grant row carries: its parent grant, every resource its terms
/// name, and its child root. A status or label edit keeps the prior row's.
fn grantEdges(
    view: *Read,
    plan: *const core.GrantPlan,
    changes: *const core.GrantPlan.Changes,
    original: ?Read.Row,
    child_root: ?loam.ObjectId,
    edges: *[records.GrantRecord.max_edges]loam.Edge,
) !usize {
    if (plan.delta == .status or plan.delta == .label) return record.copyEdges(original.?.view, edges);
    var edge_count: usize = 0;
    if (changes.record.parent) |id| {
        edges[edge_count] = .{ .target = (try loaded(view, .{ .grant = id })).id };
        edge_count += 1;
    }
    for ([_]core.Terms{ changes.record.ceiling, changes.record.configured }) |terms| switch (terms.scope) {
        .object, .owned_subtree => |id| {
            edges[edge_count] = .{ .target = (try loaded(view, .{ .resource = id })).id };
            edge_count += 1;
        },
        .objects => |ids| for (ids) |id| {
            edges[edge_count] = .{ .target = (try loaded(view, .{ .resource = id })).id };
            edge_count += 1;
        },
    };
    if (child_root) |id| {
        edges[edge_count] = .{ .target = id };
        edge_count += 1;
    }
    return edge_count;
}

/// Re-stage the parent grant: rebase its child index onto the staged
/// child, point its last edge at the new root, and advance its inventory.
fn restageParent(
    view: *Read,
    row: Read.Row,
    append: ?*Append,
    object: loam.ObjectId,
    changes: *const core.GrantPlan.Changes,
    header: records.OwnerRecord,
) !void {
    var parent_edges: [records.GrantRecord.max_edges]loam.Edge = undefined;
    var n = try record.copyEdges(row.view, &parent_edges);
    var parent_record: records.GrantRecord = undefined;
    try parent_record.decodeOwned(view.allocator, row.view.payload);
    defer parent_record.deinit(view.allocator);
    const child_index = append.?.child orelse return error.NotPrepared;
    try child_index.rebaseProposed(parent_record.children);
    const root = (try child_index.stage(object)).?;
    if (parent_record.children) |old| {
        if (n == 0 or !parent_edges[n - 1].target.eql(old)) return error.InvalidRecord;
        parent_edges[n - 1] = .{ .target = root };
    } else {
        parent_edges[n] = .{ .target = root };
        n += 1;
    }
    parent_record.children = root;
    parent_record.grant.child_count = changes.parent.?.child_count;
    parent_record.grant.revision = changes.parent.?.revision;
    parent_record.inventory = try history.stamp(view, @backingInt(header.version.grants));
    try putEncoded(view.store, row.view.id, records.profile.grant, parent_record, parent_edges[0..n], row.expected, .reachable);
}

/// Independent management changes fence admissions without advancing the
/// portable grant graph's revision or fabricating a grant change event.
pub fn controlChanged(view: *Read, object: loam.ObjectId, kind: @FieldType(@FieldType(records.ChangeBatchRecord.Effect, "control"), "kind")) !void {
    try writable(view);
    errdefer view.store.abort() catch unreachable;
    view.transaction = view.store.ticket;
    var header = view.header;
    header.control_revision = std.math.add(u64, header.control_revision, 1) catch return error.RevisionExhausted;
    view.header = header;
    try history.append(view, .{ .control = .{ .object = object, .kind = kind } });
    try record.putOwner(view, &view.header);
}

/// The caller prepared this path before invoking the application method.
pub fn contentChanged(view: *Read, target: core.ResourceId) !void {
    try writable(view);
    const path = try history.resourcePath(view, target);
    errdefer view.store.abort() catch unreachable;
    view.transaction = view.store.ticket;
    view.header.version.resources = view.header.version.resources.next() orelse return error.RevisionExhausted;
    try history.touchResources(view, path.slice(), .content);
    try history.append(view, .{ .content = .{ .id = target, .path = path.slice() } });
    try record.putOwner(view, &view.header);
}

/// Load the immutable ancestry needed to stamp and journal a prepared grant.
pub fn prepareGrant(view: *Read, plan: *const core.GrantPlan) !void {
    try view.prepareHistory();
    var grants = try view.grantView();
    const parent = if (plan.delta == .issue) plan.delta.issue.parent else @as(?core.GrantId, plan.grant);
    if (parent) |id| {
        var path = grants.ancestry(id);
        defer path.close();
        while (try path.next()) |_| {}
    }
}

/// Hosting has admitted the method and exact endpoint target before requesting
/// this owner-only preparation. It grants no public capability authority.
pub fn prepareContent(operation: *capability_operation.Operation, target: core.ResourceId) !void {
    const value = capability_operation.state(operation);
    try value.opened();
    if (value.staged or (value.prepared != .none and value.prepared != .resource and value.prepared != .child)) return error.WrongPhase;
    if (value.children != 0) return error.Busy;
    try value.read.prepareHistory();
    _ = try history.resourcePath(&value.read, target);
}

pub fn content(operation: *capability_operation.Operation, target: core.ResourceId) !void {
    const value = capability_operation.state(operation);
    try value.opened();
    try value.unprepared();
    try contentChanged(&value.read, target);
    value.staged = true;
}

/// Stage the prepared child under its parent. Hosting writes the child's
/// content record and endpoint in this same batch.
pub fn child(operation: *capability_operation.Operation, kind: core.KindId) !AppendedResource {
    const value = capability_operation.state(operation);
    try value.opened();
    if (value.staged or value.prepared != .child) return error.WrongPhase;
    const appended = try appendResourceRecord(value.prepared.child.append, kind, value.prepared.child.parent);
    value.staged = true;
    return appended;
}

/// One more content effect in the batch where this operation already staged
/// its first effect. The caller prepared the target's path with `prepareContent`.
pub fn contentAlso(operation: *capability_operation.Operation, target: core.ResourceId) !void {
    const value = capability_operation.state(operation);
    try value.opened();
    if (!value.staged) return error.WrongPhase;
    try contentChanged(&value.read, target);
}

pub fn resourceWithContent(operation: *capability_operation.Operation, changed: bool) !bool {
    return capability_operation.stagePreparedResource(capability_operation.state(operation), changed);
}
