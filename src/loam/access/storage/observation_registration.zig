//! Prepared registration pins authority and joins the caller's Store batch.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const op = @import("capability_operation.zig");
const Load = @import("load.zig").Load;
const record = @import("record.zig");
const snapshot = @import("observation_snapshot.zig");

const State = struct {
    operation: *op.Operation,
    target: ?core.ResourceId,
    key: [32]u8,
    load: Load = .{},
    index: records.ObservationIndexRecord = .{},
    index_expected: ?u64 = null,
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
        if (self.index.count == records.ObservationIndexRecord.capacity) return error.ObservationCapacity;
        self.ready = true;
        return .ready;
    }

    pub fn completeRead(self: *State, ticket: loam.Ticket, result: loam.ReadResult) !void {
        return self.load.complete(op.state(self.operation).binding.owner.store, ticket, result);
    }

    /// Trusted publication composition supplies the already-allocated recipes.
    /// The returned context becomes observation authority only after commit.
    pub fn stage(self: *State, publications: [2]?loam.ObjectId) !loam.ObjectId {
        const state = op.state(self.operation);
        try state.opened();
        if (!self.ready or self.staged or self.cancelled) return error.WrongPhase;
        const store = state.binding.owner.store;
        if (store.phase != .staging) return error.WrongPhase;
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
        errdefer store.abort() catch unreachable;
        read.transaction = store.ticket;
        const context = try store.allocateId();
        const value: records.ObservationRecord = .{ .owner = read.owner_object, .descriptor = state.binding.object, .target = self.target, .key = self.key, .started = state.read.?.history.next_sequence - 1, .publications = publications };
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
        try self.load.cancel(op.state(self.operation).binding.owner.store);
        self.cancelled = true;
    }

    pub fn deinit(self: *State) !void {
        if (self.load.pending != null) return error.Busy;
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
        return backing(self).stage(publications);
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
