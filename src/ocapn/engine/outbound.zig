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
const encoded = @import("outbound/encoded.zig");
const listener_fire = @import("outbound/listener_fire.zig");
const outbound_copying = @import("outbound/copying.zig");
const lower = @import("lower.zig");
const passable = @import("node/passable.zig");
const outbound_budget = @import("peer/outbound/budget.zig");
const pipeline = @import("pipeline.zig");
const resolution_chain = @import("resolution_chain.zig");
const v1_0 = @import("v1_0.zig");

const freeMessage = model.freeMessage;

pub const StoreTarget = listener_fire.StoreTarget;
pub const FireTarget = listener_fire.FireTarget;
pub const Encoded = encoded.Encoded;

const SettledAnswer = struct {
    target: session.AnswerTarget,
    payload: *session.AnswerPayload,
    /// Charge represented by this carrier at its current admission phase.
    /// Before the Session commit it covers the complete settlement. After the
    /// resolution charge moves into the answer store it is this fixed
    /// carrier's charge.
    reservation_charge: usize,
};

/// One slot in the outbound queue. The kinds the drain must still inspect
/// queue a fully-built `message` the queue owns until `step` encodes it. A
/// deliver leaves as its frame at admission instead (`outbound/encoded.zig`,
/// ADR-0236). A sent `op:resolve` is the other exception: its
/// resolution lives in the answer store (recording moves it there), so the
/// queue holds only `settled_answer`, the position of the inbound answer it
/// settles, its incarnation stamp, and a retained pointer to that incarnation's
/// payload, and `step` reads the resolution from that one store to encode.
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
    /// One relinquished application answer, including a send still being
    /// prepared. The position is POD. Recording the decrement waits
    /// until the release frame is encoded, so deferred V1.0 answer setup runs
    /// first and allocator/backpressure refusal remains retryable.
    answer_release: model.AnswerPosition,
    /// A deliver encoded with its inline subscription. The frame and the
    /// authority a retracted turn gives back are admitted together. `step`
    /// publishes the single frame without another argument-tree walk.
    encoded: Encoded,
    /// A sent `op:resolve` whose resolution lives in the inbound answer store
    /// (recording moves it there). Carries the answer position *and* the
    /// stable payload owner. Answer positions are partner-named and reusable.
    /// The payload pointer and `AnswerTarget` preserve the accepted resolver or
    /// listener obligation independently of the live name.
    settled_answer: SettledAnswer,
    /// One `op:listen` fire. The `target` names which payload `step` borrows at
    /// encode: an inbound answer payload, a handoff-imported
    /// third-party promise (ADR-0009), or a live object export's POD
    /// `fulfill(near)` (`FireTarget.near_object`). Store-backed targets carry
    /// exact store identity inside their arm, stamped at queue time.
    /// `near_object` encodes from the export position when the row is still
    /// live. Queue-time accounting already ran (`enqueueFire` in
    /// `pipeline_listeners.zig`). Answer targets retain their payload through
    /// name reuse. Imported targets drop only when their stamped row is gone or
    /// replaced.
    listener_fire: listener_fire.Carrier,
    /// The position of a carrier the Node is still staging (its gift ids have
    /// not arrived). A step stops here, so later carriers keep their order
    /// behind it. The batch fills the row when it finishes and removes it when
    /// it fails.
    staged: Staged,

    pub const Staged = struct {
        batch: passable.BatchId,
        /// The staged carrier is a deliver, so a provisional window retracts it.
        deliver: bool,
        /// A queued release owns this answer across preparation.
        release_queued: bool = false,
        /// A staged send owns this answer before its Session row is installed.
        answer: ?model.AnswerPosition,
    };

    pub fn deinit(self: Outbound, peer: *Peer) void {
        switch (self) {
            .answer_release, .staged => {},
            .settled_answer => |settled| {
                peer.session_state.retireVirtualAnswer(settled.target);
                peer.session_state.retireDetachedAnswer(settled.target, settled.payload);
                peer.session_state.releaseAnswerPayload(settled.payload);
                peer.session_state.collectLocalPromiseProjections();
            },
            .listener_fire => |fire| listener_fire.deinit(fire, peer),
            .encoded => |sent| sent.deinit(peer),
            .message => |message| freeMessage(peer.allocator, message),
        }
    }
};

/// Record and enqueue one *flat* (no-decomposition) `message` for outbound
/// encode, taking ownership of its heap. The shared tail of `send` and the
/// decomposed-chain links, kept separate so the chain links bypass the
/// (already-checked) multi-hop guard, breaking the `send` recursion cycle.
pub fn enqueueRecorded(self: *Peer, message: model.Message) !void {
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
    // One walk certifies the tree's shape and lists what every later pass
    // returns to (ADR-0234). A refused shape frees the message here, before
    // any authority or queue seat is touched.
    const inventory = self.session_state.inventoryMessage(message) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };
    defer inventory.deinit(self.allocator);
    return enqueueInventoried(self, message, inventory);
}

/// Record and enqueue `message`, borrowing it for the call. A deliver whose
/// tree lists no reference is freight: the session rewrites nothing in it,
/// the Node stages nothing from it (`passable/walk.zig` counts only what the
/// inventory lists), and the encoder reads it once, so it leaves as its
/// frame before this returns and the caller owns its storage again. A tree
/// that lists a reference, handoff, or set is cloned and sent owned, because
/// the session rewrites those slots in place and the Node may hold the tree
/// while it stages a handoff. Every other kind is cloned, since the drain
/// still inspects it at emission. These clones are the named outbound
/// boundary copy (memory-ledger skill).
pub fn enqueueBorrowed(self: *Peer, message: model.Message) !void {
    switch (message) {
        .deliver => |deliver| {
            const inventory = try self.session_state.inventoryMessage(message);
            defer inventory.deinit(self.allocator);
            if (inventory.slots.len != 0)
                return enqueueRecorded(self, try model.cloneMessage(self.allocator, message));
            var envelope: model.Message = .{ .deliver = deliver };
            if (self.node_services) |services| {
                if (services.lowering_active.*) try lower.lowerMessage(services, &envelope, inventory);
            }
            self.session_state.rewriteShortenedMessage(&envelope, inventory);
            return encoded.admit(self, envelope, inventory, null);
        },
        .resolve => |resolve| return enqueueAnswerResolutionOwned(
            self,
            .fromWire(resolve.answer),
            try outbound_copying.cloneResolution(self, resolve.resolution),
        ),
        else => return enqueueRecorded(self, try model.cloneMessage(self.allocator, message)),
    }
}

/// Record and enqueue a deliver whose arguments the caller lends as views
/// (ADR-0246): the Host's values behind a sequence table, or a delivery
/// forwarded from the frame it arrived in. The tree is freight, values
/// only, and the session certifies it as such; a reference or handoff in it
/// refuses the send. The envelope's own references are lowered and
/// shortened as on the owned path, and the deliver leaves as its frame
/// before this returns, so the views are the caller's again.
pub fn enqueueFreight(self: *Peer, target: model.Reference, args: model.view.Args, answer: ?model.AnswerPosition) !void {
    var envelope: model.Message = .{ .deliver = .{ .target = target, .args = &.{}, .answer = answer } };
    if (self.node_services) |services| {
        if (services.lowering_active.*) try lower.lowerMessage(services, &envelope, .none);
    }
    self.session_state.rewriteShortenedMessage(&envelope, .none);
    return encoded.admit(self, envelope, .none, args);
}

/// `enqueueRecorded` for a message whose inventory the caller already took:
/// the Node's finished staging batch, which inventoried the message to
/// validate it before handing it over. Consumes `message` on every outcome
/// and borrows `inventory`. Never a resolve, which `enqueueRecorded` routes
/// to its settlement path first.
pub fn enqueueInventoried(self: *Peer, message_in: model.Message, inventory: session.Inventory) !void {
    // Lower any node-local foreign-import token this message carries to its
    // wire reference, in place, before it is recorded or encoded (ADR-0069).
    // This is the single chokepoint every flat outbound message funnels
    // through, the direct send, each decomposed pipeline link, a prepared
    // fetch, so a token cannot leak onto the wire in any position. A
    // `RouteNotLowerable` aborts the send with the message still owned here.
    var message = message_in;
    std.debug.assert(message != .resolve);

    if (self.node_services) |services| {
        if (services.lowering_active.*) {
            var semantic: passable.Outbound = .{ .message = message };
            const staged = services.stageOutbound(&semantic, inventory) catch |err| {
                semantic.deinit(&self.session_state);
                return err;
            };
            if (staged) return;
            message = semantic.message;
            lower.lowerMessage(services, &message, inventory) catch |err| {
                freeMessage(self.allocator, message);
                return err;
            };
        }
    }

    self.session_state.rewriteShortenedMessage(&message, inventory);
    if (encoded.admits(self, message)) {
        defer freeMessage(self.allocator, message);
        return encoded.admit(self, message, inventory, null);
    }
    // A release may carry a shortening closure: trailing entries that are the
    // session's own retains, recorded apart from the caller's below.
    const closure_len: usize = if (message == .gc_export)
        self.session_state.expandShorteningGcExportReleases(self.allocator, &message.gc_export) catch |err| {
            freeMessage(self.allocator, message);
            return err;
        }
    else
        0;

    // The queue row's charge: the message's envelope plus the tree the
    // inventory measured, after the release closure grew the envelope.
    const charge = messageCharge(message, inventory) catch |err| {
        freeMessage(self.allocator, message);
        return err;
    };

    var owned_needs_free = true;
    errdefer if (owned_needs_free) freeMessage(self.allocator, message);

    const reservation = try self.reservePendingCharged(charge, message == .start_session);
    self.pushPendingAssume(reservation, .{ .message = message });
    owned_needs_free = false;
    var appended = true;
    errdefer if (appended) self.popPendingBack().?.item.deinit(self);

    if (closure_len == 0) {
        try self.session_state.recordSendInventoried(message, inventory);
    } else {
        // The caller's own entries are validated like any send; the closure
        // behind them spends what the session adopted for exactly this
        // release, so it cannot fail once the caller's part committed.
        const gc_export = message.gc_export;
        const own = gc_export.positions.len - closure_len;
        try self.session_state.recordSend(.{ .gc_export = .{
            .positions = gc_export.positions[0..own],
            .deltas = gc_export.deltas[0..own],
        } });
        self.session_state.recordSessionImportRelease(.{
            .positions = gc_export.positions[own..],
            .deltas = gc_export.deltas[own..],
        });
    }
    if (message == .start_session) self.settleNegotiatedProfile();
    appended = false;
}

/// A queued tree's admission charge: its envelope plus the bytes the
/// inventory measured.
pub fn messageCharge(message: model.Message, inventory: session.Inventory) !usize {
    const envelope = try model.measureMessageEnvelopeBytes(message);
    return std.math.add(usize, envelope, inventory.owned_bytes) catch error.MalformedView;
}

/// Record and queue one owned semantic answer settlement. `answer` may be a
/// partner-selected wire position or a session-local virtual answer. The queue
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
/// before entropy staging. The Node checks the stamp before entering here. The
/// synchronous enqueue then preserves the ordinary store-backed carrier stamp.
pub fn enqueueStagedAnswerSettlementOwned(
    self: *Peer,
    settlement: passable.AnswerSettlement,
    inventory: session.Inventory,
    staged_owner: *?Peer.InlinePassableStagingReservation,
) !void {
    return enqueueAnswerSettlementOwned(self, settlement, .{ .staged = .{
        .owner = staged_owner,
        .inventory = inventory,
    } });
}

fn enqueueAnswerSettlementOwned(
    self: *Peer,
    settlement_in: passable.AnswerSettlement,
    admission: AnswerSettlementAdmission,
) !void {
    var semantic: passable.Outbound = .{ .answer_settlement = settlement_in };
    // A fresh settlement is inventoried here, once; a staged one arrives with
    // the inventory its batch took to validate it.
    const fresh_inventory: ?session.Inventory = switch (admission) {
        .fresh => self.session_state.inventoryResolution(settlement_in.resolution) catch |err| {
            semantic.deinit(&self.session_state);
            return err;
        },
        .staged => null,
    };
    defer if (fresh_inventory) |inventory| inventory.deinit(self.allocator);
    const inventory = fresh_inventory orelse admission.staged.inventory;
    if (admission == .fresh) {
        if (self.node_services) |services| if (services.lowering_active.*) {
            const staged = services.stageOutbound(&semantic, inventory) catch |err| {
                semantic.deinit(&self.session_state);
                return err;
            };
            if (staged) return;
            lower.lowerResolution(
                services,
                &semantic.answer_settlement.resolution,
                inventory,
            ) catch |err| {
                semantic.deinit(&self.session_state);
                return err;
            };
        };
    }
    const settlement = semantic.answer_settlement;
    const charge = outbound_budget.answerSettlementCharge(
        Outbound,
        inventory.owned_bytes,
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
        .staged => |staged| transferAnswerStaging(self, staged.owner, item),
    } catch |err| {
        semantic.deinit(&self.session_state);
        return err;
    };
    self.session_state.recordSentResolutionTarget(
        settlement.target,
        settlement.payload,
        settlement.resolution,
        inventory,
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
    staged: struct {
        owner: *?Peer.InlinePassableStagingReservation,
        inventory: session.Inventory,
    },
};

fn transferAnswerStaging(
    self: *Peer,
    staged_owner: *?Peer.InlinePassableStagingReservation,
    item: Outbound,
) !Peer.PendingReservation {
    // `finish` passes the batch's staging reservation, which the batch holds
    // until this transfer consumes it.
    const transferred = try self.transferInlinePassableStaging(staged_owner.* orelse unreachable, item);
    staged_owner.* = null;
    return transferred;
}
