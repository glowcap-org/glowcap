//! Bounded retained calls, dispatched through the existing Vat and settled by
//! its resolver machinery only after the associated storage outcome is known.
const std = @import("std");
const core = @import("loam_core");
const actors = @import("actors");
const driver = @import("driver_core");
const model = @import("model");
const h = @import("attachment.zig");
const values = @import("values.zig");
const storage = @import("storage.zig");
const forwarding = @import("forwarding.zig");
const execution = @import("execution.zig");
const call_memory = @import("call_memory.zig");
pub const Completion = union(enum) {
    protected,
    mediated: *const Projection,
    receipt: *execution.Dispatch,

    pub fn retain(self: Completion) void {
        if (self == .receipt) self.receipt.retain();
        if (self == .mediated) self.mediated.retain(self.mediated.context);
    }

    pub fn release(self: Completion) void {
        if (self == .receipt) self.receipt.release();
        if (self == .mediated) self.mediated.release(self.mediated.context);
    }
};

/// Immutable application interface custody. The admitted operation retains
/// this declaration independently of the endpoint that received its call.
/// Implementors are unknown at this declaration, so `project` keeps an
/// `anyerror` return set.
pub const Projection = struct {
    context: *anyopaque,
    retain: *const fn (*anyopaque) void,
    release: *const fn (*anyopaque) void,
    project: *const fn (*anyopaque, *h.Call, driver.Value) anyerror!driver.Value,
};

pub const Operation = struct {
    phase: enum { free, waiting, restarting, scheduled, materializing, forwarding, forwarded, disclosing, writing, settling, failed } = .free,
    entry: *h.Entry = undefined,
    sequence: u64 = 0,
    ingress: actors.IngressId = .local,
    peer: ?@FieldType(driver.HostSession, "peer_handle") = null,
    memory: call_memory.Memory = undefined,
    pending_read: bool = false,
    verb: []const u8 = "",
    args: []const driver.Value = &.{},
    argument_retains: []driver.Capability = &.{},
    dispatch: ?h.Call.Intent = null,
    dispatch_retains: []driver.Capability = &.{},
    resolver: union(enum) { local: u64, host: u64, none } = .none,
    lifetime: driver.Host.PendingWorkLease = .{ .host = null },
    lease: ?core.Lease = null,
    snapshot_revision: u64 = 0,
    call: ?h.Call = null,
    reply: driver.Value = .{ .void = {} },
    failure: anyerror = error.CallFailed,
    failure_kind: @FieldType(@FieldType(driver.Host.Call.Result, "failed"), "kind") = .broken,
    /// Borrows the owned forwarded result, or bounded call-arena text.
    failure_reason: ?[]const u8 = null,
    confirmed: bool = false,
    dependent_target: ?driver.Capability = null,
    forwarded: forwarding.Forwarding = .{},
    /// Public fronts protect outward delivery. Only the private continuation
    /// executor settles an already completed result into receipt custody.
    completion: Completion = .protected,
    /// A completed target result may only leave a public front after current
    /// source admission. Internal receipt settlement has a different owner.
    disclosure: enum { none, pending, checked } = .none,
    forwarded_failure: bool = false,
};

pub const Endpoint = struct {
    entry: *h.Entry,

    pub fn handle(self: *Endpoint, turn: *driver.HostTurn, verb: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        if (self.entry.owner.closing) return error.AttachmentClosed;
        if (turn.host != self.entry.owner.host) return error.ForeignTurn;
        try admit(self.entry, turn.turn, turn.session, verb, arg_values, null, null, .protected);
        return .{ .void = {} };
    }

    pub fn handleLocal(self: *Endpoint, turn: *actors.Turn, message: actors.Delivery) !model.Argument {
        const owner = self.entry.owner;
        if (owner.closing) return error.AttachmentClosed;
        if (turn.origin != .local) {
            const args = try values.copyArgs(turn.arena, message.args);
            try admit(self.entry, turn, null, message.verb, args, null, null, .protected);
            return .{ .void = {} };
        }
        // A cold near call cannot start I/O. Another pending call must finish
        // before this one observes or replaces the actor's committed state.
        for (owner.operations) |op| if (op.phase != .free and op.entry == self.entry) return error.ActorBusy;
        const lease = try owner.store.resident(self.entry.id);
        defer owner.store.release(lease) catch unreachable;
        const view = try owner.store.view(lease);
        const behavior = try owner.findBehavior(view);
        if (behavior.prepare != null) return error.DurableTurnRequired;
        var memory: h.Call.Memory = undefined;
        memory.init(turn.arena, owner.options.call_bytes);
        defer memory.deinit();
        const args = try values.copyArgs(memory.input.allocator(), message.args);
        var call: h.Call = .{ .memory = &memory, .attachment = owner, .view = view, .context = behavior.context };
        defer call.release();
        const reply = try behavior.invoke(&call, view, message.verb orelse return error.NoSuchMethod, args);
        if (call.replacement != null or call.transaction != null or call.result != null or call.confirmation != null or call.forward != null) return error.DurableTurnRequired;
        return values.copy(model.Argument, turn.arena, reply);
    }

    pub fn deinit(self: *Endpoint, _: std.mem.Allocator) void {
        if (self.entry.retention) |token| {
            self.entry.owner.store.releaseRetention(token) catch unreachable;
            self.entry.retention = null;
        }
        self.entry.owner.releaseEntry(self.entry);
        h.releaseClosed(self.entry.owner);
    }
};

/// Runtime-only conjunction of a managed invoking grant and an exact stored
/// target. The facet owns both retains. Calls re-enter the ordinary durable
/// queue with the guard entry and carry the target capability as authority.
/// No object identifier can manufacture this path.
pub const DependentEndpoint = struct {
    owner: *h.Attachment,
    guard: driver.Capability,
    target: driver.Capability,

    pub fn handle(self: *DependentEndpoint, turn: *driver.HostTurn, verb: ?[]const u8, args: driver.Args) !driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        if (self.owner.closing) return error.AttachmentClosed;
        if (turn.host != self.owner.host) return error.ForeignTurn;
        const entry = try self.owner.entryFor(self.guard);
        try admit(entry, turn.turn, turn.session, verb, arg_values, self.target, null, .protected);
        return .{ .void = {} };
    }

    pub fn deinit(self: *DependentEndpoint, _: std.mem.Allocator) void {
        self.owner.host.releaseCapabilityTerminal(self.target, null);
        self.owner.host.releaseCapabilityTerminal(self.guard, null);
        std.debug.assert(self.owner.dependent_facets != 0);
        self.owner.dependent_facets -= 1;
        h.releaseClosed(self.owner);
    }
};

/// Continuation fronts enter through their actual retained source. Original
/// source intent and outgoing target intent are independently copied and held.
pub fn admitContinuation(owner: *h.Attachment, source: driver.Capability, turn: *driver.HostTurn, intent: h.Call.Intent, target: driver.Capability, dispatch: h.Call.Intent, completion: Completion) !void {
    if (owner.closing) return error.AttachmentClosed;
    if (turn.host != owner.host) return error.ForeignTurn;
    try admit(try owner.entryFor(source), turn.turn, turn.session, intent.verb, intent.args, target, dispatch, completion);
}

pub fn admitLocalContinuation(owner: *h.Attachment, source: driver.Capability, turn: *actors.Turn, intent: h.Call.Intent, target: driver.Capability, dispatch: h.Call.Intent) !void {
    if (owner.closing) return error.AttachmentClosed;
    try admit(try owner.entryFor(source), turn, null, intent.verb, intent.args, target, dispatch, .protected);
}

fn admit(entry: *h.Entry, turn: *actors.Turn, session: ?*driver.HostSession, selector: ?[]const u8, args: []const driver.Value, dependent_target: ?driver.Capability, dispatch: ?h.Call.Intent, completion: Completion) !void {
    const verb = selector orelse return error.NoSuchMethod;
    const owner = entry.owner;
    if (turn.vat != &owner.host.vat) return error.ForeignTurn;
    if (owner.sequence == std.math.maxInt(i64)) return error.SequenceExhausted;
    if (owner.pending_bytes > owner.options.pending_bytes - owner.options.call_bytes) return error.CallCapacity;
    var ingress_calls: usize = 0;
    for (owner.operations) |operation| if (operation.phase != .free and operation.ingress == turn.ingress()) {
        ingress_calls += 1;
    };
    if (ingress_calls >= owner.host.vat.queue_limits.max_pending_turns or
        ingress_calls >= (owner.options.ingress_bytes orelse owner.host.vat.queue_limits.max_pending_bytes) / owner.options.call_bytes) return error.CallCapacity;
    const op = for (owner.operations) |*operation| {
        if (operation.phase == .free) break operation;
    } else return error.CallCapacity;
    op.* = .{ .entry = entry, .ingress = turn.ingress(), .peer = if (session) |s| s.peer_handle else null, .completion = completion };
    op.memory.init(owner.allocator, owner.options.call_bytes);
    errdefer {
        op.memory.deinit();
        op.* = .{};
    }
    if (dependent_target) |target| {
        const retained = try owner.host.retainValueCapabilities(op.memory.input.allocator(), &.{.{ .capability = target }});
        op.dependent_target = retained[0];
    }
    errdefer if (op.dependent_target) |target| owner.host.releaseCapabilityTerminal(target, null);
    const arena = op.memory.input.allocator();
    op.verb = try arena.dupe(u8, verb);
    const copied = try arena.alloc(driver.Value, args.len);
    for (copied, args) |*out, item| out.* = try values.copy(driver.Value, arena, item);
    op.args = copied;
    // The inbound turn releases its observations on return. The admitted
    // operation owns one retain per occurrence through every storage wait,
    // preparation restart, and commit outcome, including a closed session.
    op.argument_retains = try owner.host.retainValueCapabilities(arena, copied);
    errdefer owner.host.releaseCapabilityRetains(op.argument_retains);
    if (dispatch) |action| {
        const dispatch_verb = try arena.dupe(u8, action.verb);
        const dispatch_args = try arena.alloc(driver.Value, action.args.len);
        for (dispatch_args, action.args) |*out, item| out.* = try values.copy(driver.Value, arena, item);
        op.dispatch_retains = try owner.host.retainValueCapabilities(arena, dispatch_args);
        op.dispatch = .{ .verb = dispatch_verb, .args = dispatch_args };
    }
    errdefer owner.host.releaseCapabilityRetains(op.dispatch_retains);
    op.lifetime = if (turn.opaque_message != null) admitted: {
        var host_turn = try driver.HostTurn.fromActorTurn(turn);
        break :admitted try host_turn.retainPendingWork();
    } else try owner.host.admitPendingWork();
    errdefer op.lifetime.complete();
    const answered = switch (turn.origin) {
        .local => return error.DurableTurnRequired,
        .eventual => |eventual| eventual.answer != null,
        .served => |answer| answer != null,
    };
    if (answered) {
        if (session != null or turn.opaque_message != null) {
            op.resolver = .{ .host = try owner.host.deferTurn(session, turn) };
        } else {
            const pair_capacity = try owner.host.vat.reserveResolverPair();
            const forward = try turn.reserveForwardVow(.local);
            const pair = owner.host.vat.spawnReservedVow(pair_capacity);
            turn.forwardReservedVow(forward, pair.vow);
            op.resolver = .{ .local = pair.resolver };
        }
    }
    owner.host.vat.retainActor(entry.actor.?.local);
    completion.retain();
    owner.sequence += 1;
    op.sequence = owner.sequence;
    op.phase = .waiting;
    owner.pending_bytes += owner.options.call_bytes;
}
