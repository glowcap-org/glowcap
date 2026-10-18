//! Receipt-backed registration reserves both observer fronts before commit.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const Mutation = @import("mutation.zig").Mutation;
const core = @import("loam_access_core");
const Step = @import("step.zig").Step;

/// The context key seals one entropy per front.
const Key = @FieldType(records.ObservationRecord, "key");
const roles = std.enums.values(records.ObservationEndpointRecord.Role);
const role_count = roles.len;
const entropy_bytes = @sizeOf(driver.Host.DurableSwiss.Entropy);
comptime {
    std.debug.assert(@sizeOf(Key) == role_count * entropy_bytes);
}

pub const Registration = struct {
    call: *hosting.Call,
    config: *service.Service,
    endpoint: *const records.EndpointRecord,
    mutation: *Mutation,
    live: bool = false,
    registration: ?*storage.ObservationRegistration = null,
    key: Key = undefined,
    initialized: bool = false,
    proposed: bool = false,
    replay: ?driver.Value = null,
    fronts: [role_count]loam.ObjectId = undefined,
    publications: [role_count]loam.ObjectId = undefined,
    /// The bounded call owns these until staging, replay or refusal retires.
    leases: [Slot.count]?loam.Lease = @splat(null),
    expired_publications: records.ObservationRecord.Publications = @splat(null),
    pending: ?loam.Ticket = null,
    reservations: [role_count]?driver.Host.DurableReservation = @splat(null),

    /// Lease slots: a front, its publication, and an expired publication per
    /// role, plus the context and the lifetime marker.
    const Slot = struct {
        const front = 0;
        const context = front + role_count;
        const publication = context + 1;
        const marker = publication + role_count;
        const expired = marker + 1;
        const count = expired + role_count;
    };

    pub fn advance(self: *Registration, source: *storage.Operation) !Step {
        if (self.endpoint.content) |content| {
            const description = try loam.reload(source.describe(content.resource)) orelse return .more;
            if (description.access == .revoked) return error.Revoked;
        } else {
            const description = try loam.reload(source.describeControl()) orelse return .more;
            if (!description.available) return error.ControlRevoked;
        }
        if (self.mutation.lease == null) {
            if (!self.initialized) {
                const entropy = self.config.entropy orelse return error.EntropyRequired;
                for (0..role_count) |index| self.key[index * entropy_bytes ..][0..entropy_bytes].* = try entropy.draw();
                self.initialized = true;
            }
            if (self.registration == null) {
                const target = if (self.endpoint.content) |content| @as(?core.ResourceId, content.resource) else null;
                const lifetime: ?records.ObservationRecord.Lifetime = if (self.live) lifetime: {
                    const scope = self.call.attachment.options.live_scope orelse return error.LiveScopeRequired;
                    const epoch = scope.epoch orelse return error.LiveScopeNotStarted;
                    if (try self.load(Slot.marker, epoch.object)) |step| return step;
                    try epoch.check(self.store(), self.leases[Slot.marker].?);
                    break :lifetime .{ .marker = epoch.object, .revision = (try self.store().currentView(self.leases[Slot.marker].?)).revision };
                } else null;
                self.registration = try loam.reload((if (lifetime) |value| storage.ObservationRegistration.initLifetime(source, target, self.key, value) else storage.ObservationRegistration.init(source, target, self.key))) orelse return .more;
            }
            switch (try self.registration.?.advance()) {
                .ready => {},
                .waiting => return .waiting,
                .read => |request| return .{ .read = request },
            }
            self.expired_publications = try self.registration.?.expiredPublications();
            for (self.expired_publications, 0..) |publication, index| if (publication) |id| {
                if (try self.load(Slot.expired + index, id)) |step| return step;
            };
            return .ready;
        }
        if (self.replay == null) {
            const replay = try self.mutation.replay();
            if (replay != .list or replay.list.len != role_count) return error.InvalidRecord;
            for (replay.list, 0..) |value, index| {
                if (value != .capability) return error.InvalidRecord;
                self.fronts[index] = (try self.call.attachment.capture(value.capability)).target;
            }
            self.replay = replay;
        }
        for (self.fronts, roles, 0..) |front, role, index| {
            if (try self.load(Slot.front + index, front)) |step| return step;
            const endpoint = try records.ObservationEndpointRecord.decode(try self.store().currentView(self.leases[Slot.front + index].?));
            if (endpoint.role != role) return error.InvalidRecord;
            if (try self.load(Slot.context, endpoint.context)) |step| return step;
            const context = try records.ObservationRecord.decode(try self.store().currentView(self.leases[Slot.context].?));
            if (context.descriptor == null) return error.ObservationClosed;
            if (context.lifetime) |lifetime| {
                if (try self.load(Slot.marker, lifetime.marker)) |step| return step;
                if ((try self.store().currentView(self.leases[Slot.marker].?)).revision != lifetime.revision) return error.ObservationClosed;
            }
            if (!context.descriptor.?.eql(self.endpoint.descriptor) or !std.meta.eql(context.target, if (self.endpoint.content) |content| @as(?core.ResourceId, content.resource) else null)) return error.InvalidRecord;
            self.key = context.key;
            self.publications[index] = context.publications[index] orelse return error.InvalidRecord;
            if (try self.load(Slot.publication + index, self.publications[index])) |step| return step;
            const publication = try self.store().currentView(self.leases[Slot.publication + index].?);
            if (!(try hosting.publication.activeTarget(publication)).eql(front)) return error.InvalidRecord;
            if (!std.mem.eql(u8, publication.payload, &entropyFor(self.key, role))) return error.InvalidRecord;
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
        switch (try hosting.Preparation.acquire(self.store(), id)) {
            .ready => |lease| self.leases[index] = lease,
            .read => |request| {
                self.pending = request.ticket;
                return .{ .read = request };
            },
            .waiting => return .waiting,
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
    for (&self.fronts, &self.publications, roles) |*front, *publication, role| {
        front.* = try store.allocateId();
        publication.* = try hosting.publication.stageTarget(store, entropyFor(self.key, role), front.*);
    }
    const id = try self.registration.?.stageWithRetirement(.{ self.publications[0], self.publications[1] }, .{ .context = self, .stage = retire });
    for (self.fronts, roles) |front, role| {
        const payload = try (records.ObservationEndpointRecord{ .context = id, .role = role }).encodeAlloc(self.call.arena());
        try store.putCopying(.{ .id = front, .revision = 0, .schema = records.profile.observation_endpoint, .payload = payload, .edges = &.{.{ .target = id }} }, null);
    }
    self.proposed = true;
}
fn reply(call: *hosting.Call) !driver.Value {
    const self = backing(call.confirmation.?.context);
    if (self.proposed) call.requireDisclosedReply();
    const values = try call.arena().alloc(driver.Value, role_count);
    for (values, roles, 0..) |*value, role, index| {
        const ref = if (self.proposed) try call.propose(self.fronts[index]) else self.replay.?.list[index].capability;
        value.* = .{ .capability = try call.discloseHeld(ref) };
        self.reservations[index] = try call.attachment.host.reserveDurableCapability(entropyFor(self.key, role), ref);
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
fn retire(context: *anyopaque, publications: records.ObservationRecord.Publications) !void {
    const self = backing(context);
    for (publications, 0..) |publication, index| if (publication) |id| {
        const lease = self.leases[Registration.Slot.expired + index] orelse return error.NotPrepared;
        if (!(try self.store().currentView(lease)).id.eql(id)) return error.NotPrepared;
        try hosting.publication.stageRetirement(self.call.attachment, lease);
    };
}
/// Each front's secret derives from the context key under its own domain.
fn entropyFor(key: Key, role: records.ObservationEndpointRecord.Role) driver.Host.DurableSwiss.Entropy {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var hash: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&hash, switch (role) {
        .receive => "glowcap:observer:receive:1",
        .cancel => "glowcap:observer:cancel:1",
    }, &key);
    return hash[0..entropy_bytes].*;
}
