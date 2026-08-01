//! The vat's wire-hosting family: serving inbound events and settling far vows.
//!
//! `serve` dispatches one inbound peer event — a deliver to a bound export
//! runs the actor's turn through the shared frame spine and resolves the
//! answer; a resolve fires the far vow's one-shot listener, projecting a
//! handoff give typed. `settleFar` is the byte-fed host's spelling of the
//! same settle, `forwardTurn` drives `Turn.forward`, and export binding
//! (`bindExport`/`refForExport`) plus disconnect breaks (`breakFarVows`) live
//! beside them. The `Vat` re-binds the public verbs; the turn module runs the
//! same frame spine for local calls.

const std = @import("std");
const engine = @import("engine");
const model = @import("model");

const boxed = @import("boxed.zig");
const turn_mod = @import("turn.zig");
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

/// Heap context a forwarded turn's vow listener carries: the vat to resolve
/// against and the deferred inbound answer. Freed by the listener once it fires
/// (on settle, or on a disconnect break via `breakFarVows`).
pub const ForwardContext = struct { vat: *Vat, port: *Port, answer: model.AnswerPosition };

pub fn forwardListener(ctx: ?*anyopaque, resolution: Resolution) void {
    const fc: *ForwardContext = @ptrCast(@alignCast(ctx.?));
    defer fc.vat.allocator.destroy(fc);
    // Best-effort: a failed resolve strands the partner's answer until teardown
    // (the same class as a refused GC release), never a fault on this side.
    switch (resolution) {
        .fulfilled => |value| resolveFulfill(fc.port, fc.answer, value) catch {},
        .broken => |message| resolveBreak(fc.port, fc.answer, message) catch {},
        // A give is addressed to THIS vat's session key; a forwarded copy
        // could never be redeemed by the partner, so the honest relay is a
        // break naming why.
        .give => resolveBreak(fc.port, fc.answer, "introduction not forwardable") catch {},
    }
}

/// Drive `Turn.forward`: forward this turn's call to `target` and dispatch
/// on the turn's `origin` — the one place the provenance matters.
///
/// A `.local` frame's return value is consumed directly (the near-caller's
/// reply, or the queued vow's resolution), so it forwards by near-call and
/// returns the target's value, legal only for a local target, since `near`
/// refuses a far ref. A `.served` turn defers: with a wire answer it sends
/// and settles that answer on the forwarded promise; with none (a wire
/// `tell`) it forwards fire-and-forget. The placeholder return is ignored
/// by `serve` once `forwarded` is set.
pub fn forwardTurn(self: *Vat, turn: *Turn, target: Ref, msg: Message) anyerror!model.Argument {
    const maybe_answer = switch (turn.origin) {
        .local => return self.nearFromPort(turn.port, turn.ingress, target, msg),
        .served => |maybe_answer| maybe_answer,
    };
    const answer = maybe_answer orelse {
        try turn.port.?.tellFromIngress(self, turn.ingress, target, msg);
        turn.forwarded = true;
        return .{ .void = {} };
    };
    const vow = try turn.port.?.sendFromIngress(self, turn.ingress, target, msg);
    const fc = try self.allocator.create(ForwardContext);
    fc.* = .{ .vat = self, .port = turn.port.?, .answer = answer };
    // A fresh vow can only collide on OOM, never `AlreadyListening`.
    turn.port.?.on(self, vow, .{ .ctx = fc, .func = forwardListener }) catch |e| {
        self.allocator.destroy(fc);
        return e;
    };
    turn.forwarded = true;
    return .{ .void = {} };
}

/// Dispatch one inbound peer event: a deliver to a published actor runs its
/// turn and resolves the answer (`serveDeliver`); a resolve for a far vow
/// fires its listener (`serveResolve`). Returns whether the event belonged
/// to this vat; if it did not, the caller handles it. The application polls
/// the peer and hands events here.
pub fn serveFromIngress(self: *Vat, port: *Port, ingress: vat_mod.IngressId, event: *engine.Event) !bool {
    const body = event.view() catch return false;
    return switch (body) {
        .deliver => |deliver| serveDeliver(self, port, ingress, deliver),
        .resolve => |resolve| serveResolve(self, port, resolve),
        else => false,
    };
}

/// The deliver arm of `serve`: run the bound actor's turn against the
/// borrowed wire message and resolve (or break) the inbound answer,
/// consulting the resolve interceptor on the fulfilled path.
fn serveDeliver(self: *Vat, port: *Port, ingress: vat_mod.IngressId, deliver: model.view.Deliver) !bool {
    const export_position = deliver.target.exportPosition() orelse return false;
    // V1.0: a resolver-only deliver carries no wire answer but names a resolver
    // descriptor. The engine maps it to the virtual answer it installed, so the
    // resolve reaches the partner. The engine owns that mapping, so the vat never
    // decodes the descriptor. Without a peer (no wire), only an explicit wire
    // answer exists.
    const answer = port.peer.answerForDeliver(deliver);
    const local_id = port.exports.get(export_position.int()) orelse {
        // The bootstrap position is engine-owned: the peer
        // auto-answers its delivers (`fetch`, gift deposit /
        // withdraw) and only surfaces the event for observation,
        // so the vat must not race a break onto its answer.
        if (export_position.int() == engine.BOOTSTRAP_POSITION) return false;
        // The engine admitted the deliver, so the position IS a
        // granted export at peer level — but no actor is bound
        // (no `bindExport`). An answered call must
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
    // them — bump-and-reset instead of a per-event allocate/free walk
    // on the vat allocator. The handler contract is already
    // turn-scoped (module header), so nothing may retain them past
    // this window anyway; the reply (which may alias the args) stays
    // valid until the next outermost turn, exactly as documented.
    const args = try deliver.args.toOwnedSlice(arena);
    var turn = Turn{ .vat = self, .port = port, .self_ref = .{ .local = local_id }, .ingress = ingress, .arena = arena, .origin = .{ .served = answer } };
    if (box.handle(box.ptr, &turn, messageFor(args))) |value| {
        if (turn.pending_become) |pending| boxed.promoteBecome(self, pending);
        // A moved reply (`Turn.moveOut`) needs nothing here: the vat
        // already holds its bytes, and `resolveFulfill` copies the
        // reply onto the wire inside this turn, before the deferred
        // free. The wire copy is mandatory regardless, so the move
        // saves nothing on the serve path — it only avoids
        // `callLocal`'s sever-copy on the near path.
        // A forwarding actor handed its answer to another send's
        // vow; that vow resolves it, not this return.
        if (turn.forwarded) return true;
        // The interceptor runs inside the turn (`turn_depth >= 1`), so
        // any top-level turn it opens is nested and never resets the
        // arena `value` may live in — the value is turn-borrowed,
        // exactly like a handler's own reply.
        if (port.resolve_interceptor) |interceptor| {
            if (answer) |ans| {
                const outcome = interceptor.func(interceptor.ctx, ans, value) catch |err| {
                    try resolveBreak(port, answer, @errorName(err));
                    return true;
                };
                switch (outcome) {
                    // The interceptor resolved the answer itself
                    // (an originated give); the vat sends nothing.
                    .claimed => {},
                    // Resolve with what it returned — the original
                    // value, or a token rewritten to its wire
                    // reference.
                    .resolve => |reply| try resolveFulfill(port, answer, reply),
                }
                return true;
            }
        }
        try resolveFulfill(port, answer, value);
        return true;
    } else |err| {
        if (turn.pending_become) |pending| releaseBox(self.allocator, pending.box);
        try resolveBreak(port, answer, @errorName(err));
        return true;
    }
}

/// The no-listener drop shared by the two far-settle spines: remember the
/// answer (bounded) so a late `on` for this vow is refused
/// `AlreadySettled` instead of parking forever. A `put` failure or a full
/// set only forgoes that guard for this one answer, never a fault.
fn noteServedDrop(port: *Port, answer: model.AnswerPosition) void {
    if (port.served_dropped_far.count() < vat_mod.max_served_dropped_far_answers) {
        port.served_dropped_far.put(port.allocator, answer, {}) catch {};
    }
}

/// The fulfilled-arm settle spine shared by `serveResolve` and
/// `settleFar`, holding the choreography their prose used to promise
/// stayed in sync. The clone defends two hazards: a listener may open a
/// top-level turn (`near` or `drive`) whose depth-0 turn-arena reset
/// would free a turn-borrowed value mid-call, and the value may borrow
/// actor state a listener-run turn mutates or `become`-frees. Its home is
/// the settle arena; queue chunks own queued messages and are not listener
/// scratch. The depth guard keeps a re-entrant settle (a listener pumping
/// `serve` again) from resetting the arena under the outer value. Materialized
/// before the remove so an OOM leaves the
/// listener parked, not stranded. `value` is either a borrowed
/// `model.view.Argument` (the wire path) or an owned `model.Argument`
/// (the byte-fed host path); the clone verb is the only difference.
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
    std.debug.assert(port.far_listeners.fetchRemove(answer) != null);
    listener.func(listener.ctx, .{ .fulfilled = owned });
}

/// The broken-arm sibling: remove-before-fire, reason borrowed for the
/// call.
fn fireBrokenFar(port: *Port, answer: model.AnswerPosition, listener: Listener, reason: []const u8) void {
    std.debug.assert(port.far_listeners.fetchRemove(answer) != null);
    listener.func(listener.ctx, .{ .broken = reason });
}

/// The resolve arm of `serve`: fire the far vow's one-shot listener with
/// the settled outcome — a typed give projection when the fulfillment
/// carries a signed handoff give (`event` is here for exactly that: the
/// verbatim envelope span lives only in the event's frame), an owned clone
/// on the plain fulfilled path, or the break reason.
fn serveResolve(self: *Vat, port: *Port, resolve: model.view.Resolve) !bool {
    // Peek the listener rather than remove it: the fulfilled and give
    // arms do fallible allocation before firing, and an error return
    // must leave the entry in the map so teardown
    // (`freeOwnedForwardContexts`) or `breakFarVows` still reclaims
    // it — a `forwardListener` frees its heap `ForwardContext` only
    // when it fires. Each arm removes the entry immediately before it
    // fires, preserving the remove-before-fire order a listener that
    // registers a new far vow relies on.
    const listener = port.far_listeners.get(resolve.answer) orelse {
        noteServedDrop(port, resolve.answer);
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
                        std.debug.assert(port.far_listeners.fetchRemove(resolve.answer) != null);
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
/// that never crossed this vat's own wire — the byte-fed host's spelling of
/// the resolve arm of `serve`, minus the wire event. The fulfilled value is
/// cloned into the settle arena for the listener call, under the same depth
/// guard as `serveResolve`'s fulfilled arm; a broken reason is borrowed for
/// the call. With no listener parked, the answer is recorded into
/// `served_dropped_far` (bounded), the same contract as a wire resolve
/// served with no listener, so a late `on` is refused `AlreadySettled`
/// instead of parking forever. The parameter admits no `.give`: the
/// executor that calls this exists to redeem gives before the vat sees
/// them, and the narrower type makes that contract unrepresentable rather
/// than a runtime trap an external caller could hit.
pub fn settleFar(self: *Vat, port: *Port, answer: model.AnswerPosition, outcome: FarOutcome) Error!void {
    const listener = port.far_listeners.get(answer) orelse return noteServedDrop(port, answer);
    switch (outcome) {
        .fulfilled => |value| try fireFulfilledFar(self, port, answer, listener, value),
        .broken => |reason| fireBrokenFar(port, answer, listener, reason),
    }
}

/// Break every outstanding far vow with `message`, firing each
/// listener's break path synchronously, before this returns, a
/// stack-bound listener context is safe because nothing fires later. A far vow settles only when the partner's resolution
/// arrives over the wire, so once the connection is gone those resolutions can
/// never come. A driver calls this on disconnect, so an awaiting `on`
/// listener settles broken instead of waiting forever. `message` is borrowed
/// for the duration of the calls, so a static string is the norm. Local
/// vows are untouched: they settle synchronously in `drive` and never
/// wait on the wire.
pub fn breakFarVows(port: *Port, message: []const u8) void {
    // Swap the whole map out before any fire: a listener may react by
    // registering another far vow, which lands in the fresh (live)
    // map and can never invalidate the drained iterator — the same
    // remove-before-fire strength as removing entries one at a time,
    // without the O(n × capacity) fresh key scan per entry. The outer
    // while re-checks, so vows registered during the break also fire
    // broken: once the connection is gone, no resolution can ever come.
    while (port.far_listeners.count() > 0) {
        var taken = port.far_listeners;
        port.far_listeners = .{};
        defer taken.deinit(port.allocator);
        var it = taken.valueIterator();
        while (it.next()) |listener| {
            listener.func(listener.ctx, .{ .broken = message });
        }
    }
}

/// Bind an already-spawned local actor to export `position` so a partner's
/// deliveries to that position run the actor (dispatched by `serve`). Requires
/// a bound peer. This is the numeric-position primitive; the by-name publish
/// verb one layer up (`Served.publish`, `BlockingSession.publish`) rides on
/// it. Binding *reserves* the position, it does not grant it: the partner
/// can address the actor only once its reference first marshals onto the
/// wire, or after an explicit `peer.exportObject` grant (ADR-0074). Only a
/// local actor can be bound — a far ref already lives elsewhere — so a far
/// ref returns `NotLocal`.
pub fn bindExport(port: *Port, actor: Ref, position: u64) !void {
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
    if (!port.reverse_exports.contains(local_id))
        port.reverse_exports.putAssumeCapacity(local_id, position);
}

/// The local `Ref` bound to wire export `position`, or null when no actor is
/// exported there, the inverse of `bindExport`'s position-to-actor map. A
/// surface that receives a near reference (which names an object by its wire
/// export position, not its vat-local actor id) resolves it through here so a
/// position is never mistaken for an actor id; `Vat.serve` resolves an inbound
/// deliver's target the same way.
pub fn refForExport(port: *const Port, position: u64) ?Ref {
    const local_id = port.exports.get(position) orelse return null;
    return .{ .local = local_id };
}

pub fn resolveFulfill(port: *Port, answer: ?model.AnswerPosition, reply: model.Argument) !void {
    const ans = answer orelse return;
    try port.peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .fulfill = reply } } });
}

pub fn resolveBreak(port: *Port, answer: ?model.AnswerPosition, message: []const u8) !void {
    const ans = answer orelse return;
    try port.peer.sendCopying(.{ .resolve = .{ .answer = ans, .resolution = .{ .@"break" = .{ .message = message } } } });
}

/// Split an inbound deliver's args into a method verb and its arguments: a
/// leading symbol is the verb, the rest are its arguments. This is the inverse of
/// what `Vat.send` does on the way out (it prepends the verb as a leading
/// symbol), so a pancake actor talking to a pancake actor round-trips exactly.
///
/// It is a convention of this actor layer, not an OCapN rule: OCapN delivers a
/// positional argument list with no distinguished method slot. So a deliver from
/// a peer that does not follow the convention — a genuine Goblins object whose
/// first real argument is itself a symbol, or a call sent with no leading verb —
/// is read here as "the first symbol is the method." A vat hosting objects for a
/// non-pancake peer must agree on this verb-as-leading-symbol convention, or
/// dispatch by inspecting the args directly rather than through this split.
fn messageFor(args: []const model.Argument) Message {
    if (args.len > 0 and args[0] == .symbol) {
        return .{ .verb = args[0].symbol, .args = args[1..] };
    }
    return .{ .verb = "", .args = args };
}
