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

pub const Operation = struct {
    phase: enum { free, waiting, scheduled, materializing, writing, settling, failed } = .free,
    entry: *h.Entry = undefined,
    sequence: u64 = 0,
    ingress: actors.IngressId = .local,
    peer: ?@FieldType(driver.HostSession, "peer_handle") = null,
    memory: []u8 = undefined,
    fixed: std.heap.FixedBufferAllocator = undefined,
    input_end: usize = 0,
    pending_read: bool = false,
    verb: []const u8 = "",
    args: []const driver.Value = &.{},
    resolver: union(enum) { local: u64, host: u64, none } = .none,
    lifetime: driver.Host.PendingWorkLease = .{ .host = null },
    lease: ?core.Lease = null,
    snapshot_revision: u64 = 0,
    call: ?h.Call = null,
    reply: driver.Value = .{ .void = {} },
    failure: anyerror = error.CallFailed,
    confirmed: bool = false,
    dependent_target: ?driver.Capability = null,
};

pub const Endpoint = struct {
    entry: *h.Entry,

    pub fn handle(self: *Endpoint, turn: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        defer turn.releaseValues(args);
        if (self.entry.owner.closing) return error.AttachmentClosed;
        if (turn.host != self.entry.owner.host) return error.ForeignTurn;
        try admit(self.entry, turn.turn, turn.session, verb, args, null);
        return .{ .void = {} };
    }

    pub fn handleLocal(self: *Endpoint, turn: *actors.Turn, message: actors.Message) !model.Argument {
        const owner = self.entry.owner;
        if (owner.closing) return error.AttachmentClosed;
        const args = try turn.arena.alloc(driver.Value, message.args.len);
        for (args, message.args) |*out, item| out.* = try values.copy(driver.Value, turn.arena, item);
        if (turn.origin != .local) {
            try admit(self.entry, turn, null, message.verb, args, null);
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
        var call: h.Call = .{ .arena = turn.arena, .attachment = owner, .view = view, .context = behavior.context };
        defer call.release();
        const reply = try behavior.invoke(&call, view, message.verb, args);
        if (call.replacement != null or call.transaction != null or call.result != null or call.confirmation != null) return error.DurableTurnRequired;
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
        _ = try self.owner.entryFor(self.target);
        try admit(entry, turn.turn, turn.session, verb, args, self.target);
        return .{ .void = {} };
    }

    pub fn deinit(self: *DependentEndpoint, _: std.mem.Allocator) void {
        self.owner.host.releaseCapability(self.target, 1) catch unreachable;
        self.owner.host.releaseCapability(self.guard, 1) catch unreachable;
        std.debug.assert(self.owner.dependent_facets != 0);
        self.owner.dependent_facets -= 1;
        h.releaseClosed(self.owner);
    }
};

fn admit(entry: *h.Entry, turn: *actors.Turn, session: ?*driver.HostSession, verb: []const u8, args: []const driver.Value, dependent_target: ?driver.Capability) !void {
    const owner = entry.owner;
    if (turn.vat != &owner.host.vat) return error.ForeignTurn;
    for (args) |arg| if (!values.plain(arg)) return error.NotDurable;
    if (owner.sequence == std.math.maxInt(i64)) return error.SequenceExhausted;
    if (owner.pending_bytes > owner.options.pending_bytes - owner.options.call_bytes) return error.CallCapacity;
    var ingress_calls: usize = 0;
    for (owner.operations) |operation| if (operation.phase != .free and operation.ingress == turn.ingress) {
        ingress_calls += 1;
    };
    if (ingress_calls >= owner.host.vat.queue_limits.max_pending_turns or
        ingress_calls >= owner.host.vat.queue_limits.max_pending_bytes / owner.options.call_bytes) return error.CallCapacity;
    const op = for (owner.operations) |*operation| {
        if (operation.phase == .free) break operation;
    } else return error.CallCapacity;
    const memory = try owner.allocator.alloc(u8, owner.options.call_bytes);
    errdefer owner.allocator.free(memory);
    op.* = .{ .entry = entry, .memory = memory, .fixed = .init(memory), .ingress = turn.ingress, .peer = if (session) |s| s.peer_handle else null };
    errdefer op.* = .{};
    if (dependent_target) |target| {
        const actor = owner.host.localActorFor(target) orelse return error.NotDurable;
        op.dependent_target = try owner.host.retainLocalCapability(actor);
    }
    errdefer if (op.dependent_target) |target| owner.host.releaseCapability(target, 1) catch unreachable;
    const arena = op.fixed.allocator();
    op.verb = try arena.dupe(u8, verb);
    const copied = try arena.alloc(driver.Value, args.len);
    for (copied, args) |*out, item| out.* = try values.copy(driver.Value, arena, item);
    op.args = copied;
    op.input_end = op.fixed.end_index;
    op.lifetime = try owner.host.admitPendingWork();
    errdefer op.lifetime.complete();
    const answered = switch (turn.origin) {
        .local => return error.DurableTurnRequired,
        .eventual => |eventual| eventual.answer != null,
        .served => |answer| answer != null,
    };
    if (answered) {
        if (session) |s| {
            op.resolver = .{ .host = try owner.host.deferTurn(s, turn) };
        } else {
            const pair_capacity = try owner.host.vat.reserveResolverPair();
            const forward = try turn.reserveForwardVow(.local);
            const pair = owner.host.vat.spawnReservedVow(pair_capacity);
            turn.forwardReservedVow(forward, pair.vow);
            op.resolver = .{ .local = pair.resolver };
        }
    }
    owner.host.vat.retainActor(entry.actor.?.local);
    owner.sequence += 1;
    op.sequence = owner.sequence;
    op.phase = .waiting;
    owner.pending_bytes += memory.len;
}

/// Storage completions only change eligibility. Ready invocations run as
/// ordinary Vat turns; settlement runs here at a top-level owner boundary.
pub fn advance(owner: *h.Attachment) !void {
    try owner.topLevel();
    owner.advancing = true;
    defer owner.advancing = false;
    for (owner.operations, 0..) |*op, index| {
        if (op.pending_read) continue;
        if (op.phase == .materializing and op.call.?.replacement == null and op.call.?.transaction == null and
            (owner.store.phase != .idle or op.snapshot_revision != owner.store.metadata.revision))
        {
            reset(owner, op);
            op.phase = .waiting;
            continue;
        }
        if (op.phase == .materializing) finishInvocation(owner, index) catch |err| {
            if (owner.store.phase == .staging or owner.store.phase == .prepared) owner.store.abort() catch unreachable;
            op.failure = err;
            op.phase = .failed;
        };
        if (op.phase == .settling or op.phase == .failed) try settle(owner, op);
        if (op.phase != .waiting or owner.store.phase != .idle) continue;
        var earlier = false;
        for (owner.operations) |other| {
            if (other.phase != .free and other.entry == op.entry and other.sequence < op.sequence) {
                earlier = true;
                break;
            }
        }
        if (earlier) continue;
        if (op.lease != null and op.snapshot_revision != owner.store.metadata.revision) reset(owner, op);
        if (op.lease == null) {
            const acquired = owner.store.acquire(op.entry.id) catch |err| switch (err) {
                error.PendingRead, error.ResidentCapacity, error.LeaseCapacity => continue,
                else => {
                    op.failure = err;
                    op.phase = .failed;
                    continue;
                },
            };
            switch (acquired) {
                .read => |read| {
                    storage.retainRead(owner, read, null);
                    continue;
                },
                .ready => |lease| {
                    op.lease = lease;
                    op.snapshot_revision = owner.store.metadata.revision;
                },
            }
        }
        prepare(owner, op) catch |err| {
            op.failure = err;
            op.phase = .failed;
            continue;
        };
        if (op.call.?.preparation) |working| {
            const step = working.advance() catch |err| {
                op.failure = err;
                op.phase = .failed;
                continue;
            };
            switch (step) {
                .waiting => continue,
                .read => |read| {
                    op.pending_read = true;
                    storage.retainRead(owner, read, index);
                    continue;
                },
                .ready => {},
            }
        }
        _ = owner.host.vat.sendObservedFromIngress(op.ingress, owner.runner, .{
            .verb = "invoke",
            .args = &.{ .{ .integer = @intCast(index) }, .{ .integer = @intCast(op.sequence) } },
        }, .{ .ctx = op, .func = dispatched }) catch |err| {
            reset(owner, op);
            if (err == error.UnknownIngress) {
                op.failure = err;
                op.phase = .failed;
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
}

fn prepare(owner: *h.Attachment, op: *Operation) !void {
    if (op.call != null) return;
    const view = try owner.store.view(op.lease.?);
    const behavior = try owner.findBehavior(view);
    op.call = .{ .arena = op.fixed.allocator(), .attachment = owner, .view = view, .context = behavior.context, .dependent_target = op.dependent_target };
    if (behavior.prepare) |factory| op.call.?.preparation = try factory(&op.call.?, op.verb, op.args);
}

/// No outstanding read may borrow working-set or arena storage at this point.
pub fn reset(owner: *h.Attachment, op: *Operation) void {
    std.debug.assert(!op.pending_read);
    if (op.call) |*call| {
        call.release();
        if (call.preparation) |working| working.deinit();
    }
    op.call = null;
    if (op.lease) |lease| owner.store.release(lease) catch unreachable;
    op.lease = null;
    op.fixed.end_index = op.input_end;
}

fn dispatched(ctx: ?*anyopaque, result: actors.Resolution) void {
    const op: *Operation = @ptrCast(@alignCast(ctx.?));
    if (op.phase != .scheduled) return;
    // The runner normally changes phase before resolving. A still-scheduled
    // operation was canceled or refused before invoking its behavior.
    _ = result;
    reset(op.entry.owner, op);
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
            reset(self.owner, op);
            op.phase = .waiting;
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
    // Preparation may borrow portrait bytes until its deinit at settlement.
    // Keep the lease through commit and resolver retries, even after invocation.
    const view = try owner.store.view(op.lease.?);
    // A queued lease is a snapshot. Another actor may have committed between
    // scheduling and execution; reacquire instead of invoking on stale state.
    if (op.lease.?.incarnation != owner.store.metadata.incarnation) return error.StaleCompletion;
    const behavior = try owner.findBehavior(view);
    const arena = op.fixed.allocator();
    owner.stats.invocations += 1;
    op.reply = try behavior.invoke(&op.call.?, view, op.verb, op.args);
    if (op.call.?.replacement != null or op.call.?.transaction != null) {
        // Local-only resolver results cannot transport owning capability values.
        try owner.store.begin();
        errdefer if (owner.store.phase == .staging or owner.store.phase == .prepared) owner.store.abort() catch unreachable;
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
    op.reply = try values.copy(driver.Value, op.fixed.allocator(), reply);
}

fn settle(owner: *h.Attachment, op: *Operation) !void {
    const failed = op.phase == .failed;
    if (!failed and !op.confirmed) {
        if (op.call.?.confirmation) |confirmation| confirmation.apply(confirmation.context);
        op.confirmed = true;
    }
    switch (op.resolver) {
        .none => {},
        .local => |resolver| {
            if (failed) try owner.host.vat.breakVow(resolver, @errorName(op.failure)) else {
                // Conversion may be retried after allocation refusal. This is
                // preparation only; it does not rerun the actor or its write.
                var arena = std.heap.ArenaAllocator.init(owner.allocator);
                defer arena.deinit();
                try owner.host.vat.fulfillVow(resolver, try values.copy(model.Argument, arena.allocator(), op.reply));
            }
        },
        .host => |resolver| {
            var arena = std.heap.ArenaAllocator.init(owner.allocator);
            defer arena.deinit();
            const result = if (failed)
                owner.host.resolverBreak(resolver, @errorName(op.failure))
            else
                owner.host.resolverFulfillValue(resolver, op.reply, arena.allocator());
            result catch |err| switch (err) {
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
    if (op.dependent_target) |target| owner.host.releaseCapability(target, 1) catch unreachable;
    op.lifetime.complete();
    owner.pending_bytes -= op.memory.len;
    owner.allocator.free(op.memory);
    op.* = .{};
}
