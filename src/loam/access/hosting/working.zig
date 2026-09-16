//! A retained call's leases and current grant check, retired by ordinary hosting.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const storage = @import("loam_access_storage");
const loam = @import("loam_core");
const hosting = @import("loam_hosting");
const driver = @import("driver_core");
const service = @import("service.zig");
const sharing = @import("sharing.zig");

const State = struct {
    config: *service.Service,
    arena: std.mem.Allocator,
    endpoint: records.EndpointRecord,
    endpoint_object: loam.ObjectId,
    dependent_object: ?loam.ObjectId = null,
    dependent_endpoint_lease: ?loam.Lease = null,
    dependent_endpoint: ?records.EndpointRecord = null,
    verb: []const u8,
    args: []const driver.Value,
    operation: ?*storage.Operation = null,
    dependent_operation: ?*storage.Operation = null,
    authority_read: enum { none, invoking, target } = .none,
    content: ?loam.Lease = null,
    pending: ?loam.Ticket = null,
    requirement: ?core.Policy.Requirement = null,
    edit: ?core.Control.Edit = null,
    changed: bool = false,
    ready: bool = false,
    replacement: ?[]const u8 = null,
    reference_edits: []const service.ReferenceEdit = &.{},
    special: enum { none, derive, sequence, durable_name, describe } = .none,
    description: ?*storage.Operation.Description = null,
    share: ?*sharing.Sharing = null,
    share_read: bool = false,
    publication: ?loam.Lease = null,
    swiss: driver.Host.DurableSwiss = undefined,

    fn store(self: *State) *loam.Store {
        return self.config.capabilities.store;
    }

    fn advance(self: *State) !hosting.Preparation.Step {
        if (self.ready) return .ready;
        if (self.pending != null) return .waiting;
        if (self.operation == null) {
            const lease = switch (try self.acquire(self.endpoint.descriptor)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            defer self.store().release(lease) catch unreachable;
            if (self.endpoint.content != null) {
                const ref = try self.config.capabilities.restoreUse(lease);
                defer ref.release();
                self.operation = try ref.begin(self.config.record_capacity);
            } else {
                const ref = try self.config.capabilities.restoreControl(lease);
                defer ref.release();
                self.operation = try ref.begin(self.config.record_capacity);
            }
        }
        if (self.dependent_object) |object| {
            if (self.dependent_endpoint_lease == null) self.dependent_endpoint_lease = switch (try self.acquire(object)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            if (self.dependent_endpoint == null) {
                const endpoint_view = try self.store().currentView(self.dependent_endpoint_lease.?);
                self.dependent_endpoint = try records.EndpointRecord.decode(endpoint_view);
                if (self.dependent_endpoint.?.content == null) return error.NotUsable;
            }
            if (self.dependent_operation == null) {
                const lease = switch (try self.acquire(self.dependent_endpoint.?.descriptor)) {
                    .ready => |value| value,
                    .read => |read| return .{ .read = read },
                    .waiting => return .waiting,
                };
                defer self.store().release(lease) catch unreachable;
                const ref = try self.config.capabilities.restoreUse(lease);
                defer ref.release();
                self.dependent_operation = try ref.begin(self.config.record_capacity);
            }
        }
        // Content and metadata share one Store revision; hosting restarts both
        // after any intervening commit, including a queued activation.
        const bound_content = if (self.dependent_endpoint) |target| target.content else self.endpoint.content;
        if (bound_content != null and self.special == .none) {
            const bound = bound_content.?;
            if (self.content == null) self.content = switch (try self.acquire(bound.object)) {
                .ready => |lease| lease,
                .read => |read| return .{ .read = read },
                .waiting => return .waiting,
            };
            if (self.requirement == null) {
                const view = try self.store().currentView(self.content.?);
                const behavior = try self.config.contentBehavior(view);
                self.requirement = try behavior.requirement(self.arena, view, self.verb, self.args);
            }
        }
        const operation = self.operation.?;
        for (0..128) |_| {
            switch (try operation.advance()) {
                .read => |read| {
                    self.authority_read = .invoking;
                    return .{ .read = read };
                },
                .waiting => return .waiting,
                .ready => {},
            }
            if (bound_content) |bound| {
                if (self.special == .describe) {
                    self.description.?.* = operation.describe(bound.resource) catch |err| {
                        if (err == error.RecordUnloaded) continue;
                        return err;
                    };
                } else operation.require(bound.resource, self.requirement orelse .{ .permissions = &.{} }) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            } else {
                self.changed = operation.prepareEditCopying(self.edit.?) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            }
            if (self.dependent_operation) |target_operation| {
                switch (try target_operation.advance()) {
                    .read => |read| {
                        self.authority_read = .target;
                        return .{ .read = read };
                    },
                    .waiting => return .waiting,
                    .ready => {},
                }
                const target = self.dependent_endpoint.?.content.?;
                target_operation.require(target.resource, self.requirement.?) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            }
            if (self.share) |share| switch (try share.advance(operation)) {
                .more => continue,
                .waiting => return .waiting,
                .read => |read| {
                    self.share_read = true;
                    return .{ .read = read };
                },
                .ready => {},
            };
            if (self.special == .durable_name and self.publication == null) {
                const id = self.endpoint.publication orelse return error.NotPublished;
                self.publication = switch (try self.acquire(id)) {
                    .ready => |lease| lease,
                    .waiting => return .waiting,
                    .read => |read| return .{ .read = read },
                };
                const view = try self.store().currentView(self.publication.?);
                try sharing.validatePublication(view, self.endpoint_object);
                self.swiss = driver.Host.DurableSwiss.fromEntropy(view.payload[0..@sizeOf(driver.Host.DurableSwiss.Entropy)].*);
            }
            self.ready = true;
            return .ready;
        }
        return error.ActivationLimit;
    }

    fn acquire(self: *State, id: loam.ObjectId) !union(enum) { ready: loam.Lease, read: loam.Read, waiting } {
        const result = self.store().acquire(id) catch |err| {
            if (err == error.PendingRead) return .waiting;
            return err;
        };
        return switch (result) {
            .ready => |lease| .{ .ready = lease },
            .read => |read| blk: {
                self.pending = read.ticket;
                break :blk .{ .read = read };
            },
        };
    }
};

pub fn prepare(call: *hosting.Call, verb: []const u8, args: []const driver.Value) !hosting.Preparation {
    const config: *service.Service = @ptrCast(@alignCast(call.context.?));
    if (config.capabilities.store != call.attachment.store) return error.ForeignStore;
    const value = try call.arena.create(State);
    value.* = .{ .config = config, .arena = call.arena, .endpoint = try records.EndpointRecord.decode(call.view), .endpoint_object = call.view.id, .verb = verb, .args = args };
    if (call.dependent_target) |target| {
        if (value.endpoint.content == null) return error.NotUsable;
        value.dependent_object = (try call.attachment.entryFor(target)).id;
    }
    if (value.endpoint.content == null) value.edit = try config.decode_control(call.arena, verb, args);
    if (value.endpoint.content != null and value.dependent_object == null) {
        if (std.mem.eql(u8, verb, "derive")) {
            value.special = .derive;
            const share = try call.arena.create(sharing.Sharing);
            share.* = try sharing.Sharing.init(call, config, value.endpoint, args);
            value.share = share;
        } else if (std.mem.eql(u8, verb, "describe-access")) {
            if (args.len != 0) return error.InvalidArguments;
            value.special = .describe;
            value.description = try call.arena.create(storage.Operation.Description);
        } else if (std.mem.eql(u8, verb, "derivation-sequence") or std.mem.eql(u8, verb, "durable-name")) {
            if (args.len != 0) return error.InvalidArguments;
            value.special = if (std.mem.eql(u8, verb, "durable-name")) .durable_name else .sequence;
        }
    }
    return .{ .context = value, .advanceFn = advance, .completeFn = complete, .deinitFn = deinit };
}

fn state(context: *anyopaque) *State {
    return @ptrCast(@alignCast(context));
}
fn advance(context: *anyopaque) !hosting.Preparation.Step {
    return state(context).advance();
}
fn complete(context: *anyopaque, ticket: loam.Ticket, result: loam.ReadResult) !void {
    const value = state(context);
    if (value.share_read) {
        value.share_read = false;
        return value.share.?.completeRead(ticket, result);
    }
    if (value.pending) |pending| {
        if (!std.meta.eql(pending, ticket)) return error.StaleCompletion;
        value.pending = null;
        return value.store().completeRead(ticket, result);
    }
    const authority = value.authority_read;
    value.authority_read = .none;
    return switch (authority) {
        .none => error.StaleCompletion,
        .invoking => value.operation.?.completeRead(ticket, result),
        .target => value.dependent_operation.?.completeRead(ticket, result),
    };
}
fn deinit(context: *anyopaque) void {
    const value = state(context);
    std.debug.assert(value.pending == null);
    if (value.share) |share| share.deinit();
    if (value.operation) |operation| operation.deinit() catch unreachable;
    if (value.dependent_operation) |operation| operation.deinit() catch unreachable;
    if (value.content) |lease| value.store().release(lease) catch unreachable;
    if (value.dependent_endpoint_lease) |lease| value.store().release(lease) catch unreachable;
    if (value.publication) |lease| value.store().release(lease) catch unreachable;
}

pub fn invoke(call: *hosting.Call, _: loam.RecordView, verb: []const u8, args: []const driver.Value) !driver.Value {
    const value = state(call.preparation.?.context);
    if (!value.ready) return error.RecordUnloaded;
    switch (value.special) {
        .derive => return value.share.?.invoke(),
        .sequence => return .{ .integer = std.math.cast(i64, value.endpoint.next_derivation) orelse return error.SequenceExhausted },
        .durable_name => return .{ .string = value.swiss.slice() },
        .describe => return @import("description.zig").encode(call.arena, value.description.?.*),
        .none => {},
    }
    if (value.content) |lease| {
        const view = try value.store().currentView(lease);
        const behavior = try value.config.contentBehavior(view);
        var content_call = service.ContentCallState.init(call, view);
        const reply = try behavior.invoke(content_call.handle(), view, verb, args);
        if (content_call.replacement != null or content_call.edits.items.len != 0) {
            value.replacement = content_call.replacement;
            value.reference_edits = content_call.edits.items;
            call.transaction = .{ .context = value, .stage = stage };
        }
        return reply;
    }
    if (value.changed) call.transaction = .{ .context = value, .stage = stage };
    return .{ .boolean = value.changed };
}

fn stage(context: *anyopaque, store: *loam.Store) !void {
    const value = state(context);
    if (store != value.store()) return error.ForeignStore;
    if (value.replacement != null or value.reference_edits.len != 0) {
        const view = try store.currentView(value.content.?);
        var removed: usize = 0;
        for (value.reference_edits) |edit| if (edit.replacement == null) {
            removed += 1;
        };
        const edges = try value.arena.alloc(loam.Edge, view.edge_count - removed);
        var iterator = view.edges();
        var output: usize = 0;
        var index: usize = 0;
        while (iterator.next()) |committed| : (index += 1) {
            const replacement = for (value.reference_edits) |edit| {
                if (edit.index == index) break edit.replacement;
            } else @as(?loam.Edge, committed);
            if (replacement) |edge| {
                edges[output] = edge;
                output += 1;
            }
        }
        std.debug.assert(output == edges.len);
        try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .schema_version = view.schema_version, .rooted = view.rooted, .payload = value.replacement orelse view.payload, .edges = edges }, view.revision);
    } else _ = try value.config.capabilities.stage(value.operation.?, false);
}
