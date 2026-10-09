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
/// failure never replaces an owner; callers explicitly retain this reference.
pub fn createOwner(store: *loam.Store, owner: core.OwnerId, policy: core.Policy, options: Options) !loam.ObjectId {
    if (store.phase != .staging) return error.WrongPhase;
    if (options.max_resource_depth > 64 or options.max_grant_depth > 64) return error.DepthLimit;
    errdefer store.abort() catch unreachable;
    const object = try store.allocateId();
    const header: records.OwnerRecord = .{ .owner = owner, .policy = policy, .max_resource_depth = options.max_resource_depth, .max_grant_depth = options.max_grant_depth, .max_grant_children = options.max_grant_children };
    try putEncoded(store, object, records.profile.owner, header, &.{}, null, true);
    return object;
}
pub const Options = struct { max_resource_depth: u32 = 64, max_grant_depth: u16 = 64, max_grant_children: u32 = 256 };

fn writable(view: *Read) !void {
    try view.prepareHistory();
    if (view.store.phase != .staging) return error.WrongPhase;
}

fn headerRow(view: *Read, header: records.OwnerRecord) !void {
    const expected: ?u64 = if (try view.store.proposed(view.owner_object)) |staged|
        staged.expected
    else
        view.header_revision.?;
    var edges: [records.OwnerRecord.max_edges]loam.Edge = undefined;
    try putEncoded(view.store, view.owner_object, records.profile.owner, header, header.edges(&edges), expected, true);
    view.transaction = view.store.ticket;
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
    const view = append.view;
    try writable(view);
    if (append.directory.family != .resource or append.directory.count != 4 or append.directory.staged or append.directory.cancelled) return error.WrongPhase;
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
    header.version.resources = @fromBackingInt(std.math.add(u64, @backingInt(header.version.resources), 1) catch return error.RevisionExhausted);
    const id: core.ResourceId = .{ .owner = header.owner, .slot = append.directory.slot, .generation = 1 };
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
    try history.touchResources(view, parent_path.slice(), false);
    var path = parent_path;
    if (path.count == path.ids.len) return error.DepthLimit;
    std.mem.copyBackwards(core.ResourceId, path.ids[1 .. path.count + 1], path.ids[0..path.count]);
    path.ids[0] = id;
    path.count += 1;
    try history.append(view, .{ .resource = .{ .id = id, .kind = .created, .before = &.{}, .after = path.slice() } });
    try headerRow(view, view.header);
    return id;
}

/// Stages a prepared grant and its ancestry in the shared retained batch.
/// Issuance needs a prepared append path. Plans and this function are trusted
/// owner operations; use/control authority is admitted before calling them.
pub const StagedGrant = struct { change: core.GrantPlan.Change, object: loam.ObjectId };

pub fn grant(view: *Read, plan: *const core.GrantPlan, append: ?*Append) !StagedGrant {
    try writable(view);
    var grants = try view.grantView();
    const event_parent = if (plan.delta == .issue) plan.delta.issue.parent else (try grants.get(plan.grant)).parent;
    var ancestors: [records.ChangeBatchRecord.max_path]core.GrantId = undefined;
    ancestors[0] = plan.grant;
    var ancestor_count: usize = 1;
    var ancestry = grants.ancestry(event_parent orelse plan.grant);
    if (event_parent != null) while (try ancestry.next()) |entry| {
        if (ancestor_count == ancestors.len) return error.DepthLimit;
        ancestors[ancestor_count] = entry.id;
        ancestor_count += 1;
    };
    const changes = try plan.changes(&grants);
    const issuing = changes.expected == null;
    if (issuing) {
        const path = append orelse return error.WrongPhase;
        if (path.view != view or path.directory.family != .grant or path.directory.count != 4 or path.directory.staged or path.directory.cancelled or path.directory.slot != plan.grant.slot or plan.grant.generation != 1) return error.WrongPhase;
    } else if (append != null) return error.WrongPhase;
    const original = if (issuing) null else try rowOf(view, .{ .grant = plan.grant });
    // Policy edits preserve lifecycle history. Separate scratch keeps the
    // plan's borrowed selections intact while decoding the prior stamp.
    const status_stamp = if (issuing or plan.delta == .status) try history.stamp(view, @backingInt(changes.record.revision)) else blk: {
        var scratch: [2 * core.max_scope_objects * @sizeOf(core.ResourceId)]u8 align(@alignOf(core.ResourceId)) = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&scratch);
        var prior = try records.GrantRecord.decodeOwned(fixed.allocator(), original.?.view.payload);
        defer prior.deinit(fixed.allocator());
        break :blk prior.value.lifecycle;
    };
    const parent = if (changes.parent_record) |parent_record| try rowOf(view, .{ .grant = parent_record.id }) else null;
    var child_root: ?loam.ObjectId = null;
    if (original) |row| {
        var prior = try records.GrantRecord.decodeOwned(view.allocator, row.view.payload);
        defer prior.deinit(view.allocator);
        child_root = prior.value.children;
    }
    var edges: [515]loam.Edge = undefined;
    var edge_count: usize = 0;
    if (plan.delta == .status or plan.delta == .label) {
        var it = original.?.view.edges();
        while (it.next()) |edge| {
            if (edge_count == edges.len) return error.InvalidRecord;
            edges[edge_count] = edge;
            edge_count += 1;
        }
    } else {
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
    }
    var header = view.header;
    header.version = changes.event.version;
    errdefer view.store.abort() catch unreachable;
    view.transaction = view.store.ticket;
    const object = if (original) |row| row.view.id else try view.store.allocateId();
    try putEncoded(view.store, object, records.profile.grant, records.GrantRecord{ .children = child_root, .grant = changes.record, .lifecycle = status_stamp, .authority = try history.stamp(view, @backingInt(header.version.grants)), .inventory = try history.stamp(view, @backingInt(header.version.grants)) }, edges[0..edge_count], if (original) |row| row.expected else null, false);
    if (parent) |row| {
        var parent_edges: [515]loam.Edge = undefined;
        var n: usize = 0;
        var it = row.view.edges();
        while (it.next()) |edge| {
            if (n == parent_edges.len) return error.InvalidRecord;
            parent_edges[n] = edge;
            n += 1;
        }
        var parent_record = try records.GrantRecord.decodeOwned(view.allocator, row.view.payload);
        defer parent_record.deinit(view.allocator);
        const child_index = append.?.child orelse return error.NotPrepared;
        try child_index.rebaseProposed(parent_record.value.children);
        const root = (try child_index.stage(object)).?;
        if (parent_record.value.children) |old| {
            if (n == 0 or !parent_edges[n - 1].target.eql(old)) return error.InvalidRecord;
            parent_edges[n - 1] = .{ .target = root };
        } else {
            parent_edges[n] = .{ .target = root };
            n += 1;
        }
        parent_record.value.children = root;
        parent_record.value.grant.child_count = changes.parent_record.?.child_count;
        parent_record.value.grant.revision = changes.parent_record.?.revision;
        parent_record.value.inventory = try history.stamp(view, @backingInt(header.version.grants));
        try putEncoded(view.store, row.view.id, records.profile.grant, parent_record.value, parent_edges[0..n], row.expected, false);
    }
    if (append) |path| {
        header.grants = try path.stageDirectory(object);
        header.next_grant += 1;
    }
    view.header = header;
    try history.touchGrants(view, ancestors[1..ancestor_count]);
    try history.append(view, .{ .grant = .{ .change = changes.event, .path = ancestors[0..ancestor_count] } });
    try headerRow(view, view.header);
    return .{ .change = changes.event, .object = object };
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
    try headerRow(view, view.header);
}

/// The caller prepared this path before invoking the application method.
pub fn contentChanged(view: *Read, target: core.ResourceId) !void {
    try writable(view);
    const path = try history.resourcePath(view, target);
    errdefer view.store.abort() catch unreachable;
    view.transaction = view.store.ticket;
    view.header.version.resources = @fromBackingInt(std.math.add(u64, @backingInt(view.header.version.resources), 1) catch return error.RevisionExhausted);
    try history.touchResources(view, path.slice(), true);
    try history.append(view, .{ .content = .{ .id = target, .path = path.slice() } });
    try headerRow(view, view.header);
}

/// Load the immutable ancestry needed to stamp and journal a prepared grant.
pub fn prepareGrant(view: *Read, plan: *const core.GrantPlan) !void {
    try view.prepareHistory();
    var grants = try view.grantView();
    const parent = if (plan.delta == .issue) plan.delta.issue.parent else @as(?core.GrantId, plan.grant);
    if (parent) |id| {
        var path = grants.ancestry(id);
        while (try path.next()) |_| {}
    }
}

/// Hosting has admitted the method and exact endpoint target before requesting
/// this owner-only preparation. It grants no public capability authority.
pub fn prepareContent(operation: *@import("capability_operation.zig").Operation, target: core.ResourceId) !void {
    const value = @import("capability_operation.zig").state(operation);
    try value.opened();
    if (value.staged or (value.prepared != .none and value.prepared != .resource)) return error.WrongPhase;
    if (value.children != 0) return error.Busy;
    try value.read.?.prepareHistory();
    _ = try history.resourcePath(&value.read.?, target);
}

pub fn content(operation: *@import("capability_operation.zig").Operation, target: core.ResourceId) !void {
    const value = @import("capability_operation.zig").state(operation);
    try value.opened();
    try value.unprepared();
    try contentChanged(&value.read.?, target);
    value.staged = true;
}

pub fn resourceWithContent(operation: *@import("capability_operation.zig").Operation, changed: bool) !bool {
    return @import("capability_operation.zig").stagePreparedResource(@import("capability_operation.zig").state(operation), changed);
}
