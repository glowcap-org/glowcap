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
const Delivery = vat_mod.Delivery;
const IngressId = vat_mod.IngressId;
const ResolveInterceptor = vat_mod.ResolveInterceptor;
const Listener = vat_mod.Listener;
const Outcome = vat_mod.Outcome;
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
    /// Listener for a far send's vow, keyed by the question's identity in
    /// this Port's outbound answer namespace. Dense storage lets bulk failure
    /// pop one listener before each callback in O(1), while cancellation
    /// still sees the rest.
    far_listeners: std.AutoArrayHashMapUnmanaged(engine.OutboundAnswerTarget, Listener) = .{},
    /// A bulk break consumes every answer minted before it, including sends
    /// without observers: a vow whose row stamp is at or below this watermark
    /// is broken. Fresh sends after the break may still be observed.
    far_broken_stamp: u64 = 0,
    /// Local actor id for each export position projected on this Port.
    exports: std.AutoHashMapUnmanaged(u64, u64) = .{},
    /// Canonical export position already projecting a local actor.
    reverse_exports: std.AutoHashMapUnmanaged(u64, u64) = .{},

    pub fn init(allocator: std.mem.Allocator, peer: *engine.Peer) Port {
        return .{ .allocator = allocator, .peer = peer };
    }

    /// Tear down this Port, releasing the export-binding root each projected
    /// actor held (ADR-0014): a session's closure releases exactly the
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

    /// Location-transparent eventual-send through this session projection,
    /// on this Port's ingress.
    pub fn send(self: *Port, vat: *Vat, target: Ref, msg: Message) Error!Vow {
        return switch (target) {
            .local => |id| .{ .local = try ingress_mod.enqueueLocal(vat, self.ingress, self, id, msg, .answered) },
            .far => |far| self.sendFarTo(vat, .{ .far = far }, msg),
        };
    }

    fn sendFarTo(self: *Port, vat: *Vat, target: model.Reference, msg: Message) Error!Vow {
        const answer = try self.peer.allocateAnswer();
        try farDeliverTo(vat, self, target, msg, answer.position);
        return .{ .far = answer };
    }

    /// `send` for a delivery whose arguments may be lent as views. The Port
    /// decides how it leaves (ADR-0064): arguments behind an owned slice go
    /// as that message, a far delivery whose views session validation
    /// counted no reference in leaves as freight, certified and encoded in
    /// place with nothing copied, and any other views are materialized once
    /// into the vat's allocator and freed when the queue or the wire has
    /// taken them.
    pub fn sendDelivery(self: *Port, vat: *Vat, target: Ref, delivery: Delivery) Error!Vow {
        if (delivery.args.ownedSlice()) |args| return self.send(vat, target, .{ .verb = delivery.verb, .args = args });
        switch (target) {
            .local => |id| return .{ .local = try enqueueLocalDelivery(vat, self, id, delivery, .answered) },
            .far => |far| {
                const answer = try self.peer.allocateAnswer();
                try farDeliverViews(vat, self, .{ .far = far }, delivery, answer.position);
                return .{ .far = answer };
            },
        }
    }

    /// `sendDelivery` with no answer.
    pub fn tellDelivery(self: *Port, vat: *Vat, target: Ref, delivery: Delivery) Error!void {
        if (delivery.args.ownedSlice()) |args| return self.tell(vat, target, .{ .verb = delivery.verb, .args = args });
        switch (target) {
            .local => |id| _ = try enqueueLocalDelivery(vat, self, id, delivery, .unanswered),
            .far => |far| try farDeliverViews(vat, self, .{ .far = far }, delivery, null),
        }
    }

    /// Promise-pipelined eventual-send through this Port's answer namespace.
    /// A vow whose question the session no longer holds is settled as far as status-allow: lifecycle transition
    /// this Port can tell, so pipelining onto it is refused.
    pub fn sendToAnswer(self: *Port, vat: *Vat, answer: engine.OutboundAnswerTarget, msg: Message) Error!Vow {
        if (!self.peer.session_state.hasLiveOutboundAnswer(answer)) return error.AlreadySettled;
        return self.sendFarTo(vat, .{ .promise = .{ .answer_position = answer.position } }, msg);
    }

    /// Fire-and-forget eventual-send through this Port's answer namespace.
    pub fn tellToAnswer(self: *Port, vat: *Vat, answer: engine.OutboundAnswerTarget, msg: Message) Error!void {
        if (!self.peer.session_state.hasLiveOutboundAnswer(answer)) return error.AlreadySettled;
        return farDeliverTo(vat, self, .{ .promise = .{ .answer_position = answer.position } }, msg, null);
    }

    /// `send` with no answer.
    pub fn tell(self: *Port, vat: *Vat, target: Ref, msg: Message) Error!void {
        switch (target) {
            .local => |id| _ = try ingress_mod.enqueueLocal(vat, self.ingress, self, id, msg, .unanswered),
            .far => |far| try farDeliverTo(vat, self, .{ .far = far }, msg, null),
        }
    }

    /// Observe a local Vat vow or a far vow in this Port's answer namespace.
    pub fn on(self: *Port, vat: *Vat, vow: Vow, listener: Listener) Error!void {
        switch (vow) {
            .local => try vat.on(vow, listener),
            .far => |answer| {
                if (!self.farObservable(answer)) return error.AlreadySettled;
                const gop = try self.far_listeners.getOrPut(self.allocator, answer);
                if (gop.found_existing) return error.AlreadyListening;
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
    pub fn breakRetracted(self: *Port, answer: engine.OutboundAnswerTarget, reason: []const u8) void {
        const entry = self.far_listeners.fetchSwapRemove(answer) orelse return;
        entry.value.func(entry.value.ctx, .{ .broken = reason });
    }

    /// Reserve the exact listener table a not-yet-committed send will use. status-allow: pending state or quoted runtime label
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
                std.debug.assert(self.farObservable(answer));
                std.debug.assert(!self.far_listeners.contains(answer));
                self.far_listeners.putAssumeCapacity(answer, listener);
            },
        }
    }

    /// Whether a far vow in this Port's answer namespace can still be
    /// observed: minted after the last bulk break, and neither settled nor
    /// consumed at the session.
    fn farObservable(self: *const Port, answer: engine.OutboundAnswerTarget) bool {
        return answer.row_id > self.far_broken_stamp and self.peer.canObserveAnswer(answer);
    }

    /// Dispatch one inbound event under this Port's causal ingress.
    pub fn serve(self: *Port, vat: *Vat, event: *engine.Event) !bool {
        const state = try ingress_mod.ingressState(vat, self.ingress);
        state.active_turns += 1;
        defer state.active_turns -= 1;
        return serve_mod.serve(vat, self, event);
    }

    pub fn settleFar(self: *Port, vat: *Vat, answer: engine.OutboundAnswerTarget, outcome: Outcome) Error!void {
        return serve_mod.settleFar(vat, self, answer, outcome);
    }

    pub fn breakFarVows(self: *Port, message: []const u8) void {
        serve_mod.breakFarVows(self, message);
    }

    /// Bind an already-spawned local actor to export `position` so a partner's
    /// deliveries to that position run the actor (dispatched by `serve`). This
    /// is the numeric-position primitive. The by-name publish verb one layer
    /// up (`Served.publish`, `driver.Session.publish`) rides on it. Binding
    /// *reserves* the position, it does not grant it: the partner can address
    /// the actor only once its reference first marshals onto the wire, or
    /// after an explicit `peer.exportObject` grant (ADR-0027). Only a local
    /// actor can be bound, a far ref already lives elsewhere, so a far ref
    /// returns `NotLocal`.
    pub fn bindExport(self: *Port, vat: *Vat, actor: Ref, position: u64) !void {
        const local_id = switch (actor) {
            .local => |a| a,
            .far => return error.NotLocal,
        };
        // Reject a collision before touching the peer: the export to actor map is
        // authority (it decides which local object a partner reaches), so a second
        // bind to the same position fails loud rather than orphaning the first.
        try self.reverse_exports.ensureUnusedCapacity(self.allocator, 1);
        const gop = try self.exports.getOrPut(self.allocator, position);
        if (gop.found_existing) return error.AlreadyPublished;
        // getOrPut inserted the key with an undefined value; if registering the
        // export fails, drop the half-inserted entry so the map never holds a
        // position the peer doesn't actually export.
        errdefer std.debug.assert(self.exports.remove(position));
        try self.peer.reserveExport(position);
        gop.value_ptr.* = local_id;
        if (!self.reverse_exports.contains(local_id)) {
            self.reverse_exports.putAssumeCapacity(local_id, position);
            // The actor's first binding on this Port is a rooting relationship
            // (ADR-0014), released by rollback of the last binding or Port
            // teardown.
            vat.retainActor(local_id);
        }
    }

    /// The local `Ref` bound to wire export `position`, or null when no actor
    /// is exported there, the inverse of `bindExport`'s position-to-actor map.
    /// A surface that receives a near reference (which names an object by its
    /// wire export position, not its vat-local actor id) resolves it through
    /// here so a position is never mistaken for an actor id. `serve` resolves
    /// an inbound deliver's target the same way.
    pub fn refForExport(self: *const Port, position: u64) ?Ref {
        const local_id = self.exports.get(position) orelse return null;
        return .{ .local = local_id };
    }

    pub const Projection = struct {
        near: model.NearRef,
        created: bool,
    };

    /// Undo a bind that never became shared with the partner. Dropping the
    /// actor's last binding on this Port also releases the export-binding
    /// root that bind took (ADR-0014).
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
            .far => return error.NotLocal,
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

/// Views to a local actor are materialized once into the vat's allocator
/// and freed after the queue copied them.
fn enqueueLocalDelivery(vat: *Vat, port: *Port, id: u64, delivery: Delivery, answered: ingress_mod.Answer) Error!u64 {
    const message = try materialize(vat, delivery);
    defer model.freeArgumentSlice(vat.allocator, message.args);
    return ingress_mod.enqueueLocal(vat, port.ingress, port, id, message, answered);
}

fn materialize(vat: *Vat, delivery: Delivery) Error!Message {
    return .{ .verb = delivery.verb, .args = delivery.args.toOwnedSlice(vat.allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedView => Error.MalformedView,
    } };
}

/// Inside a turn the Port enrolls before a far send, so the send is
/// retractable if the turn fails (ADR-0058), and an answered send reserves
/// the break its retraction fires.
fn enrollFarSend(vat: *Vat, port: *Port, answered: bool) Error!void {
    const peer = port.peer;
    if (vat.turn_depth != 0 and !peer.provisional) {
        try vat.enrollTurn(.{ .ctx = port, .commit = commitTurn, .abort = abortTurn });
        peer.openProvisional();
    }
    if (vat.turn_depth != 0 and answered) try @import("turn_commit.zig").reserveBreak(vat);
}

fn releaseBreakReservation(vat: *Vat, answered: bool) void {
    if (vat.turn_depth != 0 and answered) vat.turn_break_reservations -= 1;
}

/// The spine a far `op:deliver` is encoded from: the verb as a leading
/// symbol, then `count` arguments the caller fills in from `head`. `buf`
/// backs the common arity, and a longer spine comes from the vat's
/// allocator, which the caller frees when the spine outgrew `buf`.
fn verbSpine(comptime Elem: type, vat: *Vat, buf: []Elem, verb: ?[]const u8, count: usize) Error!struct { spine: []Elem, head: usize } {
    const has_verb = verb != null;
    const total = std.math.add(usize, count, @intFromBool(has_verb)) catch return error.MalformedView;
    const spine = if (total <= buf.len) buf[0..total] else try vat.allocator.alloc(Elem, total);
    if (verb) |method| spine[0] = .{ .symbol = method };
    return .{ .spine = spine, .head = @intFromBool(has_verb) };
}

/// Encode one far `op:deliver` while the caller's message is borrowed. The
/// outbound queue takes the one owned boundary clone. Only the verb-splice
/// spine is scratch.
fn farDeliverTo(vat: *Vat, port: *Port, target: model.Reference, msg: Message, answer: ?model.AnswerPosition) Error!void {
    const peer = port.peer;
    try enrollFarSend(vat, port, answer != null);
    errdefer releaseBreakReservation(vat, answer != null);
    var buf: [8]model.Argument = undefined;
    const spine = try verbSpine(model.Argument, vat, &buf, msg.verb, msg.args.len);
    defer if (spine.spine.len > buf.len) vat.allocator.free(spine.spine);
    for (msg.args, 0..) |argument, i| spine.spine[spine.head + i] = argument;
    peer.sendBorrowed(.{ .deliver = .{
        .target = target,
        .args = spine.spine,
        .answer = answer,
    } }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.SendRejected,
    };
}

/// `farDeliverTo` for a delivery lent as views. One session validation
/// counted no reference in leaves as freight (ADR-0064): the verb is
/// spliced ahead of the views in the same spine, and the peer certifies
/// and encodes the tree in place. Any other views are materialized once,
/// because the tree may name a reference the session must rewrite.
fn farDeliverViews(vat: *Vat, port: *Port, target: model.Reference, delivery: Delivery, answer: ?model.AnswerPosition) Error!void {
    if (delivery.reference_slots != 0) {
        const message = try materialize(vat, delivery);
        defer model.freeArgumentSlice(vat.allocator, message.args);
        return farDeliverTo(vat, port, target, message, answer);
    }
    const peer = port.peer;
    try enrollFarSend(vat, port, answer != null);
    errdefer releaseBreakReservation(vat, answer != null);
    var buf: [8]model.view.Argument = undefined;
    const count = delivery.args.len() catch return error.MalformedView;
    const spine = try verbSpine(model.view.Argument, vat, &buf, delivery.verb, count);
    defer if (spine.spine.len > buf.len) vat.allocator.free(spine.spine);
    var head = spine.head;
    var it = delivery.args.iterator();
    while (it.next() catch return error.MalformedView) |argument| : (head += 1) {
        if (head == spine.spine.len) return error.MalformedView;
        spine.spine[head] = argument;
    }
    if (head != spine.spine.len) return error.MalformedView;
    peer.sendFreight(target, .fromViews(spine.spine), answer) catch |err| return switch (err) {
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
        fn retracted(erased: *anyopaque, answer: engine.OutboundAnswerTarget) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            if (self.port.far_listeners.contains(answer)) {
                self.vat.turn_breaks.appendAssumeCapacity(.{ .port = self.port, .answer = answer });
            }
        }
    };
    var breaker: Breaker = .{ .port = port, .vat = vat };
    port.peer.retractProvisional(&breaker, Breaker.retracted);
}
