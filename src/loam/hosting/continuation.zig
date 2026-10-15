//! Owned runtime effect custody, activated only by confirmed receipt commit.
//! Durable effect records remain application content. This owner holds no lease.
const std = @import("std");
const driver = @import("driver_core");
const actors = @import("actors");
const model = @import("model");
const h = @import("attachment.zig");
const calls = @import("calls.zig");
const values = @import("values.zig");
const memory = @import("call_memory.zig");
const execution = @import("execution.zig");
const ReadScope = @import("read_scope.zig").Scope;

/// Callback-scoped receipt custody. Only confirmed activation yields the
/// owning continuation. The callback cannot dispatch or release a reservation.
pub const Reservation = opaque {
    pub fn source(self: *Reservation) driver.Capability {
        return reserved(self).source;
    }
    pub fn target(self: *Reservation, index: usize) !driver.Capability {
        const value = reserved(self);
        if (index >= value.targets.len) return error.NoSuchTarget;
        return value.targets[index];
    }
};
fn reserved(self: *Reservation) *State {
    return @ptrCast(@alignCast(self));
}

pub const Continuation = opaque {
    pub const Activation = struct {
        context: ?*anyopaque,
        /// Transfers the reservation's owning reference. The executor seat and
        /// work buffers must already exist. Activation cannot refuse or yield.
        activate: *const fn (?*anyopaque, *Continuation) void,
        /// Consumes the executor reservation after restart or confirmed absence.
        cancel: *const fn (?*anyopaque) void,
    };

    /// Independent physical allowance for immutable intent, target declarations,
    /// capability-retain spines and the continuation owner. Host actor/registry
    /// storage and executor buffers are separately bounded by their owners.
    pub fn sizeBound(arguments: values.Bounds, verb_bytes: usize, targets: usize) !usize {
        var bound = try @import("call_memory.zig").inputAllocationBound(arguments, verb_bytes, false);
        try bound.include(try std.math.mul(usize, targets, @sizeOf(driver.Value)), @alignOf(driver.Value), 1);
        try bound.include(try std.math.mul(usize, targets, @sizeOf(driver.Capability)), @alignOf(driver.Capability), 1);
        return std.math.add(usize, @sizeOf(State), try bound.physicalBytes());
    }

    /// Copies borrowed intent once and retains the actual invoking endpoint and
    /// each exact target. Separate custody is necessary because receipt commit
    /// retires the callback's arena, prepared graph and leases. Reservation is
    /// bounded before staging. Failure leaves activation ownership with caller.
    pub fn reserveCopying(call: *h.Call, intent: h.Call.Intent, targets: []const driver.Capability, activation: Activation) !*Reservation {
        if (call.confirmation != null) return error.DuplicateContinuation;
        const owner = call.attachment;
        if (owner.closing) return error.AttachmentClosed;
        if (owner.continuations >= owner.options.max_continuations or targets.len > owner.options.max_continuation_targets) return error.ContinuationCapacity;
        if (owner.options.continuation_bytes <= @sizeOf(State)) return error.ContinuationCapacity;
        const entry = owner.liveEntry(call.view.id) orelse return error.NotDurable;
        const value = try owner.allocator.create(State);
        errdefer owner.allocator.destroy(value);
        value.* = .{ .owner = owner, .activation = activation };
        value.memory.init(owner.allocator, owner.options.continuation_bytes - @sizeOf(State));
        errdefer value.memory.deinit();
        const arena = value.memory.input.allocator();
        const verb = try arena.dupe(u8, intent.verb);
        const args = try arena.alloc(driver.Value, intent.args.len);
        for (args, intent.args) |*out, item| out.* = try values.copy(driver.Value, arena, item);
        const retained_args = try owner.host.retainValueCapabilities(arena, args);
        errdefer owner.host.releaseCapabilityRetains(retained_args);
        const fields = try arena.alloc(driver.Value, targets.len);
        for (fields, targets) |*out, capability| out.* = .{ .capability = capability };
        const retained_targets = try owner.host.retainValueCapabilities(arena, fields);
        errdefer owner.host.releaseCapabilityRetains(retained_targets);
        const retained_source = try owner.host.retainLocalCapability(entry.actor.?);
        value.intent = .{ .verb = verb, .args = args };
        value.source = retained_source;
        value.arguments = retained_args;
        value.targets = retained_targets;
        owner.continuations += 1;
        owner.effect_continuations += 1;
        call.confirmation = .{ .context = value, .apply = confirm, .cancel = cancel, .requires_commit = true };
        return @ptrCast(value);
    }

    /// Borrow the exact source for receipt staging, never a descriptive ID.
    /// The reservation or activated executor owns its retain.
    pub fn source(self: *Continuation) driver.Capability {
        return state(self).source;
    }

    /// Creates one owned dispatch front. It retains this immutable continuation.
    /// Calls copy its original source intent into the existing durable queue.
    /// Current source admission and the exact target action are distinct. The
    /// target checks its own policy. No checked raw-target escape is returned.
    pub fn project(self: *Continuation, index: usize) !driver.Capability {
        return self.endpoint(index, .protected);
    }

    /// Lend only declared read methods over an exact retained target. Read
    /// scopes share immutable continuation custody. They copy no source intent
    /// or arguments. Every call and recursive result uses original admission.
    pub fn projectReadsCopying(self: *Continuation, index: usize, interfaces: []const ReadScope.Interface, role: usize) !driver.Capability {
        const admitted = try self.admission();
        const selected = try target(state(self), index);
        if (admitted.owner.closing) return error.AttachmentClosed;
        const scope = try ReadScope.createRetaining(self, interfaces);
        defer scope.release();
        return scope.project(selected, role);
    }

    pub const Admission = struct { owner: *h.Attachment, source: driver.Capability, intent: h.Call.Intent };
    pub fn admission(self: *Continuation) !Admission {
        const value = state(self);
        if (!value.active) return error.ContinuationUnconfirmed;
        return .{ .owner = value.owner, .source = value.source, .intent = value.intent };
    }
    pub fn retain(self: *Continuation) !void {
        const value = state(self);
        if (!value.active) return error.ContinuationUnconfirmed;
        if (value.references == std.math.maxInt(usize)) return error.ContinuationCapacity;
        if (value.references == value.read_references) value.owner.effect_continuations += 1;
        value.references += 1;
    }

    /// Read scopes retain immutable intent without extending executor lifetime.
    /// Separate retain kinds let attachment close distinguish passive readers
    /// from an executor or a still-held dispatch front, with no custody scan.
    pub fn retainForReadScope(self: *Continuation) !void {
        const value = state(self);
        if (!value.active) return error.ContinuationUnconfirmed;
        if (value.references == std.math.maxInt(usize)) return error.ContinuationCapacity;
        value.references += 1;
        value.read_references += 1;
    }

    pub fn releaseForReadScope(self: *Continuation) void {
        releaseState(state(self), true);
    }

    /// Execute through current source and exact-target admission. The private
    /// result owns the completed outcome even if source admission is lost
    /// while the target waits. Only the application receipt owner may consume
    /// it. Public results use project() and recheck outward disclosure.
    /// Cancellation releases the observer, not an admitted target effect.
    pub fn execute(self: *Continuation, allocator: std.mem.Allocator, index: usize, verb: []const u8, args: []const driver.Value, reply_bytes: usize) !*execution.Execution {
        const value = state(self);
        const dispatch = try execution.Dispatch.create(value.owner.host);
        errdefer dispatch.release();
        const front = try self.endpoint(index, .{ .receipt = dispatch });
        defer value.owner.host.releaseCapabilityTerminal(front, null);
        dispatch.call = try value.owner.host.callLocalCapability(allocator, front, verb, args, reply_bytes);
        return dispatch.handle();
    }

    fn endpoint(self: *Continuation, index: usize, completion: calls.Completion) !driver.Capability {
        const value = state(self);
        if (!value.active) return error.ContinuationUnconfirmed;
        _ = try target(value, index);
        if (value.owner.closing) return error.AttachmentClosed;
        if (value.references == std.math.maxInt(usize)) return error.ContinuationCapacity;
        try self.retain();
        completion.retain();
        // Spawn consumes the endpoint even on refusal. Its destructor owns this
        // reference; successful lift transfers fresh actor ownership to Host.
        const actor = try value.owner.host.vat.spawn(driver.Hosting(Endpoint), .{ .inner = .{ .continuation = self, .index = index, .completion = completion } });
        errdefer value.owner.host.vat.discardFreshActor(actor);
        return value.owner.host.liftLocalActor(actor);
    }

    /// Releases one owning reference. Dispatched calls own independent input
    /// copies and retains. Their observers do not own this runtime reservation.
    pub fn release(self: *Continuation) void {
        const value = state(self);
        std.debug.assert(value.active);
        releaseState(value, false);
    }
};

const State = struct {
    owner: *h.Attachment,
    memory: memory.Memory = undefined,
    source: driver.Capability = undefined,
    intent: h.Call.Intent = undefined,
    arguments: []driver.Capability = &.{},
    targets: []driver.Capability = &.{},
    activation: Continuation.Activation,
    references: usize = 1,
    read_references: usize = 0,
    active: bool = false,

    fn handle(self: *State) *Continuation {
        return @ptrCast(self);
    }
};
fn state(self: *Continuation) *State {
    return @ptrCast(@alignCast(self));
}
fn target(value: *State, index: usize) !driver.Capability {
    if (index >= value.targets.len) return error.NoSuchTarget;
    return value.targets[index];
}
fn releaseState(value: *State, read_scope: bool) void {
    std.debug.assert(value.references != 0);
    const effect_owned = value.references > value.read_references;
    if (read_scope) {
        std.debug.assert(value.read_references != 0);
        value.read_references -= 1;
    } else std.debug.assert(effect_owned);
    value.references -= 1;
    if (effect_owned and value.references == value.read_references) {
        std.debug.assert(value.owner.effect_continuations != 0);
        value.owner.effect_continuations -= 1;
    }
    if (value.references != 0) return;
    const owner = value.owner;
    owner.host.releaseCapabilityTerminal(value.source, null);
    for (value.arguments) |item| owner.host.releaseCapabilityTerminal(item, null);
    for (value.targets) |item| owner.host.releaseCapabilityTerminal(item, null);
    value.memory.deinit();
    owner.allocator.destroy(value);
    std.debug.assert(owner.continuations != 0);
    owner.continuations -= 1;
}
fn confirm(context: *anyopaque) void {
    const value: *State = @ptrCast(@alignCast(context));
    std.debug.assert(!value.active);
    value.active = true;
    value.activation.activate(value.activation.context, value.handle());
}
fn cancel(context: *anyopaque) void {
    const value: *State = @ptrCast(@alignCast(context));
    std.debug.assert(!value.active);
    value.activation.cancel(value.activation.context);
    releaseState(value, false);
}
const Endpoint = struct {
    continuation: *Continuation,
    index: usize,
    completion: calls.Completion,

    pub fn handle(self: *Endpoint, turn: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        const value = state(self.continuation);
        if (!value.active) return error.ContinuationUnconfirmed;
        try calls.admitContinuation(value.owner, value.source, turn, value.intent, try target(value, self.index), .{ .verb = verb, .args = arg_values }, self.completion);
        return .{ .void = {} };
    }
    pub fn handleLocal(self: *Endpoint, turn: *actors.Turn, message: actors.Delivery) !model.Argument {
        const value = state(self.continuation);
        if (!value.active) return error.ContinuationUnconfirmed;
        const args = try values.copyArgs(turn.arena, message.args);
        try calls.admitLocalContinuation(value.owner, value.source, turn, value.intent, try target(value, self.index), .{ .verb = message.verb, .args = args });
        return .{ .void = {} };
    }
    pub fn deinit(self: *Endpoint, _: std.mem.Allocator) void {
        self.continuation.release();
        self.completion.release();
    }
};
