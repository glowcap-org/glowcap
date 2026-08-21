//! Constant-time ownership accounting for one Peer's retained outbound work.
//!
//! Pending semantic carriers, Node-held Passable transactions, encoded frames,
//! and Session-retained sent-answer resolutions share one Peer waterline. The
//! transfer helpers move a charge between those owners without an uncharged or
//! double-charged interval.

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
    try self.pending_send.ensureUnusedCapacityForOne(self.allocator);
    self.pending_send_bytes = std.math.add(usize, self.pending_send_bytes, charge) catch
        return error.OutboundBackpressure;
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
    // The staged producer may finish across the waterline, but work admitted
    // after it must not make an already-saturated queue accept another
    // semantic commit. Exclude this producer's existing charge exactly as the
    // encoded-frame transfer does.
    try checkTransferWaterline(self, staged.charge);
    try self.pending_send.ensureUnusedCapacityForOne(self.allocator);
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
    return .{ .charge = charge };
}

pub fn transferPendingToAnswerStore(self: anytype, reservation: anytype, store_charge: usize) void {
    std.debug.assert(reservation.charge >= store_charge);
    std.debug.assert(self.pending_send_bytes >= store_charge);
    reservation.charge -= store_charge;
    self.pending_send_bytes -= store_charge;
}

pub fn checkWaterline(self: anytype) !void {
    const retained = std.math.add(
        usize,
        self.pending_send_bytes,
        self.session_state.retainedSentAnswerBytes(),
    ) catch return error.OutboundBackpressure;
    const current = std.math.add(usize, retained, self.outbound.weight()) catch
        return error.OutboundBackpressure;
    if (current >= self.outbound_budget) return error.OutboundBackpressure;
}

pub fn checkTransferWaterline(self: anytype, staged_charge: usize) !void {
    std.debug.assert(staged_charge <= self.pending_send_bytes);
    const retained = std.math.add(
        usize,
        self.pending_send_bytes - staged_charge,
        self.session_state.retainedSentAnswerBytes(),
    ) catch return error.OutboundBackpressure;
    const current = std.math.add(usize, retained, self.outbound.weight()) catch
        return error.OutboundBackpressure;
    if (current >= self.outbound_budget) return error.OutboundBackpressure;
}

pub fn queuedBytes(self: anytype) usize {
    const retained = std.math.add(
        usize,
        self.pending_send_bytes,
        self.session_state.retainedSentAnswerBytes(),
    ) catch return std.math.maxInt(usize);
    return std.math.add(usize, retained, self.outbound.weight()) catch std.math.maxInt(usize);
}
