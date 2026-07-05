//! The stateful drain of the resolve seam (ADR-0007, ADR-0050): the `*Peer` half.
//!
//! These functions take a `*Peer` and perform the side effects the pure
//! resolution math computes: they install listeners, queue and drain pipelined
//! calls, anchor and settle projections, and fire listeners when a sent
//! `op:resolve` settles an answer. The engine spine calls into them from
//! `Peer.step`'s resolve tail and from inbound dispatch; like the rest of the
//! engine they are sync and no-I/O.
//!
//! The pure half — what falls out of a settled answer, with no `Peer` in sight —
//! lives in `pipeline_resolution.zig`; this file re-exports its surface so
//! `engine.pipeline.<name>` still names the whole resolve seam.
//!
//! On ownership: anything that produces an owned message takes ownership of what
//! you pass in (the queued call, the listener target) and moves its heap into the
//! result. It moves, it doesn't copy.

const std = @import("std");

const codec = @import("codec");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const freeMessage = model.freeMessage;

// The pure resolution math lives in `pipeline_resolution.zig`. Re-exported here
// so `engine.pipeline.<name>` names the whole resolve seam and the stateful
// drain below can call the pure half by its bare name.
const resolution_math = @import("pipeline_resolution.zig");

pub const rewriteDeliverTarget = resolution_math.rewriteDeliverTarget;
pub const synthesizeListenerFire = resolution_math.synthesizeListenerFire;
pub const decomposeOutboundDeliver = resolution_math.decomposeOutboundDeliver;
pub const ListenerDrainAction = resolution_math.ListenerDrainAction;
pub const classifyListenerDrain = resolution_math.classifyListenerDrain;
const projectResolution = resolution_math.projectResolution;

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
        // it takes the same install as a promise-descriptor listen — the
        // export and answer spaces coincide here, so the reinterpret is
        // explicit.
        .near => |near| try installAnswerListener(peer, near.export_position.reinterpret(model.AnswerId), listen),
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
            try peer.session_state.registerImport(model.ImportId.from(position));
            try peer.session_state.installImportedPromiseListener(import_position, .{
                .listener = .{ .far = model.FarRef.object(position) },
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
fn installAnswerListener(peer: *Peer, answer: model.AnswerId, listen: model.view.Listen) !void {
    _ = peer.session_state.inboundAnswer(answer) orelse return;
    const position = listen.listener.position() orelse return;
    try peer.session_state.registerImport(model.ImportId.from(position));
    const listener_entry: session.ListenerEntry = .{
        .listener = .{ .far = model.FarRef.object(position) },
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
/// resolution, the case a live Goblins enliven-and-call in one breath hits,
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
    // being misrouted; it sees the real value and dispatches against it.
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
    // multi-hop pipeline: A→B→C queues B on A, then C targets B's answer, C
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
    // fans out only across the calls queued on this answer, it never
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
/// promise, a `desc:answer` (`.promise`) or an export position that is an
/// inbound answer (`.near`, the same flip `installAnswerListener`
/// handles). Any other receiver can never settle to a value here, so the
/// projected answer breaks immediately.
pub fn respondToProjection(
    peer: *Peer,
    receiver: anytype,
    kind: session.ProjectionKind,
    new_answer: model.AnswerId,
) !void {
    const projection: session.Projection = .{
        .kind = switch (kind) {
            .field => |field| .{ .field = try peer.allocator.dupe(u8, field) },
            .index => |index| .{ .index = index },
            .untag => |tag| .{ .untag = try peer.allocator.dupe(u8, tag) },
        },
        .answer = new_answer,
    };
    // A `.near` receiver is one of our exports whose position is also an inbound
    // answer (the same flip `installAnswerListener` handles); the reinterpret to
    // the answer space is explicit.
    const source: ?model.AnswerId = switch (receiver) {
        .promise => |promise| promise.answer_position,
        .near => |near| if (peer.session_state.inboundAnswer(near.export_position.reinterpret(model.AnswerId)) != null)
            near.export_position.reinterpret(model.AnswerId)
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
/// message per step, and each drain settles a distinct pending answer,
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
fn anchorProjection(peer: *Peer, source: model.AnswerId, projection: session.Projection) !void {
    var current = source;
    var moving = projection;
    while (true) {
        if (peer.session_state.inboundAnswer(current) == null)
            return breakProjection(peer, moving, "projection receiver names an unknown answer");
        // The stored resolution is itself the settled/pending decision (the
        // `applySentResolve` invariant couples status and resolution, so peeking
        // is equivalent to reading the flag and never rests on the `.?`). Absent
        // means still pending, install the projection and let the answer's own
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
fn dispatchDrainedCall(peer: *Peer, answer: model.AnswerId, queued: model.Message, resolution: model.Resolution) !void {
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
        // V1.0 resolver-only: look up the virtual answer. The resolver mention
        // is a partner import; a `.near` here is a local resolver export in the
        // same integer space, reinterpreted explicitly for the lookup.
        if (queued.deliver.resolve_me_desc) |rmd| {
            const id: u64 = switch (rmd) {
                .far => |far| far.import_position.int(),
                .near => |near| near.export_position.int(),
                else => break :blk @as(?model.AnswerId, null),
            };
            break :blk peer.session_state.answerForResolverImport(model.ImportId.from(id));
        }
        break :blk @as(?model.AnswerId, null);
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
        // Local delivery is wire-shaped as `desc:export` (a `far` here); the
        // export position is reinterpreted into the import space explicitly.
        .{ .far = .{ .import_position = near.export_position.reinterpret(model.ImportId) } },
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
    errdefer for (listeners[index..]) |entry| model.freeReference(peer.allocator, entry.listener);

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
pub fn fireImportedPromiseListeners(peer: *Peer, import_position: model.ImportId, resolution: model.Resolution) !void {
    const listeners = try peer.session_state.takeImportedPromiseListeners(import_position);
    defer peer.allocator.free(listeners);

    var index: usize = 0;
    errdefer for (listeners[index..]) |entry| model.freeReference(peer.allocator, entry.listener);

    while (index < listeners.len) {
        const entry = listeners[index];
        index += 1;
        const fire = try synthesizeListenerFire(peer.allocator, entry.listener, resolution);
        try peer.send(fire);
    }
}

/// Fire a just-installed listener on `import_position` if its relayed resolution
/// already arrived (ADR-0009 late-listener immediate fire). The stored
/// resolution is borrowed for the fire and left in place for further late
/// listeners.
fn maybeFireLateImportedListener(peer: *Peer, import_position: model.ImportId) !void {
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
                model.freeReference(peer.allocator, fr.entry.listener);
                return err;
            };
            try peer.session_state.installListener(fr.next_answer, fr.entry);
        },
        .reinstall => |ri| try peer.session_state.installListener(ri.next_answer, ri.entry),
    }
}
