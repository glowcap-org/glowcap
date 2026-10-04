//! Observer fronts reuse attachment preparation, commit and retirement custody.
const std = @import("std");
const loam = @import("loam_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const description = @import("description.zig");

const State = struct {
    call: *hosting.Call,
    config: *service.Service,
    endpoint: records.ObservationEndpointRecord,
    verb: []const u8,
    cursor: ?storage.Observation.Cursor,
    pending: ?loam.Ticket = null,
    observation: ?*storage.Observation = null,
    cancellation: ?*storage.ObservationCancellation = null,
    result: ?storage.Observation.Result = null,
    publication: ?loam.Lease = null,
    retirement_leases: [2]?loam.Lease = @splat(null),
    waiting: bool = false,
    ready: bool = false,
    changed: bool = false,

    fn store(self: *State) *loam.Store {
        return self.config.capabilities.store;
    }
    fn advance(self: *State) !hosting.Preparation.Step {
        if (self.ready) return .ready;
        if (self.waiting or self.pending != null) return .waiting;
        if (self.observation == null and self.cancellation == null and self.publication == null) {
            const lease = switch (try self.acquire(self.endpoint.context)) {
                .ready => |lease| lease,
                .read => |request| return .{ .read = request },
                .waiting => return .waiting,
            };
            defer self.store().release(lease) catch unreachable;
            if (std.mem.eql(u8, self.verb, "durable-name")) {
                const context = try records.ObservationRecord.decode(try self.store().currentView(lease));
                const id = context.publications[if (self.endpoint.role == .receive) @as(usize, 0) else 1] orelse return error.ObservationClosed;
                const published = switch (try self.acquire(id)) {
                    .ready => |held| held,
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                };
                errdefer self.store().release(published) catch unreachable;
                if (!(try hosting.publication.activeTarget(try self.store().currentView(published))).eql(self.call.view.id)) {
                    return error.InvalidRecord;
                }
                self.publication = published;
                self.ready = true;
                return .ready;
            }
            if (self.endpoint.role == .receive) self.observation = try storage.Observation.init(self.config.capabilities, lease, self.cursor, self.config.record_capacity) else self.cancellation = try storage.ObservationCancellation.init(self.store(), lease);
        }
        if (self.observation) |observation| {
            const step = try observation.advance();
            if (step != .ready) return switch (step) {
                .read => |request| .{ .read = request },
                .waiting => .waiting,
                .ready => unreachable,
            };
            const result = try observation.result();
            if (!result.changed and std.mem.eql(u8, self.verb, "receive")) {
                // Attachment restarts this preparation on the next commit.
                // Waiting retains no model leases or native source operation.
                try observation.deinit();
                self.observation = null;
                self.waiting = true;
                return .waiting;
            }
            self.result = result;
            // The snapshot owns every value. Attachment checks the Store
            // revision again before invocation, so a ready reply needs no
            // native operation or model leases while waiting its turn.
            try observation.deinit();
            self.observation = null;
        } else if (self.cancellation) |cancellation| {
            const step = try cancellation.advance();
            if (step != .ready) return switch (step) {
                .read => |request| .{ .read = request },
                .waiting => .waiting,
                .ready => unreachable,
            };
            self.changed = try cancellation.changed();
            const publications = try cancellation.publications();
            for (publications, 0..) |publication, index| if (publication) |id| {
                if (self.retirement_leases[index] == null) self.retirement_leases[index] = switch (try self.acquire(id)) {
                    .ready => |held| held,
                    .read => |request| return .{ .read = request },
                    .waiting => return .waiting,
                };
            };
        }
        self.ready = true;
        return .ready;
    }

    fn acquire(self: *State, id: loam.ObjectId) !union(enum) { ready: loam.Lease, read: loam.Read, waiting } {
        const acquired = self.store().acquire(id) catch |err| {
            if (err == error.PendingRead) return .waiting;
            return err;
        };
        return switch (acquired) {
            .ready => |lease| .{ .ready = lease },
            .read => |request| blk: {
                self.pending = request.ticket;
                break :blk .{ .read = request };
            },
        };
    }
};

pub fn behavior(config: *service.Service) hosting.Behavior {
    return .{ .schema = records.profile.observation_endpoint, .context = config, .prepare = prepare, .invoke = invoke };
}
fn prepare(call: *hosting.Call, verb: []const u8, args: []const driver.Value) !hosting.Preparation {
    const config: *service.Service = @ptrCast(@alignCast(call.context.?));
    const endpoint = try records.ObservationEndpointRecord.decode(call.view);
    if (call.dependent_target != null) return error.NoSuchMethod;
    var cursor: ?storage.Observation.Cursor = null;
    if (std.mem.eql(u8, verb, "durable-name")) {
        if (args.len != 0) return error.InvalidArguments;
    } else if (endpoint.role == .cancel) {
        if (!std.mem.eql(u8, verb, "cancel")) return error.NoSuchMethod;
        if (args.len != 0) return error.InvalidArguments;
    } else {
        if (!std.mem.eql(u8, verb, "receive") and !std.mem.eql(u8, verb, "poll")) return error.NoSuchMethod;
        if (args.len > 1 or (args.len == 1 and (args[0] != .bytes or args[0].bytes.len != @sizeOf(storage.Observation.Cursor)))) return error.InvalidArguments;
        if (args.len == 1) cursor = args[0].bytes[0..@sizeOf(storage.Observation.Cursor)].*;
    }
    const value = try call.arena.create(State);
    value.* = .{ .call = call, .config = config, .endpoint = endpoint, .verb = verb, .cursor = cursor };
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
        return value.store().completeRead(ticket, completion);
    }
    if (value.observation) |observation| return observation.completeRead(ticket, completion);
    if (value.cancellation) |cancellation| return cancellation.completeRead(ticket, completion);
    return error.StaleCompletion;
}
fn deinit(context: *anyopaque) void {
    const value = backing(context);
    std.debug.assert(value.pending == null);
    if (value.observation) |observation| observation.deinit() catch unreachable;
    if (value.cancellation) |cancellation| cancellation.deinit() catch unreachable;
    if (value.publication) |lease| value.store().release(lease) catch unreachable;
    for (value.retirement_leases) |lease| if (lease) |held| value.store().release(held) catch unreachable;
}
fn invoke(call: *hosting.Call, _: loam.RecordView, _: []const u8, _: []const driver.Value) !driver.Value {
    const value = backing(call.preparation.?.context);
    if (!value.ready) return error.NotPrepared;
    if (value.publication) |lease| {
        const view = try value.store().currentView(lease);
        const name = driver.Host.DurableSwiss.fromEntropy(view.payload[0..@sizeOf(driver.Host.DurableSwiss.Entropy)].*);
        return .{ .string = try call.arena.dupe(u8, name.slice()) };
    }
    if (value.cancellation != null) {
        if (value.changed) call.transaction = .{ .context = value, .stage = stage };
        return .{ .boolean = value.changed };
    }
    const result = value.result.?;
    const parts = try call.arena.alloc(driver.Value, 5);
    parts[0] = .{ .bytes = try call.arena.dupe(u8, &result.cursor) };
    parts[1] = switch (result.snapshot) {
        .use => |snapshot| try description.encode(call.arena, snapshot),
        .control => |snapshot| try description.controlSnapshot(call.arena, snapshot),
    };
    parts[2] = .{ .boolean = result.resync };
    parts[3] = .{ .boolean = result.changed };
    const flags = try call.arena.alloc(driver.Value, @intFromBool(result.notices.access) + @as(usize, @intFromBool(result.notices.target)) + @intFromBool(result.notices.inventory) + @intFromBool(result.notices.management));
    var count: usize = 0;
    inline for (.{ "access", "target", "inventory", "management" }) |field| if (@field(result.notices, field)) {
        flags[count] = .{ .symbol = field };
        count += 1;
    };
    parts[4] = .{ .list = flags };
    return .{ .tagged = .{ .tag = "access:observation", .value = parts } };
}
fn stage(context: *anyopaque, store: *loam.Store) !void {
    const value = backing(context);
    if (store != value.store()) return error.ForeignStore;
    _ = try value.cancellation.?.stage(.{ .context = value, .stage = retire });
}
fn retire(context: *anyopaque, publications: [2]?loam.ObjectId) !void {
    const value = backing(context);
    for (publications, value.retirement_leases) |publication, lease| if (publication) |id| {
        if (lease == null or !(try value.store().currentView(lease.?)).id.eql(id)) return error.NotPrepared;
        try hosting.publication.stageRetirement(value.call.attachment, lease.?);
    };
}
