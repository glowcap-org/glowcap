//! Forward a turn to a foreign session while retaining its original answer.
const std = @import("std");
const actors = @import("actors");
const engine = @import("engine");
const capability = @import("../capability.zig");
const values = @import("../value.zig");
const local = @import("local_delivery.zig");
const delivery = @import("delivery.zig");
const host_mod = @import("../host.zig");
const admission = @import("admission.zig");
const lower = @import("capabilities/lower.zig");
const lift = @import("capabilities/lift.zig");
const pump = @import("pump.zig");

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
                    break :reply .{ .broken = engine.Broken.unnamed("session closed") };
                };
                source.prepareWire(home, value) catch |err|
                    break :reply .{ .broken = engine.Broken.unnamed(@errorName(err)) };
                break :reply .{ .fulfilled = .{ .void = {} } };
            },
            .broken => |reason| failed: {
                source.failure_kind = @import("../vows/completion.zig").classifyFailure(host, self.peer);
                break :failed .{ .broken = reason };
            },
            .give => .{ .broken = engine.Broken.unnamed("UnsupportedValue") },
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

/// The destination vow owns this callback and the source session's pending
/// operation. Either session's cancellation retires both. Peer handles guard
/// the borrowed Port in AnswerTransfer. Completion projects the reply through
/// a temporary arena into the original answer store.
const WireForward = struct {
    host: *host_mod.Host,
    source: engine.PeerHandle,
    destination: engine.PeerHandle,
    transfer: actors.Turn.AnswerTransfer,

    fn complete(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *WireForward = @ptrCast(@alignCast(ctx.?));
        const host = self.host;
        defer host.allocator.destroy(self);
        const destination = host.sessionForPeer(self.destination);
        const source = host.sessionForPeer(self.source);
        if (source == null or !host.lifecyclePhase().serving() or
            source.?.lifecyclePhase() == .cancel_pending or source.?.lifecyclePhase() == .terminating)
        {
            if (resolution == .fulfilled) if (destination) |home|
                lift.discardValueObservation(host, home, resolution.fulfilled);
            return;
        }
        defer pump.markDirty(host, self.source);
        switch (resolution) {
            .fulfilled => |value| self.fulfill(source.?, destination, value) catch |err|
                self.breakAnswer(engine.Broken.unnamed(@errorName(err))),
            .broken => |reason| self.breakAnswer(reason),
            .give => self.breakAnswer(engine.Broken.unnamed("UnsupportedValue")),
        }
    }

    fn breakAnswer(self: *WireForward, reason: engine.Broken) void {
        self.transfer.tryComplete(.{ .broken = reason }) catch |err| switch (err) {
            // The caller may release its answer while the sibling call runs.
            error.InvalidReference => {},
            else => {
                const source = self.host.sessionForPeer(self.source).?;
                // This callback is the last reply owner. If even the break
                // cannot be published, close the source rather than leave
                // an open session owing an answer nobody can complete.
                pump.condemnAndClose(self.host, source, switch (err) {
                    error.OutOfMemory, error.OutboundBackpressure => .resource_exhausted,
                    else => .other,
                }, @errorName(err));
            },
        };
    }

    fn fulfill(self: *WireForward, source: *host_mod.HostSession, destination: ?*host_mod.HostSession, value: @import("model").Argument) !void {
        const home = destination orelse return error.SessionCondemned;
        var arena = std.heap.ArenaAllocator.init(self.host.allocator);
        defer arena.deinit();
        const lifted = try self.host.liftValue(home, arena.allocator(), value);
        defer lower.releaseValueCapabilitiesTerminalAt(self.host, &.{lifted}, null);
        var prepared = try self.host.prepareValues(source, arena.allocator(), &.{lifted});
        defer prepared.deinit();
        prepared.beginStaging();
        defer prepared.endStaging();
        try self.transfer.tryComplete(.{ .fulfilled = prepared.values[0] });
        _ = prepared.commit();
    }
};

pub fn beginWire(host: *host_mod.Host, source: *host_mod.HostSession, destination: *host_mod.HostSession, turn: *actors.Turn, target: capability.Ref, verb: ?[]const u8, args: []const values.Value) !void {
    const proof: admission.WorkAdmission = .{ .served = .{ .session = source, .turn = turn } };
    try proof.check(host);
    const answer = (try turn.prepareAnswerTransfer()) orelse {
        try delivery.tellValuesAdmitted(host, destination, target, verb, args, turn.arena, proof);
        turn.forwardNoAnswer();
        return;
    };
    const self = try host.allocator.create(WireForward);
    errdefer host.allocator.destroy(self);
    self.* = .{ .host = host, .source = source.peer_handle, .destination = destination.peer_handle, .transfer = answer };
    const id = try delivery.sendObservedValuesAdmitted(host, destination, target, verb, args, turn.arena, .{
        .listener = .{ .ctx = self, .func = WireForward.complete },
    }, proof);
    const row = host.vows.get(id).?;
    std.debug.assert(row.forwarded == .none);
    row.forwarded = .{ .wire_answer = source.peer_handle };
    host.beginSessionOperation(source);
    answer.commit(turn);
}
