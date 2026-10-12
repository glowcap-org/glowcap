//! One session's projection of a Vat onto CapTP wire names.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");
const ingress_mod = @import("ingress.zig");
const serve_mod = @import("serve.zig");
const vat_mod = @import("mod.zig");
const vows = @import("vows.zig");

const Vat = vat_mod.Vat;
const Ref = vat_mod.Ref;
const Vow = vat_mod.Vow;
const VowLocation = vat_mod.VowLocation;
const ListenerReservation = vat_mod.ListenerReservation;
const Message = vat_mod.Message;
const IngressId = vat_mod.IngressId;
const ResolveInterceptor = vat_mod.ResolveInterceptor;
const Listener = vat_mod.Listener;
const FarOutcome = vat_mod.FarOutcome;
const Error = vat_mod.Error;

/// One CapTP session's projection of a Vat: wire peer, export positions, and
/// far-vow settlement. A Port owns names and authority that exist only on that
/// session. The Vat owns the actor graph and turn machinery shared by every
/// Port attached to it.
pub const Port = struct {
    allocator: std.mem.Allocator,
    /// Borrowed from the Node that owns this session's Peer allocation.
    peer: *engine.Peer,
    /// Causal/admission identity in the Vat. Standalone Ports use `.local`.
    /// A multi-Port Host assigns one minted ingress per session.
    ingress: IngressId = .local,
    resolve_interceptor: ?ResolveInterceptor = null,
    /// Listener for a far send's vow, keyed by this Port's outbound answer
    /// position namespace. Dense storage lets bulk failure pop one listener
    /// before each callback in O(1), while cancellation still sees the rest.
    far_listeners: std.AutoArrayHashMapUnmanaged(model.AnswerPosition, Listener) = .{},
    /// A bulk break consumes every previously minted answer, including sends
    /// without observers. Fresh sends after the break may still be observed.
    far_broken_before: u64 = 0,
    /// Local actor id for each export position projected on this Port.
    exports: std.AutoHashMapUnmanaged(u64, u64) = .{},
    /// Canonical export position already projecting a local actor.
    reverse_exports: std.AutoHashMapUnmanaged(u64, u64) = .{},

    pub fn init(allocator: std.mem.Allocator, peer: *engine.Peer) Port {
        return .{ .allocator = allocator, .peer = peer };
    }

    /// Tear down this Port, releasing the export-binding root each projected
    /// actor held (ADR-0101): a session's closure releases exactly the
    /// retains that session held, never the actor itself.
    pub fn deinit(self: *Port, vat: *Vat) void {
        var bound = self.reverse_exports.keyIterator();
        while (bound.next()) |actor_id| vat.releaseActor(actor_id.*);
        vows.freeOwnedForwardContexts(vat, &self.far_listeners);
        self.far_listeners.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.reverse_exports.deinit(self.allocator);
        self.* = undefined;
    }

    /// Install (or clear) the fulfilled-reply interceptor for this session.
    pub fn setResolveInterceptor(self: *Port, interceptor: ?ResolveInterceptor) void {
        self.resolve_interceptor = interceptor;
    }

    /// Location-transparent eventual-send through this session projection.
    pub fn send(self: *Port, vat: *Vat, target: Ref, msg: Message) Error!Vow {
        return self.sendFromIngress(vat, self.ingress, target, msg);
    }

    pub fn sendFromIngress(self: *Port, vat: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!Vow {
        if (ingress != self.ingress) return Error.UnknownIngress;
        _ = try ingress_mod.ingressState(vat, ingress);
        return switch (target) {
            .local => |id| .{ .local = try ingress_mod.enqueueLocal(vat, ingress, self, id, msg, true) },
            .far => |far| self.sendFarTo(vat, .{ .far = far }, msg),
        };
    }

    fn sendFarTo(self: *Port, vat: *Vat, target: model.Reference, msg: Message) Error!Vow {
        const answer = model.AnswerPosition.from(self.peer.allocateAnswer() catch |err| switch (err) {
            error.OutboundAnswerSpaceExhausted => return Error.ResourceExhausted,
        });
        try farDeliverTo(vat, self, target, msg, answer);
        return .{ .far = answer };
    }

    /// Promise-pipelined eventual-send through this Port's answer namespace.
    pub fn sendToAnswer(self: *Port, vat: *Vat, answer: model.AnswerPosition, msg: Message) Error!Vow {
        return self.sendFarTo(vat, .{ .promise = .{ .answer_position = answer } }, msg);
    }

    /// Fire-and-forget eventual-send through this Port's answer namespace.
    pub fn tellToAnswer(self: *Port, vat: *Vat, answer: model.AnswerPosition, msg: Message) Error!void {
        return farDeliverTo(vat, self, .{ .promise = .{ .answer_position = answer } }, msg, null);
    }

    pub fn tell(self: *Port, vat: *Vat, target: Ref, msg: Message) Error!void {
        return self.tellFromIngress(vat, self.ingress, target, msg);
    }

    pub fn tellFromIngress(self: *Port, vat: *Vat, ingress: IngressId, target: Ref, msg: Message) Error!void {
        if (ingress != self.ingress) return Error.UnknownIngress;
        _ = try ingress_mod.ingressState(vat, ingress);
        switch (target) {
            .local => |id| _ = try ingress_mod.enqueueLocal(vat, ingress, self, id, msg, false),
            .far => |far| try farDeliverTo(vat, self, .{ .far = far }, msg, null),
        }
    }

    /// Observe a local Vat vow or a far vow in this Port's answer namespace.
    pub fn on(self: *Port, vat: *Vat, vow: Vow, listener: Listener) Error!void {
        switch (vow) {
            .local => try vat.on(vow, listener),
            .far => |answer| {
                if (answer.int() < self.far_broken_before or !self.peer.canObserveAnswer(answer)) return Error.AlreadySettled;
                const gop = try self.far_listeners.getOrPut(self.allocator, answer);
                if (gop.found_existing) return Error.AlreadyListening;
                gop.value_ptr.* = listener;
            },
        }
    }

    /// Remove and return one pending vow listener without settling the vow.
    /// This is the lifetime inverse of `on`: callers that own the listener
    /// context can retire it while the underlying local turn or wire answer
    /// continues independently.
    pub fn takeListener(self: *Port, vat: *Vat, vow: Vow) ?Listener {
        return switch (vow) {
            .local => vat.takeListener(vow),
            .far => |answer| if (self.far_listeners.fetchSwapRemove(answer)) |entry| entry.value else null,
        };
    }

    /// Rollback removed the send before this notification. Its observer can
    /// still cancel through takeListener while another failure listener runs.
    pub fn breakRetracted(self: *Port, answer: model.AnswerPosition, reason: []const u8) void {
        const entry = self.far_listeners.fetchSwapRemove(answer) orelse return;
        entry.value.func(entry.value.ctx, .{ .broken = reason });
    }

    /// Reserve the exact listener table a not-yet-committed send will use.
    /// Keeping this at the Port seam prevents Host and other adapters from
    /// reaching into Vat or per-session listener maps independently.
    pub fn reserveListener(self: *Port, vat: *Vat, location: VowLocation) Error!ListenerReservation {
        switch (location) {
            .local => try vows.reserveLocalListener(vat),
            .far => try self.far_listeners.ensureUnusedCapacity(self.allocator, 1),
        }
        return .{ .location = location };
    }

    /// Install into capacity reserved before the vow-producing operation.
    /// Fresh vows cannot already be listened on or settled until their caller
    /// drives the Vat/Port, so violating either assertion is an adapter bug.
    pub fn onReserved(
        self: *Port,
        vat: *Vat,
        reservation: ListenerReservation,
        vow: Vow,
        listener: Listener,
    ) void {
        switch (vow) {
            .local => |id| {
                std.debug.assert(reservation.location == .local);
                vows.onReservedLocal(vat, id, listener);
            },
            .far => |answer| {
                std.debug.assert(reservation.location == .far);
                std.debug.assert(answer.int() >= self.far_broken_before and self.peer.canObserveAnswer(answer));
                std.debug.assert(!self.far_listeners.contains(answer));
                self.far_listeners.putAssumeCapacity(answer, listener);
            },
        }
    }

    /// Dispatch one inbound event under this Port's causal ingress.
    pub fn serveFromIngress(self: *Port, vat: *Vat, ingress: IngressId, event: *engine.Event) !bool {
        if (ingress != self.ingress) return Error.UnknownIngress;
        const state = try ingress_mod.ingressState(vat, ingress);
        state.active_turns += 1;
        defer state.active_turns -= 1;
        return serve_mod.serveFromIngress(vat, self, ingress, event);
    }

    pub fn serve(self: *Port, vat: *Vat, event: *engine.Event) !bool {
        return self.serveFromIngress(vat, self.ingress, event);
    }

    pub fn settleFar(self: *Port, vat: *Vat, answer: model.AnswerPosition, outcome: FarOutcome) Error!void {
        return serve_mod.settleFar(vat, self, answer, outcome);
    }

    pub fn breakFarVows(self: *Port, message: []const u8) void {
        serve_mod.breakFarVows(self, message);
    }

    pub fn bindExport(self: *Port, vat: *Vat, actor: Ref, position: u64) !void {
        return serve_mod.bindExport(self, vat, actor, position);
    }

    pub fn refForExport(self: *const Port, position: u64) ?Ref {
        return serve_mod.refForExport(self, position);
    }

    pub const Projection = struct {
        near: model.NearRef,
        created: bool,
    };

    /// Undo a bind that never became shared with the partner. Dropping the
    /// actor's last binding on this Port also releases the export-binding
    /// root that bind took (ADR-0101).
    pub fn rollbackExport(self: *Port, vat: *Vat, actor: Ref, position: u64) void {
        const actor_id = switch (actor) {
            .local => |id| id,
            .far => unreachable,
        };
        std.debug.assert(self.exports.get(position).? == actor_id);
        std.debug.assert(self.exports.remove(position));
        if (self.reverse_exports.get(actor_id) == position) {
            var replacement: ?u64 = null;
            var it = self.exports.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == actor_id) {
                    replacement = entry.key_ptr.*;
                    break;
                }
            }
            if (replacement) |other| {
                self.reverse_exports.getPtr(actor_id).?.* = other;
            } else {
                std.debug.assert(self.reverse_exports.remove(actor_id));
                vat.releaseActor(actor_id);
            }
        }
        self.peer.session_state.releaseUnsharedExport(.from(position));
    }

    /// Reuse or lazily mint this Port's canonical wire position for `actor`,
    /// reporting whether this call created the row. The receipt lets a caller
    /// whose larger transaction later fails roll back only authority it minted.
    pub fn prepareProjection(self: *Port, vat: *Vat, actor: Ref) !Projection {
        const actor_id = switch (actor) {
            .local => |id| id,
            .far => return Error.NotLocal,
        };
        if (self.reverse_exports.get(actor_id)) |position| return .{
            .near = model.NearRef.object(position),
            .created = false,
        };
        const position = try self.peer.exportNextObject();
        errdefer self.peer.session_state.releaseUnsharedExport(.from(position));
        try self.bindExport(vat, actor, position);
        return .{
            .near = model.NearRef.object(position),
            .created = true,
        };
    }

    /// Reuse or lazily mint this Port's canonical wire position for `actor`.
    pub fn projectActor(self: *Port, vat: *Vat, actor: Ref) !model.NearRef {
        return (try self.prepareProjection(vat, actor)).near;
    }
};

/// Encode one far `op:deliver` while the caller's message is borrowed. The
/// outbound queue takes the one owned boundary clone. Only the verb-splice
/// spine is scratch, stack-backed for the common arity. Inside a turn the Port
/// enrolls first, so the send is retractable if the turn fails (ADR-0194).
fn farDeliverTo(vat: *Vat, port: *Port, target: model.Reference, msg: Message, answer: ?model.AnswerPosition) Error!void {
    const peer = port.peer;
    if (vat.turn_depth != 0 and !peer.provisional) {
        try vat.enrollTurn(.{ .ctx = port, .commit = commitTurn, .abort = abortTurn });
        peer.openProvisional();
    }
    const reserve_break = vat.turn_depth != 0 and answer != null;
    if (reserve_break) try @import("turn_commit.zig").reserveBreak(vat);
    errdefer if (reserve_break) {
        vat.turn_break_reservations -= 1;
    };
    const has_verb = msg.verb.len > 0;
    const total = msg.args.len + @intFromBool(has_verb);
    var buf: [8]model.Argument = undefined;
    const full = if (total <= buf.len)
        buf[0..total]
    else
        try vat.allocator.alloc(model.Argument, total);
    defer if (total > buf.len) vat.allocator.free(full);
    var head: usize = 0;
    if (has_verb) {
        full[0] = .{ .symbol = msg.verb };
        head = 1;
    }
    for (msg.args, 0..) |argument, i| full[head + i] = argument;
    peer.sendCopying(.{ .deliver = .{
        .target = target,
        .args = full,
        .answer = answer,
    } }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.SendRejected,
    };
}

fn commitTurn(ctx: *anyopaque, vat: *Vat) void {
    _ = vat;
    const port: *Port = @ptrCast(@alignCast(ctx));
    port.peer.commitProvisional();
}

/// Retract the failed turn's far sends. The Vat notifies their listeners only
/// after every participant has undone its effects.
fn abortTurn(ctx: *anyopaque, vat: *Vat, reason: []const u8) void {
    _ = reason;
    const port: *Port = @ptrCast(@alignCast(ctx));
    const Breaker = struct {
        port: *Port,
        vat: *Vat,
        fn retracted(erased: *anyopaque, answer: model.AnswerPosition) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            if (self.port.far_listeners.contains(answer)) {
                self.vat.turn_breaks.appendAssumeCapacity(.{ .port = self.port, .answer = answer });
            }
        }
    };
    var breaker: Breaker = .{ .port = port, .vat = vat };
    port.peer.retractProvisional(&breaker, Breaker.retracted);
}
