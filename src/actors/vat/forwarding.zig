//! Answer transfer for queued and wire turns. Near calls remain synchronous.
const std = @import("std");
const engine = @import("engine");
const model = @import("model");
const vat_mod = @import("mod.zig");
const serve = @import("serve.zig");
const vows = @import("vows.zig");
const Vat = vat_mod.Vat;
const Turn = vat_mod.Turn;
const Error = vat_mod.Error;

const Answer = union(enum) { local: u64, wire: engine.AnswerTarget };
pub const ForwardContext = struct {
    vat: *Vat,
    port: ?*vat_mod.Port,
    answer: Answer,
};

/// Reserve before publishing a send or resolver; a no-answer turn needs neither
/// a continuation allocation nor an answer listener.
pub const ForwardReservation = union(enum) {
    no_answer,
    answer: struct { context: *ForwardContext, listener: vat_mod.ListenerReservation },
};

fn destination(turn: *const Turn) !?Answer {
    return switch (turn.origin) {
        .local => Error.NotLocal,
        .eventual => |eventual| if (eventual.answer) |id| .{ .local = id } else null,
        .served => |answer| if (answer) |wire| .{ .wire = wire } else null,
    };
}

pub fn forwardListener(ctx: ?*anyopaque, resolution: vat_mod.Resolution) void {
    const fc: *ForwardContext = @ptrCast(@alignCast(ctx.?));
    defer fc.vat.allocator.destroy(fc);
    switch (fc.answer) {
        .local => |id| {
            // The producer's settlement scope already owns these bytes across
            // listener reentry. Transfer this borrow without a second clone.
            const result: vat_mod.Resolution = switch (resolution) {
                .give => .{ .broken = "introduction not forwardable" },
                else => resolution,
            };
            vows.settleLocalPrepared(fc.vat, id, result);
        },
        .wire => |answer| switch (resolution) {
            .fulfilled => |value| serve.resolveFulfill(fc.port.?, answer, value) catch |err| fc.port.?.peer.emitFailure(err),
            .broken => |message| serve.resolveBreak(fc.port.?, answer, message) catch |err| fc.port.?.peer.emitFailure(err),
            .give => serve.resolveBreak(fc.port.?, answer, "introduction not forwardable") catch |err| fc.port.?.peer.emitFailure(err),
        },
    }
}

pub fn forwardTurn(self: *Vat, turn: *Turn, target: vat_mod.Ref, msg: vat_mod.Message) anyerror!model.Argument {
    if (turn.forwarded) return Error.AlreadyForwarded;
    if (turn.origin == .local) return self.nearFromPort(turn.port, turn.ingress, target, msg);
    const answer = try destination(turn);
    if (answer == null) {
        try turn.tell(target, msg);
        markForwarded(turn, false);
        return .{ .void = {} };
    }
    const reservation = try reserveForward(self, turn, if (target == .local) .local else .far);
    errdefer cancelForward(self, reservation);
    const vow = try turn.send(target, msg);
    commitForward(self, turn, reservation, vow);
    return .{ .void = {} };
}

pub fn reserveForward(self: *Vat, turn: *Turn, location: vat_mod.VowLocation) !ForwardReservation {
    if (turn.forwarded) return Error.AlreadyForwarded;
    const answer = (try destination(turn)) orelse return .no_answer;
    const context = try self.allocator.create(ForwardContext);
    errdefer self.allocator.destroy(context);
    const listener = if (turn.port) |port|
        try port.reserveListener(self, location)
    else blk: {
        if (location != .local) return Error.NotConnected;
        try vows.reserveLocalListener(self);
        break :blk vat_mod.ListenerReservation{ .location = .local };
    };
    context.* = .{ .vat = self, .port = turn.port, .answer = answer };
    return .{ .answer = .{ .context = context, .listener = listener } };
}

pub fn cancelForward(self: *Vat, reservation: ForwardReservation) void {
    switch (reservation) {
        .no_answer => {},
        .answer => |answer| self.allocator.destroy(answer.context),
    }
}

fn markForwarded(turn: *Turn, answered: bool) void {
    if (turn.origin == .eventual) turn.origin.eventual.outcome.* = if (answered) .deferred else .discarded;
    turn.forwarded = true;
}

pub fn commitForward(self: *Vat, turn: *Turn, reservation: ForwardReservation, vow: vat_mod.Vow) void {
    switch (reservation) {
        .no_answer => {},
        .answer => |answer| {
            const listener = vat_mod.Listener{ .ctx = answer.context, .func = forwardListener };
            if (turn.port) |port| {
                port.onReserved(self, answer.listener, vow, listener);
            } else {
                std.debug.assert(vow == .local and answer.listener.location == .local);
                vows.onReservedLocal(self, vow.local, listener);
            }
        },
    }
    markForwarded(turn, reservation == .answer);
}

/// An existing vow uses checked installation: it may already have a listener
/// or have settled, unlike a just-minted send's reserved continuation.
pub fn forwardTurnVow(self: *Vat, turn: *Turn, vow: vat_mod.Vow) !void {
    if (turn.forwarded) return Error.AlreadyForwarded;
    const answer = (try destination(turn)) orelse {
        markForwarded(turn, false);
        return;
    };
    const context = try self.allocator.create(ForwardContext);
    errdefer self.allocator.destroy(context);
    context.* = .{ .vat = self, .port = turn.port, .answer = answer };
    const listener = vat_mod.Listener{ .ctx = context, .func = forwardListener };
    if (turn.port) |port| try port.on(self, vow, listener) else try self.on(vow, listener);
    markForwarded(turn, true);
}
