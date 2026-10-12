//! Prepared registration pins authority and joins the caller's Store batch.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const op = @import("capability_operation.zig");
const Load = @import("load.zig").Load;
const record = @import("record.zig");
const snapshot = @import("observation_snapshot.zig");
const Cancellation = @import("observation_cancellation.zig").Cancellation;
const Lifetime = records.ObservationRecord.Lifetime;

const State = struct {
    operation: *op.Operation,
    target: ?core.ResourceId,
    key: [32]u8,
    lifetime: ?Lifetime = null,
    load: Load = .{},
    index: records.ObservationIndexRecord = .{},
    index_expected: ?u64 = null,
    index_loaded: bool = false,
    scanned: usize = 0,
    expired: ?*Cancellation = null,
    ready: bool = false,
    staged: bool = false,
    cancelled: bool = false,

    pub fn init(operation: *op.Operation, target: ?core.ResourceId, key: [32]u8) !State {
        const state = op.state(operation);
        try state.opened();
        try state.unprepared();
        try state.read.?.prepareHistory();
        const current = try snapshot.prepare(operation, target);
        if (current.snapshot == .use and current.snapshot.use.access == .revoked) return error.Revoked;
        if (current.snapshot == .control and !current.snapshot.control.available) return error.ControlRevoked;
        state.children += 1;
        return .{ .operation = operation, .target = target, .key = key };
    }

    pub fn advance(self: *State) !@import("read.zig").Step {
        if (self.cancelled) return error.Cancelled;
        if (self.staged) return error.WrongPhase;
        const state = op.state(self.operation);
        try state.opened();
        if (self.ready) return .ready;
        if (!self.index_loaded) {
            if (state.read.?.header.observations) |id| {
                const row = switch (try self.load.resolve(state.binding.owner.store, id)) {
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                    .ready => |row| row,
                };
                defer row.release(state.binding.owner.store);
                self.index = try records.ObservationIndexRecord.decode(row.view);
                self.index_expected = if (try state.binding.owner.store.proposed(id)) |proposal| proposal.expected else row.view.revision;
            }
            self.index_loaded = true;
        }
        if (self.lifetime) |lifetime| {
            // Reclaim at most one expired slot per registration. This bounds
            // transaction demand independently of how many callers crashed;
            // a full expired index always has room for its replacement.
            const store = state.binding.owner.store;
            while (self.expired == null and self.scanned < self.index.count) {
                const row = switch (try self.load.resolve(store, self.index.contexts[self.scanned])) {
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                    .ready => |row| row,
                };
                defer row.release(store);
                const context = try records.ObservationRecord.decode(row.view);
                if (context.lifetime) |prior| {
                    if (prior.marker.eql(lifetime.marker) and prior.revision != lifetime.revision) {
                        if (prior.revision > lifetime.revision) return error.InvalidRecord;
                        self.expired = try Cancellation.init(store, row.lease orelse return error.WrongPhase);
                    }
                }
                self.scanned += 1;
            }
            if (self.expired) |expired| {
                const step = try expired.advance();
                if (step != .ready) return step;
            }
        }
        if (self.index.count == records.ObservationIndexRecord.capacity and self.expired == null) return error.ObservationCapacity;
        self.ready = true;
        return .ready;
    }

    pub fn completeRead(self: *State, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.load.pending == null) if (self.expired) |expired| return expired.completeRead(ticket, result);
        return self.load.complete(op.state(self.operation).binding.owner.store, ticket, result);
    }

    /// Trusted publication composition supplies the already-allocated recipes.
    /// The returned context becomes observation authority only after commit.
    pub fn stage(self: *State, publications: [2]?loam.ObjectId, retirement: ?Cancellation.Retirement) !loam.ObjectId {
        const state = op.state(self.operation);
        try state.opened();
        if (!self.ready or self.staged or self.cancelled) return error.WrongPhase;
        const store = state.binding.owner.store;
        if (store.phase != .staging) return error.WrongPhase;
        errdefer store.abort() catch unreachable;
        if (self.expired) |expired| _ = try expired.stage(retirement);
        const read = &state.read.?;
        var header = read.header;
        var expected = read.header_revision;
        if (try store.proposed(read.owner_object)) |proposal| {
            header = try records.OwnerRecord.decode(proposal.view);
            expected = proposal.expected;
        }
        var index = self.index;
        var index_expected = self.index_expected;
        if (header.observations) |id| if (try store.proposed(id)) |proposal| {
            index = try records.ObservationIndexRecord.decode(proposal.view);
            index_expected = proposal.expected;
        };
        if (index.count == records.ObservationIndexRecord.capacity) return error.ObservationCapacity;
        read.transaction = store.ticket;
        const context = try store.allocateId();
        const value: records.ObservationRecord = .{ .owner = read.owner_object, .descriptor = state.binding.object, .target = self.target, .key = self.key, .started = state.read.?.history.next_sequence - 1, .publications = publications, .lifetime = self.lifetime };
        var edges: [records.ObservationRecord.max_edges]loam.Edge = undefined;
        try record.putEncoded(store, context, records.profile.observation, value, value.edges(&edges), null, false);
        try index.append(context);
        const root = header.observations orelse try store.allocateId();
        var contexts: [records.ObservationIndexRecord.capacity]loam.Edge = undefined;
        try record.putEncoded(store, root, records.profile.observation_index, index, try index.edges(&contexts), index_expected, false);
        header.observations = root;
        var roots: [records.OwnerRecord.max_edges]loam.Edge = undefined;
        try record.putEncoded(store, read.owner_object, records.profile.owner, header, header.edges(&roots), expected, true);
        read.header = header;
        self.staged = true;
        return context;
    }

    pub fn cancel(self: *State) !void {
        if (self.expired) |expired| try expired.cancel();
        try self.load.cancel(op.state(self.operation).binding.owner.store);
        self.cancelled = true;
    }

    pub fn deinit(self: *State) !void {
        if (self.load.pending != null) return error.Busy;
        if (self.expired) |expired| try expired.deinit();
        op.state(self.operation).children -= 1;
        self.* = undefined;
    }
};

pub const Registration = opaque {
    pub fn init(operation: *op.Operation, target: ?core.ResourceId, key: [32]u8) !*Registration {
        const allocator = op.state(operation).binding.owner.allocator;
        const value = try allocator.create(State);
        errdefer allocator.destroy(value);
        value.* = try State.init(operation, target, key);
        return @ptrCast(value);
    }
    pub fn advance(self: *Registration) !@import("read.zig").Step {
        return backing(self).advance();
    }
    pub fn completeRead(self: *Registration, ticket: loam.Ticket, result: loam.ReadResult) !void {
        return backing(self).completeRead(ticket, result);
    }
    pub fn stage(self: *Registration, publications: [2]?loam.ObjectId) !loam.ObjectId {
        return backing(self).stage(publications, null);
    }
    /// Runtime observations borrow an explicitly supplied trusted marker. One
    /// optional cancellation owns stale-context preparation through commit.
    /// No population-sized allocation or permanent runtime index is added.
    pub fn initLifetime(operation: *op.Operation, target: ?core.ResourceId, key: [32]u8, lifetime: Lifetime) !*Registration {
        const store = op.state(operation).binding.owner.store;
        if (lifetime.marker.store != store.metadata.store or lifetime.revision == 0) return error.InvalidRecord;
        const result = try init(operation, target, key);
        backing(result).lifetime = lifetime;
        return result;
    }
    pub fn expiredPublications(self: *Registration) ![2]?loam.ObjectId {
        return if (backing(self).expired) |expired| expired.publications() else @splat(null);
    }
    pub fn stageWithRetirement(self: *Registration, publications: [2]?loam.ObjectId, retirement: Cancellation.Retirement) !loam.ObjectId {
        return backing(self).stage(publications, retirement);
    }
    pub fn cancel(self: *Registration) !void {
        return backing(self).cancel();
    }
    pub fn deinit(self: *Registration) !void {
        const value = backing(self);
        const allocator = op.state(value.operation).binding.owner.allocator;
        try value.deinit();
        allocator.destroy(value);
    }
};
fn backing(self: *Registration) *State {
    return @ptrCast(@alignCast(self));
}
