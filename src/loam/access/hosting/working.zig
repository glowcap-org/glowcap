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
const ContentDelta = @import("content_delta.zig").ContentDelta;
const ObservationRegistration = @import("observation_registration.zig").Registration;
const Mutation = @import("mutation.zig").Mutation;

const ControlRequest = union(enum) {
    edit: ?core.Control.Edit,
    attenuate: struct { powers: ?core.Control.Powers = null, proposed: ?driver.Capability = null },
    revoke,

    fn prepare(self: ControlRequest, operation: *storage.Operation) !bool {
        return switch (self) {
            .edit => |edit| operation.prepareEditCopying(edit.?),
            .revoke => operation.prepareControlRevocation(),
            .attenuate => |attenuation| result: {
                try operation.prepareAttenuationCopying(attenuation.powers.?);
                break :result true;
            },
        };
    }
};

const Request = union(enum) {
    content,
    forward,
    control: ControlRequest,
    derive: *sharing.Sharing,
    observe: *ObservationRegistration,
    sequence,
    mutation_sequence,
    durable_name,
    describe: *storage.Operation.Description,
    describe_control: *storage.Operation.ControlDescription,

    fn invokes(self: Request) bool {
        return self == .content or self == .control;
    }
};

/// One inline registration snapshot in the existing bounded call arena: no
/// allocation or payload copy. Admission, references and invocation must use
/// the same callbacks and borrowed context across storage waits. Re-looking up
/// the registration both repeats the scan and can change the admitted binding.
const BoundContent = struct { lease: loam.Lease, behavior: service.ContentBehavior };

const State = struct {
    config: *service.Service,
    call: *hosting.Call,
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
    content: ?BoundContent = null,
    pending: ?struct { ticket: loam.Ticket, owner: enum { store, invoking, target, mutation, sharing, observation, references } } = null,
    requirement: ?core.Policy.Requirement = null,
    changed: bool = false,
    control_prepared: bool = false,
    retry: service.RetryMode = .read_only,
    resource_action: ?storage.ResourceChange.Action = null,
    resource_prepared: bool = false,
    mutation: ?*Mutation = null,
    ready: bool = false,
    content_delta: ?ContentDelta = null,
    request: Request = .content,
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
        if (bound_content != null and (self.request == .content or self.request == .forward)) {
            const bound = bound_content.?;
            if (self.content == null) {
                const lease = switch (try self.acquire(bound.object)) {
                    .ready => |lease| lease,
                    .read => |read| return .{ .read = read },
                    .waiting => return .waiting,
                };
                errdefer self.store().release(lease) catch unreachable;
                const view = try self.store().currentView(lease);
                const behavior = try self.config.contentBehavior(view);
                // Publish ownership only after lookup succeeds. A fallible
                // struct literal can write through the assignment's result
                // location before returning an error.
                self.content = .{ .lease = lease, .behavior = behavior };
            }
            if (self.requirement == null) {
                const view = try self.store().currentView(self.content.?.lease);
                const behavior = self.content.?.behavior;
                if (self.request == .forward) {
                    const declare = behavior.dependent_requirement orelse return error.NotForwardable;
                    self.requirement = try declare(behavior.context, self.arena, view, self.verb, self.args);
                } else {
                    self.requirement = try behavior.requirement(behavior.context, self.arena, view, self.verb, self.args);
                    self.retry = try behavior.retry(behavior.context, self.verb, self.args);
                    if (behavior.resource) |decode| self.resource_action = try decode(behavior.context, self.arena, bound.resource, view, self.verb, self.args);
                }
            }
        }
        const operation = self.operation.?;
        for (0..128) |_| {
            switch (try operation.advance()) {
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .invoking };
                    return .{ .read = read };
                },
                .waiting => return .waiting,
                .ready => {},
            }
            if (bound_content) |bound| {
                if (self.request == .describe) {
                    self.request.describe.* = operation.describe(bound.resource) catch |err| {
                        if (err == error.RecordUnloaded) continue;
                        return err;
                    };
                } else if (self.request != .observe) operation.require(bound.resource, self.requirement orelse .{ .permissions = &.{} }) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            } else if (self.request == .describe_control) {
                self.request.describe_control.* = operation.describeControl() catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            } else if (self.request == .control and !self.control_prepared) {
                const control = &self.request.control;
                if ((control.* == .edit and control.edit == null) or (control.* == .attenuate and control.attenuate.powers == null)) {
                    const description = operation.describeControl() catch |err| {
                        if (err == error.RecordUnloaded) continue;
                        return err;
                    };
                    switch (control.*) {
                        .edit => control.edit = try self.config.decode_control(self.config.context, self.arena, description.powers, self.verb, self.args),
                        .attenuate => control.attenuate.powers = try self.config.decode_attenuation.?(self.config.context, self.arena, description.powers, self.args),
                        .revoke => unreachable,
                    }
                }
                self.changed = self.request.control.prepare(operation) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                self.control_prepared = true;
            }
            if (self.dependent_operation) |target_operation| {
                switch (try target_operation.advance()) {
                    .read => |read| {
                        self.pending = .{ .ticket = read.ticket, .owner = .target };
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
            if (self.request.invokes() and self.retry == .receipt and self.mutation == null) return error.RetryRequired;
            if (self.resource_action) |action| if (!self.resource_prepared and (self.mutation == null or self.mutation.?.sequence == self.endpoint.mutations.next)) {
                if (self.dependent_object != null) return error.InvalidMutation;
                self.changed = operation.prepareResourceCopying(bound_content.?.resource, action, self.requirement.?) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                self.resource_prepared = true;
                continue;
            };
            if (self.request == .content and self.retry != .read_only and bound_content != null) {
                const content_operation = self.dependent_operation orelse operation;
                storage.stage.prepareContent(content_operation, bound_content.?.resource) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            }
            if (self.mutation) |mutation| switch (try mutation.advance()) {
                .waiting => return .waiting,
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .mutation };
                    return .{ .read = read };
                },
                .ready => {},
            };
            if (self.request == .derive) switch (try self.request.derive.advance(operation)) {
                .more => continue,
                .waiting => return .waiting,
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .sharing };
                    return .{ .read = read };
                },
                .ready => {},
            };
            if (self.request == .observe) switch (try self.request.observe.advance(operation)) {
                .more => continue,
                .waiting => return .waiting,
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .observation };
                    return .{ .read = read };
                },
                .ready => {},
            };
            if (self.request == .durable_name and self.publication == null) {
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
            if (self.request == .content and self.content != null) {
                const view = try self.store().currentView(self.content.?.lease);
                const behavior = self.content.?.behavior;
                if (behavior.references) |declare| {
                    if (self.call.references == null) _ = try hosting.references.Set.create(self.call, view, try declare(behavior.context, self.arena, view, self.verb, self.args));
                    switch (try self.call.references.?.advance()) {
                        .waiting => return .waiting,
                        .read => |read| {
                            self.pending = .{ .ticket = read.ticket, .owner = .references };
                            return .{ .read = read };
                        },
                        .ready => {},
                    }
                }
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
                self.pending = .{ .ticket = read.ticket, .owner = .store };
                break :blk .{ .read = read };
            },
        };
    }
};

pub fn prepare(call: *hosting.Call, verb: []const u8, args: []const driver.Value) !hosting.Preparation {
    const config: *service.Service = @ptrCast(@alignCast(call.context.?));
    if (config.capabilities.store != call.attachment.store) return error.ForeignStore;
    const value = try call.arena.create(State);
    value.* = .{ .config = config, .call = call, .arena = call.arena, .endpoint = try records.EndpointRecord.decode(call.view), .endpoint_object = call.view.id, .verb = verb, .args = args };
    if (call.dependent_target) |target| {
        if (value.endpoint.content == null) return error.NotUsable;
        if (call.attachment.entryFor(target)) |entry| {
            value.dependent_object = entry.id;
        } else |err| {
            if (err != error.NotDurable) return err;
            value.request = .forward;
            return .{ .context = value, .advanceFn = advance, .completeFn = complete, .deinitFn = deinit };
        }
    }
    if (std.mem.eql(u8, verb, "mutate")) {
        if (args.len < 2 or args[0] != .integer or args[0].integer < 1 or args[1] != .string) return error.InvalidArguments;
        value.verb = args[1].string;
        value.args = args[2..];
        if (std.mem.eql(u8, value.verb, "mutate") or std.mem.eql(u8, value.verb, "derive") or std.mem.eql(u8, value.verb, "derive-managed") or std.mem.eql(u8, value.verb, "describe-control") or std.mem.eql(u8, value.verb, "mutation-sequence") or std.mem.eql(u8, value.verb, "derivation-sequence") or std.mem.eql(u8, value.verb, "describe-access") or std.mem.eql(u8, value.verb, "durable-name")) return error.InvalidMutation;
        const mutation = try call.arena.create(Mutation);
        mutation.* = try Mutation.init(call, &value.endpoint, @intCast(args[0].integer), value.verb, value.args, value.dependent_object);
        value.mutation = mutation;
    } else if (std.mem.eql(u8, verb, "mutation-sequence")) {
        if (args.len != 0) return error.InvalidArguments;
        value.request = .mutation_sequence;
    }
    if (std.mem.eql(u8, value.verb, "observe")) {
        if (value.mutation == null) return error.RetryRequired;
        if (value.args.len != 0) return error.InvalidArguments;
        if (value.dependent_object != null) return error.NoSuchMethod;
        const registration = try call.arena.create(ObservationRegistration);
        registration.* = .{ .call = call, .config = config, .endpoint = &value.endpoint, .mutation = value.mutation.? };
        value.request = .{ .observe = registration };
    }
    if (value.endpoint.content == null and value.request == .content) {
        if (std.mem.eql(u8, value.verb, "describe-control")) {
            if (value.args.len != 0) return error.InvalidArguments;
            value.request = .{ .describe_control = try call.arena.create(storage.Operation.ControlDescription) };
        } else if (std.mem.eql(u8, value.verb, "attenuate-control")) {
            if (config.decode_attenuation == null) return error.NoSuchMethod;
            value.request = .{ .control = .{ .attenuate = .{} } };
            value.retry = .receipt;
        } else if (std.mem.eql(u8, value.verb, "revoke-control")) {
            if (value.args.len != 0) return error.InvalidArguments;
            value.request = .{ .control = .revoke };
        } else value.request = .{ .control = .{ .edit = null } };
    }
    if (value.endpoint.content != null and value.dependent_object == null and value.mutation == null and value.request == .content) {
        if (std.mem.eql(u8, verb, "derive") or std.mem.eql(u8, verb, "derive-managed")) {
            const share = try call.arena.create(sharing.Sharing);
            share.* = try (if (std.mem.eql(u8, verb, "derive-managed")) sharing.Sharing.initManaged(call, config, &value.endpoint, args) else sharing.Sharing.init(call, config, &value.endpoint, args));
            value.request = .{ .derive = share };
        } else if (std.mem.eql(u8, verb, "describe-access")) {
            if (args.len != 0) return error.InvalidArguments;
            value.request = .{ .describe = try call.arena.create(storage.Operation.Description) };
        } else if (std.mem.eql(u8, verb, "derivation-sequence") or std.mem.eql(u8, verb, "durable-name")) {
            if (args.len != 0) return error.InvalidArguments;
            value.request = if (std.mem.eql(u8, verb, "durable-name")) .durable_name else .sequence;
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
    const pending = value.pending orelse return error.StaleCompletion;
    if (!std.meta.eql(pending.ticket, ticket)) return error.StaleCompletion;
    value.pending = null;
    return switch (pending.owner) {
        .store => value.store().completeRead(ticket, result),
        .invoking => value.operation.?.completeRead(ticket, result),
        .target => value.dependent_operation.?.completeRead(ticket, result),
        .mutation => value.mutation.?.completeRead(ticket, result),
        .sharing => value.request.derive.completeRead(ticket, result),
        .observation => value.request.observe.completeRead(ticket, result),
        .references => value.call.references.?.completeRead(ticket, result),
    };
}
fn deinit(context: *anyopaque) void {
    const value = state(context);
    std.debug.assert(value.pending == null);
    if (value.request == .derive) value.request.derive.deinit();
    if (value.request == .observe) value.request.observe.deinit();
    if (value.mutation) |mutation| mutation.deinit();
    if (value.operation) |operation| operation.deinit() catch unreachable;
    if (value.dependent_operation) |operation| operation.deinit() catch unreachable;
    if (value.content) |bound| value.store().release(bound.lease) catch unreachable;
    if (value.dependent_endpoint_lease) |lease| value.store().release(lease) catch unreachable;
    if (value.publication) |lease| value.store().release(lease) catch unreachable;
}

pub fn invoke(call: *hosting.Call, _: loam.RecordView, _: []const u8, _: []const driver.Value) !driver.Value {
    const value = state(call.preparation.?.context);
    if (!value.ready) return error.RecordUnloaded;
    switch (value.request) {
        .forward => {
            call.forward = .{ .target = call.dependent_target.?, .verb = value.verb, .args = value.args };
            return .{ .void = {} };
        },
        .derive => |share| return share.invoke(),
        .observe => |registration| return registration.invoke(),
        .mutation_sequence => return .{ .integer = @intCast(value.endpoint.mutations.next) },
        .sequence => return .{ .integer = std.math.cast(i64, value.endpoint.derivations.next) orelse return error.SequenceExhausted },
        .durable_name => return .{ .string = value.swiss.slice() },
        .describe_control => |description| return @import("description.zig").control(call.arena, description.*),
        .describe => |description| return @import("description.zig").encode(call.arena, description.*),
        .content, .control => {},
    }
    if (value.mutation) |mutation| if (mutation.lease != null) return mutation.replay();
    if (value.content) |bound| {
        const view = try value.store().currentView(bound.lease);
        const behavior = bound.behavior;
        var content_call = service.ContentCallState.init(call, view);
        const reply = try behavior.invoke(behavior.context, content_call.handle(), view, value.verb, value.args);
        if (value.retry == .read_only and (content_call.replacement != null or content_call.edits.items.len != 0 or content_call.appended.items.len != 0 or value.resource_action != null)) return error.InvalidMutation;
        if (value.mutation) |mutation| {
            try mutation.retainResult(reply);
            call.transaction = .{ .context = value, .stage = stage };
        }
        value.content_delta = try ContentDelta.prepare(value.arena, view, content_call.replacement, content_call.edits.items, content_call.appended.items);
        if (value.content_delta != null or value.changed) {
            call.transaction = .{ .context = value, .stage = stage };
        }
        return reply;
    }
    if (value.request == .control and value.request.control == .attenuate) {
        call.transaction = .{ .context = value, .stage = stage };
        call.result = controlReply;
        return .{ .void = {} };
    }
    const result: driver.Value = .{ .boolean = value.changed };
    if (value.mutation) |mutation| try mutation.retainResult(result);
    if (value.changed or value.mutation != null) call.transaction = .{ .context = value, .stage = stage };
    return result;
}

fn stage(context: *anyopaque, store: *loam.Store) !void {
    const value = state(context);
    if (store != value.store()) return error.ForeignStore;
    if (value.content_delta) |delta| {
        const view = try store.currentView(value.content.?.lease);
        try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .schema_version = view.schema_version, .rooted = view.rooted, .payload = delta.payload, .edges = try delta.stageEdges(store, value.arena) }, view.revision);
    }
    if (value.request == .control and value.request.control == .attenuate) {
        const descriptor = try value.config.capabilities.stageAttenuatedControl(value.operation.?, false);
        const endpoint = try service.stageDerivedEndpoint(value.operation.?, value.arena, .{ .descriptor = descriptor }, false);
        const mutation = value.mutation orelse return error.RetryRequired;
        value.request.control.attenuate.proposed = try mutation.call.propose(endpoint);
        try mutation.retainResult(.{ .capability = value.request.control.attenuate.proposed.? });
    } else if (value.request == .control and value.request.control == .revoke) {
        _ = try value.operation.?.stageControlRevocation();
    } else if (value.changed and !value.resource_prepared) _ = try value.config.capabilities.stage(value.operation.?, false);
    if (value.resource_prepared) {
        _ = try storage.stage.resourceWithContent(value.operation.?, value.content_delta != null);
    } else if (value.content_delta != null) {
        const operation = value.dependent_operation orelse value.operation.?;
        const endpoint = value.dependent_endpoint orelse value.endpoint;
        try storage.stage.content(operation, endpoint.content.?.resource);
    }
    if (value.mutation) |mutation| try mutation.stage(store);
}

fn controlReply(call: *hosting.Call) !driver.Value {
    return .{ .capability = state(call.preparation.?.context).request.control.attenuate.proposed orelse return error.NoPreparedChange };
}
