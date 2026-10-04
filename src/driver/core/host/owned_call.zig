//! A bounded, owned result of one admitted capability send. Delivery and vows
//! remain the producers; this owner never consumes the application's FIFO.
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

    /// Result bytes and capability retains borrow this operation.
    pub fn result(self: *const Call) Result {
        const state: *const State = @ptrCast(@alignCast(self));
        return state.result();
    }

    /// Top-level, before Host destruction. Cancellation detaches the observer;
    /// it cannot undo a target effect that was already admitted.
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
        pending: struct { id: u64, peer: engine.PeerHandle },
        ready: value_mod.Value,
        failed: struct { kind: action.VowFailure, text: FailureText },
    } = .starting,

    /// Values, including nested capability retains, borrow this operation.
    /// Keep it alive through projection or acquire separate retains explicitly.
    fn result(self: *const State) Call.Result {
        return switch (self.state) {
            .pending => .pending,
            .ready => |value| .{ .ready = value },
            .failed => |*failed| .{ .failed = .{ .kind = failed.kind, .message = failed.text.message() } },
            .starting => unreachable,
        };
    }

    /// Detach the exact pending observer or release its completed value. This
    /// does not undo an already admitted target effect. Top-level, before Host
    /// destruction; cancellation needs no allocator after admission.
    fn deinit(self: *State) void {
        self.host.refuseReentry() catch unreachable;
        switch (self.state) {
            .pending => |pending| release.cancelObserved(self.host, pending.id, self.listener()),
            .ready => |value| lower.releaseValueCapabilitiesTerminalAt(self.host, &.{value}, null),
            .failed => {},
            .starting => unreachable,
        }
        self.allocator.free(self.memory);
        self.allocator.destroy(self);
    }

    /// Delivery installs this before committing the operation that can settle.
    fn observe(self: *State, session: *host_mod.HostSession, row: *settlement.VowRow) !void {
        if (row.answer_release == .peer_visible)
            row.observer_release = try session.served.port.peer.reserveAnswerRelease();
        row.inner = self.listener();
        self.state = .{ .pending = .{ .id = row.id, .peer = session.peer_handle } };
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
                const owned = lift.ownValue(self.host, session, self.fixed.allocator(), value) catch |err| {
                    self.fail(.broken, @errorName(err));
                    return;
                };
                self.state = .{ .ready = owned };
            },
            .broken => |reason| self.fail(@import("../vows/completion.zig").classifyFailure(self.host, pending.peer), reason),
            .give => self.fail(.broken, "UnsupportedValue"),
        }
    }
};

/// Internal delivery seam; the supported operation exposes result/deinit only.
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
    verb: []const u8,
    values: []const value_mod.Value,
    reply_bytes: usize,
) !*Call {
    try host.refuseReentry();
    if (reply_bytes == 0) return error.InvalidLimits;
    const self = try allocator.create(State);
    errdefer allocator.destroy(self);
    const memory = try allocator.alloc(u8, reply_bytes);
    errdefer allocator.free(memory);
    self.* = .{ .host = host, .allocator = allocator, .memory = memory, .fixed = .init(memory) };
    var staging = std.heap.ArenaAllocator.init(allocator);
    defer staging.deinit();
    _ = try @import("delivery.zig").sendObservedValues(host, session, target, verb, values, staging.allocator(), @ptrCast(self));
    return @ptrCast(self);
}
