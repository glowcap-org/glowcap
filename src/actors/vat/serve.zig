//! The vat's wire-hosting family: serving inbound events and settling far vows.
//!
//! `serve` dispatches one inbound peer event, a deliver to a bound export
//! runs the actor's turn through the shared frame spine and resolves the
//! answer. A resolve fires the far vow's one-shot listener, projecting a
//! handoff give typed. `settleFar` is the byte-fed host's counterpart to the
//! same settle, `forwardTurn` drives `Turn.forward`, and export binding
//! (`Port.bindExport`/`refForExport`) plus disconnect breaks (`breakFarVows`) live
//! beside them. `Port` re-binds the session public verbs. The turn module runs the
//! same frame spine for local calls.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");

const boxed = @import("boxed.zig");
const turn_mod = @import("turn.zig");
const turn_commit = @import("turn_commit.zig");
const vat_mod = @import("mod.zig");

const Error = vat_mod.Error;
const FarOutcome = vat_mod.FarOutcome;
const Listener = vat_mod.Listener;
const Message = vat_mod.Message;
const Ref = vat_mod.Ref;
const Resolution = vat_mod.Resolution;
const Turn = vat_mod.Turn;
const Vat = vat_mod.Vat;
const Port = vat_mod.Port;
const releaseBox = boxed.releaseBox;

/// Dispatch one inbound peer event: a deliver to a published actor runs its
/// turn and resolves the answer (`serveDeliver`). A resolve for a far vow
/// fires its listener (`serveResolve`). Returns whether the event belonged
/// to this vat. If it did not, the caller handles it. The application polls
/// the peer and hands events here.
pub fn serveFromIngress(self: *Vat, port: *Port, ingress: vat_mod.IngressId, event: *engine.Event) !bool {
    const body = event.view() catch return false;
    return switch (body) {
        .deliver => |deliver| serveDeliver(self, port, ingress, deliver, event.deliverAnswerTarget()),
        .resolve => |resolve| blk: {
            var handled = try serveResolve(self, port, resolve);
            for (event.resolveAliases()) |answer| {
                var alias = resolve;
                alias.answer = answer;
                handled = (try serveResolve(self, port, alias)) or handled;
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
    ingress: vat_mod.IngressId,
    deliver: model.view.Deliver,
    answer: ?engine.AnswerTarget,
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
        if (export_position.int() == engine.BOOTSTRAP_POSITION) return false;
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
    const frame = turn_mod.openTurnFrame(self, local_id) catch |err| switch (err) {
        Error.NearCallTooDeep, Error.NoSuchActor => {
            try resolveBreak(port, answer, @errorName(err));
            return true;
        },
        else => |other| return other,
    };
    const box = frame.box;
    const arena = frame.arena;
    // The reply and the interceptor both read `value` while
    // `running >= 1`, so the box `value` may alias is never freed
    // before the fulfill is sent.
    defer turn_mod.closeTurnFrame(self, local_id);
    // Materialize the borrowed wire args *inside* the turn window:
    // `beginTurn`'s depth-0 reset has already run, so the args land
    // in the turn arena and the next outermost turn's reset reclaims
    // them, bump-and-reset instead of a per-event allocate/free walk
    // on the vat allocator. The handler contract is already
    // turn-scoped (module header), so nothing may retain them past
    // this window anyway; the reply (which may alias the args) stays
    // valid until the next outermost turn, exactly as documented.
    const args = try deliver.args.toOwnedSlice(arena);
    var turn = Turn{ .vat = self, .port = port, .self_ref = .{ .local = local_id }, .ingress = ingress, .arena = arena, .origin = .{ .served = answer } };
    switch (box.handle(box.ptr, &turn, messageFor(args))) {
        .returned => |value| {
            if (turn.pending_become) |pending| boxed.promoteBecome(self, pending);
            // The turn's local sends are queued before its reply (ADR-0191).
            // Promotion may run a discarded state's destructor and stage sends.
            if (self.turn_depth == 1) turn_commit.commit(self);
            // A moved reply (`Turn.moveOut`) needs nothing here: the vat
            // already holds its bytes, and `resolveFulfill` copies the
            // reply onto the wire inside this turn, before the deferred
            // free. The wire copy is mandatory regardless, so the move
            // saves nothing on the serve path. It only avoids
            // `callLocal`'s sever-copy on the near path.
            // A forwarding actor handed its answer to another send's
            // vow; that vow resolves it, not this return.
            if (turn.forwarded) return true;
            // The interceptor runs inside the turn (`turn_depth >= 1`), so
            // any top-level turn it opens is nested and never resets the
            // arena `value` may live in, the value is turn-borrowed,
            // exactly like a handler's own reply.
            if (port.resolve_interceptor) |interceptor| {
                if (answer) |ans| {
                    const intercepted = interceptor.func(interceptor.ctx, ans, value);
                    // The handler already committed. Finish nested callback
                    // effects before handling either its result or refusal.
                    if (self.turn_depth == 1) turn_commit.commit(self);
                    const outcome = intercepted catch |err| {
                        try resolveBreak(port, answer, @errorName(err));
                        return true;
                    };
                    switch (outcome) {
                        // The interceptor resolved the answer itself
                        // (an originated give); the vat sends nothing.
                        .claimed => {},
                        // Resolve with what it returned, the original
                        // value, or a token rewritten to its wire
                        // reference.
                        .resolve => |reply| try resolveFulfill(port, answer, reply),
                    }
                    return true;
                }
            }
            try resolveFulfill(port, answer, value);
            return true;
        },
        .refused => |failure| {
            if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
            if (self.turn_depth == 1) self.turn_failure = failure.name;
            // Forwarding or an explicit break already owns this answer.
            if (turn.forwarded) return true;
            try resolveBreak(port, answer, failure.name);
            return true;
        },
    }
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
/// producer, so `settleLocal` breaks its waiter instead. `value` is either a borrowed
/// `model.view.Argument` (the wire path) or an owned `model.Argument`
/// (the byte-fed host path). The clone verb is the only difference.
fn fireFulfilledFar(self: *Vat, port: *Port, answer: model.AnswerPosition, listener: Listener, value: anytype) !void {
    self.settle_depth += 1;
    defer {
        self.settle_depth -= 1;
        if (self.settle_depth == 0) _ = self.settle_arena.reset(.{ .retain_with_limit = vat_mod.steady_settle_arena_bytes });
    }
    const arena = self.settle_arena.allocator();
    const owned = if (@TypeOf(value) == model.Argument)
        try model.cloneArgument(arena, value)
    else
        try value.toOwned(arena);
    std.debug.assert(port.far_listeners.fetchSwapRemove(answer) != null);
    port.peer.session_state.consumeOutboundAnswerNotification(answer);
    listener.func(listener.ctx, .{ .fulfilled = owned });
}

/// The broken-arm sibling: remove-before-fire, reason borrowed for the
/// call.
fn fireBrokenFar(port: *Port, answer: model.AnswerPosition, listener: Listener, reason: []const u8) void {
    std.debug.assert(port.far_listeners.fetchSwapRemove(answer) != null);
    port.peer.session_state.consumeOutboundAnswerNotification(answer);
    listener.func(listener.ctx, .{ .broken = reason });
}

/// The resolve arm of `serve`: fire the far vow's one-shot listener with
/// the settled outcome, a typed give projection when the fulfillment
/// carries a signed handoff give (`event` is here for exactly that: the
/// verbatim envelope span lives only in the event's frame), an owned clone
/// on the plain fulfilled path, or the break reason.
fn serveResolve(self: *Vat, port: *Port, resolve: model.view.Resolve) !bool {
    // Peek the listener rather than remove it: the fulfilled and give
    // arms do fallible allocation before firing, and an error return
    // must leave the entry in the map so teardown
    // (`freeOwnedForwardContexts`) or `breakFarVows` still reclaims
    // it, a `forwardListener` frees its heap `ForwardContext` only
    // when it fires. Each arm removes the entry immediately before it
    // fires, preserving the remove-before-fire order a listener that
    // registers a new far vow relies on.
    const listener = port.far_listeners.get(resolve.answer) orelse {
        port.peer.session_state.consumeOutboundAnswerNotification(resolve.answer);
        return false;
    };
    switch (resolve.resolution) {
        .fulfill => |value| {
            // A fulfillment carrying a handoff give fires typed:
            // the verbatim envelope span lives only in the event's
            // frame, so this is the one place it can be projected.
            // A give whose envelope or location does not project
            // falls through and fires as the plain argument.
            if (value == .handoff and value.handoff == .give) {
                var projected = try engine.handoff_recipient.projectGiveForRedeem(
                    self.allocator,
                    value.handoff.give,
                );
                defer projected.deinit(self.allocator);
                if (projected.bytes()) |give_bytes| {
                    if (projected.locator == .uri) {
                        const locator_uri = projected.locator.uri;
                        std.debug.assert(port.far_listeners.fetchSwapRemove(resolve.answer) != null);
                        port.peer.session_state.consumeOutboundAnswerNotification(resolve.answer);
                        listener.func(listener.ctx, .{ .give = .{
                            .give_bytes = give_bytes,
                            .exporter_locator_uri = locator_uri,
                            .recipient_key = value.handoff.give.recipient_key,
                        } });
                        return true;
                    }
                }
            }
            try fireFulfilledFar(self, port, resolve.answer, listener, value);
        },
        .@"break" => |reason| fireBrokenFar(port, resolve.answer, listener, reason.message),
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
pub fn settleFar(self: *Vat, port: *Port, answer: model.AnswerPosition, outcome: FarOutcome) Error!void {
    const listener = port.far_listeners.get(answer) orelse {
        port.peer.session_state.consumeOutboundAnswerNotification(answer);
        return;
    };
    switch (outcome) {
        .fulfilled => |value| try fireFulfilledFar(self, port, answer, listener, value),
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
        port.far_broken_before = port.peer.session_state.next_outbound_answer;
        entry.value.func(entry.value.ctx, .{ .broken = message });
    }
    port.far_broken_before = port.peer.session_state.next_outbound_answer;
    port.far_listeners.deinit(port.allocator);
    port.far_listeners = .{};
}

/// Bind an already-spawned local actor to export `position` so a partner's
/// deliveries to that position run the actor (dispatched by `serve`). Requires
/// a session `Port`. This is the numeric-position primitive. The by-name publish
/// verb one layer up (`Served.publish`, `driver.Session.publish`) rides on
/// it. Binding *reserves* the position, it does not grant it: the partner
/// can address the actor only once its reference first marshals onto the
/// wire, or after an explicit `peer.exportObject` grant (ADR-0074). Only a
/// local actor can be bound, a far ref already lives elsewhere, so a far
/// ref returns `NotLocal`.
pub fn bindExport(port: *Port, vat: *Vat, actor: Ref, position: u64) !void {
    const local_id = switch (actor) {
        .local => |a| a,
        .far => return Error.NotLocal,
    };
    const peer = port.peer;
    // Reject a collision before touching the peer: the export to actor map is
    // authority (it decides which local object a partner reaches), so a second
    // bind to the same position fails loud rather than orphaning the first.
    try port.reverse_exports.ensureUnusedCapacity(port.allocator, 1);
    const gop = try port.exports.getOrPut(port.allocator, position);
    if (gop.found_existing) return Error.AlreadyPublished;
    // getOrPut inserted the key with an undefined value; if registering the
    // export fails, drop the half-inserted entry so the map never holds a
    // position the peer doesn't actually export.
    errdefer std.debug.assert(port.exports.remove(position));
    try peer.reserveExport(position);
    gop.value_ptr.* = local_id;
    if (!port.reverse_exports.contains(local_id)) {
        port.reverse_exports.putAssumeCapacity(local_id, position);
        // The actor's first binding on this Port is a rooting relationship
        // (ADR-0101), released by rollback of the last binding or Port
        // teardown.
        vat.retainActor(local_id);
    }
}

/// The local `Ref` bound to wire export `position`, or null when no actor is
/// exported there, the inverse of `Port.bindExport`'s position-to-actor map. A
/// surface that receives a near reference (which names an object by its wire
/// export position, not its vat-local actor id) resolves it through here so a
/// position is never mistaken for an actor id. `Vat.serve` resolves an inbound
/// deliver's target the same way.
pub fn refForExport(port: *const Port, position: u64) ?Ref {
    const local_id = port.exports.get(position) orelse return null;
    return .{ .local = local_id };
}

pub fn resolveFulfill(port: *Port, answer: ?engine.AnswerTarget, reply: model.Argument) !void {
    const ans = answer orelse return;
    try port.peer.sendAnswerTargetResolutionCopying(ans, .{ .fulfill = reply });
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
fn messageFor(args: []const model.Argument) Message {
    if (args.len > 0 and args[0] == .symbol) {
        return .{ .verb = args[0].symbol, .args = args[1..] };
    }
    return .{ .verb = "", .args = args };
}
