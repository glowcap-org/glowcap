//! Peer-local outbound queue admission, accounting, and ownership transfer.
//!
//! Semantic recording and encoding stay in `engine/outbound.zig`; this module
//! owns the transaction that retains those carriers on one Peer. Every payload
//! is measured once, carries its charge through staging, and transfers between
//! Node staging, pending storage, Session answer storage, and encoded frames
//! without an uncharged or double-charged interval.

const std = @import("std");

const model = @import("model");

const semantic = @import("../outbound.zig");
const engine = @import("../mod.zig");
const budget = @import("outbound/budget.zig");

const Peer = engine.Peer;

/// A pending semantic carrier plus its once-measured admission charge.
pub const PendingOutbound = struct {
    item: semantic.Outbound,
    charge: usize,
};

pub const PendingReservation = struct { charge: usize };
pub const InlinePassableStagingReservation = struct { charge: usize };

/// One authority transaction that may stage several outbound carriers.
/// Admission is checked for the producer as a whole; every returned seat stays
/// independently cancelable until its caller commits the matching carrier.
pub const PendingBatch = struct {
    peer: *Peer,
    charge: usize = 0,
    admitted: bool = false,

    pub fn reserve(self: *PendingBatch, item: semantic.Outbound) !PendingReservation {
        const item_charge = try pendingOutboundCharge(item);
        const batch_charge = std.math.add(usize, self.charge, item_charge) catch
            return error.OutboundBackpressure;
        if (batch_charge > self.peer.outbound_budget) return error.OutboundBackpressure;
        if (!self.admitted) {
            try checkOutboundWaterline(self.peer);
            self.admitted = true;
        }
        self.peer.pending_send_bytes = std.math.add(
            usize,
            self.peer.pending_send_bytes,
            item_charge,
        ) catch return error.OutboundBackpressure;
        self.peer.pending_send_reservations += 1;
        self.charge = batch_charge;
        return .{ .charge = item_charge };
    }
};

/// Measure one staged carrier once at admission. Store-backed carriers are
/// POD; owned messages account for their retained model bytes.
pub fn pendingOutboundCharge(item: semantic.Outbound) !usize {
    return budget.pendingCharge(item);
}

/// Reserve shared outbound budget and one queue seat before protocol state
/// commits. The result must be published or canceled on the same unwind path.
pub fn reservePending(self: *Peer, item: semantic.Outbound) !PendingReservation {
    return budget.reservePending(self, item, PendingReservation);
}

/// Reserve the POD carrier that will relinquish one application answer after
/// an in-process observer fires. The answer value is supplied only at commit;
/// its fixed charge and queue seat are the resources this preparation owns.
pub fn reserveAnswerRelease(self: *Peer) !PendingReservation {
    return reservePending(self, .{ .answer_release = .from(0) });
}

pub fn publishAnswerRelease(
    self: *Peer,
    reservation: PendingReservation,
    answer: model.AnswerPosition,
) void {
    pushPendingAssume(self, reservation, .{ .answer_release = answer });
}

/// Admit a complete carrier while Node projects its foreign Passable tree.
pub fn reserveInlinePassableStaging(
    self: *Peer,
    charge: usize,
) !InlinePassableStagingReservation {
    return budget.reserveInline(self, charge, InlinePassableStagingReservation);
}

pub fn cancelInlinePassableStaging(
    self: *Peer,
    reservation: InlinePassableStagingReservation,
) void {
    budget.cancelInline(self, reservation);
}

/// Transfer an already-charged Node staging carrier into pending storage.
pub fn transferInlinePassableStaging(
    self: *Peer,
    staged: InlinePassableStagingReservation,
    item: semantic.Outbound,
) !PendingReservation {
    return budget.transferInline(self, staged, item, PendingReservation);
}

/// Preflight storage once for a multi-carrier authority transaction. The first
/// actual reservation performs admission, so an empty upper bound is inert.
pub fn beginPendingBatch(self: *Peer, max_items: usize) !PendingBatch {
    try ensurePendingCapacity(self, max_items);
    return .{ .peer = self };
}

pub fn ensurePendingCapacity(self: *Peer, count: usize) !void {
    try self.pending_send.ensureUnusedCapacity(
        self.allocator,
        self.pending_send_reservations + count,
    );
}

/// Publish a reserved row infallibly after protocol authority commits.
pub fn pushPendingAssume(
    self: *Peer,
    reservation: PendingReservation,
    item: semantic.Outbound,
) void {
    std.debug.assert(self.pending_send_reservations != 0);
    self.pending_send_reservations -= 1;
    self.pending_send.pushAssumeCapacity(.{ .item = item, .charge = reservation.charge });
}

pub fn cancelPendingReservation(self: *Peer, reservation: PendingReservation) void {
    std.debug.assert(self.pending_send_reservations != 0);
    self.pending_send_reservations -= 1;
    std.debug.assert(self.pending_send_bytes >= reservation.charge);
    self.pending_send_bytes -= reservation.charge;
    if (self.pending_send_reservations == 0 and self.pending_send.isEmpty())
        self.pending_send.trimDrained(self.allocator);
}

/// Move the owned-resolution portion into Session storage without changing
/// the aggregate waterline or measuring the payload again.
pub fn transferPendingChargeToAnswerStore(
    self: *Peer,
    reservation: *PendingReservation,
    store_charge: usize,
) void {
    budget.transferPendingToAnswerStore(self, reservation, store_charge);
}

/// Dequeue one semantic carrier and retire its pending accounting charge.
pub fn takePending(self: *Peer) PendingOutbound {
    const pending = if (self.pending_send_reservations == 0)
        self.pending_send.consumeFront(self.allocator)
    else
        self.pending_send.consumeFrontReserved(self.allocator);
    std.debug.assert(self.pending_send_bytes >= pending.charge);
    self.pending_send_bytes -= pending.charge;
    return pending;
}

/// Roll back only the newest staged append on a caller's error path.
pub fn popPendingBack(self: *Peer) ?PendingOutbound {
    const pending = self.pending_send.popBack() orelse return null;
    std.debug.assert(self.pending_send_bytes >= pending.charge);
    self.pending_send_bytes -= pending.charge;
    return pending;
}

/// Refuse a new producer once all retained outbound work reaches the waterline.
pub fn checkOutboundWaterline(self: *const Peer) !void {
    return budget.checkWaterline(self);
}

pub fn ensureOutboundCapacity(self: *Peer, count: usize) !void {
    try self.outbound.ensureUnusedCapacity(self.allocator, count);
}

/// Constant-time aggregate of pending carriers and encoded frames. Durable
/// sent resolutions answer to the session's table bounds, not this flow
/// waterline. Host and adapters use this without re-walking payloads.
pub fn queuedOutboundBytes(self: *const Peer) usize {
    return budget.queuedBytes(self);
}

/// Whether retained outbound work has reached this peer's waterline. This is
/// the signal an adapter parks new inbound on: every applied frame can only
/// add replies behind the saturation, and the byte-fed Host's feed admission
/// already refuses at the same line. Draining encoded frames is what clears
/// it.
pub fn outboundSaturated(self: *const Peer) bool {
    return budget.queuedBytes(self) >= self.outbound_budget;
}

/// Encoded frames waiting for a transport drain, excluding semantic carriers
/// retained by the session or node. Completion-loop backpressure counts these
/// bytes with its own front/back queues; Host admission uses
/// `queuedOutboundBytes`.
pub fn encodedOutboundBytes(self: *const Peer) usize {
    return self.outbound.weight();
}

pub fn hasOutbound(self: *const Peer) bool {
    return !self.outbound.isEmpty();
}

pub const measureAnswerSettlementCharge = budget.measureAnswerSettlementCharge;
