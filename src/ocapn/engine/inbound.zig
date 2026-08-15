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
/// must stay valid until apply completes; afterwards the retained event owns
/// only `frame_in` and the borrow is dropped.
pub fn applyDecodedOwnedFrame(
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
            try engine.verifyPartnerStartSession(self.allocator, decoded_body.start_session);
        }
        // What this side demands of the partner's durable claim (ADR-0105),
        // at this same pre-open chokepoint: one byte-fed `feed` can carry the
        // start-session and later frames in a single chunk, and a post-open
        // check would let those frames apply under the wrong identity before
        // anyone looked.
        try checkPartnerDurableClaim(self, decoded_body.start_session);
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
    var shortening_callback: ?struct {
        resolver: model.ExportPosition,
        shortened_to: model.FarRef,
    } = null;
    var retired_resolver_callback: ?model.ExportPosition = null;
    var node_resolver_callback: ?model.ExportPosition = null;
    var bootstrap_request: ?bootstrap.Request = null;
    if (decoded_body == .deliver) {
        switch (try classifyInboundDeliver(self, decoded_body.deliver, &introduced)) {
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
                try self.session_state.validateResolverCallbackResolve(resolver_callback_resolve.?, &introduced);
                try self.session_state.validatePromiseSettlingFollowers(answer);
            },
            .shortening_callback => |resolver| {
                const resolution = try events.resolutionFromResolverCallback(decoded_body.deliver.args);
                const shortened_to: model.FarRef = switch (resolution) {
                    .fulfill => |arg| switch (arg) {
                        .reference => |reference| switch (reference) {
                            .far => |far| if (far.kind == .promise) far else return session.Error.UnexpectedMessage,
                            else => return session.Error.UnexpectedMessage,
                        },
                        else => return session.Error.UnexpectedMessage,
                    },
                    .@"break" => return session.Error.UnexpectedMessage,
                };
                try self.session_state.validateShorteningCompletion(resolver, shortened_to);
                try self.session_state.validateInboundDeliverView(decoded_body.deliver, &introduced);
                shortening_callback = .{ .resolver = resolver, .shortened_to = shortened_to };
            },
            .retired_resolver_callback => |resolver| retired_resolver_callback = resolver,
            .node_resolver_callback => |resolver| node_resolver_callback = resolver,
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

    const shortening_source = if (shortening_callback) |callback| switch (self.session_state.sourceForShorteningResolver(callback.resolver).?) {
        .pending => |source| source,
        .complete => unreachable,
    } else null;
    const shortening_source_is_held = if (shortening_callback) |callback|
        self.session_state.shorteningSourceIsHeld(callback.resolver)
    else
        false;
    const shortening_source_has_settling = if (shortening_source) |source|
        self.session_state.promiseSettlingListenerClaimed(source)
    else
        false;
    const shortening_source_has_settling_consumer = if (shortening_source) |source|
        self.session_state.promiseSettlingConsumerClaimed(source)
    else
        false;

    // Preparation below may hold several reservations while authority is
    // validated and committed as one transaction. Reserve the whole possible
    // batch once; a per-row reservation cannot express slots for rows that
    // have not been appended yet.
    const pending_preparation_count = if (retired_resolver_callback != null)
        @as(usize, 1)
    else blk: {
        var count = introduced.promise_mentions.items.len;
        if (shortening_callback != null and !shortening_source_is_held) count += 1;
        if (shortening_source_has_settling_consumer) count += 1;
        break :blk count;
    };
    var pending_batch = try self.beginPendingBatch(pending_preparation_count);

    // Acquire every resolver row, queue slot, and owned GC slice before apply.
    // Once the received frame commits, the required protocol maintenance must
    // not become optional under allocator pressure.
    var prepared_shortening: ?PreparedShortening = null;
    var prepared_late_release: ?PreparedOutboundMessage = null;
    var prepared_retired_release: ?PreparedOutboundMessage = null;
    if (retired_resolver_callback != null) {
        prepared_shortening = .{};
        prepared_retired_release = try prepareIntroducedImportReleases(self, &pending_batch, introduced.mentions.items);
    } else if (shortening_callback != null and !shortening_source_is_held and !shortening_source_has_settling_consumer) {
        prepared_late_release = try prepareIntroducedPromiseRelease(self, &pending_batch, shortening_callback.?.shortened_to.import_position);
    } else {
        prepared_shortening = try prepareIntroducedPromiseShortening(self, &pending_batch, &introduced);
        if (shortening_callback != null and !shortening_source_is_held)
            prepared_late_release = try prepareIntroducedPromiseRelease(self, &pending_batch, shortening_callback.?.shortened_to.import_position);
    }
    var settling_rearm = if (shortening_source_has_settling_consumer)
        try prepareSettlingRearm(
            self,
            &pending_batch,
            shortening_source.?,
            shortening_callback.?.shortened_to.import_position,
            prepared_shortening.?.nominations.items.len + @intFromBool(prepared_late_release != null),
        )
    else
        null;
    defer {
        if (settling_rearm) |*prepared| prepared.deinit(self);
        if (prepared_shortening) |*prepared| prepared.abandon(self);
        if (prepared_late_release) |prepared| {
            self.cancelPendingReservation(prepared.reservation);
            model.freeMessage(self.allocator, prepared.message);
        }
        if (prepared_retired_release) |prepared| {
            self.cancelPendingReservation(prepared.reservation);
            model.freeMessage(self.allocator, prepared.message);
        }
    }

    if (shortening_callback) |callback| {
        try self.session_state.applyValidatedInboundDeliverView(decoded_body.deliver, &introduced);
        self.session_state.completeShortening(callback.resolver, callback.shortened_to);
        if (shortening_source_is_held or shortening_source_has_settling_consumer) {
            commitPreparedShortening(self, &prepared_shortening.?);
            prepared_shortening = null;
            if (settling_rearm) |prepared| {
                commitSettlingRearm(self, shortening_source.?, callback.shortened_to, prepared);
                settling_rearm = null;
            }
            if (shortening_source_has_settling and !shortening_source_has_settling_consumer)
                self.session_state.discardUnconsumedPromiseSettlingListener(shortening_source.?);
            if (prepared_late_release) |prepared| {
                commitPreparedImportRelease(self, prepared);
                prepared_late_release = null;
                self.session_state.releaseShorteningSourceAuthority(shortening_source.?);
            }
        } else {
            if (shortening_source_has_settling)
                self.session_state.discardUnconsumedPromiseSettlingListener(shortening_source.?);
            commitPreparedImportRelease(self, prepared_late_release.?);
            prepared_late_release = null;
            self.session_state.releaseShorteningSourceAuthority(shortening_source.?);
        }
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
    var prepared_far_imports: ?[]model.ImportPosition = if (introduced.mentions.items.len == 0)
        null
    else
        try self.allocator.dupe(model.ImportPosition, introduced.mentions.items);
    defer if (prepared_far_imports) |positions| self.allocator.free(positions);

    try self.events.push(self.allocator, .{
        .frame = frame,
        .tag = tag,
        .answer_override = answer_override,
        // The codec this frame arrived in, not the session's. A handshake
        // frame is Syrup on a session that settles on something else, and an
        // event is decoded again by whoever drains it — after the settle. Ask
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
        if (node_resolver_callback) |resolver|
            self.session_state.completeNodeSettlingResolverCallback(resolver);
    } else {
        try self.session_state.recordRecvView(decoded_body);
    }
    if (!was_closed and self.session_state.state == .closed) self.retireClosedSessionAuthority();
    if (decoded_body == .start_session) self.settleNegotiatedProfile();
    appended = false;

    commitPreparedShortening(self, &prepared_shortening.?);
    prepared_shortening = null;
    if (settling_rearm) |prepared| {
        commitSettlingRearm(self, shortening_source.?, shortening_callback.?.shortened_to, prepared);
        settling_rearm = null;
    }

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
                const scope = if (self.node_services) |services| services.peer_id else null;
                try self.send(try bootstrap.resolveForSwissnum(&self.session_state, self.localObjectProjection(), scope, req));
            },
            .deposit_gift => |req| {
                const scope = if (self.node_services) |services| services.peer_id else null;
                const response = try bootstrap.resolveForDeposit(&self.session_state, self.giftRegistry(), self.localObjectProjection(), scope, req);
                if (self.node_services) |services| services.giftDeposited(req.gift_id);
                if (response) |msg| {
                    try self.send(msg);
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
    /// A next-profile shortening-only callback. It advances private session
    /// routing and is consumed before the application event queue.
    shortening_callback: model.ExportPosition,
    /// A resolver callback that raced with local answer release. Its arguments
    /// are admitted and immediately released, with no application event.
    retired_resolver_callback: model.ExportPosition,
    /// A Node-only settling callback. It remains a deliver event for the Host's
    /// Node composition hook, while session authority retires it as one-shot.
    node_resolver_callback: model.ExportPosition,
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
/// 2. Ordinary deliver validation runs next, before any deliver-specific
///    authority mutation.
/// 3. V1.0 resolver registration then installs the partner's
///    advertised resolver as a side effect, and a pipelined deliver carrying
///    `resolve_me_desc` needs that resolver installed before its frame is
///    released, so the V1.0 translation finds it when the drained call
///    resolves later.
/// 4. Pipelining runs after that registration: an inbound deliver whose target
///    is a still-pending answer is queued until that answer resolves
///    (ADR-0007).
/// 5. The bootstrap probe runs last, so a pipelined call is never mistaken
///    for a bootstrap fetch, and a resolver-only fetch has its virtual
///    answer installed before the bootstrap action is computed.
fn classifyInboundDeliver(
    self: *Peer,
    deliver: model.view.Deliver,
    introduced: *session.validate.IntroducedImports,
) !InboundDeliverClass {
    // A resolver export settles by an `['fulfill|'break, payload]` deliver on
    // every negotiated version, so this probe carries no version gate: the
    // V1.0 resolver callback and the `op:listen` notification a listener
    // export receives are the same wire shape (ADR-0095). Only a `.near`
    // reaches the link, so a partner-named `.far` in the same integer space
    // cannot key it.
    if (deliver.target.exportPosition()) |position| {
        if (self.session_state.sourceForShorteningResolver(position)) |state| {
            return switch (state) {
                .pending => .{ .shortening_callback = position },
                .complete => session.Error.UnexpectedMessage,
            };
        }
        if (self.session_state.isNodeSettlingResolver(position)) {
            _ = try events.resolutionFromResolverCallback(deliver.args);
            try self.session_state.validateInboundDeliverView(deliver, introduced);
            return .{ .node_resolver_callback = position };
        }
        if (self.session_state.retiredResolverState(position)) |state| {
            if (state == .complete) return session.Error.UnexpectedMessage;
            _ = try events.resolutionFromResolverCallback(deliver.args);
            try self.session_state.validateInboundDeliverView(deliver, introduced);
            return .{ .retired_resolver_callback = position };
        }
        if (self.session_state.answerForResolverExport(position)) |answer| {
            return .{ .resolver_callback_resolve = answer };
        }
    }
    // Every remaining route has ordinary deliver semantics. Validate the full
    // target, answer, resolver descriptor, and argument tree before resolver
    // registration or pipeline retention can mutate session authority.
    try self.session_state.validateInboundDeliverView(deliver, introduced);
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

const PreparedShortening = struct {
    nominations: std.ArrayListUnmanaged(session.ShorteningNomination) = .empty,
    reservations: std.ArrayListUnmanaged(engine.Peer.PendingReservation) = .empty,

    fn abandon(self: *PreparedShortening, peer: *Peer) void {
        for (self.reservations.items) |reservation| peer.cancelPendingReservation(reservation);
        self.reservations.deinit(peer.allocator);
        for (self.nominations.items) |nomination|
            peer.session_state.abandonShorteningResolver(nomination);
        self.nominations.deinit(peer.allocator);
        self.* = .{};
    }
};

const PreparedOutboundMessage = struct {
    message: model.Message,
    reservation: engine.Peer.PendingReservation,
};

fn prepareIntroducedPromiseShortening(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    introduced: *const session.validate.IntroducedImports,
) !PreparedShortening {
    var prepared: PreparedShortening = .{};
    errdefer prepared.abandon(self);
    if (self.session_state.captp_version != .next) return prepared;

    try prepared.nominations.ensureTotalCapacity(self.allocator, introduced.promise_mentions.items.len);
    try prepared.reservations.ensureTotalCapacity(self.allocator, introduced.promise_mentions.items.len);
    for (introduced.promise_mentions.items) |source| {
        const nomination = (try self.session_state.nominateShorteningResolver(source)) orelse continue;
        prepared.nominations.appendAssumeCapacity(nomination);
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(nomination.source.int()) },
            .listener = session.slot.toReference(self.session_state.exportSlot(nomination.resolver_export).?).?,
            .mode = .shortening_only,
        } };
        prepared.reservations.appendAssumeCapacity(try pending_batch.reserve(.{ .message = message }));
    }
    return prepared;
}

fn commitPreparedShortening(self: *Peer, prepared: *PreparedShortening) void {
    for (prepared.nominations.items, prepared.reservations.items) |nomination, reservation| {
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(nomination.source.int()) },
            .listener = session.slot.toReference(self.session_state.exportSlot(nomination.resolver_export).?).?,
            .mode = .shortening_only,
        } };
        self.session_state.recordSend(message) catch unreachable;
        self.pushPendingAssume(reservation, .{ .message = message });
    }
    prepared.nominations.deinit(self.allocator);
    prepared.reservations.deinit(self.allocator);
    prepared.* = .{};
}

const PreparedSettlingRearm = struct {
    listener_export: model.ExportPosition,
    node_services: ?engine.NodeServices,
    move: session.SettlingMovePlan,
    reservation: ?engine.Peer.PendingReservation = null,

    fn deinit(self: *PreparedSettlingRearm, peer: *Peer) void {
        if (self.reservation) |reservation| peer.cancelPendingReservation(reservation);
        self.move.deinit(peer.allocator);
    }
};

fn prepareSettlingRearm(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    source: session.PromiseIncarnation,
    target: model.ImportPosition,
    shortening_send_count: usize,
) !?PreparedSettlingRearm {
    if (!self.session_state.promiseSettlingListenerClaimed(source)) return null;
    var move = try self.session_state.preparePromiseSettlingMove(source, target);
    errdefer move.deinit(self.allocator);

    const answer = self.session_state.promiseSettlingAnswer(source);
    const source_listener = self.session_state.promiseSettlingListenerExport(source) orelse
        return session.Error.UnexpectedMessage;
    const target_incarnation = self.session_state.shorteningIncarnationForImport(target) orelse
        return session.Error.UnexpectedMessage;
    const target_listener = if (move.converges)
        self.session_state.promiseSettlingListenerExport(target_incarnation) orelse
            return session.Error.UnexpectedMessage
    else
        source_listener;
    const node_services = if (self.session_state.promiseSettlingNodeClaimed(source)) blk: {
        const services = self.node_services orelse return session.Error.UnexpectedMessage;
        try services.preparePromiseShortening(
            source.position.int(),
            target.int(),
            target_listener.int(),
            move.converges,
        );
        break :blk services;
    } else null;
    if (answer == null and node_services == null) return session.Error.UnexpectedMessage;
    var prepared: PreparedSettlingRearm = .{
        .listener_export = source_listener,
        .node_services = node_services,
        .move = move,
    };
    _ = shortening_send_count;
    if (!prepared.move.converges) {
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = model.FarRef.promise(target.int()) },
            .listener = session.slot.toReference(self.session_state.exportSlot(prepared.listener_export).?).?,
            .mode = .settling_only,
        } };
        prepared.reservation = try pending_batch.reserve(.{ .message = message });
    }
    return prepared;
}

fn commitSettlingRearm(
    self: *Peer,
    source: session.PromiseIncarnation,
    target: model.FarRef,
    prepared_in: PreparedSettlingRearm,
) void {
    var prepared = prepared_in;
    if (!prepared.move.converges) {
        const message: model.Message = .{ .listen = .{
            .target = .{ .far = target },
            .listener = session.slot.toReference(self.session_state.exportSlot(prepared.listener_export).?).?,
            .mode = .settling_only,
        } };
        self.session_state.recordSend(message) catch unreachable;
        self.pushPendingAssume(prepared.reservation.?, .{ .message = message });
        prepared.reservation = null;
    }
    self.session_state.commitPromiseSettlingMove(&prepared.move);
    if (prepared.node_services) |services|
        services.commitPromiseShortening(
            source.position.int(),
            target.import_position.int(),
            if (prepared.move.converges)
                self.session_state.promiseSettlingListenerExport(
                    self.session_state.shorteningIncarnationForImport(target.import_position) orelse unreachable,
                ).?.int()
            else
                prepared.listener_export.int(),
            prepared.move.converges,
        );
}

fn prepareIntroducedPromiseRelease(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    position: model.ImportPosition,
) !PreparedOutboundMessage {
    const positions = try self.allocator.alloc(u64, 1);
    errdefer self.allocator.free(positions);
    const deltas = try self.allocator.alloc(u64, 1);
    errdefer self.allocator.free(deltas);
    positions[0] = position.int();
    deltas[0] = 1;
    const message: model.Message = .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
    return .{ .message = message, .reservation = try pending_batch.reserve(.{ .message = message }) };
}

fn prepareIntroducedImportReleases(
    self: *Peer,
    pending_batch: *engine.Peer.PendingBatch,
    imports: []const model.ImportPosition,
) !?PreparedOutboundMessage {
    if (imports.len == 0) return null;
    const positions = try self.allocator.alloc(u64, imports.len);
    errdefer self.allocator.free(positions);
    const deltas = try self.allocator.alloc(u64, imports.len);
    errdefer self.allocator.free(deltas);
    for (imports, positions, deltas) |import_position, *position, *delta| {
        position.* = import_position.int();
        delta.* = 1;
    }
    const message: model.Message = .{ .gc_export = .{ .positions = positions, .deltas = deltas } };
    return .{ .message = message, .reservation = try pending_batch.reserve(.{ .message = message }) };
}

fn commitPreparedImportRelease(self: *Peer, prepared: PreparedOutboundMessage) void {
    self.session_state.recordSend(prepared.message) catch unreachable;
    self.pushPendingAssume(prepared.reservation, .{ .message = prepared.message });
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
        .start_session => .start_session,
        .abort => .abort,
        .listen => .listen,
        .get => .get,
        .index => .index,
        .untag => .untag,
    };
}
