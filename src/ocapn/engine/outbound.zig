//! The outbound enqueue/encode path: pending-send carriers, store-borrow fires,
//! and the encode step that drains them onto `outbound`.
//!
//! Free functions over `*Peer`, the same shape `inbound.zig` and `pipeline.zig`
//! use. The public `Peer.send` / `takeOutbound` surface stays on `Peer` in
//! `mod.zig` and calls in here.

const std = @import("std");

const codec = @import("codec");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const Peer = engine.Peer;

const abort_projection = @import("abort_projection.zig");
const listener_fire = @import("outbound/listener_fire.zig");
const lower = @import("lower.zig");
const passable = @import("node/passable.zig");
const outbound_budget = @import("peer/outbound/budget.zig");
const pipeline = @import("pipeline.zig");
const v1_0 = @import("v1_0.zig");

const freeMessage = model.freeMessage;

pub const StoreTarget = listener_fire.StoreTarget;
pub const FireTarget = listener_fire.FireTarget;

const NextAnswered = struct {
    operation: model.Message,
    listener: model.Message,
};

const SettledAnswer = struct {
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    /// Charge represented by this carrier at its current admission phase.
    /// Before the Session commit it covers the complete settlement; after the
    /// resolution charge moves into the answer store it is exactly this fixed
    /// carrier's charge.
    reservation_charge: usize,
};

/// One slot in the outbound queue. Most kinds queue a fully-built `message` the
/// queue owns until `step` encodes it. A sent `op:resolve` is the exception: its
/// resolution lives in the answer store (it moved there at record time), so the
/// queue holds only `settled_answer` — the position of the inbound answer it
/// settles, its incarnation stamp, and a retained pointer to that incarnation's
/// payload — and `step` reads the resolution from that one store to encode.
/// That single store ownership is the point: the resolution is not copied into a
/// frame here and the store there. Inbound `op:gc-answers` releases the live
/// pipelining name, not a resolver/listener notification already accepted for
/// that incarnation. The retained payload therefore survives legal position
/// reuse and cannot be redirected to the replacement row.
///
/// A listener fire rides the same store-borrow pattern: when a promise with N
/// listeners resolves, each fire queues a POD `listener_fire` carrier instead
/// of N payload clones, and `step` borrows the stored resolution back to encode
/// (`pipeline.borrowedListenerFire`). Answer-backed fires retain the exact
/// payload box, so releasing/reusing its former wire name neither cancels nor
/// redirects the notification. Imported-promise fires still validate their
/// row stamp because that store does not have detached notification ownership.
/// A stored payload cannot change under a queued carrier: an answer resolves once (`validateInboundResolve` /
/// `applySentResolve`) and a relayed resolution records once
/// (`recordRelayedResolution` refuses a second relay), so a matching identity
/// stamp proves the payload too.
pub const Outbound = union(enum) {
    message: model.Message,
    /// A next-profile answered operation and the mandatory listener that must
    /// immediately follow it. `step` encodes both and reserves both outbound
    /// slots before publishing either frame, so an internal allocation failure
    /// cannot expose the operation without its listener.
    next_answered: NextAnswered,
    /// A sent `op:resolve` whose resolution lives in the inbound answer store
    /// (it moved there at record time). Carries the answer position *and* the
    /// stable payload owner. Answer positions are partner-named and reusable;
    /// the payload pointer and `AnswerTarget` preserve the accepted resolver or
    /// listener obligation independently of the live name.
    settled_answer: SettledAnswer,
    /// One `op:listen` fire. The `target` names which payload `step` borrows at
    /// encode: an inbound answer payload, a handoff-imported
    /// third-party promise (ADR-0009), or a live object export's POD
    /// `fulfill(near)` (`FireTarget.near_object`). Store-backed targets carry
    /// exact store identity inside their arm, stamped at queue time;
    /// `near_object` encodes from the export position when the row is still
    /// live. Queue-time accounting already ran (`pipeline.enqueueFire` /
    /// `enqueueNearObjectFire`). Answer targets retain their payload through
    /// name reuse; imported targets drop only when their stamped row is gone or
    /// replaced.
    listener_fire: listener_fire.Carrier,

    pub fn deinit(self: Outbound, peer: *Peer) void {
        switch (self) {
            .settled_answer => |settled| {
                peer.session_state.retireDetachedAnswer(settled.target, settled.payload);
                peer.session_state.releaseAnswerPayload(settled.payload);
            },
            .listener_fire => |fire| listener_fire.deinit(fire, peer),
            .next_answered => |pair| {
                freeMessage(peer.allocator, pair.operation);
                freeMessage(peer.allocator, pair.listener);
            },
            .message => |message| freeMessage(peer.allocator, message),
        }
    }
};

/// Record and enqueue one *flat* (no-decomposition) `message` for outbound
/// encode, taking ownership of its heap. The shared tail of `send` and the
/// decomposed-chain links — kept separate so the chain links bypass the
/// (already-checked) multi-hop guard, breaking the `send` recursion cycle.
pub fn enqueueRecorded(self: *Peer, message_in: model.Message) !void {
    // Lower any node-local foreign-import token this message carries to its
    // wire reference, in place, before it is recorded or encoded (ADR-0069).
    // This is the single chokepoint every flat outbound message funnels
    // through — the direct send, each decomposed pipeline link, a prepared
    // fetch — so a token cannot leak onto the wire in any position. A
    // `RouteNotLowerable` aborts the send with the message still owned here.
    var message = message_in;

    // A resolve's semantic answer identity must survive Node staging. Convert
    // the wire-only message shape before the Passable transaction so the same
    // path also serves resolver-only virtual answers without inventing a wire
    // position.
    if (message == .resolve) {
        return enqueueAnswerResolutionOwned(
            self,
            .fromWire(message.resolve.answer),
            message.resolve.resolution,
        );
    }

    if (self.node_services) |services| {
        if (services.lowering_active.*) {
            var semantic: passable.Outbound = .{ .message = message };
            const staged = services.stageOutbound(&semantic) catch |err| {
                semantic.deinit(&self.session_state);
                return err;
            };
            if (staged) return;
            message = semantic.message;
            lower.lowerMessage(services, &message) catch |err| {
                freeMessage(self.allocator, message);
                return err;
            };
        }
    }

    self.session_state.rewriteShortenedMessage(&message);
    if (message == .gc_export) {
        self.session_state.expandShorteningGcExportReleases(self.allocator, &message.gc_export) catch |err| {
            freeMessage(self.allocator, message);
            return err;
        };
    }

    if (self.session_state.captp_version == .next) {
        if (answerProducedBy(message)) |answer| {
            return enqueueNextAnsweredOperation(self, message, answer);
        }
    }

    var owned_needs_free = true;
    errdefer if (owned_needs_free) freeMessage(self.allocator, message);

    const reservation = try self.reservePending(.{ .message = message });
    self.pushPendingAssume(reservation, .{ .message = message });
    owned_needs_free = false;
    var appended = true;
    errdefer if (appended) self.popPendingBack().?.item.deinit(self);

    try self.session_state.recordSend(message);
    appended = false;
}

/// Record and queue one owned semantic answer settlement. `answer` may be a
/// partner-selected wire position or a session-local virtual answer; the queue
/// retains that distinction through publication and consequence drain.
pub fn enqueueAnswerResolutionOwned(
    self: *Peer,
    answer: model.AnswerName,
    resolution: model.Resolution,
) !void {
    const settlement = self.session_state.beginAnswerSettlementNamed(answer) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    return enqueueAnswerSettlementOwned(self, .{
        .target = settlement.target,
        .payload = settlement.payload,
        .resolution = resolution,
    }, .fresh);
}

pub fn enqueueAnswerTargetResolutionOwned(
    self: *Peer,
    target: session.AnswerTarget,
    resolution: model.Resolution,
) !void {
    const settlement = self.session_state.beginAnswerSettlement(target) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    return enqueueAnswerSettlementOwned(self, .{
        .target = settlement.target,
        .payload = settlement.payload,
        .resolution = resolution,
    }, .fresh);
}

/// Complete a Node-owned settlement whose answer incarnation was stamped
/// before entropy staging. The Node checks the stamp before entering here; the
/// synchronous enqueue then preserves the ordinary store-backed carrier stamp.
pub fn enqueueStagedAnswerSettlementOwned(
    self: *Peer,
    settlement: passable.AnswerSettlement,
    staged_owner: *?Peer.InlinePassableStagingReservation,
) !void {
    return enqueueAnswerSettlementOwned(self, settlement, .{ .staged = staged_owner });
}

fn enqueueAnswerSettlementOwned(
    self: *Peer,
    settlement_in: passable.AnswerSettlement,
    admission: AnswerSettlementAdmission,
) !void {
    var semantic: passable.Outbound = .{ .answer_settlement = settlement_in };
    if (admission == .fresh) {
        if (self.node_services) |services| if (services.lowering_active.*) {
            const staged = services.stageOutbound(&semantic) catch |err| {
                semantic.deinit(&self.session_state);
                return err;
            };
            if (staged) return;
            lower.lowerResolution(
                services,
                &semantic.answer_settlement.resolution,
            ) catch |err| {
                semantic.deinit(&self.session_state);
                return err;
            };
        };
    }
    const settlement = semantic.answer_settlement;
    const charge = outbound_budget.measureAnswerSettlementCharge(
        Outbound,
        settlement.resolution,
    ) catch |err| {
        semantic.deinit(&self.session_state);
        return err;
    };
    const item: Outbound = .{ .settled_answer = .{
        .target = settlement.target,
        .payload = settlement.payload,
        .reservation_charge = charge.total,
    } };
    var reservation = switch (admission) {
        .fresh => self.reservePending(item),
        .staged => |staged_owner| transferAnswerStaging(self, staged_owner, item),
    } catch |err| {
        semantic.deinit(&self.session_state);
        return err;
    };
    self.session_state.recordSentResolutionTarget(
        settlement.target,
        settlement.payload,
        settlement.resolution,
    ) catch |err| {
        self.cancelPendingReservation(reservation);
        self.session_state.releaseAnswerPayload(settlement.payload);
        return err;
    };
    self.transferPendingChargeToAnswerStore(&reservation, charge.resolution);
    std.debug.assert(reservation.charge == charge.carrier);
    self.pushPendingAssume(reservation, .{ .settled_answer = .{
        .target = settlement.target,
        .payload = settlement.payload,
        .reservation_charge = reservation.charge,
    } });
}

const AnswerSettlementAdmission = union(enum) {
    fresh,
    staged: *?Peer.InlinePassableStagingReservation,
};

fn transferAnswerStaging(
    self: *Peer,
    staged_owner: *?Peer.InlinePassableStagingReservation,
    item: Outbound,
) !Peer.PendingReservation {
    const transferred = try self.transferInlinePassableStaging(staged_owner.* orelse unreachable, item);
    staged_owner.* = null;
    return transferred;
}

fn answerProducedBy(message: model.Message) ?model.AnswerPosition {
    return switch (message) {
        .deliver => |deliver| deliver.answer,
        .get => |get| get.answer,
        .index => |index| index.answer,
        .untag => |untag| untag.answer,
        else => null,
    };
}

/// Queue a next-profile operation and its mandatory shortening-capable listen
/// as one preparation. Every fallible resource is acquired before `recordSend`
/// commits the operation's answer; the two queue appends are then infallible and
/// preserve wire order.
fn enqueueNextAnsweredOperation(
    self: *Peer,
    message: model.Message,
    answer: model.AnswerPosition,
) !void {
    const resolver_export = self.session_state.mintMentionedResolverExport(answer, .object) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };
    var resolver_owned = true;
    errdefer if (resolver_owned)
        self.session_state.abandonMentionedResolverExport(resolver_export);

    const listener: model.Message = .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = answer } },
        .listener = session.slot.toReference(self.session_state.exportSlot(resolver_export).?).?,
        .mode = .shortening_or_settling,
    } };
    const reservation = self.reservePending(.{ .next_answered = .{
        .operation = message,
        .listener = listener,
    } }) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };

    self.session_state.recordSend(message) catch |err| {
        self.cancelPendingReservation(reservation);
        freeMessage(self.allocator, message);
        return err;
    };
    self.pushPendingAssume(reservation, .{ .next_answered = .{
        .operation = message,
        .listener = listener,
    } });
    resolver_owned = false;
}

/// Encode the front pending-send item during `step`. Every carrier remains at
/// the queue front until its complete wire publication succeeds. V1.0
/// translation may install resolver authority while preparing a message; its
/// preparation owns rollback until the corresponding frame or frame pair is
/// queued, so allocator pressure is retryable without losing a carrier or
/// leaving a partial projection transaction on the wire.
pub fn stepPending(self: *Peer) !void {
    const pending = self.pending_send.peek() orelse unreachable;
    switch (pending.item) {
        .settled_answer => |sa| {
            const stored = self.session_state.answerPayloadResolution(sa.payload) orelse unreachable;
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
                    try v1_0.encodeResolutionAsCallback(self, stored.*, resolver_import, pending.charge);
                    self.session_state.clearAnswerPayloadResolver(sa.target, sa.payload);
                }
            }
            // Once notification is committed (or, on next, deliberately
            // omitted), a consequence-drain failure must not retain the
            // carrier and repeat the settlement on retry.
            // A sent `op:resolve` also settles one of our inbound answers locally.
            const consumed = self.takePending();
            consumed.item.deinit(self);
            try settleSentAnswer(self, sa.target, sa.payload, stored.*);
        },
        .next_answered => |pair| {
            try stepNextAnswered(self, pending.charge, pair);
            var consumed = self.takePending();
            consumed.item.deinit(self);
        },
        .message => |message| {
            try emitPendingMessage(self, message, pending.charge);
            var consumed = self.takePending();
            consumed.item.deinit(self);
        },
        .listener_fire => |fire| {
            try emitPendingListenerFire(self, pending.charge, fire);
            const consumed = self.takePending();
            consumed.item.deinit(self);
        },
    }
}

fn stepNextAnswered(self: *Peer, staged_charge: usize, pair: NextAnswered) !void {
    try pushEncodedPairFromPending(self, staged_charge, pair.operation, pair.listener);
}

/// Encode and publish two adjacent frames as one pending-carrier transaction.
/// Both encodes, the waterline check, and both queue slots are acquired before
/// either frame becomes visible, so the first half can never escape alone.
fn pushEncodedPairFromPending(
    self: *Peer,
    staged_charge: usize,
    first: model.Message,
    second: model.Message,
) !void {
    var operation_frame = try codec.dispatch.encodeMessageForProfile(
        self.session_state.codec,
        self.allocator,
        self.session_state.captp_version,
        first,
    );
    errdefer operation_frame.deinit();
    var listener_frame = try codec.dispatch.encodeMessageForProfile(
        self.session_state.codec,
        self.allocator,
        self.session_state.captp_version,
        second,
    );
    errdefer listener_frame.deinit();
    try self.checkOutboundTransferWaterline(staged_charge);
    try self.ensureOutboundCapacity(2);

    self.outbound.pushAssumeCapacity(operation_frame);
    self.outbound.pushAssumeCapacity(listener_frame);
}

fn emitPendingListenerFire(self: *Peer, staged_charge: usize, fire: listener_fire.Carrier) !void {
    var args: [2]model.Argument = undefined;
    if (listener_fire.borrowedMessage(self, fire, &args)) |message|
        try emitPendingMessage(self, message, staged_charge);
}

/// Encode one pending message onto `outbound`, applying the V1.0
/// translations that have no wire form under next (`v1_0`, ADR-0010):
///   - a semantic `Resolve` ships as a resolver-callback `op:deliver` to the
///     partner's resolver import, or is dropped when only `op:listen`
///     listeners settle the answer (the listener fire in `settleSentResolve`
///     handles notification);
///   - an answered `op:deliver` gains a synthesized resolver export at encode
///     time, committing the resolver link as it does;
///   - a projection trails an `op:listen` that carries its new answer's
///     resolution back, since the projection ops carry no inline resolver
///     (ADR-0050, ADR-0052). The listen must follow the op that opened the
///     answer on the wire, so it is pushed after the encode.
/// next encodes the message as it stands. Borrows `message`; the pending queue
/// continues owning it until this returns successfully. An `op:abort` closes
/// only after its frame is published so the partner can still take it.
fn emitPendingMessage(self: *Peer, message: model.Message, pending_charge: usize) !void {
    if (message == .abort) {
        try self.commitAbortOutbound(message.abort);
        return;
    }

    const needs_v1_0 = self.session_state.needsV1_0Translation();

    if (needs_v1_0 and message == .resolve) {
        // A V1.0 partner hears a resolution only through the resolver
        // capability its own deliver carried (`resolve-me-desc`). A deliver
        // that named an answer but advertised no resolver asked for no
        // callback: there is nobody to notify, so the resolve emits nothing —
        // V1.0 has no wire shape to invent for it.
        if (self.session_state.resolverForInboundAnswer(.fromWire(message.resolve.answer))) |resolver_import| {
            try v1_0.encodeResolveAsCallback(self, message.resolve, resolver_import, pending_charge);
        }
        return;
    }

    if (!needs_v1_0) return self.pushEncodedFromPending(pending_charge, message);

    switch (message) {
        .deliver => |deliver| {
            const prepared = try v1_0.prepareOutboundDeliver(self, deliver);
            errdefer prepared.rollback(self);
            try self.pushEncodedFromPending(pending_charge, prepared.message);
        },
        .get => |get| try emitV1Projection(self, pending_charge, message, get.answer),
        .index => |index| try emitV1Projection(self, pending_charge, message, index.answer),
        .untag => |untag| try emitV1Projection(self, pending_charge, message, untag.answer),
        else => try self.pushEncodedFromPending(pending_charge, message),
    }
}

fn emitV1Projection(
    self: *Peer,
    pending_charge: usize,
    projection: model.Message,
    answer: model.AnswerPosition,
) !void {
    const listener = try v1_0.prepareProjectionListener(self, answer);
    errdefer listener.rollback(self);
    try pushEncodedPairFromPending(self, pending_charge, projection, listener.message);
}

/// Settle the local consequences of a just-sent `op:resolve`: drain the
/// calls the partner pipelined against the answer and the projections
/// anchored on it (calls first — a drained call may settle further answers,
/// ADR-0007 § Queue ownership and drain), then fire its listeners. The
/// resolution itself is already stored — `applySentResolve` stored it when
/// this resolve was recorded (`recordSend` routes a sent resolve there), the
/// same moment the answer's status flipped — so a
/// pipelined call, projection, or `op:listen` that arrived between record and
/// this emit already saw the settled answer with its value on hand and was
/// served directly; only the calls / projections / listeners that anchored
/// while the answer was still pending remain for these drains. The resolution
/// frame is already on `outbound`, so a drain refusal surfaces as a step
/// error without un-sending it. Borrows `resolve`; the caller owns and frees
/// it.
fn settleSentAnswer(
    self: *Peer,
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    resolution: model.Resolution,
) !void {
    try pipeline.drainAnswerConsequencesTarget(self, target, payload, resolution);
    self.session_state.retireReleasedLocalPromiseAnswer(target.name);
}
