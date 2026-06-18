//! What happens when an answer settles — the whole of it (ADR-0007, ADR-0050).
//!
//! The first half is pure math, with no `Peer` in sight. When a promise
//! resolves, a few new messages fall out of it: the retargeted version of a
//! pipelined call that was waiting on it, the `op:deliver` that fires a
//! listener, and the projection of an `op:get` over the settled value. The pure
//! functions compute exactly those. Keeping them pure is what makes the whole
//! matrix of cases testable without standing up a live session: resolution
//! shape, path shape, and whether the listener asked for a partial.
//!
//! The second half is the stateful drain. Those functions take a `*Peer` and
//! perform the side effects the pure half computed: they install listeners,
//! queue and drain pipelined calls, anchor and settle projections, and fire
//! listeners when a sent `op:resolve` settles an answer. The engine spine calls
//! into them from `Peer.step`'s resolve tail and from inbound dispatch; like
//! the rest of the engine they are sync and no-I/O.
//!
//! On ownership: anything here that produces an owned message takes ownership of
//! what you pass in, like the queued call or the listener target, and moves its
//! heap into the result. It moves, it doesn't copy. The one exception is the
//! partial-listener case, where a single resolution has to both fire the listener
//! immediately and re-anchor it on the next answer, so there it makes one
//! `model.cloneReference`.

const std = @import("std");

const codec = @import("codec");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const freeMessage = model.freeMessage;

/// Replace a queued pipelined `op:deliver`'s target with `new_target`, taking
/// ownership of both `deliver`'s heap and `new_target`. The deliver's args,
/// answer, and `resolve_me_desc` are preserved (moved) into the returned message.
pub fn rewriteDeliverTarget(
    allocator: std.mem.Allocator,
    deliver: model.Deliver,
    new_target: model.Reference,
) model.Message {
    model.freeReference(allocator, deliver.target);
    return .{ .deliver = .{
        .target = new_target,
        .args = deliver.args,
        .answer = deliver.answer,
        .resolve_me_desc = deliver.resolve_me_desc,
    } };
}

/// Build the `op:deliver` that fires a listener with `resolution`, taking
/// ownership of `listener_target` (moved into the deliver's target) and cloning
/// the resolution payload. Per the OCapN `op:listen` notification shape (the
/// upstream conformance suite is the authority), the args are
/// `[Symbol("fulfill"), payload]` for a fulfillment or `[Symbol("break"),
/// Symbol(reason)]` for a break. On any failure `listener_target` and every
/// partial allocation are released.
pub fn synthesizeListenerFire(
    allocator: std.mem.Allocator,
    listener_target: model.Reference,
    resolution: model.Resolution,
) !model.Message {
    var target_owned = true;
    errdefer if (target_owned) model.freeReference(allocator, listener_target);

    const method = switch (resolution) {
        .fulfill => "fulfill",
        .@"break" => "break",
    };
    const method_symbol = try allocator.dupe(u8, method);
    errdefer allocator.free(method_symbol);

    const payload: model.Argument = switch (resolution) {
        .fulfill => |arg| try model.cloneArgument(allocator, arg),
        // The `op:listen` break notification carries the reason as a bare
        // Symbol, not an `<error>` record — the upstream OCapN suite asserts
        // `[Symbol("break"), Symbol(reason)]` for `test_op_listen_to_promise_and_break`,
        // and `v1_0.encodeResolveAsCallback` renders its V1.0 break the same
        // way (Goblins' unmarshaller rejects unknown records, so an `<error>`
        // payload would kill the break on a live Goblins partner).
        .@"break" => |err| try model.cloneArgument(allocator, .{ .symbol = err.message }),
    };
    errdefer model.freeArgument(allocator, payload);

    const args = try allocator.alloc(model.Argument, 2);
    args[0] = .{ .symbol = method_symbol };
    args[1] = payload;

    target_owned = false;
    return .{ .deliver = .{
        .target = listener_target,
        .args = args,
        .answer = null,
        .resolve_me_desc = null,
    } };
}

/// The single-hop chain a multi-hop pipelined deliver decomposes into:
/// zero-or-more intermediate messages in send order, plus the guaranteed-present
/// terminal deliver carrying the caller's outer args / answer / `resolve_me_desc`.
/// Splitting intermediates from the terminal makes non-emptiness structural — a
/// caller can't observe an empty chain.
pub const DecomposedChain = struct {
    /// One flat `op:deliver` per path step, in send order. The `intermediates`
    /// backing slice is the caller's to free; each element is an owned message.
    intermediates: []model.Message,
    /// The caller's outer deliver against the last intermediate answer. Always
    /// present (an empty path never reaches decomposition).
    terminal: model.Message,
};

/// Errors decomposition surfaces beyond allocation failure.
pub const DecomposeError = std.mem.Allocator.Error || error{
    /// A `field` path step reached the Syrup decomposer. `field` navigation is
    /// Cap'n-Proto-only (the model contract: `desc:answer` has no structural
    /// analog on `op:deliver`); surfacing it loudly beats a silently-dropped step.
    UnsupportedPipelineOp,
};

/// Decompose an owned multi-hop pipelined `op:deliver` (target = promise with a
/// non-empty path) into the chain of single-hop messages the Syrup wire admits.
/// `desc:answer` carries no path operand (ADR-0007 § Multi-hop decomposition at
/// the sender), so each `call`
/// step becomes its own flat `op:deliver` against a freshly-allocated
/// intermediate answer, and the caller's outer deliver chains against the last.
///
/// Pure move, no clone: each `call` op's args move into its intermediate deliver,
/// the outer args / `resolve_me_desc` move into the terminal, and the emptied
/// `path.ops` backing slice is freed (its elements live in the chain).
///
/// Ownership on error: a `field` step is rejected up front and `OutOfMemory`
/// fires on the single allocation — both before any move — so `message` is left
/// whole for the caller to release. Decomposition never partially consumes
/// `message`.
pub fn decomposeOutboundDeliver(
    allocator: std.mem.Allocator,
    sess: *session.Session,
    message: model.Message,
) DecomposeError!DecomposedChain {
    const deliver = message.deliver;
    const promise = deliver.target.promise;
    const ops = promise.path.ops;
    std.debug.assert(ops.len != 0);

    // Pre-flight: Syrup admits only `call` steps as chained delivers. Reject a
    // `field` step before moving anything, leaving `message` whole.
    for (ops) |op| {
        if (op == .field) return DecomposeError.UnsupportedPipelineOp;
    }

    const intermediates = try allocator.alloc(model.Message, ops.len);
    // Infallible from here: allocateOutboundAnswer never fails and building a
    // deliver struct only moves heap, so no partial-move cleanup is needed.
    var prev_answer = promise.answer_position;
    for (ops, 0..) |op, i| {
        const intermediate_id = sess.allocateOutboundAnswer();
        intermediates[i] = .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = prev_answer } },
            .args = op.call,
            .answer = intermediate_id,
            .resolve_me_desc = null,
        } };
        prev_answer = intermediate_id;
    }
    const terminal: model.Message = .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = prev_answer } },
        .args = deliver.args,
        .answer = deliver.answer,
        .resolve_me_desc = deliver.resolve_me_desc,
    } };
    // Every op payload + the outer args moved into the chain; release only the
    // emptied `ops` backing slice.
    allocator.free(ops);
    return .{ .intermediates = intermediates, .terminal = terminal };
}

/// What draining one listener against a resolution produces, per ADR-0007
/// § Listener fire matrix. The engine applies the action (send the fire, reinstall the
/// entry). Each variant owns the heap it carries.
pub const ListenerDrainAction = union(enum) {
    /// Fire the listener once with the resolution and drop the entry. Every
    /// resolution shape except `Fulfill(Promise(_))` lands here.
    fire: model.Message,
    /// Fire the listener with the partial promise AND re-anchor the entry on
    /// `next_answer`. `wants_partial` × `Fulfill(Promise(_))` only.
    fire_and_reinstall: struct {
        fire: model.Message,
        next_answer: u64,
        entry: session.ListenerEntry,
    },
    /// Re-anchor the entry on `next_answer` without firing. Spec-strict
    /// `Fulfill(Promise(_))` (no `wants_partial`).
    reinstall: struct {
        next_answer: u64,
        entry: session.ListenerEntry,
    },
};

/// Decide how `entry` drains against `resolution` (ADR-0007 § Listener fire matrix),
/// taking ownership of `entry`'s target. `Fulfill(Promise(_))` re-anchors the
/// listener on the promise's answer (firing first only when `wants_partial`);
/// every other resolution fires once. On failure `entry`'s target is released.
pub fn classifyListenerDrain(
    allocator: std.mem.Allocator,
    entry: session.ListenerEntry,
    resolution: model.Resolution,
) !ListenerDrainAction {
    if (resolution == .fulfill and
        resolution.fulfill == .reference and
        resolution.fulfill.reference == .promise)
    {
        const next_answer = resolution.fulfill.reference.promise.answer_position;
        if (!entry.wants_partial) {
            return .{ .reinstall = .{ .next_answer = next_answer, .entry = entry } };
        }
        // The one place a resolution is duplicated: the listener both fires now
        // (with the partial promise) and stays anchored on the next answer.
        const target_clone = model.cloneReference(allocator, entry.target) catch |err| {
            model.freeReference(allocator, entry.target);
            return err;
        };
        const fire = synthesizeListenerFire(allocator, target_clone, resolution) catch |err| {
            model.freeReference(allocator, entry.target);
            return err;
        };
        return .{ .fire_and_reinstall = .{ .fire = fire, .next_answer = next_answer, .entry = entry } };
    }

    // synthesizeListenerFire consumes entry.target (and frees it on its own
    // error), so no further cleanup is needed here.
    const fire = try synthesizeListenerFire(allocator, entry.target, resolution);
    return .{ .fire = fire };
}

/// What `projectResolution` decided for one `op:get` / `op:index`
/// projection over a settled resolution.
pub const Projected = union(enum) {
    /// The projection settled. The payload *borrows* the input resolution;
    /// the caller's send clones it (the one named boundary copy).
    resolved: model.Resolution,
    /// The resolution was itself a promise; re-anchor the projection on that
    /// promise's answer.
    reanchor: u64,
};

/// Compute an `op:get` / `op:index` / `op:untag` projection over a settled
/// resolution (ADR-0050). A field projection requires a Struct fulfillment,
/// an element projection a List, and an untag projection a Tagged with the
/// asserted tag; a broken receiver passes its break through (the spec's
/// inherited rejection); a fulfillment that is itself a promise reference
/// re-anchors. Every other shape breaks with a typed reason. Pure; the
/// `.resolved` payload borrows `resolution`.
pub fn projectResolution(resolution: model.Resolution, kind: session.ProjectionKind) Projected {
    const value = switch (resolution) {
        .@"break" => |err| return .{ .resolved = .{ .@"break" = err } },
        .fulfill => |arg| arg,
    };
    if (value == .reference and value.reference == .promise) {
        return .{ .reanchor = value.reference.promise.answer_position };
    }
    switch (kind) {
        .field => |field| {
            if (value != .@"struct") return .{ .resolved = .{ .@"break" = .{
                .message = "op:get receiver did not resolve to a Struct",
            } } };
            for (value.@"struct") |entry| {
                if (std.mem.eql(u8, entry.key, field)) {
                    return .{ .resolved = .{ .fulfill = entry.value } };
                }
            }
            return .{ .resolved = .{ .@"break" = .{
                .message = "op:get field is absent on the Struct",
            } } };
        },
        .index => |index| {
            if (value != .list) return .{ .resolved = .{ .@"break" = .{
                .message = "op:index receiver did not resolve to a List",
            } } };
            if (index < 0 or index >= value.list.len) return .{ .resolved = .{ .@"break" = .{
                .message = "op:index position is out of the List's bounds",
            } } };
            return .{ .resolved = .{ .fulfill = value.list[@intCast(index)] } };
        },
        .untag => |tag| {
            if (value != .tagged) return .{ .resolved = .{ .@"break" = .{
                .message = "op:untag receiver did not resolve to a Tagged",
            } } };
            if (!std.mem.eql(u8, value.tagged.tag, tag)) return .{ .resolved = .{ .@"break" = .{
                .message = "op:untag tag does not match the receiver's Tagged tag",
            } } };
            // The spec's Tagged carries a single value; pancake's model carries
            // the Goblins user-record payload as a slice (ADR-0021). One value
            // unwraps to that value; any other arity unwraps to the payload as
            // the List it is, so nothing is guessed and nothing is dropped.
            if (value.tagged.value.len == 1) {
                return .{ .resolved = .{ .fulfill = value.tagged.value[0] } };
            }
            return .{ .resolved = .{ .fulfill = .{ .list = value.tagged.value } } };
        },
    }
}

// ---------------------------------------------------------------------------
// The stateful drain: the `*Peer` half of the resolve seam. Everything below
// is called from the engine spine (`Peer.step`'s resolve tail and inbound
// dispatch) and applies the decisions the pure half above computes.
// ---------------------------------------------------------------------------

/// Register an inbound `op:listen`'s listener against the targeted answer so
/// our eventual `op:resolve` fires it (ADR-0007 § op:listen). Mirrors the
/// V1.0 resolver-import pattern: the partner introduces their listener object
/// as a descriptor we import; we reach it later via the matching `far`. A
/// non-promise target or a listen on an answer we don't owe resolution for is
/// not an error — it falls through to ordinary recv handling.
///
/// Validated before anything mutates, like its sibling
/// `maybeEnqueuePipelinedCall`: the session's `.listen` rule runs first, so an
/// unauthorized listen (feature not negotiated, unheld target) is refused
/// before any import or listener is installed.
pub fn maybeInstallInboundListener(peer: *Peer, listen: model.view.Listen) !void {
    try peer.session_state.validateInboundListen(listen);
    switch (listen.target) {
        .promise => |promise| try installAnswerListener(peer, promise.answer_position, listen),
        // A listen on one of our exports: the partner sent `desc:export N`,
        // which is `.near` after the perspective flip. If N is an inbound
        // answer (e.g. a promise returned by the promise-resolver actor),
        // it takes the same install as a promise-descriptor listen.
        .near => |near| try installAnswerListener(peer, near.export_position, listen),
        // An `op:listen` on a handoff-imported promise (ADR-0009): the target
        // names one of our imports — post-flip (ADR-0010) `<desc:import-*>`
        // decodes to a `far` whose import_position is the import. Only a
        // third-party-hosted import admits a relayed-resolution listener;
        // a direct-partner import (or unknown id) falls through to ordinary
        // recv handling.
        .far => |far| {
            const import_position = far.import_position;
            if (!peer.session_state.isThirdPartyImport(import_position)) return;
            const position = listen.listener.position() orelse return;
            try peer.session_state.registerImport(position);
            try peer.session_state.installImportedPromiseListener(import_position, .{
                .target = .{ .far = model.FarRef.object(position) },
                .wants_partial = listen.wants_partial,
            });
            // Late listener: if the relayed resolution already arrived, fire
            // it now (the relay drain that recorded it already drained the
            // listeners present at that time).
            try maybeFireLateImportedListener(peer, import_position);
        },
        .sturdy, .broken => return,
    }
}

/// Install `listen`'s listener on inbound answer `answer` — the shared body
/// for a listen that names the answer by promise descriptor or by export
/// position. An unknown answer or a position-less listener falls through to
/// ordinary recv handling. An already-settled answer fires the listener now
/// against the stored resolution, or a generic break when none was kept.
fn installAnswerListener(peer: *Peer, answer: u64, listen: model.view.Listen) !void {
    _ = peer.session_state.inboundAnswer(answer) orelse return;
    const position = listen.listener.position() orelse return;
    try peer.session_state.registerImport(position);
    const listener_entry: session.ListenerEntry = .{
        .target = .{ .far = model.FarRef.object(position) },
        .wants_partial = listen.wants_partial,
    };
    // A settled inbound answer always holds its stored resolution (the
    // `applySentResolve` invariant: status and resolution land together at
    // record time). So the peek is the whole decision — present means settled, fire the
    // listener now from the kept value; absent means still pending, install it
    // for the answer's own resolve to fire (`fireListenersOnResolve`).
    if (peer.session_state.peekResolution(answer)) |resolution| {
        const action = try classifyListenerDrain(peer.allocator, listener_entry, resolution.*);
        try applyListenerAction(peer, action);
    } else {
        try peer.session_state.installListener(answer, listener_entry);
    }
}

/// Handle an inbound `op:deliver` that pipelines against an answer we owe,
/// returning whether it was handled. A non-promise target or an unknown answer
/// returns `false` (the caller surfaces it normally); every known answer is
/// handled here and returns `true`.
///
/// A still-pending answer queues the owned call until we resolve it; an
/// enqueue refusal (e.g. the queue cap) propagates and the session frees the
/// call. A settled answer dispatches the call right now, through the same
/// `dispatchDrainedCall` path a queued call takes on drain, against its kept
/// resolution — the case a live Goblins enliven-and-call in one breath hits,
/// since we auto-serve the bootstrap fetch synchronously and the answer settles
/// before the pipelined frame is processed. The settled-vs-pending split is the
/// stored resolution itself (the `applySentResolve` invariant: a settled inbound
/// answer always holds its resolution), not the status flag, so a call arriving while
/// the answer's own resolve is queued-but-unemitted is dispatched against the
/// real value rather than mistaken for an unresolved or broken target.
///
/// Every arm validates the borrowed view first (the same reference / argument /
/// depth checks as a direct deliver) and only then materializes it owned, so an
/// attacker-shaped pipelined deliver is refused before anything allocates or
/// mutates.
pub fn maybeEnqueuePipelinedCall(peer: *Peer, deliver: model.view.Deliver) !bool {
    if (deliver.target != .promise) return false;
    const answer = deliver.target.promise.answer_position;
    if (peer.session_state.inboundAnswer(answer) == null) return false;

    // The V1.0 resolver for this deliver's `resolve_me_desc` was already
    // installed by the inbound-deliver classifier (`Peer.classifyInboundDeliver`),
    // which probes V1.0 classification before pipelining.

    try peer.session_state.validatePipelinedDeliver(deliver);

    // The stored resolution is the settled/pending decision (the
    // `applySentResolve` invariant: a settled inbound answer always holds its
    // resolution). Peeking
    // rather than reading the status flag is what keeps a call that arrives
    // while the answer's own resolve is still a queued outbound message from
    // being misrouted — it sees the real value and dispatches against it.
    if (peer.session_state.peekResolution(answer)) |resolution| {
        // Settled: dispatch the call right now, the same path a queued call
        // takes on drain. The local-delivery bound is per-resolution (see
        // `drainPipelinedCalls`), so it resets for this immediate dispatch
        // exactly as it does for a drain.
        const owned = try (model.view.Body{ .deliver = deliver }).toOwned(peer.allocator);
        peer.local_delivery_depth = 0;
        try dispatchDrainedCall(peer, answer, owned, resolution.*);
        return true;
    }

    // Still pending: queue the call until we resolve the answer. Install the
    // queued call's own answer first so further pipelined calls can target it (a
    // multi-hop pipeline: A→B→C queues B on A, then C targets B's answer — C
    // needs B's answer to exist).
    if (deliver.answer) |call_answer| {
        try peer.session_state.installInboundAnswer(call_answer);
    }
    const owned = try (model.view.Body{ .deliver = deliver }).toOwned(peer.allocator);
    try peer.session_state.enqueuePipelinedCall(answer, owned);
    return true;
}

/// Drain the calls the partner pipelined against the answer a just-sent
/// `op:resolve` settles, dispatching each against the resolution (ADR-0007
/// § Queue ownership and drain). Queued inbound targets always carry an empty path: a
/// multi-hop pipeline is decomposed at the *sender* into single-hop frames
/// (`Peer.send`'s decomposition), so every `desc:answer` on the wire is flat.
pub fn drainPipelinedCalls(peer: *Peer, resolve: model.Resolve) !void {
    // `local_delivery_depth` bounds the local deliveries *one* resolution's
    // drain produces (a drained call resolving to a local export). The drain
    // fans out only across the calls queued on this answer — it never
    // synchronously re-enters, since each local delivery surfaces an event the
    // application resolves on a later turn. So the bound is per-resolution and
    // resets here; left as a peer-lifetime counter it would wedge a long-lived
    // peer after `max_local_deliveries` legitimate deliveries across the whole
    // connection. The cross-turn chain is application-paced, not unbounded
    // auto-recursion, and a promise cycle is caught separately on requeue.
    peer.local_delivery_depth = 0;
    const calls = try peer.session_state.takePipelinedCalls(resolve.answer);
    defer peer.allocator.free(calls);

    var index: usize = 0;
    errdefer for (calls[index..]) |queued| freeMessage(peer.allocator, queued);

    while (index < calls.len) {
        const queued = calls[index];
        index += 1;
        try dispatchDrainedCall(peer, resolve.answer, queued, resolve.resolution);
    }
}

/// Answer an inbound `op:get` / `op:index` (ADR-0050; CapTP § op:get
/// "Receiving"): the projected answer is already installed by apply;
/// anchor the projection on the receiver's answer. The receiver names a
/// promise — a `desc:answer` (`.promise`) or an export position that is an
/// inbound answer (`.near`, the same flip `installAnswerListener`
/// handles). Any other receiver can never settle to a value here, so the
/// projected answer breaks immediately.
pub fn respondToProjection(
    peer: *Peer,
    receiver: anytype,
    kind: session.ProjectionKind,
    new_answer: u64,
) !void {
    const projection: session.Projection = .{
        .kind = switch (kind) {
            .field => |field| .{ .field = try peer.allocator.dupe(u8, field) },
            .index => |index| .{ .index = index },
            .untag => |tag| .{ .untag = try peer.allocator.dupe(u8, tag) },
        },
        .answer = new_answer,
    };
    const source: ?u64 = switch (receiver) {
        .promise => |promise| promise.answer_position,
        .near => |near| if (peer.session_state.inboundAnswer(near.export_position) != null)
            near.export_position
        else
            null,
        else => null,
    };
    if (source) |answer| {
        try anchorProjection(peer, answer, projection);
    } else {
        try breakProjection(peer, projection, "projection receiver is not a promise");
    }
}

/// Drain the `op:get` / `op:index` projections anchored on the answer a
/// just-sent `op:resolve` settles (ADR-0050): each one resolves its
/// projected answer to the named field or element, re-anchors when the
/// resolution is itself a promise, or breaks. This never grows the native
/// stack: a projected resolve is *queued* (encode is deferred to `step`),
/// so a chain of projections-on-projections drains iteratively, one queued
/// message per step, and each drain settles a distinct pending answer —
/// total work is bounded by the projections the caps admitted. The one
/// synchronous walk, following *stored* resolutions in
/// `anchorProjection`, is hop-bounded by `max_projection_chain`.
pub fn drainProjections(peer: *Peer, resolve: model.Resolve) !void {
    const projections = try peer.session_state.takeProjections(resolve.answer);
    if (projections.len == 0) return;
    defer peer.allocator.free(projections);
    var index: usize = 0;
    errdefer for (projections[index..]) |p| session.deinitProjection(peer.allocator, p);

    while (index < projections.len) {
        const projection = projections[index];
        index += 1;
        switch (projectResolution(resolve.resolution, projection.kind)) {
            .resolved => |projected| try resolveProjection(peer, projection, projected),
            .reanchor => |next| try anchorProjection(peer, next, projection),
        }
    }
}

/// Take ownership of `projection` and anchor it on inbound answer
/// `source`: install on a pending answer, compute immediately from a
/// settled answer's stored resolution (following promise-shaped
/// resolutions hop by hop up to `max_projection_chain`), or break the
/// projected answer when the walk dead-ends.
fn anchorProjection(peer: *Peer, source: u64, projection: session.Projection) !void {
    var current = source;
    var moving = projection;
    while (true) {
        if (peer.session_state.inboundAnswer(current) == null)
            return breakProjection(peer, moving, "projection receiver names an unknown answer");
        // The stored resolution is itself the settled/pending decision (the
        // `applySentResolve` invariant couples status and resolution, so peeking
        // is equivalent to reading the flag and never rests on the `.?`). Absent
        // means still pending — install the projection and let the answer's own
        // resolve drain it (`drainProjections`); present means project now.
        // Mirrors `installProjection`, `installAnswerListener`, and
        // `Peer.stepInner`, every other settled-answer reader.
        const resolution = peer.session_state.peekResolution(current) orelse
            return peer.session_state.installProjection(current, moving);
        switch (projectResolution(resolution.*, moving.kind)) {
            .resolved => |projected| return resolveProjection(peer, moving, projected),
            .reanchor => |next| {
                moving.hops += 1;
                if (moving.hops > peer.session_state.limits.max_projection_chain) {
                    return breakProjection(peer, moving, "projection chain exceeds max_projection_chain");
                }
                current = next;
            },
        }
    }
}

/// Settle one projection (taking ownership): send the projected resolve for
/// its answer through the full resolve seam, so chained projections,
/// pipelined calls, and listeners on the projected answer all drain. The
/// projected payload borrows its source resolution; `sendCopying` clones it
/// (the named boundary copy). A projected answer the application already
/// settled is left as it is.
fn resolveProjection(peer: *Peer, projection: session.Projection, projected: model.Resolution) !void {
    defer session.deinitProjection(peer.allocator, projection);
    if (peer.session_state.answerResolved(projection.answer)) return;
    try peer.sendCopying(.{ .resolve = .{ .answer = projection.answer, .resolution = projected } });
}

/// Break one projection's answer (taking ownership of the projection) with
/// a static reason.
fn breakProjection(peer: *Peer, projection: session.Projection, reason: []const u8) !void {
    defer session.deinitProjection(peer.allocator, projection);
    if (peer.session_state.answerResolved(projection.answer)) return;
    try peer.sendCopying(.{ .resolve = .{
        .answer = projection.answer,
        .resolution = .{ .@"break" = .{ .message = reason } },
    } });
}

/// Dispatch one drained pipelined call (owned) against `resolution`, taking
/// ownership of `queued`. A `Far` resolution forwards the call on the wire; a
/// `Near` delivers it locally; another promise re-queues it; every other
/// shape (broken / sturdy / non-reference / break) drops it after propagating
/// the break (`propagateBreakToDrainedCall`).
fn dispatchDrainedCall(peer: *Peer, answer: u64, queued: model.Message, resolution: model.Resolution) !void {
    const maybe_reference: ?model.Reference = switch (resolution) {
        .fulfill => |arg| if (arg == .reference) arg.reference else null,
        .@"break" => null,
    };
    const reference = maybe_reference orelse
        return propagateBreakToDrainedCall(peer, queued, resolution);
    switch (reference) {
        .far => |far| try peer.send(rewriteDeliverTarget(peer.allocator, queued.deliver, .{ .far = far })),
        .near => |near| try deliverDrainedCallLocally(peer, queued, near),
        .promise => |promise| {
            const batch = peer.allocator.alloc(model.Message, 1) catch |err| {
                freeMessage(peer.allocator, queued);
                return err;
            };
            batch[0] = queued;
            try peer.session_state.requeuePipelinedCalls(promise.answer_position, &.{answer}, batch);
        },
        .sturdy, .broken => freeMessage(peer.allocator, queued),
    }
}

/// Settle a drained call whose resolution carried no reference target (a break
/// or a non-reference fulfill), taking ownership of `queued`: propagate the
/// break so the partner isn't left hanging on any answer or V1.0 resolver the
/// queued call expected, then release the call.
fn propagateBreakToDrainedCall(peer: *Peer, queued: model.Message, resolution: model.Resolution) !void {
    const call_answer = queued.deliver.answer orelse blk: {
        // V1.0 resolver-only: look up the virtual answer.
        if (queued.deliver.resolve_me_desc) |rmd| {
            const id = switch (rmd) {
                .far => |far| far.import_position,
                .near => |near| near.export_position,
                else => break :blk @as(?u64, null),
            };
            break :blk peer.session_state.answerForResolverImport(id);
        }
        break :blk @as(?u64, null);
    };
    if (call_answer) |ca| {
        const break_reason: model.BreakReason = switch (resolution) {
            .@"break" => |err| err,
            .fulfill => .{ .message = "pipelined target resolved to a non-reference value" },
        };
        // A failure here means the partner is left hanging on `ca`, so
        // it surfaces as a step error like every other drain refusal
        // (the resolution frame is already on `outbound`; see
        // `drainPipelinedCalls`).
        peer.sendCopying(.{ .resolve = .{
            .answer = ca,
            .resolution = .{ .@"break" = break_reason },
        } }) catch |err| {
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
    // export is wire-shaped as `desc:export` (a `far` here) — the same shape
    // a directly-received deliver to that export carries — so the synthesized
    // event is indistinguishable from one that arrived on the wire.
    // The rewritten call is serialized into its own frame below, so its heap
    // is always released here regardless of the append outcome.
    const rewritten = rewriteDeliverTarget(
        peer.allocator,
        queued.deliver,
        .{ .far = .{ .import_position = near.export_position } },
    );
    defer freeMessage(peer.allocator, rewritten);

    if (rewritten.deliver.answer) |call_answer| {
        try peer.session_state.installInboundAnswer(call_answer);
    }
    var frame = try codec.dispatch.encodeMessageForProfile(
        peer.session_state.codec,
        peer.allocator,
        peer.session_state.wire_profile,
        rewritten,
    );
    errdefer frame.deinit();
    try peer.events.push(peer.allocator, .{ .frame = frame, .tag = .deliver, .resolve_answer = null, .codec = peer.session_state.codec });
    peer.local_delivery_depth += 1;
}

/// Drain the listeners registered against the answer a just-sent
/// `op:resolve` settles, firing each per the (resolution × `wants_partial`)
/// matrix (ADR-0007 § Listener fire matrix). Each fire moves onto `pending_send` via
/// `Peer.send` so a later `step` encodes it; partial promises re-anchor the
/// listener on the next answer.
pub fn fireListenersOnResolve(peer: *Peer, resolve: model.Resolve) !void {
    const listeners = try peer.session_state.takePipelinedListeners(resolve.answer);
    defer peer.allocator.free(listeners);

    var index: usize = 0;
    // On any mid-drain failure, release the targets of the listeners not yet
    // consumed; entries already moved into an action are owned by it.
    errdefer for (listeners[index..]) |entry| model.freeReference(peer.allocator, entry.target);

    while (index < listeners.len) {
        const entry = listeners[index];
        index += 1;
        const action = try classifyListenerDrain(peer.allocator, entry, resolve.resolution);
        try applyListenerAction(peer, action);
    }
}

/// Fire every listener installed on handoff-imported promise `import_position`
/// (ADR-0009) with `resolution`, draining the listener list. `resolution` is
/// borrowed — each fire clones the payload it carries — so the caller keeps
/// ownership. Each fire moves onto `pending_send` via `Peer.send`. Imported-
/// promise listeners fire unconditionally (no `wants_partial` re-anchor; a
/// relayed resolution is the settled value).
pub fn fireImportedPromiseListeners(peer: *Peer, import_position: u64, resolution: model.Resolution) !void {
    const listeners = try peer.session_state.takeImportedPromiseListeners(import_position);
    defer peer.allocator.free(listeners);

    var index: usize = 0;
    errdefer for (listeners[index..]) |entry| model.freeReference(peer.allocator, entry.target);

    while (index < listeners.len) {
        const entry = listeners[index];
        index += 1;
        const fire = try synthesizeListenerFire(peer.allocator, entry.target, resolution);
        try peer.send(fire);
    }
}

/// Fire a just-installed listener on `import_position` if its relayed resolution
/// already arrived (ADR-0009 late-listener immediate fire). The stored
/// resolution is borrowed for the fire and left in place for further late
/// listeners.
fn maybeFireLateImportedListener(peer: *Peer, import_position: u64) !void {
    const resolution = (peer.session_state.importedPromiseResolution(import_position) orelse return).*;
    try fireImportedPromiseListeners(peer, import_position, resolution);
}

/// Apply one `ListenerDrainAction`, taking ownership of the heap
/// it carries: a fire moves onto `pending_send`; a re-anchored entry moves
/// back into the listener table on its next answer.
fn applyListenerAction(peer: *Peer, action: ListenerDrainAction) !void {
    switch (action) {
        .fire => |fire| try peer.send(fire),
        .fire_and_reinstall => |fr| {
            peer.send(fr.fire) catch |err| {
                model.freeReference(peer.allocator, fr.entry.target);
                return err;
            };
            try peer.session_state.installListener(fr.next_answer, fr.entry);
        },
        .reinstall => |ri| try peer.session_state.installListener(ri.next_answer, ri.entry),
    }
}
