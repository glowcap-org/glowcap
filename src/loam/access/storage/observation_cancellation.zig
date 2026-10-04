//! Cancellation releases context authority and composes publication retirement.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const Load = @import("load.zig").Load;
const Read = @import("read.zig").Read;
const record = @import("record.zig");

const State = struct {
    store: *loam.Store,
    object: loam.ObjectId,
    context: records.ObservationRecord,
    expected: u64,
    snapshot: u64,
    retention: loam.Retention,
    read: ?Read = null,
    load: Load = .{},
    index: records.ObservationIndexRecord = .{},
    index_expected: ?u64 = null,
    ready: bool = false,
    staged: bool = false,
    cancelled: bool = false,

    fn advance(self: *State) !@import("read.zig").Step {
        try self.current();
        if (self.ready) return .ready;
        if (self.context.descriptor == null) {
            self.ready = true;
            return .ready;
        }
        if (self.read == null) self.read = try Read.init(self.store.allocator, self.store, self.context.owner, 1);
        const step = try self.read.?.advance();
        if (step != .ready) return step;
        const root = self.read.?.header.observations orelse return error.InvalidRecord;
        const row = switch (try self.load.resolve(self.store, root)) {
            .read => |request| return .{ .read = request },
            .waiting => return .waiting,
            .ready => |row| row,
        };
        defer row.release(self.store);
        self.index = try records.ObservationIndexRecord.decode(row.view);
        self.index_expected = row.view.revision;
        self.ready = true;
        return .ready;
    }

    fn current(self: *State) !void {
        if (self.cancelled) return error.Cancelled;
        if (self.staged) return error.WrongPhase;
        if (self.store.phase == .uncertain) return error.RecoveryRequired;
        if (self.store.metadata.revision != self.snapshot) return error.RevisionConflict;
    }
};

pub const Cancellation = opaque {
    pub const Retirement = struct {
        context: *anyopaque,
        /// All publication rows were loaded during preparation. This callback
        /// stages their retirement through the existing owning hosting seam.
        stage: *const fn (*anyopaque, [2]?loam.ObjectId) anyerror!void,
    };

    pub fn init(store: *loam.Store, lease: loam.Lease) !*Cancellation {
        const view = try store.currentView(lease);
        const context = try records.ObservationRecord.decode(view);
        const value = try store.allocator.create(State);
        errdefer store.allocator.destroy(value);
        value.* = .{ .store = store, .object = view.id, .context = context, .expected = view.revision, .snapshot = store.metadata.revision, .retention = try store.retain(view.id) };
        return @ptrCast(value);
    }

    pub fn advance(self: *Cancellation) !@import("read.zig").Step {
        return backing(self).advance();
    }
    pub fn publications(self: *Cancellation) ![2]?loam.ObjectId {
        const value = backing(self);
        try value.current();
        return value.context.publications;
    }
    pub fn changed(self: *Cancellation) !bool {
        const value = backing(self);
        try value.current();
        if (!value.ready) return error.NotPrepared;
        return value.context.descriptor != null;
    }

    pub fn stage(self: *Cancellation, retirement: ?Retirement) !bool {
        const value = backing(self);
        try value.current();
        if (!value.ready or value.store.phase != .staging) return error.WrongPhase;
        if (value.context.descriptor == null) return false;
        for (value.context.publications) |publication| if (publication != null and retirement == null) return error.RetirementRequired;
        const store = value.store;
        var index = value.index;
        const read = &value.read.?;
        const root = read.header.observations.?;
        var expected = value.index_expected;
        if (try store.proposed(root)) |proposal| {
            index = try records.ObservationIndexRecord.decode(proposal.view);
            expected = proposal.expected;
        }
        try index.remove(value.object);
        errdefer store.abort() catch unreachable;
        read.transaction = store.ticket;
        if (retirement) |transition| try transition.stage(transition.context, value.context.publications);
        var contexts: [records.ObservationIndexRecord.capacity]loam.Edge = undefined;
        try record.putEncoded(store, root, records.profile.observation_index, index, try index.edges(&contexts), expected, false);
        var closed = value.context;
        closed.descriptor = null;
        closed.publications = @splat(null);
        closed.key = @splat(0);
        var edges: [records.ObservationRecord.max_edges]loam.Edge = undefined;
        try record.putEncoded(store, value.object, records.profile.observation, closed, closed.edges(&edges), value.expected, false);
        value.staged = true;
        return true;
    }

    pub fn completeRead(self: *Cancellation, ticket: loam.Ticket, completion: loam.ReadResult) !void {
        const value = backing(self);
        if (value.load.pending != null) return value.load.complete(value.store, ticket, completion);
        if (value.read) |*read| return read.completeRead(ticket, completion);
        return error.StaleCompletion;
    }
    pub fn cancel(self: *Cancellation) !void {
        const value = backing(self);
        try value.load.cancel(value.store);
        if (value.read) |*read| try read.cancel();
        value.cancelled = true;
    }
    pub fn deinit(self: *Cancellation) !void {
        const value = backing(self);
        const store = value.store;
        if (value.load.pending != null) return error.Busy;
        if (value.read) |*read| try read.deinit();
        try store.releaseRetention(value.retention);
        store.allocator.destroy(value);
    }
};
fn backing(self: *Cancellation) *State {
    return @ptrCast(@alignCast(self));
}
