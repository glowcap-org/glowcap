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
pub const Completion = union(enum) {
    protected,
    mediated: *Projection,
    receipt: *@import("execution.zig").Dispatch,

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
pub const Projection = struct {
    context: *anyopaque,
    retain: *const fn (*anyopaque) void,
    release: *const fn (*anyopaque) void,
    project: *const fn (*anyopaque, *h.Call, driver.Value) anyerror!driver.Value,
};

/// Retained input survives every working-set restart. Host/network and resolver
/// settlement allocations have their own owners outside this call backing.
pub fn inputAllocationBound(shape: values.Bounds, verb_bytes: usize, dependent: bool) !@import("call_memory.zig").AllocationBound {
    var bound = try values.allocationBound(driver.Value, shape);
    try bound.include(verb_bytes, 1, 1);
    try bound.include(try std.math.mul(usize, shape.capabilities, @sizeOf(driver.Host.StagedCapabilityRetain)), @alignOf(driver.Host.StagedCapabilityRetain), 1);
    if (dependent) try bound.include(@sizeOf(driver.Host.StagedCapabilityRetain), @alignOf(driver.Host.StagedCapabilityRetain), 1);
    return bound;
}

pub const Operation = struct {
    phase: enum { free, waiting, restarting, scheduled, materializing, forwarding, forwarded, disclosing, writing, settling, failed } = .free,
    entry: *h.Entry = undefined,
    sequence: u64 = 0,
    ingress: actors.IngressId = .local,
    peer: ?@FieldType(driver.HostSession, "peer_handle") = null,
    memory: @import("call_memory.zig").Memory = undefined,
    pending_read: bool = false,
    verb: []const u8 = "",
    args: []const driver.Value = &.{},
    argument_retains: []driver.Host.StagedCapabilityRetain = &.{},
    dispatch: ?h.Call.Intent = null,
    dispatch_retains: []driver.Host.StagedCapabilityRetain = &.{},
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

    pub fn handle(self: *Endpoint, turn: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        defer turn.releaseValues(args);
        if (self.entry.owner.closing) return error.AttachmentClosed;
        if (turn.host != self.entry.owner.host) return error.ForeignTurn;
        try admit(self.entry, turn.turn, turn.session, verb, args, null, null, .protected);
        return .{ .void = {} };
    }

    pub fn handleLocal(self: *Endpoint, turn: *actors.Turn, message: actors.Message) !model.Argument {
        const owner = self.entry.owner;
        if (owner.closing) return error.AttachmentClosed;
        if (turn.origin != .local) {
            const args = try turn.arena.alloc(driver.Value, message.args.len);
            for (args, message.args) |*out, item| out.* = try values.copy(driver.Value, turn.arena, item);
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
        const args = try memory.input.allocator().alloc(driver.Value, message.args.len);
        for (args, message.args) |*out, item| out.* = try values.copy(driver.Value, memory.input.allocator(), item);
        var call: h.Call = .{ .memory = &memory, .attachment = owner, .view = view, .context = behavior.context };
        defer call.release();
        const reply = try behavior.invoke(&call, view, message.verb, args);
        if (call.replacement != null or call.transaction != null or call.result != null or call.confirmation != null or call.forward != null) return error.DurableTurnRequired;
        return values.copy(model.Argument, turn.arena, reply);
    }

    pub fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.entry.retention) |token| {
            self.entry.owner.store.releaseRetention(token) catch unreachable;
            self.entry.retention = null;
        }
        self.entry.actor = null;
        h.releaseClosed(self.entry.owner);
    }
};

/// Runtime-only conjunction of a managed invoking grant and an exact stored
/// target. The facet owns both retains. Calls re-enter the ordinary durable
/// queue with the guard entry and carry the target capability as authority;
/// no object identifier can manufacture this path.
pub const DependentEndpoint = struct {
    owner: *h.Attachment,
    guard: driver.Capability,
    target: driver.Capability,

    pub fn handle(self: *DependentEndpoint, turn: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        defer turn.releaseValues(args);
        if (self.owner.closing) return error.AttachmentClosed;
        if (turn.host != self.owner.host) return error.ForeignTurn;
        const entry = try self.owner.entryFor(self.guard);
        try admit(entry, turn.turn, turn.session, verb, args, self.target, null, .protected);
        return .{ .void = {} };
    }

    pub fn deinit(self: *DependentEndpoint, _: std.mem.Allocator) void {
        self.owner.host.releaseCapabilityTerminal(self.target, null);
        self.owner.host.releaseCapability(self.guard, 1) catch unreachable;
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

fn admit(entry: *h.Entry, turn: *actors.Turn, session: ?*driver.HostSession, verb: []const u8, args: []const driver.Value, dependent_target: ?driver.Capability, dispatch: ?h.Call.Intent, completion: Completion) !void {
    const owner = entry.owner;
    if (turn.vat != &owner.host.vat) return error.ForeignTurn;
    if (owner.sequence == std.math.maxInt(i64)) return error.SequenceExhausted;
    if (owner.pending_bytes > owner.options.pending_bytes - owner.options.call_bytes) return error.CallCapacity;
    var ingress_calls: usize = 0;
    for (owner.operations) |operation| if (operation.phase != .free and operation.ingress == turn.ingress) {
        ingress_calls += 1;
    };
    if (ingress_calls >= owner.host.vat.queue_limits.max_pending_turns or
        ingress_calls >= (owner.options.ingress_bytes orelse owner.host.vat.queue_limits.max_pending_bytes) / owner.options.call_bytes) return error.CallCapacity;
    const op = for (owner.operations) |*operation| {
        if (operation.phase == .free) break operation;
    } else return error.CallCapacity;
    op.* = .{ .entry = entry, .ingress = turn.ingress, .peer = if (session) |s| s.peer_handle else null, .completion = completion };
    op.memory.init(owner.allocator, owner.options.call_bytes);
    errdefer {
        op.memory.deinit();
        op.* = .{};
    }
    if (dependent_target) |target| {
        const retained = try owner.host.retainValueCapabilities(op.memory.input.allocator(), &.{.{ .capability = target }});
        op.dependent_target = retained[0].ref;
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
    errdefer owner.host.releaseUntransferredCapabilityRetains(op.argument_retains);
    if (dispatch) |action| {
        const dispatch_verb = try arena.dupe(u8, action.verb);
        const dispatch_args = try arena.alloc(driver.Value, action.args.len);
        for (dispatch_args, action.args) |*out, item| out.* = try values.copy(driver.Value, arena, item);
        op.dispatch_retains = try owner.host.retainValueCapabilities(arena, dispatch_args);
        op.dispatch = .{ .verb = dispatch_verb, .args = dispatch_args };
    }
    errdefer owner.host.releaseUntransferredCapabilityRetains(op.dispatch_retains);
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

/// Storage completions only change eligibility. Ready invocations run as
/// ordinary Vat turns; settlement runs here at a top-level owner boundary.
pub fn advance(owner: *h.Attachment) !void {
    _ = try advanceProgress(owner);
}

/// Reports work that needs another owning Host turn, including effects emitted
/// during preparation. Parked foreign replies and storage workers stay idle.
pub fn advanceProgress(owner: *h.Attachment) !bool {
    try owner.topLevel();
    // Released endpoint rows still borrow their fixed entries until the next
    // ordinary Vat boundary. Host progress owns that retirement even with no
    // queued invocation; otherwise idle release leaves capacity occupied.
    var progressed = owner.host.vat.hasRetiredState();
    if (progressed) {
        owner.advancing = true;
        defer owner.advancing = false;
        _ = try owner.host.vat.near(owner.runner, .{ .verb = "barrier", .args = &.{} });
    }
    progressed = (if (owner.discovery) |discovery| try discovery.advanceProgress() else false) or progressed;
    if (owner.options.live_scope) |scope| progressed = (try scope.advanceProgress()) or progressed;
    progressed = (try advanceOperations(owner)) or progressed;
    // Settlement releases leases before deferred publication tries to acquire
    // them. Host publication runs outside the retained-operation callback guard.
    progressed = (try @import("publication.zig").advanceRepublish(owner)) or progressed;
    // Preparation can emit a fetch or dial while its operation stays waiting.
    // The embedder must drain that Host work before parking for its reply.
    return progressed or owner.host.hasRunnableWork();
}

fn advanceOperations(owner: *h.Attachment) !bool {
    var progressed = false;
    owner.advancing = true;
    defer owner.advancing = false;
    for (owner.operations, 0..) |*op, index| {
        const prior_phase = op.phase;
        defer progressed = progressed or op.phase != prior_phase;
        if (op.pending_read) continue;
        // Retire uninvoked preparations; committed writes and effects keep custody.
        if ((op.phase == .waiting or op.phase == .restarting) and !owner.host.vat.hasIngress(op.ingress)) {
            op.failure = error.UnknownIngress;
            op.phase = .failed;
            continue;
        }
        if (op.phase == .restarting) {
            reset(owner, op);
            op.phase = .waiting;
            continue;
        }
        if (op.phase == .forwarding) {
            if (owner.store.phase != .idle or op.snapshot_revision != owner.store.metadata.revision) {
                reset(owner, op);
                op.phase = .waiting;
                continue;
            }
            const action = op.call.?.forward.?;
            // Source callbacks establish admission; private execution retains
            // the selected request rather than accepting rewritten arguments.
            const request = if (op.completion != .protected) op.dispatch.? else h.Call.Intent{ .verb = action.verb, .args = action.args };
            const arena = op.memory.input.allocator();
            op.forwarded.begin(&op.lifetime, action.target, request.verb, request.args, arena, owner.options.forward_reply_bytes) catch |err| {
                op.failure = err;
                op.phase = .failed;
                continue;
            };
            if (op.completion == .receipt) op.completion.receipt.admitted = true;
            retirePreparation(owner, op);
            op.phase = .forwarded;
        }
        if (op.phase == .forwarded) switch (op.forwarded.poll()) {
            .pending => continue,
            .failed => |failed| {
                op.failure = error.ForwardedCallFailed;
                op.failure_reason = failed.message;
                op.failure_kind = failed.kind;
                op.forwarded_failure = true;
                op.phase = .failed;
            },
            .ready => |reply| {
                op.reply = reply;
                op.phase = .settling;
            },
        };
        if (op.completion != .receipt and op.forwarded.call != null and (op.phase == .settling or (op.phase == .failed and op.forwarded_failure))) {
            // A resolver retry repeats admission against a fresh preparation.
            // Always start projection from the immutable upstream result.
            // Application lifetime can change without a storage revision.
            retirePreparation(owner, op);
            if (!op.forwarded_failure) op.reply = op.forwarded.poll().ready;
            op.disclosure = .pending;
            op.phase = .disclosing;
        }
        if (op.phase == .disclosing) {
            if (owner.store.phase != .idle) continue;
            const ready = prepareCurrent(owner, op, index) catch |err| {
                op.failure = err;
                op.failure_reason = null;
                op.forwarded_failure = false;
                op.failure_kind = .broken;
                op.disclosure = .none;
                op.phase = .failed;
                continue;
            };
            if (!ready) continue;
            op.disclosure = .checked;
            op.phase = if (op.forwarded_failure) .failed else .settling;
        }
        if (op.phase == .settling and op.completion != .receipt and op.forwarded.call != null) retainPublicResult(op) catch |err| {
            op.failure = err;
            op.failure_reason = null;
            op.phase = .failed;
        };
        if (op.phase == .materializing and op.call.?.replacement == null and op.call.?.transaction == null and
            (owner.store.phase != .idle or op.snapshot_revision != owner.store.metadata.revision))
        {
            reset(owner, op);
            op.phase = .waiting;
            continue;
        }
        if (op.phase == .materializing) finishInvocation(owner, index) catch |err| {
            if (owner.store.phase == .staging or owner.store.phase == .prepared) {
                owner.store.abort() catch unreachable;
                @import("publication.zig").releaseRetirements(owner, false);
            }
            op.failure = err;
            op.phase = .failed;
        };
        if (op.phase == .settling or op.phase == .failed) try settle(owner, op);
        if (op.phase != .waiting or owner.store.phase != .idle) continue;
        var earlier = false;
        for (owner.operations) |other| {
            // Forwarded calls hold immutable intent/result custody, not the
            // source's preparation or storage lease. Waiting on their target
            // cannot exclude that target's own invocation of this entry.
            if (other.phase != .free and other.phase != .forwarded and other.entry == op.entry and other.sequence < op.sequence) {
                earlier = true;
                break;
            }
        }
        if (earlier) continue;
        const ready = prepareCurrent(owner, op, index) catch |err| {
            op.failure = err;
            op.phase = .failed;
            continue;
        };
        if (!ready) continue;
        _ = owner.host.vat.sendObservedFromIngress(op.ingress, owner.runner, .{
            .verb = "invoke",
            .args = &.{ .{ .integer = @intCast(index) }, .{ .integer = @intCast(op.sequence) } },
        }, .{ .ctx = op, .func = dispatched }) catch |err| {
            reset(owner, op);
            if (err == error.UnknownIngress) {
                // Session cancellation removes admission while this call may
                // still own storage preparation. Retire its exact operation;
                // a disconnected caller cannot condemn unrelated Host work.
                op.failure = err;
                op.phase = .failed;
                continue;
            }
            return err;
        };
        op.phase = .scheduled;
        // Wake through the owning Host lane: its session quantum and
        // close verdict still govern deferred application work.
        if (op.peer) |peer| {
            if (owner.host.sessionForPeer(peer)) |session| try owner.host.flushSession(session);
        }
    }
    return progressed;
}

fn prepare(owner: *h.Attachment, op: *Operation) !void {
    if (op.call != null) return;
    const view = try owner.store.view(op.lease.?);
    const behavior = try owner.findBehavior(view);
    op.call = .{ .memory = &op.memory, .attachment = owner, .view = view, .context = behavior.context, .dependent_target = op.dependent_target, .dispatch = op.dispatch, .work = &op.lifetime };
    if (behavior.prepare) |factory| op.call.?.preparation = try factory(&op.call.?, op.verb, op.args);
}

/// No outstanding read may borrow working storage. Terminal results occupy
/// input custody when they must survive a fresh admission preparation.
fn retirePreparation(owner: *h.Attachment, op: *Operation) void {
    std.debug.assert(!op.pending_read);
    if (op.call) |*call| {
        call.release();
        if (call.preparation) |working| working.deinit();
    }
    op.call = null;
    if (op.lease) |lease| owner.store.release(lease) catch unreachable;
    op.lease = null;
    op.memory.resetWorking();
}

pub fn reset(owner: *h.Attachment, op: *Operation) void {
    op.forwarded.deinit();
    op.failure_reason = null;
    retirePreparation(owner, op);
}

/// A stale preparation must preserve a completed target and its exact outcome.
pub fn reprepare(owner: *h.Attachment, op: *Operation) void {
    if (op.disclosure != .none) retirePreparation(owner, op) else reset(owner, op);
}

fn prepareCurrent(owner: *h.Attachment, op: *Operation, index: usize) !bool {
    try op.lifetime.checkHost(owner.host);
    if (op.lease != null and op.snapshot_revision != owner.store.metadata.revision) retirePreparation(owner, op);
    if (op.lease == null) {
        const acquired = owner.store.acquire(op.entry.id) catch |err| switch (err) {
            error.PendingRead, error.ResidentCapacity, error.LeaseCapacity => return false,
            else => return err,
        };
        switch (acquired) {
            .read => |read| {
                storage.retainRead(owner, read, null);
                return false;
            },
            .ready => |lease| {
                op.lease = lease;
                op.snapshot_revision = owner.store.metadata.revision;
            },
        }
    }
    try prepare(owner, op);
    if (op.call.?.preparation) |working| switch (try working.advance()) {
        .waiting => return false,
        .read => |read| {
            op.pending_read = true;
            storage.retainRead(owner, read, index);
            return false;
        },
        .ready => {},
    };
    return true;
}

fn dispatched(ctx: ?*anyopaque, result: actors.Resolution) void {
    const op: *Operation = @ptrCast(@alignCast(ctx.?));
    if (op.phase != .scheduled) return;
    // The runner normally changes phase before resolving. A still-scheduled
    // operation was canceled or refused before invoking its behavior.
    _ = result;
    op.failure = error.ActivationCanceled;
    op.phase = .failed;
}

pub const Runner = struct {
    owner: *h.Attachment,
    pub fn handle(self: *Runner, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "barrier")) return .{ .void = {} };
        if (!std.mem.eql(u8, msg.verb, "invoke") or msg.args.len != 2) return error.InvalidDelivery;
        const index = std.math.cast(usize, msg.args[0].integer) orelse return error.InvalidDelivery;
        if (index >= self.owner.operations.len) return error.InvalidDelivery;
        const op = &self.owner.operations[index];
        if (op.phase != .scheduled or op.sequence != msg.args[1].integer) return error.StaleCompletion;
        if (self.owner.store.phase != .idle or op.snapshot_revision != self.owner.store.metadata.revision) {
            // Retire preparation at the next top-level advance boundary.
            op.phase = .restarting;
            return .{ .void = {} };
        }
        invoke(self.owner, index) catch |err| {
            op.failure = err;
            op.phase = .failed;
        };
        return .{ .void = {} };
    }
};

fn invoke(owner: *h.Attachment, index: usize) !void {
    const op = &owner.operations[index];
    try op.lifetime.checkHost(owner.host);
    // Preparation may borrow portrait bytes until its deinit at settlement.
    // Keep the lease through commit and resolver retries, even after invocation.
    const view = try owner.store.view(op.lease.?);
    // A queued lease is a snapshot. Another actor may have committed between
    // scheduling and execution; reacquire instead of invoking on stale state.
    if (op.lease.?.incarnation != owner.store.metadata.incarnation) return error.StaleCompletion;
    const behavior = try owner.findBehavior(view);
    const arena = op.memory.working.allocator();
    owner.stats.invocations += 1;
    op.reply = try behavior.invoke(&op.call.?, view, op.verb, op.args);
    if (op.completion != .protected) {
        const action = op.call.?.forward orelse return error.InvalidContinuationDispatch;
        if (!action.target.eql(op.dependent_target.?) or !std.mem.eql(u8, action.verb, op.dispatch.?.verb)) return error.InvalidContinuationDispatch;
    }
    if (op.call.?.confirmation) |confirmation| {
        if (confirmation.requires_commit and op.call.?.replacement == null and op.call.?.transaction == null) return error.ReceiptRequired;
    }
    if (op.call.?.forward != null) {
        if (op.call.?.replacement != null or op.call.?.transaction != null or op.call.?.result != null or op.call.?.confirmation != null) return error.InvalidForwarding;
        op.phase = .forwarding;
        return;
    }
    if (op.call.?.replacement != null or op.call.?.transaction != null) {
        // Local-only resolver results cannot transport owning capability values.
        try owner.store.begin();
        errdefer {
            if (owner.store.phase == .staging or owner.store.phase == .prepared) owner.store.abort() catch unreachable;
            @import("publication.zig").releaseRetirements(owner, false);
        }
        if (op.call.?.replacement) |payload| {
            const edges = try arena.alloc(core.Edge, view.edge_count);
            var iterator = view.edges();
            for (edges) |*edge| edge.* = iterator.next().?;
            try owner.store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .schema_version = view.schema_version, .rooted = view.rooted, .payload = payload, .edges = edges }, view.revision);
        }
        if (op.call.?.transaction) |participant| try participant.stage(participant.context, owner.store);
        if (op.call.?.result != null) {
            op.phase = .materializing;
            return;
        }
        try finishInvocation(owner, index);
        return;
    }
    if (op.call.?.result != null) op.phase = .materializing else try finishInvocation(owner, index);
}

fn finishInvocation(owner: *h.Attachment, index: usize) !void {
    const op = &owner.operations[index];
    if (op.call.?.result) |result| op.reply = try result(&op.call.?);
    try retainResult(op, op.reply);
    if (op.call.?.replacement != null or op.call.?.transaction != null) {
        if (owner.options.live_scope) |scope| try scope.validateStaged();
        try owner.store.retainOnCommit();
        const ticket = try owner.store.prepare();
        const batch = try owner.store.beginWrite(ticket);
        owner.writing = .{ .batch = batch, .operation = index };
        op.phase = .writing;
    } else op.phase = .settling;
}

fn retainResult(op: *Operation, reply: driver.Value) !void {
    const local = op.resolver == .local;
    const has_capability = try op.call.?.prepareReply(reply, if (local) .validate_only else .retain);
    if (local and has_capability) return error.OwningReplyRequired;
    // Invocation/result callbacks return call-lifetime data. A foreign Host
    // result keeps its Call owner until reset; local forwarded replies already
    // copy at their callback boundary. Capability custody is prepared above.
    op.reply = reply;
}

fn retainPublicResult(op: *Operation) !void {
    // Projection is after current source admission, before outward retention.
    // It cannot lend the raw capability that arrived from the target.
    const reply = if (op.completion == .mediated)
        try op.completion.mediated.project(op.completion.mediated.context, &op.call.?, op.reply)
    else
        op.reply;
    try retainResult(op, reply);
}

fn settle(owner: *h.Attachment, op: *Operation) !void {
    const failed = op.phase == .failed;
    if (!failed and !op.confirmed) {
        if (op.call) |*call| if (call.confirmation) |confirmation| {
            call.confirmation = null;
            confirmation.apply(confirmation.context);
        };
        op.confirmed = true;
    }
    switch (op.resolver) {
        .none => {},
        .local => |resolver| {
            if (failed) try owner.host.vat.breakVow(resolver, op.failure_reason orelse @errorName(op.failure)) else {
                // Conversion may be retried after allocation refusal. This is
                // preparation only; it does not rerun the actor or its write.
                var arena = std.heap.ArenaAllocator.init(owner.allocator);
                defer arena.deinit();
                try owner.host.vat.fulfillVow(resolver, try values.copy(model.Argument, arena.allocator(), op.reply));
            }
        },
        .host => |resolver| host_reply: {
            var arena = std.heap.ArenaAllocator.init(owner.allocator);
            defer arena.deinit();
            if (!failed) owner.host.resolverFulfillValue(resolver, op.reply, arena.allocator()) catch |err| {
                if (err == error.AlreadySettled) break :host_reply;
                if (!driver.Host.Call.replyRefusalIsPermanent(err)) return err;
                // This reply is immutable. Retrying cannot enlarge its buffer
                // or restore a retired capability home. Keep its owner until
                // rejection succeeds; temporary heap refusal retries rejection.
                op.failure = err;
                op.failure_reason = null;
                op.failure_kind = .broken;
                op.phase = .failed;
            };
            if (op.phase == .failed) owner.host.resolverReject(resolver, op.failure_kind, op.failure_reason orelse @errorName(op.failure)) catch |err| switch (err) {
                error.AlreadySettled => {},
                else => return err,
            };
        },
    }
    reset(owner, op);
    if (owner.options.sleep_policy == .every_turn) {
        if (owner.store.evictObject(op.entry.id) catch false) owner.stats.sleeps += 1;
    }
    owner.host.vat.releaseActor(op.entry.actor.?.local);
    if (op.dependent_target) |target| owner.host.releaseCapabilityTerminal(target, null);
    for (op.argument_retains) |retained| owner.host.releaseCapabilityTerminal(retained.ref, null);
    for (op.dispatch_retains) |retained| owner.host.releaseCapabilityTerminal(retained.ref, null);
    op.lifetime.complete();
    owner.pending_bytes -= owner.options.call_bytes;
    op.memory.deinit();
    op.completion.release();
    op.* = .{};
}
