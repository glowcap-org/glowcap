//! The drain of the outbound queue: every step the pending carriers take
//! from queue front to wire, and the local consequences a settled answer
//! releases behind its publication.
//!
//! One direction: the drain reads the queue types and the enqueue family from
//! `outbound.zig`, which never reaches back in.

const std = @import("std");

const codec = @import("codec");
const encoded = @import("encoded.zig");
const inbound = @import("../inbound.zig");
const listener_fire = @import("listener_fire.zig");
const model = @import("model");
const outbound = @import("../outbound.zig");
const pipeline = @import("../pipeline.zig");
const resolution_chain = @import("../resolution_chain.zig");
const session = @import("session");
const engine = @import("../mod.zig");
const v1_0 = @import("../v1_0.zig");

const Peer = engine.Peer;

/// Consecutive answer releases at the queue front leave as one
/// `op:gc-answers` of at most this many positions, one stack buffer per step.
const release_wave = 32;

/// Whether the queue front is a run of answer releases with no message
/// behind it and at least one answer still to release. `Peer.step` holds
/// such a run, so the releases ride ahead of the session's next message in
/// one frame, or leave alone through `Peer.flushAnswerReleases` when the
/// embedder parks. A closed session, or a run whose answers are already
/// gone (a retracted staged send), holds nothing: the ordinary step
/// consumes it without a frame.
pub fn holdsAnswerReleases(self: *Peer) bool {
    if (!self.sessionIsOpen()) return false;
    var live = false;
    for (self.pending_send.pending()) |row| switch (row.item) {
        .answer_release => |answer| live = live or self.session_state.hasLiveOutboundAnswer(answer),
        else => return false,
    };
    return live;
}

/// Encode the front pending-send item during `step`. Every carrier remains at
/// the queue front until its complete wire publication succeeds. V1.0
/// translation may install resolver authority while preparing a message. Its
/// preparation owns rollback until the corresponding frame or frame pair is
/// queued, so allocator pressure is retryable without losing a carrier or
/// leaving a partial projection transaction on the wire.
pub fn stepPending(self: *Peer) !void {
    if (self.sessionIsClosed()) {
        var discarded = self.takePending();
        discarded.item.deinit(self);
        return;
    }
    // `drive` steps here only while `peek` answers.
    const pending = self.pending_send.peek() orelse unreachable;
    switch (pending.item) {
        .answer_release => try emitAnswerReleaseWave(self),
        .settled_answer => |sa| try emitSettledAnswer(self, sa),
        .encoded => |sent| {
            try emitEncoded(self, sent);
            const consumed = self.takePending();
            consumed.item.encoded.deinitEmitted(self);
        },
        .message => |message| {
            try emitPendingMessage(self, message);
            var consumed = self.takePending();
            consumed.item.deinit(self);
        },
        .listener_fire => |fire| {
            try emitPendingListenerFire(self, fire);
            const consumed = self.takePending();
            const emitted = switch (consumed.item) {
                .listener_fire => |item| item,
                else => unreachable,
            };
            listener_fire.deinitEmitted(emitted, self);
        },
        // `step` stops before a staged row on an open session.
        .staged => unreachable,
    }
}

/// Consecutive releases leave as one `op:gc-answers`. Failed preparation
/// leaves no answer to release, and a successful carrier precedes its
/// release in the same pending queue.
fn emitAnswerReleaseWave(self: *Peer) !void {
    var positions: [release_wave]u64 = undefined;
    var count: usize = 0;
    var carriers: usize = 0;
    const rows = self.pending_send.pending();
    while (carriers < rows.len and carriers < release_wave) : (carriers += 1) {
        const answer = switch (rows[carriers].item) {
            .answer_release => |answer| answer,
            else => break,
        };
        if (!self.sessionIsOpen() or !self.session_state.hasLiveOutboundAnswer(answer)) continue;
        const position = answer.position.int();
        const seen = for (positions[0..count]) |earlier| {
            if (earlier == position) break true;
        } else false;
        if (seen) continue;
        positions[count] = position;
        count += 1;
    }
    if (count != 0) try emitRecordedPendingMessage(self, .{
        .gc_answer = .{ .positions = positions[0..count] },
    }, .prepared_send);
    for (0..carriers) |_| {
        var consumed = self.takePending();
        consumed.item.deinit(self);
    }
}

/// Send one settled inbound answer, then run its local consequences.
fn emitSettledAnswer(self: *Peer, sa: outbound.SettledAnswer) !void {
    // The `applySentResolve` invariant: a settled inbound answer always
    // holds its resolution, stored when the resolve was recorded.
    const stored = self.session_state.answerPayloadResolution(sa.payload) orelse unreachable;
    // Only an answer with work anchored on it walks the chain. One with none
    // has no listeners to take and nothing to drain.
    const consequence: ?resolution_chain.Outcome = if (sa.payload.hasAnchoredWork())
        resolution_chain.followAnswer(self, sa.target, sa.payload)
    else
        null;
    var prepared_listeners: pipeline.PreparedListenerDrain = if (consequence) |outcome|
        try pipeline.prepareAnswerListenerDrain(self, sa.payload, outcome)
    else
        .none(sa.payload);
    var listeners_prepared = true;
    errdefer if (listeners_prepared) prepared_listeners.abandon(self);
    // A temporary retain bridges carrier consumption and consequence
    // drain. Resolver/listener publication is committed once, then the
    // queue carrier is consumed before any fallible local consequence,
    // so retry can never duplicate the notification.
    try self.session_state.retainAnswerPayload(sa.payload);
    defer self.session_state.releaseAnswerCarrier(sa.target, sa.payload);
    // V1.0 sends the settlement through its resolver callback. The
    // next profile has no wire op:resolve: its inline or explicit
    // subscription is the notification path, so only the local consequence drain runs.
    if (self.session_state.captp_version == .v1_0) {
        if (self.session_state.answerPayloadResolver(sa.payload)) |resolver_import| {
            try v1_0.encodeResolutionAsCallback(self, stored.*, resolver_import);
            self.session_state.clearAnswerPayloadResolver(sa.target, sa.payload);
        }
    }
    // A sent settlement also resolves this answer locally. Notification
    // publication is the last retryable boundary: after it, repeating
    // the carrier would duplicate wire authority, while dropping a
    // failed call/projection drain would leave the peer hanging. Make
    // that failure terminal and consume the carrier exactly once.
    if (consequence) |outcome| pipeline.drainAnswerConsequencesTarget(self, sa.target, sa.payload, outcome, &prepared_listeners) catch |err| {
        prepared_listeners.abandon(self);
        listeners_prepared = false;
        const consumed = self.takePending();
        consumed.item.deinit(self);
        inbound.failClosed(self, err);
        return err;
    };
    listeners_prepared = false;
    const consumed = self.takePending();
    consumed.item.deinit(self);
}

/// Move an admitted row's frame, including its inline subscription, to
/// `outbound`. No waterline stands here: the row's
/// bytes were admitted when it was queued (`outbound/budget.zig`).
fn emitEncoded(self: *Peer, sent: encoded.Encoded) !void {
    try self.ensureOutboundCapacity(1);
    self.outbound.pushAssumeCapacity(sent.frame);
}

fn emitPendingListenerFire(self: *Peer, fire: listener_fire.Carrier) !void {
    var args: [2]model.Argument = undefined;
    const message = listener_fire.borrowedMessage(self, fire, &args);
    const listener_import = model.ImportPosition.from(fire.listener_position);
    if (!self.session_state.importRequiresWireRelease(listener_import)) {
        if (message) |callback|
            try self.pushEncodedFromPending(callback);
        return;
    }
    const positions = [_]u64{fire.listener_position};
    const deltas = [_]u64{1};
    const release: model.Message = .{ .gc_export = .{
        .positions = &positions,
        .deltas = &deltas,
    } };
    if (message) |callback| {
        try self.pushEncodedPairFromPending(callback, release, .session_release_at_commit);
    } else {
        try emitRecordedPendingMessage(self, release, .session_release);
    }
}

/// How a message the engine prepared records its session accounting when it
/// is published alone: as any prepared send, or as the release of the
/// session's own import retains (a fire whose callback fell moot).
const PreparedAccounting = enum { prepared_send, session_release };

fn emitRecordedPendingMessage(self: *Peer, message: model.Message, accounting: PreparedAccounting) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(
        self.session_state.codec,
        self.allocator,
        self.session_state.captp_version,
        message,
    );
    errdefer frame.deinit();
    try self.ensureOutboundCapacity(1);
    switch (accounting) {
        .prepared_send => self.session_state.recordPreparedSend(message),
        .session_release => self.session_state.recordSessionImportRelease(message.gc_export),
    }
    self.outbound.pushAssumeCapacity(frame);
}

/// Encode one pending message onto `outbound`, applying the V1.0
/// translations that have no wire form under next (`v1_0`, ADR-0010):
///   - a semantic `Resolve` ships as a resolver-callback `op:deliver` to the
///     partner's resolver import, or is dropped when only `op:listen`
///     listeners settle the answer (the listener fire in `drainAnswerConsequencesTarget`
///     handles notification).
///   - a projection trails an `op:listen` that carries its new answer's
///     resolution back, since the projection ops carry no inline resolver
///     (ADR-0050, ADR-0052). The listen must follow the op that opened the
///     answer on the wire, so it is pushed after the encode.
/// next encodes the message as it stands. Borrows `message`. The pending queue
/// continues owning it until this returns successfully. An `op:abort` closes
/// only after its frame is published so the partner can still take it. A
/// deliver never reaches here: it left as its frame at admission.
fn emitPendingMessage(self: *Peer, message: model.Message) !void {
    std.debug.assert(message != .deliver);
    if (message == .abort) {
        try self.commitAbortOutbound(message.abort);
        return;
    }

    const needs_v1_0 = self.session_state.needsV1_0Translation();

    if (needs_v1_0 and message == .resolve) {
        // A V1.0 partner hears a resolution only through the resolver
        // capability its own deliver carried (`resolve-me-desc`). A deliver
        // that named an answer but advertised no resolver asked for no
        // callback: there is nobody to notify, so the resolve emits nothing:
        // V1.0 has no wire shape to invent for it.
        if (self.session_state.resolverForInboundAnswer(.fromWire(message.resolve.answer))) |resolver_import| {
            try v1_0.encodeResolutionAsCallback(self, message.resolve.resolution, resolver_import);
        }
        return;
    }

    if (!needs_v1_0) return self.pushEncodedFromPending(message);

    switch (message) {
        .get => |get| try emitV1Projection(self, message, get.answer),
        .index => |index| try emitV1Projection(self, message, index.answer),
        .untag => |untag| try emitV1Projection(self, message, untag.answer),
        else => try self.pushEncodedFromPending(message),
    }
}

fn emitV1Projection(
    self: *Peer,
    projection: model.Message,
    answer: model.AnswerPosition,
) !void {
    const listener = (try v1_0.prepareProjectionListener(self, answer)) orelse
        return self.pushEncodedFromPending(projection);
    errdefer listener.abandon(self);
    try self.pushEncodedPairFromPending(
        projection,
        listener.message,
        .already_recorded,
    );
}
