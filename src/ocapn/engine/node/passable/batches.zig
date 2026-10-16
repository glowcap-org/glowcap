//! Atomic inline-Passable projection batches across Node peers.
//!
//! One inline aggregate owns admission, delayed gift entropy, recursive
//! rewrite, commit or rollback, pressure reservations, and terminal teardown.
//! `passable.zig` owns the carrier vocabulary and `walk.zig` owns the shared
//! tree passes. This module owns the transaction that applies them.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const engine = @import("../../mod.zig");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");
const outbound = @import("../../outbound.zig");
const passable = @import("../passable.zig");
const walk = @import("walk.zig");
const local_custody = @import("local_custody.zig");
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
/// The aggregate is embedded in Node. No runtime object or allocation is
/// introduced by the ownership boundary.
pub const Batches = struct {
    rows: std.AutoHashMapUnmanaged(passable.BatchId, Batch) = .empty,
    /// Aggregate staged projection occurrences by recipient. Batches are
    /// already individually queue-capped. This also bounds their metadata.
    occurrences_by_recipient: std.AutoHashMapUnmanaged(PeerHandle, usize) = .empty,
    /// Future terminal action seats held by every live batch.
    action_reservations: usize = 0,
    next_id: u64 = 1,
    /// Promise-proxy recipients committed by sends inside an open provisional
    /// window, oldest first, kept or withdrawn with that window (ADR-0194).
    provisional_proxies: std.ArrayListUnmanaged(proxy_admission.Receipt) = .empty,
};

pub const Destination = union(enum) {
    outbound,
    relayed: proxy_topology.Recipient,
};

pub const Batch = struct {
    recipient_peer: PeerHandle,
    allocator: std.mem.Allocator,
    payload: passable.Payload,
    payload_owned: bool = true,
    local_custody_owned: bool = false,
    destination: Destination,
    failure_target: ?passable.FailureTarget,
    staging_reservation: ?engine.Peer.InlinePassableStagingReservation,
    gifts: []passable.Gift,
    promises: []passable.PromiseProjection,
    ready: usize = 0,
    terminal_action_reservations: usize,

    pub fn deinit(self: *Batch, node: *Node) void {
        // `removePeer` retires a recipient's batches before the Peer goes, and
        // `Node.deinit` retires every batch before any Peer; the occurrence row
        // was counted when the batch was staged.
        const projection_count = self.gifts.len + self.promises.len;
        const owner = node.peer(self.recipient_peer) orelse unreachable;
        if (self.staging_reservation) |reservation| {
            owner.cancelInlinePassableStaging(reservation);
        }
        if (self.local_custody_owned) {
            local_custody.release(&owner.session_state, &self.payload);
            self.local_custody_owned = false;
        }
        if (self.payload_owned) {
            self.payload.deinit(owner.allocator, &owner.session_state);
        }
        owner.session_state.collectLocalPromiseProjections();
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

/// A provisional window on `peer_handle` closed. Each proxy recipient its sends
/// committed is kept or, on retraction, withdrawn newest first, after the
/// Peer has already retracted the carriers that named them.
pub fn provisionalClosed(self: *Node, peer_handle: PeerHandle, retract: bool) void {
    const receipts = &self.inline_passable_batches.provisional_proxies;
    var i = receipts.items.len;
    while (i != 0) {
        i -= 1;
        if (receipts.items[i].peer != peer_handle) continue;
        const receipt = receipts.orderedRemove(i);
        if (retract) proxy_admission.withdraw(self, receipt) else proxy_admission.keep(self, receipt);
    }
}

/// A retracted provisional window removed the row of a send `batch` is still
/// staging (ADR-0194). Failing it cancels its gift tickets and leases and
/// breaks its answer. No gift has been deposited yet: the embedder does not
/// pump while the turn that made the send runs.
pub fn stagedWithdrawn(self: *Node, peer_handle: PeerHandle, batch: passable.BatchId) void {
    const row = self.inline_passable_batches.rows.get(batch) orelse return;
    std.debug.assert(row.recipient_peer == peer_handle);
    fail(self, batch, error.TurnAborted);
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
        if (batch.destination == .outbound) if (self.peer(peer_handle)) |recipient| {
            // tolerant: a closed session may already have discarded the row,
            // and a retiring recipient steps nothing more.
            _ = recipient.removeStagedRow(batch_id);
        };
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
    self.inline_passable_batches.provisional_proxies.deinit(self.allocator);
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

pub fn spendTerminalReservations(self: *Node, batch: *Batch) void {
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

pub fn unclaimProjectionLeases(self: *Node, batch: *Batch) void {
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
        .outbound => if (self.peer(batch.recipient_peer)) |recipient| {
            // A row that was holding later carriers back releases them. The
            // flush spends one of the completion seats this batch no longer
            // needs. A retracted window removes the row before failing it.
            if (recipient.removeStagedRow(batch_id) == .unblocked)
                actions.pushReserved(self, .{ .flush = batch.recipient_peer });
            if (batch.failure_target) |target| actions.pushReserved(self, .{ .fail = .{
                .dest = switch (target) {
                    .outbound_answer => |answer| .{ .answer = .{
                        .recipient_peer = batch.recipient_peer,
                        .answer = answer,
                    } },
                    .inbound_answer => |answer| .{ .served_answer = .{
                        .recipient_peer = batch.recipient_peer,
                        .answer = answer,
                    } },
                },
                .reason = .{ .static = @errorName(err) },
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

pub fn finish(self: *Node, batch_id: passable.BatchId) !void {
    const batch = self.inline_passable_batches.rows.getPtr(batch_id) orelse return;
    if (batch.ready != batch.gifts.len) return;
    const recipient = self.peer(batch.recipient_peer) orelse return error.RouteNotLowerable;
    // Return pre-recording custody only under a synchronous collection pause.
    // On retryable refusal the restored original tree reacquires that custody;
    // on consumption Session recording takes over before tracing resumes.
    const collection_pause = session_mod.Session.LocalPromiseCustody.pauseCollection(&recipient.session_state);
    defer collection_pause.deinit(&recipient.session_state);
    var return_custody = true;
    defer if (return_custody and batch.payload_owned and !batch.local_custody_owned) {
        // These counts were just returned, and the synchronous pause admits no
        // competing owner, so restoration cannot overflow.
        local_custody.restore(&recipient.session_state, &batch.payload);
        batch.local_custody_owned = true;
    };
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
    // A send inside an open window keeps a receipt for every proxy recipient
    // it commits, so a failed turn can withdraw them.
    const provisional = batch.destination == .outbound and recipient.stagedRowProvisional(batch_id);
    if (provisional)
        try self.inline_passable_batches.provisional_proxies.ensureUnusedCapacity(
            self.allocator,
            batch.promises.len,
        );
    if (batch.local_custody_owned) {
        local_custody.release(&recipient.session_state, &batch.payload);
        batch.local_custody_owned = false;
    }
    var projections_rewritten = true;
    errdefer if (projections_rewritten) walk.restore(batch);
    try walk.replace(self, batch);
    switch (batch.destination) {
        .outbound => {
            switch (batch.payload.outbound) {
                .message => |message| {
                    // Validate while the batch owns the message. The enqueue
                    // consumes on every outcome, so refusal precedes that edge.
                    const inventory = try recipient.session_state.inventoryMessage(message);
                    defer inventory.deinit(recipient.allocator);
                    try recipient.session_state.admits(model.view.Body.fromOwned(&message));
                    try session_mod.validate.validateSend(&recipient.session_state, message, inventory);
                    recipient.cancelInlinePassableStaging(batch.staging_reservation.?);
                    batch.staging_reservation = null;
                    const rows_before = recipient.pending_send.pending().len;
                    const send_result = outbound.enqueueInventoried(recipient, message, inventory);
                    batch.payload_owned = false;
                    projections_rewritten = false;
                    try send_result;
                    recipient.fillStagedRow(batch_id, recipient.pending_send.pending().len - rows_before);
                },
                .answer_settlement => |settlement| {
                    const inventory = try recipient.session_state.inventoryResolution(settlement.resolution);
                    defer inventory.deinit(recipient.allocator);
                    try recipient.session_state.validateAnswerSettlement(
                        settlement.target,
                        settlement.payload,
                        settlement.resolution,
                        inventory,
                    );
                    const rows_before = recipient.pending_send.pending().len;
                    const enqueue_result = outbound.enqueueStagedAnswerSettlementOwned(
                        recipient,
                        settlement,
                        inventory,
                        &batch.staging_reservation,
                    );
                    batch.payload_owned = false;
                    projections_rewritten = false;
                    try enqueue_result;
                    recipient.fillStagedRow(batch_id, recipient.pending_send.pending().len - rows_before);
                },
            }
            if (provisional)
                promises.commitProvisional(self, &self.inline_passable_batches.provisional_proxies)
            else
                promises.commit(self);
            for (deposits.items) |*prepared| prepared.deposit.commit(prepared.peer);
            deposits.clearRetainingCapacity();
        },
        .relayed => |*proxy_recipient| {
            const resolution = batch.payload.relayed_resolution;
            const inventory = try recipient.session_state.inventoryResolution(resolution);
            defer inventory.deinit(recipient.allocator);
            try recipient.session_state.validateStoredResolution(resolution, inventory);
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

    // The row found at the top of `finish`; nothing in the switch removes it.
    return_custody = false;
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
        recipient,
        recipient_peer,
        gift.home,
        gift_id,
        recipient_key,
        exporter_key,
        if (exporter_location.len != 0) exporter_location else claimed,
    ) catch |err| return fail(self, staged.batch, err);
    defer self.allocator.free(give);
    gift.handoff = engine.handoff_gifter.decodeHandoffGive(batch.allocator, give) catch |err|
        return fail(self, staged.batch, err);
    @memcpy(&gift.gift_id, gift_id);
    batch.ready += 1;
    finish(self, staged.batch) catch |err| fail(self, staged.batch, err);
}
