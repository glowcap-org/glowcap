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
const Participants = @import("participants.zig").Participants;
const Creation = @import("creation.zig").Creation;

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
    /// Further resources a method declares. Zig hosting only.
    participants: usize = 0,
    /// The method creates a child, so its reply is that child's facet. Its
    /// staging holds two more retains: the child endpoint and the facet.
    /// Zig hosting only.
    creates: bool = false,
};

pub fn invocationAllocationBound(declared: InvocationBounds) !hosting.references.AllocationBound {
    var shape = declared;
    if (shape.creates) {
        shape.reply.capabilities = try std.math.add(usize, shape.reply.capabilities, 1);
        shape.reply.values = @max(shape.reply.values, shape.reply.capabilities);
        shape.held_occurrences = try std.math.add(usize, shape.held_occurrences, 2);
    }
    try shape.arguments.validate();
    try shape.reply.validate();
    if (shape.reply.values == 0) return error.InvalidArguments;
    var bound = try hosting.inputAllocationBound(shape.arguments, shape.verb_bytes, shape.dependent);
    try bound.include(@sizeOf(State), @alignOf(State), 1);
    const captured = try std.math.add(usize, shape.reply.capabilities, if (shape.receipt) shape.arguments.capabilities else 0);
    try bound.merge(try hosting.Call.heldAllocationBound(try std.math.add(usize, shape.held_occurrences, captured)));
    if (shape.receipt) try bound.merge(try Mutation.allocationBound(shape.arguments, shape.reply, shape.dependent));
    try bound.merge(try Participants.allocationBound(shape.participants));
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

pub const State = struct {
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
    effects_declared: bool = false,
    resource_effect: ?service.ResourceEffect = null,
    resource_prepared: bool = false,
    participants: ?Participants = null,
    participants_ready: bool = false,
    creation: ?Creation = null,
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

    pub fn store(self: *State) *loam.Store {
        return self.config.capabilities.store;
    }

    /// Every managed effect of one call stages through one operation, so the
    /// call commits one owner header and one change batch. A dependent call
    /// stages through its target's operation.
    pub fn staging(self: *State) *storage.Operation {
        return self.dependent_operation orelse self.operation.?;
    }

    pub fn effectTarget(self: *State, bound: core.ResourceId) !core.ResourceId {
        return switch (self.resource_effect.?.target) {
            .bound => bound,
            .participant => |index| (self.participants orelse return error.NoSuchParticipant).resource(index),
        };
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
                target_operation.require(target.resource, self.requirement orelse .{ .permissions = &.{} }) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
            }
            if (self.request.invokes() and self.retry == .receipt and self.mutation == null) return error.RetryRequired;
            // A replay answers from its receipt, so only a fresh call resolves
            // participants and effects against current content.
            const fresh = self.mutation == null or self.mutation.?.sequence == self.endpoint.mutations.next;
            if (self.request == .content and self.content != null and fresh) {
                if (!self.effects_declared and self.participants == null) if (self.content.?.behavior.participants) |declare| {
                    if (self.content.?.behavior.graph != null) return error.NotReferenceField;
                    const input = try self.invocation();
                    const declared = try declare(self.content.?.behavior.context, self.arena, input);
                    if (declared.len != 0) self.participants = try .init(self.arena, self.call.attachment, declared, input.content, self.args);
                };
                if (self.participants) |*participants| if (!self.participants_ready) {
                    switch (try participants.advance(self.arena, self.store(), bound_content.?.resource.owner, bound_content.?.resource, .{ operation, self.dependent_operation }, self.staging())) {
                        .more => continue,
                        .waiting => return .waiting,
                        .read => |read| {
                            self.pending = .{ .ticket = read.ticket, .owner = .store };
                            return .{ .read = read };
                        },
                        .ready => {
                            // A participant's content takes plain field edits.
                            for (participants.loaded) |view| if ((try self.config.contentBehavior(view.content)).graph != null) return error.NotReferenceField;
                            self.participants_ready = true;
                        },
                    }
                };
                if (!self.effects_declared) {
                    const behavior = self.content.?.behavior;
                    const input = try self.invocation();
                    if (behavior.resource) |decode| self.resource_effect = try decode(behavior.context, self.arena, input);
                    if (behavior.create) |decode| if (try decode(behavior.context, self.arena, input)) |declared| {
                        self.creation = .{ .declared = declared };
                    };
                    if (self.creation != null and (self.resource_effect != null or self.mutation == null)) return error.InvalidMutation;
                    // A child's home is a plain strong field of the bound content.
                    if (self.creation != null and behavior.graph != null) return error.NotReferenceField;
                    self.effects_declared = true;
                }
            }
            if (self.resource_effect) |effect| if (!self.resource_prepared and fresh) {
                const target = try self.effectTarget(bound_content.?.resource);
                // The staging operation admits source and both parents, and
                // the invoking grant of a dependent call admits the same three.
                if (self.dependent_operation != null) operation.requireStructural(target, effect.action, self.requirement.?) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                self.changed = self.staging().prepareResourceCopying(target, effect.action, self.requirement.?) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                self.resource_prepared = true;
                continue;
            };
            if (self.creation) |*creation| if (!creation.prepared and fresh) {
                const describe = self.config.child_descriptor orelse return error.NoSuchMethod;
                const descriptor = describe(self.config.context, bound_content.?.resource.owner) orelse return error.NotUsable;
                switch (try creation.prepare(self.store(), descriptor, self.staging(), bound_content.?.resource, self.requirement.?)) {
                    .ready, .more => continue,
                    .waiting => return .waiting,
                    .read => |read| {
                        self.pending = .{ .ticket = read.ticket, .owner = .store };
                        return .{ .read = read };
                    },
                }
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
                storage.stage.prepareContent(self.staging(), bound_content.?.resource) catch |err| {
                    if (err == error.RecordUnloaded) continue;
                    return err;
                };
                if (self.participants) |*participants| if (try participants.prepareContent(self.staging()) == .more) continue;
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

    pub fn invocation(self: *State) !service.ContentInvocation {
        const bound = self.content.?;
        const participants: []const service.ParticipantView = if (self.participants_ready) self.participants.?.loaded else &.{};
        return .{ .bound_resource = bound.resource.?, .delivery = if (self.request == .forward) .forwarding else .local, .content = try self.store().currentView(bound.lease), .graph = if (self.content_graph) |prepared| prepared.snapshot else null, .participants = participants, .verb = self.verb, .args = self.args };
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

pub fn state(context: *anyopaque) *State {
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
    if (value.participants) |*participants| participants.release(value.store());
    if (value.creation) |*creation| creation.release(value.store());
}
