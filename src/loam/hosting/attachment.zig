//! Durable, record-backed actors attached to an existing Host. The attachment
//! emits storage work and queues ready calls on that Host's Vat. It owns no I/O.
const std = @import("std");
const core = @import("loam_core");
const actors = @import("actors");
const driver = @import("driver_core");
const behavior = @import("behavior.zig");
const calls = @import("calls.zig");
const drive = @import("drive.zig");
const storage = @import("storage.zig");
pub const Behavior = behavior.Behavior;
pub const Call = behavior.Call;
pub const Work = union(enum) { read: core.Read, write: core.Batch, lookup: core.NameLookup };
pub const Options = struct {
    max_endpoints: usize = 128,
    max_calls: usize = 64,
    max_continuations: usize = 64,
    /// Independent runtime effect custody, excluding graph snapshots and
    /// storage leases. Each reservation charges this complete ceiling.
    continuation_bytes: usize = 64 * 1024,
    max_continuation_targets: usize = 32,
    /// Complete acquired arena blocks per call, including headers and slack.
    /// Admission reserves this ceiling. Heap backing grows only as needed.
    call_bytes: usize = 64 * 1024,
    /// Whole-call reservations for admitted operations, rather than live heap bytes.
    pending_bytes: usize = 4 * 1024 * 1024,
    /// Per attachment and ingress, retained call bytes after the Vat turn has
    /// dispatched. Null uses the Vat's queue byte allowance. An explicit budget
    /// permits larger application working sets without changing message queues.
    ingress_bytes: ?usize = null,
    max_retirements: usize = 16,
    max_reference_saves: usize = 64,
    forward_reply_bytes: usize = 16 * 1024,
    reference_scope: ?*@import("reference_scope.zig").Scope = null,
    live_scope: ?*@import("live_scope.zig").Scope = null,
    /// Stable embedding-owned attachment name. Borrowed until this attachment closes.
    attachment_name: ?[]const u8 = null,
    sleep_policy: enum { lru, every_turn } = .lru,

    /// Shared admission laws also run before foreign storage construction.
    pub fn validate(self: Options, default_ingress_bytes: usize) !void {
        if (self.max_endpoints == 0 or self.max_calls == 0 or self.call_bytes == 0 or self.pending_bytes < self.call_bytes) return error.InvalidLimits;
        if ((self.ingress_bytes orelse default_ingress_bytes) < self.call_bytes) return error.InvalidLimits;
        _ = try @import("execution.zig").Execution.sizeBound(self.forward_reply_bytes);
    }
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
pub const Writing = struct { batch: core.Batch, operation: ?usize, submitted: bool = false, uncertain: bool = false };
/// One staged publication tombstone this attachment owns the registry
/// transition for. Reserved when the tombstone stages. Fenced (discovery
/// removed) when its batch reaches an unknown outcome. Cleared at every
/// confirmed retirement. Known-absent recovery retains bounded retry custody
/// while advance restores the still-rooted recipe through the ordinary read
/// and Host publication paths. Later write outcomes cannot discard that work.
pub const Retirement = struct {
    record: core.ObjectId,
    swiss: driver.Host.DurableSwiss,
    fenced: bool = false,
    republish: bool = false,
    registered: bool = false,
};

pub const Attachment = struct {
    allocator: std.mem.Allocator,
    host: *driver.Host,
    store: *core.Store,
    behaviors: []const Behavior,
    options: Options,
    entries: []Entry,
    operations: []Operation,
    reads: []?Loading,
    retirements: []?Retirement,
    discovery: ?*@import("discovery.zig").Discovery = null,
    writing: ?Writing = null,
    runner: actors.Ref,
    sequence: u64 = 0,
    /// Reserved call ceilings. Nonzero even for calls with no acquired backing.
    pending_bytes: usize = 0,
    reference_saves: usize = 0,
    continuations: usize = 0,
    /// Continuations with an executor or dispatch-front retain. A continuation
    /// held solely by read scopes is passive custody and does not prevent close.
    effect_continuations: usize = 0,
    /// Passive read scopes share the continuation budget, but hold only closed
    /// routing metadata after destroy. Outstanding calls still own pending_bytes.
    read_scopes: usize = 0,
    dependent_facets: usize = 0,
    advancing: bool = false,
    closing: bool = false,
    stats: Stats = .{},

    /// Borrows Host, Store, and behavior descriptors until destroy. Attachments
    /// sharing a Store serialize through its single write lane and reprepare
    /// calls whenever another owner changes the committed revision.
    pub fn create(allocator: std.mem.Allocator, host: *driver.Host, store: *core.Store, behaviors: []const Behavior, options: Options) !*Attachment {
        if (store.phase != .idle) return error.Busy;
        try options.validate(host.vat.queue_limits.max_pending_bytes);
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
        if (options.max_retirements == 0) return error.InvalidLimits;
        const retirements = try allocator.alloc(?Retirement, options.max_retirements);
        errdefer allocator.free(retirements);
        @memset(retirements, null);
        if ((options.reference_scope == null) != (options.attachment_name == null) or options.max_reference_saves == 0) return error.InvalidLimits;
        const runner = try host.vat.spawn(drive.Runner, .{ .owner = self });
        errdefer host.vat.discardFreshActor(runner);
        self.* = .{ .allocator = allocator, .host = host, .store = store, .behaviors = behaviors, .options = options, .entries = entries, .operations = operations, .reads = reads, .retirements = retirements, .runner = runner };
        if (options.reference_scope) |scope| try scope.register(self);
        errdefer if (options.reference_scope) |scope| scope.unregister(self);
        if (options.live_scope) |scope| try scope.register(self);
        return self;
    }

    /// Refuses pending work. Stops future calls and releases the attachment's
    /// ownership. Live endpoint boxes retain only its closed routing metadata
    /// until their existing Host/Vat custody ends. Do not use self afterward.
    pub fn destroy(self: *Attachment) !void {
        try self.topLevel();
        if (self.pending_bytes != 0 or self.writing != null or self.reference_saves != 0 or self.effect_continuations != 0) return error.Busy;
        for (self.reads) |read| if (read != null) return error.Busy;
        for (self.retirements) |retirement| if (retirement != null) return error.Busy;
        if (self.options.live_scope) |scope| if (scope.hasPendingWork()) return error.Busy;
        if (self.discovery) |discovery| try discovery.destroy();
        // Cross a normal Vat boundary to retire released proxy boxes before
        // freeing the entry storage their destructors reference.
        _ = try self.host.vat.near(self.runner, .{ .verb = "barrier", .args = &.{} });
        self.host.vat.releaseActor(self.runner.local);
        for (self.entries) |*entry| if (entry.retention) |token| {
            try self.store.releaseRetention(token);
            entry.retention = null;
        };
        if (self.options.reference_scope) |scope| scope.unregister(self);
        if (self.options.live_scope) |scope| scope.unregister(self);
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
    /// source id only selects the already-held endpoint entry. It never restores
    /// authority. Both actor retains transfer into the facet on successful spawn.
    pub fn projectDependent(self: *Attachment, source: core.ObjectId, target: driver.Capability) !driver.Capability {
        if (self.closing) return error.AttachmentClosed;
        const source_entry = for (self.entries) |*entry| {
            if (entry.actor != null and entry.id.eql(source)) break entry;
        } else return error.NotDurable;
        const guard = try self.host.retainLocalCapability(source_entry.actor.?);
        const retained = self.host.retainValueCapabilities(self.allocator, &.{.{ .capability = target }}) catch |err| {
            self.host.releaseCapability(guard, 1) catch unreachable;
            return err;
        };
        defer self.allocator.free(retained);
        const held_target = retained[0].ref;
        if (self.dependent_facets == std.math.maxInt(usize)) {
            self.host.releaseCapability(held_target, 1) catch unreachable;
            self.host.releaseCapability(guard, 1) catch unreachable;
            return error.EndpointCapacity;
        }
        self.dependent_facets += 1;
        // Vat.spawn adopts initial state on every outcome, including allocation
        // refusal. The endpoint destructor owns both retains and the count.
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

    pub const advance = drive.advance;
    pub const advanceProgress = drive.advanceProgress;
    pub const prefetch = storage.prefetch;
    pub const nextWork = storage.nextWork;
    pub const completeRead = storage.completeRead;
    pub const completeLookup = storage.completeLookup;
    pub const completeWrite = storage.completeWrite;
    pub const awaitsRecovery = storage.awaitsRecovery;
    pub const recoveryBatch = storage.recoveryBatch;
    pub const resolve = storage.resolve;
    pub const submit = storage.submit;

    /// Work still owned by this attachment, including cold discovery after
    /// its last caller leaves. Shutdown must deliver every submitted completion.
    pub fn hasPendingWork(self: *const Attachment) bool {
        if (self.pending_bytes != 0 or self.writing != null) return true;
        for (self.reads) |read| if (read != null) return true;
        for (self.retirements) |retirement| if (retirement != null) return true;
        if (self.discovery) |discovery| for (discovery.groups) |group| if (group != null) return true;
        if (self.options.live_scope) |scope| if (scope.hasPendingWork()) return true;
        return false;
    }

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
    if (self.continuations != 0) return;
    if (self.dependent_facets != 0) return;
    for (self.entries) |entry| if (entry.actor != null) return;
    self.allocator.free(self.reads);
    self.allocator.free(self.operations);
    self.allocator.free(self.retirements);
    self.allocator.free(self.entries);
    const allocator = self.allocator;
    allocator.destroy(self);
}
