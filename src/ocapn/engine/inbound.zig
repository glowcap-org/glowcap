//! The inbound receive/dispatch path: how one decoded frame becomes session
//! state plus a surfaced event, and how a failure fails loud.
//!
//! These are the heavy internals of `Peer`'s receive boundary, factored out of
//! `mod.zig` so the peer object holds construction, the send path, and the queue
//! surface while this file owns the parse-validate-apply spine. They are free
//! functions over `*Peer` (the same shape `v1_0` and `pipeline` use), not
//! methods, because the cluster is one cohesive responsibility — the inbound
//! seam — and reads better named than scattered through the struct body. The
//! public entry methods (`recvBorrowed`, `recvStreamPrefix`, `step`) stay on
//! `Peer` and call in here.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const abort_projection = @import("abort_projection.zig");
const bootstrap = @import("bootstrap.zig");
const events = @import("events.zig");
const pipeline = @import("pipeline.zig");
const v1_0 = @import("v1_0.zig");

const codec = @import("codec");

/// Dispatch an owned inbound frame, taking ownership.
///
/// On success the frame moves into the surfaced event (zero copy). Before
/// authority applies, any error releases the frame and leaves session state
/// unchanged: the event is enqueued before `recordRecv`, with rollback if
/// authority rejects it, so session state never advances without a matching
/// event. Once apply has committed, a responder or projection failure (a
/// projection anchor refusal, a bootstrap responder cap or send refusal)
/// keeps the surfaced event and the recorded state, which match what was
/// admitted, and projects the abort like any other dispatch failure.
///
/// A rejection that names a protocol violation (codec-malformed frame or a
/// session state-machine refusal) projects to a typed outbound `op:abort`
/// and closes the session (`abort_projection`) before the error surfaces:
/// the partner sees a fail-loud abort, and the caller still receives the
/// typed error (and should flush `takeOutbound` to send the abort frame).
pub fn dispatchOwnedFrame(self: *Peer, frame_in: foundation.Frame) !void {
    return dispatchOwnedFrameInner(self, frame_in) catch |err| {
        emitAbortForError(self, err);
        return err;
    };
}

/// Best-effort emit of the outbound `op:abort` an inbound failure projects to
/// (`abort_projection.abortForError`). Shares `Peer.commitAbortOutbound` with
/// app-queued aborts so a successful queue push applies the projected CapTP
/// disposition. Bypasses `recordSend`, which would reject against post-failure
/// session state. Swallows encode/push failures so the original dispatch
/// error is never masked; when the disposition is `.close`, still closes
/// even if the abort frame could not be queued.
pub fn emitAbortForError(self: *Peer, err: anyerror) void {
    self.recordFailure(err);
    const projected = abort_projection.abortForError(err) orelse return;
    self.commitAbortOutbound(.{
        .kind = projected.kind,
        .message = projected.message,
    }, projected.disposition) catch {
        if (projected.disposition == .close) self.closeSession();
    };
}

pub fn dispatchOwnedFrameInner(self: *Peer, frame_in: foundation.Frame) !void {
    const decoded_body = codec.dispatch.decodeBody(self.session_state.codec, frame_in.view()) catch |err| {
        var frame = frame_in;
        frame.deinit();
        return err;
    };
    try applyDecodedOwnedFrame(self, frame_in, decoded_body);
}

/// Apply an already-decoded inbound frame: install listeners, enqueue a
/// pipelined call, surface the event, and record authority. This is the
/// shared tail of the owned-frame boundary (`dispatchOwnedFrameInner`) and the
/// byte-stream framer (`recvStreamPrefix`), so an inbound frame is parsed
/// exactly once regardless of how it arrived.
///
/// `decoded_body` may borrow `frame_in`'s own bytes (frame boundary) or a
/// separate stream buffer that outlives this call (`recvStreamPrefix`). It
/// must stay valid until apply completes; afterwards the retained event owns
/// only `frame_in` and the borrow is dropped.
pub fn applyDecodedOwnedFrame(self: *Peer, frame_in: foundation.Frame, decoded_body: model.view.Body) !void {
    var frame = frame_in;
    var stored = false;
    errdefer if (!stored) frame.deinit();

    // Apply the session's state-admission gate before any authority mutation
    // below. The pipelined-call enqueue, listener install, and V1.0 resolver
    // registration all run ahead of `recordRecvView`/`recordRecv`, and the
    // pipelined path returns without ever reaching them, so without this a
    // closed (or negotiating) session would mutate authority for an inbound
    // kind it must refuse. `recordRecv*` re-checks the gate; the check is pure.
    try self.session_state.admits(decoded_body);

    // A verifying peer authenticates the partner's `op:start-session` before
    // learning its key: real Ed25519 over the captured location bytes. The
    // session core runs no crypto, so this engine-boundary check gates the
    // handshake; a failure returns `InvalidStartSessionSignature`, which
    // projects an abort and leaves the session un-opened (the key is never
    // learned, since `recordRecvView` below does not run).
    if (decoded_body == .start_session) {
        if (self.verify_partner_handshake) {
            try engine.verifyPartnerStartSession(self.allocator, decoded_body.start_session);
        }
        // The durable-key-attestation contract (ADR-0097): on a transport
        // whose key designator has no lower-layer proof, a hello claiming a
        // key-designator location must prove the durable key authorized this
        // session key. Same chokepoint, same one-chunk rationale as the pin.
        if (self.require_partner_attestation) {
            try engine.verifyPartnerAttestation(decoded_body.start_session);
        }
        // The durable-identity claim check (ADR-0097): a hello may claim the
        // identity this session expects, or none at all — never someone
        // else's. Checked at this same pre-open chokepoint because one
        // byte-fed `feed` can carry the start-session and later frames in a
        // single chunk, and a post-open check would let those frames apply
        // under the wrong identity before anyone looked. `session_pubkey` is
        // deliberately unconstrained: each connection signs with its own key,
        // so comparing it against a durable name proves nothing.
        if (self.expected_durable_key) |verified| {
            const claimed = decoded_body.start_session.acceptable_location.designator;
            if (foundation.crypto.PeerKey.fromDesignator(claimed) != null and
                !std.mem.eql(u8, claimed, &verified.toDesignator()))
            {
                return error.PartnerDesignatorMismatch;
            }
        }
    }

    // An inbound `op:listen` against one of our pending inbound answers
    // registers the listener so the resolution fires it (ADR-0007 §
    // op:listen). Installed before the event/`recordRecv` so a refusal
    // leaves nothing surfaced. Non-promise targets and listens on unknown
    // answers fall through to ordinary recv handling.
    if (decoded_body == .listen) {
        try pipeline.maybeInstallInboundListener(self, decoded_body.listen);
    }

    // An inbound deliver takes exactly one of four routes; the classifier
    // holds the probe order, so the precedence is data here, not call-site
    // ordering (see `classifyInboundDeliver`).
    var tag = eventKindFromBody(decoded_body);
    var answer_override: events.AnswerOverride = .none;
    var resolver_callback_resolve: ?model.view.Resolve = null;
    var bootstrap_request: ?bootstrap.Request = null;
    if (decoded_body == .deliver) {
        switch (try classifyInboundDeliver(self, decoded_body.deliver)) {
            // Surfaces as a semantic `Resolve` (ADR-0010, ADR-0095). The resolution is
            // a *borrowed* view over the deliver's args, applied through the
            // session's resolver-callback seam below — no owned
            // materialization. `recordResolverCallbackResolve` settles the
            // outbound answer and installs any `far` the fulfill introduces,
            // but does not store the resolution itself — the surfaced frame,
            // kept alive on the event queue, carries the value to the
            // application. The borrow stays valid because that frame outlives
            // the apply call.
            .resolver_callback_resolve => |answer| {
                tag = .resolve;
                answer_override = .{ .resolver_callback = answer };
                resolver_callback_resolve = .{
                    .answer = answer,
                    .resolution = try events.resolutionFromResolverCallback(decoded_body.deliver.args),
                };
            },
            // Queued or redirected against the answer it pipelined on
            // (ADR-0007); nothing surfaces for this frame.
            .pipelined => {
                frame.deinit();
                return;
            },
            // Answered automatically once authority records the deliver
            // (ADR-0006 responder half); the action applies below.
            .bootstrap => |action| bootstrap_request = action,
            // A resolver-only deliver carries the virtual answer the
            // classifier allocated, so the surfaced deliver can be replied
            // to; an answered deliver carries null (the frame has the answer).
            .ordinary => |answer| {
                if (answer) |a| answer_override = .{ .virtual_deliver = a };
            },
        }
    }

    try self.events.push(self.allocator, .{
        .frame = frame,
        .tag = tag,
        .answer_override = answer_override,
        .codec = self.session_state.codec,
        .allocator = self.allocator,
    });
    stored = true;
    var appended = true;
    errdefer if (appended) {
        var removed = self.events.popBack().?;
        removed.frame.deinit();
    };

    // The introduced-import record the validate walk fills and apply
    // consumes for an ordinary deliver (`session.validate.IntroducedImports`),
    // captured here so its far positions can be patched onto the event just
    // pushed above, for post-dispatch stateless GC
    // (`driver.core.gc.emitExportsForDeliver`) instead of a second walk of
    // the same argument tree once the event is polled. Backed by
    // `self.allocator`, not `recv_scratch`: `recordRecvView`'s own turn-
    // scratch record resets before that call even returns, too short-lived
    // to reach the event. Every other surfaced kind still runs through
    // `recordRecvView`'s throwaway record, unchanged.
    var introduced: session.validate.IntroducedImports = .init(self.allocator, self.session_state.limits);
    defer introduced.deinit();

    const was_closed = self.session_state.state == .closed;
    if (resolver_callback_resolve) |resolve| {
        try self.session_state.recordResolverCallbackResolve(resolve);
    } else if (tag == .deliver) {
        try self.session_state.recordInboundDeliverView(decoded_body, &introduced);
    } else {
        try self.session_state.recordRecvView(decoded_body);
    }
    if (!was_closed and self.session_state.state == .closed) self.retireClosedSessionAuthority();
    appended = false;

    // Patch the far mentions onto the just-pushed event when the deliver
    // introduced at least one (the common case introduces none, so no
    // allocation then). Apply has already committed by this point, so a
    // copy failure is swallowed rather than propagated — failing loud here
    // would misreport a successful receive as a failed one. The event is
    // still correct either way; `gc` just falls back to its own walk for
    // this one deliver when the field stays null. Nothing between the push
    // above and here can grow `self.events`, so the back pointer is stable.
    if (introduced.mentions.items.len != 0) {
        if (self.allocator.dupe(model.ImportPosition, introduced.mentions.items)) |dup| {
            self.events.backPtr().?.introduced_far_imports = dup;
        } else |_| {}
    }

    // op:get / op:index / op:untag responder (ADR-0050): apply above
    // installed the projected answer; anchor the projection on the
    // receiver. The view's field/tag bytes borrow the frame, so the owned
    // dupe happens here, while the borrow is still valid.
    switch (decoded_body) {
        .get => |get| try pipeline.respondToProjection(self, get.receiver, .{ .field = get.field }, get.answer),
        .index => |idx| try pipeline.respondToProjection(self, idx.receiver, .{ .index = idx.index }, idx.answer),
        .untag => |untag| try pipeline.respondToProjection(self, untag.receiver, .{ .untag = untag.tag }, untag.answer),
        else => {},
    }

    if (bootstrap_request) |action| {
        switch (action) {
            .fetch => |req| {
                const scope = if (self.node_services) |services| services.peer_id else null;
                try self.sendCopying(try bootstrap.resolveForSwissnum(&self.session_state, self.localObjectProjection(), scope, req));
            },
            .deposit_gift => |req| {
                const scope = if (self.node_services) |services| services.peer_id else null;
                const response = try bootstrap.resolveForDeposit(&self.session_state, self.giftRegistry(), self.localObjectProjection(), scope, req);
                if (self.node_services) |services| services.giftDeposited(req.gift_id);
                if (response) |msg| {
                    try self.sendCopying(msg);
                }
            },
            .withdraw_gift => |req| {
                const scope = if (self.node_services) |services| services.peer_id else null;
                if (self.pendingWithdrawCount() >= self.session_state.limits.max_pending_withdraws) {
                    const gifter = bootstrap.liveGifterSession(self.gifterSessionResolver(), req.receive.signed_give);
                    if (gifter == null or !gifter.?.gifts.giftLive(req.receive.signed_give.gift_id)) {
                        return session.Error.PendingWithdrawCapExceeded;
                    }
                }
                switch (try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, self.giftRegistry(), self.gifterSessionResolver(), self.localObjectProjection(), scope, req)) {
                    .settled => |msg| try self.sendWithdrawSettled(msg),
                    // The gift's deposit has not arrived yet (it travels on
                    // a different session); park the withdraw, `step`
                    // settles it once the deposit lands.
                    .awaiting_deposit => |admission| {
                        if (self.pendingWithdrawCount() >= self.session_state.limits.max_pending_withdraws) {
                            var receive = admission.receive;
                            receive.deinit(self.allocator);
                            return session.Error.PendingWithdrawCapExceeded;
                        }
                        var receive = admission.receive;
                        errdefer receive.deinit(self.allocator);
                        try self.parkPendingWithdraw(receive, req.answer, admission.gifter_peer_id);
                    },
                }
            },
        }
    }
}

/// The one route an inbound `op:deliver` takes, decided by
/// `classifyInboundDeliver`. The variants are mutually exclusive by
/// construction: a resolver-callback targets a resolver export, a pipelined
/// call targets a `desc:answer` promise, and a bootstrap deliver targets the
/// bootstrap export, three disjoint target shapes.
const InboundDeliverClass = union(enum) {
    /// A deliver to one of our resolver exports, settling the outbound answer
    /// carried here; the frame surfaces as a semantic `Resolve`.
    resolver_callback_resolve: model.AnswerPosition,
    /// Pipelined against an answer we owe (ADR-0007): the call was queued or
    /// redirected during classification, so the frame surfaces nothing.
    pipelined,
    /// A bootstrap-protocol deliver (ADR-0006): the caller applies the
    /// action after authority records the deliver.
    bootstrap: bootstrap.Request,
    /// An ordinary deliver, surfaced to the application. The optional answer
    /// is the virtual inbound answer the V1.0 classifier allocated for a
    /// resolver-only deliver (a `resolve_me_desc` with no wire
    /// answer-position); the surfaced deliver carries it so the
    /// application's reply routes back through the resolver callback. Null
    /// for an ordinary deliver whose answer (if any) the frame already
    /// carries.
    ordinary: ?model.AnswerPosition,
};

/// Classify an inbound `op:deliver` into the one route it takes. The four
/// special-case probes live here in their load-bearing order, so the
/// precedence is data at the call site rather than comment-enforced
/// sequencing:
///
/// 1. The resolver-export probe runs first, and runs on every session
///    (ADR-0095). A deliver to an export we minted as a resolver settles the
///    answer that export was bound to, whatever else the position might also
///    look like.
/// 2. V1.0 resolver registration runs next. It installs the partner's
///    advertised resolver as a side effect, and a pipelined deliver carrying
///    `resolve_me_desc` needs that resolver installed before its frame is
///    released, so the V1.0 translation finds it when the drained call
///    resolves later.
/// 3. Pipelining runs after that registration: an inbound deliver whose target
///    is a still-pending answer is queued until that answer resolves
///    (ADR-0007).
/// 4. The bootstrap probe runs last, so a pipelined call is never mistaken
///    for a bootstrap fetch, and a resolver-only fetch has its virtual
///    answer installed before the bootstrap action is computed.
fn classifyInboundDeliver(self: *Peer, deliver: model.view.Deliver) !InboundDeliverClass {
    // A resolver export settles by an `['fulfill|'break, payload]` deliver on
    // every negotiated version, so this probe carries no version gate: the
    // V1.0 resolver callback and the `op:listen` notification a listener
    // export receives are the same wire shape (ADR-0095). Only a `.near`
    // reaches the link, so a partner-named `.far` in the same integer space
    // cannot key it.
    if (deliver.target.exportPosition()) |position| {
        if (self.session_state.answerForResolverExport(position)) |answer| {
            return .{ .resolver_callback_resolve = answer };
        }
    }
    // A resolver-only deliver (no wire answer) has a virtual answer
    // allocated here; carry it to the `.ordinary` surface so a deliver to a
    // local object can be replied to. A pipelined or bootstrap deliver
    // consumes the answer through its own path (the queued call's answer,
    // `answerForResolverImport`), so the override only matters for ordinary.
    var ordinary_answer: ?model.AnswerPosition = null;
    if (self.session_state.needsV1_0Translation()) {
        ordinary_answer = try v1_0.registerPartnerResolver(self, deliver);
    }
    if (try pipeline.maybeEnqueuePipelinedCall(self, deliver)) {
        return .pipelined;
    }
    if (try bootstrap.pendingBootstrapAction(deliver, &self.session_state)) |action| {
        return .{ .bootstrap = action };
    }
    return .{ .ordinary = ordinary_answer };
}

/// The `EventKind` a decoded body surfaces as, a 1:1 body-tag mapping. The one
/// re-tag (a V1.0 resolver-callback deliver surfacing as `.resolve`) is decided
/// by the inbound classifier (`classifyInboundDeliver`), not here.
fn eventKindFromBody(body: model.view.Body) events.EventKind {
    return switch (body) {
        .deliver => .deliver,
        .resolve => .resolve,
        .gc_export => .gc_export,
        .gc_answer => .gc_answer,
        .handoff => .handoff,
        .start_session => .start_session,
        .abort => .abort,
        .listen => .listen,
        .get => .get,
        .index => .index,
        .untag => .untag,
    };
}
