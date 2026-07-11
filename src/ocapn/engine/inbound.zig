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
/// On success the frame moves into the surfaced event (zero copy). On any
/// error the frame is released and session state is left unchanged: the event
/// is enqueued before `recordRecv`, with rollback if authority rejects it, so
/// session state never advances without a matching event and vice versa.
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
/// (`abort_projection.abortForError`), then close if the projection says
/// so. The abort frame is encoded directly (aborts are always admitted) and
/// appended to `outbound`; it bypasses `recordSend`, which would reject it
/// against the post-failure session state. Swallows its own allocation
/// failures so the original dispatch error is never masked, but still closes
/// when the projection requires it, since the decision to abort stands
/// regardless of whether the frame could be encoded.
pub fn emitAbortForError(self: *Peer, err: anyerror) void {
    self.recordFailure(err);
    const projected = abort_projection.abortForError(err) orelse return;
    defer if (projected.close) self.session_state.close();

    const message: model.Message = .{ .abort = .{
        .kind = projected.kind,
        .message = projected.message,
    } };
    var frame = codec.dispatch.encodeMessageForProfile(
        self.session_state.codec,
        self.allocator,
        self.session_state.wire_profile,
        message,
    ) catch return;
    self.outbound.push(self.allocator, frame) catch frame.deinit();
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
        // The dial-side identity pin (`Peer.expectPartnerKey`): a dialer that
        // resolved a key-designator locator admits only the key it dialed.
        // Checked here, at the same pre-open chokepoint as the signature,
        // because one byte-fed `feed` can carry the start-session and later
        // frames in a single chunk — a post-open check would let those frames
        // apply under the wrong identity before anyone looked.
        if (self.expected_partner_key) |expected| {
            if (!std.mem.eql(u8, expected.asBytes(), decoded_body.start_session.session_pubkey)) {
                return error.PartnerKeyMismatch;
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
    var v1_0_resolve: ?model.view.Resolve = null;
    var bootstrap_request: ?bootstrap.Request = null;
    if (decoded_body == .deliver) {
        switch (try classifyInboundDeliver(self, decoded_body.deliver)) {
            // Surfaces as a semantic `Resolve` (ADR-0010). The resolution is
            // a *borrowed* view over the deliver's args, applied through the
            // session's resolver-callback seam below — no owned
            // materialization. `recordResolverCallbackResolve` settles the
            // outbound answer and installs any `far` the fulfill introduces,
            // but does not store the resolution itself — the surfaced frame,
            // kept alive on the event queue, carries the value to the
            // application. The borrow stays valid because that frame outlives
            // the apply call.
            .v1_0_resolve => |answer| {
                tag = .resolve;
                answer_override = .{ .resolver_callback = answer };
                v1_0_resolve = .{
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

    try self.events.push(self.allocator, .{ .frame = frame, .tag = tag, .answer_override = answer_override, .codec = self.session_state.codec });
    stored = true;
    var appended = true;
    errdefer if (appended) {
        var removed = self.events.popBack().?;
        removed.frame.deinit();
    };

    if (v1_0_resolve) |resolve| {
        try self.session_state.recordResolverCallbackResolve(resolve);
    } else {
        try self.session_state.recordRecvView(decoded_body);
    }
    appended = false;

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
            .fetch => |req| try self.sendCopying(bootstrap.resolveForSwissnum(&self.session_state, req)),
            .deposit_gift => |req| {
                if (try bootstrap.resolveForDeposit(&self.session_state, self.giftRegistry(), req)) |msg| {
                    try self.sendCopying(msg);
                }
            },
            .withdraw_gift => |req| {
                switch (try bootstrap.resolveForWithdraw(self.allocator, &self.session_state, self.giftRegistry(), req)) {
                    .settled => |msg| try self.sendWithdrawSettled(msg),
                    // The gift's deposit has not arrived yet (it travels on
                    // a different session); park the withdraw, `step`
                    // settles it once the deposit lands.
                    .awaiting_deposit => {
                        if (self.pending_withdraws.items.len >= self.session_state.limits.max_pending_withdraws) {
                            return session.Error.PendingWithdrawCapExceeded;
                        }
                        const owned = try (model.view.Handoff{ .receive = req.receive }).toOwned(self.allocator);
                        errdefer model.freeHandoff(self.allocator, owned);
                        try self.pending_withdraws.append(self.allocator, .{
                            .handoff = owned,
                            .answer = req.answer,
                        });
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
    /// A V1.0 resolver-callback (ADR-0010) settling the inbound answer
    /// carried here; the frame surfaces as a semantic `Resolve`.
    v1_0_resolve: model.AnswerPosition,
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

/// Classify an inbound `op:deliver` into the one route it takes. The three
/// special-case probes live here in their load-bearing order, so the
/// precedence is data at the call site rather than comment-enforced
/// sequencing:
///
/// 1. V1.0 resolver classification runs first. Classification installs the
///    partner's resolver as a side effect, and a pipelined deliver carrying
///    `resolve_me_desc` needs that resolver installed before its frame is
///    released, so the V1.0 translation finds it when the drained call
///    resolves later.
/// 2. Pipelining runs after V1.0 classify: an inbound deliver whose target
///    is a still-pending answer is queued until that answer resolves
///    (ADR-0007).
/// 3. The bootstrap probe runs last, so a pipelined call is never mistaken
///    for a bootstrap fetch, and a resolver-only fetch has its virtual
///    answer installed before the bootstrap action is computed.
fn classifyInboundDeliver(self: *Peer, deliver: model.view.Deliver) !InboundDeliverClass {
    // A resolver-only deliver (no wire answer) has a virtual answer
    // allocated here; carry it to the `.ordinary` surface so a deliver to a
    // local object can be replied to. A pipelined or bootstrap deliver
    // consumes the answer through its own path (the queued call's answer,
    // `answerForResolverImport`), so the override only matters for ordinary.
    var ordinary_answer: ?model.AnswerPosition = null;
    if (self.session_state.needsV1_0Translation()) {
        switch (try v1_0.interceptInboundDeliver(self, deliver)) {
            .settles_answer => |answer| return .{ .v1_0_resolve = answer },
            .ordinary => |answer| ordinary_answer = answer,
        }
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
