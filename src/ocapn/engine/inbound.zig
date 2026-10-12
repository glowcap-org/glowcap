//! The inbound receive/dispatch path: how one decoded frame becomes session
//! state plus a surfaced event, and how a failure fails loud.
//!
//! These are the heavy internals of `Peer`'s receive boundary, factored out of
//! `mod.zig` so the peer object holds construction, the send path, and the queue
//! surface while this file owns the parse-validate-apply spine. They are free
//! functions over `*Peer` (the same shape `v1_0` and `pipeline` use), not
//! methods, because the cluster is one cohesive responsibility, the inbound
//! seam, and reads better named than scattered through the struct body. The
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
const deliver_route = @import("inbound/deliver_route.zig");
const events = @import("events.zig");
const outbound = @import("outbound.zig");
const pipeline = @import("pipeline.zig");
const shortening = @import("inbound_shortening.zig");

const codec = @import("codec");

const PreparedShortening = shortening.PreparedShortening;
const PreparedShorteningCallback = shortening.PreparedShorteningCallback;
const ShorteningCallbackPlan = shortening.ShorteningCallbackPlan;
const PreparedOutboundMessage = shortening.PreparedOutboundMessage;
const prepareIntroducedPromiseShortening = shortening.prepareIntroducedPromiseShortening;
const commitPreparedShortening = shortening.commitPreparedShortening;
const prepareIntroducedImportReleases = shortening.prepareIntroducedImportReleases;
const commitPreparedImportRelease = shortening.commitPreparedImportRelease;

/// One inbound pipelined deliver after its destination and maintenance are
/// prepared. It owns the prepared call, resolver link, and shortening work.
/// Commit borrows the validated frame view and its import record only long
/// enough to apply authority before publishing those consequences.
const PreparedPipelinedDeliver = struct {
    call: pipeline.PreparedPipelinedCall,
    resolver: ?session.PreparedInboundResolver,
    shortening: PreparedShortening,

    fn abandon(self: *PreparedPipelinedDeliver, peer: *Peer) void {
        self.shortening.abandon(peer);
        self.call.abandon(peer);
    }

    fn commit(
        self: *PreparedPipelinedDeliver,
        peer: *Peer,
        deliver: model.view.Deliver,
        introduced: *const session.validate.IntroducedImports,
    ) !void {
        try peer.session_state.applyValidatedInboundDeliverView(deliver, introduced);
        if (self.resolver) |prepared| prepared.commit(&peer.session_state);
        commitPreparedShortening(peer, &self.shortening);
        try self.call.commit(peer);
    }
};

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
        failOwnedDispatch(self, err);
        return err;
    };
}

/// Dispatch a frame the transport boundary already decoded. Packet and stream
/// ingress use this to preserve one consumed-frame failure contract without
/// decoding the same bytes again.
pub fn dispatchDecodedOwnedFrame(
    self: *Peer,
    frame: foundation.Frame,
    decoded: model.view.Body,
    wire_profile: model.CaptpVersion,
) !void {
    return applyDecodedOwnedFrame(self, frame, decoded, wire_profile) catch |err| {
        failOwnedDispatch(self, err);
        return err;
    };
}

fn failOwnedDispatch(self: *Peer, err: anyerror) void {
    emitAbortForError(self, err);
    // The owned frame is consumed on every outcome. If the error carries no
    // protocol abort (notably allocation failure), there is still no frame
    // left to retry and post-admission effects may already be committed.
    // Continuing this session would pretend the frame never existed.
    if (!self.sessionIsClosed()) self.closeSession();
}

/// Emit the outbound `op:abort` an inbound failure projects to
/// (`abort_projection.abortForError`). Shares `Peer.commitAbortOutbound` with
/// app-queued aborts so a successful queue push closes CapTP. Bypasses
/// `recordSend`, which would reject against post-failure
/// session state. An encode/push failure is recorded beside the originating
/// failure, which remains the returned authority, and closes the session.
pub fn emitAbortForError(self: *Peer, err: anyerror) void {
    self.recordFailure(err);
    const projected = abort_projection.abortForError(err) orelse return;
    self.commitAbortOutbound(.{
        .kind = projected.kind,
        .message = projected.message,
    }) catch |delivery_err| {
        self.recordAbortDeliveryFailure(delivery_err);
        self.closeSession();
    };
}

pub fn dispatchOwnedFrameInner(self: *Peer, frame_in: foundation.Frame) !void {
    checkFrameSize(self, frame_in.bytes().len) catch |err| {
        var frame = frame_in;
        frame.deinit();
        return err;
    };
    const wire_profile = self.inboundProfile();
    const decoded_body = codec.dispatch.decodeBodyForProfile(
        self.inboundCodec(),
        wire_profile,
        frame_in.view(),
    ) catch |err| {
        var frame = frame_in;
        frame.deinit();
        return err;
    };
    try applyDecodedOwnedFrame(self, frame_in, decoded_body, wire_profile);
}

/// Every ingress form shares this inclusive frame limit. Whole-frame callers
/// check before copying or queueing. Dispatch rechecks queued frames because
/// the caller may have lowered the session limit since admission.
pub fn checkFrameSize(self: *const Peer, size: usize) error{FrameTooLarge}!void {
    if (size > self.limits().max_frame_bytes) return error.FrameTooLarge;
}

/// Enforce the durable identity a dial named against the partner's hello claim.
/// This is target matching, not authentication: channel authentication is a
/// separate fact supplied by the realizer and reported through provenance.
fn checkPartnerDurableClaim(self: *Peer, ss: model.view.StartSession) !void {
    if (self.demandedPartnerKey()) |demanded| {
        // The hello's locator is the partner's selected route, not a record of
        // this channel. Only a key-designator route makes a durable identity
        // claim to compare with the key this dial named. An address route is a
        // legitimate proxy or ingress; authenticated realizers prove the
        // channel separately, while raw keyed transports trust their netlayer
        // to have honored the dial target (ADR-0109).
        const scheme = (if (self.node_services) |services|
            services.designatorScheme(ss.acceptable_location.transport)
        else if (model.transport.parseKnown(ss.acceptable_location.transport)) |known|
            known.metadata().designator_scheme
        else
            null) orelse return error.UnknownTransportSemantics;
        if (scheme != .key) return;
        const claimed_key = foundation.crypto.PeerKey.fromDesignator(
            ss.acceptable_location.designator,
        ) orelse return error.PartnerDesignatorMismatch;
        if (!demanded.eql(claimed_key)) return error.PartnerDesignatorMismatch;
    }
}

/// Apply an already-decoded inbound frame: install listeners, enqueue a
/// pipelined call, surface the event, and record authority. This is the
/// shared tail of the owned-frame boundary (`dispatchOwnedFrameInner`) and the
/// byte-stream framer (`recvStreamPrefix`), so an inbound frame is parsed
/// exactly once regardless of how it arrived.
///
/// `decoded_body` may borrow `frame_in`'s own bytes (frame boundary) or a
/// separate stream buffer that outlives this call (`recvStreamPrefix`). It
/// must stay valid until apply completes. Afterwards the queued row owns only
/// `frame_in`, and `Peer.pollEvent` decodes it once more when it surfaces.
fn applyDecodedOwnedFrame(
    self: *Peer,
    frame_in: foundation.Frame,
    decoded_body: model.view.Body,
    wire_profile: model.CaptpVersion,
) !void {
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

    var canonical_partner_location: ?[]u8 = null;
    defer if (canonical_partner_location) |bytes| self.allocator.free(bytes);
    var recorded_body = decoded_body;
    if (recorded_body == .start_session and recorded_body.start_session.acceptable_location_raw == null) {
        canonical_partner_location = try engine.encodePeerLocatorViewRecord(
            self.allocator,
            recorded_body.start_session.acceptable_location,
        );
        recorded_body.start_session.acceptable_location_raw = canonical_partner_location.?;
    }

    // A verifying peer authenticates the partner's `op:start-session` before
    // learning its key: real Ed25519 over the captured location bytes. The
    // session core runs no crypto, so this engine-boundary check gates the
    // handshake; a failure returns `InvalidStartSessionSignature`, which
    // projects an abort and leaves the session un-opened (the key is never
    // learned, since `recordRecvView` below does not run).
    //
    // Both checks below weigh the handshake hello this session is still
    // waiting for, and only that one. A duplicate or post-open hello is
    // refused by `validateStartSession` in `recordRecvView` further down, so
    // weighing it here would spend an Ed25519 verification on a frame already
    // destined for refusal, and let it revise identity state the accepted
    // hello had already decided.
    if (decoded_body == .start_session and self.session_state.awaitsPartnerHello()) {
        if (self.verify_partner_handshake) {
            try engine.verifyPartnerStartSession(self.allocator, recorded_body.start_session);
        }
        // What this side demands of the partner's durable claim (ADR-0105),
        // at this same pre-open chokepoint: one byte-fed `feed` can carry the
        // start-session and later frames in a single chunk, and a post-open
        // check would let those frames apply under the wrong identity before
        // anyone looked.
        try checkPartnerDurableClaim(self, recorded_body.start_session);
    }

    // An inbound `op:listen` against one of our pending inbound answers
    // registers the listener so the resolution fires it (ADR-0007 §
    // op:listen). Installed before the event/`recordRecv` so a refusal
    // leaves nothing surfaced. Non-promise targets and listens on unknown
    // answers fall through to ordinary recv handling.
    if (decoded_body == .listen) {
        try pipeline.maybeInstallInboundListener(self, decoded_body.listen);
    }

    // The introduced-import record is filled by deliver validation before any
    // deliver-specific authority mutation and consumed by ordinary/bootstrap
    // apply below. It also survives long enough to annotate the surfaced event
    // for stateless GC without walking the argument tree again.
    var introduced: session.validate.IntroducedImports = .init(self.allocator, self.session_state.limits);
    defer introduced.deinit();

    // An inbound deliver takes exactly one of four routes; the classifier
    // holds the probe order and the validate-before-mutate boundary.
    var tag = eventKindFromBody(decoded_body);
    var answer_override: events.AnswerOverride = .none;
    var resolver_callback_resolve: ?model.view.Resolve = null;
    var shortening_callback: ?ShorteningCallbackPlan = null;
    var retired_resolver_callback: ?model.ExportPosition = null;
    var node_resolver_callback: ?model.ExportPosition = null;
    var bootstrap_request: ?bootstrap.Request = null;
    var classified_deliver: ?deliver_route.Classification = null;
    defer if (classified_deliver) |*classified| classified.abandon(self);
    if (decoded_body == .deliver) {
        classified_deliver = try deliver_route.classify(self, decoded_body.deliver, &introduced);
        switch (classified_deliver.?.route) {
            // Surfaces as a semantic `Resolve` (ADR-0010, ADR-0095). The resolution is
            // a *borrowed* view over the deliver's args, applied through the
            // session's resolver-callback seam below, no owned
            // materialization. `recordResolverCallbackResolve` settles the
            // outbound answer and installs any `far` the fulfill introduces,
            // but does not store the resolution itself, the surfaced frame,
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
                try self.session_state.validateResolverCallbackResolve(resolver_callback_resolve.?, &introduced);
                try self.session_state.validatePromiseSettlingFollowers(answer);
            },
            .shortening_callback => |resolver| shortening_callback = try ShorteningCallbackPlan.init(
                self,
                resolver,
                decoded_body.deliver,
                &introduced,
            ),
            .retired_resolver_callback => |resolver| retired_resolver_callback = resolver,
            .node_resolver_callback => |resolver| node_resolver_callback = resolver,
            // Queued or redirected against the answer it pipelined on
            // (ADR-0007). Commit waits below for the same shortening and
            // maintenance preparation every other accepted deliver receives.
            .pipelined => {},
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

    // Callback routes validate through specialized semantic views after
    // classification and still need the shared import preflight. Ordinary
    // routes already reserved the full answer/import apply before retaining
    // their destination; do not replay that O(reference-count) capacity pass.
    if (classified_deliver != null and
        classified_deliver.?.needsIntroducedImportPreparation())
        try self.session_state.prepareIntroducedImports(&introduced);

    // Preparation below may hold several reservations while authority is
    // validated and committed as one transaction. Reserve the whole possible
    // batch once; a per-row reservation cannot express slots for rows that
    // have not been appended yet.
    const pending_preparation_count = if (retired_resolver_callback != null)
        @as(usize, 1)
    else if (shortening_callback) |callback|
        callback.pendingPreparationCount(&introduced)
    else
        introduced.promise_mentions.items.len;
    var pending_batch = try self.beginPendingBatch(pending_preparation_count);

    // Acquire every resolver row, queue slot, and owned GC slice before apply.
    // Once the received frame commits, the required protocol maintenance must
    // not become optional under allocator pressure.
    var prepared_shortening: ?PreparedShortening = null;
    var prepared_pipelined_deliver: ?PreparedPipelinedDeliver = null;
    defer if (prepared_pipelined_deliver) |*prepared| prepared.abandon(self);
    var prepared_shortening_callback: ?PreparedShorteningCallback = null;
    var prepared_retired_release: ?PreparedOutboundMessage = null;
    if (retired_resolver_callback != null) {
        prepared_shortening = .{};
        prepared_retired_release = try prepareIntroducedImportReleases(self, &pending_batch, introduced.mentions.items);
    } else if (shortening_callback) |callback| {
        prepared_shortening_callback = try callback.prepare(self, &pending_batch, &introduced);
    } else {
        prepared_shortening = try prepareIntroducedPromiseShortening(self, &pending_batch, &introduced);
    }
    defer {
        if (prepared_shortening_callback) |*prepared| prepared.abandon(self);
        if (prepared_shortening) |*prepared| prepared.abandon(self);
        if (prepared_retired_release) |prepared| {
            self.cancelPendingReservation(prepared.reservation);
            model.freeMessage(self.allocator, prepared.message);
        }
    }

    if (classified_deliver != null and classified_deliver.?.route == .pipelined) {
        prepared_pipelined_deliver = .{
            .call = classified_deliver.?.route.pipelined,
            .resolver = classified_deliver.?.resolver,
            .shortening = prepared_shortening.?,
        };
        // The composite is now the sole owner of all three preparations; keep
        // the existing scope cleanup from abandoning a second copy.
        classified_deliver = null;
        prepared_shortening = null;
    }

    if (prepared_pipelined_deliver) |*prepared| {
        try prepared.commit(self, decoded_body.deliver, &introduced);
        frame.deinit();
        return;
    }

    if (prepared_shortening_callback) |*prepared| {
        try prepared.commit(self, decoded_body.deliver, &introduced);
        frame.deinit();
        return;
    }

    if (retired_resolver_callback) |resolver| {
        try self.session_state.applyValidatedInboundDeliverView(decoded_body.deliver, &introduced);
        self.session_state.completeRetiredResolverCallback(resolver);
        if (prepared_retired_release) |prepared| {
            commitPreparedImportRelease(self, prepared);
            prepared_retired_release = null;
        }
        frame.deinit();
        return;
    }

    // Acquire the event's GC annotation before authority applies. The event can
    // fall back to walking its frame, but allocator refusal is still a real
    // admission failure: accepting the frame while quietly dropping derived
    // state makes memory pressure alter the observable bookkeeping path.
    var prepared_far_imports = try introduced.dupeArgumentMentions(self.allocator);
    defer if (prepared_far_imports) |positions| self.allocator.free(positions);

    try self.events.push(self.allocator, .{
        .frame = frame,
        .tag = tag,
        .answer_override = answer_override,
        // The codec this frame arrived in, not the session's. A handshake
        // frame is Syrup on a session that settles on something else, and an
        // event is decoded again by whoever drains it, after the settle. Ask
        // the session for its codec there and a hello re-reads as the codec it
        // just negotiated, which fails silently at the drain and skips
        // everything the hello was supposed to trigger.
        .codec = self.inboundCodec(),
        .captp_version = wire_profile,
        .allocator = self.allocator,
    });
    stored = true;
    var appended = true;
    errdefer if (appended) {
        var removed = self.events.popBack().?;
        removed.frame.deinit();
    };

    const was_closed = self.session_state.state == .closed;
    if (resolver_callback_resolve) |resolve| {
        try self.session_state.applyValidatedResolverCallbackResolve(resolve, &introduced);
        self.session_state.applyPromiseSettlingFollowers(resolve.answer, resolve.resolution);
        self.events.backPtr().?.resolve_aliases = self.session_state.takePromiseSettlingFollowers(resolve.answer);
    } else if (tag == .deliver) {
        try self.session_state.applyValidatedInboundDeliverView(decoded_body.deliver, &introduced);
        if (classified_deliver.?.resolver) |prepared|
            prepared.commit(&self.session_state);
        if (node_resolver_callback) |resolver|
            self.session_state.completeNodeSettlingResolverCallback(resolver);
        // The answer this deliver settles, read from the body already decoded
        // above rather than by decoding the queued frame again.
        const answer_name: ?model.AnswerName = switch (answer_override) {
            .virtual_deliver => |answer| .fromVirtual(answer),
            else => if (decoded_body.deliver.answer) |answer| .fromWire(answer) else null,
        };
        self.events.backPtr().?.deliver_answer_target = if (answer_name) |answer|
            self.session_state.answerTargetNamed(answer)
        else
            null;
    } else {
        try self.session_state.recordRecvView(recorded_body);
    }
    if (!was_closed and self.session_state.state == .closed) self.retireClosedSessionAuthority();
    if (decoded_body == .start_session) self.settleNegotiatedProfile();
    appended = false;

    commitPreparedShortening(self, &prepared_shortening.?);
    prepared_shortening = null;

    // Publish the pre-commit GC annotation onto the just-pushed event. Nothing
    // between the push and here can grow `self.events`, so the back pointer is
    // stable and this transfer is infallible.
    if (prepared_far_imports) |positions| {
        self.events.backPtr().?.introduced_far_imports = positions;
        prepared_far_imports = null;
    }

    // op:get / op:index / op:untag responder (ADR-0050): apply above
    // installed the projected answer; anchor the projection on the
    // receiver. The view's field/tag bytes borrow the frame, so the owned
    // dupe happens here, while the borrow is still valid.
    switch (decoded_body) {
        .get => |get| try pipeline.respondToProjection(self, get.receiver, .{ .field = get.field }, get.answer),
        .index => |idx| try pipeline.respondToProjection(
            self,
            idx.receiver,
            .{ .index = session.ProjectionIndex.fromInteger(idx.index) },
            idx.answer,
        ),
        .untag => |untag| try pipeline.respondToProjection(self, untag.receiver, .{ .untag = untag.tag }, untag.answer),
        else => {},
    }

    if (bootstrap_request) |action| {
        switch (action) {
            .fetch => |req| {
                const scope = if (self.node_services) |services| services.peer_handle else null;
                if (try bootstrap.resolveForSwissnum(&self.session_state, self.localObjectProjection(), scope, req)) |resolution|
                    try outbound.enqueueAnswerResolutionOwned(self, req.answer, resolution);
            },
            .deposit_gift => |req| {
                const scope = if (self.node_services) |services| services.peer_handle else null;
                const response = try bootstrap.resolveForDeposit(&self.session_state, self.giftRegistry(), self.localObjectProjection(), scope, req);
                if (self.node_services) |services| services.giftDeposited(req.gift_id);
                if (response) |resolution| {
                    try outbound.enqueueAnswerResolutionOwned(self, req.answer.?, resolution);
                }
            },
            .withdraw_gift => |req| {
                const scope = if (self.node_services) |services| services.peer_handle else null;
                if (self.pendingWithdrawCount() >= @as(usize, self.session_state.limits.max_pending_withdraws)) {
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
                        if (self.pendingWithdrawCount() >= @as(usize, self.session_state.limits.max_pending_withdraws)) {
                            var receive = admission.receive;
                            receive.deinit(self.allocator);
                            return session.Error.PendingWithdrawCapExceeded;
                        }
                        var receive = admission.receive;
                        errdefer receive.deinit(self.allocator);
                        try self.parkPendingWithdraw(receive, req.answer, admission.gifter_peer_handle);
                    },
                }
            },
        }
    }
}

/// The `EventKind` a decoded body surfaces as, a 1:1 body-tag mapping. The one
/// re-tag (a V1.0 resolver-callback deliver surfacing as `.resolve`) is decided
/// by the inbound deliver-route classifier, not here.
fn eventKindFromBody(body: model.view.Body) events.EventKind {
    return switch (body) {
        .deliver => .deliver,
        .resolve => .resolve,
        .gc_export => .gc_export,
        .gc_answer => .gc_answer,
        .start_session => .start_session,
        .abort => .abort,
        .listen => .listen,
        .get => .get,
        .index => .index,
        .untag => .untag,
    };
}
