//! The inbound receive/dispatch path: how one decoded frame becomes session
//! state plus a surfaced event, and how a failure fails loud.
//!
//! These are the heavy internals of `Peer`'s receive boundary, factored out of
//! `mod.zig` so the peer object holds construction, the send path, and the queue
//! surface while this file owns the parse-validate-apply spine. They are free
//! functions over `*Peer` (the same shape `v1_0` and `pipeline` use), not
//! methods, because the cluster is one cohesive responsibility, the inbound
//! seam, and reads better named than scattered through the struct body. The
//! public entry methods (`recvBorrowed`, `step`) stay on `Peer` and call in
//! here.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const abort_projection = @import("abort_projection.zig");
const bootstrap = @import("bootstrap.zig");
const deliver = @import("inbound/deliver.zig");
const events = @import("events.zig");
const outbound = @import("outbound.zig");
const pipeline = @import("pipeline.zig");

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
        failClosed(self, err);
        return err;
    };
}

/// Fail the session closed on an error raised after its input was consumed:
/// record it, emit the abort it projects to, and close. The owned frame or
/// carrier is gone on every outcome, so even an error with no protocol abort
/// (notably allocation failure) leaves nothing to retry, and post-admission
/// effects may already be committed. Continuing would pretend the input
/// never existed.
pub fn failClosed(self: *Peer, err: anyerror) void {
    emitAbortForError(self, err);
    if (!self.sessionIsClosed()) self.closeSession();
}

/// Emit the outbound `op:abort` an inbound failure projects to
/// (`abort_projection.abortForError`). Shares `Peer.commitAbortOutbound` with
/// app-queued aborts so a successful queue push closes CapTP. Bypasses
/// `recordSend`, which would reject against post-failure
/// session state. An encode/push failure is recorded beside the originating
/// failure, which remains the returned authority, and closes the session.
///
/// A session already closed keeps the cause that closed it. A frame refused
/// afterwards, the partner's traffic still in the pipe, is recorded beside
/// that cause and projects no second abort.
pub fn emitAbortForError(self: *Peer, err: anyerror) void {
    if (self.sessionIsClosed()) {
        self.recordSecondaryFailure(err);
        return;
    }
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
    // The body is parsed once, where the surfaced event carries it, and its
    // argument list into the frame's own head (ADR-0063).
    const parse = events.Parse.decode(self.allocator, &frame_in, self.inboundCodec(), wire_profile) catch |err| {
        var frame = frame_in;
        frame.deinit();
        return err;
    };
    try applyDecodedOwnedFrame(self, frame_in, parse, wire_profile);
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
        // to have honored the dial target (ADR-0028).
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

/// A hello carrying this session's own key is this session's hello reflected
/// back by the path, and it verifies under that key. The two ends of a
/// session hold distinct keys, so the reflection is refused before the key is
/// learned. A session that has sent no hello has nothing a path could reflect,
/// and an unverified key is an assertion, which in-process pairs share.
fn refuseReflectedHello(self: *Peer, ss: model.view.StartSession) error{ReflectedSessionKey}!void {
    const ours = self.session_state.localSessionKey() orelse return;
    if (std.mem.eql(u8, ours, ss.session_pubkey)) return error.ReflectedSessionKey;
}

/// Apply an already-decoded inbound frame: install listeners, enqueue a
/// pipelined call, surface the event, and record authority. Every door a
/// frame enters by (`recvBorrowed`, `recvPacket`, `feedOwned`, the queued
/// inbound row) reaches here through `dispatchOwnedFrameInner`, so an inbound
/// frame is parsed exactly once regardless of how it arrived.
///
/// `parse` names the decoded body, which borrows `frame_in`'s own heap bytes
/// and the views in its head. The queued row carries the frame and this
/// parse together, so `Peer.pollEvent` surfaces the body without reading the
/// bytes again. Both are consumed on every outcome.
///
/// A deliver takes one of four routes and may prepare resolver rows, queue
/// slots, and GC annotations before it commits. Every other message records
/// and surfaces, so it takes a path that holds none of that state.
fn applyDecodedOwnedFrame(
    self: *Peer,
    frame_in: foundation.Frame,
    parse: events.Parse,
    wire_profile: model.CaptpVersion,
) !void {
    const body = parse.body();
    // Apply the session's state-admission gate before any authority mutation
    // below. The pipelined-call enqueue, listener install, and V1.0 resolver
    // registration all run ahead of `recordRecvView`/`recordRecv`, and the
    // pipelined path returns without ever reaching them, so without this a
    // closed (or negotiating) session would mutate authority for an inbound
    // kind it must refuse. `recordRecv*` re-checks the gate; the check is pure.
    self.session_state.admits(body.*) catch |err| {
        parse.deinit(self.allocator);
        var frame = frame_in;
        frame.deinit();
        return err;
    };
    return switch (body.*) {
        .deliver => deliver.apply(self, frame_in, parse, wire_profile),
        else => applyPlainOwnedFrame(self, frame_in, parse, wire_profile),
    };
}

/// Every message but a deliver: check a hello, install a listener, surface
/// the event, record authority, and answer a projection.
fn applyPlainOwnedFrame(
    self: *Peer,
    frame_in: foundation.Frame,
    parse: events.Parse,
    wire_profile: model.CaptpVersion,
) !void {
    var frame = frame_in;
    var stored = false;
    errdefer if (!stored) {
        parse.deinit(self.allocator);
        frame.deinit();
    };

    // The body recorded is the decoded one, read in place, except a hello
    // without captured location bytes, which records them canonicalized.
    const decoded_body = parse.body();
    var recorded_body: *const model.view.Body = decoded_body;
    var canonical_partner_location: ?[]u8 = null;
    defer if (canonical_partner_location) |bytes| self.allocator.free(bytes);
    var canonical_hello: model.view.Body = undefined;
    if (decoded_body.* == .start_session and decoded_body.start_session.acceptable_location_raw == null) {
        canonical_partner_location = try engine.encodePeerLocatorViewRecord(
            self.allocator,
            decoded_body.start_session.acceptable_location,
        );
        canonical_hello = decoded_body.*;
        canonical_hello.start_session.acceptable_location_raw = canonical_partner_location.?;
        recorded_body = &canonical_hello;
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
    if (decoded_body.* == .start_session and self.session_state.awaitsPartnerHello()) {
        if (self.verify_partner_handshake) {
            try engine.verifyPartnerStartSession(self.allocator, recorded_body.start_session);
            try refuseReflectedHello(self, recorded_body.start_session);
        }
        // What this side demands of the partner's durable claim (ADR-0028),
        // at this same pre-open chokepoint: one byte-fed `feed` can carry the
        // start-session and later frames in a single chunk, and a post-open
        // check would let those frames apply under the wrong identity before
        // anyone looked.
        try checkPartnerDurableClaim(self, recorded_body.start_session);
    }

    // An inbound `op:listen` against one of our pending inbound answers
    // registers the listener so the resolution fires it (ADR-0003). Installed before the event/`recordRecv` so a refusal
    // leaves nothing surfaced. Non-promise targets and listens on unknown
    // answers fall through to ordinary recv handling.
    if (decoded_body.* == .listen) {
        try pipeline.maybeInstallInboundListener(self, decoded_body.listen);
    }

    try pushAdmittedEvent(self, frame, parse, eventKindFromBody(decoded_body), .none, wire_profile);
    stored = true;
    // Until authority records the frame, a refusal takes the event back. After
    // that the frame is applied and stays surfaced whatever follows.
    var appended = true;
    errdefer if (appended) abandonPushedEvent(self);

    const was_closed = self.session_state.state == .closed;
    try self.session_state.recordRecvView(recorded_body.*);
    if (!was_closed and self.session_state.state == .closed) self.retireClosedSessionAuthority();
    if (decoded_body.* == .start_session) self.settleNegotiatedProfile();
    // Apply settled the answer's live row, so the event names the question
    // by identity for every reader that serves it after the position may
    // have been released and reused.
    if (decoded_body.* == .resolve) self.events.backPtr().?.answer_override = .{
        .resolve = self.session_state.outboundAnswerTarget(decoded_body.resolve.answer) orelse unreachable,
    };
    appended = false;

    // op:get / op:index / op:untag responder (ADR-0004): apply above
    // installed the projected answer; anchor the projection on the
    // receiver. The view's field/tag bytes borrow the frame, so the owned
    // dupe happens here, while the borrow is still valid.
    switch (decoded_body.*) {
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
}

/// Queue the admitted frame and its parse as one event. From here the row
/// owns both; a caller whose authority apply then fails takes the row back
/// with `abandonPushedEvent`. A caller refused here still owns both.
pub fn pushAdmittedEvent(
    self: *Peer,
    frame: foundation.Frame,
    parse: events.Parse,
    tag: events.EventKind,
    answer_override: events.AnswerOverride,
    wire_profile: model.CaptpVersion,
) !void {
    const row = try self.events.pushUninit(self.allocator);
    row.* = .{
        .frame = frame,
        .parse = parse,
        .tag = tag,
        .answer_override = answer_override,
        // The codec this frame arrived in, not the session's. A handshake
        // frame is Syrup on a session that settles on something else, and the
        // event reports the codec that carried its frame.
        .codec = self.inboundCodec(),
        .captp_version = wire_profile,
        .allocator = self.allocator,
    };
}

/// Take back the event `pushAdmittedEvent` queued last, with its frame.
pub fn abandonPushedEvent(self: *Peer) void {
    var removed = self.events.popBack().?;
    removed.parse.deinit(self.allocator);
    removed.frame.deinit();
}

/// The `EventKind` a decoded body surfaces as, a 1:1 body-tag mapping. The one
/// re-tag (a V1.0 resolver-callback deliver surfacing as `.resolve`) is decided
/// by the inbound deliver-route classifier, not here.
fn eventKindFromBody(body: *const model.view.Body) events.EventKind {
    return switch (body.*) {
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
