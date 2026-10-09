//! A bounded managed working set pins Loam records and resumes directory faults.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Page = records.DirectoryPage;
const Load = @import("load.zig").Load;
const Registry = @import("identity_registry.zig").Registry;

pub const Target = union(Page.Family) {
    resource: core.ResourceId,
    grant: core.GrantId,
    identity: struct { owner: core.OwnerId, slot: u32 },

    pub fn slot(self: Target) u32 {
        return switch (self) {
            inline else => |id| id.slot,
        };
    }
    pub fn owner(self: Target) core.OwnerId {
        return switch (self) {
            inline else => |id| id.owner,
        };
    }
};
pub const Binding = struct { target: Target, lease: ?loam.Lease, absence: core.ResourceView.Absence = .unknown, object: ?loam.ObjectId = null };
pub const Step = union(enum) { ready, read: loam.Read, waiting };

pub const Read = struct {
    allocator: std.mem.Allocator,
    store: *loam.Store,
    owner_object: loam.ObjectId,
    snapshot: u64,
    incarnation: u64,
    transaction: ?loam.Ticket = null,
    header: records.OwnerRecord = undefined,
    header_revision: ?u64 = null,
    header_ready: bool = false,
    history: records.ChangeHistoryRecord = undefined,
    history_ready: bool = false,
    history_requested: bool = false,
    history_expected: ?u64 = null,
    identities: ?*Registry = null,
    bindings: []Binding,
    count: usize = 0,
    load: Load = .{},
    demand: ?Target = null,
    cursor: ?Cursor = null,
    cancelled: bool = false,
    exclusive: enum { none, append, resource_change } = .none,
    grant_scratch: [2 * core.max_scope_objects * @sizeOf(core.ResourceId)]u8 align(@alignOf(core.ResourceId)) = undefined,
    // Grants with scalar scopes need no selection scratch. Reuse those bytes
    // for one owned committed portrait; selected scopes and mutable proposals
    // decode afresh. Clear the marker before any decoder can reuse the bytes.
    grant_cache_valid: bool = false,
    const GrantCache = struct { object: loam.ObjectId, revision: u64, grant: core.GrantView.Record };

    /// Every decoder borrows this same fixed selection buffer. Taking it
    /// invalidates the scalar portrait before inventory or grant decoding can
    /// overwrite its key. Resource reads leave selected-scope borrows intact.
    pub fn grantScratch(self: *Read) *@FieldType(Read, "grant_scratch") {
        self.grant_cache_valid = false;
        return &self.grant_scratch;
    }

    const Cursor = struct { node: ?loam.ObjectId, level: u3 = 0 };

    /// Store and operation stay at stable addresses during view use. Capacity
    /// bounds pinned model records; directory pages borrow one extra cache slot.
    pub fn init(allocator: std.mem.Allocator, store: *loam.Store, owner: loam.ObjectId, capacity: usize) !Read {
        if (owner.store != store.metadata.store) return error.ForeignObject;
        if (capacity == 0 or capacity > store.limits.max_leases -| 1) return error.InvalidLimits;
        if (store.phase == .uncertain) return error.RecoveryRequired;
        return .{ .allocator = allocator, .store = store, .owner_object = owner, .snapshot = store.metadata.revision, .incarnation = store.metadata.incarnation, .bindings = try allocator.alloc(Binding, capacity) };
    }

    pub fn hasPendingRead(self: *const Read) bool {
        return self.load.pending != null or (if (self.identities) |registry| registry.pending() else false);
    }

    pub fn deinit(self: *Read) !void {
        if (self.hasPendingRead() or self.exclusive != .none) return error.Busy;
        if (self.identities) |registry| {
            try registry.deinit();
            self.allocator.destroy(registry);
        }
        for (self.bindings[0..self.count]) |entry| if (entry.lease) |lease| try self.store.release(lease);
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn cancel(self: *Read) !void {
        try self.load.cancel(self.store);
        if (self.identities) |registry| try registry.cancel();
        self.cancelled = true;
    }

    pub fn completeRead(self: *Read, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.load.pending != null) return self.load.complete(self.store, ticket, result);
        if (self.identities) |registry| return registry.completeRead(ticket, result);
        return error.StaleCompletion;
    }

    pub fn current(self: *const Read) !void {
        if (self.cancelled) return error.Cancelled;
        if (self.store.phase == .uncertain) return error.RecoveryRequired;
        if (self.snapshot != self.store.metadata.revision or self.incarnation != self.store.metadata.incarnation) return error.RevisionConflict;
        if (self.transaction) |ticket| {
            if (self.store.phase != .staging or !std.meta.eql(self.store.ticket, @as(?loam.Ticket, ticket))) return error.RevisionConflict;
        }
    }

    pub fn advance(self: *Read) !Step {
        try self.current();
        if (!self.header_ready) {
            if (try self.store.proposed(self.owner_object)) |staged| {
                // A composed transaction stages the owner header itself: read
                // this transaction's own proposal so a further managed change
                // prepares against the deltas already staged here.
                self.header = try records.OwnerRecord.decode(staged.view);
                self.transaction = self.store.ticket;
                self.header_ready = true;
            } else {
                const lease = switch (try self.load.acquire(self.store, self.owner_object)) {
                    .ready => |lease| lease,
                    .read => |read| return .{ .read = read },
                    .waiting => return .waiting,
                };
                defer self.store.release(lease) catch unreachable;
                const committed = try self.store.currentView(lease);
                self.header = try records.OwnerRecord.decode(committed);
                self.header_revision = committed.revision;
                self.header_ready = true;
            }
        }
        if (!self.history_ready and (self.history_requested or self.header.history == null)) {
            if (self.header.history) |id| {
                const loaded = switch (try self.load.resolve(self.store, id)) {
                    .ready => |row| row,
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                };
                defer loaded.release(self.store);
                self.history = try records.ChangeHistoryRecord.decode(loaded.view);
                if (self.history.owner != self.header.owner) return error.InvalidRecord;
                self.history_expected = if (try self.store.proposed(id)) |proposal| proposal.expected else loaded.view.revision;
            } else self.history = .{ .owner = self.header.owner };
            self.history_ready = true;
        }
        if (self.identities) |registry| {
            const step = try registry.advance();
            if (step != .ready) return step;
        }
        const target = self.demand orelse return .ready;
        if (self.count == self.bindings.len) return error.WorkingSetCapacity;
        if (self.cursor == null) self.cursor = .{ .node = switch (target) {
            .resource => self.header.resources,
            .grant => self.header.grants,
            .identity => self.header.identities,
        } };
        const cursor = &self.cursor.?;
        while (cursor.node) |node| {
            if (cursor.level == 4) {
                if ((try self.store.proposed(node)) != null) {
                    self.bindings[self.count] = .{ .target = target, .lease = null, .object = node };
                    self.finish();
                    return .ready;
                }
                const lease = switch (try self.load.acquire(self.store, node)) {
                    .ready => |lease| lease,
                    .read => |read| return .{ .read = read },
                    .waiting => return .waiting,
                };
                self.bindings[self.count] = .{ .target = target, .lease = lease, .object = node };
                self.finish();
                return .ready;
            }
            const level: u2 = @intCast(cursor.level);
            if (try self.store.proposed(node)) |staged| {
                const page = try Page.decode(staged.view);
                try checkPage(page, self.header.owner, target, level);
                cursor.node = page.get(Page.digit(target.slot(), level));
                cursor.level += 1;
                continue;
            }
            const lease = switch (try self.load.acquire(self.store, node)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            defer self.store.release(lease) catch unreachable;
            const page = try Page.decode(try self.store.currentView(lease));
            try checkPage(page, self.header.owner, target, level);
            cursor.node = page.get(Page.digit(target.slot(), level));
            cursor.level += 1;
        }
        const next = switch (target) {
            .resource => self.header.next_resource,
            .grant => self.header.next_grant,
            .identity => self.header.next_identity,
        };
        self.bindings[self.count] = .{ .target = target, .lease = null, .absence = if (target.slot() < next) .gone else .unknown };
        self.finish();
        return .ready;
    }

    /// Reserve bounded weak membership paths before object creation. This is
    /// independent of authority revisions and shares the caller's transaction.
    pub fn prepareIdentities(self: *Read, count: usize) !void {
        try self.opened();
        if (self.header.lifecycle != .active) return error.OwnerRetired;
        if (count == 0 or count > Registry.max_registration) return error.InvalidLimits;
        if (self.identities) |registry| {
            if (!registry.available(count)) {
                var replacement = try Registry.init(self, count);
                errdefer replacement.deinit() catch unreachable;
                try registry.deinit();
                registry.* = replacement;
            }
        } else {
            const registry = try self.allocator.create(Registry);
            errdefer self.allocator.destroy(registry);
            registry.* = try Registry.init(self, count);
            self.identities = registry;
        }
        if (self.identities.?.preparing != self.identities.?.paths.len) return error.RecordUnloaded;
    }

    pub fn stageIdentity(self: *Read, object: loam.ObjectId) !u32 {
        const registry = self.identities orelse return error.RecordUnloaded;
        return registry.stage(object);
    }

    /// Demand retained history only for mutation or observation preparation.
    pub fn prepareHistory(self: *Read) !void {
        try self.opened();
        if (!self.history_ready) {
            self.history_requested = true;
            return error.RecordUnloaded;
        }
    }

    fn finish(self: *Read) void {
        self.count += 1;
        self.demand = null;
        self.cursor = null;
    }

    pub fn resourceView(self: *Read) !core.ResourceView {
        try self.opened();
        if (self.header.lifecycle != .active) return error.OwnerRetired;
        return core.ResourceView.init(.{ .owner = self.header.owner, .revision = self.header.version.resources }, self.header.max_resource_depth, self, readResource);
    }

    pub fn grantView(self: *Read) !core.GrantView {
        try self.opened();
        if (self.header.lifecycle != .active) return error.OwnerRetired;
        return core.GrantView.init(.{ .owner = self.header.owner, .revisions = self.header.version }, self.header.max_grant_depth, self, readGrant);
    }

    pub fn opened(self: *Read) !void {
        try self.current();
        if (!self.header_ready) return error.RecordUnloaded;
        if (try self.store.proposed(self.owner_object)) |proposal| {
            const composed = try records.OwnerRecord.decode(proposal.view);
            if (!std.meta.eql(composed.version, self.header.version) or composed.control_revision != self.header.control_revision) return error.RevisionConflict;
            // Registration changes retention roots without changing authority.
            // Every later writer must preserve that transaction's header.
            self.header = composed;
        }
    }

    pub const Row = struct { view: loam.RecordView, expected: ?u64 };

    /// Resolve a binding's row: the transaction's own staged proposal when this
    /// transaction already staged the row (the expected revision is the one the
    /// backend must still match when staging it again), else the committed lease
    /// view. Null means the binding resolved absent.
    pub fn rowFor(store: *loam.Store, entry: Binding) !?Row {
        const object = entry.object orelse return null;
        return try rowForObject(store, object, entry.lease);
    }

    pub fn rowForObject(store: *loam.Store, object: loam.ObjectId, lease: ?loam.Lease) !Row {
        if (try store.proposed(object)) |staged| return .{ .view = staged.view, .expected = staged.expected };
        const committed = try store.currentView(lease orelse return error.RecordUnloaded);
        if (!committed.id.eql(object)) return error.InvalidRecord;
        return .{ .view = committed, .expected = committed.revision };
    }

    /// Resolve an already-loaded model record for trusted transaction staging.
    pub fn binding(self: *Read, target: Target) !?Binding {
        try self.opened();
        if (target.owner() != self.header.owner) return error.ForeignOwner;
        for (self.bindings[0..self.count]) |entry| if (std.meta.eql(entry.target, target)) return entry;
        if (self.demand) |prior| {
            if (!std.meta.eql(prior, target)) return error.PendingRead;
        } else self.demand = target;
        return null;
    }

    pub fn forgetResources(self: *Read) !void {
        try self.opened();
        if (self.demand != null or self.load.pending != null or self.exclusive != .none) return error.Busy;
        var output: usize = 0;
        for (self.bindings[0..self.count]) |entry| {
            if (entry.target == .resource) {
                if (entry.lease) |lease| try self.store.release(lease);
            } else {
                self.bindings[output] = entry;
                output += 1;
            }
        }
        self.count = output;
    }

    fn checkPage(page: Page, owner: core.OwnerId, target: Target, level: u2) !void {
        if (page.owner != owner or page.family != std.meta.activeTag(target) or page.level != level or page.prefix != Page.prefixFor(target.slot(), level)) return error.InvalidRecord;
    }

    fn sourceError(err: anyerror) core.GrantView.SourceError {
        return switch (err) {
            error.RecoveryRequired => error.RecoveryRequired,
            error.RevisionConflict, error.StaleSnapshot => error.RevisionConflict,
            error.InvalidRecord => error.InvalidRecord,
            else => error.ReadFailed,
        };
    }

    fn readResource(context: *const anyopaque, id: core.ResourceId) core.ResourceView.SourceError!core.ResourceView.Reply {
        const self: *Read = @ptrCast(@alignCast(@constCast(context)));
        const entry = self.binding(.{ .resource = id }) catch |err| return sourceError(err);
        const version: core.ResourceView.Version = .{ .owner = self.header.owner, .revision = self.header.version.resources };
        const found = entry orelse return .{ .version = version, .value = .unloaded };
        const row = ((rowFor(self.store, found) catch |err| return sourceError(err)) orelse
            return .{ .version = version, .value = .{ .absent = found.absence } }).view;
        if (row.schema != records.profile.resource or row.schema_version != 1) return error.InvalidRecord;
        const record = records.ResourceRecord.decode(row) catch return error.InvalidRecord;
        if (record.resource.id.owner != id.owner or record.resource.id.slot != id.slot or @backingInt(record.revision) > @backingInt(version.revision)) return error.InvalidRecord;
        if (!record.live or record.resource.id.generation != id.generation) return .{ .version = version, .value = .{ .absent = .gone } };
        return .{ .version = version, .value = .{ .present = record.resource } };
    }

    fn readGrant(context: *const anyopaque, id: core.GrantId) core.GrantView.SourceError!core.GrantView.Reply {
        const self: *Read = @ptrCast(@alignCast(@constCast(context)));
        const entry = self.binding(.{ .grant = id }) catch |err| return sourceError(err);
        const version: core.GrantView.Version = .{ .owner = self.header.owner, .revisions = self.header.version };
        const found = entry orelse return .{ .version = version, .value = .unloaded };
        const found_row = ((rowFor(self.store, found) catch |err| return sourceError(err)) orelse
            return .{ .version = version, .value = .{ .absent = found.absence } }).view;
        if (found_row.schema != records.profile.grant or found_row.schema_version != records.GrantRecord.format_version) return error.InvalidRecord;
        const committed = (self.store.proposed(found_row.id) catch |err| return sourceError(err)) == null;
        const cached: *GrantCache = @ptrCast(@alignCast(&self.grant_scratch));
        if (committed and self.grant_cache_valid) {
            if (cached.object.eql(found_row.id) and cached.revision == found_row.revision)
                return grantReply(version, id, cached.grant);
        }
        // This bounded scratch is reused only by the next grant lookup.
        // Resource lookups cannot disturb the returned selected-scope borrow.
        var fixed = std.heap.FixedBufferAllocator.init(self.grantScratch());
        const decoded = records.GrantRecord.decodeOwned(fixed.allocator(), found_row.payload) catch return error.InvalidRecord;
        decoded.value.validateChildren(found_row) catch return error.InvalidRecord;
        const record = decoded.value.grant;
        if (committed and record.ceiling.scope != .objects and record.configured.scope != .objects) {
            comptime std.debug.assert(@sizeOf(GrantCache) <= @sizeOf(@FieldType(Read, "grant_scratch")));
            comptime std.debug.assert(@alignOf(GrantCache) <= @alignOf(core.ResourceId));
            cached.* = .{ .object = found_row.id, .revision = found_row.revision, .grant = record };
            self.grant_cache_valid = true;
        }
        return grantReply(version, id, record);
    }

    fn grantReply(version: core.GrantView.Version, id: core.GrantId, record: core.GrantView.Record) core.GrantView.SourceError!core.GrantView.Reply {
        if (record.id.owner != id.owner or record.id.slot != id.slot) return error.InvalidRecord;
        if (record.id.generation != id.generation) return .{ .version = version, .value = .{ .absent = .gone } };
        return .{ .version = version, .value = .{ .present = record } };
    }
};
