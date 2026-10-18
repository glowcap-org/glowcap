//! Constant-time ownership accounting for one Peer's retained outbound work.
//!
//! Pending semantic carriers, Node-held Passable transactions, and encoded
//! frames share one Peer waterline of in-flight outbound work. The transfer
//! helpers move a charge between those owners without an uncharged or
//! double-charged interval.
//!
//! Session-retained sent-answer resolutions sit outside it. A
//! stored resolution is durable table state that lives with its answer row,
//! forever, on a session whose partner sends no `op:gc-answers`. Counting it
//! here would saturate the waterline of every long V1.0 session after a few
//! dozen answered calls. The store answers to the
//! session's answer-row and retained-byte caps (`InboundAnswerCapExceeded` and
//! `RetainedAnswerCapExceeded`). `transferPendingToAnswerStore` is where a
//! settlement's stored share leaves flow accounting and enters that separately
//! bounded durable owner.
//!
//! The waterline gates admission only. A transfer, completing work a
//! reservation already admitted, always proceeds, because retained state can
//! shrink only through completion: a sent answer's stored resolution releases
//! when its carrier encodes, so a waterline that refused transfers while the
//! store was saturated would deadlock, with sixteen concurrently
//! staged answers holding the budget closed against the encodes that would
//! have drained them. Memory stays bounded without gating completion: every
//! staged byte was admitted under the waterline, a completion converts those
//! bytes to encoded frames at no more than one message's encoding expansion,
//! and new producers stay refused until the transport drains.

const std = @import("std");
const model = @import("model");
const semantic = @import("../../outbound.zig");
const engine = @import("../../mod.zig");
const Peer = engine.Peer;

/// One pending queue seat and the charge reserved with it. Published or
/// canceled on the same unwind path.
pub const PendingReservation = struct { charge: usize };

/// A complete carrier's charge admitted while Node projects its foreign
/// Passable tree, before it has a queue seat.
pub const InlinePassableStagingReservation = struct { charge: usize };

/// Exact admission charge while one answer settlement is split across a fixed
/// pending carrier and an owned Session resolution. The carrier type is passed
/// explicitly so this budget owner, rather than an enqueue caller, remains the
/// authority for the representation's fixed charge.
pub const AnswerSettlementCharge = struct {
    total: usize,
    resolution: usize,
    carrier: usize,
};

pub fn answerSettlementCharge(
    comptime Carrier: type,
    resolution_charge: usize,
) !AnswerSettlementCharge {
    const carrier_charge = @sizeOf(Carrier);
    return .{
        .total = std.math.add(usize, carrier_charge, resolution_charge) catch
            return error.MalformedView,
        .resolution = resolution_charge,
        .carrier = carrier_charge,
    };
}

/// Measure one staged carrier once at admission. Store-backed carriers are
/// POD. Owned messages account for their retained model bytes.
pub fn pendingCharge(item: semantic.Outbound) !usize {
    return switch (item) {
        .answer_release => @sizeOf(@TypeOf(item)),
        .message => |message| model.measureMessageOwnedBytes(message),
        .encoded => |sent| sent.charge(),
        .settled_answer => |settled| settled.reservation_charge,
        .listener_fire => @sizeOf(@TypeOf(item)),
        // The staged carrier's bytes stay charged to its Node staging
        // reservation until the batch fills this row.
        .staged => 0,
    };
}

/// Reserve shared outbound budget and one queue seat before protocol state
/// commits. The result must be published or canceled on the same unwind path.
pub fn reservePending(self: *Peer, item: semantic.Outbound) !PendingReservation {
    const handshake = switch (item) {
        .message => |message| message == .start_session,
        else => false,
    };
    return reservePendingCharged(self, try pendingCharge(item), handshake);
}

/// Reserve a pending seat for a carrier whose charge the caller already
/// measured: the inventoried send path, whose inventory carries the tree's
/// bytes. A handshake is exempt from backpressure, because the session cannot
/// open without it.
pub fn reservePendingCharged(self: *Peer, charge: usize, handshake: bool) !PendingReservation {
    if (!handshake) try admitProducer(self, charge);
    try self.pending_send.ensureUnusedCapacity(
        self.allocator,
        self.pending_send_reservations + 1,
    );
    self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
        return error.OutboundBackpressure;
    self.pending_send_reservations += 1;
    return .{ .charge = charge };
}

/// Refuse a producer of `charge` bytes that the budget cannot hold or that
/// arrives at the waterline, before it costs anything.
pub fn admitProducer(self: *const Peer, charge: usize) !void {
    if (charge > self.outbound_budget) return error.OutboundBackpressure;
    try checkWaterline(self);
}

/// Admit a complete carrier while Node projects its foreign Passable tree.
pub fn reserveInline(self: *Peer, charge: usize) !InlinePassableStagingReservation {
    try admitProducer(self, charge);
    self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
        return error.OutboundBackpressure;
    return .{ .charge = charge };
}

pub fn cancelInline(self: *Peer, reservation: InlinePassableStagingReservation) void {
    std.debug.assert(self.pending_send_bytes >= reservation.charge);
    self.pending_send_bytes -= reservation.charge;
}

/// Transfer an already-charged Node staging carrier into pending storage.
pub fn transferInline(
    self: *Peer,
    staged: InlinePassableStagingReservation,
    item: semantic.Outbound,
) !PendingReservation {
    const charge = try pendingCharge(item);
    if (charge > self.outbound_budget) return error.OutboundBackpressure;
    // The staged producer finishes across the waterline (see the module doc):
    // this commit converts an admitted inline reservation into its pending
    // carrier, and refusing it here is how a saturated queue deadlocked
    // against its own drain. Only the single-item ceiling above remains.
    try self.pending_send.ensureUnusedCapacity(
        self.allocator,
        self.pending_send_reservations + 1,
    );
    if (charge > staged.charge) {
        self.pending_send_bytes = std.math.add(
            usize,
            self.pending_send_bytes,
            charge - staged.charge,
        ) catch return error.OutboundBackpressure;
    } else {
        std.debug.assert(self.pending_send_bytes >= staged.charge - charge);
        self.pending_send_bytes -= staged.charge - charge;
    }
    self.pending_send_reservations += 1;
    return .{ .charge = charge };
}

/// Move the owned-resolution portion into Session storage without changing
/// the aggregate waterline or measuring the payload again.
pub fn transferPendingToAnswerStore(self: *Peer, reservation: *PendingReservation, store_charge: usize) void {
    std.debug.assert(reservation.charge >= store_charge);
    std.debug.assert(self.pending_send_bytes >= store_charge);
    reservation.charge -= store_charge;
    self.pending_send_bytes -= store_charge;
}

/// Refuse a new producer once all retained outbound work reaches the waterline.
pub fn checkWaterline(self: *const Peer) !void {
    const current = std.math.add(usize, self.pending_send_bytes, self.outbound.weight()) catch
        return error.OutboundBackpressure;
    if (current >= self.outbound_budget) return error.OutboundBackpressure;
}

/// Constant-time aggregate of pending carriers and encoded frames. Durable
/// sent resolutions answer to the session's table bounds, not this flow
/// waterline. Host and adapters use this without re-walking payloads.
pub fn queuedBytes(self: *const Peer) usize {
    return std.math.add(usize, self.pending_send_bytes, self.outbound.weight()) catch
        std.math.maxInt(usize);
}
