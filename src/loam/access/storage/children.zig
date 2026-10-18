//! Opaque child iteration filters every item through current grant admission.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const op = @import("capability_operation.zig");
const DirectoryQuery = @import("directory_query.zig").DirectoryQuery;
const Load = @import("load.zig").Load;
const Read = @import("read.zig").Read;

const State = struct {
    operation: *op.Operation,
    parent: core.ResourceId,
    requirement: core.Policy.Requirement,
    query: DirectoryQuery,
    load: Load = .{},
    entry: ?DirectoryQuery.Entry = null,
    candidate: ?core.ResourceId = null,
    pending: ?struct { ticket: loam.Ticket, owner: enum { query, candidate, authority } } = null,
    cancelled: bool = false,
};

pub fn create(operation: *op.Operation, parent: core.ResourceId, requirement: core.Policy.Requirement) !*Children {
    const value = op.state(operation);
    try value.unprepared();
    try operation.require(parent, requirement);
    const view = &value.read;
    const binding = (try view.binding(.{ .resource = parent })).?;
    const row = (try Read.rowFor(view.store, binding)).?.view;
    const parent_record = try records.ResourceRecord.decode(row);
    const allocator = value.binding.owner.allocator;
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    const permissions = try allocator.dupe(core.Policy.Key, requirement.permissions);
    errdefer allocator.free(permissions);
    const facts = try allocator.dupe(core.Policy.Bound, requirement.facts);
    errdefer allocator.free(facts);
    state.* = .{ .operation = operation, .parent = parent, .requirement = .{ .permissions = permissions, .facts = facts }, .query = DirectoryQuery.init(view, parent_record.children) };
    value.children += 1;
    return @ptrCast(state);
}

pub const Children = opaque {
    pub const Step = union(enum) { item: core.ResourceId, done, read: loam.Read, waiting };

    pub fn advance(self: *Children) !Step {
        const state: *State = @ptrCast(@alignCast(self));
        if (state.cancelled) return error.Cancelled;
        if (state.pending != null) return .waiting;
        const operation = state.operation;
        const value = op.state(operation);
        try value.opened();
        const view = &value.read;
        for (0..16) |_| {
            if (state.candidate == null) {
                if (state.entry == null) {
                    switch (try state.query.advance()) {
                        .read => |request| {
                            state.pending = .{ .ticket = request.ticket, .owner = .query };
                            return .{ .read = request };
                        },
                        .waiting => return .waiting,
                        .ready => {},
                    }
                    state.entry = state.query.entry;
                    if (state.entry == null) return .done;
                }
                const entry = state.entry.?;
                const loaded = switch (try state.load.resolve(view.store, entry.object)) {
                    .read => |request| {
                        state.pending = .{ .ticket = request.ticket, .owner = .candidate };
                        return .{ .read = request };
                    },
                    .waiting => return .waiting,
                    .ready => |row| row,
                };
                defer loaded.release(view.store);
                const row = loaded.view;
                const record = try records.ResourceRecord.decodeChildOf(row, state.parent, entry.slot);
                state.candidate = record.resource.id;
            }
            operation.require(state.candidate.?, state.requirement) catch |err| switch (err) {
                error.RecordUnloaded => {
                    switch (try operation.advance()) {
                        .read => |request| {
                            state.pending = .{ .ticket = request.ticket, .owner = .authority };
                            return .{ .read = request };
                        },
                        .waiting => return .waiting,
                        .ready => {},
                    }
                    continue;
                },
                error.Denied, error.OutOfScope => {
                    try view.forgetResources();
                    state.candidate = null;
                    state.entry = null;
                    continue;
                },
                else => return err,
            };
            const binding = (try view.binding(.{ .resource = state.candidate.? })).?;
            const row = (try Read.rowFor(view.store, binding)).?.view;
            if (!row.id.eql(state.entry.?.object)) return error.InvalidRecord;
            const result = state.candidate.?;
            try view.forgetResources();
            state.candidate = null;
            state.entry = null;
            return .{ .item = result };
        }
        return .waiting;
    }

    pub fn completeRead(self: *Children, ticket: loam.Ticket, result: loam.ReadResult) !void {
        const state: *State = @ptrCast(@alignCast(self));
        const store = op.state(state.operation).binding.owner.store;
        const pending = state.pending orelse return error.StaleCompletion;
        if (!std.meta.eql(pending.ticket, ticket)) return error.StaleCompletion;
        state.pending = null;
        return switch (pending.owner) {
            .authority => state.operation.completeRead(ticket, result),
            .candidate => state.load.complete(store, ticket, result),
            .query => state.query.completeRead(ticket, result),
        };
    }

    pub fn cancel(self: *Children) !void {
        const state: *State = @ptrCast(@alignCast(self));
        const store = op.state(state.operation).binding.owner.store;
        try state.load.cancel(store);
        try state.query.load.cancel(store);
        if (state.pending) |pending| if (pending.owner == .authority) try state.operation.cancel();
        state.cancelled = true;
    }

    pub fn deinit(self: *Children) !void {
        const state: *State = @ptrCast(@alignCast(self));
        if (state.pending != null) return error.Busy;
        const value = op.state(state.operation);
        const allocator = value.binding.owner.allocator;
        value.children -= 1;
        allocator.free(state.requirement.permissions);
        allocator.free(state.requirement.facts);
        allocator.destroy(state);
    }
};
