//! Answer transfer for queued and wire turns. Near calls remain synchronous.
const std = @import("std");
const engine = @import("engine");
const model = @import("model");
const vat_mod = @import("mod.zig");
const serve = @import("serve.zig");
const vows = @import("vows.zig");
const Vat = vat_mod.Vat;
const Turn = vat_mod.Turn;
const Port = vat_mod.Port;
const Error = vat_mod.Error;

/// Where a forwarded turn's completion goes: a local vow, or a served wire
/// answer with the Port that serves it.
const Answer = union(enum) {
    local: u64,
    wire: struct { port: *Port, target: engine.AnswerTarget },
};
pub const ForwardContext = struct {
    vat: *Vat,
    answer: Answer,

    /// Capture an eventual answer before an adapter publishes its effect.
    /// Storage belongs to the adapter. Completion never frees this context.
    pub fn prepare(turn: *const Turn) !?ForwardContext {
        if (turn.forwarded) return error.AlreadyForwarded;
        const answer = (try destination(turn)) orelse return null;
        return .{ .vat = turn.vat, .answer = answer };
    }

    /// The adapter has committed a completion recipient for this answer.
    pub fn commit(self: *const ForwardContext, turn: *Turn) void {
        std.debug.assert(self.vat == turn.vat);
        std.debug.assert(!turn.forwarded);
        std.debug.assert(std.meta.eql(self.answer, (destination(turn) catch unreachable).?));
        markForwarded(turn, true);
    }

    /// Resolution borrows the producer's settlement scope across reentry.
    pub fn complete(self: *const ForwardContext, resolution: vat_mod.Resolution) void {
        switch (self.answer) {
            .local => |id| vows.settleLocalPrepared(self.vat, id, switch (resolution) {
                .give => .{ .broken = "introduction not forwardable" },
                else => resolution,
            }),
            .wire => |wire| {
                const sent = switch (resolution) {
                    .fulfilled => |value| serve.resolveFulfill(wire.port, wire.target, value),
                    .broken => |message| serve.resolveBreak(wire.port, wire.target, message),
                    .give => serve.resolveBreak(wire.port, wire.target, "introduction not forwardable"),
                };
                sent catch |err| wire.port.peer.emitFailure(err);
            },
        }
    }
};

/// An existing vow outlives the turn installing its continuation. This temporary
/// receipt keeps the source key for rollback without enlarging every forwarding
/// context or searching the listener tables. Commit frees it, leaving the
/// ordinary context with the listener. Abort detaches before any notification.
const ForwardRegistration = struct {
    context: ?*ForwardContext,
    port: ?*Port,
    source: vat_mod.Vow,

    comptime {
        // Two pointers and a vow, whose far arm names its question by identity.
        std.debug.assert(@sizeOf(@This()) <= 40);
    }

    fn commit(ctx: *anyopaque, vat: *Vat) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        vat.allocator.destroy(self);
    }

    fn abort(ctx: *anyopaque, vat: *Vat, _: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const context = self.context.?;
        const listener = if (self.port) |port|
            port.takeListener(vat, self.source)
        else
            vat.takeListener(self.source);
        if (listener) |held| {
            std.debug.assert(held.ctx == @as(?*anyopaque, context) and held.func == vat.forward_listener);
        } else {
            self.context = null;
        }
    }

    fn notify(ctx: *anyopaque, vat: *Vat, reason: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        defer vat.allocator.destroy(self);
        const context = self.context orelse return;
        defer vat.allocator.destroy(context);
        context.complete(.{ .broken = reason });
    }
};

/// Reserve before publishing a send or resolver. A no-answer turn needs neither
/// a continuation allocation nor an answer listener.
pub const ForwardReservation = union(enum) {
    no_answer,
    answer: struct { context: *ForwardContext, listener: vat_mod.ListenerReservation },
};

fn destination(turn: *const Turn) !?Answer {
    return switch (turn.origin) {
        .local => Error.NotLocal,
        .eventual => |eventual| if (eventual.answer) |id| .{ .local = id } else null,
        .served => |answer| if (answer) |target| .{ .wire = .{ .port = turn.source.port, .target = target } } else null,
    };
}

pub fn forwardListener(ctx: ?*anyopaque, resolution: vat_mod.Resolution) void {
    const fc: *ForwardContext = @ptrCast(@alignCast(ctx.?));
    defer fc.vat.allocator.destroy(fc);
    fc.complete(resolution);
}

pub fn forwardTurn(self: *Vat, turn: *Turn, target: vat_mod.Ref, msg: vat_mod.Delivery) anyerror!model.Argument {
    if (turn.forwarded) return error.AlreadyForwarded;
    if (turn.origin == .local) return self.nearDelivery(turn.source, target, msg);
    // An eventual hop leaves the turn, and views end with it: a far hop is
    // the Port's to send as it is, and a local one is materialized once into
    // the turn arena, which holds it until the queue clones it
    // (`Turn.sendDelivery`).
    const answer = try destination(turn);
    if (answer == null) {
        try turn.tellDelivery(target, msg);
        markForwarded(turn, false);
        return .{ .void = {} };
    }
    const reservation = try reserveForward(self, turn, if (target == .local) .local else .far);
    errdefer cancelForward(self, reservation);
    const vow = try turn.sendDelivery(target, msg);
    commitForward(self, turn, reservation, vow);
    return .{ .void = {} };
}

/// Adapter-owned messages use the same queued answer transfer. The result
/// value belongs to the adapter. This vow carries only its completion token.
pub fn forwardOpaque(self: *Vat, turn: *Turn, target: vat_mod.Ref, body: vat_mod.OpaqueMessage) !void {
    if (turn.port() != null or target != .local) return error.NotConnected;
    const reservation = try reserveForward(self, turn, .local);
    errdefer cancelForward(self, reservation);
    const id = try @import("ingress.zig").enqueueOpaque(self, turn.ingress(), target.local, body, if (reservation == .answer) .answered else .unanswered);
    commitForward(self, turn, reservation, .{ .local = id });
}

pub fn reserveForward(self: *Vat, turn: *Turn, location: vat_mod.VowLocation) !ForwardReservation {
    const prepared = (try ForwardContext.prepare(turn)) orelse return .no_answer;
    const context = try self.allocator.create(ForwardContext);
    errdefer self.allocator.destroy(context);
    const listener = try turn.reserveListener(location);
    context.* = prepared;
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

pub fn commitNoAnswer(turn: *Turn) void {
    std.debug.assert(!turn.forwarded and (destination(turn) catch unreachable) == null);
    markForwarded(turn, false);
}

pub fn commitForward(self: *Vat, turn: *Turn, reservation: ForwardReservation, vow: vat_mod.Vow) void {
    switch (reservation) {
        .no_answer => {},
        .answer => |answer| {
            turn.onReserved(answer.listener, vow, .{ .ctx = answer.context, .func = self.forward_listener });
        },
    }
    markForwarded(turn, reservation == .answer);
}

/// An existing vow uses checked installation: it may already have a listener
/// or have settled, unlike a just-minted send's reserved continuation.
pub fn forwardTurnVow(self: *Vat, turn: *Turn, vow: vat_mod.Vow) !void {
    if (turn.forwarded) return error.AlreadyForwarded;
    const answer = (try destination(turn)) orelse {
        markForwarded(turn, false);
        return;
    };
    const context = try self.allocator.create(ForwardContext);
    errdefer self.allocator.destroy(context);
    context.* = .{ .vat = self, .answer = answer };
    const registration = try self.allocator.create(ForwardRegistration);
    errdefer self.allocator.destroy(registration);
    registration.* = .{ .context = context, .port = turn.port(), .source = vow };
    const listener = vat_mod.Listener{ .ctx = context, .func = self.forward_listener };
    try turn.observe(vow, listener);
    errdefer {
        const removed = turn.unobserve(vow);
        std.debug.assert(removed != null and removed.?.ctx == listener.ctx);
    }
    try self.enrollTurn(.{
        .ctx = registration,
        .commit = ForwardRegistration.commit,
        .abort = ForwardRegistration.abort,
        .abort_notify = ForwardRegistration.notify,
    });
    markForwarded(turn, true);
}
