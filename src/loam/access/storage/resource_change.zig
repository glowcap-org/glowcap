//! Resource moves inspect descendants with bounded residency before staging.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const read = @import("read.zig");
const DirectoryEdit = @import("directory_edit.zig").DirectoryEdit;
const DirectoryQuery = @import("directory_query.zig").DirectoryQuery;
const Load = @import("load.zig").Load;
const record = @import("record.zig");
const history = @import("history.zig");

pub const ResourceChange = struct {
    view: *read.Read,
    base: core.Revision,
    source: read.Read.Row,
    original: records.ResourceRecord,
    action: Action,
    before: history.ResourcePath,
    after: history.ResourcePath,
    old_parent: ?read.Read.Row = null,
    new_parent: ?read.Read.Row = null,
    old_index: DirectoryEdit,
    new_index: ?*DirectoryEdit = null,
    frames: []Frame,
    count: usize = 0,
    height: u32 = 0,
    load: Load = .{},
    changed: bool,
    content_changed: bool = false,
    ready: bool = false,
    staged: bool = false,
    cancelled: bool = false,
    pub const Action = union(enum) { move: ?core.ResourceId, delete_leaf };
    const Frame = struct { id: core.ResourceId, query: DirectoryQuery, entry: ?DirectoryQuery.Entry = null };

    /// Trusted structural preparation. Capability operations admit the source
    /// and both placement parents before creating this change.
    pub fn init(view: *read.Read, target: core.ResourceId, action: Action) !ResourceChange {
        if (view.exclusive != .none) return error.Busy;
        var resources = try view.resourceView();
        const canonical = try resources.get(target);
        const source = try row(view, target);
        const original = try records.ResourceRecord.decode(source.view);
        if (!original.live) return error.Gone;
        const old_parent = if (canonical.parent) |parent| try row(view, parent) else null;
        var new_parent: ?read.Read.Row = null;
        const changed = switch (action) {
            .move => |parent| value: {
                const changed = try resources.checkReparent(target, parent, 0);
                if (parent) |id| new_parent = try row(view, id);
                break :value changed;
            },
            .delete_leaf => value: {
                if (original.children != null) return error.HasChildren;
                break :value true;
            },
        };
        if (changed) try view.prepareHistory();
        const before = try history.resourcePath(view, target);
        var after: history.ResourcePath = .{};
        if (action == .move) {
            if (action.move) |parent| after = try history.resourcePath(view, parent);
            if (after.count == after.ids.len) return error.DepthLimit;
            std.mem.copyBackwards(core.ResourceId, after.ids[1 .. after.count + 1], after.ids[0..after.count]);
            after.ids[0] = target;
            after.count += 1;
        }
        const old_root = if (old_parent) |parent| (try records.ResourceRecord.decode(parent.view)).children else view.header.roots;
        const frame_count = if (changed and action == .move)
            std.math.add(usize, view.header.max_resource_depth, 1) catch return error.DepthLimit
        else
            0;
        const frames = try view.allocator.alloc(Frame, frame_count);
        errdefer view.allocator.free(frames);
        var next: ?*DirectoryEdit = null;
        errdefer if (next) |index| view.allocator.destroy(index);
        if (changed and action == .move) {
            next = try view.allocator.create(DirectoryEdit);
            const root = if (new_parent) |parent| (try records.ResourceRecord.decode(parent.view)).children else view.header.roots;
            next.?.* = DirectoryEdit.init(view, .resource, root, target.slot);
        }
        var self: ResourceChange = .{ .view = view, .base = view.header.version.resources, .source = source, .original = original, .action = action, .before = before, .after = after, .old_parent = old_parent, .new_parent = new_parent, .old_index = DirectoryEdit.init(view, .resource, old_root, target.slot), .new_index = next, .frames = frames, .changed = changed };
        if (frames.len != 0) {
            frames[0] = .{ .id = target, .query = DirectoryQuery.init(view, original.children) };
            self.count = 1;
        }
        view.exclusive = .resource_change;
        return self;
    }

    fn current(self: *ResourceChange) !void {
        try self.view.opened();
        if (self.cancelled) return error.Cancelled;
        if (self.base != self.view.header.version.resources) return error.RevisionConflict;
    }

    pub fn advance(self: *ResourceChange) !read.Step {
        try self.current();
        if (self.staged) return error.WrongPhase;
        if (self.ready) return .ready;
        if (!self.changed) {
            self.ready = true;
            return .ready;
        }
        for (0..64) |_| {
            if (self.count == 0) break;
            const frame = &self.frames[self.count - 1];
            if (frame.entry == null) {
                const step = try frame.query.advance();
                if (step != .ready) return step;
                frame.entry = frame.query.entry;
                if (frame.entry == null) {
                    if (!frame.query.done) return error.InvalidRecord;
                    self.count -= 1;
                    continue;
                }
            }
            const entry = frame.entry.?;
            const loaded = switch (try self.load.resolve(self.view.store, entry.object)) {
                .read => |request| return .{ .read = request },
                .waiting => return .waiting,
                .ready => |resolved| resolved,
            };
            defer loaded.release(self.view.store);
            const stored = loaded.view;
            if (stored.schema != records.profile.resource or stored.schema_version != 1) return error.InvalidRecord;
            const child = try records.ResourceRecord.decode(stored);
            if (!child.live or child.resource.id.owner != frame.id.owner or child.resource.id.slot != entry.slot or child.resource.parent == null or !child.resource.parent.?.eql(frame.id)) return error.InvalidRecord;
            frame.entry = null;
            if (self.count == self.frames.len) return error.DepthLimit;
            self.height = @max(self.height, @as(u32, @intCast(self.count)));
            self.frames[self.count] = .{ .id = child.resource.id, .query = DirectoryQuery.init(self.view, child.children) };
            self.count += 1;
        }
        if (self.count != 0) return .waiting; // Yield bounded CPU work to the attachment.
        if (self.action == .move) {
            var resources = try self.view.resourceView();
            _ = try resources.checkReparent(self.original.resource.id, self.action.move, self.height);
        }
        const old = try self.old_index.advance();
        if (old != .ready) return old;
        if (self.old_index.cursor == null or !self.old_index.cursor.?.eql(self.source.view.id)) return error.InvalidRecord;
        if (self.new_index) |index| {
            const next = try index.advance();
            if (next != .ready) return next;
            if (index.cursor != null) return error.IdentityCollision;
        }
        self.ready = true;
        return .ready;
    }

    pub fn completeRead(self: *ResourceChange, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.load.pending != null) return self.load.complete(self.view.store, ticket, result);
        if (self.count != 0 and self.frames[self.count - 1].query.load.pending != null) return self.frames[self.count - 1].query.completeRead(ticket, result);
        if (self.old_index.load.pending != null) return self.old_index.completeRead(ticket, result);
        if (self.new_index) |index| if (index.load.pending != null) return index.completeRead(ticket, result);
        return error.StaleCompletion;
    }

    pub fn cancel(self: *ResourceChange) !void {
        try self.load.cancel(self.view.store);
        for (self.frames[0..self.count]) |*frame| try frame.query.load.cancel(self.view.store);
        try self.old_index.cancel();
        if (self.new_index) |index| try index.cancel();
        self.cancelled = true;
    }

    pub fn deinit(self: *ResourceChange) !void {
        if (self.load.pending != null or self.old_index.load.pending != null) return error.Busy;
        for (self.frames[0..self.count]) |frame| if (frame.query.load.pending != null) return error.Busy;
        if (self.new_index) |index| {
            if (index.load.pending != null) return error.Busy;
            self.view.allocator.destroy(index);
        }
        self.view.allocator.free(self.frames);
        self.view.exclusive = .none;
        self.* = undefined;
    }

    pub fn stage(self: *ResourceChange) !bool {
        try self.current();
        if (!self.ready or self.staged or self.view.store.phase != .staging) return error.WrongPhase;
        self.staged = true;
        if (!self.changed) return false;
        var header = self.view.header;
        header.version.resources = @fromBackingInt(std.math.add(u64, @backingInt(self.base), 1) catch return error.RevisionExhausted);
        const store = self.view.store;
        errdefer store.abort() catch unreachable;
        self.view.transaction = store.ticket;
        const old = try self.old_index.stage(null);
        if (self.old_parent) |parent| try record.putChildren(store, parent, old, header.version.resources) else header.roots = old;
        var updated = self.original;
        updated.revision = header.version.resources;
        updated.placement = try history.stamp(self.view, @backingInt(updated.revision));
        updated.subtree = try history.stamp(self.view, @backingInt(updated.revision));
        if (self.content_changed) updated.content = try history.stamp(self.view, @backingInt(updated.revision));
        var parent_object: ?loam.ObjectId = null;
        switch (self.action) {
            .move => |parent| {
                const next = try self.new_index.?.stage(self.source.view.id);
                if (self.new_parent) |destination| {
                    try record.putChildren(store, destination, next, header.version.resources);
                    parent_object = destination.view.id;
                } else header.roots = next;
                updated.resource.parent = parent;
            },
            .delete_leaf => {
                updated.live = false;
                updated.resource.parent = null;
                updated.children = null;
            },
        }
        try record.putResource(store, self.source.view.id, updated, parent_object, self.source.expected);
        const expected = if (try store.proposed(self.view.owner_object)) |proposal| proposal.expected else self.view.header_revision.?;
        var roots: [records.OwnerRecord.max_edges]loam.Edge = undefined;
        self.view.header = header;
        try history.touchResources(self.view, self.before.slice()[1..], false);
        try history.touchResources(self.view, self.after.slice()[@min(1, self.after.count)..], false);
        try history.append(self.view, .{ .resource = .{ .id = self.original.resource.id, .kind = if (self.action == .move) .moved else .deleted, .before = self.before.slice(), .after = self.after.slice() } });
        if (self.content_changed) try history.append(self.view, .{ .content = .{ .id = self.original.resource.id, .path = if (self.action == .move) self.after.slice() else self.before.slice() } });
        try record.putEncoded(store, self.view.owner_object, records.profile.owner, self.view.header, self.view.header.edges(&roots), expected, true);
        self.view.transaction = store.ticket;
        return true;
    }

    fn row(view: *read.Read, target: core.ResourceId) !read.Read.Row {
        var resources = try view.resourceView();
        _ = try resources.get(target);
        const binding = (try view.binding(.{ .resource = target })).?;
        return (try read.Read.rowFor(view.store, binding)) orelse error.Gone;
    }
};
