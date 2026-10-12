//! The drain of the outbound queue: every step the pending carriers take
//! from queue front to wire, and the local consequences a settled answer
//! releases behind its publication.
//!
//! One direction: the drain reads the queue types and the enqueue family from
//! `outbound.zig`, which never reaches back in.

const abort_projection = @import("../abort_projection.zig");
const codec = @import("codec");
const listener_fire = @import("listener_fire.zig");
const model = @import("model");
const outbound = @import("../outbound.zig");
const pipeline = @import("../pipeline.zig");
const resolution_chain = @import("../resolution_chain.zig");
const session = @import("session");
const engine = @import("../mod.zig");
const v1_0 = @import("../v1_0.zig");

const Peer = engine.Peer;

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
        .answer_release => |answer| {
            // Failed preparation leaves no answer to release. A successful
            // carrier precedes this release in the same pending queue.
            if (self.sessionIsOpen() and self.session_state.outboundAnswer(answer) != null) {
                const positions = [_]u64{answer.int()};
                try emitRecordedPendingMessage(self, .{
                    .gc_answer = .{ .positions = &positions },
                }, .prepared_send);
            }
            var consumed = self.takePending();
            consumed.item.deinit(self);
        },
        .settled_answer => |sa| {
            // The `applySentResolve` invariant: a settled inbound answer always
            // holds its resolution, stored when the resolve was recorded.
            const stored = self.session_state.answerPayloadResolution(sa.payload) orelse unreachable;
            const has_consequences = sa.payload.queue.items.len != 0 or
                sa.payload.listeners.len() != 0 or
                sa.payload.projections.items.len != 0;
            const consequence = if (has_consequences)
                resolution_chain.followAnswer(self, sa.target, sa.payload)
            else
                null;
            var prepared_listeners = try pipeline.prepareAnswerListenerDrain(
                self,
                sa.payload,
                consequence,
            );
            var listeners_prepared = true;
            errdefer if (listeners_prepared) prepared_listeners.abandon(self);
            // A temporary retain bridges carrier consumption and consequence
            // drain. Resolver/listener publication is committed once, then the
            // queue carrier is consumed before any fallible local consequence,
            // so retry can never duplicate the notification.
            try self.session_state.retainAnswerPayload(sa.payload);
            defer {
                self.session_state.retireVirtualAnswer(sa.target);
                self.session_state.retireDetachedAnswer(sa.target, sa.payload);
                self.session_state.releaseAnswerPayload(sa.payload);
            }
            // V1.0 sends the settlement through its resolver callback. The
            // next profile has no wire op:resolve: its mandatory op:listen is
            // the notification path, so only the local consequence drain runs.
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
            settleSentAnswer(self, sa.target, sa.payload, consequence, &prepared_listeners) catch |err| {
                prepared_listeners.abandon(self);
                listeners_prepared = false;
                self.session_state.retireReleasedLocalPromiseAnswer(sa.target.name);
                const consumed = self.takePending();
                consumed.item.deinit(self);
                emitTerminalConsequenceFailure(self, err);
                return err;
            };
            listeners_prepared = false;
            const consumed = self.takePending();
            consumed.item.deinit(self);
        },
        .next_answered => |pair| {
            try stepNextAnswered(self, pair);
            var consumed = self.takePending();
            consumed.item.deinit(self);
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

fn emitTerminalConsequenceFailure(self: *Peer, err: anyerror) void {
    self.recordFailure(err);
    const projected = abort_projection.abortForError(err);
    if (projected) |reason| {
        self.commitAbortOutbound(.{ .kind = reason.kind, .message = reason.message }) catch |abort_err| {
            self.recordAbortDeliveryFailure(abort_err);
            self.closeSession();
        };
    } else {
        self.closeSession();
    }
}

fn stepNextAnswered(self: *Peer, pair: outbound.NextAnswered) !void {
    try self.pushEncodedPairFromPending(
        pair.operation,
        pair.listener,
        .already_recorded,
    );
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
///     listeners settle the answer (the listener fire in `settleSentResolve`
///     handles notification).
///   - an answered `op:deliver` gains a synthesized resolver export at encode
///     time, committing the resolver link as it does.
///   - a projection trails an `op:listen` that carries its new answer's
///     resolution back, since the projection ops carry no inline resolver
///     (ADR-0050, ADR-0052). The listen must follow the op that opened the
///     answer on the wire, so it is pushed after the encode.
/// next encodes the message as it stands. Borrows `message`. The pending queue
/// continues owning it until this returns successfully. An `op:abort` closes
/// only after its frame is published so the partner can still take it.
fn emitPendingMessage(self: *Peer, message: model.Message) !void {
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
            try v1_0.encodeResolveAsCallback(self, message.resolve, resolver_import);
        }
        return;
    }

    if (!needs_v1_0) return self.pushEncodedFromPending(message);

    switch (message) {
        .deliver => |deliver| {
            const prepared = try v1_0.prepareOutboundDeliver(self, deliver);
            errdefer prepared.abandon(self);
            try self.pushEncodedFromPending(prepared.message);
        },
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

/// Settle the local consequences of a just-sent `op:resolve`: drain the
/// calls the partner pipelined against the answer and the projections
/// anchored on it (calls first, since a drained call may settle further answers,
/// ADR-0007 § Queue ownership and drain), then fire its listeners. The
/// resolution itself is already stored: `applySentResolve` stored it when
/// this resolve was recorded (`recordSend` routes a sent resolve there), at the
/// same moment the answer's status flipped. A
/// pipelined call, projection, or `op:listen` that arrived between record and
/// this emit already saw the settled answer with its value on hand and was
/// served directly. Only the calls / projections / listeners that anchored
/// while the answer was still pending remain for these drains. The resolution
/// frame is already on `outbound`, so a drain refusal surfaces as a step
/// error without un-sending it. Borrows `resolve`. The caller owns and frees
/// it.
fn settleSentAnswer(
    self: *Peer,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    consequence: ?resolution_chain.Outcome,
    prepared_listeners: *pipeline.PreparedListenerDrain,
) !void {
    try pipeline.drainAnswerConsequencesTarget(self, target, payload, consequence, prepared_listeners);
    self.session_state.retireReleasedLocalPromiseAnswer(target.name);
}
