//! Receipt-backed registration reserves both observer fronts before commit.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const Mutation = @import("mutation.zig").Mutation;

pub const Registration = struct {
    call: *hosting.Call,
    config: *service.Service,
    endpoint: *const records.EndpointRecord,
    mutation: *Mutation,
    live: bool = false,
    registration: ?*storage.ObservationRegistration = null,
    key: [32]u8 = undefined,
    initialized: bool = false,
    proposed: bool = false,
    replay: ?driver.Value = null,
    fronts: [2]loam.ObjectId = undefined,
    publications: [2]loam.ObjectId = undefined,
    // Existing replay custody plus one lifetime marker and two stale names.
    // The bounded call owns them until staging, replay or refusal retires.
    leases: [8]?loam.Lease = @splat(null),
    expired_publications: [2]?loam.ObjectId = @splat(null),
    pending: ?loam.Ticket = null,
    reservations: [2]?driver.Host.DurableReservation = @splat(null),
    pub const Step = union(enum) { ready, read: loam.Read, waiting, more };

    pub fn advance(self: *Registration, source: *storage.Operation) !Step {
        if (self.endpoint.content) |content| {
            const description = source.describe(content.resource) catch |err| {
                if (err == error.RecordUnloaded) return .more;
                return err;
            };
            if (description.access == .revoked) return error.Revoked;
        } else {
            const description = source.describeControl() catch |err| {
                if (err == error.RecordUnloaded) return .more;
                return err;
            };
            if (!description.available) return error.ControlRevoked;
        }
        if (self.mutation.lease == null) {
            if (!self.initialized) {
                const entropy = self.config.entropy orelse return error.EntropyRequired;
                for (0..2) |index| {
                    var bytes: driver.Host.DurableSwiss.Entropy = undefined;
                    try entropy.fill(entropy.context, &bytes);
                    @memcpy(self.key[index * 16 ..][0..16], &bytes);
                }
                self.initialized = true;
            }
            if (self.registration == null) {
                const target = if (self.endpoint.content) |content| @as(?@import("loam_access_core").ResourceId, content.resource) else null;
                const lifetime: ?records.ObservationRecord.Lifetime = if (self.live) lifetime: {
                    const scope = self.call.attachment.options.live_scope orelse return error.LiveScopeRequired;
                    const epoch = scope.epoch orelse return error.LiveScopeNotStarted;
                    if (try self.load(5, epoch.object)) |step| return step;
                    try epoch.check(self.store(), self.leases[5].?);
                    break :lifetime .{ .marker = epoch.object, .revision = (try self.store().currentView(self.leases[5].?)).revision };
                } else null;
                self.registration = (if (lifetime) |value| storage.ObservationRegistration.initLifetime(source, target, self.key, value) else storage.ObservationRegistration.init(source, target, self.key)) catch |err| {
                    if (err == error.RecordUnloaded) return .more;
                    return err;
                };
            }
            switch (try self.registration.?.advance()) {
                .ready => {},
                .waiting => return .waiting,
                .read => |request| return .{ .read = request },
            }
            self.expired_publications = try self.registration.?.expiredPublications();
            for (self.expired_publications, 0..) |publication, index| if (publication) |id| {
                if (try self.load(6 + index, id)) |step| return step;
            };
            return .ready;
        }
        if (self.replay == null) {
            const replay = try self.mutation.replay();
            if (replay != .list or replay.list.len != 2) return error.InvalidRecord;
            for (replay.list, 0..) |value, index| {
                if (value != .capability) return error.InvalidRecord;
                self.fronts[index] = (try self.call.attachment.capture(value.capability)).target;
            }
            self.replay = replay;
        }
        for (self.fronts, 0..) |front, index| {
            if (try self.load(index, front)) |step| return step;
            const endpoint = try records.ObservationEndpointRecord.decode(try self.store().currentView(self.leases[index].?));
            const role: @FieldType(records.ObservationEndpointRecord, "role") = if (index == 0) .receive else .cancel;
            if (endpoint.role != role) return error.InvalidRecord;
            if (try self.load(2, endpoint.context)) |step| return step;
            const context = try records.ObservationRecord.decode(try self.store().currentView(self.leases[2].?));
            if (context.descriptor == null) return error.ObservationClosed;
            if (context.lifetime) |lifetime| {
                if (try self.load(5, lifetime.marker)) |step| return step;
                if ((try self.store().currentView(self.leases[5].?)).revision != lifetime.revision) return error.ObservationClosed;
            }
            if (!context.descriptor.?.eql(self.endpoint.descriptor) or !std.meta.eql(context.target, if (self.endpoint.content) |content| @as(?@import("loam_access_core").ResourceId, content.resource) else null)) return error.InvalidRecord;
            self.key = context.key;
            self.publications[index] = context.publications[index] orelse return error.InvalidRecord;
            if (try self.load(3 + index, self.publications[index])) |step| return step;
            const publication = try self.store().currentView(self.leases[3 + index].?);
            if (!(try hosting.publication.activeTarget(publication)).eql(front)) return error.InvalidRecord;
            if (!std.mem.eql(u8, publication.payload, &entropyFor(self.key, index))) return error.InvalidRecord;
        }
        return .ready;
    }

    pub fn completeRead(self: *Registration, ticket: loam.Ticket, completion: loam.ReadResult) !void {
        if (self.pending) |pending| {
            if (!std.meta.eql(pending, ticket)) return error.StaleCompletion;
            self.pending = null;
            return self.store().completeRead(ticket, completion);
        }
        if (self.registration) |registration| return registration.completeRead(ticket, completion);
        return error.StaleCompletion;
    }

    pub fn invoke(self: *Registration) driver.Value {
        if (self.replay == null) self.call.transaction = .{ .context = self, .stage = stage };
        self.call.result = reply;
        self.call.confirmation = .{ .context = self, .apply = confirm };
        return .{ .void = {} };
    }
    pub fn deinit(self: *Registration) void {
        std.debug.assert(self.pending == null);
        for (&self.reservations) |*reservation| if (reservation.*) |*held| held.cancel();
        for (self.leases) |lease| if (lease) |held| self.store().release(held) catch unreachable;
        if (self.registration) |registration| registration.deinit() catch unreachable;
    }
    fn store(self: *Registration) *loam.Store {
        return self.config.capabilities.store;
    }
    fn load(self: *Registration, index: usize, id: loam.ObjectId) !?Step {
        if (self.leases[index]) |lease| {
            if (!(try self.store().currentView(lease)).id.eql(id)) return error.InvalidRecord;
            return null;
        }
        const acquired = self.store().acquire(id) catch |err| {
            if (err == error.PendingRead) return .waiting;
            return err;
        };
        switch (acquired) {
            .ready => |lease| self.leases[index] = lease,
            .read => |request| {
                self.pending = request.ticket;
                return .{ .read = request };
            },
        }
        return null;
    }
};

fn backing(context: *anyopaque) *Registration {
    return @ptrCast(@alignCast(context));
}
fn stage(context: *anyopaque, store: *loam.Store) !void {
    const self = backing(context);
    if (store != self.store()) return error.ForeignStore;
    for (&self.fronts, &self.publications, 0..) |*front, *publication, index| {
        front.* = try store.allocateId();
        publication.* = try hosting.publication.stageTarget(store, entropyFor(self.key, index), front.*);
    }
    const id = try self.registration.?.stageWithRetirement(.{ self.publications[0], self.publications[1] }, .{ .context = self, .stage = retire });
    for (self.fronts, 0..) |front, index| {
        const payload = try (records.ObservationEndpointRecord{ .context = id, .role = if (index == 0) .receive else .cancel }).encodeAlloc(self.call.arena());
        try store.putCopying(.{ .id = front, .revision = 0, .schema = records.profile.observation_endpoint, .payload = payload, .edges = &.{.{ .target = id }} }, null);
    }
    self.proposed = true;
}
fn reply(call: *hosting.Call) !driver.Value {
    const self = backing(call.confirmation.?.context);
    if (self.proposed) call.requireDisclosedReply();
    const values = try call.arena().alloc(driver.Value, 2);
    for (values, 0..) |*value, index| {
        const ref = if (self.proposed) try call.propose(self.fronts[index]) else self.replay.?.list[index].capability;
        value.* = .{ .capability = try call.discloseHeld(ref) };
        self.reservations[index] = try call.attachment.host.reserveDurableCapability(entropyFor(self.key, index), ref);
    }
    const result: driver.Value = .{ .list = values };
    if (self.proposed) {
        try self.mutation.retainResult(result);
        try self.mutation.stage(self.store());
    }
    return result;
}
fn confirm(context: *anyopaque) void {
    const self = backing(context);
    for (&self.reservations) |*reservation| reservation.*.?.commit();
}
fn retire(context: *anyopaque, publications: [2]?loam.ObjectId) !void {
    const self = backing(context);
    for (publications, 0..) |publication, index| if (publication) |id| {
        const lease = self.leases[6 + index] orelse return error.NotPrepared;
        if (!(try self.store().currentView(lease)).id.eql(id)) return error.NotPrepared;
        try hosting.publication.stageRetirement(self.call.attachment, lease);
    };
}
fn entropyFor(key: [32]u8, index: usize) driver.Host.DurableSwiss.Entropy {
    var hash: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&hash, if (index == 0) "glowcap:observer:receive:1" else "glowcap:observer:cancel:1", &key);
    return hash[0..16].*;
}
