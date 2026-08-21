//! Atomic inline-Passable projection batches across Node peers.
//!
//! One inline aggregate owns admission, delayed gift entropy, recursive
//! rewrite, commit or rollback, pressure reservations, and terminal teardown.
//! `passable.zig` owns the carrier vocabulary and `walk.zig` owns the shared
//! tree passes; this module owns the transaction that applies them.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const engine = @import("../../mod.zig");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");
const outbound = @import("../../outbound.zig");
const passable = @import("../passable.zig");
const walk = @import("walk.zig");
const gift_recipe = @import("../handoffs/gifts/recipe.zig");
const gift_tickets = @import("../handoffs/gifts/tickets.zig");
const peer_routes = @import("../peers/routes.zig");
const proxy_admission = @import("../proxies/admission.zig");
const proxy_settlement = @import("../proxies/settlement.zig");
const proxy_topology = @import("../proxies/topology.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

/// Every mutable fact owned by one Node's delayed Passable transactions.
/// The aggregate is embedded in Node; no runtime object or allocation is
/// introduced by the ownership boundary.
pub const Batches = struct {
    rows: std.AutoHashMapUnmanaged(passable.BatchId, Batch) = .empty,
    /// Aggregate staged projection occurrences by recipient. Batches are
    /// already individually queue-capped; this also bounds their metadata.
    occurrences_by_recipient: std.AutoHashMapUnmanaged(PeerHandle, usize) = .empty,
    /// Future terminal action seats held by every live batch.
    action_reservations: usize = 0,
    next_id: u64 = 1,
};

pub const Destination = union(enum) {
    outbound,
    relayed: proxy_topology.Recipient,
};

const Batch = struct {
    recipient_peer: PeerHandle,
    allocator: std.mem.Allocator,
    payload: passable.Payload,
    payload_owned: bool = true,
    destination: Destination,
    staging_reservation: ?engine.Peer.InlinePassableStagingReservation,
    gifts: []passable.Gift,
    promises: []passable.PromiseProjection,
    ready: usize = 0,
    terminal_action_reservations: usize,

    fn deinit(self: *Batch, node: *Node) void {
        const projection_count = self.gifts.len + self.promises.len;
        if (self.staging_reservation) |reservation| {
            const recipient = node.peer(self.recipient_peer) orelse unreachable;
            recipient.cancelInlinePassableStaging(reservation);
        }
        if (self.payload_owned) {
            const recipient = node.peer(self.recipient_peer) orelse unreachable;
            self.payload.deinit(recipient.allocator, &recipient.session_state);
        }
        switch (self.destination) {
            .outbound => {},
            .relayed => |*recipient| if (recipient.failure_reason != null) {
                recipient.releaseFailure(self.allocator);
                actions.releaseProxyReservation(node);
            },
        }
        for (self.gifts) |gift| if (gift.handoff) |handoff| {
            model.freeHandoff(self.allocator, handoff.*);
            self.allocator.destroy(handoff);
        };
        self.allocator.free(self.gifts);
        self.allocator.free(self.promises);
        const occurrences = node.inline_passable_batches.occurrences_by_recipient.getPtr(
            self.recipient_peer,
        ) orelse unreachable;
        std.debug.assert(occurrences.* >= projection_count);
        occurrences.* -= projection_count;
        if (occurrences.* == 0)
            std.debug.assert(node.inline_passable_batches.occurrences_by_recipient.remove(
                self.recipient_peer,
            ));
        std.debug.assert(node.inline_passable_batches.action_reservations >=
            self.terminal_action_reservations);
        node.inline_passable_batches.action_reservations -= self.terminal_action_reservations;
        self.* = undefined;
    }
};

/// Adopt an outbound carrier only when it needs cross-session projection.
pub fn stageOutbound(
    self: *Node,
    recipient_peer: PeerHandle,
    semantic: *passable.Outbound,
) engine.node_services.OutboundStagingError!bool {
    var payload: passable.Payload = .{ .outbound = semantic.* };
    var destination: Destination = .outbound;
    const staged = stage(self, recipient_peer, &payload, &destination) catch |err| {
        semantic.* = payload.outbound;
        return err;
    };
    if (!staged) semantic.* = payload.outbound;
    return staged;
}

/// One recursive staging transaction for every Passable tree crossing a
/// session boundary. Ordinary outbound messages and relayed promise
/// settlements differ only at their terminal owner.
pub fn stage(
    self: *Node,
    recipient_peer: PeerHandle,
    payload: *passable.Payload,
    destination: *Destination,
) engine.node_services.OutboundStagingError!bool {
    const recipient = self.peer(recipient_peer) orelse return error.RouteNotLowerable;
    // This shared model walk both measures the retained message and rejects
    // trees beyond the hard recursion ceiling before the staging passes.
    const message_charge = try payload.retainedBytes();
    const counts = try walk.count(self, recipient_peer, payload.*);
    const projection_count = try counts.total();
    if (projection_count == 0) return false;
    if (projection_count > recipient.limits().queue_cap or counts.objects > std.math.maxInt(u32))
        return error.QueueCapExceeded;
    const batches = &self.inline_passable_batches;
    const current_occurrences = batches.occurrences_by_recipient.get(recipient_peer) orelse 0;
    const next_occurrences = std.math.add(usize, current_occurrences, projection_count) catch
        return error.QueueCapExceeded;
    if (next_occurrences > recipient.limits().queue_cap or
        batches.rows.count() >= recipient.limits().queue_cap)
        return error.QueueCapExceeded;
    if (batches.next_id == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    try batches.rows.ensureUnusedCapacity(self.allocator, 1);
    try gift_tickets.ensureUnusedCapacity(self, @intCast(counts.objects));
    if (current_occurrences == 0)
        try batches.occurrences_by_recipient.ensureUnusedCapacity(self.allocator, 1);
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
    try walk.collect(self, recipient_peer, payload.*, gifts, promises);
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

    // This is the last fallible step before publication. The Node-wide ticket
    // range commits once, then every batch row/action below publishes
    // infallibly without wrapping into an older effect generation.
    const first_ticket = try actions.claimTicketRange(self, counts.objects);
    const batch_id: passable.BatchId = @fromBackingInt(@intCast(batches.next_id));
    batches.rows.putAssumeCapacity(batch_id, .{
        .recipient_peer = recipient_peer,
        .allocator = recipient.allocator,
        .payload = payload.*,
        .destination = destination.*,
        .staging_reservation = staging_reservation,
        .gifts = gifts,
        .promises = promises,
        .terminal_action_reservations = terminal_reservations,
    });
    if (current_occurrences == 0)
        batches.occurrences_by_recipient.putAssumeCapacity(recipient_peer, next_occurrences)
    else
        batches.occurrences_by_recipient.getPtr(recipient_peer).?.* = next_occurrences;
    staging_reservation_owned = false;
    gifts_owned = false;
    promises_owned = false;
    payload.* = undefined;
    destination.* = undefined;
    batches.next_id += 1;
    batches.action_reservations += terminal_reservations;

    for (gifts, 0..) |gift, index| {
        const ticket = first_ticket + @as(u64, @intCast(index));
        gift_tickets.publishInlineAssumeCapacity(self, ticket, recipient_peer, gift.route_id, .{
            .batch = batch_id,
            .gift_index = @intCast(index),
        });
        actions.pushReserved(self, .{ .need_gift_id = .{ .ticket = ticket } });
    }
    if (gifts.len == 0) {
        finish(self, batch_id) catch |err| {
            const failed = batches.rows.getPtr(batch_id) orelse unreachable;
            if (!failed.payload_owned) {
                // Peer consumed the message before its final refusal. No
                // caller-owned value remains; use the correlated barrier.
                fail(self, batch_id, err);
                return true;
            }
            var restored = (batches.rows.fetchRemove(batch_id) orelse unreachable).value;
            spendTerminalReservations(self, &restored);
            unclaimProjectionLeases(self, &restored);
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

/// Retire batches charged to a recipient while that exact Peer is alive.
pub fn retireRecipient(self: *Node, peer_handle: PeerHandle) void {
    while (true) {
        var found: ?passable.BatchId = null;
        var it = self.inline_passable_batches.rows.iterator();
        while (it.next()) |entry| if (entry.value_ptr.recipient_peer == peer_handle) {
            found = entry.key_ptr.*;
            break;
        };
        const batch_id = found orelse break;
        var batch = (self.inline_passable_batches.rows.fetchRemove(batch_id) orelse unreachable).value;
        gift_tickets.cancelBatch(self, batch_id);
        spendTerminalReservations(self, &batch);
        queueGiftLeaseReleases(self, batch.gifts);
        queuePromiseLeaseReleases(self, batch.promises);
        batch.deinit(self);
    }
}

/// Fail batches whose projection home is closing while route rows still live.
pub fn failForHome(self: *Node, peer_handle: PeerHandle) void {
    while (true) {
        var found: ?passable.BatchId = null;
        var it = self.inline_passable_batches.rows.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.gifts) |gift| if (gift.home == peer_handle) {
                found = entry.key_ptr.*;
                break;
            };
            if (found == null) for (entry.value_ptr.promises) |promise| if (promise.home == peer_handle) {
                found = entry.key_ptr.*;
                break;
            };
            if (found != null) break;
        }
        fail(self, found orelse break, error.RouteNotLowerable);
    }
}

/// Terminal Host cancellation keeps queued entropy actions as stale no-ops.
pub fn cancelAll(self: *Node) void {
    var batches = self.inline_passable_batches.rows.valueIterator();
    while (batches.next()) |batch| batch.deinit(self);
    self.inline_passable_batches.rows.clearRetainingCapacity();
}

/// Node teardown releases the aggregate while every recipient Peer is live.
pub fn deinitAll(self: *Node) void {
    var batches = self.inline_passable_batches.rows.valueIterator();
    while (batches.next()) |batch| {
        // A consumed proxy fire has no later retry source. Spend its terminal
        // escrow before freeing the batch and borrowed recipient stores.
        switch (batch.destination) {
            .outbound => {},
            .relayed => |*recipient| if (recipient.failure_reason != null)
                proxy_settlement.breakRecipient(self, recipient),
        }
        batch.deinit(self);
    }
    self.inline_passable_batches.rows.deinit(self.allocator);
    std.debug.assert(self.inline_passable_batches.action_reservations == 0);
    std.debug.assert(self.inline_passable_batches.occurrences_by_recipient.count() == 0);
    self.inline_passable_batches.occurrences_by_recipient.deinit(self.allocator);
}

const PreparedDeposit = struct {
    peer: *engine.Peer,
    deposit: engine.handoff_gifter.PreparedDepositGift,
};

const ExporterPreparation = struct {
    peer: *engine.Peer,
    count: usize = 0,
    batch: ?engine.Peer.PendingBatch = null,
};

fn spendTerminalReservations(self: *Node, batch: *Batch) void {
    std.debug.assert(self.inline_passable_batches.action_reservations >=
        batch.terminal_action_reservations);
    self.inline_passable_batches.action_reservations -= batch.terminal_action_reservations;
    batch.terminal_action_reservations = 0;
}

fn queueGiftLeaseReleases(self: *Node, gifts: []const passable.Gift) void {
    for (gifts) |gift| if (gift.capability_lease) |capability_raw|
        actions.pushReserved(self, .{ .release_capability = capability_raw });
}

fn queuePromiseLeaseReleases(self: *Node, promises: []const passable.PromiseProjection) void {
    for (promises) |promise| if (promise.capability_lease) |capability_raw|
        actions.pushReserved(self, .{ .release_capability = capability_raw });
}

fn unclaimProjectionLeases(self: *Node, batch: *Batch) void {
    for (batch.gifts) |*gift| if (gift.capability_lease) |capability_raw| {
        Internal.unclaimOutboundStagingLease(self, gift.route_id, capability_raw);
        gift.capability_lease = null;
    };
    for (batch.promises) |*promise| if (promise.capability_lease) |capability_raw| {
        Internal.unclaimOutboundStagingLease(self, promise.route_id, capability_raw);
        promise.capability_lease = null;
    };
}

pub fn fail(self: *Node, batch_id: passable.BatchId, err: anyerror) void {
    var batch = takeForTerminal(self, batch_id) orelse return;
    switch (batch.destination) {
        .outbound => if (self.peer(batch.recipient_peer) != null) {
            actions.pushReserved(self, .{ .fail_session = .{
                .peer_handle = batch.recipient_peer,
                .reason = @errorName(err),
            } });
        },
        .relayed => |*recipient| proxy_settlement.breakRecipient(self, recipient),
    }
    queueGiftLeaseReleases(self, batch.gifts);
    queuePromiseLeaseReleases(self, batch.promises);
    batch.deinit(self);
}

fn takeForTerminal(self: *Node, batch_id: passable.BatchId) ?Batch {
    var batch = (self.inline_passable_batches.rows.fetchRemove(batch_id) orelse return null).value;
    gift_tickets.cancelBatch(self, batch_id);
    spendTerminalReservations(self, &batch);
    return batch;
}

fn finish(self: *Node, batch_id: passable.BatchId) !void {
    const batch = self.inline_passable_batches.rows.getPtr(batch_id) orelse return;
    if (batch.ready != batch.gifts.len) return;
    const recipient = self.peer(batch.recipient_peer) orelse return error.RouteNotLowerable;
    switch (batch.payload) {
        .outbound => |outbound_payload| switch (outbound_payload) {
            .answer_settlement => |settlement| {
                if (recipient.session_state.answerPayloadForTarget(settlement.target) != settlement.payload)
                    return error.InvalidReference;
            },
            .message => {},
        },
        .relayed_resolution => {},
    }

    var deposits: std.ArrayListUnmanaged(PreparedDeposit) = .empty;
    defer deposits.deinit(self.allocator);
    errdefer for (deposits.items) |*prepared| prepared.deposit.abandon(prepared.peer);
    try deposits.ensureTotalCapacityPrecise(self.allocator, batch.gifts.len);

    // One message may carry several gifts homed on the same exporter. Reserve
    // its complete transaction once so cumulative pressure is enforced.
    var exporters: std.AutoHashMapUnmanaged(PeerHandle, ExporterPreparation) = .empty;
    defer exporters.deinit(self.allocator);
    try exporters.ensureUnusedCapacity(self.allocator, @intCast(batch.gifts.len));
    for (batch.gifts) |gift| {
        const exporter = self.peer(gift.home) orelse return error.RouteNotLowerable;
        const entry = exporters.getOrPutAssumeCapacity(gift.home);
        if (!entry.found_existing) entry.value_ptr.* = .{ .peer = exporter };
        entry.value_ptr.count += 1;
    }
    var exporter_it = exporters.valueIterator();
    while (exporter_it.next()) |entry|
        entry.batch = try entry.peer.beginPendingBatch(entry.count);
    for (batch.gifts) |gift| {
        const exporter = exporters.getPtr(gift.home) orelse unreachable;
        const pending_batch = if (exporter.batch) |*pending| pending else unreachable;
        deposits.appendAssumeCapacity(.{
            .peer = exporter.peer,
            .deposit = try engine.handoff_gifter.prepareDepositGiftInBatch(
                exporter.peer,
                pending_batch,
                &gift.gift_id,
                gift.gifted,
            ),
        });
    }

    var promises = try proxy_admission.prepare(self, batch.recipient_peer, batch.promises);
    defer promises.deinit(self);
    var projections_rewritten = true;
    errdefer if (projections_rewritten) walk.restore(batch);
    try walk.replace(self, batch);
    switch (batch.destination) {
        .outbound => {
            switch (batch.payload.outbound) {
                .message => |message| {
                    // Validate while the batch owns the message. Peer.send
                    // consumes on every outcome, so refusal precedes that edge.
                    try recipient.session_state.admits(model.view.Body.fromOwned(&message));
                    try session_mod.validate.validateSend(&recipient.session_state, message);
                    recipient.cancelInlinePassableStaging(batch.staging_reservation.?);
                    batch.staging_reservation = null;
                    const send_result = recipient.send(message);
                    batch.payload_owned = false;
                    projections_rewritten = false;
                    try send_result;
                },
                .answer_settlement => |settlement| {
                    try recipient.session_state.validateAnswerSettlement(
                        settlement.target,
                        settlement.payload,
                        settlement.resolution,
                    );
                    const enqueue_result = outbound.enqueueStagedAnswerSettlementOwned(
                        recipient,
                        settlement,
                        &batch.staging_reservation,
                    );
                    batch.payload_owned = false;
                    projections_rewritten = false;
                    try enqueue_result;
                },
            }
            promises.commit(self);
            for (deposits.items) |*prepared| prepared.deposit.commit(prepared.peer);
            deposits.clearRetainingCapacity();
        },
        .relayed => |*proxy_recipient| {
            const resolution = batch.payload.relayed_resolution;
            try recipient.session_state.validateStoredResolution(resolution);
            const imported = recipient.session_state.findImportedPromise(
                .from(proxy_recipient.import_pos),
            ) orelse return error.InvalidReference;
            if (imported.cell.row_id != proxy_recipient.row_id) return error.InvalidReference;
            if (imported.cell.resolution != null) return error.UnexpectedMessage;
            // Publish every consequence before the recipient store: observers
            // see the complete projection or its reserved terminal break.
            promises.commit(self);
            for (deposits.items) |*prepared| prepared.deposit.commit(prepared.peer);
            deposits.clearRetainingCapacity();
            recipient.cancelInlinePassableStaging(batch.staging_reservation.?);
            batch.staging_reservation = null;
            batch.payload_owned = false;
            projections_rewritten = false;
            proxy_settlement.settleRecipient(self, proxy_recipient, resolution);
        },
    }

    var finished = (self.inline_passable_batches.rows.fetchRemove(batch_id) orelse unreachable).value;
    spendTerminalReservations(self, &finished);
    for (finished.gifts) |gift| actions.pushReserved(self, .{ .flush = gift.home });
    if (finished.destination == .outbound)
        actions.pushReserved(self, .{ .flush = finished.recipient_peer });
    queueGiftLeaseReleases(self, finished.gifts);
    queuePromiseLeaseReleases(self, finished.promises);
    finished.deinit(self);
}

/// Complete one entropy ticket already removed from Node's generic table.
pub fn provideGiftId(
    self: *Node,
    recipient_peer: PeerHandle,
    route_id: model.CapabilityRouteId,
    staged: gift_tickets.InlineTicket,
    gift_id: []const u8,
) void {
    const batch = self.inline_passable_batches.rows.getPtr(staged.batch) orelse return;
    if (staged.gift_index >= batch.gifts.len or gift_id.len != model.HANDOFF_GIFT_ID_BYTES)
        return fail(self, staged.batch, error.GiftIdUnavailable);
    const gift = &batch.gifts[staged.gift_index];
    const gift_route = peer_routes.route(self, .{ .routed = .{ .id = route_id } }) orelse
        return fail(self, staged.batch, error.RouteNotLowerable);
    if (gift_route.peer_handle != gift.home or !std.meta.eql(gift_route.reference, gift.gifted))
        return fail(self, staged.batch, error.RouteNotLowerable);
    const recipient = self.peer(recipient_peer) orelse
        return fail(self, staged.batch, error.UnknownConnection);
    const exporter = self.peer(gift.home) orelse
        return fail(self, staged.batch, error.UnknownConnection);
    const recipient_key = recipient.session_state.partnerSessionKey() orelse
        return fail(self, staged.batch, error.NoRecipientKey);
    const exporter_key = exporter.session_state.partnerSessionKey() orelse
        return fail(self, staged.batch, error.NoExporterKey);
    const claimed = exporter.session_state.partnerLocatorRaw() orelse
        return fail(self, staged.batch, error.NoExporterLocator);
    const exporter_location = gift_recipe.get(self, gift.home);
    const give = gift_recipe.mint(
        self,
        gift.home,
        gift_id,
        recipient_key,
        exporter_key,
        if (exporter_location.len != 0) exporter_location else claimed,
        recipient.session_state.partnerKnownPancake(),
    ) catch |err| return fail(self, staged.batch, err);
    defer self.allocator.free(give);
    gift.handoff = engine.handoff_gifter.decodeHandoffGive(batch.allocator, give) catch |err|
        return fail(self, staged.batch, err);
    @memcpy(&gift.gift_id, gift_id);
    batch.ready += 1;
    finish(self, staged.batch) catch |err| fail(self, staged.batch, err);
}
