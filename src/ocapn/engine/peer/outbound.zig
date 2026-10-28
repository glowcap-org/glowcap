//! Peer-local outbound queue admission, accounting, and ownership transfer.
//!
//! Semantic recording and encoding stay in `engine/outbound.zig`. This module
//! owns the transaction that retains those carriers on one Peer. Every payload
//! is measured once, carries its charge through staging, and transfers between
//! Node staging, pending storage, Session answer storage, and encoded frames
//! without an uncharged or double-charged interval.

const std = @import("std");

const model = @import("model");
const session = @import("session");

const semantic = @import("../outbound.zig");
const engine = @import("../mod.zig");
const budget = @import("outbound/budget.zig");
const provisional = @import("provisional.zig");
const BatchId = @import("../node/passable.zig").BatchId;

const Peer = engine.Peer;

/// A pending semantic carrier plus its once-measured admission charge.
pub const PendingOutbound = struct {
    item: semantic.Outbound,
    charge: usize,
    /// Pushed inside an open provisional window, so a failed turn retracts it
    /// (`peer/provisional.zig`).
    provisional: bool = false,
};

pub const PendingReservation = budget.PendingReservation;
pub const InlinePassableStagingReservation = budget.InlinePassableStagingReservation;

/// One authority transaction that may stage several outbound carriers.
/// Admission is checked for the producer as a whole. Every returned seat stays
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

pub const pendingOutboundCharge = budget.pendingCharge;
pub const reservePending = budget.reservePending;
pub const reservePendingCharged = budget.reservePendingCharged;

/// Reserve the POD carrier that will relinquish one application answer after
/// its caller releases it or an in-process observer fires. Commit supplies the
/// answer. This preparation owns its fixed charge and queue seat.
pub fn reserveAnswerRelease(self: *Peer) !PendingReservation {
    return reservePending(self, .{ .answer_release = .{ .position = .from(0), .row_id = 0 } });
}

/// Transfer release responsibility to the pending queue. A staged send carries
/// the claim into its Session row, so a late reply cannot cause a second release.
pub fn publishAnswerRelease(
    self: *Peer,
    reservation: PendingReservation,
    answer: session.OutboundAnswerTarget,
) void {
    if (self.session_state.outbound_answers.live(answer)) |_| {
        // A listen record's position never went on the wire, so a release
        // naming it would be refused by the partner.
        std.debug.assert(self.session_state.outbound_answers.isQuestion(answer.position));
        claimQueuedRelease(self, answer);
    } else {
        std.debug.assert(self.session_state.outbound_answers.reservedStamp(answer.position) == answer.row_id);
        for (self.pending_send.pending()) |*row| switch (row.item) {
            .staged => |*staged| if (staged.answer == answer.position) {
                std.debug.assert(!staged.release_queued);
                staged.release_queued = true;
                break;
            },
            else => {},
        } else unreachable;
    }
    pushPendingAssume(self, reservation, .{ .answer_release = answer });
}

fn claimQueuedRelease(self: *Peer, answer: session.OutboundAnswerTarget) void {
    if (!self.session_state.outboundAnswerReleaseClaimed(answer)) {
        const claimed = self.session_state.claimOutboundAnswerRelease(answer);
        std.debug.assert(claimed);
    }
    self.session_state.consumeOutboundAnswerNotification(answer);
}

pub const reserveInlinePassableStaging = budget.reserveInline;
pub const cancelInlinePassableStaging = budget.cancelInline;
pub const transferInlinePassableStaging = budget.transferInline;

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
    self.pending_send.pushAssumeCapacity(.{
        .item = item,
        .charge = reservation.charge,
        .provisional = self.provisional and provisional.retractable(item),
    });
}

pub fn cancelPendingReservation(self: *Peer, reservation: PendingReservation) void {
    std.debug.assert(self.pending_send_reservations != 0);
    self.pending_send_reservations -= 1;
    std.debug.assert(self.pending_send_bytes >= reservation.charge);
    self.pending_send_bytes -= reservation.charge;
    trimPendingIfIdle(self);
}

/// Give the pending queue its steady footprint back once nothing is queued
/// and no reservation still counts on its capacity.
pub fn trimPendingIfIdle(self: *Peer) void {
    if (self.pending_send_reservations == 0 and self.pending_send.isEmpty())
        self.pending_send.trimDrained(self.allocator);
}

pub const transferPendingChargeToAnswerStore = budget.transferPendingToAnswerStore;

/// Hold the queue position of a carrier the Node starts staging. The row is
/// free: the carrier's bytes stay charged to its staging reservation.
pub fn reserveStagedRow(self: *Peer) !PendingReservation {
    try ensurePendingCapacity(self, 1);
    self.pending_send_reservations += 1;
    return .{ .charge = 0 };
}

/// Whether a send still owns an unconsumed application notification. The
/// Session row owns the usual case. Only sends awaiting Node preparation need
/// the pending-queue walk, before their row exists. No completed-answer cache
/// is needed, and a retracted or released answer cannot acquire a new observer.
pub fn canObserveAnswer(self: *Peer, answer: session.OutboundAnswerTarget) bool {
    if (self.session_state.outbound_answers.live(answer)) |row|
        return !row.application_notification_consumed;
    if (self.session_state.outbound_answers.reservedStamp(answer.position) != answer.row_id) return false;
    for (self.pending_send.pending()) |row| switch (row.item) {
        .staged => |staged| if (staged.answer == answer.position) return !staged.release_queued,
        else => {},
    };
    return false;
}

/// Whether this exact answer is a wire question. A staged send owns its
/// reserved question before Session installs the row; a listen record never
/// does, even though both can be observed through the same answer API.
pub fn isWireAnswer(self: *Peer, answer: session.OutboundAnswerTarget) bool {
    if (self.session_state.outbound_answers.live(answer)) |_| {
        return self.session_state.outbound_answers.isQuestion(answer.position);
    }
    return self.canObserveAnswer(answer);
}

fn stagedRowIndex(self: *Peer, batch: BatchId) ?usize {
    for (self.pending_send.pending(), 0..) |row, index| switch (row.item) {
        .staged => |staged| if (staged.batch == batch) return index,
        else => {},
    };
    return null;
}

/// Move the carrier a finished batch just appended into the row its send
/// reserved. `appended` is how many rows the batch's send pushed: none when
/// the carrier needed no row, so the reservation is simply removed.
pub fn fillStagedRow(self: *Peer, batch: BatchId, appended: usize) void {
    std.debug.assert(appended <= 1);
    // `reserveStagedRow` staged this batch's row when the batch was staged, and
    // the row leaves only through this fill or the batch's retirement.
    const index = stagedRowIndex(self, batch) orelse unreachable;
    const staged = self.pending_send.pending()[index].item.staged;
    if (staged.release_queued) claimQueuedRelease(self, self.session_state.outbound_answers.targetOf(staged.answer.?) orelse unreachable);
    if (appended == 0) return self.pending_send.removePending(index);
    // `appended == 1`: the send pushed exactly the carrier popped here.
    const filled = self.pending_send.popBack() orelse unreachable;
    const rows = self.pending_send.pending();
    rows[index] = .{
        .item = filled.item,
        .charge = filled.charge,
        // The carrier belongs to the turn that made the send, not to
        // whichever window is open when its gift ids arrive.
        .provisional = rows[index].provisional and provisional.retractable(filled.item),
    };
}

pub const StagedRowRemoval = enum {
    /// A retracted window or a closed session already removed it.
    absent,
    removed,
    /// It was the head and a sendable carrier waits behind it, so the Peer
    /// can step.
    unblocked,
};

/// Remove the row of a staged carrier that will never be sent.
pub fn removeStagedRow(self: *Peer, batch: BatchId) StagedRowRemoval {
    const index = stagedRowIndex(self, batch) orelse return .absent;
    self.pending_send.removePending(index);
    trimPendingIfIdle(self);
    const sendable = !self.pending_send.isEmpty() and !blockedOnStaging(self);
    return if (index == 0 and sendable) .unblocked else .removed;
}

/// Whether the row a staged carrier reserved belongs to an open provisional
/// window, so the carrier and everything its batch commits retract with it.
pub fn stagedRowProvisional(self: *Peer, batch: BatchId) bool {
    const index = stagedRowIndex(self, batch) orelse return false;
    return self.pending_send.pending()[index].provisional;
}

/// Withdraw a queued `op:listen` that never reached the wire, undoing what
/// recording it did. The Node's promise proxy queued it inside a turn that
/// failed. Nothing steps a Peer while its turn runs, so it is still here.
pub fn withdrawQueuedListen(self: *Peer, listener: model.ExportPosition) void {
    for (self.pending_send.pending(), 0..) |row, index| switch (row.item) {
        .message => |message| if (message == .listen and message.listen.listener == .near and
            message.listen.listener.near.export_position == listener)
        {
            self.pending_send.removePending(index);
            std.debug.assert(self.pending_send_bytes >= row.charge);
            self.pending_send_bytes -= row.charge;
            self.session_state.retractPreparedListen(message);
            row.item.deinit(self);
            trimPendingIfIdle(self);
            return;
        },
        else => {},
    };
    unreachable;
}

/// Whether the next carrier is still being staged, so nothing can be sent yet. status-allow: pending state or quoted runtime label
pub fn blockedOnStaging(self: *const Peer) bool {
    const head = self.pending_send.peek() orelse return false;
    return head.item == .staged;
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

pub const checkOutboundWaterline = budget.checkWaterline;
pub const admitOutboundProducer = budget.admitProducer;

pub fn ensureOutboundCapacity(self: *Peer, count: usize) !void {
    try self.outbound.ensureUnusedCapacity(self.allocator, count);
}

pub const queuedOutboundBytes = budget.queuedBytes;

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
/// bytes with its own front/back queues. Host admission uses
/// `queuedOutboundBytes`.
pub fn encodedOutboundBytes(self: *const Peer) usize {
    return self.outbound.weight();
}

pub fn hasOutbound(self: *const Peer) bool {
    return !self.outbound.isEmpty();
}
