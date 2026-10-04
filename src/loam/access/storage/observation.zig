//! Bounded committed replay, scoped by the exact descriptor retained at creation.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const caps = @import("capabilities.zig");
const op = @import("capability_operation.zig");
const Load = @import("load.zig").Load;
const snapshots = @import("observation_snapshot.zig");
const cursors = @import("observation_cursor.zig");

const State = struct {
    capabilities: *caps.Capabilities,
    context_id: loam.ObjectId,
    context: records.ObservationRecord,
    input: ?Cursor,
    position: ?cursors.Position,
    retention: loam.Retention,
    revision: u64,
    capacity: usize,
    load: Load = .{},
    operation: ?*op.Operation = null,
    prepared: ?snapshots.Prepared = null,
    result: ?Result = null,
    batch_index: usize = 0,
    flags: Notices = .{},
    cancelled: bool = false,
    pub const Cursor = cursors.Cursor;
    pub const Snapshot = snapshots.Snapshot;
    pub const Control = snapshots.Control;
    pub const Notices = packed struct(u8) { access: bool = false, target: bool = false, inventory: bool = false, management: bool = false, padding: u4 = 0 };
    pub const Result = struct { cursor: Cursor, snapshot: Snapshot, notices: Notices = .{}, resync: bool = false, changed: bool = true };
    pub const Step = @import("read.zig").Step;

    /// A committed context lease is authority, never a cursor by itself. This
    /// operation retains the context without pinning its bytes through waits.
    pub fn init(capabilities: *caps.Capabilities, lease: loam.Lease, cursor: ?Cursor, capacity: usize) !State {
        const view = try capabilities.store.currentView(lease);
        const context = try records.ObservationRecord.decode(view);
        if (context.descriptor == null) return error.ObservationClosed;
        if (capacity == 0 or capacity > capabilities.store.limits.max_leases -| 2) return error.InvalidLimits;
        const position = if (cursor) |value| try cursors.open(context.key, view.id, value) else null;
        return .{ .capabilities = capabilities, .context_id = view.id, .context = context, .input = cursor, .position = position, .retention = try capabilities.store.retain(view.id), .revision = capabilities.store.metadata.revision, .capacity = capacity };
    }

    pub fn advance(self: *State) !Step {
        if (self.cancelled) return error.Cancelled;
        const store = self.capabilities.store;
        if (store.phase == .uncertain) return error.RecoveryRequired;
        if (store.metadata.revision != self.revision) return error.RevisionConflict;
        if (store.phase != .idle) return .waiting;
        if (self.result != null) return .ready;
        if (self.operation == null) {
            const lease = switch (try self.load.acquire(store, self.context.descriptor.?)) {
                .read => |request| return .{ .read = request },
                .waiting => return .waiting,
                .ready => |lease| lease,
            };
            defer store.release(lease) catch unreachable;
            if (self.context.target != null) {
                const use = try self.capabilities.restoreUse(lease);
                defer use.release();
                self.operation = try use.begin(self.capacity);
            } else {
                const control = try self.capabilities.restoreControl(lease);
                defer control.release();
                self.operation = try control.begin(self.capacity);
            }
        }
        const operation = self.operation.?;
        // Each warm retry binds one scoped grant or resource. Both ancestry
        // families and the history root fit within this structural bound.
        for (0..2 * records.ChangeBatchRecord.max_path + 2) |_| {
            const step = try operation.advance();
            if (step == .ready and !op.state(operation).descriptor.owner.eql(self.context.owner)) return error.InvalidRecord;
            if (step != .ready) return step;
            if (self.prepared == null) {
                self.prepared = snapshots.prepare(operation, self.context.target) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                if (self.position) |position| if (std.mem.eql(u8, &position.digest, &self.prepared.?.digest)) {
                    self.result = .{ .cursor = self.input.?, .snapshot = self.prepared.?.snapshot, .changed = false };
                    return .ready;
                };
            }
            const read = &op.state(operation).read.?;
            read.prepareHistory() catch |err| {
                if (err == error.RecordUnloaded) continue;
                return err;
            };
            const history = &read.history;
            if (self.position) |position| {
                if (position.sequence >= history.next_sequence) return error.InvalidCursor;
                if (position.sequence < history.firstSequence() - 1) return self.finish(true);
            } else return self.finish(false);
            while (self.batch_index < history.count) {
                const index = self.batch_index;
                const sequence = history.firstSequence() + index;
                if (sequence <= self.position.?.sequence) {
                    self.batch_index += 1;
                    continue;
                }
                const row = switch (try self.load.resolve(store, history.batches[index])) {
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                    .ready => |row| row,
                };
                defer row.release(store);
                var batch = try records.ChangeBatchRecord.decodeOwned(store.allocator, row.view);
                defer batch.deinit(store.allocator);
                if (batch.value.sequence != sequence or batch.value.owner != read.header.owner) return error.InvalidRecord;
                for (batch.value.effects) |effect| self.project(effect);
                self.batch_index += 1;
            }
            const empty = !self.flags.access and !self.flags.target and !self.flags.inventory and !self.flags.management;
            if (empty) {
                // The scoped digest changed, but current authority can hide the
                // old effect's branch. Deliver only the authorized snapshot.
                if (self.prepared.?.snapshot == .use) self.flags.access = true else self.flags.management = true;
            }
            return self.finish(false);
        }
        return .waiting;
    }

    fn finish(self: *State, resync: bool) !Step {
        const input_position = if (self.position) |input| input.sequence else 0;
        const position = @max(self.context.started, @max(input_position, self.prepared.?.position));
        if (position >= op.state(self.operation.?).read.?.history.next_sequence) return error.InvalidRecord;
        self.result = .{ .cursor = cursors.seal(self.context.key, self.context_id, .{ .sequence = position, .digest = self.prepared.?.digest }), .snapshot = self.prepared.?.snapshot, .notices = self.flags, .resync = resync };
        return .ready;
    }

    fn project(self: *State, effect: records.ChangeBatchRecord.Effect) void {
        const prepared = &self.prepared.?;
        const own = op.state(self.operation.?).descriptor.grant;
        switch (effect) {
            .grant_retired => |grant| if (prepared.snapshot == .control and prepared.active() and contains(core.GrantId, grant.path, own)) {
                self.flags.inventory = true;
            },
            .grant => |grant| {
                if (contains(core.GrantId, prepared.grants[0..prepared.grant_count], grant.change.grant) and grant.change.kind != .issued) self.flags.access = true;
                if (prepared.snapshot == .control and prepared.active() and contains(core.GrantId, grant.path, own)) self.flags.inventory = true;
            },
            .content => |content| if (prepared.snapshot == .use and prepared.active() and content.id.eql(self.context.target.?)) {
                self.flags.target = true;
            },
            .resource => |resource| if (prepared.snapshot == .use and contains(core.ResourceId, prepared.resources[0..prepared.resource_count], resource.id)) {
                self.flags.access = true;
                if (prepared.active() and resource.id.eql(self.context.target.?)) self.flags.target = true;
            },
            .control => |control| if (prepared.snapshot == .control and control.kind == .revoked) {
                // Availability already includes the exact management dependency
                // chain. Hidden control creation cannot change this digest.
                self.flags.management = !prepared.snapshot.control.available;
            },
        }
        if (!prepared.active()) {
            self.flags.target = false;
            self.flags.inventory = false;
        }
    }

    pub fn completeRead(self: *State, ticket: loam.Ticket, result: loam.ReadResult) !void {
        if (self.load.pending != null) return self.load.complete(self.capabilities.store, ticket, result);
        if (self.operation) |operation| return operation.completeRead(ticket, result);
        return error.StaleCompletion;
    }

    pub fn cancel(self: *State) !void {
        try self.load.cancel(self.capabilities.store);
        if (self.operation) |operation| try operation.cancel();
        self.cancelled = true;
    }

    pub fn deinit(self: *State) !void {
        if (self.load.pending != null) return error.Busy;
        if (self.operation) |operation| try operation.deinit();
        try self.capabilities.store.releaseRetention(self.retention);
        self.* = undefined;
    }
};

fn contains(comptime Id: type, path: []const Id, target: Id) bool {
    for (path) |id| if (id.eql(target)) return true;
    return false;
}

pub const Observation = opaque {
    pub const Cursor = State.Cursor;
    pub const Snapshot = State.Snapshot;
    pub const Control = State.Control;
    pub const Notices = State.Notices;
    pub const Result = State.Result;
    pub const Step = State.Step;

    pub fn init(capabilities: *caps.Capabilities, lease: loam.Lease, cursor: ?Cursor, capacity: usize) !*Observation {
        if (capabilities.observations == capabilities.limits.max_operations) return error.OperationCapacity;
        const value = try capabilities.allocator.create(State);
        errdefer capabilities.allocator.destroy(value);
        value.* = try State.init(capabilities, lease, cursor, capacity);
        capabilities.observations += 1;
        return @ptrCast(value);
    }
    pub fn advance(self: *Observation) !Step {
        return state(self).advance();
    }
    pub fn completeRead(self: *Observation, ticket: loam.Ticket, completion: loam.ReadResult) !void {
        return state(self).completeRead(ticket, completion);
    }
    pub fn result(self: *Observation) !Result {
        const value = state(self);
        if (value.cancelled) return error.Cancelled;
        if (value.revision != value.capabilities.store.metadata.revision) return error.RevisionConflict;
        if (value.capabilities.store.phase == .uncertain) return error.RecoveryRequired;
        return value.result orelse error.NotPrepared;
    }
    pub fn cancel(self: *Observation) !void {
        return state(self).cancel();
    }
    pub fn deinit(self: *Observation) !void {
        const value = state(self);
        const owner = value.capabilities;
        try value.deinit();
        owner.observations -= 1;
        owner.allocator.destroy(value);
    }
};
fn state(self: *Observation) *State {
    return @ptrCast(@alignCast(self));
}
