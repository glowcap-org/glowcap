//! Exact live custody beside graph-owned recipes, using the attachment's lane.
//! No runtime handle enters storage and no table entry roots its recipe row.
const std = @import("std");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const Epoch = @import("live_epoch.zig").Epoch;
const Recipe = @import("reference_recipe.zig").Recipe;

pub const Scope = struct {
    allocator: std.mem.Allocator,
    host: *driver.Host,
    store: *core.Store,
    entries: []Reservation,
    by_recipe: std.AutoHashMapUnmanaged(core.ObjectId, *Reservation) = .empty,
    owner: ?*h.Attachment = null,
    proposal: ?Epoch.Proposed = null,
    epoch: ?Epoch = null,
    cursor: usize = 0,
    remaining: usize = 0,
    revision: u64 = 0,
    pending: ?struct { entry: *Reservation, ticket: core.Ticket } = null,
    startup: ?@import("live_start.zig").Start = null,

    /// Allocate the complete bounded runtime inventory and hash index before
    /// startup stages anything. A reservation owns one exact Host retain. Its
    /// transfer on commit needs no allocation. Graph retention stays elsewhere
    /// so collecting the last stored occurrence can retire that runtime retain.
    pub fn init(allocator: std.mem.Allocator, host: *driver.Host, store: *core.Store, capacity: u32) !Scope {
        try host.refuseReentry();
        if (capacity == 0) return error.InvalidLimits;
        const entries = try allocator.alloc(Reservation, capacity);
        errdefer allocator.free(entries);
        @memset(entries, .{});
        var index: std.AutoHashMapUnmanaged(core.ObjectId, *Reservation) = .empty;
        errdefer index.deinit(allocator);
        try index.ensureTotalCapacity(allocator, capacity);
        return .{ .allocator = allocator, .host = host, .store = store, .entries = entries, .by_recipe = index };
    }

    /// Startup must stage its own advance. An old caller-supplied Epoch cannot
    /// activate a new scope, even if the Store remained open across Host restart.
    pub fn stageStart(self: *Scope, prior: ?core.Lease) !core.ObjectId {
        try self.host.refuseReentry();
        if (self.epoch != null or self.proposal != null) return error.LiveScopeAlreadyStarted;
        self.proposal = if (prior) |lease| try Epoch.stageRestart(self.store, lease) else try Epoch.stageFresh(self.store);
        return self.proposal.?.epoch.object;
    }

    pub fn confirmStart(self: *Scope, lease: core.Lease) !void {
        try self.host.refuseReentry();
        const proposal = self.proposal orelse return error.LiveScopeNotStarted;
        self.epoch = try proposal.confirm(self.store, lease);
        self.proposal = null;
        self.revision = self.store.metadata.revision;
    }

    /// Confirmed absence permits another startup attempt. An unknown write
    /// cannot discard the opening proposal before exact backend recovery.
    pub fn cancelStart(self: *Scope) !void {
        try self.host.refuseReentry();
        if (self.store.phase != .idle or self.epoch != null) return error.Busy;
        self.proposal = null;
    }

    pub fn register(self: *Scope, owner: *h.Attachment) !void {
        if (owner.host != self.host or owner.store != self.store) return error.ForeignStore;
        if (self.epoch == null) return error.LiveScopeNotStarted;
        if (self.owner != null) return error.LiveScopeAttached;
        self.owner = owner;
    }

    /// Optional activation after attaching durable behaviors. Live declarations
    /// refuse until the existing write lane confirms this startup's new marker.
    pub fn startHosted(self: *Scope, owner: *h.Attachment, prior: ?core.ObjectId) !void {
        try owner.topLevel();
        if (owner.host != self.host or owner.store != self.store) return error.ForeignStore;
        if (self.owner != null or self.epoch != null or self.proposal != null or owner.options.live_scope != null) return error.LiveScopeAttached;
        if (prior) |id| if (id.store != self.store.metadata.store) return error.ForeignObject;
        self.owner = owner;
        self.startup = .{ .prior = prior };
        owner.options.live_scope = self;
    }

    pub const Result = union(enum) { pending, ready: Epoch, failed: anyerror };

    pub fn result(self: *const Scope) Result {
        if (self.epoch) |epoch| return .{ .ready = epoch };
        if (self.startup) |startup| if (startup.phase == .failed) return .{ .failed = startup.failure };
        return .pending;
    }

    pub fn hasPendingWork(self: *const Scope) bool {
        if (self.startup) |startup| if (startup.phase != .ready and startup.phase != .failed) return true;
        return self.pending != null or self.remaining != 0;
    }

    pub fn writeFinished(self: *Scope, ticket: core.Ticket, failure: ?anyerror) void {
        if (self.startup) |*startup| startup.writeFinished(self, ticket, failure);
    }

    pub fn unregister(self: *Scope, owner: *h.Attachment) void {
        std.debug.assert(self.owner == owner and self.pending == null);
        if (self.startup) |startup| std.debug.assert(startup.phase == .ready or startup.phase == .failed);
        self.owner = null;
    }

    pub fn deinit(self: *Scope) !void {
        try self.host.refuseReentry();
        if (self.owner != null or self.pending != null) return error.Busy;
        if (self.proposal != null and (self.startup == null or self.startup.?.phase != .failed or self.store.phase != .idle)) return error.Busy;
        for (self.entries) |entry| if (entry.phase == .reserved) return error.Busy;
        for (self.entries) |*entry| if (entry.phase == .committed) self.release(entry);
        self.by_recipe.deinit(self.allocator);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// Reservation precedes all preparation waits and staging. The caller's
    /// arena owns only the temporary retain spine, not the transferred retain.
    pub fn reserve(self: *Scope, scratch: std.mem.Allocator, capability: driver.Capability) !*Reservation {
        if (self.epoch == null or self.owner == null) return error.LiveScopeNotStarted;
        const entry = for (self.entries) |*entry| {
            if (entry.phase == .free) break entry;
        } else return error.ReferenceCapacity;
        const held = try self.host.retainValueCapabilities(scratch, &.{.{ .capability = capability }});
        entry.* = .{ .phase = .reserved, .scope = self, .capability = held[0] };
        return entry;
    }

    /// Construct once from two actual held authorities before preparation can
    /// wait. Temporary canonical retains establish the names borrowed below.
    /// The facet owns those same retains for the reservation's whole lifetime.
    /// Saving its actual capability preserves identity through receipt replay.
    pub fn reserveDependent(self: *Scope, scratch: std.mem.Allocator, source: driver.Capability, target: driver.Capability) !*Reservation {
        if (self.epoch == null) return error.LiveScopeNotStarted;
        const owner = self.owner orelse return error.LiveScopeNotStarted;
        const source_entry = try owner.entryFor(source);
        const guard = try self.host.retainLocalCapability(source_entry.actor.?);
        defer self.host.releaseCapabilityTerminal(guard, null);
        const held = try self.host.retainValueCapabilities(scratch, &.{.{ .capability = target }});
        defer self.host.releaseCapabilityRetains(held);
        const facet = try owner.projectDependent(source_entry.id, held[0]);
        defer self.host.releaseCapabilityTerminal(facet, null);
        const entry = try self.reserve(scratch, facet);
        entry.dependent = .{ .source = guard, .target = held[0] };
        return entry;
    }

    /// Compare actual guarded authority on retry without constructing a new
    /// facet. The table owns the facet. Its two retains keep these names valid.
    pub fn matchesDependent(self: *Scope, facet: driver.Capability, source: driver.Capability, target: driver.Capability) bool {
        const source_actor = self.host.localActorFor(source) orelse return false;
        for (self.entries) |entry| {
            if (entry.phase != .committed or !entry.capability.eql(facet)) continue;
            const pair = entry.dependent orelse return false;
            const guard_actor = self.host.localActorFor(pair.source) orelse return false;
            return guard_actor.local == source_actor.local and pair.target.eql(target);
        }
        return false;
    }

    /// Trusted lifetime metadata for one committed facet. The existing bounded
    /// inventory retains its guarded pair. Observation borrows the Host session
    /// without disclosing either capability or constructing another facade.
    pub fn dependentExporter(self: *Scope, facet: driver.Capability) ?*driver.HostSession {
        for (self.entries) |entry| {
            if (entry.phase != .committed or !entry.capability.eql(facet)) continue;
            const pair = entry.dependent orelse return null;
            return self.host.capabilitySession(pair.target);
        }
        return null;
    }

    /// Preparation checks the actual current epoch row before invoking. This
    /// lookup also requires exact recipe identity and actual warm Host custody.
    pub fn restore(self: *Scope, scratch: std.mem.Allocator, id: core.ObjectId, epoch: Epoch) !driver.Capability {
        if (self.epoch == null or !std.meta.eql(epoch, self.epoch.?)) return error.LiveReferenceExpired;
        const entry = self.by_recipe.get(id) orelse return error.LiveReferenceExpired;
        const held = try self.host.retainValueCapabilities(scratch, &.{.{ .capability = entry.capability }});
        return held[0];
    }

    pub fn validateStaged(self: *Scope) !void {
        if (self.epoch) |epoch| if (try self.store.proposed(epoch.object) != null) {
            for (self.entries) |entry| if (entry.phase == .reserved and entry.staged != null and std.meta.eql(entry.staged.?.ticket, self.store.ticket.?)) return error.LiveReferenceExpired;
        };
    }

    /// Run one runtime inventory slot per step after a committed revision.
    /// This checks only this scope's held recipes, never the owner's population.
    /// Reads share the existing attachment lane and expected Gone has one owner.
    pub fn advanceProgress(self: *Scope) !bool {
        if (self.startup) |*startup| {
            if (startup.phase != .ready and startup.phase != .failed) return startup.advance(self) catch |err| {
                // Before submission, preparation refusal has no durable effect.
                // A failed confirmation retains its proposal until scope close.
                if (self.store.phase == .idle and startup.phase == .loading) self.proposal = null;
                startup.failure = err;
                startup.phase = .failed;
                return true;
            };
        }
        if (self.store.phase != .idle or self.pending != null) return false;
        const owner = self.owner orelse return false;
        if (self.revision != self.store.metadata.revision) {
            self.revision = self.store.metadata.revision;
            self.remaining = self.entries.len;
        }
        if (self.remaining == 0) return false;
        const entry = &self.entries[self.cursor];
        if (entry.phase == .committed) {
            const acquired = self.store.acquire(entry.staged.?.edge.target) catch |err| switch (err) {
                error.PendingRead, error.ResidentCapacity, error.LeaseCapacity, error.Busy => return false,
                else => return err,
            };
            switch (acquired) {
                .ready => |lease| try self.store.release(lease),
                .read => |read| {
                    self.pending = .{ .entry = entry, .ticket = read.ticket };
                    @import("storage.zig").retainRead(owner, read, null);
                },
            }
        }
        self.cursor = (self.cursor + 1) % self.entries.len;
        self.remaining -= 1;
        return true;
    }

    pub fn readFinished(self: *Scope, ticket: core.Ticket, failure: ?anyerror) bool {
        if (self.startup) |*startup| if (startup.readFinished(ticket, failure)) return true;
        const pending = self.pending orelse return false;
        if (!std.meta.eql(pending.ticket, ticket)) return false;
        self.pending = null;
        if (failure) |err| {
            if (err == error.Gone) {
                self.release(pending.entry);
                return true;
            } else {
                // Retry at the next owning step after stale or failed I/O.
                self.cursor = (self.cursor + self.entries.len - 1) % self.entries.len;
                self.remaining += 1;
            }
        }
        return false;
    }

    fn release(self: *Scope, entry: *Reservation) void {
        if (entry.phase == .committed) std.debug.assert(self.by_recipe.remove(entry.staged.?.edge.target));
        self.host.releaseCapabilityTerminal(entry.capability, null);
        entry.* = .{};
    }
};

pub const Reservation = struct {
    phase: enum { free, reserved, committed } = .free,
    scope: *Scope = undefined,
    capability: driver.Capability = undefined,
    dependent: ?struct { source: driver.Capability, target: driver.Capability } = null,
    staged: ?struct { ticket: core.Ticket, edge: core.Edge } = null,

    pub fn stage(self: *Reservation, store: *core.Store, arena: std.mem.Allocator) !core.Edge {
        if (store != self.scope.store) return error.ForeignStore;
        if (self.phase != .reserved or store.phase != .staging) return error.WrongPhase;
        if (try store.proposed(self.scope.epoch.?.object) != null) return error.LiveReferenceExpired;
        if (self.staged) |staged| if (std.meta.eql(staged.ticket, store.ticket.?)) return staged.edge;
        const edge = try (Recipe{ .live = self.scope.epoch.? }).stage(store, arena);
        self.staged = .{ .ticket = store.ticket.?, .edge = edge };
        return edge;
    }

    /// Call references own this confirmation independently of continuations.
    /// It runs at known storage completion, before reply projection can refuse.
    pub fn finish(self: *Reservation, ticket: core.Ticket, committed: bool) void {
        if (self.phase != .reserved) return;
        if (!committed) return; // Call retirement cancels confirmed absence.
        const staged = self.staged orelse return;
        if (!std.meta.eql(staged.ticket, ticket)) return;
        self.scope.by_recipe.putAssumeCapacityNoClobber(staged.edge.target, self);
        self.phase = .committed;
    }

    pub fn cancel(self: *Reservation) void {
        if (self.phase == .reserved) self.scope.release(self);
    }
};
