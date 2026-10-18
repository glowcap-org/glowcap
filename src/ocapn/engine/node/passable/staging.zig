//! Staging one inline-Passable transaction: admit the tree, count and collect
//! its projections, and open the batch that waits for their gift ids.
//!
//! `batches.zig` owns the open batches and their completion. This file is the
//! entry that creates one.

const std = @import("std");
const engine = @import("../../mod.zig");
const session_mod = @import("session");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");
const batches = @import("batches.zig");
const passable = @import("../passable.zig");
const walk = @import("walk.zig");
const gift_tickets = @import("../handoffs/gifts/tickets.zig");
const local_custody = @import("local_custody.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

/// Adopt an outbound carrier only when it needs cross-session projection.
pub fn stageOutbound(
    self: *Node,
    recipient_peer: PeerHandle,
    semantic: *passable.Outbound,
    inventory: session_mod.Inventory,
) engine.node_services.OutboundStagingError!bool {
    const recipient = self.peer(recipient_peer) orelse return error.RouteNotLowerable;
    const failure_target = semantic.failureTarget(&recipient.session_state);
    var no_escrow: ?[]u8 = null;
    return stage(self, recipient_peer, semantic, inventory, failure_target, &no_escrow);
}

/// What admission measured and reserved for one staging transaction before
/// any per-projection resource is acquired.
const Admission = struct {
    counts: walk.Counts,
    message_charge: usize,
    current_occurrences: usize,
    next_occurrences: usize,
    /// Completion needs one Host-retain release per projection, exporter/home
    /// flushes, one future promise-settlement flush, and for ordinary outbound
    /// one recipient flush. Failure uses that final correlated terminal seat.
    terminal_reservations: usize,
};

/// Everything `reserve` holds between admission and publication. `abandon`
/// releases it all in reverse order of acquisition, and `publish` consumes
/// it infallibly.
const Reserved = struct {
    recipient: *engine.Peer,
    payload: *passable.Outbound,
    staging_reservation: engine.Peer.InlinePassableStagingReservation,
    gifts: []passable.Gift = &.{},
    promises: []passable.PromiseProjection = &.{},
    claimed_leases: usize = 0,
    staged_row: ?engine.Peer.PendingReservation = null,
    custody_owned: bool = false,
    first_ticket: u64 = 0,

    fn abandon(self: *Reserved, node: *Node) void {
        if (self.custody_owned) local_custody.release(&self.recipient.session_state, self.payload);
        if (self.staged_row) |row| self.recipient.cancelPendingReservation(row);
        var remaining = self.claimed_leases;
        for (self.gifts) |gift| {
            if (remaining == 0) break;
            Internal.unclaimOutboundStagingLease(node, gift.route_id, gift.capability_lease.?);
            remaining -= 1;
        }
        for (self.promises) |promise| {
            if (remaining == 0) break;
            Internal.unclaimOutboundStagingLease(node, promise.route_id, promise.capability_lease.?);
            remaining -= 1;
        }
        self.recipient.allocator.free(self.promises);
        self.recipient.allocator.free(self.gifts);
        self.recipient.cancelInlinePassableStaging(self.staging_reservation);
    }
};

/// One staging transaction for every Passable tree crossing a session
/// boundary. `inventory` is the recipient session's
/// inventory of the payload's tree, which measured it and listed its
/// references, so no pass here walks the tree. Admission and reservation are
/// the fallible half; publication commits infallibly after the last refusal.
/// A staged batch takes `failure_escrow` (`Batch.failure_escrow`), and a
/// refusal that hands the payload back hands the escrow back with it.
pub fn stage(
    self: *Node,
    recipient_peer: PeerHandle,
    payload: *passable.Outbound,
    inventory: session_mod.Inventory,
    failure_target: ?passable.FailureTarget,
    failure_escrow: *?[]u8,
) engine.node_services.OutboundStagingError!bool {
    const recipient = self.peer(recipient_peer) orelse return error.RouteNotLowerable;
    const admission = try admit(self, recipient, recipient_peer, payload, inventory) orelse return false;
    var reserved = try reserve(self, recipient, recipient_peer, payload, inventory, admission);
    const batch_id = publish(self, recipient_peer, payload, failure_target, failure_escrow, admission, &reserved);
    if (reserved.gifts.len == 0) try finishEmpty(self, recipient, batch_id, payload, failure_escrow);
    return true;
}

/// Measure the tree against the recipient's caps and reserve the batch row,
/// gift tickets, and completion actions it will need. Null when the tree
/// crosses no session boundary.
fn admit(
    self: *Node,
    recipient: *engine.Peer,
    recipient_peer: PeerHandle,
    payload: *passable.Outbound,
    inventory: session_mod.Inventory,
) !?Admission {
    const message_charge = try payload.retainedBytes(inventory);
    const counts = try walk.count(self, recipient_peer, payload, inventory);
    const projection_count = counts.total();
    if (projection_count == 0) return null;
    if (projection_count > recipient.limits().queue_cap or counts.objects > std.math.maxInt(u32))
        return error.QueueCapExceeded;
    const rows = &self.inline_passable_batches;
    const current_occurrences = rows.occurrences_by_recipient.get(recipient_peer) orelse 0;
    const next_occurrences = std.math.add(usize, current_occurrences, projection_count) catch
        return error.QueueCapExceeded;
    if (next_occurrences > recipient.limits().queue_cap or
        rows.rows.count() >= recipient.limits().queue_cap)
        return error.QueueCapExceeded;
    if (rows.next_id == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    try rows.rows.ensureUnusedCapacity(self.allocator, 1);
    try gift_tickets.ensureUnusedCapacity(self, @intCast(counts.objects));
    if (current_occurrences == 0)
        try rows.occurrences_by_recipient.ensureUnusedCapacity(self.allocator, 1);
    const object_completion = std.math.mul(usize, counts.objects, 2) catch
        return error.OutOfMemory;
    const promise_completion = std.math.mul(usize, counts.promises, 3) catch
        return error.OutOfMemory;
    const completion_without_recipient = std.math.add(
        usize,
        object_completion,
        promise_completion,
    ) catch return error.OutOfMemory;
    // The recipient's flush once the carrier is queued.
    const recipient_completion: usize = 1;
    const terminal_reservations = std.math.add(
        usize,
        completion_without_recipient,
        recipient_completion,
    ) catch return error.OutOfMemory;
    const action_reservations = std.math.add(usize, counts.objects, terminal_reservations) catch
        return error.OutOfMemory;
    try actions.reserve(self, action_reservations);
    return .{
        .counts = counts,
        .message_charge = message_charge,
        .current_occurrences = current_occurrences,
        .next_occurrences = next_occurrences,
        .terminal_reservations = terminal_reservations,
    };
}

/// Acquire every per-projection resource: the staging charge, the gift and
/// promise projections with their outbound leases, the queue place of an
/// outbound carrier, local custody of the tree, and last the ticket range.
/// The ticket claim is the final refusal point: after it, every batch row
/// and action publishes without wrapping into an older effect generation.
fn reserve(
    self: *Node,
    recipient: *engine.Peer,
    recipient_peer: PeerHandle,
    payload: *passable.Outbound,
    inventory: session_mod.Inventory,
    admission: Admission,
) !Reserved {
    const counts = admission.counts;
    var reserved: Reserved = .{
        .recipient = recipient,
        .payload = payload,
        .staging_reservation = try recipient.reserveInlinePassableStaging(admission.message_charge),
    };
    errdefer reserved.abandon(self);
    reserved.gifts = try recipient.allocator.alloc(passable.Gift, counts.objects);
    reserved.promises = try recipient.allocator.alloc(passable.PromiseProjection, counts.promises);
    try walk.collect(self, recipient_peer, payload, inventory, reserved.gifts, reserved.promises);
    if (self.outbound_staging_leases != null) {
        for (reserved.gifts) |*gift| {
            gift.capability_lease = Internal.claimOutboundStagingLease(self, gift.route_id) orelse
                return error.RouteNotLowerable;
            reserved.claimed_leases += 1;
        }
        for (reserved.promises) |*promise| {
            promise.capability_lease = Internal.claimOutboundStagingLease(self, promise.route_id) orelse
                return error.RouteNotLowerable;
            reserved.claimed_leases += 1;
        }
    }
    // An outbound carrier keeps its place in the recipient's queue while it
    // stages, so later sends to that recipient cannot overtake it.
    reserved.staged_row = try recipient.reserveStagedRow();
    try local_custody.acquire(&recipient.session_state, payload, inventory);
    reserved.custody_owned = true;
    reserved.first_ticket = try actions.claimTicketRange(self, counts.objects);
    return reserved;
}

/// Open the batch row, take the tree from the caller, and publish one
/// gift-id action per object projection.
fn publish(
    self: *Node,
    recipient_peer: PeerHandle,
    payload: *passable.Outbound,
    failure_target: ?passable.FailureTarget,
    failure_escrow: *?[]u8,
    admission: Admission,
    reserved: *Reserved,
) passable.BatchId {
    const recipient = reserved.recipient;
    const rows = &self.inline_passable_batches;
    const staged_deliver = payload.* == .message and payload.message == .deliver;
    const staged_answer = if (staged_deliver) payload.message.deliver.answer else null;
    const batch_id: passable.BatchId = @fromBackingInt(@intCast(rows.next_id));
    rows.rows.putAssumeCapacity(batch_id, .{
        .recipient_peer = recipient_peer,
        .allocator = recipient.allocator,
        .payload = payload.*,
        .local_custody_owned = true,
        .failure_target = failure_target,
        .failure_escrow = failure_escrow.*,
        .staging_reservation = reserved.staging_reservation,
        .gifts = reserved.gifts,
        .promises = reserved.promises,
        .terminal_action_reservations = admission.terminal_reservations,
    });
    if (admission.current_occurrences == 0)
        rows.occurrences_by_recipient.putAssumeCapacity(recipient_peer, admission.next_occurrences)
    else
        rows.occurrences_by_recipient.getPtr(recipient_peer).?.* = admission.next_occurrences;
    payload.* = undefined;
    failure_escrow.* = null;
    rows.next_id += 1;
    rows.action_reservations += admission.terminal_reservations;
    recipient.pushPendingAssume(reserved.staged_row.?, .{ .staged = .{
        .batch = batch_id,
        .deliver = staged_deliver,
        .answer = staged_answer,
    } });
    for (reserved.gifts, 0..) |gift, index| {
        const ticket = reserved.first_ticket + @as(u64, @intCast(index));
        gift_tickets.publishInlineAssumeCapacity(self, ticket, recipient_peer, gift.route_id, .{
            .batch = batch_id,
            .gift_index = @intCast(index),
        });
        actions.pushReserved(self, .{ .need_gift_id = .{ .ticket = ticket } });
    }
    return batch_id;
}

/// A batch with no object projection waits for no gift id, so it finishes
/// now. A refusal after the Peer consumed the carrier fails the batch through
/// its correlated barrier; one before that hands the carrier back.
fn finishEmpty(
    self: *Node,
    recipient: *engine.Peer,
    batch_id: passable.BatchId,
    payload: *passable.Outbound,
    failure_escrow: *?[]u8,
) !void {
    const rows = &self.inline_passable_batches;
    batches.finish(self, batch_id) catch |err| {
        // `finish` removes the row only after its last refusal point.
        const failed = rows.rows.getPtr(batch_id) orelse unreachable;
        if (!failed.payload_owned) {
            // Peer consumed the message before its final refusal. No
            // caller-owned value remains; use the correlated barrier.
            batches.fail(self, batch_id, err);
            return;
        }
        var restored = (rows.rows.fetchRemove(batch_id) orelse unreachable).value;
        // The caller gets its carrier back, so no row holds its place.
        const removed = recipient.removeStagedRow(batch_id);
        std.debug.assert(removed != .absent);
        batches.spendTerminalReservations(self, &restored);
        batches.unclaimProjectionLeases(self, &restored);
        payload.* = restored.payload;
        restored.payload_owned = false;
        failure_escrow.* = restored.failure_escrow;
        restored.failure_escrow = null;
        restored.deinit(self);
        return err;
    };
}
