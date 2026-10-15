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

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;
const Destination = batches.Destination;

/// Adopt an outbound carrier only when it needs cross-session projection.
pub fn stageOutbound(
    self: *Node,
    recipient_peer: PeerHandle,
    semantic: *passable.Outbound,
    inventory: session_mod.Inventory,
) engine.node_services.OutboundStagingError!bool {
    const failure_target = semantic.failureTarget();
    var payload: passable.Payload = .{ .outbound = semantic.* };
    var destination: Destination = .outbound;
    const staged = stage(self, recipient_peer, &payload, inventory, &destination, failure_target) catch |err| {
        semantic.* = payload.outbound;
        return err;
    };
    if (!staged) semantic.* = payload.outbound;
    return staged;
}

/// One staging transaction for every Passable tree crossing a session
/// boundary. Ordinary outbound messages and relayed promise settlements differ
/// only at their terminal owner. `inventory` is the recipient session's
/// inventory of the payload's tree, which measured it and listed its
/// references, so no pass here walks the tree.
pub fn stage(
    self: *Node,
    recipient_peer: PeerHandle,
    payload: *passable.Payload,
    inventory: session_mod.Inventory,
    destination: *Destination,
    failure_target: ?passable.FailureTarget,
) engine.node_services.OutboundStagingError!bool {
    const recipient = self.peer(recipient_peer) orelse return error.RouteNotLowerable;
    const message_charge = try payload.retainedBytes(inventory);
    const counts = try walk.count(self, recipient_peer, payload, inventory);
    const projection_count = try counts.total();
    if (projection_count == 0) return false;
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
    // Completion needs one Host-retain release per projection, exporter/home
    // flushes, one future promise-settlement flush, and for ordinary outbound
    // one recipient flush. Failure uses that final correlated terminal seat.
    const object_completion = std.math.mul(usize, counts.objects, 2) catch
        return error.OutOfMemory;
    const promise_completion = std.math.mul(usize, counts.promises, 3) catch
        return error.OutOfMemory;
    const completion_without_recipient = std.math.add(
        usize,
        object_completion,
        promise_completion,
    ) catch return error.OutOfMemory;
    const recipient_completion: usize = if (destination.* == .outbound) 1 else 0;
    const terminal_reservations = std.math.add(
        usize,
        completion_without_recipient,
        recipient_completion,
    ) catch return error.OutOfMemory;
    const action_reservations = std.math.add(usize, counts.objects, terminal_reservations) catch
        return error.OutOfMemory;
    try actions.reserve(self, action_reservations);

    const staging_reservation = try recipient.reserveInlinePassableStaging(message_charge);
    var staging_reservation_owned = true;
    errdefer if (staging_reservation_owned)
        recipient.cancelInlinePassableStaging(staging_reservation);

    const gifts = try recipient.allocator.alloc(passable.Gift, counts.objects);
    var gifts_owned = true;
    errdefer if (gifts_owned) recipient.allocator.free(gifts);
    const promises = try recipient.allocator.alloc(passable.PromiseProjection, counts.promises);
    var promises_owned = true;
    errdefer if (promises_owned) recipient.allocator.free(promises);
    try walk.collect(self, recipient_peer, payload, inventory, gifts, promises);
    var claimed_leases: usize = 0;
    errdefer {
        var remaining = claimed_leases;
        for (gifts) |gift| {
            if (remaining == 0) break;
            Internal.unclaimOutboundStagingLease(self, gift.route_id, gift.capability_lease.?);
            remaining -= 1;
        }
        for (promises) |promise| {
            if (remaining == 0) break;
            Internal.unclaimOutboundStagingLease(self, promise.route_id, promise.capability_lease.?);
            remaining -= 1;
        }
    }
    if (self.outbound_staging_leases != null) {
        for (gifts) |*gift| {
            gift.capability_lease = Internal.claimOutboundStagingLease(self, gift.route_id) orelse
                return error.RouteNotLowerable;
            claimed_leases += 1;
        }
        for (promises) |*promise| {
            promise.capability_lease = Internal.claimOutboundStagingLease(self, promise.route_id) orelse
                return error.RouteNotLowerable;
            claimed_leases += 1;
        }
    }

    // An outbound carrier keeps its place in the recipient's queue while it
    // stages, so later sends to that recipient cannot overtake it.
    const staged_row: ?engine.Peer.PendingReservation = if (destination.* == .outbound)
        try recipient.reserveStagedRow()
    else
        null;
    var staged_row_owned = staged_row != null;
    errdefer if (staged_row_owned) recipient.cancelPendingReservation(staged_row.?);
    const staged_deliver = switch (payload.*) {
        .outbound => |carrier| carrier == .message and carrier.message == .deliver,
        .relayed_resolution => false,
    };

    const staged_answer = switch (payload.*) {
        .outbound => |carrier| if (carrier == .message and carrier.message == .deliver)
            carrier.message.deliver.answer
        else
            null,
        .relayed_resolution => null,
    };

    // This is the last fallible step before publication. The Node-wide ticket
    // range commits once, then every batch row/action below publishes
    // infallibly without wrapping into an older effect generation.
    const first_ticket = try actions.claimTicketRange(self, counts.objects);
    const batch_id: passable.BatchId = @fromBackingInt(@intCast(rows.next_id));
    rows.rows.putAssumeCapacity(batch_id, .{
        .recipient_peer = recipient_peer,
        .allocator = recipient.allocator,
        .payload = payload.*,
        .destination = destination.*,
        .failure_target = failure_target,
        .staging_reservation = staging_reservation,
        .gifts = gifts,
        .promises = promises,
        .terminal_action_reservations = terminal_reservations,
    });
    if (current_occurrences == 0)
        rows.occurrences_by_recipient.putAssumeCapacity(recipient_peer, next_occurrences)
    else
        rows.occurrences_by_recipient.getPtr(recipient_peer).?.* = next_occurrences;
    staging_reservation_owned = false;
    gifts_owned = false;
    promises_owned = false;
    payload.* = undefined;
    destination.* = undefined;
    rows.next_id += 1;
    rows.action_reservations += terminal_reservations;
    if (staged_row) |row| {
        recipient.pushPendingAssume(row, .{ .staged = .{ .batch = batch_id, .deliver = staged_deliver, .answer = staged_answer } });
        staged_row_owned = false;
    }

    for (gifts, 0..) |gift, index| {
        const ticket = first_ticket + @as(u64, @intCast(index));
        gift_tickets.publishInlineAssumeCapacity(self, ticket, recipient_peer, gift.route_id, .{
            .batch = batch_id,
            .gift_index = @intCast(index),
        });
        actions.pushReserved(self, .{ .need_gift_id = .{ .ticket = ticket } });
    }
    if (gifts.len == 0) {
        batches.finish(self, batch_id) catch |err| {
            // `finish` removes the row only after its last refusal point.
            const failed = rows.rows.getPtr(batch_id) orelse unreachable;
            if (!failed.payload_owned) {
                // Peer consumed the message before its final refusal. No
                // caller-owned value remains; use the correlated barrier.
                batches.fail(self, batch_id, err);
                return true;
            }
            var restored = (rows.rows.fetchRemove(batch_id) orelse unreachable).value;
            // The caller gets its carrier back, so no row holds its place.
            std.debug.assert(recipient.removeStagedRow(batch_id) != .absent);
            batches.spendTerminalReservations(self, &restored);
            batches.unclaimProjectionLeases(self, &restored);
            payload.* = restored.payload;
            restored.payload_owned = false;
            destination.* = restored.destination;
            restored.destination = .outbound;
            restored.deinit(self);
            return err;
        };
    }
    return true;
}
