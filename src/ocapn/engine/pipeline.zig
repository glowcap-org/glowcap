//! The stateful drain of the resolve seam (ADR-0003, ADR-0004): the `*Peer` half.
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
const remote_forward = @import("remote_forward.zig");

pub const rewriteDeliverTarget = resolution_math.rewriteDeliverTarget;
pub const borrowedListenerFire = resolution_math.borrowedListenerFire;
pub const ListenerDrainAction = resolution_math.ListenerDrainAction;
pub const classifyListenerDrain = resolution_math.classifyListenerDrain;
const projectResolution = resolution_math.projectResolution;
pub const maybeInstallInboundListener = listener_drain.maybeInstallInboundListener;
pub const prepareAnswerListenerDrain = listener_drain.prepareAnswerListenerDrain;
pub const PreparedListenerDrain = listener_drain.PreparedListenerDrain;

/// The answer authority behind an inbound promise target. A wire
/// `desc:answer` names the answer directly. A wire `desc:export` naming one of
/// our local promise exports decodes as `.near`. The session's explicit
/// export-to-answer link gives both forms one queue and settlement authority.
/// An object export with the same integer remains an object because the export
/// slot kind wins before the promise link is consulted.
fn pipelinedAnswer(peer: *Peer, target: *const model.view.Reference) ?model.AnswerName {
    return switch (target.*) {
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
    pub const Action = union(enum) {
        queue: session.PreparedPipelinedCallQueue,
        dispatch: resolution_chain.Outcome,
    };

    action: Action,
    message: ?model.Message,
    answer: ?model.AnswerName,
    introduced_far_imports: ?[]model.ImportPosition,
    reference_slots: u32,

    pub fn abandon(self: *PreparedPipelinedCall, peer: *Peer) void {
        switch (self.action) {
            .queue => |*prepared| prepared.abandon(&peer.session_state),
            .dispatch => {},
        }
        if (self.message) |message| {
            freeMessage(peer.allocator, message);
            self.message = null;
        }
        if (self.introduced_far_imports) |imports| {
            peer.allocator.free(imports);
            self.introduced_far_imports = null;
        }
    }

    pub fn commit(self: *PreparedPipelinedCall, peer: *Peer) !void {
        // `preparePipelinedCall` set `message` in the same prepare/commit
        // pair. The unset state is a caller bug, not a peer-reachable one.
        const message = self.message orelse unreachable;
        self.message = null;
        // Classification chose the name before receive committed its row.
        // Capture the stamp now, once, before GC can release and reuse it.
        const answer = if (self.answer) |name| peer.session_state.answerTargetNamed(name) orelse unreachable else null;
        const call: session.QueuedCall = .{
            .message = message,
            .answer = answer,
            .introduced_far_imports = self.introduced_far_imports,
            .reference_slots = self.reference_slots,
        };
        self.introduced_far_imports = null;
        switch (self.action) {
            .queue => |*prepared| prepared.commitNamed(call),
            .dispatch => |outcome| {
                peer.local_delivery_depth = 0;
                try dispatchDrainedCall(peer, call, outcome);
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
    deliver: *const model.view.Deliver,
    call_answer: ?model.AnswerName,
    introduced: *const session.validate.IntroducedImports,
) !?PreparedPipelinedCall {
    const answer = pipelinedAnswer(peer, &deliver.target) orelse return null;
    const owned = try (model.view.Body{ .deliver = deliver.* }).toOwned(peer.allocator);
    errdefer freeMessage(peer.allocator, owned);
    const imports = try introduced.dupeArgumentMentions(peer.allocator);
    errdefer if (imports) |positions| peer.allocator.free(positions);

    // The stored resolution is the settled/pending decision (the
    // `applySentResolve` invariant: a settled inbound answer always holds its
    // resolution). Peeking
    // rather than reading the status flag is what keeps a call that arrives
    // while the answer's own resolve is still a queued outbound message from
    // being misrouted; it sees the real value and dispatches against it.
    // Presence is certain because `pipelinedAnswer` above gated this name
    // through `hasInboundAnswer` in the same dispatch.
    const target = peer.session_state.answerTargetNamed(answer) orelse unreachable;
    const action: PreparedPipelinedCall.Action = if (resolution_chain.settledOutcome(peer, target)) |outcome|
        .{ .dispatch = outcome }
    else
        .{ .queue = try peer.session_state.preparePipelinedCallNamed(answer) };
    return .{
        .action = action,
        .message = owned,
        .answer = call_answer,
        .introduced_far_imports = imports,
        .reference_slots = introduced.reference_slots,
    };
}

/// Settle the local consequences of a just-sent `op:resolve`: the calls the
/// partner pipelined against the answer, then the projections anchored on it,
/// then its listeners (ADR-0003, ADR-0004 for
/// projections). Calls go first because a drained call may settle further
/// answers. The resolution itself is already stored: `applySentResolve`
/// stored it when the resolve was recorded, at the moment the answer's status
/// flipped, so a call, projection, or `op:listen` that arrived between record
/// and this drain was served directly. Only the work that anchored while the
/// answer was still pending remains. The resolution frame is already on
/// `outbound`, so a drain refusal surfaces as a step error without
/// un-sending it.
pub fn drainAnswerConsequencesTarget(
    peer: *Peer,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    consequence: resolution_chain.Outcome,
    prepared_listeners: *PreparedListenerDrain,
) !void {
    std.debug.assert(peer.session_state.answerPayloadForTarget(target) == payload);
    try drainPipelinedCalls(peer, payload, consequence);
    try drainProjections(peer, payload, consequence);
    prepared_listeners.commit(peer);
}

/// Drain calls the partner pipelined against a just-settled answer, dispatching
/// each against the resolution (ADR-0003).
/// `desc:answer` carries one answer position, so every queued target is flat.
fn drainPipelinedCalls(
    peer: *Peer,
    payload: *session.AnswerPayload,
    consequence: resolution_chain.Outcome,
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
    // Undispatched calls temporarily belong to the drain's local array.
    // Nested import release must not collect capabilities that those accepted
    // calls still own. Restore tracing after their ownership has transferred.
    const collection_pause = session.Session.LocalPromiseCustody.pauseCollection(&peer.session_state);
    defer collection_pause.deinit(&peer.session_state);
    const calls = try peer.session_state.takeAnswerPayloadCalls(payload);
    defer peer.allocator.free(calls);

    var index: usize = 0;
    errdefer for (calls[index..]) |queued| queued.deinit(peer.allocator);

    while (index < calls.len) {
        const queued = calls[index];
        index += 1;
        try dispatchDrainedCall(peer, queued, consequence);
    }
}

/// Answer an inbound `op:get` / `op:index` (ADR-0004, CapTP § op:get
/// "Receiving"): the projected answer is already installed by apply.
/// Anchor the projection on the receiver's answer. The receiver names a
/// promise, a `desc:answer` (`.promise`) or an export position that is an
/// inbound answer (`.near`, the same flip `installAnswerListener`
/// handles). Any other receiver can never settle to a value here, so the
/// projected answer breaks immediately.
pub fn respondToProjection(
    peer: *Peer,
    receiver: model.view.Reference,
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
/// settled (ADR-0004): each one resolves its
/// projected answer to the named field or element, re-anchors when the
/// resolution is itself a promise, or breaks. This never grows the native
/// stack: the shared stored-resolution walker returns one terminal value,
/// pending exact incarnation, or break before this batch is touched.
fn drainProjections(
    peer: *Peer,
    payload: *session.AnswerPayload,
    consequence: resolution_chain.Outcome,
) !void {
    const projections = try peer.session_state.takeAnswerPayloadProjections(payload);
    if (projections.len == 0) return;
    defer peer.allocator.free(projections);
    var index: usize = 0;
    errdefer for (projections[index..]) |p| session.deinitProjection(peer.allocator, p);

    while (index < projections.len) {
        const projection = projections[index];
        index += 1;
        try applyProjectionOutcome(peer, projection, consequence);
    }
}

/// Take ownership of `projection` and anchor it on inbound answer
/// `source`: install on its exact pending incarnation, compute from the shared
/// stored-resolution walk, or break when that walk cannot preserve identity.
fn anchorProjection(peer: *Peer, source: model.AnswerName, projection: session.Projection) !void {
    const target = peer.session_state.answerTargetNamed(source) orelse
        return breakProjection(peer, projection, "projection receiver names an unknown answer");
    if (resolution_chain.settledOutcome(peer, target)) |outcome|
        return applyProjectionOutcome(peer, projection, outcome);
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
            .resolved => |projected| try settleProjection(peer, projection, projected),
            .reanchor => try breakProjection(
                peer,
                projection,
                resolution_chain.missing_target_message,
            ),
        },
    }
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

/// Settle the exact question a projection created, taking ownership of the
/// projection: the resolve goes through the full resolve seam, so chained
/// projections, pipelined calls, and listeners on the projected answer all
/// drain. A projected value borrows its source resolution, which the
/// settlement clones into the answer store (the named boundary copy). A
/// released answer with no accepted dependents disappears and needs no reply.
/// If dependents were already accepted, its detached row remains the
/// settlement target: they drain without confusing a later question that
/// reused the wire position.
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
    queued: session.QueuedCall,
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

/// A sturdyref or routed reference is a value this session holds, not a
/// target it can deliver to, so a call pipelined onto it breaks here.
pub const undeliverable_target_message = "pipelined target resolved to a reference this session cannot deliver to";

fn dispatchTerminalCall(peer: *Peer, queued: session.QueuedCall, resolution: model.Resolution) !void {
    const maybe_reference: ?model.Reference = switch (resolution) {
        .fulfill => |arg| if (arg == .reference) arg.reference else null,
        .@"break" => null,
    };
    const reference = maybe_reference orelse
        return propagateBreakToDrainedCall(peer, queued, resolution);
    switch (reference) {
        .far => |far| try remote_forward.send(
            peer,
            rewriteDeliverTarget(peer.allocator, queued.message.deliver, .{ .far = far }),
            queued.answer,
            queued.introduced_far_imports,
        ),
        .near => |near| try deliverDrainedCallLocally(peer, queued, near),
        .promise => try propagateBreakToDrainedCall(
            peer,
            queued,
            .{ .@"break" = .{ .message = resolution_chain.missing_target_message } },
        ),
        .broken => |reason| try propagateBreakToDrainedCall(peer, queued, .{ .@"break" = reason }),
        .routed, .sturdy => try propagateBreakToDrainedCall(
            peer,
            queued,
            .{ .@"break" = .{ .message = undeliverable_target_message } },
        ),
    }
}

/// Settle a drained call whose resolution carried no reference target (a break
/// or a non-reference fulfill), taking ownership of `queued`: propagate the
/// break so the partner isn't left hanging on any answer or V1.0 resolver the
/// queued call expected, then release the call.
fn propagateBreakToDrainedCall(peer: *Peer, queued: session.QueuedCall, resolution: model.Resolution) !void {
    if (queued.answer) |target| if (session.ForwardedReply.targetIsLive(&peer.session_state, target)) {
        const break_reason: model.BreakReason = switch (resolution) {
            .@"break" => |err| err,
            .fulfill => .{ .message = "pipelined target resolved to a non-reference value" },
        };
        // A failure here means the partner is left hanging on this target, so
        // it surfaces as a step error like every other drain refusal
        // (the resolution frame is already on `outbound`; see
        // `drainPipelinedCalls`).
        peer.sendAnswerTargetResolutionCopying(target, .{ .@"break" = break_reason }) catch |err| {
            queued.deinit(peer.allocator);
            return err;
        };
    };
    defer freeMessage(peer.allocator, queued.message);
    try remote_forward.releaseArguments(peer, queued.introduced_far_imports);
}

/// Deliver a drained pipelined call to a local export `near` resolved its
/// target to: rewrite the target, install the call's own answer as one the session
/// owes, and surface a synthesized `op:deliver` event so the application
/// dispatches it as if it had arrived directly. Bounded by
/// `SessionLimits.max_local_deliveries` to stop a resolution chain looping.
fn deliverDrainedCallLocally(peer: *Peer, queued: session.QueuedCall, near: model.NearRef) !void {
    var imports_transferred = false;
    defer if (!imports_transferred) {
        if (queued.introduced_far_imports) |imports| peer.allocator.free(imports);
    };
    if (peer.local_delivery_depth >= peer.session_state.limits.max_local_deliveries) {
        freeMessage(peer.allocator, queued.message);
        return error.LocalDeliveryCapExceeded;
    }
    // Re-target at the export the resolution named. A delivery to a local
    // export is wire-shaped as `desc:export` (a `far` here), the same shape
    // a directly-received deliver to that export carries, so the synthesized
    // event is indistinguishable from one that arrived on the wire.
    // The rewritten call is serialized into its own frame below, so its heap
    // is always released here regardless of the append outcome.
    var rewritten = rewriteDeliverTarget(
        peer.allocator,
        queued.message.deliver,
        .{ .far = .{ .import_position = near.export_position.reinterpret(model.ImportPosition) } },
    );
    defer freeMessage(peer.allocator, rewritten);
    // This serialization recreates an inbound event. Restore sender
    // perspective for every descriptor so decoding preserves the admitted
    // receiver-perspective values, including the inline resolver.
    if (rewritten.deliver.resolve_me_desc) |resolver|
        rewritten.deliver.resolve_me_desc = replayReference(resolver);
    for (@constCast(rewritten.deliver.args)) |*argument| replayArgument(argument);

    // Private reply identity travels with the queued call, independently of
    // wire answer positions and reusable resolver capabilities.
    const answer_override: events.AnswerOverride = if (queued.answer) |answer| switch (answer.name) {
        .virtual => |virtual| .{ .virtual_deliver = virtual },
        .wire => .none,
    } else .none;
    var frame = try codec.dispatch.encodeMessageForProfile(
        peer.session_state.codec,
        peer.allocator,
        peer.session_state.captp_version,
        rewritten,
    );
    errdefer frame.deinit();
    const parse = events.Parse.decode(
        peer.allocator,
        &frame,
        peer.session_state.codec,
        peer.session_state.captp_version,
    ) catch |err| switch (err) {
        error.OutOfMemory => |oom| return oom,
        // This peer encoded the frame from `rewritten` a moment ago, so its
        // parse cannot fail. A failure would be an engine invariant broken,
        // not input.
        else => unreachable,
    };
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
        .deliver_answer_target = queued.answer,
        .introduced_far_imports = queued.introduced_far_imports,
        .reference_slots = queued.reference_slots,
        .allocator = peer.allocator,
    });
    imports_transferred = true;
    peer.local_delivery_depth += 1;
}

/// Invert codec perspective without consulting authority or allocating. Only
/// synthesized local replay needs this: its owned tree came from decode.
fn replayReference(reference: model.Reference) model.Reference {
    return switch (reference) {
        .near => |near| .{ .far = .{ .import_position = near.export_position.reinterpret(model.ImportPosition), .kind = near.kind } },
        .far => |far| .{ .near = .{ .export_position = far.import_position.reinterpret(model.ExportPosition), .kind = far.kind } },
        .promise, .routed, .sturdy, .broken => reference,
    };
}

fn replayArgument(argument: *model.Argument) void {
    switch (argument.*) {
        .reference => |reference| argument.* = .{ .reference = replayReference(reference) },
        .list, .set => |children| for (@constCast(children)) |*child| replayArgument(child),
        .tagged => |tagged| for (@constCast(tagged.value)) |*child| replayArgument(child),
        .@"struct" => |entries| for (@constCast(entries)) |*entry| replayArgument(&entry.value),
        .bytes, .symbol, .@"error", .handoff, .string, .integer, .boolean, .void, .float64, .keyword, .big_integer => {},
    }
}
