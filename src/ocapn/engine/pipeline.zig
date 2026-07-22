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
//! you pass in (the queued call) and moves its heap into the result. It moves,
//! it doesn't copy. A listener fire owns nothing at all: the drain queues a POD
//! carrier and `Peer.step` borrows the stored resolution back to encode it.

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
pub const borrowedListenerFire = resolution_math.borrowedListenerFire;
pub const decomposeOutboundDeliver = resolution_math.decomposeOutboundDeliver;
pub const ListenerDrainAction = resolution_math.ListenerDrainAction;
pub const classifyListenerDrain = resolution_math.classifyListenerDrain;
const projectResolution = resolution_math.projectResolution;

/// Where an inbound `op:listen` anchors: an answer we owe, a third-party-hosted
/// import promise, a live object export, or nowhere (ignore).
const InboundListenClass = union(enum) {
    answer: model.AnswerPosition,
    third_party_import: model.ImportPosition,
    live_export: model.ExportPosition,
    ignore,
};

/// Classify `listen`'s target without mutating session state. A `.near` on an
/// export position that is also an inbound answer follows the answer path; a
/// third-party-backed promise export follows the import path; every other export
/// is a live-object listen. A `.far` on a non-third-party import is ignored.
fn classifyInboundListenTarget(peer: *Peer, listen: model.view.Listen) InboundListenClass {
    switch (listen.target) {
        .promise => |promise| return .{ .answer = promise.answer_position },
        // `desc:export N`: answer and export spaces can coincide (a promise
        // returned by the promise-resolver actor). Dispatch by which table
        // actually holds N — do not funnel exports through AnswerPosition.
        .near => |near| {
            const as_answer = near.export_position.reinterpret(model.AnswerPosition);
            if (peer.session_state.hasInboundAnswer(as_answer)) {
                return .{ .answer = as_answer };
            }
            // CapTP-normal listen on a received import-promise: the partner
            // encodes `<desc:export N>` (ADR-0010 → `.near`). When N is a
            // third-party-backed promise export (introducing-session proxy),
            // admit the same relayed-resolution listener path as `.far`.
            const as_import = model.ImportPosition.from(near.export_position.int());
            if (peer.session_state.isThirdPartyImport(as_import)) {
                return .{ .third_party_import = as_import };
            }
            return .{ .live_export = near.export_position };
        },
        // An `op:listen` on a handoff-imported promise (ADR-0009): the target
        // names one of our imports — post-flip (ADR-0010) `<desc:import-*>`
        // decodes to a `far` whose import_position is the import. Only a
        // third-party-hosted import admits a relayed-resolution listener;
        // a direct-partner import (or unknown id) is ignored.
        .far => |far| {
            if (!peer.session_state.isThirdPartyImport(far.import_position)) return .ignore;
            return .{ .third_party_import = far.import_position };
        },
        .sturdy, .broken => return .ignore,
    }
}

/// Register an inbound `op:listen`'s listener against the targeted answer so
/// our eventual `op:resolve` fires it (ADR-0007 § op:listen). Mirrors the
/// V1.0 resolver-import pattern: the partner introduces their listener object
/// as a descriptor we import; we reach it later via the matching `far`.
///
/// Validated before anything mutates, like its sibling
/// `maybeEnqueuePipelinedCall`: the session's `.listen` rule runs first, so an
/// unauthorized listen (feature not negotiated, unheld target) is refused
/// before any import or listener is installed.
///
/// A listen on a live object export (`local_value`) fires immediately with that
/// export — CapTP already-settled target — through the POD `listener_fire`
/// path. A listen on a bare unresolved promise export refuses loud: pancake exports no
/// free-standing resolvable promise, so nothing could ever fire it. An answer
/// we do not owe likewise refuses loud (`InvalidReference`).
pub fn maybeInstallInboundListener(peer: *Peer, listen: model.view.Listen) !void {
    try peer.session_state.validateInboundListen(listen);
    switch (classifyInboundListenTarget(peer, listen)) {
        .answer => |answer| try installAnswerListener(peer, answer, listen),
        .third_party_import => |import_position| try installThirdPartyImportListener(peer, import_position, listen),
        .live_export => |export_position| try installExportListener(peer, export_position, listen),
        .ignore => {},
    }
}

/// Install `listen`'s listener on inbound answer `answer`. An already-settled
/// answer fires this entry now; a pending answer installs for resolve drain.
fn listenerEntryFromListen(peer: *Peer, listen: model.view.Listen) !session.ListenerEntry {
    const position = listen.listener.position() orelse return session.Error.InvalidReference;
    try peer.session_state.registerImport(model.ImportPosition.from(position));
    return .{
        .listener = model.FarRef.object(position),
        .wants_partial = listen.wants_partial,
    };
}

/// Install (or immediately fire) a listener on a third-party-hosted import
/// promise. Shared by the `.far` (`desc:import-promise`) and `.near`
/// (`desc:export` on a proxied promise export) listen arms.
fn installThirdPartyImportListener(peer: *Peer, import_position: model.ImportPosition, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    // Answer-shaped late listen: fire this entry if the relay already
    // landed; otherwise install. Prior listeners were drained at record.
    // Import fires always deliver (no wants_partial re-anchor).
    if (peer.session_state.importedPromiseResolution(import_position)) |resolution| {
        const row = peer.session_state.findImportedPromise(import_position).?;
        try enqueueFire(
            peer,
            listener_entry.listener.import_position.int(),
            .{ .import = .{ .position = import_position, .row_id = row.cell.row_id } },
            resolution.*,
        );
    } else {
        try peer.session_state.installImportedPromiseListener(import_position, listener_entry);
    }
}

fn installAnswerListener(peer: *Peer, answer: model.AnswerPosition, listen: model.view.Listen) !void {
    const listener_entry = try listenerEntryFromListen(peer, listen);
    // A settled inbound answer always holds its stored resolution (the
    // `applySentResolve` invariant: status and resolution land together at
    // record time). Peek present → fire this entry; absent → install for
    // `fireListenersOnResolve`.
    if (peer.session_state.peekResolution(answer)) |resolution| {
        // The peek proved the row live, so its stamp is present; the drain
        // re-stamps answer fires anyway, guarding a mid-drain GC.
        const row_id = peer.session_state.inboundAnswerRowId(answer).?;
        try applyListenerDrain(peer, .{ .answer = .{ .position = answer, .row_id = row_id } }, resolution.*, classifyListenerDrain(listener_entry, resolution.*));
    } else {
        try peer.session_state.installListener(answer, listener_entry);
    }
}

/// Listen on one of our exports. A live object export (`local_value`) fires
/// immediately with `fulfill(near object)`. Every other export refuses loud:
/// pancake exports no free-standing resolvable promise (the only promise
/// exports it mints are resolver callbacks the partner delivers to, never
/// listens on), so a listen on a bare promise export names a subscription
/// nothing could ever fire — fail closed rather than accept it.
fn installExportListener(peer: *Peer, export_position: model.ExportPosition, listen: model.view.Listen) !void {
    if (peer.session_state.exportSlot(export_position)) |export_slot| {
        if (export_slot == .local_value) {
            try fireLiveObjectExportListener(peer, export_position, listen);
            return;
        }
    }
    return session.Error.InvalidReference;
}

/// CapTP already-settled object target: fire the listener once with
/// `fulfill(near object export)` through the same POD `listener_fire` carrier
/// path as answer/import listens — queue-time accounting on a borrowed stack
/// message, encode from the export position at `step`.
fn fireLiveObjectExportListener(peer: *Peer, export_position: model.ExportPosition, listen: model.view.Listen) !void {
    const position = listen.listener.position() orelse return session.Error.InvalidReference;
    try peer.session_state.registerImport(model.ImportPosition.from(position));
    try enqueueNearObjectFire(peer, position, export_position);
}

/// Queue one live-object-export listen fire: same reserve-record-push spine as
/// `enqueueFire`, but the payload is POD `fulfill(near)` — no answer or import
/// store row to borrow from at encode.
fn enqueueNearObjectFire(
    peer: *Peer,
    listener_position: u64,
    export_position: model.ExportPosition,
) !void {
    const resolution: model.Resolution = .{ .fulfill = .{
        .reference = .{ .near = model.NearRef.object(export_position.int()) },
    } };
    // The POD `fulfill(near)` is stack-lived for the call, which is all
    // `enqueueFire`'s `borrowedListenerFire` + `recordSend` accounting need.
    try enqueueFire(peer, listener_position, .{ .near_object = export_position }, resolution);
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
    if (!peer.session_state.hasInboundAnswer(answer)) return false;

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
/// Drain the local consequences of a just-sent `op:resolve`: pipelined calls,
/// anchored projections, then listeners — in that order (ADR-0007 § Queue
/// ownership and drain; ADR-0050 for projections).
pub fn drainResolveConsequences(peer: *Peer, resolve: model.Resolve) !void {
    try drainPipelinedCalls(peer, resolve);
    try drainProjections(peer, resolve);
    try fireListenersOnResolve(peer, resolve);
}

fn drainPipelinedCalls(peer: *Peer, resolve: model.Resolve) !void {
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
    new_answer: model.AnswerPosition,
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
    const source: ?model.AnswerPosition = switch (receiver) {
        .promise => |promise| promise.answer_position,
        .near => |near| if (peer.session_state.hasInboundAnswer(near.export_position.reinterpret(model.AnswerPosition)))
            near.export_position.reinterpret(model.AnswerPosition)
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
fn drainProjections(peer: *Peer, resolve: model.Resolve) !void {
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
fn anchorProjection(peer: *Peer, source: model.AnswerPosition, projection: session.Projection) !void {
    var current = source;
    var moving = projection;
    while (true) {
        if (!peer.session_state.hasInboundAnswer(current))
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
fn dispatchDrainedCall(peer: *Peer, answer: model.AnswerPosition, queued: model.Message, resolution: model.Resolution) !void {
    const maybe_reference: ?model.Reference = switch (resolution) {
        .fulfill => |arg| if (arg == .reference) arg.reference else null,
        .@"break" => null,
    };
    const reference = maybe_reference orelse
        return propagateBreakToDrainedCall(peer, queued, resolution);
    switch (reference) {
        .far => |far| try peer.send(rewriteDeliverTarget(peer.allocator, queued.deliver, .{ .far = far })),
        .near => |near| try deliverDrainedCallLocally(peer, queued, near),
        // Re-queued one message at a time — the drain dispatches per call, so
        // there is never a batch here and no container to allocate.
        .promise => |promise| try peer.session_state.requeuePipelinedCall(promise.answer_position, &.{answer}, queued),
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
            if (rmd.position()) |id| {
                break :blk peer.session_state.answerForResolverImport(model.ImportPosition.from(id));
            }
        }
        break :blk @as(?model.AnswerPosition, null);
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
        .{ .far = .{ .import_position = near.export_position.reinterpret(model.ImportPosition) } },
    );
    defer freeMessage(peer.allocator, rewritten);

    if (rewritten.deliver.answer) |call_answer| {
        try peer.session_state.installInboundAnswer(call_answer);
    }
    var frame = try codec.dispatch.encodeMessageForProfile(
        peer.session_state.codec,
        peer.allocator,
        peer.session_state.captp_version,
        rewritten,
    );
    errdefer frame.deinit();
    try peer.events.push(peer.allocator, .{ .frame = frame, .tag = .deliver, .codec = peer.session_state.codec, .allocator = peer.allocator });
    peer.local_delivery_depth += 1;
}

/// Drain the listeners registered against the answer a just-sent
/// `op:resolve` settles, firing each per the (resolution × `wants_partial`)
/// matrix (ADR-0007 § Listener fire matrix). Each fire queues a POD carrier on
/// `pending_send` (`applyListenerDrain`) so a later `step` encodes it from
/// the store; partial promises re-anchor the listener on the next answer.
/// `resolve.resolution` borrows the answer store (the caller peeked it), so
/// nothing here owns heap: the drained entries are POD `.far` values.
fn fireListenersOnResolve(peer: *Peer, resolve: model.Resolve) !void {
    // The row the resolve just settled; loop-invariant, and the whole drain
    // is moot without it. The per-fire freshness guard stays in
    // `enqueueDrainFire`, which re-stamps answer fires from the live row so a
    // GC'd answer mid-drain skips the fire while reinstall arms still run.
    const row_id = peer.session_state.inboundAnswerRowId(resolve.answer) orelse return;
    const listeners = try peer.session_state.takePipelinedListeners(resolve.answer);
    defer peer.allocator.free(listeners);

    for (listeners) |entry| {
        try applyListenerDrain(
            peer,
            .{ .answer = .{ .position = resolve.answer, .row_id = row_id } },
            resolve.resolution,
            classifyListenerDrain(entry, resolve.resolution),
        );
    }
}

/// Fire every listener installed on handoff-imported promise `import_position`
/// (ADR-0009) from its *stored* relayed resolution, draining the listener
/// list. Each fire queues a POD carrier stamped with the store row's identity
/// (`Outbound.listener_fire` targeting the import store); `step` borrows the stored payload back
/// to encode. A row with no stored resolution yet fires nothing (the
/// listeners stay installed for the relay to drain). Imported-promise
/// listeners fire unconditionally (no `wants_partial` re-anchor; a relayed
/// resolution is the settled value — it records once, a second relay is
/// refused). Also the late-listener immediate fire (ADR-0009): an `op:listen`
/// arriving after the relay lands installs its listener and calls straight in
/// here.
pub fn fireImportedPromiseListeners(peer: *Peer, import_position: model.ImportPosition) !void {
    const row = peer.session_state.findImportedPromise(import_position) orelse return;
    const resolution = row.cell.resolution orelse return;
    const listeners = try peer.session_state.takeImportedPromiseListeners(import_position);
    defer peer.allocator.free(listeners);
    // Relayed resolutions are final (record-once); fire every listener, no
    // wants_partial re-anchor.
    try fireTakenListeners(peer, .{ .import = .{ .position = import_position, .row_id = row.cell.row_id } }, resolution, listeners, .always_fire);
}

const FireTakenPolicy = enum { always_fire, classify };

fn fireTakenListeners(
    peer: *Peer,
    target: engine.FireTarget,
    resolution: model.Resolution,
    listeners: []const session.ListenerEntry,
    policy: FireTakenPolicy,
) !void {
    for (listeners) |entry| {
        switch (policy) {
            .always_fire => try enqueueFire(
                peer,
                entry.listener.import_position.int(),
                target,
                resolution,
            ),
            .classify => try applyListenerDrain(
                peer,
                target,
                resolution,
                classifyListenerDrain(entry, resolution),
            ),
        }
    }
}

/// Queue one listener fire against a stored resolution: session accounting on
/// the borrowed stack message (the wire mentions the payload once more, so its
/// `near` export mentions take the same wire-delta retain an owned fire took),
/// then the POD carrier, whose store-backed target arm carries the row's
/// identity stamp so a released-and-reused position can never satisfy it at
/// encode. Reserve-then-record-then-push, the sent-resolve order
/// (`Peer.enqueueRecorded`'s resolve arm): the accounting is committed by an
/// infallible push, never an undo. `resolution` borrows the store `target`
/// names (the inbound answer store, or the third-party imported-promise store
/// of ADR-0009), which owns the payload the carrier's encode reads back; that
/// value cannot change while the carrier is queued (each store records its
/// resolution once).
fn enqueueFire(
    peer: *Peer,
    listener_position: u64,
    target: engine.FireTarget,
    resolution: model.Resolution,
) !void {
    var args: [2]model.Argument = undefined;
    const borrowed = borrowedListenerFire(listener_position, resolution, &args);
    try peer.pending_send.ensureUnusedCapacityForOne(peer.allocator);
    // `recordSend` borrows a deliver (it consumes only the resolve arm), so
    // the stack message is safe on every outcome.
    try peer.session_state.recordSend(borrowed);
    peer.pending_send.pushAssumeCapacity(.{ .listener_fire = .{
        .listener_position = listener_position,
        .target = target,
    } });
}

/// Apply one `ListenerDrainAction` against a stored resolution: fire queues a
/// POD carrier; re-anchor moves the entry onto the next inbound answer.
/// Answer fires re-stamp from the live row so a GC'd answer mid-drain skips
/// the fire but still reinstalls.
fn applyListenerDrain(
    peer: *Peer,
    target: engine.FireTarget,
    resolution: model.Resolution,
    action: ListenerDrainAction,
) !void {
    switch (action) {
        .fire => |position| try enqueueDrainFire(peer, position, target, resolution),
        .fire_and_reinstall => |fr| {
            try enqueueDrainFire(peer, fr.fire, target, resolution);
            try peer.session_state.installListener(fr.next_answer, fr.entry);
        },
        .reinstall => |ri| try peer.session_state.installListener(ri.next_answer, ri.entry),
    }
}

fn enqueueDrainFire(
    peer: *Peer,
    listener_position: u64,
    target: engine.FireTarget,
    resolution: model.Resolution,
) !void {
    const stamped: engine.FireTarget = switch (target) {
        // Re-stamp from the live row: a GC'd answer mid-drain skips the fire
        // (the reinstall arms above still run).
        .answer => |answer| .{ .answer = .{
            .position = answer.position,
            .row_id = peer.session_state.inboundAnswerRowId(answer.position) orelse return,
        } },
        .import => target,
        .near_object => unreachable, // live-object export listens fire immediately, never through a drain
    };
    try enqueueFire(peer, listener_position, stamped, resolution);
}
