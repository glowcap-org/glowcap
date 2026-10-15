//! The stateful drain of the resolve seam (ADR-0007, ADR-0050): the `*Peer` half.
//!
//! These functions take a `*Peer` and perform the side effects the pure
//! resolution math computes: they install listeners, queue and drain pipelined
//! calls, anchor and settle projections, and fire listeners when the local
//! resolve seam settles an answer. The engine spine calls into them from
//! `Peer.step`'s settlement tail and from inbound dispatch. Like the rest of
//! the engine they are sync and no-I/O.
//!
//! The pure half, what falls out of a settled answer, with no `Peer` in sight,
//! lives in `pipeline_resolution.zig`. This file re-exports its surface so
//! `engine.pipeline.<name>` still names the whole resolve seam.
//!
//! On ownership: anything that produces an owned message takes ownership of what
//! you pass in (the queued call) and moves its heap into the result. It moves,
//! it doesn't copy. A listener fire owns nothing at all: the drain queues a POD
//! carrier and `Peer.step` borrows the stored resolution back to encode it.

const std = @import("std");

const codec = @import("codec");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const events = @import("events.zig");
const Peer = engine.Peer;

const freeMessage = model.freeMessage;

// The pure resolution math lives in `pipeline_resolution.zig`. Re-exported here
// so `engine.pipeline.<name>` names the whole resolve seam and the stateful
// drain below can call the pure half by its bare name.
const resolution_math = @import("pipeline_resolution.zig");
const listener_drain = @import("pipeline_listeners.zig");
const resolution_chain = @import("resolution_chain.zig");

pub const rewriteDeliverTarget = resolution_math.rewriteDeliverTarget;
pub const borrowedListenerFire = resolution_math.borrowedListenerFire;
pub const ListenerDrainAction = resolution_math.ListenerDrainAction;
pub const classifyListenerDrain = resolution_math.classifyListenerDrain;
const projectResolution = resolution_math.projectResolution;
pub const maybeInstallInboundListener = listener_drain.maybeInstallInboundListener;
pub const prepareAnswerListenerDrain = listener_drain.prepareAnswerListenerDrain;
pub const fireImportedPromiseListeners = listener_drain.fireImportedPromiseListeners;
pub const PreparedListenerDrain = listener_drain.PreparedListenerDrain;
pub const prepareImportedPromiseFires = listener_drain.prepareImportedPromiseFires;

/// The answer authority behind an inbound promise target. A wire
/// `desc:answer` names the answer directly. A wire `desc:export` naming one of
/// our local promise exports decodes as `.near`. The session's explicit
/// export-to-answer link gives both forms one queue and settlement authority.
/// An object export with the same integer remains an object because the export
/// slot kind wins before the promise link is consulted.
fn pipelinedAnswer(peer: *Peer, target: anytype) ?model.AnswerName {
    return switch (target) {
        .promise => |promise| if (peer.session_state.hasInboundAnswer(promise.answer_position))
            model.AnswerName.fromWire(promise.answer_position)
        else
            null,
        .near => |near| blk: {
            const export_slot = peer.session_state.exportSlot(near.export_position) orelse break :blk null;
            if (export_slot != .local_unresolved) break :blk null;
            break :blk peer.session_state.answerForLocalPromiseExport(near.export_position);
        },
        else => null,
    };
}

/// A validated pipelined deliver with its owned message and, for a pending
/// source answer, its exact queue seat prepared. No answer/import/resolver
/// authority has moved while this value is live.
pub const PreparedPipelinedCall = struct {
    action: union(enum) {
        queue: session.PreparedPipelinedCallQueue,
        dispatch: resolution_chain.Outcome,
    },
    message: ?model.Message,

    pub fn abandon(self: *PreparedPipelinedCall, peer: *Peer) void {
        switch (self.action) {
            .queue => |*prepared| prepared.abandon(&peer.session_state),
            .dispatch => {},
        }
        if (self.message) |message| {
            freeMessage(peer.allocator, message);
            self.message = null;
        }
    }

    pub fn commit(self: *PreparedPipelinedCall, peer: *Peer) !void {
        // `preparePipelinedCall` set `message` in the same prepare/commit
        // pair. The unset state is a caller bug, not a peer-reachable one.
        const message = self.message orelse unreachable;
        self.message = null;
        switch (self.action) {
            .queue => |*prepared| prepared.commit(message),
            .dispatch => |outcome| {
                peer.local_delivery_depth = 0;
                try dispatchDrainedCall(peer, message, outcome);
            },
        }
    }
};

/// Handle an inbound `op:deliver` that pipelines against an answer we owe,
/// returning whether it was handled. A non-promise target or an unknown answer
/// returns `false` (the caller surfaces it normally). Every known answer is
/// handled here and returns `true`.
///
/// A still-pending answer queues the owned call until we resolve it. An
/// enqueue refusal (e.g. the queue cap) propagates and the session frees the
/// call. A settled answer dispatches the call right now, through the same
/// `dispatchDrainedCall` path a queued call takes on drain, against its kept
/// resolution, the case a live Goblins enliven-and-call in one breath hits,
/// when bootstrap lookup resolves before the pipelined frame is processed.
/// A deferred bootstrap lookup uses the same pending-answer queue. The settled-vs-pending split is the
/// stored resolution itself (the `applySentResolve` invariant: a settled inbound
/// answer always holds its resolution), not the status flag, so a call arriving while
/// the answer's own resolve is queued-but-unemitted is dispatched against the
/// real value rather than mistaken for an unresolved or broken target.
///
/// The inbound classifier validates the complete borrowed deliver before this
/// function is called. This function may therefore retain or redirect it
/// without repeating the argument walk.
pub fn preparePipelinedCall(
    peer: *Peer,
    deliver: model.view.Deliver,
) !?PreparedPipelinedCall {
    const answer = pipelinedAnswer(peer, deliver.target) orelse return null;
    const owned = try (model.view.Body{ .deliver = deliver }).toOwned(peer.allocator);
    errdefer freeMessage(peer.allocator, owned);

    // The stored resolution is the settled/pending decision (the
    // `applySentResolve` invariant: a settled inbound answer always holds its
    // resolution). Peeking
    // rather than reading the status flag is what keeps a call that arrives
    // while the answer's own resolve is still a queued outbound message from
    // being misrouted; it sees the real value and dispatches against it.
    // Presence is certain because `pipelinedAnswer` above gated this name
    // through `hasInboundAnswer` in the same dispatch.
    const target = peer.session_state.answerTargetNamed(answer) orelse unreachable;
    if (peer.session_state.answerPayloadForTarget(target)) |payload| {
        if (peer.session_state.answerPayloadStoredResolution(payload) != null)
            return .{
                .action = .{ .dispatch = resolution_chain.followAnswer(peer, target, payload) },
                .message = owned,
            };
    }
    return .{
        .action = .{ .queue = try peer.session_state.preparePipelinedCallNamed(answer) },
        .message = owned,
    };
}

/// Drain calls the partner pipelined against a just-settled answer, dispatching
/// each against the resolution (ADR-0007 § Queue ownership and drain).
/// `desc:answer` carries one answer position, so every queued target is flat.
/// Drain the local consequences of settlement: pipelined calls,
/// anchored projections, then listeners, in that order (ADR-0007 § Queue
/// ownership and drain, ADR-0050 for projections).
pub fn drainAnswerConsequencesTarget(
    peer: *Peer,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    consequence: ?resolution_chain.Outcome,
    prepared_listeners: *PreparedListenerDrain,
) !void {
    std.debug.assert(peer.session_state.answerPayloadForTarget(target) == payload);
    try drainPipelinedCalls(peer, payload, consequence);
    try drainProjections(peer, payload, consequence);
    prepared_listeners.commit(peer);
}

fn drainPipelinedCalls(
    peer: *Peer,
    payload: *session.AnswerPayload,
    consequence: ?resolution_chain.Outcome,
) !void {
    // `local_delivery_depth` bounds the local deliveries *one* resolution's
    // drain produces (a drained call resolving to a local export). The drain
    // fans out only across the calls queued on this answer, it never
    // synchronously re-enters, since each local delivery surfaces an event the
    // application resolves on a later turn. So the bound is per-resolution and
    // resets here; left as a peer-lifetime counter it would wedge a long-lived
    // peer after `max_local_deliveries` legitimate deliveries across the whole
    // connection. The cross-turn chain is application-paced, not unbounded
    // auto-recursion, and the shared resolution walk breaks promise cycles.
    peer.local_delivery_depth = 0;
    const calls = try peer.session_state.takeAnswerPayloadCalls(payload);
    defer peer.allocator.free(calls);

    var index: usize = 0;
    errdefer for (calls[index..]) |queued| freeMessage(peer.allocator, queued);

    while (index < calls.len) {
        const queued = calls[index];
        index += 1;
        // `stepPending` computed `consequence` non-null exactly when this
        // payload had queued work (its `has_consequences` conditional), so
        // the drain cannot see both.
        try dispatchDrainedCall(peer, queued, consequence orelse unreachable);
    }
}

/// Answer an inbound `op:get` / `op:index` (ADR-0050, CapTP § op:get
/// "Receiving"): the projected answer is already installed by apply.
/// Anchor the projection on the receiver's answer. The receiver names a
/// promise, a `desc:answer` (`.promise`) or an export position that is an
/// inbound answer (`.near`, the same flip `installAnswerListener`
/// handles). Any other receiver can never settle to a value here, so the
/// projected answer breaks immediately.
pub fn respondToProjection(
    peer: *Peer,
    receiver: anytype,
    kind: session.ProjectionKind,
    new_answer: model.AnswerPosition,
) !void {
    // The projected answer's row is live here: apply installed it just above,
    // and validation refused a position already in use. Capturing its stamp
    // now is what lets the settle below tell this question from a later one
    // wearing the same number. A zero stamp cannot match a live row, so if
    // that invariant ever broke the projection would go quiet rather than
    // answer somebody else's question.
    const answer_row_id = peer.session_state.inboundAnswerRowId(new_answer) orelse 0;
    std.debug.assert(answer_row_id != 0);
    const projection: session.Projection = .{
        .kind = switch (kind) {
            .field => |field| .{ .field = try peer.allocator.dupe(u8, field) },
            .index => |index| .{ .index = index },
            .untag => |tag| .{ .untag = try peer.allocator.dupe(u8, tag) },
        },
        .answer = new_answer,
        .answer_row_id = answer_row_id,
    };
    // A local promise projection has one explicit export→answer link. Export
    // and answer positions are independent namespaces; numeric coincidence is
    // never authority to pipeline against an answer.
    const source: ?model.AnswerName = switch (receiver) {
        .promise => |promise| .fromWire(promise.answer_position),
        .near => |near| peer.session_state.answerForLocalPromiseExport(near.export_position),
        else => null,
    };
    if (source) |answer| {
        try anchorProjection(peer, answer, projection);
    } else {
        try breakProjection(peer, projection, "projection receiver is not a promise");
    }
}

/// Drain the `op:get` / `op:index` projections anchored on the answer just
/// settled (ADR-0050): each one resolves its
/// projected answer to the named field or element, re-anchors when the
/// resolution is itself a promise, or breaks. This never grows the native
/// stack: the shared stored-resolution walker returns one terminal value,
/// pending exact incarnation, or break before this batch is touched.
fn drainProjections(
    peer: *Peer,
    payload: *session.AnswerPayload,
    consequence: ?resolution_chain.Outcome,
) !void {
    const projections = try peer.session_state.takeAnswerPayloadProjections(payload);
    if (projections.len == 0) return;
    defer peer.allocator.free(projections);
    var index: usize = 0;
    errdefer for (projections[index..]) |p| session.deinitProjection(peer.allocator, p);

    while (index < projections.len) {
        const projection = projections[index];
        index += 1;
        // `stepPending` computed `consequence` non-null exactly when this
        // payload had queued work (its `has_consequences` conditional), so
        // the drain cannot see both.
        try applyProjectionOutcome(peer, projection, consequence orelse unreachable);
    }
}

/// Take ownership of `projection` and anchor it on inbound answer
/// `source`: install on its exact pending incarnation, compute from the shared
/// stored-resolution walk, or break when that walk cannot preserve identity.
fn anchorProjection(peer: *Peer, source: model.AnswerName, projection: session.Projection) !void {
    const target = peer.session_state.answerTargetNamed(source) orelse
        return breakProjection(peer, projection, "projection receiver names an unknown answer");
    if (peer.session_state.answerPayloadForTarget(target)) |payload| {
        if (peer.session_state.answerPayloadStoredResolution(payload) != null)
            return applyProjectionOutcome(
                peer,
                projection,
                resolution_chain.followAnswer(peer, target, payload),
            );
    }
    return peer.session_state.installProjectionTarget(target, projection);
}

fn applyProjectionOutcome(
    peer: *Peer,
    projection: session.Projection,
    consequence: resolution_chain.Outcome,
) !void {
    switch (consequence) {
        .pending => |target| try peer.session_state.installProjectionTarget(target, projection),
        .terminal_break => |message| try breakProjection(peer, projection, message),
        .terminal => |terminal| switch (projectResolution(terminal.resolution, projection.kind)) {
            .resolved => |projected| try resolveProjection(peer, projection, projected),
            .reanchor => try breakProjection(
                peer,
                projection,
                resolution_chain.missing_target_message,
            ),
        },
    }
}

/// Settle one projection (taking ownership): send the projected resolve for
/// its answer through the full resolve seam, so chained projections,
/// pipelined calls, and listeners on the projected answer all drain. The
/// projected payload borrows its source resolution, which the settlement
/// clones into the answer store (the named boundary copy). A projected answer the application already
/// settled is left as it is.
fn resolveProjection(peer: *Peer, projection: session.Projection, projected: model.Resolution) !void {
    try settleProjection(peer, projection, projected);
}

fn projectionTarget(peer: *Peer, projection: session.Projection) ?session.AnswerTarget {
    const target: session.AnswerTarget = .{
        .name = .fromWire(projection.answer),
        .row_id = projection.answer_row_id,
    };
    if (peer.session_state.inboundAnswerRowId(projection.answer)) |row_id| {
        if (row_id == target.row_id) return target;
    }
    if (peer.session_state.answerPayloadForTarget(target) != null) return target;
    return null;
}

/// Break one projection's answer (taking ownership of the projection) with
/// a static reason.
fn breakProjection(peer: *Peer, projection: session.Projection, reason: []const u8) !void {
    return settleProjection(peer, projection, .{ .@"break" = .{ .message = reason } });
}

/// Settle the exact question a projection created. A released answer with no
/// accepted dependents disappears and needs no reply. If dependents were
/// already accepted, its detached row remains the settlement target: they
/// drain without confusing a later question that reused the wire position.
fn settleProjection(peer: *Peer, projection: session.Projection, resolution: model.Resolution) !void {
    defer session.deinitProjection(peer.allocator, projection);
    const target = projectionTarget(peer, projection) orelse return;
    if (peer.session_state.answerPayloadForTarget(target)) |payload| {
        if (peer.session_state.answerPayloadResolution(payload) != null) return;
    }
    try peer.sendAnswerTargetResolutionCopying(target, resolution);
}

/// Dispatch one owned call against the shared exact-incarnation chain result.
fn dispatchDrainedCall(
    peer: *Peer,
    queued: model.Message,
    consequence: resolution_chain.Outcome,
) !void {
    switch (consequence) {
        .pending => |target| return peer.session_state.enqueuePipelinedCallTarget(target, queued),
        .terminal_break => |message| return propagateBreakToDrainedCall(
            peer,
            queued,
            .{ .@"break" = .{ .message = message } },
        ),
        .terminal => |terminal| return dispatchTerminalCall(peer, queued, terminal.resolution),
    }
}

fn dispatchTerminalCall(peer: *Peer, queued: model.Message, resolution: model.Resolution) !void {
    const maybe_reference: ?model.Reference = switch (resolution) {
        .fulfill => |arg| if (arg == .reference) arg.reference else null,
        .@"break" => null,
    };
    const reference = maybe_reference orelse
        return propagateBreakToDrainedCall(peer, queued, resolution);
    switch (reference) {
        .far => |far| try peer.send(rewriteDeliverTarget(peer.allocator, queued.deliver, .{ .far = far })),
        .near => |near| try deliverDrainedCallLocally(peer, queued, near),
        .promise => try propagateBreakToDrainedCall(
            peer,
            queued,
            .{ .@"break" = .{ .message = resolution_chain.missing_target_message } },
        ),
        .routed, .sturdy, .broken => freeMessage(peer.allocator, queued),
    }
}

/// Settle a drained call whose resolution carried no reference target (a break
/// or a non-reference fulfill), taking ownership of `queued`: propagate the
/// break so the partner isn't left hanging on any answer or V1.0 resolver the
/// queued call expected, then release the call.
fn propagateBreakToDrainedCall(peer: *Peer, queued: model.Message, resolution: model.Resolution) !void {
    // The virtual answer a V1.0 resolver-only call settles, through the one
    // engine seam that owns the resolver-descriptor mapping.
    const call_answer = peer.answerForDeliver(queued.deliver);
    if (call_answer) |ca| {
        const break_reason: model.BreakReason = switch (resolution) {
            .@"break" => |err| err,
            .fulfill => .{ .message = "pipelined target resolved to a non-reference value" },
        };
        // A failure here means the partner is left hanging on `ca`, so
        // it surfaces as a step error like every other drain refusal
        // (the resolution frame is already on `outbound`; see
        // `drainPipelinedCalls`).
        peer.sendAnswerResolutionCopying(ca, .{ .@"break" = break_reason }) catch |err| {
            freeMessage(peer.allocator, queued);
            return err;
        };
    }
    freeMessage(peer.allocator, queued);
}

/// Deliver a drained pipelined call to a local export `near` resolved its
/// target to: rewrite the target, install the call's own answer as one the session
/// owes, and surface a synthesized `op:deliver` event so the application
/// dispatches it as if it had arrived directly. Bounded by
/// `SessionLimits.max_local_deliveries` to stop a resolution chain looping.
fn deliverDrainedCallLocally(peer: *Peer, queued: model.Message, near: model.NearRef) !void {
    if (peer.local_delivery_depth >= peer.session_state.limits.max_local_deliveries) {
        freeMessage(peer.allocator, queued);
        return error.LocalDeliveryCapExceeded;
    }
    // Re-target at the export the resolution named. A delivery to a local
    // export is wire-shaped as `desc:export` (a `far` here), the same shape
    // a directly-received deliver to that export carries, so the synthesized
    // event is indistinguishable from one that arrived on the wire.
    // The rewritten call is serialized into its own frame below, so its heap
    // is always released here regardless of the append outcome.
    const rewritten = rewriteDeliverTarget(
        peer.allocator,
        queued.deliver,
        // Local delivery is wire-shaped as `desc:export` (a `far` here); the
        // export position is reinterpreted into the import space explicitly.
        .{ .far = .{ .import_position = near.export_position.reinterpret(model.ImportPosition) } },
    );
    defer freeMessage(peer.allocator, rewritten);

    // A V1.0 resolver-only call carries its answer in session state rather than
    // on the wire, and a queued one has to recover it here. The classifier
    // installed the virtual answer and linked it to the partner's resolver
    // import when the call arrived, then discarded it as `.pipelined`, because
    // at that moment the call had no target to be answered by. Re-encoding the
    // queued frame reproduces the wire, and the wire is exactly what never held
    // this answer, so without the override the surfaced deliver has nothing to
    // reply to and the reply is dropped where it is optional
    // (`actors.serve.resolveFulfill` returns on a null answer). Silence on the
    // partner's vow, from a call the engine accepted.
    const answer_override: events.AnswerOverride = if (rewritten.deliver.answer == null) blk: {
        const rmd = rewritten.deliver.resolve_me_desc orelse break :blk .none;
        const import_position = rmd.position() orelse break :blk .none;
        const named = peer.session_state.answerForResolverImport(
            model.ImportPosition.from(import_position),
        ) orelse break :blk .none;
        break :blk switch (named) {
            .virtual => |virtual| .{ .virtual_deliver = virtual },
            // A wire answer needs no override: the frame carries it.
            .wire => .none,
        };
    } else .none;
    var frame = try codec.dispatch.encodeMessageForProfile(
        peer.session_state.codec,
        peer.allocator,
        peer.session_state.captp_version,
        rewritten,
    );
    errdefer frame.deinit();
    // This peer encoded the frame from `rewritten` a moment ago, so its parse
    // cannot fail. A failure would be an engine invariant broken, not input.
    const parse = try events.Parse.store(peer.allocator, &frame, codec.dispatch.decodeBodyForProfile(
        peer.session_state.codec,
        peer.session_state.captp_version,
        frame.view(),
    ) catch unreachable);
    errdefer parse.deinit(peer.allocator);
    // The push is the last fallible step, so the row's ownership of the parse
    // begins exactly where this function's errdefer ends.
    try peer.events.push(peer.allocator, .{
        .frame = frame,
        .parse = parse,
        .tag = .deliver,
        .codec = peer.session_state.codec,
        .captp_version = peer.session_state.captp_version,
        .answer_override = answer_override,
        .deliver_answer_target = if (rewritten.deliver.answer) |answer|
            peer.session_state.answerTargetNamed(.fromWire(answer))
        else switch (answer_override) {
            .virtual_deliver => |answer| peer.session_state.answerTargetNamed(.fromVirtual(answer)),
            else => null,
        },
        .allocator = peer.allocator,
    });
    peer.local_delivery_depth += 1;
}
