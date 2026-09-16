//! Durable, record-backed actors attached to an existing Host. The attachment
//! emits storage work and queues ready calls on that Host's Vat; it owns no I/O.
const std = @import("std");
const core = @import("loam_core");
const actors = @import("actors");
const driver = @import("driver_core");
const behavior = @import("behavior.zig");
const calls = @import("calls.zig");
const storage = @import("storage.zig");
pub const Behavior = behavior.Behavior;
pub const Call = behavior.Call;
pub const Work = union(enum) { read: core.Read, write: core.Batch };
pub const Options = struct {
    max_endpoints: usize = 128,
    max_calls: usize = 64,
    call_bytes: usize = 64 * 1024,
    pending_bytes: usize = 4 * 1024 * 1024,
    sleep_policy: enum { lru, every_turn } = .lru,
};
pub const Stats = struct { loads: u64 = 0, invocations: u64 = 0, sleeps: u64 = 0 };

pub const Entry = struct {
    owner: *Attachment,
    id: core.ObjectId = undefined,
    actor: ?actors.Ref = null,
    retention: ?core.Retention = null,
};
pub const Operation = calls.Operation;
pub const Loading = struct { request: core.Read, submitted: bool = false, operation: ?usize = null };
pub const Writing = struct { batch: core.Batch, operation: usize, submitted: bool = false, uncertain: bool = false };

pub const Attachment = struct {
    allocator: std.mem.Allocator,
    host: *driver.Host,
    store: *core.Store,
    behaviors: []const Behavior,
    options: Options,
    entries: []Entry,
    operations: []Operation,
    reads: []?Loading,
    writing: ?Writing = null,
    runner: actors.Ref,
    sequence: u64 = 0,
    pending_bytes: usize = 0,
    dependent_facets: usize = 0,
    advancing: bool = false,
    closing: bool = false,
    stats: Stats = .{},

    /// Borrows Host, Store, and behavior descriptors until destroy. The Store's
    /// write lane belongs exclusively to this attachment while calls are pending.
    pub fn create(allocator: std.mem.Allocator, host: *driver.Host, store: *core.Store, behaviors: []const Behavior, options: Options) !*Attachment {
        if (options.max_endpoints == 0 or options.max_calls == 0 or options.call_bytes == 0 or options.pending_bytes < options.call_bytes) return error.InvalidLimits;
        for (behaviors, 0..) |item, i| {
            var found = false;
            for (store.cache.schemas) |schema| if (schema.id == item.schema and schema.version == item.version) {
                found = true;
            };
            if (!found) return error.UnsupportedSchema;
            for (behaviors[0..i]) |previous| if (previous.schema == item.schema and previous.version == item.version) return error.DuplicateSchema;
        }
        const self = try allocator.create(Attachment);
        errdefer allocator.destroy(self);
        const entries = try allocator.alloc(Entry, options.max_endpoints);
        errdefer allocator.free(entries);
        for (entries) |*entry| entry.* = .{ .owner = self };
        const operations = try allocator.alloc(Operation, options.max_calls);
        errdefer allocator.free(operations);
        @memset(operations, .{});
        const reads = try allocator.alloc(?Loading, store.limits.cache_slots);
        errdefer allocator.free(reads);
        @memset(reads, null);
        const runner = try host.vat.spawn(calls.Runner, .{ .owner = self });
        self.* = .{ .allocator = allocator, .host = host, .store = store, .behaviors = behaviors, .options = options, .entries = entries, .operations = operations, .reads = reads, .runner = runner };
        return self;
    }

    /// Refuses pending work. Stops future calls and releases the attachment's
    /// ownership; live endpoint boxes retain only its closed routing metadata
    /// until their existing Host/Vat custody ends. Do not use self afterward.
    pub fn destroy(self: *Attachment) !void {
        try self.topLevel();
        if (self.pending_bytes != 0 or self.writing != null) return error.Busy;
        for (self.reads) |read| if (read != null) return error.Busy;
        // Cross a normal Vat boundary to retire released proxy boxes before
        // freeing the entry storage their destructors reference.
        _ = try self.host.vat.near(self.runner, .{ .verb = "barrier", .args = &.{} });
        self.host.vat.releaseActor(self.runner.local);
        for (self.entries) |*entry| if (entry.retention) |token| {
            try self.store.releaseRetention(token);
            entry.retention = null;
        };
        self.closing = true;
        releaseClosed(self);
    }

    /// Privileged restoration consumes a checked record lease, not an arbitrary
    /// caller-supplied object name. Remote users enter through held capabilities.
    pub fn restore(self: *Attachment, lease: core.Lease) !driver.Capability {
        if (self.closing) return error.AttachmentClosed;
        const view = try self.store.currentView(lease);
        if (!view.rooted) return error.NotRooted;
        _ = try self.findBehavior(view);
        return restoreEdge(self, view.id);
    }

    /// Save a held local actor capability as a strong portrait edge. Foreign,
    /// volatile, and other-attachment targets have no restoration contract here.
    pub fn capture(self: *Attachment, ref: driver.Capability) !core.Edge {
        const entry = try self.entryFor(ref);
        return .{ .target = entry.id };
    }

    /// Construct a dependent runtime facet from two live capabilities. The
    /// source id only selects the already-held endpoint entry; it never restores
    /// authority. Both actor retains transfer into the facet on successful spawn.
    pub fn projectDependent(self: *Attachment, source: core.ObjectId, target: driver.Capability) !driver.Capability {
        if (self.closing) return error.AttachmentClosed;
        const source_entry = for (self.entries) |*entry| {
            if (entry.actor != null and entry.id.eql(source)) break entry;
        } else return error.NotDurable;
        const target_entry = try self.entryFor(target);
        const guard = try self.host.retainLocalCapability(source_entry.actor.?);
        const held_target = self.host.retainLocalCapability(target_entry.actor.?) catch |err| {
            self.host.releaseCapability(guard, 1) catch unreachable;
            return err;
        };
        if (self.dependent_facets == std.math.maxInt(usize)) {
            self.host.releaseCapability(held_target, 1) catch unreachable;
            self.host.releaseCapability(guard, 1) catch unreachable;
            return error.EndpointCapacity;
        }
        self.dependent_facets += 1;
        const actor = try self.host.vat.spawn(driver.Hosting(calls.DependentEndpoint), .{ .inner = .{
            .owner = self,
            .guard = guard,
            .target = held_target,
        } });
        errdefer self.host.vat.discardFreshActor(actor);
        return self.host.liftLocalActor(actor);
    }

    pub fn pin(self: *Attachment, ref: driver.Capability) !core.Lease {
        return self.store.resident((try self.entryFor(ref)).id);
    }

    pub fn sleep(self: *Attachment, ref: driver.Capability) !void {
        try self.topLevel();
        const entry = try self.entryFor(ref);
        for (self.operations) |operation| if (operation.phase != .free and operation.entry == entry) return error.Busy;
        if (try self.store.evictObject(entry.id)) self.stats.sleeps += 1;
    }

    pub const advance = calls.advance;
    pub const prefetch = storage.prefetch;
    pub const nextWork = storage.nextWork;
    pub const completeRead = storage.completeRead;
    pub const completeWrite = storage.completeWrite;
    pub const recoveryBatch = storage.recoveryBatch;
    pub const resolve = storage.resolve;

    pub fn findBehavior(self: *Attachment, view: core.RecordView) !Behavior {
        for (self.behaviors) |item| if (item.schema == view.schema and item.version == view.schema_version) return item;
        return error.UnsupportedBehavior;
    }

    pub fn entryFor(self: *Attachment, ref: driver.Capability) !*Entry {
        if (self.closing) return error.AttachmentClosed;
        const actor = self.host.localActorFor(ref) orelse return error.NotDurable;
        for (self.entries) |*entry| if (entry.actor != null and entry.actor.?.local == actor.local) return entry;
        return error.NotDurable;
    }

    pub fn topLevel(self: *Attachment) !void {
        if (self.closing) return error.AttachmentClosed;
        self.host.assertOwner();
        if (self.advancing or self.host.vat.turn_depth != 0 or self.host.in_callback) return error.ReenteredAttachment;
    }
};

/// Internal restoration of an already-validated stored capability edge.
pub fn restoreEdge(self: *Attachment, id: core.ObjectId) !driver.Capability {
    if (self.closing) return error.AttachmentClosed;
    if (id.store != self.store.metadata.store) return error.NotDurable;
    for (self.entries) |*entry| {
        if (entry.actor != null and entry.id.eql(id) and self.host.vat.hasActor(entry.actor.?.local))
            return self.host.retainLocalCapability(entry.actor.?);
    }
    const entry = for (self.entries) |*candidate| {
        if (candidate.actor == null) break candidate;
    } else return error.EndpointCapacity;
    entry.id = id;
    const retained = try self.store.retain(id);
    errdefer self.store.releaseRetention(retained) catch unreachable;
    const actor = try self.host.vat.spawn(driver.Hosting(calls.Endpoint), .{ .inner = .{ .entry = entry } });
    entry.actor = actor;
    errdefer self.host.vat.discardFreshActor(actor);
    const result = try self.host.liftLocalActor(actor);
    entry.retention = retained;
    return result;
}

pub fn releaseClosed(self: *Attachment) void {
    if (!self.closing) return;
    if (self.dependent_facets != 0) return;
    for (self.entries) |entry| if (entry.actor != null) return;
    self.allocator.free(self.reads);
    self.allocator.free(self.operations);
    self.allocator.free(self.entries);
    const allocator = self.allocator;
    allocator.destroy(self);
}
