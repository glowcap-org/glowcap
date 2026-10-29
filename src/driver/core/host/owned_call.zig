//! A bounded, owned result of one admitted capability send. Delivery and vows
//! remain the producers. This owner never consumes the application's FIFO.
const std = @import("std");
const actors = @import("actors");
const engine = @import("engine");
const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const value_mod = @import("../value.zig");
const FailureText = @import("failure_text.zig");
const action = @import("action.zig");
const settlement = @import("../vows/settlement.zig");
const release = @import("../vows/release.zig");
const lift = @import("capabilities/lift.zig");
const lower = @import("capabilities/lower.zig");

pub const Call = opaque {
    pub const Result = union(enum) {
        pending,
        ready: value_mod.Value,
        failed: struct { kind: action.VowFailure, message: []const u8 },
    };

    /// Retrying the same immutable reply cannot repair these preparation
    /// refusals. A resolver may still accept a different reply. Heap pressure
    /// and mutable resource limits remain retryable at their actual owners.
    pub fn replyRefusalIsPermanent(err: anyerror) bool {
        return switch (err) {
            error.ReplyCapacity,
            error.UnknownCapability,
            error.PromiseBroken,
            error.ValueTooDeep,
            error.NestingTooDeep,
            error.UnsupportedValue,
            error.OwningReplyRequired,
            => true,
            else => false,
        };
    }

    /// Exact caller-owned allocation demand: one operation and its fixed reply
    /// buffer. Queued input, Host rows and transport work have separate owners.
    pub fn sizeBound(reply_bytes: usize) !usize {
        if (reply_bytes == 0) return error.InvalidLimits;
        return std.math.add(usize, @sizeOf(State), reply_bytes);
    }

    /// Describe the two retained allocations to the caller's allocator owner.
    /// Physical arena growth and headers are derived by that owner.
    pub fn allocationBound(comptime Bound: type, reply_bytes: usize) !Bound {
        _ = try sizeBound(reply_bytes);
        var bound: Bound = .{};
        try bound.include(@sizeOf(State), @alignOf(State), 1);
        try bound.include(reply_bytes, 1, 1);
        return bound;
    }

    /// Result bytes and capability retains borrow this operation.
    pub fn result(self: *const Call) Result {
        const state: *const State = @ptrCast(@alignCast(self));
        return state.result();
    }

    /// Top-level, before Host destruction. Cancellation detaches the observer.
    /// It cannot undo a target effect that was already admitted.
    pub fn deinit(self: *Call) void {
        const state: *State = @ptrCast(@alignCast(self));
        state.deinit();
    }
};

const State = struct {
    host: *host_mod.Host,
    allocator: std.mem.Allocator,
    memory: []u8,
    fixed: std.heap.FixedBufferAllocator,
    state: union(enum) {
        starting,
        pending: struct { id: u64, peer: engine.PeerHandle, observer: actors.Listener },
        local: struct { producer: *@import("local_delivery.zig").Producer, prepared: ?value_mod.Value = null },
        ready: value_mod.Value,
        failed: struct { kind: action.VowFailure, text: FailureText },
    } = .starting,

    comptime {
        const Outcome = @FieldType(State, "state");
        std.debug.assert(@sizeOf(@FieldType(Outcome, "pending")) <= @sizeOf(@FieldType(Outcome, "failed")));
    }

    /// Values, including nested capability retains, borrow this operation.
    /// Keep it alive through projection or acquire separate retains explicitly.
    fn result(self: *const State) Call.Result {
        return switch (self.state) {
            .pending, .local => .pending,
            .ready => |value| .{ .ready = value },
            .failed => |*failed| .{ .failed = .{ .kind = failed.kind, .message = failed.text.message() } },
            .starting => unreachable,
        };
    }

    /// Detach the exact pending observer or release its completed value. This
    /// does not undo an already admitted target effect. Top-level, before Host
    /// destruction. Cancellation needs no allocator after admission.
    fn deinit(self: *State) void {
        self.host.refuseReentry() catch unreachable;
        switch (self.state) {
            .pending => |pending| release.cancelObserved(self.host, pending.id, pending.observer),
            .local => |local| {
                const producer = local.producer;
                std.debug.assert(producer.destination == .owning and producer.destination.owning == @as(*Call, @ptrCast(self)));
                producer.destination.owning = null;
                if (self.state.local.prepared) |value| lower.releaseValueCapabilitiesTerminalAt(self.host, &.{value}, null);
            },
            .ready => |value| lower.releaseValueCapabilitiesTerminalAt(self.host, &.{value}, null),
            .failed => {},
            .starting => unreachable,
        }
        self.allocator.free(self.memory);
        self.allocator.destroy(self);
    }

    /// Delivery installs this before committing the operation that can settle.
    fn observe(self: *State, session: *host_mod.HostSession, row: *settlement.VowRow) !void {
        if (row.answer_release == .owned)
            row.observer_release = try session.served.port.peer.reserveAnswerRelease();
        const observer = self.listener();
        row.inner = observer;
        self.state = .{ .pending = .{ .id = row.id, .peer = session.peer_handle, .observer = observer } };
    }

    fn listener(self: *State) actors.Listener {
        return .{ .ctx = self, .func = complete };
    }

    fn fail(self: *State, kind: action.VowFailure, reason: []const u8) void {
        self.state = .{ .failed = .{ .kind = kind, .text = FailureText.init(reason) } };
    }

    fn complete(context: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *State = @ptrCast(@alignCast(context.?));
        const pending = self.state.pending;
        switch (resolution) {
            .fulfilled => |value| {
                const session = self.host.sessions.get(pending.peer) orelse return self.fail(.closed, "session closed");
                const owned = self.ownWireReply(session, value) catch |err| {
                    self.fail(.broken, @errorName(err));
                    return;
                };
                self.state = .{ .ready = owned };
            },
            .broken => |reason| self.fail(@import("../vows/completion.zig").classifyFailure(self.host, pending.peer), reason),
            .give => self.fail(.broken, "UnsupportedValue"),
        }
    }

    fn ownWireReply(self: *State, session: *host_mod.HostSession, value: @import("model").Argument) !value_mod.Value {
        errdefer self.fixed.reset();
        var reply: ReplyAllocator = .{ .backing = self.fixed.allocator() };
        return lift.ownValue(self.host, session, reply.allocator(), value) catch |err| return reply.refusal(err);
    }
};

comptime {
    if (@sizeOf(usize) == 8 and @sizeOf(State) > 328)
        @compileError("owning Call exceeded its 328-byte operation budget");
}

/// Internal delivery seam. The supported operation exposes result/deinit only.
pub fn observe(call: *Call, session: *host_mod.HostSession, row: *settlement.VowRow) !void {
    const state: *State = @ptrCast(@alignCast(call));
    try state.observe(session, row);
}

/// Admit one resolved local or foreign capability call with bounded owned
/// reply storage. Unresolved promises need pipelining through the vow API.
/// The allocator owns both this operation and exactly `reply_bytes` of storage.
pub fn callCapability(
    host: *host_mod.Host,
    allocator: std.mem.Allocator,
    session: *host_mod.HostSession,
    target: capability.Ref,
    verb: ?[]const u8,
    values: []const value_mod.Value,
    reply_bytes: usize,
) !*Call {
    return callAdmitted(host, allocator, session, target, verb, values, reply_bytes, .application);
}

/// Internal counterpart with a synchronous admitted-work proof. Session
/// admission remains independent. A Host lease cannot reopen a session.
pub fn callAdmitted(host: *host_mod.Host, allocator: std.mem.Allocator, session: *host_mod.HostSession, target: capability.Ref, verb: ?[]const u8, values: []const value_mod.Value, reply_bytes: usize, admission: @import("admission.zig").WorkAdmission) !*Call {
    try host.refuseReentry();
    try admission.check(host);
    if (reply_bytes == 0) return error.InvalidLimits;
    const self = try allocator.create(State);
    errdefer allocator.destroy(self);
    const memory = try allocator.alloc(u8, reply_bytes);
    errdefer allocator.free(memory);
    self.* = .{ .host = host, .allocator = allocator, .memory = memory, .fixed = .init(memory) };
    var staging = std.heap.ArenaAllocator.init(allocator);
    defer staging.deinit();
    _ = try @import("delivery.zig").sendObservedValuesAdmitted(host, session, target, verb, values, staging.allocator(), .{ .call = @ptrCast(self) }, admission);
    return @ptrCast(self);
}

/// Internal local producer admission. State and its fixed reply buffer are
/// observer storage. The Host row and queue own all producer/input custody.
pub fn createLocal(host: *host_mod.Host, allocator: std.mem.Allocator, reply_bytes: usize, producer: *@import("local_delivery.zig").Producer) !*Call {
    if (reply_bytes == 0) return error.InvalidLimits;
    const self = try allocator.create(State);
    errdefer allocator.destroy(self);
    const memory = try allocator.alloc(u8, reply_bytes);
    self.* = .{ .host = host, .allocator = allocator, .memory = memory, .fixed = .init(memory), .state = .{ .local = .{ .producer = producer } } };
    producer.destination = .{ .owning = @ptrCast(self) };
    return @ptrCast(self);
}

/// Preparation failure leaves the observer pending and its fixed buffer
/// reusable. Acquire reply retains before the actor's state can retire.
pub fn prepareLocal(observer: *Call, value: value_mod.Value) !void {
    const self: *State = @ptrCast(@alignCast(observer));
    std.debug.assert(self.state == .local and self.state.local.prepared == null);
    errdefer self.fixed.reset();
    var reply: ReplyAllocator = .{ .backing = self.fixed.allocator() };
    const copied = @import("../value_copy.zig").copy(value_mod.Value, reply.allocator(), value) catch |err| return reply.refusal(err);
    try @import("capabilities/completion.zig").retainValue(self.host, copied);
    self.state.local.prepared = copied;
}

/// A foreign forwarding result projects once into the original local reply
/// buffer. The wire observation and its occurrence retains move to this owner.
pub fn prepareWire(observer: *Call, session: *host_mod.HostSession, value: @import("model").Argument) !void {
    const self: *State = @ptrCast(@alignCast(observer));
    std.debug.assert(self.state == .local and self.state.local.prepared == null);
    self.state.local.prepared = try self.ownWireReply(session, value);
}

/// Synchronous stack borrow of the fixed reply allocator. Record only a failed
/// allocation: resize/remap refusal can legitimately fall back to allocation.
/// Host-owned allocation refusal is never confused with this caller's bound.
const ReplyAllocator = struct {
    backing: std.mem.Allocator,
    refused: bool = false,

    fn allocator(self: *ReplyAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn refusal(self: *const ReplyAllocator, err: anytype) (@TypeOf(err) || error{ReplyCapacity}) {
        return if (err == error.OutOfMemory and self.refused) error.ReplyCapacity else err;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *ReplyAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, address) orelse {
            self.refused = true;
            return null;
        };
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *ReplyAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, len, address);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *ReplyAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, len, address);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *ReplyAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, address);
    }
};

/// The ordinary Vat vow settlement commits the prepared owning result. A
/// refused/rolled-back turn cannot publish a successful prepared reply.
pub fn finishLocal(observer: *Call, resolution: actors.Resolution, failure_kind: action.VowFailure) void {
    const self: *State = @ptrCast(@alignCast(observer));
    std.debug.assert(self.state == .local);
    if (resolution == .fulfilled) {
        const value = self.state.local.prepared orelse {
            self.fail(.broken, "OwningReplyRequired");
            return;
        };
        self.state.local.prepared = null;
        self.state = .{ .ready = value };
    } else {
        if (self.state.local.prepared) |value| lower.releaseValueCapabilitiesTerminalAt(self.host, &.{value}, null);
        self.state.local.prepared = null;
        self.fail(failure_kind, if (resolution == .broken) resolution.broken else "UnsupportedValue");
    }
}

/// Roll back a deferred result preparation if its resolver could not settle.
pub fn cancelLocalPreparation(observer: *Call) void {
    const self: *State = @ptrCast(@alignCast(observer));
    if (self.state.local.prepared) |value| lower.releaseValueCapabilitiesTerminalAt(self.host, &.{value}, null);
    self.state.local.prepared = null;
    self.fixed.reset();
}
