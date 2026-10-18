//! Owning local delivery on the existing Vat queue. The Host vow row and
//! turn participant keep the producer alive independently of its observer.
const std = @import("std");
const actors = @import("actors");
const host_mod = @import("../host.zig");
const value_mod = @import("../value.zig");
const value_copy = @import("../value_copy.zig");
const capability = @import("../capability.zig");
const lower = @import("capabilities/lower.zig");
const vows = @import("../vows.zig");
const settlement = @import("../vows/settlement.zig");
const owned = @import("owned_call.zig");
const FailureText = @import("failure_text.zig");

pub const Producer = struct {
    host: *host_mod.Host,
    destination: union(enum) {
        owning: ?*owned.Call,
        public: *@import("local_completion.zig").Reply,
        discard,
    } = .{ .owning = null },
    refs: usize = 1,
    phase: enum { queued, running, committed } = .queued,
    outcome: union(enum) { pending, fulfilled, broken: FailureText } = .pending,
    failure_kind: @import("action.zig").VowFailure = .broken,
    lease: ?@import("admission.zig").PendingWorkLease = null,

    pub fn retain(self: *Producer) void {
        std.debug.assert(self.refs != std.math.maxInt(usize));
        self.refs += 1;
    }

    pub fn release(self: *Producer) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        switch (self.destination) {
            .owning => |observer| if (observer) |call| owned.finishLocal(call, .{ .broken = "HostReleased" }, .closed),
            .public => |reply| reply.deinit(),
            .discard => {},
        }
        if (self.lease) |*lease| lease.complete();
        switch (self.destination) {
            .public => |reply| self.host.allocator.destroy(reply),
            else => self.host.allocator.destroy(self),
        }
    }

    pub fn prepare(self: *Producer, value: value_mod.Value) !void {
        std.debug.assert(self.outcome == .pending);
        switch (self.destination) {
            .owning => |observer| if (observer) |call| try owned.prepareLocal(call, value),
            .public => |reply| try reply.prepare(value),
            .discard => {},
        }
    }

    pub fn prepareWire(self: *Producer, session: *host_mod.HostSession, value: @import("model").Argument) !void {
        switch (self.destination) {
            .owning => |observer| {
                if (observer) |call| return owned.prepareWire(call, session, value);
            },
            .public => |reply| return reply.prepareWire(session, value),
            .discard => {},
        }
        @import("capabilities/lift.zig").discardValueObservation(self.host, session, value);
    }

    pub fn cancelPreparation(self: *Producer) void {
        switch (self.destination) {
            .owning => |observer| if (observer) |call| owned.cancelLocalPreparation(call),
            .public => |reply| reply.cancelPreparation(),
            .discard => {},
        }
    }

    pub fn settle(self: *Producer, resolution: actors.Resolution) void {
        if (self.phase == .queued) self.phase = .committed;
        if (self.outcome == .pending) self.outcome = switch (resolution) {
            .fulfilled => .fulfilled,
            .broken => |reason| .{ .broken = FailureText.init(reason) },
            .give => .{ .broken = FailureText.init("UnsupportedValue") },
        };
        self.publish();
    }

    fn publish(self: *Producer) void {
        if (self.phase != .committed or self.outcome == .pending) return;
        const resolution: actors.Resolution = switch (self.outcome) {
            .fulfilled => .{ .fulfilled = .{ .void = {} } },
            .broken => |*reason| .{ .broken = reason.message() },
            .pending => unreachable,
        };
        switch (self.destination) {
            .owning => |observer| if (observer) |call| {
                self.destination.owning = null;
                owned.finishLocal(call, resolution, self.failure_kind);
            },
            .public => |reply| reply.publish(resolution, self.failure_kind),
            .discard => {},
        }
    }

    fn commit(ctx: *anyopaque, _: *actors.Vat) void {
        const self: *Producer = @ptrCast(@alignCast(ctx));
        self.phase = .committed;
        self.publish();
        self.release();
    }

    fn abort(ctx: *anyopaque, _: *actors.Vat, reason: []const u8) void {
        const self: *Producer = @ptrCast(@alignCast(ctx));
        self.phase = .committed;
        self.outcome = .{ .broken = FailureText.init(reason) };
        self.failure_kind = .broken;
    }

    fn notifyAbort(ctx: *anyopaque, _: *actors.Vat, _: []const u8) void {
        const self: *Producer = @ptrCast(@alignCast(ctx));
        self.publish();
        self.release();
    }

    pub fn enroll(self: *Producer, turn: *actors.Turn) !void {
        // A forwarding chain shares one reply destination. Nested execution
        // already belongs to its outer turn participant; a later queued hop
        // enrolls that destination under its own outer commit boundary.
        if (self.phase == .running) return;
        std.debug.assert(self.outcome == .pending);
        try turn.vat.enrollTurn(.{ .ctx = self, .commit = commit, .abort = abort, .abort_notify = notifyAbort });
        self.retain();
        self.phase = .running;
    }
};

const Input = struct {
    producer: *Producer,
    target: capability.Ref,
    verb: []const u8,
    args: []const value_mod.Value,
    retained: []capability.Ref = &.{},
    owned_bytes: usize,

    const protocol = "glowcap.host.v01".*;
    const vtable: actors.OpaqueMessage.VTable = .{ .protocol = protocol, .copy = copy, .retire = retire };

    fn message(self: *Input) actors.OpaqueMessage {
        return .{ .ctx = self, .vtable = &vtable, .owned_bytes = self.owned_bytes };
    }

    /// One queue-arena materialization, plus one keeper retain per capability
    /// occurrence and target. These outlive observer cancellation and retire
    /// with the actual queued input, not its completion buffer.
    fn copy(ctx: *anyopaque, arena: std.mem.Allocator) actors.OpaqueMessage.CopyResult {
        return .{ .copied = copyOwned(ctx, arena) catch |err| return .{ .refused = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.ResourceExhausted => .resource_exhausted,
            else => .malformed_view,
        } } };
    }

    fn copyOwned(ctx: *anyopaque, arena: std.mem.Allocator) actors.Error!actors.OpaqueMessage {
        const self: *Input = @ptrCast(@alignCast(ctx));
        const result = try arena.create(Input);
        const verb = try arena.dupe(u8, self.verb);
        const args = try arena.alloc(value_mod.Value, self.args.len);
        for (args, self.args) |*out, value| out.* = value_copy.copy(value_mod.Value, arena, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedView,
        };
        const host = self.producer.host;
        const retained = host.retainValueCapabilities(arena, args) catch |err| return retainError(err);
        errdefer lower.releaseCapabilityRetains(host, retained);
        const target = host.capabilities.resolve(self.target) orelse return error.MalformedView;
        const target_ref = host.capabilities.retain(host.allocator, target) catch |err| return retainError(err);
        self.producer.retain();
        result.* = .{ .producer = self.producer, .target = target_ref, .verb = verb, .args = args, .retained = retained, .owned_bytes = self.owned_bytes };
        return result.message();
    }

    fn retainError(err: anyerror) actors.Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.RetainOverflow, error.CapabilitySpaceExhausted => error.ResourceExhausted,
            else => error.MalformedView,
        };
    }

    fn retire(ctx: *anyopaque, _: ?[]const u8) void {
        const self: *Input = @ptrCast(@alignCast(ctx));
        const host = self.producer.host;
        for (self.retained) |item| host.releaseCapabilityTerminal(item, null);
        host.releaseCapabilityTerminal(self.target, null);
        self.producer.release();
    }
};

/// Recover only this adapter's payload, in its own Host's Vat. It cannot be
/// smuggled through a model argument or a different local adapter.
pub fn producer(turn: *actors.Turn) !*Producer {
    const body = turn.opaque_message orelse return error.ForeignTurn;
    if (!std.mem.eql(u8, &body.vtable.protocol, &Input.protocol)) return error.ForeignTurn;
    const input: *Input = @ptrCast(@alignCast(body.ctx));
    if (turn.vat != &input.producer.host.vat) return error.ForeignTurn;
    return input.producer;
}

/// Acquire callback observations separately from the queue's keeper retains. A
/// behavior can release its observations and return an aliased argument. The
/// queue still holds that authority through owning-reply preparation.
pub fn arguments(turn: *actors.Turn) !struct { verb: []const u8, args: []const value_mod.Value } {
    const owner = try producer(turn);
    const input: *Input = @ptrCast(@alignCast(turn.opaque_message.?.ctx));
    _ = try owner.host.retainValueCapabilities(turn.arena, input.args);
    return .{ .verb = input.verb, .args = input.args };
}

/// Admit one exact local target on the Host's trusted local progress lane.
/// Queued inputs belong to the Host/Vat, while
/// the operation and bounded reply buffer belong to `allocator`.
pub fn callLocalCapability(host: *host_mod.Host, allocator: std.mem.Allocator, target: capability.Ref, verb: []const u8, args: []const value_mod.Value, reply_bytes: usize) !*owned.Call {
    return callAdmitted(host, allocator, target, verb, args, reply_bytes, .application);
}

/// One constructor for top-level and lease-authorized retained child calls.
pub fn callAdmitted(host: *host_mod.Host, allocator: std.mem.Allocator, target: capability.Ref, verb: []const u8, args: []const value_mod.Value, reply_bytes: usize, admission: @import("admission.zig").WorkAdmission) !*owned.Call {
    try host.refuseReentry();
    try admission.check(host);
    if (host.localActorFor(target) == null) return error.UnknownCapability;
    const charge = try inputCharge(host, verb, args);
    const id = try vows.peekVowId(host);
    const source = try host.allocator.create(Producer);
    source.* = .{ .host = host };
    errdefer source.release();
    source.lease = switch (admission) {
        .application => try host.admitPendingWork(),
        .retained => |lease| try lease.fork(),
    };
    const call = try owned.createLocal(host, allocator, reply_bytes, source);
    errdefer call.deinit();
    const row = try vows.reserveRow(host, null, .plain, .none, id);
    errdefer host.allocator.destroy(row);
    row.owner = .{ .owning = source };
    const installed: actors.Listener = .{ .ctx = row, .func = settlement.VowRow.fire };
    row.vow = try enqueue(host, source, target, verb, args, charge, installed);
    row.pending_cancel = .{ .row_listener = installed };
    vows.publishRow(host, row);
    host.vow_ids.commit(id);
    return call;
}

pub fn inputCharge(host: *host_mod.Host, verb: []const u8, args: []const value_mod.Value) !usize {
    const bytes = try value_copy.measureSlice(args);
    // Validate identities and count the same occurrence inventory retained by
    // the queue. No publication or target effect precedes this preflight.
    var count: usize = 0;
    const Counter = struct {
        host: *host_mod.Host,
        count: *usize,
        fn visit(self: @This(), ref: capability.Ref) !void {
            _ = self.host.capabilities.resolve(ref) orelse return error.UnknownCapability;
            self.count.* = try std.math.add(usize, self.count.*, 1);
        }
    };
    for (args) |*value| try value.forEachCapability(Counter{ .host = host, .count = &count }, Counter.visit);
    var charge = try std.math.add(usize, @sizeOf(Input), verb.len);
    charge = try std.math.add(usize, charge, bytes);
    charge = try std.math.add(usize, charge, try std.math.mul(usize, count, @sizeOf(capability.Ref)));
    return charge;
}

/// Local forwarding retains the original completion owner. Each actual
/// delivery owns its input, but no hop allocates another result buffer, Host
/// vow row or producer. Existing Vat forwarding carries the terminal token.
pub fn forward(turn: *actors.Turn, target: capability.Ref, verb: []const u8, args: []const value_mod.Value) !void {
    const source = try producer(turn);
    const actor = source.host.localActorFor(target) orelse return @import("foreign_forward.zig").begin(turn, source, target, verb, args);
    const charge = try inputCharge(source.host, verb, args);
    var input: Input = .{ .producer = source, .target = target, .verb = verb, .args = args, .owned_bytes = charge };
    try turn.forwardOpaque(actor, input.message());
}

/// Callback effects derive admission from their real local input owner.
pub fn send(turn: *actors.Turn, target: capability.Ref, verb: []const u8, args: []const value_mod.Value) !u64 {
    const parent = try producer(turn);
    const lease = if (parent.lease) |*lease| lease else return error.NoPendingWork;
    try lease.checkHost(parent.host);
    if (parent.host.localActorFor(target) != null)
        return @import("local_completion.zig").send(parent.host, lease, target, verb, args);
    const session = parent.host.capabilitySession(target) orelse return error.UnknownCapability;
    return @import("delivery.zig").sendValuesAdmitted(parent.host, session, target, verb, args, turn.arena, .{ .retained = lease });
}

pub fn tell(turn: *actors.Turn, target: capability.Ref, verb: []const u8, args: []const value_mod.Value) !void {
    const parent = try producer(turn);
    const lease = if (parent.lease) |*lease| lease else return error.NoPendingWork;
    try lease.checkHost(parent.host);
    if (parent.host.localActorFor(target) != null)
        return tellLocal(parent.host, lease, target, verb, args);
    const session = parent.host.capabilitySession(target) orelse return error.UnknownCapability;
    return @import("delivery.zig").tellValuesAdmitted(parent.host, session, target, verb, args, turn.arena, .{ .retained = lease });
}

/// The queue and its producer retain admitted notification work without an
/// answer vow. Turn tells and sessionless Host tells use the same ownership.
/// The discard Producer and copied ingress input survive the caller's borrowed
/// values and target release. Reusing queue custody avoids an answer allocation.
pub fn tellLocal(host: *host_mod.Host, lease: *@import("admission.zig").PendingWorkLease, target: capability.Ref, verb: []const u8, args: []const value_mod.Value) !void {
    try lease.checkHost(host);
    const actor = host.localActorFor(target) orelse return error.UnknownCapability;
    const charge = try inputCharge(host, verb, args);
    const source = try host.allocator.create(Producer);
    source.* = .{ .host = host, .destination = .discard };
    defer source.release();
    source.lease = try lease.fork();
    var input: Input = .{ .producer = source, .target = target, .verb = verb, .args = args, .owned_bytes = charge };
    return host.vat.tellOpaqueFromIngress(.local, actor, input.message());
}

/// Shared opaque queue admission for public and private result owners.
pub fn enqueue(host: *host_mod.Host, source: *Producer, target: capability.Ref, verb: []const u8, args: []const value_mod.Value, charge: usize, listener: actors.Listener) !actors.Vow {
    const actor = host.localActorFor(target) orelse return error.UnknownCapability;
    var input: Input = .{ .producer = source, .target = target, .verb = verb, .args = args, .owned_bytes = charge };
    return host.vat.sendOpaqueFromIngress(.local, actor, input.message(), listener);
}

/// Terminal Host cleanup never invokes an unstarted local behavior. Pending
/// owning resolvers are private settlement authorities and retire in place.
pub fn cancel(host: *host_mod.Host) void {
    if (host.vat.isExecuting()) return;
    host.vat.cancelLocalIngress("HostClosing") catch unreachable;
    // Terminal settlement has no application callback and removes only
    // existing rows: no growth or relocation can invalidate this traversal.
    // Copy the id before removal and visit each occupied bucket once.
    var entries = host.resolver_index.iterator();
    while (entries.next()) |entry| {
        const row = host.vows.get(entry.value_ptr.vow_id) orelse unreachable;
        if (row.forwarded == .owning) {
            const id = entry.key_ptr.*;
            @import("../vows/resolvers.zig").terminateOwned(host, id);
        }
    }
}
