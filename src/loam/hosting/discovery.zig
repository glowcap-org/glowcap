//! Bounded cold publication lookup on the existing attachment's storage lane.
//! Names coalesce before I/O; only successful fetches create actor endpoints.
const std = @import("std");
const core = @import("loam_core");
const driver = @import("driver_core");
const h = @import("attachment.zig");
const publication = @import("publication.zig");
const storage = @import("storage.zig");

pub const Options = struct { max_names: usize = 16, max_fetches: usize = 64 };
const Waiter = struct { group: usize, fetch: driver.Host.PublicationFetch };
const Group = struct {
    entropy: publication.Entropy,
    lifetime: driver.Host.PendingWorkLease,
    phase: enum { queued, submitted, record, reading, failed, missing } = .queued,
    ticket: core.Ticket = undefined,
    id: core.ObjectId = undefined,
    failure: anyerror = error.LookupFailed,
};

pub const Discovery = struct {
    owner: *h.Attachment,
    registration: driver.Host.PublicationLookup,
    groups: []?Group,
    waiters: []?Waiter,
    sequence: u64 = 0,

    pub fn create(owner: *h.Attachment, options: Options) !*Discovery {
        try owner.topLevel();
        if (owner.discovery != null) return error.PublicationLookupInstalled;
        if (options.max_names == 0 or options.max_fetches == 0) return error.InvalidLimits;
        const configured = for (owner.store.cache.schemas) |schema| {
            if (schema.id == publication.schema.id and schema.version == publication.schema.version and schema.name_offset == 0) break true;
        } else false;
        if (!configured) return error.UnsupportedSchema;
        const self = try owner.allocator.create(Discovery);
        errdefer owner.allocator.destroy(self);
        const groups = try owner.allocator.alloc(?Group, options.max_names);
        errdefer owner.allocator.free(groups);
        @memset(groups, null);
        const waiters = try owner.allocator.alloc(?Waiter, options.max_fetches);
        errdefer owner.allocator.free(waiters);
        @memset(waiters, null);
        self.* = .{ .owner = owner, .registration = .{ .context = self, .idle = idle, .start = start, .cancel = cancel }, .groups = groups, .waiters = waiters };
        try owner.host.setPublicationLookup(&self.registration);
        owner.discovery = self;
        return self;
    }

    pub fn destroy(self: *Discovery) !void {
        try self.owner.host.clearPublicationLookup(&self.registration);
        self.owner.discovery = null;
        const allocator = self.owner.allocator;
        allocator.free(self.waiters);
        allocator.free(self.groups);
        allocator.destroy(self);
    }

    fn idle(context: *anyopaque) bool {
        const self: *Discovery = @ptrCast(@alignCast(context));
        for (self.groups) |group| if (group != null) return false;
        for (self.waiters) |waiter| if (waiter != null) return false;
        return true;
    }

    fn start(context: *anyopaque, name: []const u8, fetch: driver.Host.PublicationFetch) driver.Host.PublicationLookup.Admission {
        const self: *Discovery = @ptrCast(@alignCast(context));
        const entropy = driver.Host.DurableSwiss.parse(name) orelse return .unhandled;
        const waiter = for (self.waiters) |*slot| {
            if (slot.* == null) break slot;
        } else return .{ .refused = error.FetchCapacity };
        const index = for (self.groups, 0..) |group, i| {
            if (group) |g| if (std.mem.eql(u8, &g.entropy, &entropy)) break i;
        } else blk: {
            const i = for (self.groups, 0..) |group, i| {
                if (group == null) break i;
            } else return .{ .refused = error.LookupCapacity };
            const lifetime = self.owner.host.admitPendingWork() catch |err| return .{ .refused = err };
            self.groups[i] = .{ .entropy = entropy, .lifetime = lifetime };
            break :blk i;
        };
        waiter.* = .{ .group = index, .fetch = fetch };
        return .accepted;
    }

    fn cancel(context: *anyopaque, cancellation: driver.Host.PublicationLookup.Cancellation) void {
        const self: *Discovery = @ptrCast(@alignCast(context));
        for (self.waiters) |*slot| if (slot.*) |*waiter| {
            switch (cancellation) {
                .origin => |origin| {
                    if (!std.meta.eql(waiter.fetch.origin(), origin)) continue;
                    waiter.fetch.abandon();
                },
                .local_shutdown => |reason| {
                    if (waiter.fetch.destination != .local) continue;
                    waiter.fetch.closeLocal(reason);
                },
            }
            slot.* = null;
        };
    }

    fn hasWaiter(self: *Discovery, index: usize) bool {
        for (self.waiters) |slot| if (slot) |waiter| if (waiter.group == index) return true;
        return false;
    }

    fn release(self: *Discovery, index: usize) void {
        self.groups[index].?.lifetime.complete();
        self.groups[index] = null;
    }

    pub fn nextWork(self: *Discovery) !?core.NameLookup {
        if (self.owner.store.phase != .idle) return null;
        for (self.groups, 0..) |*slot, i| if (slot.*) |*group| {
            if (group.phase != .queued) continue;
            if (!self.hasWaiter(i)) {
                self.release(i);
                continue;
            }
            self.sequence = try std.math.add(u64, self.sequence, 1);
            const meta = self.owner.store.metadata;
            group.ticket = .{ .store = meta.store, .incarnation = meta.incarnation, .revision = meta.revision, .sequence = self.sequence };
            group.phase = .submitted;
            return .{ .ticket = group.ticket, .name = .{ .schema = publication.schema.id, .bytes = group.entropy } };
        };
        return null;
    }

    pub fn complete(self: *Discovery, ticket: core.Ticket, result: core.NameResult) !void {
        const group = for (self.groups) |*slot| {
            if (slot.*) |*g| if (g.phase == .submitted and std.meta.eql(g.ticket, ticket)) break g;
        } else return error.StaleCompletion;
        if (ticket.revision != self.owner.store.metadata.revision) {
            group.phase = .queued;
            return;
        }
        switch (result) {
            .found => |id| {
                if (id.store != ticket.store) {
                    group.failure = error.ForeignObject;
                    group.phase = .failed;
                    return;
                }
                group.id = id;
                group.phase = .record;
            },
            .missing => group.phase = .missing,
            .failed => |err| {
                group.failure = err;
                group.phase = if (err == error.StaleCompletion) .queued else .failed;
            },
        }
    }

    pub fn readFinished(self: *Discovery, id: core.ObjectId, failure: ?anyerror) bool {
        var matched = false;
        for (self.groups) |*slot| if (slot.*) |*group| {
            if (group.phase != .reading or !group.id.eql(id)) continue;
            matched = true;
            group.phase = .record;
            if (failure) |err| {
                group.failure = err;
                group.phase = if (err == error.StaleCompletion) .record else if (err == error.Gone) .missing else .failed;
            }
        };
        return matched;
    }

    pub fn advance(self: *Discovery) !void {
        _ = try self.advanceProgress();
    }

    /// Reports queued reads and settlements so an embedding drains the Host
    /// again after cold discovery, even when there are no actor calls yet.
    pub fn advanceProgress(self: *Discovery) !bool {
        var progressed = false;
        for (self.groups, 0..) |*slot, index| if (slot.*) |*group| {
            const prior_phase = group.phase;
            defer progressed = progressed or slot.* == null or slot.*.?.phase != prior_phase;
            // Submitted work owns its completion even after every caller leaves.
            if (group.phase == .submitted or group.phase == .reading) continue;
            if (!self.hasWaiter(index)) {
                self.release(index);
                continue;
            }
            if (self.owner.store.phase == .uncertain) {
                group.phase = .failed;
                group.failure = error.RecoveryRequired;
            } else if (self.owner.store.phase != .idle) continue;
            var target: ?driver.Capability = null;
            defer if (target) |ref| self.owner.host.releaseCapability(ref, 1) catch unreachable;
            if (group.phase == .record) {
                target = self.restore(group) catch |err| blk: {
                    if (err == error.PendingRead) continue;
                    group.failure = err;
                    group.phase = if (err == error.RetiredPublication or err == error.Gone) .missing else .failed;
                    break :blk null;
                };
                if (group.phase == .reading) continue;
            }
            if (group.phase == .queued) continue;
            for (self.waiters) |*waiter_slot| if (waiter_slot.*) |*waiter| {
                if (waiter.group != index) continue;
                try waiter.fetch.complete(if (target) |ref| .{ .found = ref } else if (group.phase == .missing) .missing else .{ .failed = @errorName(group.failure) });
                waiter_slot.* = null;
            };
            self.release(index);
        };
        return progressed;
    }

    fn restore(self: *Discovery, group: *Group) !?driver.Capability {
        const owner = self.owner;
        const acquired = owner.store.acquire(group.id) catch |err| {
            if (err == error.PendingRead) group.phase = .reading;
            return err;
        };
        switch (acquired) {
            .read => |read| {
                storage.retainRead(owner, read, null);
                group.phase = .reading;
                return null;
            },
            .ready => |lease| {
                defer owner.store.release(lease) catch unreachable;
                const view = try owner.store.currentView(lease);
                const target = try publication.activeTarget(view);
                if (!std.mem.eql(u8, view.payload, &group.entropy)) return error.InvalidPublication;
                return try h.restoreEdge(owner, target);
            },
        }
    }
};
