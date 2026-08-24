//! Constant-time ownership accounting for one Peer's retained outbound work.
//!
//! Pending semantic carriers, Node-held Passable transactions, and encoded
//! frames share one Peer waterline of in-flight outbound work. The transfer
//! helpers move a charge between those owners without an uncharged or
//! double-charged interval.
//!
//! Session-retained sent-answer resolutions are deliberately outside it. A
//! stored resolution is durable table state that lives with its answer row —
//! forever, on a session whose partner sends no `op:gc-answers` — so counting
//! it here made every long V1.0 session saturate its own waterline after a
//! few dozen answered calls and stay saturated. The store answers to the
//! session's answer-row and retained-byte caps (`InboundAnswerCapExceeded` and
//! `RetainedAnswerCapExceeded`); `transferPendingToAnswerStore` is where a
//! settlement's stored share leaves flow accounting and enters that separately
//! bounded durable owner.
//!
//! The waterline gates admission only. A transfer — completing work a
//! reservation already admitted — always proceeds, because retained state can
//! shrink only through completion: a sent answer's stored resolution releases
//! when its carrier encodes, so a waterline that refused transfers while the
//! store was saturated deadlocked exactly there, with sixteen concurrently
//! staged answers holding the budget closed against the encodes that would
//! have drained them. Memory stays bounded without gating completion: every
//! staged byte was admitted under the waterline, a completion converts those
//! bytes to encoded frames at no more than one message's encoding expansion,
//! and new producers stay refused until the transport drains.

const std = @import("std");
const model = @import("model");

/// Exact admission charge while one answer settlement is split across a fixed
/// pending carrier and an owned Session resolution. The carrier type is passed
/// explicitly so this budget owner, rather than an enqueue caller, remains the
/// authority for the representation's fixed charge.
pub const AnswerSettlementCharge = struct {
    total: usize,
    resolution: usize,
    carrier: usize,
};

pub fn measureAnswerSettlementCharge(
    comptime Carrier: type,
    resolution: model.Resolution,
) !AnswerSettlementCharge {
    const resolution_charge = try model.measureResolutionOwnedBytes(resolution);
    const carrier_charge = @sizeOf(Carrier);
    return .{
        .total = std.math.add(usize, carrier_charge, resolution_charge) catch
            return error.MalformedView,
        .resolution = resolution_charge,
        .carrier = carrier_charge,
    };
}

pub fn pendingCharge(item: anytype) !usize {
    return switch (item) {
        .answer_release => @sizeOf(@TypeOf(item)),
        .message => |message| model.measureMessageOwnedBytes(message),
        .next_answered => |pair| blk: {
            const operation = try model.measureMessageOwnedBytes(pair.operation);
            const listener = try model.measureMessageOwnedBytes(pair.listener);
            break :blk std.math.add(usize, operation, listener) catch error.MalformedView;
        },
        .settled_answer => |settled| settled.reservation_charge,
        .listener_fire => @sizeOf(@TypeOf(item)),
    };
}

pub fn reservePending(self: anytype, item: anytype, comptime Reservation: type) !Reservation {
    const charge = try pendingCharge(item);
    const is_handshake = switch (item) {
        .message => |message| message == .start_session,
        else => false,
    };
    if (!is_handshake) {
        if (charge > self.outbound_budget) return error.OutboundBackpressure;
        try checkWaterline(self);
    }
    try self.pending_send.ensureUnusedCapacity(
        self.allocator,
        self.pending_send_reservations + 1,
    );
    self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
        return error.OutboundBackpressure;
    self.pending_send_reservations += 1;
    return .{ .charge = charge };
}

pub fn reserveInline(self: anytype, charge: usize, comptime Reservation: type) !Reservation {
    if (charge > self.outbound_budget) return error.OutboundBackpressure;
    try checkWaterline(self);
    self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
        return error.OutboundBackpressure;
    return .{ .charge = charge };
}

pub fn cancelInline(self: anytype, reservation: anytype) void {
    std.debug.assert(self.pending_send_bytes >= reservation.charge);
    self.pending_send_bytes -= reservation.charge;
}

pub fn transferInline(
    self: anytype,
    staged: anytype,
    item: anytype,
    comptime PendingReservation: type,
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

pub fn transferPendingToAnswerStore(self: anytype, reservation: anytype, store_charge: usize) void {
    std.debug.assert(reservation.charge >= store_charge);
    std.debug.assert(self.pending_send_bytes >= store_charge);
    reservation.charge -= store_charge;
    self.pending_send_bytes -= store_charge;
}

pub fn checkWaterline(self: anytype) !void {
    const current = std.math.add(usize, self.pending_send_bytes, self.outbound.weight()) catch
        return error.OutboundBackpressure;
    if (current >= self.outbound_budget) return error.OutboundBackpressure;
}

pub fn queuedBytes(self: anytype) usize {
    return std.math.add(usize, self.pending_send_bytes, self.outbound.weight()) catch
        std.math.maxInt(usize);
}
