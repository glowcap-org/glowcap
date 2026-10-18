//! The vat's wire-hosting family: serving inbound events and settling far vows.
//!
//! `serve` dispatches one inbound peer event. A deliver to a bound export
//! runs the actor's turn through the shared frame spine and resolves the
//! answer, and a resolve fires the far vow's one-shot listener, projecting a
//! handoff give typed. `settleFar` is the byte-fed host's counterpart to the
//! same settle, and `breakFarVows` is the disconnect break. `Port` binds the
//! session public verbs onto them.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");

const frame = @import("frame.zig");
const turn_commit = @import("turn_commit.zig");
const vat_mod = @import("mod.zig");
const vows = @import("vows.zig");

const Error = vat_mod.Error;
const Outcome = vat_mod.Outcome;
const Listener = vat_mod.Listener;
const Delivery = vat_mod.Delivery;
const Turn = vat_mod.Turn;
const Vat = vat_mod.Vat;
const Port = vat_mod.Port;

/// Dispatch one inbound peer event: a deliver to a published actor runs its
/// turn and resolves the answer (`serveDeliver`). A resolve for a far vow
/// fires its listener (`serveResolve`). Returns whether the event belonged
/// to this vat. If it did not, the caller handles it. The application polls
/// the peer and hands events here.
pub fn serve(self: *Vat, port: *Port, event: *engine.Event) !bool {
    const body = event.view();
    return switch (body.*) {
        .deliver => |deliver| serveDeliver(self, port, deliver, event.deliverAnswerTarget(), event.reference_slots),
        .resolve => |resolve| blk: {
            var handled = try serveResolve(self, port, resolve, event.resolveTarget());
            for (event.resolveAliases()) |alias| {
                handled = (try serveResolve(self, port, resolve, alias)) or handled;
            }
            break :blk handled;
        },
        else => false,
    };
}

/// The deliver arm of `serve`: run the bound actor's turn against the
/// borrowed wire message and resolve (or break) the inbound answer,
/// consulting the resolve interceptor on the fulfilled path.
fn serveDeliver(
    self: *Vat,
    port: *Port,
    deliver: model.view.Deliver,
    answer: ?engine.AnswerTarget,
    reference_slots: ?u32,
) !bool {
    const export_position = deliver.target.exportPosition() orelse return false;
    // V1.0: a resolver-only deliver carries no wire answer but names a resolver
    // descriptor. The engine maps it to the virtual answer it installed, so the
    // resolve reaches the partner. The engine owns that mapping, so the vat never
    // decodes the descriptor. Without a peer (no wire), only an explicit wire
    // answer exists.
    const local_id = port.exports.get(export_position.int()) orelse {
        // The bootstrap position is engine-owned: the peer
        // auto-answers its delivers (`fetch`, gift deposit /
        // withdraw) and only surfaces the event for observation,
        // so the vat must not race a break onto its answer.
        if (export_position.int() == engine.bootstrap_position) return false;
        // The engine admitted the deliver, so the position IS a
        // granted export at peer level, but no actor is bound
        // (no `Port.bindExport`). An answered call must
        // not strand the partner's vow, so break it, exactly
        // as the mapped-but-vanished case below does. A no-answer
        // `tell` stays a silent no-op the caller may handle.
        if (answer != null) {
            try resolveBreak(port, answer, @errorName(Error.NoSuchActor));
            return true;
        }
        return false;
    };
    // A dispatch refusal (depth, missing actor) breaks the answer
    // instead of failing the serve; `openTurnFrame` orders the checks
    // before the arena resets or the frame is marked running.
    const opened = frame.openTurnFrame(self, local_id) catch |err| switch (err) {
        Error.NearCallTooDeep, Error.NoSuchActor => {
            try resolveBreak(port, answer, @errorName(err));
            return true;
        },
        else => |other| return other,
    };
    const box = opened.box;
    const arena = opened.arena;
    // The reply and the interceptor both read `value` while
    // `running >= 1`, so the box `value` may alias is never freed
    // before the fulfill is sent.
    defer frame.closeTurnFrame(self, local_id);
    // The handler reads the frame's views where they lie. The frame
    // outlives this call, and the reply is copied onto the wire below,
    // inside the turn, so a reply that aliases an argument is still
    // valid when `resolveFulfill` reads it. A handler that keeps a
    // value past its turn copies it (module header).
    var delivery = try deliveryFor(deliver.args);
    delivery.reference_slots = reference_slots;
    var turn = Turn{ .vat = self, .source = .{ .port = port }, .self_id = local_id, .arena = arena, .origin = .{ .served = answer } };
    switch (box.handle(box.ptr, &turn, delivery)) {
        inline .returned, .viewed => |result| {
            const value = if (@TypeOf(result) == model.Argument) model.view.Argument.fromOwned(&result) else result;
            // The turn's local sends are queued before its reply (ADR-0191).
            // Promotion may run a discarded state's destructor and stage sends.
            frame.commitFrame(self, &turn);
            // A moved reply (`Turn.moveOut`) needs nothing here: the vat
            // already holds its bytes, and `resolveFulfill` copies the
            // reply onto the wire inside this turn, before the deferred
            // free. The wire copy is mandatory regardless, so the move
            // saves nothing on the serve path. It only avoids
            // `callLocal`'s sever-copy on the near path.
            // A forwarding actor handed its answer to another send's
            // vow; that vow resolves it, not this return.
            if (turn.forwarded) return true;
            try fulfillServed(self, port, answer, value);
            return true;
        },
        .refused => |failure| {
            frame.failFrame(self, &turn, failure.name);
            // Forwarding or an explicit break already owns this answer.
            if (turn.forwarded) return true;
            try resolveBreak(port, answer, failure.name);
            return true;
        },
    }
}

/// Resolve a served answer with the handler's reply, letting the port's
/// resolve interceptor claim or rewrite it first. The interceptor runs inside
/// the turn, so any top-level turn it opens is nested and never resets the
/// arena the value may live in.
fn fulfillServed(self: *Vat, port: *Port, answer: ?engine.AnswerTarget, value: model.view.Argument) !void {
    if (port.resolve_interceptor) |interceptor| if (answer) |ans| {
        const intercepted = interceptor.func(interceptor.ctx, ans, value);
        // The handler already committed. Finish nested callback
        // effects before handling either its result or refusal.
        if (self.turn_depth == 1) turn_commit.commit(self);
        const outcome = intercepted catch |err| return resolveBreak(port, answer, @errorName(err));
        switch (outcome) {
            // The interceptor resolved the answer itself
            // (an originated give); the vat sends nothing.
            .claimed => {},
            // Resolve with what it returned, the original
            // value, or a token rewritten to its wire
            // reference.
            .resolve => |reply| try resolveFulfillView(port, answer, reply),
        }
        return;
    };
    try resolveFulfillView(port, answer, value);
}

/// The fulfilled-arm settle spine shared by `serveResolve` and
/// `settleFar`, holding the choreography both must keep in sync. The clone defends two hazards: a listener may open a
/// top-level turn (`near` or `drive`) whose depth-0 turn-arena reset
/// would free a turn-borrowed value mid-call, and the value may borrow
/// actor state a listener-run turn mutates or `become`-frees. Its home is
/// the settle arena. Queue chunks own queued messages and are not listener
/// scratch. The depth guard keeps a re-entrant settle (a listener pumping
/// `serve` again) from resetting the arena under the outer value. Materialized
/// before the remove so a refused clone leaves the listener parked. That is
/// open to the far arms only because their producer survives the refusal: a
/// Host action stays parked for a retry, and a refused frame retires the
/// session, whose release runs `breakFarVows`. A local turn has no such
/// producer, so `settleLocal` breaks its waiter instead. `value` is borrowed
/// for the call.
fn fireFulfilledFar(self: *Vat, port: *Port, answer: engine.OutboundAnswerTarget, listener: Listener, value: model.view.Argument) !void {
    const arena = vows.beginSettle(self);
    defer vows.endSettle(self);
    const owned = try value.toOwned(arena);
    std.debug.assert(port.far_listeners.fetchSwapRemove(answer) != null);
    port.peer.session_state.consumeOutboundAnswerNotification(answer);
    listener.func(listener.ctx, .{ .fulfilled = owned });
}

/// The broken-arm sibling: remove-before-fire, reason borrowed for the
/// call.
fn fireBrokenFar(port: *Port, answer: engine.OutboundAnswerTarget, listener: Listener, reason: []const u8) void {
    std.debug.assert(port.far_listeners.fetchSwapRemove(answer) != null);
    port.peer.session_state.consumeOutboundAnswerNotification(answer);
    listener.func(listener.ctx, .{ .broken = reason });
}

/// The resolve arm of `serve`: fire the far vow's one-shot listener with
/// the settled outcome, a typed give projection when the fulfillment
/// carries a signed handoff give (`event` is here for exactly that: the
/// verbatim envelope span lives only in the event's frame), an owned clone
/// on the plain fulfilled path, or the break reason.
/// `answer` is the question `resolve` settles, by identity: the event's own
/// target or one of its aliases.
fn serveResolve(self: *Vat, port: *Port, resolve: model.view.Resolve, answer: engine.OutboundAnswerTarget) !bool {
    // Peek the listener rather than remove it: the fulfilled and give
    // arms do fallible allocation before firing, and an error return
    // must leave the entry in the map so teardown
    // (`freeOwnedForwardContexts`) or `breakFarVows` still reclaims
    // it, a `forwardListener` frees its heap `ForwardContext` only
    // when it fires. Each arm removes the entry immediately before it
    // fires, preserving the remove-before-fire order a listener that
    // registers a new far vow relies on.
    const listener = port.far_listeners.get(answer) orelse {
        port.peer.session_state.consumeOutboundAnswerNotification(answer);
        return false;
    };
    switch (resolve.resolution) {
        .fulfill => |value| {
            // A fulfillment carrying a handoff give fires typed:
            // the verbatim envelope span lives only in the event's
            // frame, so this is the one place it can be projected.
            // A give whose envelope or location does not project
            // falls through and fires as the plain argument.
            const handoff: ?model.view.Handoff = if (value == .handoff) try value.handoff.project() else null;
            if (handoff != null and handoff.? == .give) {
                var projected = try engine.handoff_recipient.projectGiveForRedeem(
                    self.allocator,
                    handoff.?.give,
                );
                defer projected.deinit(self.allocator);
                if (projected.bytes()) |give_bytes| {
                    if (projected.locator == .uri) {
                        const locator_uri = projected.locator.uri;
                        std.debug.assert(port.far_listeners.fetchSwapRemove(answer) != null);
                        port.peer.session_state.consumeOutboundAnswerNotification(answer);
                        listener.func(listener.ctx, .{ .give = .{
                            .give_bytes = give_bytes,
                            .exporter_locator_uri = locator_uri,
                            .recipient_key = handoff.?.give.recipient_key,
                        } });
                        return true;
                    }
                }
            }
            try fireFulfilledFar(self, port, answer, listener, value);
        },
        .@"break" => |reason| fireBrokenFar(port, answer, listener, reason.message),
    }
    return true;
}

/// Settle the far vow at `answer` with `resolution`, firing and removing its
/// one-shot listener. This is how an embedder that executes node serve-step
/// actions (`engine.Node.Action.settle` / `.fail`) delivers a settlement
/// that never crossed this vat's own wire, the byte-fed host's counterpart to
/// the resolve arm of `serve`, minus the wire event. The fulfilled value is
/// cloned into the settle arena for the listener call, under the same depth
/// guard as `serveResolve`'s fulfilled arm. A broken reason is borrowed for
/// the call. With no listener parked, the application notification is consumed
/// on the answer row, so a late `on` is refused `AlreadySettled`
/// instead of parking forever. The parameter admits no `.give`: the
/// executor that calls this exists to redeem gives before the vat sees
/// them, and the narrower type makes that contract unrepresentable rather
/// than a runtime trap an external caller could hit.
pub fn settleFar(self: *Vat, port: *Port, answer: engine.OutboundAnswerTarget, outcome: Outcome) Error!void {
    const listener = port.far_listeners.get(answer) orelse {
        port.peer.session_state.consumeOutboundAnswerNotification(answer);
        return;
    };
    switch (outcome) {
        .fulfilled => |*value| try fireFulfilledFar(self, port, answer, listener, .fromOwned(value)),
        .broken => |reason| fireBrokenFar(port, answer, listener, reason),
    }
}

/// Break outstanding far-vow listeners and those registered by their callbacks.
/// Each listener is removed immediately before invocation. Other pending
/// listeners remain cancellable, so their owners may retire them during a
/// callback. All answers minted before return become unobservable, including
/// sends without listeners. No notification allocation is needed.
///
/// A driver uses this on disconnect, or to break current requests without
/// closing the Peer. Fresh sends after return may still be observed. Local
/// turns stay live, and local vows forwarded to these far vows receive the
/// break through their continuations. `message` is borrowed for the calls.
pub fn breakFarVows(port: *Port, message: []const u8) void {
    // Keep pending listeners at their cancellation owner. Pop copies the
    // listener and removes its row before callbacks can resize or drain the
    // map. Each iteration also consumes all answers minted so far, preventing
    // a callback from observing an old vow again. Fresh sends remain usable.
    while (port.far_listeners.pop()) |entry| {
        port.far_broken_stamp = port.peer.session_state.store_stamp_counter;
        entry.value.func(entry.value.ctx, .{ .broken = message });
    }
    port.far_broken_stamp = port.peer.session_state.store_stamp_counter;
    port.far_listeners.deinit(port.allocator);
    port.far_listeners = .{};
}

pub fn resolveFulfill(port: *Port, answer: ?engine.AnswerTarget, reply: model.Argument) !void {
    return resolveFulfillView(port, answer, model.view.Argument.fromOwned(&reply));
}

fn resolveFulfillView(port: *Port, answer: ?engine.AnswerTarget, reply: model.view.Argument) !void {
    const ans = answer orelse return;
    try port.peer.sendAnswerTargetResolutionViewCopying(ans, model.view.Resolution{ .fulfill = reply });
}

pub fn resolveBreak(port: *Port, answer: ?engine.AnswerTarget, message: []const u8) !void {
    const ans = answer orelse return;
    try port.peer.sendAnswerTargetResolutionCopying(ans, .{ .@"break" = .{ .message = message } });
}

/// Split an inbound deliver's args into a method verb and its arguments: a
/// leading symbol is the verb, the rest are its arguments. This is the inverse of
/// what the local eventual-send payload does on the way out (it prepends the
/// verb as a leading symbol), so a glowcap actor talking to a glowcap actor
/// round-trips exactly.
///
/// It is a convention of this actor layer, not an OCapN rule: OCapN delivers a
/// positional argument list with no distinguished method slot. So a deliver from
/// a peer that does not follow the convention, a genuine Goblins object whose
/// first real argument is itself a symbol, or a call sent with no leading verb,
/// is read here as "the first symbol is the method." A vat hosting objects for a
/// non-glowcap peer must agree on this verb-as-leading-symbol convention, or
/// dispatch by inspecting the args directly rather than through this split.
fn deliveryFor(args: model.view.Args) model.view.ProjectError!Delivery {
    if ((try args.len()) > 0) {
        const first = try args.at(0);
        if (first == .symbol) return .{ .verb = first.symbol, .args = try args.from(1) };
    }
    return .{ .verb = "", .args = args };
}
