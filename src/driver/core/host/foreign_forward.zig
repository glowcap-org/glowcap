//! Foreign answer transfer into the original owning local reply destination.
const actors = @import("actors");
const engine = @import("engine");
const capability = @import("../capability.zig");
const values = @import("../value.zig");
const local = @import("local_delivery.zig");
const delivery = @import("delivery.zig");

/// One completion box contains the existing Actors answer transfer plus its
/// actual wire home and strong original producer. The wire vow owns this box.
/// No child Call, resolver pair, result buffer or intermediate Value is
/// created. Input lowering and the wire row retain their existing independent
/// budgets.
const ForeignForward = struct {
    transfer: actors.Turn.AnswerTransfer,
    source: *local.Producer,
    peer: engine.PeerHandle,

    fn complete(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ForeignForward = @ptrCast(@alignCast(ctx.?));
        const source = self.source;
        const host = source.host;
        defer host.allocator.destroy(self);
        defer source.release();
        const session = host.sessionForPeer(self.peer);
        const token: actors.Resolution = switch (resolution) {
            .fulfilled => |value| reply: {
                const home = session orelse {
                    source.failure_kind = .closed;
                    break :reply .{ .broken = "session closed" };
                };
                source.prepareWire(home, value) catch |err|
                    break :reply .{ .broken = @errorName(err) };
                break :reply .{ .fulfilled = .{ .void = {} } };
            },
            .broken => |reason| failed: {
                source.failure_kind = @import("../vows/completion.zig").classifyFailure(host, self.peer);
                break :failed .{ .broken = reason };
            },
            .give => .{ .broken = "UnsupportedValue" },
        };
        self.transfer.complete(token);
    }
};

comptime {
    if (@sizeOf(usize) == 8 and @sizeOf(ForeignForward) != 64)
        @compileError("foreign forwarding changed its 64-byte completion box");
}

pub fn begin(turn: *actors.Turn, source: *local.Producer, target: capability.Ref, verb: ?[]const u8, args: []const values.Value) !void {
    const transfer = try turn.prepareAnswerTransfer();
    const host = source.host;
    const lease = if (source.lease) |*lease| lease else return error.NoPendingWork;
    try lease.checkHost(host);
    const session = (try host.capabilitySession(target)) orelse return error.UnknownCapability;
    const answer = transfer orelse {
        try delivery.tellValuesAdmitted(host, session, target, verb, args, turn.arena, .{ .retained = lease });
        turn.forwardNoAnswer();
        return;
    };
    const self = try host.allocator.create(ForeignForward);
    errdefer host.allocator.destroy(self);
    self.* = .{ .transfer = answer, .source = source, .peer = session.peer_handle };
    source.retain();
    errdefer source.release();
    _ = try delivery.sendObservedValuesAdmitted(host, session, target, verb, args, turn.arena, .{ .listener = .{ .ctx = self, .func = ForeignForward.complete } }, .{ .retained = lease });
    answer.commit(turn);
}
