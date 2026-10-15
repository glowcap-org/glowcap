//! Resource-owned pages prepared through one read window and staged as one content effect.
const std = @import("std");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");

pub const Schema = struct { id: u64, version: u32 = 1 };

/// Snapshot copies and staged edges for one complete graph replacement. Each
/// bound covers both the old and new population. Pages excludes the root,
/// payload_bytes includes it, and fields excludes resource bindings/page links.
/// The pinned root is borrowed. Caller candidates and references are separate.
pub fn allocationBound(pages: usize, payload_bytes: usize, fields: usize) !hosting.references.AllocationBound {
    const edges = try std.math.add(usize, pages, fields);
    var bound: hosting.references.AllocationBound = .{};
    try bound.include(@sizeOf(Prepared), @alignOf(Prepared), 1);
    try bound.include(try std.math.mul(usize, pages, @sizeOf(Page)), @alignOf(Page), 1);
    try bound.includeTotal(payload_bytes, 1, pages);
    try bound.includeTotal(try std.math.mul(usize, edges, loam.Edge.encodedSize()), 1, pages);
    try bound.include(try std.math.mul(usize, try std.math.add(usize, pages, 1), @sizeOf(loam.Edge)), @alignOf(loam.Edge), 1);
    try bound.includeTotal(try std.math.mul(usize, edges, @sizeOf(loam.Edge)), @alignOf(loam.Edge), pages);
    return bound;
}

/// The root's edge zero binds its canonical resource. Every remaining root
/// edge is an owned page link. Page edge zero binds that same resource, and
/// remaining page edges are capability fields. This registered role separation
/// prevents traversal through capability fields, including reference recipes.
pub const Spec = struct {
    schemas: []const Schema,
    max_pages: usize,
    max_payload_bytes: usize,
    max_edges: usize,
    /// Methods whose current requirements inspect canonical graph pages.
    /// Other requirements retain the root-only preparation cost. Invocation
    /// and forwarding reuse the same prepared graph without restoring fields.
    requirement_verbs: []const []const u8 = &.{},

    pub const max_schemas = 128;
    pub const max_requirement_verbs = 128;
    pub const max_requirement_verb_bytes = 256;

    pub fn requirementNeedsGraph(self: Spec, verb: []const u8) bool {
        for (self.requirement_verbs) |name| if (std.mem.eql(u8, name, verb)) return true;
        return false;
    }

    pub fn validate(self: Spec, store: *loam.Store, root: Schema) !void {
        if (self.requirement_verbs.len > max_requirement_verbs) return error.InvalidGraphLimits;
        for (self.requirement_verbs, 0..) |name, index| {
            if (name.len == 0 or name.len > 256) return error.InvalidGraphMethod;
            for (self.requirement_verbs[0..index]) |prior| if (std.mem.eql(u8, prior, name)) return error.DuplicateGraphMethod;
        }
        if (self.schemas.len == 0 or self.max_pages == 0 or self.max_payload_bytes == 0 or self.max_edges == 0) return error.InvalidGraphLimits;
        for (self.schemas, 0..) |schema, index| {
            for (self.schemas[0..index]) |prior| if (std.meta.eql(prior, schema)) return error.DuplicateSchema;
            _ = try registered(store, schema);
        }
        const root_schema = try registered(store, root);
        if (root_schema.max_edges == 0 or self.max_pages > root_schema.max_edges - 1) return error.InvalidGraphLimits;
    }

    fn accepts(self: Spec, schema: Schema) bool {
        for (self.schemas) |allowed| if (std.meta.eql(allowed, schema)) return true;
        return false;
    }
};

/// A borrowed token from this preparation, never a durable name or authority.
pub const PageHandle = opaque {};
pub const Page = struct {
    view: loam.RecordView,
    pub fn handle(self: *const Page) *const PageHandle {
        return @ptrCast(self);
    }
};

pub const Snapshot = struct {
    pages: []const Page,

    /// Token membership scans the bounded prepared page inventory. Edge
    /// selection is indexed and never walks preceding fields or restores them.
    pub fn field(self: Snapshot, handle: *const PageHandle, index: usize) !loam.Edge {
        return hosting.references.edgeAt(try self.page(handle), try std.math.add(usize, index, 1));
    }

    pub fn page(self: Snapshot, handle: *const PageHandle) !loam.RecordView {
        // Compare before dereferencing: foreign and retired tokens cannot select
        // an arbitrary row. A callback borrows these tokens only until return.
        for (self.pages) |*item| if (item.handle() == handle) return item.view;
        return error.ForeignPage;
    }
};

pub const Replacement = union(enum) {
    keep: *const PageHandle,
    /// Change payload while preserving this exact page's committed edges.
    update: struct { page: *const PageHandle, payload: []const u8 },
    write: struct {
        schema: Schema,
        payload: []const u8,
        fields: []const hosting.references.Replacement,
    },
};

pub const Prepared = struct {
    store: *loam.Store,
    arena: std.mem.Allocator,
    spec: Spec,
    root: loam.RecordView,
    revision: u64,
    incarnation: u64,
    resource: loam.ObjectId,
    snapshot: Snapshot,
    links: @TypeOf(@as(loam.RecordView, undefined).edges()),
    target: ?loam.ObjectId = null,
    index: usize = 0,
    payload_bytes: usize,
    edge_count: usize,
    pending: ?loam.Ticket = null,

    pub fn create(store: *loam.Store, arena: std.mem.Allocator, spec: Spec, root: loam.RecordView, resource: loam.ObjectId) !*Prepared {
        try spec.validate(store, .{ .id = root.schema, .version = root.schema_version });
        try binding(root, resource);
        if (root.edge_count - 1 > spec.max_pages) return error.GraphCapacity;
        var links = root.edges();
        _ = links.next();
        while (links.next()) |edge| {
            if (edge.strength != .strong or edge.restoration != .object or edge.target.eql(root.id)) return error.InvalidPageLink;
        }
        // Root and link counts are charged before the first child read.
        try capacity(spec, root.payload.len, root.edge_count);
        const self = try arena.create(Prepared);
        const pages = try arena.alloc(Page, root.edge_count - 1);
        links = root.edges();
        _ = links.next();
        self.* = .{ .store = store, .arena = arena, .spec = spec, .root = root, .revision = store.metadata.revision, .incarnation = store.metadata.incarnation, .resource = resource, .snapshot = .{ .pages = pages }, .links = links, .payload_bytes = root.payload.len, .edge_count = root.edge_count };
        return self;
    }

    /// Copy each validated page into the bounded retained call arena, then
    /// release its cache lease before loading the next page. Keeping all pages
    /// pinned would turn graph size into a cache-residency requirement. The
    /// snapshot must survive callback and transaction waits. The root's strong
    /// closure supplies collection custody, and hosting fences Store revisions.
    pub fn advanceCopying(self: *Prepared) !hosting.Preparation.Step {
        try self.current();
        if (self.pending != null) return .waiting;
        const pages: []Page = @constCast(self.snapshot.pages);
        while (self.index < pages.len) {
            if (self.target == null) self.target = self.links.next().?.target;
            const target = self.target.?;
            for (pages[0..self.index]) |page| if (page.view.id.eql(target)) return error.DuplicatePage;
            const acquired = self.store.acquire(target) catch |err| {
                if (err == error.PendingRead) return .waiting;
                return err;
            };
            const lease = switch (acquired) {
                .ready => |lease| lease,
                .read => |read| {
                    self.pending = read.ticket;
                    return .{ .read = read };
                },
            };
            defer self.store.release(lease) catch unreachable;
            const view = try self.store.currentView(lease);
            if (view.rooted or !self.spec.accepts(.{ .id = view.schema, .version = view.schema_version })) return error.InvalidPage;
            try binding(view, self.resource);
            const payload_bytes = try std.math.add(usize, self.payload_bytes, view.payload.len);
            const edge_count = try std.math.add(usize, self.edge_count, view.edge_count);
            try capacity(self.spec, payload_bytes, edge_count);
            var copy = view;
            copy.payload = try self.arena.dupe(u8, view.payload);
            copy.edge_bytes = try self.arena.dupe(u8, view.edge_bytes);
            pages[self.index] = .{ .view = copy };
            self.payload_bytes = payload_bytes;
            self.edge_count = edge_count;
            self.index += 1;
            self.target = null;
        }
        return .ready;
    }

    pub fn completeRead(self: *Prepared, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.pending == null or !std.meta.eql(ticket, self.pending.?)) return error.StaleCompletion;
        self.pending = null;
        try self.store.completeRead(ticket, result);
    }

    /// Admit the complete candidate before opening a transaction. New pages
    /// take fresh IDs inside that transaction. Retained pages keep their exact
    /// identity. No caller-selected object ID can enter the owned graph.
    pub fn replacement(self: *Prepared, payload: []const u8, pages: []const Replacement) !?Delta {
        if (!try self.validateCandidate(payload, pages)) return null;
        for (pages) |page| if (page == .write) {
            for (page.write.fields) |field| if (field == .edge) {
                if (field.edge.strength != .strong) return error.NotDurable;
                if (field.edge.target.store != self.store.metadata.store) return error.ForeignObject;
            };
        };
        return .{ .prepared = self, .payload = payload, .pages = pages };
    }

    /// The same shape admission runs before held-capability capture and after
    /// conversion into recipe proofs. Invalid schemas, tokens and aggregate
    /// capacity cannot acquire another capability retain or candidate spine.
    pub fn validateCandidate(self: *Prepared, payload: []const u8, pages: anytype) !bool {
        try self.current();
        if (self.index != self.snapshot.pages.len) return error.RecordUnloaded;
        if (pages.len > self.spec.max_pages) return error.GraphCapacity;
        var bytes = payload.len;
        var edges = try std.math.add(usize, pages.len, 1);
        var changed = !std.mem.eql(u8, payload, self.root.payload) or pages.len != self.snapshot.pages.len;
        const root_schema = try registered(self.store, .{ .id = self.root.schema, .version = self.root.schema_version });
        if (payload.len > root_schema.max_payload) return error.PayloadTooLarge;
        for (pages, 0..) |candidate, index| {
            switch (candidate) {
                .keep, .update => {
                    const handle = selected(candidate).?;
                    const view = try self.snapshot.page(handle);
                    for (pages[0..index]) |prior| if (selected(prior) == handle) return error.DuplicatePage;
                    const body = if (candidate == .update) candidate.update.payload else view.payload;
                    const schema = try registered(self.store, .{ .id = view.schema, .version = view.schema_version });
                    if (body.len > schema.max_payload) return error.PayloadTooLarge;
                    bytes = try std.math.add(usize, bytes, body.len);
                    edges = try std.math.add(usize, edges, view.edge_count);
                    if (!std.mem.eql(u8, body, view.payload)) changed = true;
                    if (index >= self.snapshot.pages.len or self.snapshot.pages[index].handle() != handle) changed = true;
                },
                .write => |write| {
                    if (!self.spec.accepts(write.schema)) return error.UnsupportedSchema;
                    const schema = try registered(self.store, write.schema);
                    if (write.payload.len > schema.max_payload) return error.PayloadTooLarge;
                    const count = try std.math.add(usize, write.fields.len, 1);
                    if (count > schema.max_edges) return error.TooManyEdges;
                    bytes = try std.math.add(usize, bytes, write.payload.len);
                    edges = try std.math.add(usize, edges, count);
                    changed = true;
                },
            }
            try capacity(self.spec, bytes, edges);
        }
        try capacity(self.spec, bytes, edges);
        return changed;
    }

    fn current(self: *Prepared) !void {
        if (self.store.metadata.revision != self.revision or self.store.metadata.incarnation != self.incarnation) return error.RevisionConflict;
        if (self.store.phase == .uncertain) return error.RecoveryRequired;
    }
};

pub const Delta = struct {
    prepared: *Prepared,
    payload: []const u8,
    pages: []const Replacement,

    pub fn stage(self: Delta, store: *loam.Store) !void {
        const prepared = self.prepared;
        if (prepared.store != store) return error.ForeignStore;
        try prepared.current();
        const links = try prepared.arena.alloc(loam.Edge, self.pages.len + 1);
        links[0] = .{ .target = prepared.resource };
        for (self.pages, links[1..]) |candidate, *link| {
            const id = switch (candidate) {
                .keep => |handle| (try prepared.snapshot.page(handle)).id,
                .update => |update| updated: {
                    const view = try prepared.snapshot.page(update.page);
                    if (!std.mem.eql(u8, update.payload, view.payload)) {
                        const edges = try prepared.arena.alloc(loam.Edge, view.edge_count);
                        var iterator = view.edges();
                        for (edges) |*edge| edge.* = iterator.next().?;
                        try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .schema_version = view.schema_version, .payload = update.payload, .edges = edges }, view.revision);
                    }
                    break :updated view.id;
                },
                .write => |write| fresh: {
                    const id = try store.allocateId();
                    const fields = try prepared.arena.alloc(loam.Edge, write.fields.len + 1);
                    fields[0] = .{ .target = prepared.resource };
                    for (write.fields, fields[1..]) |field, *edge| edge.* = switch (field) {
                        .edge => |committed| committed,
                        .saved => |saved| try saved.stage(store),
                    };
                    try store.putCopying(.{ .id = id, .revision = 0, .schema = write.schema.id, .schema_version = write.schema.version, .payload = write.payload, .edges = fields }, null);
                    break :fresh id;
                },
            };
            link.* = .{ .target = id };
        }
        const root = prepared.root;
        try store.putCopying(.{ .id = root.id, .revision = 0, .schema = root.schema, .schema_version = root.schema_version, .rooted = root.rooted, .payload = self.payload, .edges = links }, root.revision);
    }
};

fn selected(candidate: anytype) ?*const PageHandle {
    return switch (candidate) {
        .keep => |page| page,
        .update => |update| update.page,
        .write => null,
    };
}

fn registered(store: *loam.Store, schema: Schema) !loam.Schema {
    for (store.cache.schemas) |candidate| if (candidate.id == schema.id and candidate.version == schema.version) return candidate;
    return error.UnsupportedSchema;
}

fn binding(view: loam.RecordView, resource: loam.ObjectId) !void {
    const edge = hosting.references.edgeAt(view, 0) catch return error.InvalidResourceBinding;
    if (edge.restoration != .object or !edge.target.eql(resource)) return error.InvalidResourceBinding;
}

fn capacity(spec: Spec, bytes: usize, edges: usize) !void {
    if (bytes > spec.max_payload_bytes or edges > spec.max_edges) return error.GraphCapacity;
}
