//! Trusted owner administration uses ordinary call, read and commit custody.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");

const State = struct {
    call: *hosting.Call,
    config: *service.Service,
    operation: *storage.Maintenance,
    publications: [2]?loam.Lease = @splat(null),
    pending: ?loam.Ticket = null,
    ready: bool = false,

    fn advance(self: *State) !hosting.Preparation.Step {
        if (self.ready) return .ready;
        if (self.pending != null) return .waiting;
        const prepared = try self.operation.advance();
        if (prepared != .ready) return switch (prepared) {
            .read => |request| .{ .read = request },
            .waiting => .waiting,
            .ready => unreachable,
        };
        const publications = try self.operation.publications();
        for (publications, 0..) |publication, index| if (publication) |id| {
            if (self.publications[index] != null) continue;
            const acquired = self.config.capabilities.store.acquire(id) catch |err| {
                if (err == error.PendingRead) return .waiting;
                return err;
            };
            switch (acquired) {
                .read => |request| {
                    self.pending = request.ticket;
                    return .{ .read = request };
                },
                .ready => |lease| self.publications[index] = lease,
            }
        };
        self.ready = true;
        return .ready;
    }
};

pub fn behavior(config: *service.Service) hosting.Behavior {
    return .{ .schema = records.profile.owner, .context = config, .prepare = prepare, .invoke = invoke };
}
pub fn terminalBehavior() hosting.Behavior {
    return .{ .schema = records.profile.terminal, .invoke = terminal };
}
fn terminal(_: *hosting.Call, view: loam.RecordView, _: []const u8, _: []const driver.Value) !driver.Value {
    _ = try records.TerminalRecord.decode(view);
    return error.CapabilityRetired;
}
fn prepare(call: *hosting.Call, verb: []const u8, args: []const driver.Value) !hosting.Preparation {
    const config: *service.Service = @ptrCast(@alignCast(call.context.?));
    if (call.dependent_target != null) return error.NoSuchMethod;
    const command: storage.Maintenance.Command = if (std.mem.eql(u8, verb, "retire-owner")) .retire else if (std.mem.eql(u8, verb, "sweep")) .sweep else if (std.mem.eql(u8, verb, "maintenance-step")) .step else return error.NoSuchMethod;
    if (args.len != 1 or args[0] != .integer or args[0].integer < 0) return error.InvalidArguments;
    const value = try call.arena.create(State);
    value.* = .{ .call = call, .config = config, .operation = try storage.Maintenance.init(config.capabilities.allocator, config.capabilities.store, call.view.id, command, @intCast(args[0].integer), config.record_capacity) };
    return .{ .context = value, .advanceFn = advance, .completeFn = complete, .deinitFn = deinit };
}
fn backing(context: *anyopaque) *State {
    return @ptrCast(@alignCast(context));
}
fn advance(context: *anyopaque) !hosting.Preparation.Step {
    return backing(context).advance();
}
fn complete(context: *anyopaque, ticket: loam.Ticket, completion: loam.ReadResult) !void {
    const value = backing(context);
    if (value.pending) |pending| {
        if (!std.meta.eql(pending, ticket)) return error.StaleCompletion;
        value.pending = null;
        return value.config.capabilities.store.completeRead(ticket, completion);
    }
    return value.operation.completeRead(ticket, completion);
}
fn deinit(context: *anyopaque) void {
    const value = backing(context);
    std.debug.assert(value.pending == null);
    for (value.publications) |lease| if (lease) |held| value.config.capabilities.store.release(held) catch unreachable;
    value.operation.deinit() catch unreachable;
}
fn invoke(call: *hosting.Call, _: loam.RecordView, _: []const u8, _: []const driver.Value) !driver.Value {
    const value = backing(call.preparation.?.context);
    if (!value.ready) return error.NotPrepared;
    const result = try value.operation.result();
    const parts = try call.arena.alloc(driver.Value, 4);
    parts[0] = .{ .integer = std.math.cast(i64, result.sequence) orelse return error.SequenceExhausted };
    parts[1] = .{ .symbol = @tagName(result.phase) };
    parts[2] = .{ .boolean = result.retired };
    parts[3] = .{ .boolean = result.replay };
    if (!result.replay) call.transaction = .{ .context = value, .stage = stage };
    return .{ .tagged = .{ .tag = "access:maintenance", .value = parts } };
}
fn stage(context: *anyopaque, store: *loam.Store) !void {
    const value = backing(context);
    if (store != value.config.capabilities.store) return error.ForeignStore;
    _ = try value.operation.stage(.{ .context = value, .stage = retire });
}
fn retire(context: *anyopaque, publications: [2]?loam.ObjectId) !void {
    const value = backing(context);
    for (publications, value.publications) |publication, lease| if (publication) |id| {
        if (lease == null or !(try value.config.capabilities.store.currentView(lease.?)).id.eql(id)) return error.NotPrepared;
        try hosting.publication.stageRetirement(value.call.attachment, lease.?);
    };
}
