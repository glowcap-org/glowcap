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
const graph = @import("content_graph.zig");
const Mutation = @import("mutation.zig").Mutation;

/// Add the view inventory used by graph reference preparation. Private managed
/// state, mutation receipts, application storage and held fields are separate.
pub fn graphAllocationBound(pages: usize, payload_bytes: usize, fields: usize) !hosting.references.AllocationBound {
    var bound = try service.graphAllocationBound(pages, payload_bytes, fields);
    try bound.include(try std.math.mul(usize, try std.math.add(usize, pages, 1), @sizeOf(loam.RecordView)), @alignOf(loam.RecordView), 1);
    return bound;
}

/// Managed content invocation only: the complete inbound vector includes any
/// mutate sequence/method wrappers. Reply bounds cover both fresh and persisted
/// receipts for this profile's lifetime. Held counts application acquisitions,
/// including repeated fields. Receipt captures and replies are added here.
pub const InvocationBounds = struct {
    arguments: hosting.ValueBounds = .{},
    reply: hosting.ValueBounds = .{ .values = 1 },
    verb_bytes: usize = 0,
    held_occurrences: usize = 0,
    receipt: bool = false,
    dependent: bool = false,
};

pub fn invocationAllocationBound(shape: InvocationBounds) !hosting.references.AllocationBound {
    try shape.arguments.validate();
    try shape.reply.validate();
    if (shape.reply.values == 0) return error.InvalidArguments;
    var bound = try hosting.inputAllocationBound(shape.arguments, shape.verb_bytes, shape.dependent);
    try bound.include(@sizeOf(State), @alignOf(State), 1);
    const captured = try std.math.add(usize, shape.reply.capabilities, if (shape.receipt) shape.arguments.capabilities else 0);
    try bound.merge(try hosting.Call.heldAllocationBound(try std.math.add(usize, shape.held_occurrences, captured)));
    if (shape.receipt) try bound.merge(try Mutation.allocationBound(shape.arguments, shape.reply, shape.dependent));
    return bound;
}

const Inspection = @import("inspection.zig").Inspection;
const Request = @import("request.zig").Request;

/// One inline registration snapshot in the existing bounded call arena: no
/// allocation or payload copy. Admission, references and invocation must use
/// the same callbacks and borrowed context across storage waits. Re-looking up
/// the registration both repeats the scan and can change the admitted binding.
const BoundContent = struct {
    lease: loam.Lease,
    behavior: service.ContentBehavior,
    // One inline canonical snapshot shares the row already needed by admission.
    // Store-revision restart retires it with the existing call, without new leases.
    resource: ?storage.Operation.BoundResource = null,
};

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
    pending: ?struct { ticket: loam.Ticket, owner: enum { store, invoking, target, mutation, sharing, observation, references, graph, inventory } } = null,
    requirement: ?core.Policy.Requirement = null,
    changed: bool = false,
    control_prepared: bool = false,
    retry: service.RetryMode = .read_only,
    resource_action: ?storage.ResourceChange.Action = null,
    resource_prepared: bool = false,
    mutation: ?*Mutation = null,
    action_prepared: bool = false,
    ready: bool = false,
    content_delta: ?ContentDelta = null,
    content_graph: ?*graph.Prepared = null,
    graph_delta: ?graph.Delta = null,
    request: Request = .content,
    publication: ?loam.Lease = null,
    swiss: driver.Host.DurableSwiss = undefined,

    fn prepareAction(value: *State) !void {
        return Request.prepare(value);
    }

    fn store(self: *State) *loam.Store {
        return self.config.capabilities.store;
    }

    /// Source-mediated facades recheck their original intent against current
    /// scalar content. Reuse the admitted graph window. Restore no fields.
    fn prepareGraph(self: *State) !?hosting.Preparation.Step {
        const content = self.content.?;
        const spec = content.behavior.graph orelse return null;
        if (self.content_graph == null) self.content_graph = try graph.Prepared.create(self.store(), self.arena, spec, try self.store().currentView(content.lease), content.resource.?.object);
        switch (try self.content_graph.?.advanceCopying()) {
            .waiting => return .waiting,
            .read => |read| {
                self.pending = .{ .ticket = read.ticket, .owner = .graph };
                return .{ .read = read };
            },
            .ready => return null,
        }
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
                const endpoint = try records.EndpointRecord.decode(endpoint_view);
                const target_content = endpoint.content orelse return error.NotUsable;
                if (target_content.resource.owner != self.endpoint.content.?.resource.owner) {
                    // An attachment can host independent authority domains.
                    // Their policies meet through actual capability delivery,
                    // not one owner's evaluator over another owner's resource.
                    self.request = .forward;
                    self.dependent_object = null;
                    try self.store().release(self.dependent_endpoint_lease.?);
                    self.dependent_endpoint_lease = null;
                } else self.dependent_endpoint = endpoint;
            }
            if (self.dependent_endpoint) |endpoint| if (self.dependent_operation == null) {
                const lease = switch (try self.acquire(endpoint.descriptor)) {
                    .ready => |value| value,
                    .read => |read| return .{ .read = read },
                    .waiting => return .waiting,
                };
                defer self.store().release(lease) catch unreachable;
                const ref = try self.config.capabilities.restoreUse(lease);
                defer ref.release();
                self.dependent_operation = try ref.begin(self.config.record_capacity);
            };
        }
        // Classify independent owners before interpreting a target mutation.
        // Forwarding preserves its original verb, sequence and arguments.
        if (!self.action_prepared and self.request != .forward) try self.prepareAction();
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
            if (self.dependent_operation) |target_operation| {
                switch (try target_operation.advance()) {
                    .read => |read| {
                        self.pending = .{ .ticket = read.ticket, .owner = .target };
                        return .{ .read = read };
                    },
                    .waiting => return .waiting,
                    .ready => {},
                }
            }
            if (self.content != null and self.requirement == null) {
                const selected = self.dependent_operation orelse operation;
                if (self.content.?.resource == null) self.content.?.resource = selected.boundResource(bound_content.?.resource) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                if ((self.request != .forward or self.call.dispatch != null) and self.content.?.behavior.graph != null and self.content.?.behavior.graph.?.requirementNeedsGraph(self.verb)) {
                    if (try self.prepareGraph()) |step| return step;
                }
                const input = try self.invocation();
                const behavior = self.content.?.behavior;
                if (self.request == .forward and self.call.dispatch == null) {
                    const declare = behavior.dependent_requirement orelse return error.NotForwardable;
                    self.requirement = try declare(behavior.context, self.arena, input);
                } else {
                    self.requirement = try behavior.requirement(behavior.context, self.arena, input);
                    self.retry = try behavior.retry(behavior.context, self.verb, self.args);
                    if (behavior.resource) |decode| self.resource_action = try decode(behavior.context, self.arena, input);
                }
            }
            if (bound_content) |bound| {
                if (self.request == .describe) {
                    self.request.describe.* = operation.describe(bound.resource) catch |err| {
                        if (err == error.RecordUnloaded) continue;
                        return err;
                    };
                } else if (self.request == .mutation_sequence or self.request == .durable_name) {
                    // Receipt discovery and exact publication naming are
                    // metadata. Paused viewers can reopen observation without
                    // invoking content; revoked and foreign scope still refuse.
                    const description = operation.describe(bound.resource) catch |err| {
                        if (err == error.RecordUnloaded) continue;
                        return err;
                    };
                    switch (description.access) {
                        .revoked => return error.Revoked,
                        .out_of_scope => return error.OutOfScope,
                        .active, .paused => {},
                    }
                } else if (self.request != .observe) operation.require(bound.resource, self.requirement orelse .{ .permissions = &.{} }) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            } else if (self.request == .describe_control) {
                self.request.describe_control.* = operation.describeControl() catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            } else if (self.request == .inspect_access) {
                self.request.inspect_access.* = Inspection.prepare(operation) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            } else if (self.request == .inspect_fixed) {
                self.request.inspect_fixed.* = operation.inspectFixedAccess() catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            }

            if (self.dependent_operation) |target_operation| {
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
            if (self.request == .control and self.request.control != .revoke) operation.requireManagement() catch |err| {
                if (err == error.RecordUnloaded) continue;
                return err;
            };
            if (self.request == .durable_name and bound_content == null) {
                const description = operation.describeControl() catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                if (!description.available) return error.Revoked;
            }
            if (self.mutation) |mutation| switch (try mutation.advance()) {
                .waiting => return .waiting,
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .mutation };
                    return .{ .read = read };
                },
                .ready => {},
            };
            if (self.request.invokes()) if (self.mutation) |mutation| if (mutation.lease != null) {
                // Current source/target admission and exact receipt custody
                // already passed. Replay does not invoke or stage content, so
                // unrelated graph fields and new Saves cannot gate its result.
                self.ready = true;
                return .ready;
            };
            if (self.request == .control and !self.control_prepared) {
                self.changed = self.request.control.prepare(operation, self.config, self.arena, self.verb, self.args) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                self.control_prepared = true;
            }
            if (self.request == .content and self.retry != .read_only and bound_content != null) {
                const content_operation = self.dependent_operation orelse operation;
                storage.stage.prepareContent(content_operation, bound_content.?.resource) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            }
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
            if (self.request == .inventory) switch (try self.request.inventory.advance(operation)) {
                .more => continue,
                .waiting => return .waiting,
                .read => |read| {
                    self.pending = .{ .ticket = read.ticket, .owner = .inventory };
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
                if (try self.prepareGraph()) |step| return step;
                if (behavior.references) |declare| {
                    if (self.call.references == null) {
                        const requests = try declare(behavior.context, self.arena, try self.invocation());
                        if (self.content_graph) |prepared| {
                            const views = try self.arena.alloc(loam.RecordView, prepared.snapshot.pages.len + 1);
                            views[0] = view;
                            for (prepared.snapshot.pages, views[1..]) |page, *target| target.* = page.view;
                            // Root links are pages, not capability fields.
                            for (requests) |request| if (request == .restore or (request == .restore_record and (request.restore_record.record == 0 or request.restore_record.index == 0))) return error.NotReferenceField;
                            _ = try hosting.references.Set.createViews(self.call, views, requests);
                        } else _ = try hosting.references.Set.create(self.call, view, requests);
                    }
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

    fn invocation(self: *State) !service.ContentInvocation {
        const bound = self.content.?;
        return .{ .bound_resource = bound.resource.?, .delivery = if (self.request == .forward) .forwarding else .local, .content = try self.store().currentView(bound.lease), .graph = if (self.content_graph) |prepared| prepared.snapshot else null, .verb = self.verb, .args = self.args };
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
    const value = try call.arena().create(State);
    value.* = .{ .config = config, .call = call, .arena = call.arena(), .endpoint = try records.EndpointRecord.decode(call.view), .endpoint_object = call.view.id, .verb = verb, .args = args };
    if (call.dependent_target) |target| {
        if (value.endpoint.content == null) return error.NotUsable;
        if (call.dispatch != null) {
            value.request = .forward;
            return .{ .context = value, .advanceFn = advance, .completeFn = complete, .deinitFn = deinit };
        }
        if (call.attachment.entryFor(target)) |entry| {
            value.dependent_object = entry.id;
        } else |err| {
            if (err != error.NotDurable) return err;
            value.request = .forward;
            return .{ .context = value, .advanceFn = advance, .completeFn = complete, .deinitFn = deinit };
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
        .graph => value.content_graph.?.completeRead(ticket, result),
        .inventory => value.request.inventory.completeRead(ticket, result),
    };
}
fn deinit(context: *anyopaque) void {
    const value = state(context);
    std.debug.assert(value.pending == null);
    if (value.request == .derive) value.request.derive.deinit();
    if (value.request == .observe) value.request.observe.deinit();
    if (value.request == .inventory) value.request.inventory.deinit();
    if (value.request == .control) value.request.control.deinit();
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
            const bound = value.content.?;
            const intent = call.dispatch orelse hosting.Call.Intent{ .verb = value.verb, .args = value.args };
            if (bound.behavior.admit_forward) |admit| {
                const view = try value.store().currentView(bound.lease);
                var admission_call = service.ContentCallState.init(call, view, .{ .verb = value.verb, .args = value.args }, false, value.retry);
                admission_call.operation = value.operation;
                admission_call.graph = value.content_graph;
                try admit(bound.behavior.context, admission_call.handle(), try service.ForwardWork.measure(value.verb, intent));
                if (admission_call.replacement != null or admission_call.edits.items.len != 0 or admission_call.appended.items.len != 0 or admission_call.graph_replaced) return error.InvalidMutation;
            }
            call.forward = .{ .target = call.dependent_target.?, .verb = intent.verb, .args = intent.args };
            return .{ .void = {} };
        },
        .derive => |share| return share.invoke(),
        .observe => |registration| return registration.invoke(),
        .mutation_sequence => return .{ .integer = @intCast(value.endpoint.mutations.next) },
        .sequence => return .{ .integer = std.math.cast(i64, value.endpoint.derivations.next) orelse return error.SequenceExhausted },
        .durable_name => return .{ .string = value.swiss.slice() },
        .describe_control => |description| return @import("description.zig").control(call.arena(), description.*),
        .inspect_access => |inspection| return @import("inventory.zig").encode(call.arena(), &inspection.policy, inspection.item),
        .describe, .inspect_fixed => |description| return @import("description.zig").encode(call.arena(), description.*),
        .inventory => |page| return page.result.?,
        .content, .control => {},
    }
    if (value.mutation) |mutation| if (mutation.lease != null) return mutation.replay();
    if (value.content) |bound| {
        const view = try value.store().currentView(bound.lease);
        const behavior = bound.behavior;
        var content_call = service.ContentCallState.init(call, view, .{ .verb = value.verb, .args = value.args }, value.mutation != null, value.retry);
        content_call.graph = value.content_graph;
        content_call.operation = value.operation;
        const reply = try behavior.invoke(behavior.context, content_call.handle(), try value.invocation());
        if (value.retry == .read_only and (content_call.replacement != null or content_call.edits.items.len != 0 or content_call.appended.items.len != 0 or content_call.graph_replaced or value.resource_action != null)) return error.InvalidMutation;
        if (value.content_graph != null and content_call.replacement != null) return error.InvalidMutation;
        if (value.mutation) |mutation| {
            try mutation.retainResult(reply);
            call.transaction = .{ .context = value, .stage = stage };
        }
        value.content_delta = try ContentDelta.prepare(value.arena, view, content_call.replacement, content_call.edits.items, content_call.appended.items);
        value.graph_delta = content_call.graph_delta;
        if (value.content_delta != null or value.graph_delta != null or value.changed) {
            call.transaction = .{ .context = value, .stage = stage };
        }
        return reply;
    }
    if (value.request == .control and value.request.control == .attenuate) {
        call.transaction = .{ .context = value, .stage = stage };
        call.result = controlReply;
        call.confirmation = .{ .context = value, .apply = confirmControl, .requires_commit = true };
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
    if (value.graph_delta) |delta| try delta.stage(store);
    if (value.request == .control and value.request.control == .attenuate) {
        const descriptor = try value.config.capabilities.stageAttenuatedControl(value.operation.?, false);
        const endpoint = try store.allocateId();
        const publication = try hosting.publication.stageTarget(store, value.request.control.attenuate.entropy.?, endpoint);
        try storage.stage.endpointAtOperation(value.operation.?, value.arena, endpoint, .{ .descriptor = descriptor, .administration = value.endpoint.administration, .publication = publication }, false);
        const mutation = value.mutation orelse return error.RetryRequired;
        value.request.control.attenuate.proposed = try mutation.call.propose(endpoint);
        try mutation.retainResult(.{ .capability = value.request.control.attenuate.proposed.? });
    } else if (value.request == .control and value.request.control == .revoke) {
        _ = try value.operation.?.stageControlRevocation();
    } else if (value.changed and !value.resource_prepared) _ = try value.config.capabilities.stage(value.operation.?, false);
    if (value.resource_prepared) {
        _ = try storage.stage.resourceWithContent(value.operation.?, value.content_delta != null or value.graph_delta != null);
    } else if (value.content_delta != null or value.graph_delta != null) {
        const operation = value.dependent_operation orelse value.operation.?;
        const endpoint = value.dependent_endpoint orelse value.endpoint;
        try storage.stage.content(operation, endpoint.content.?.resource);
    }
    if (value.mutation) |mutation| try mutation.stage(store);
}

fn controlReply(call: *hosting.Call) !driver.Value {
    const value = state(call.preparation.?.context);
    const control = &value.request.control.attenuate;
    const capability = control.proposed orelse return error.NoPreparedChange;
    if (control.reservation == null) control.reservation = try call.attachment.host.reserveDurableCapability(control.entropy.?, capability);
    return .{ .capability = capability };
}

fn confirmControl(context: *anyopaque) void {
    state(context).request.control.attenuate.reservation.?.commit();
}
