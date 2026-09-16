//! A bounded managed working set pins Loam records and resumes directory faults.
const std = @import("std");
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Page = records.DirectoryPage;
const Load = @import("load.zig").Load;

pub const Target = union(Page.Family) {
    resource: core.ResourceId,
    grant: core.GrantId,

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
pub const Binding = struct { target: Target, lease: ?loam.Lease, absence: core.ResourceView.Absence = .unknown };
pub const Step = union(enum) { ready, read: loam.Read, waiting };

pub const Read = struct {
    allocator: std.mem.Allocator,
    store: *loam.Store,
    owner_object: loam.ObjectId,
    snapshot: u64,
    incarnation: u64,
    header: records.OwnerRecord = undefined,
    header_lease: ?loam.Lease = null,
    bindings: []Binding,
    count: usize = 0,
    load: Load = .{},
    demand: ?Target = null,
    cursor: ?Cursor = null,
    cancelled: bool = false,
    appending: bool = false,
    grant_scratch: [2 * core.max_scope_objects * @sizeOf(core.ResourceId)]u8 align(@alignOf(core.ResourceId)) = undefined,

    const Cursor = struct { node: ?loam.ObjectId, level: u3 = 0 };

    /// Store and operation stay at stable addresses during view use. Capacity
    /// bounds pinned model records; directory pages borrow one extra cache slot.
    pub fn init(allocator: std.mem.Allocator, store: *loam.Store, owner: loam.ObjectId, capacity: usize) !Read {
        if (owner.store != store.metadata.store) return error.ForeignObject;
        if (capacity == 0 or capacity > store.limits.max_leases -| 1) return error.InvalidLimits;
        if (store.phase == .uncertain) return error.RecoveryRequired;
        return .{ .allocator = allocator, .store = store, .owner_object = owner, .snapshot = store.metadata.revision, .incarnation = store.metadata.incarnation, .bindings = try allocator.alloc(Binding, capacity) };
    }

    pub fn deinit(self: *Read) !void {
        if (self.load.pending != null or self.appending) return error.Busy;
        for (self.bindings[0..self.count]) |entry| if (entry.lease) |lease| try self.store.release(lease);
        if (self.header_lease) |lease| try self.store.release(lease);
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn cancel(self: *Read) !void {
        try self.load.cancel(self.store);
        self.cancelled = true;
    }

    pub fn completeRead(self: *Read, ticket: loam.Ticket, result: loam.ReadResult) !void {
        try self.load.complete(self.store, ticket, result);
    }

    pub fn current(self: *const Read) !void {
        if (self.cancelled) return error.Cancelled;
        if (self.store.phase == .uncertain) return error.RecoveryRequired;
        if (self.snapshot != self.store.metadata.revision or self.incarnation != self.store.metadata.incarnation) return error.RevisionConflict;
    }

    pub fn advance(self: *Read) !Step {
        try self.current();
        if (self.header_lease == null) {
            const lease = switch (try self.load.acquire(self.store, self.owner_object)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            errdefer self.store.release(lease) catch unreachable;
            self.header = try records.OwnerRecord.decode(try self.store.currentView(lease));
            self.header_lease = lease;
        }
        const target = self.demand orelse return .ready;
        if (self.count == self.bindings.len) return error.WorkingSetCapacity;
        if (self.cursor == null) self.cursor = .{ .node = switch (target) {
            .resource => self.header.resources,
            .grant => self.header.grants,
        } };
        const cursor = &self.cursor.?;
        while (cursor.node) |node| {
            const lease = switch (try self.load.acquire(self.store, node)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            if (cursor.level == 4) {
                self.bindings[self.count] = .{ .target = target, .lease = lease };
                self.finish();
                return .ready;
            }
            defer self.store.release(lease) catch unreachable;
            const page = try Page.decode(try self.store.currentView(lease));
            const level: u2 = @intCast(cursor.level);
            if (page.owner != self.header.owner or page.family != std.meta.activeTag(target) or page.level != level or page.prefix != Page.prefixFor(target.slot(), level)) return error.InvalidRecord;
            cursor.node = page.get(Page.digit(target.slot(), level));
            cursor.level += 1;
        }
        const next = switch (target) {
            .resource => self.header.next_resource,
            .grant => self.header.next_grant,
        };
        self.bindings[self.count] = .{ .target = target, .lease = null, .absence = if (target.slot() < next) .gone else .unknown };
        self.finish();
        return .ready;
    }

    fn finish(self: *Read) void {
        self.count += 1;
        self.demand = null;
        self.cursor = null;
    }

    pub fn resourceView(self: *Read) !core.ResourceView {
        try self.opened();
        return core.ResourceView.init(.{ .owner = self.header.owner, .revision = self.header.version.resources }, self.header.max_resource_depth, self, readResource);
    }

    pub fn grantView(self: *Read) !core.GrantView {
        try self.opened();
        return core.GrantView.init(.{ .owner = self.header.owner, .revisions = self.header.version }, self.header.max_grant_depth, self, readGrant);
    }

    pub fn opened(self: *const Read) !void {
        try self.current();
        if (self.header_lease == null) return error.RecordUnloaded;
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
        const lease = found.lease orelse return .{ .version = version, .value = .{ .absent = found.absence } };
        const row = self.store.currentView(lease) catch |err| return sourceError(err);
        if (row.schema != records.profile.resource or row.schema_version != 1) return error.InvalidRecord;
        const record = records.ResourceRecord.decode(row.payload) catch return error.InvalidRecord;
        if (record.resource.id.owner != id.owner or record.resource.id.slot != id.slot or @backingInt(record.revision) > @backingInt(version.revision)) return error.InvalidRecord;
        if (record.resource.id.generation != id.generation) return .{ .version = version, .value = .{ .absent = .gone } };
        return .{ .version = version, .value = .{ .present = record.resource } };
    }

    fn readGrant(context: *const anyopaque, id: core.GrantId) core.GrantView.SourceError!core.GrantView.Reply {
        const self: *Read = @ptrCast(@alignCast(@constCast(context)));
        const entry = self.binding(.{ .grant = id }) catch |err| return sourceError(err);
        const version: core.GrantView.Version = .{ .owner = self.header.owner, .revisions = self.header.version };
        const found = entry orelse return .{ .version = version, .value = .unloaded };
        const lease = found.lease orelse return .{ .version = version, .value = .{ .absent = found.absence } };
        const row = self.store.currentView(lease) catch |err| return sourceError(err);
        if (row.schema != records.profile.grant or row.schema_version != 1) return error.InvalidRecord;
        // This bounded scratch is reused only by the next grant lookup.
        // Resource lookups cannot disturb the returned selected-scope borrow.
        var fixed = std.heap.FixedBufferAllocator.init(&self.grant_scratch);
        const decoded = records.GrantRecord.decodeOwned(fixed.allocator(), row.payload) catch return error.InvalidRecord;
        const record = decoded.value.grant;
        if (record.id.owner != id.owner or record.id.slot != id.slot) return error.InvalidRecord;
        if (record.id.generation != id.generation) return .{ .version = version, .value = .{ .absent = .gone } };
        return .{ .version = version, .value = .{ .present = record } };
    }
};
