//! Trusted managed changes join the caller's Loam transaction and recovery.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const Append = @import("append.zig").Append;
const putEncoded = @import("record.zig").putEncoded;

/// Creates an empty owner root in the caller's staging transaction. Opening
/// failure never replaces an owner; callers explicitly retain this reference.
pub fn createOwner(store: *loam.Store, owner: core.OwnerId, policy: core.Policy, options: Options) !loam.ObjectId {
    if (store.phase != .staging) return error.WrongPhase;
    errdefer store.abort() catch unreachable;
    const object = try store.allocateId();
    const header: records.OwnerRecord = .{ .owner = owner, .policy = policy, .max_resource_depth = options.max_resource_depth, .max_grant_depth = options.max_grant_depth, .max_grant_children = options.max_grant_children };
    try putEncoded(store, object, records.profile.owner, header, &.{}, null, true);
    return object;
}
pub const Options = struct { max_resource_depth: u32 = 64, max_grant_depth: u16 = 64, max_grant_children: u32 = 256 };

fn writable(view: *Read) !void {
    try view.opened();
    if (view.store.phase != .staging) return error.WrongPhase;
}

fn headerRow(view: *Read, header: records.OwnerRecord) !void {
    const row = try view.store.currentView(view.header_lease.?);
    var edges: [3]loam.Edge = undefined;
    try putEncoded(view.store, view.owner_object, records.profile.owner, header, header.edges(&edges), row.revision, true);
}

fn loaded(view: *Read, target: @import("read.zig").Target) !loam.RecordView {
    const binding = (try view.binding(target)) orelse return error.RecordUnloaded;
    return view.store.currentView(binding.lease orelse return error.Gone);
}

pub fn appendResource(append: *Append, kind: core.KindId, parent: ?core.ResourceId) !core.ResourceId {
    const view = append.view;
    try writable(view);
    if (append.family != .resource or append.count != 4 or append.staged or append.cancelled) return error.WrongPhase;
    var resources = try view.resourceView();
    var edges: [1]loam.Edge = undefined;
    if (parent) |id| {
        if (resources.max_depth == 0) return error.DepthLimit;
        resources.max_depth -= 1;
        _ = try resources.isDescendant(id, id);
        edges[0] = .{ .target = (try loaded(view, .{ .resource = id })).id };
    }
    var header = view.header;
    header.version.resources = @fromBackingInt(std.math.add(u64, @backingInt(header.version.resources), 1) catch return error.RevisionExhausted);
    const id: core.ResourceId = .{ .owner = header.owner, .slot = append.slot, .generation = 1 };
    // From here, a failure discards the entire shared content/access batch.
    errdefer view.store.abort() catch unreachable;
    const object = try view.store.allocateId();
    try putEncoded(view.store, object, records.profile.resource, records.ResourceRecord{ .revision = header.version.resources, .resource = .{ .id = id, .kind = kind, .parent = parent } }, edges[0..@intFromBool(parent != null)], null, false);
    header.resources = try append.stageDirectory(object);
    header.next_resource += 1;
    try headerRow(view, header);
    return id;
}

/// Stages a prepared grant with its parent, owner revision, and latest event.
/// Issuance needs a prepared append path. Plans and this function are trusted
/// owner operations; use/control authority is admitted before calling them.
pub const StagedGrant = struct { change: core.GrantPlan.Change, object: loam.ObjectId };

pub fn grant(view: *Read, plan: *const core.GrantPlan, append: ?*Append) !StagedGrant {
    try writable(view);
    var grants = try view.grantView();
    const changes = try plan.changes(&grants);
    const issuing = changes.expected == null;
    if (issuing) {
        const path = append orelse return error.WrongPhase;
        if (path.view != view or path.family != .grant or path.count != 4 or path.staged or path.cancelled or path.slot != plan.grant.slot or plan.grant.generation != 1) return error.WrongPhase;
    } else if (append != null) return error.WrongPhase;
    const original = if (issuing) null else try loaded(view, .{ .grant = plan.grant });
    const parent = if (changes.parent_record) |record| try loaded(view, .{ .grant = record.id }) else null;
    var edges: [514]loam.Edge = undefined;
    var edge_count: usize = 0;
    if (plan.delta == .status) {
        var it = original.?.edges();
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
    }
    var header = view.header;
    header.version = changes.event.version;
    errdefer view.store.abort() catch unreachable;
    const object = if (original) |row| row.id else try view.store.allocateId();
    try putEncoded(view.store, object, records.profile.grant, records.GrantRecord{ .grant = changes.record }, edges[0..edge_count], if (original) |row| row.revision else null, false);
    if (parent) |row| {
        var parent_edges: [514]loam.Edge = undefined;
        var n: usize = 0;
        var it = row.edges();
        while (it.next()) |edge| {
            if (n == parent_edges.len) return error.InvalidRecord;
            parent_edges[n] = edge;
            n += 1;
        }
        try putEncoded(view.store, row.id, records.profile.grant, records.GrantRecord{ .grant = changes.parent_record.? }, parent_edges[0..n], row.revision, false);
    }
    if (append) |path| {
        header.grants = try path.stageDirectory(object);
        header.next_grant += 1;
    }
    const event = try view.store.allocateId();
    try putEncoded(view.store, event, records.profile.change, records.ChangeRecord{ .change = changes.event }, &.{.{ .target = object }}, null, false);
    header.change = event;
    try headerRow(view, header);
    return .{ .change = changes.event, .object = object };
}
