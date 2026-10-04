//! All managed effects join one bounded owner batch in the Store transaction.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Read = @import("read.zig").Read;
const record = @import("record.zig");
const Batch = records.ChangeBatchRecord;

/// The first effect allocates a batch; later effects reuse that batch's
/// position. Stamps and retained effects share this one sequencing authority.
pub fn position(view: *Read) !u64 {
    try view.current();
    if (view.store.phase != .staging or !view.history_ready) return error.WrongPhase;
    if (view.history.count != 0) {
        const latest = view.history.batches[view.history.count - 1];
        if ((try view.store.proposed(latest)) != null) return view.history.next_sequence - 1;
    }
    return view.history.next_sequence;
}

pub fn stamp(view: *Read, revision: u64) !records.ChangeStamp {
    return .{ .revision = revision, .position = try position(view) };
}

pub fn append(view: *Read, effect: Batch.Effect) !void {
    try view.current();
    if (view.store.phase != .staging or !view.history_ready) return error.WrongPhase;
    const store = view.store;
    const revision = std.math.add(u64, store.metadata.revision, 1) catch return error.RevisionExhausted;
    var retained = view.history;
    var previous: ?Batch.Owned = null;
    defer if (previous) |*owned| owned.deinit(store.allocator);
    var effects: [Batch.max_effects]Batch.Effect = undefined;
    var count: usize = 0;
    var object: ?loam.ObjectId = null;
    const sequence: u64 = try position(view);
    if (retained.count != 0) {
        const latest = retained.batches[retained.count - 1];
        if (try store.proposed(latest)) |proposal| {
            previous = try Batch.decodeOwned(store.allocator, proposal.view);
            if (previous.?.value.owner != view.header.owner or previous.?.value.commit_revision != revision) return error.InvalidRecord;
            const prior = previous.?.value.effects;
            if (prior.len == effects.len) return error.ChangeCapacity;
            @memcpy(effects[0..prior.len], prior);
            count = prior.len;
            object = latest;
            if (previous.?.value.sequence != sequence) return error.InvalidRecord;
        }
    }
    if (object == null) {
        object = try store.allocateId();
        if (try retained.append(object.?) != sequence) return error.InvalidRecord;
    }
    effects[count] = effect;
    count += 1;
    try record.putEncoded(store, object.?, records.profile.change_batch, Batch{ .owner = view.header.owner, .commit_revision = revision, .sequence = sequence, .effects = effects[0..count] }, &.{}, null, false);
    const root = view.header.history orelse try store.allocateId();
    var edges: [records.ChangeHistoryRecord.capacity]loam.Edge = undefined;
    try record.putEncoded(store, root, records.profile.change_history, retained, try retained.edges(&edges), view.history_expected, false);
    view.header.history = root;
    view.history = retained;
}

pub const ResourcePath = struct {
    ids: [Batch.max_path]core.ResourceId = undefined,
    count: usize = 0,

    pub fn slice(self: *const ResourcePath) []const core.ResourceId {
        return self.ids[0..self.count];
    }
};

/// Preparation loads every path row through Read's normal fault protocol.
pub fn resourcePath(view: *Read, target: core.ResourceId) !ResourcePath {
    var resources = try view.resourceView();
    var path: ResourcePath = .{};
    var cursor: ?core.ResourceId = target;
    while (cursor) |id| {
        if (path.count == path.ids.len) return error.DepthLimit;
        for (path.slice()) |prior| if (prior.eql(id)) return error.InvalidRecord;
        const model = try resources.get(id);
        path.ids[path.count] = id;
        path.count += 1;
        cursor = model.parent;
    }
    return path;
}

pub fn row(view: *Read, target: @import("read.zig").Target) !Read.Row {
    try view.current();
    for (view.bindings[0..view.count]) |binding| if (std.meta.eql(binding.target, target))
        return (try Read.rowFor(view.store, binding)) orelse return error.Gone;
    return error.RecordUnloaded;
}

pub fn touchResources(view: *Read, path: []const core.ResourceId, content: bool) !void {
    for (path, 0..) |id, index| {
        const found = try row(view, .{ .resource = id });
        var value = try records.ResourceRecord.decode(found.view);
        const revision = @backingInt(view.header.version.resources);
        if (value.subtree.revision == revision and (!content or index != 0 or value.content.revision == revision)) continue;
        value.revision = view.header.version.resources;
        value.subtree = try stamp(view, @backingInt(value.revision));
        if (content and index == 0) value.content = try stamp(view, @backingInt(value.revision));
        var edges = found.view.edges();
        const parent = if (value.resource.parent != null) edges.next().?.target else null;
        try record.putResource(view.store, found.view.id, value, parent, found.expected);
    }
}

pub fn touchGrants(view: *Read, path: []const core.GrantId) !void {
    for (path) |id| {
        const found = try row(view, .{ .grant = id });
        var value = try records.GrantRecord.decodeOwned(view.allocator, found.view.payload);
        defer value.deinit(view.allocator);
        if (value.value.inventory.revision == @backingInt(view.header.version.grants)) continue;
        value.value.grant.revision = view.header.version.grants;
        value.value.inventory = try stamp(view, @backingInt(view.header.version.grants));
        var edges: [514]loam.Edge = undefined;
        var iterator = found.view.edges();
        var count: usize = 0;
        while (iterator.next()) |edge| {
            if (count == edges.len) return error.InvalidRecord;
            edges[count] = edge;
            count += 1;
        }
        try record.putEncoded(view.store, found.view.id, records.profile.grant, value.value, edges[0..count], found.expected, false);
    }
}
