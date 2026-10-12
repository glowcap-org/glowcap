//! Node-owned host effects, their reserved capacity, and borrowed drain.

const std = @import("std");

const model = @import("model");
const node_mod = @import("../node.zig");
const redeem = @import("redeem.zig");
const redeem_dials = @import("redeem/dials.zig");
const session = @import("session");

const ActionFifo = @import("../fifo.zig").ActionFifo;
const Node = node_mod.Node;
const PeerHandle = @import("../peer_handle.zig").PeerHandle;

/// A failed effect may also settle an inbound answer this Node claimed while
/// originating a give. Success for that path is published directly by the
/// two-peer transaction, so it is not a `redeem.Destination` and
/// cannot appear in a `.settle` action.
pub const FailureDestination = union(enum) {
    answer: struct { recipient_peer: PeerHandle, answer: model.AnswerPosition },
    served_answer: struct { recipient_peer: PeerHandle, answer: session.AnswerTarget },
    deferred: struct { recipient_peer: PeerHandle, id: u64 },
};

pub const FailureReason = union(enum) {
    owned: []u8,
    static: []const u8,

    pub fn bytes(self: FailureReason) []const u8 {
        return switch (self) {
            .owned => |reason| reason,
            .static => |reason| reason,
        };
    }
};

/// What the embedder must do next. Byte views are node-owned and valid until
/// the next `Node.nextAction` call (or node teardown). Copy what outlives that.
/// `dial` carries a pending ticket and route index, URI and dial pieces live
/// on the pending row (`Node.pendingDial`) so `acceptGive` owns them once.
pub const Action = union(enum) {
    /// Dial the exporter named by `pending`'s dial view with the node's
    /// retained identity, register the CapTP session, open the keyed session,
    /// bind any key the channel proved on that Peer, then feed
    /// `Node.exporterDialed(pending, route_index, peer_handle)`, or
    /// `Node.dialFailed(pending, route_index, reason)` if any step refuses.
    /// The executor must first commit the exact dial effect. Borrow its locator
    /// via `Node.pendingDial` until a report consumes it.
    dial: struct {
        pending: redeem_dials.PendingId,
        route_index: usize,
    },
    /// Interrupt and join a losing physical route after another route won.
    cancel_dial: struct {
        pending: redeem_dials.PendingId,
        route_index: usize,
    },
    /// Pump this CapTP session's outbound queue to the wire.
    flush: PeerHandle,
    /// Settle the returned answer or Host-owned deferred promise with the
    /// redeemed capability's ordinary routable identity.
    settle: struct {
        dest: redeem.Destination,
        route_id: model.CapabilityRouteId,
    },
    /// Break the returned answer or Host-owned deferred promise.
    fail: struct {
        dest: FailureDestination,
        /// Most failures own a copy of a call-scoped reason. Teardown uses
        /// one static diagnostic so its reserved consequence cannot fail
        /// allocation. The union makes those lifetimes non-interchangeable.
        reason: FailureReason,
    },
    /// Stop selecting and close an exporter session opened solely for handoff
    /// redemption after all of its withdrawals failed.
    retire_exporter: PeerHandle,
    /// Draw 32 bytes of gift-id entropy and feed them back through
    /// `Node.provideGiftId(ticket, bytes)`. Entropy is a host effect like
    /// dialing: the sans-io node never generates it, and requesting it only
    /// when a reply becomes a gift keeps the ordinary reply path free
    /// of speculative draws.
    need_gift_id: struct { ticket: u64 },
    /// Release one Host capability retain transferred into a delayed
    /// inline-Passable transaction. This is terminal cleanup: Host consumes
    /// the retain even when its home session can no longer carry wire GC.
    release_capability: u64,
};

/// Inline action authority. Keeping these facts together makes reservations,
/// publication, and owned-payload retirement one transaction without boxing
/// the Node aggregate.
pub const State = struct {
    queue: ActionFifo(Action) = .{},
    proxy_reservations: usize = 0,
    /// Queue seats promised to actions the Host has parked off the queue
    /// (`parkPeekedAction`), one each, so their return never allocates.
    parked_reservations: usize = 0,
    last: ?Action = null,
    next_ticket: redeem_dials.PendingId = 0,
};

pub fn deinit(self: *Node) void {
    if (self.actions.last) |last| free(self, last);
    for (self.actions.queue.unpopped()) |action| free(self, action);
    self.actions.queue.deinit(self.allocator);
}

fn free(self: *Node, action: Action) void {
    switch (action) {
        .fail => |failure| switch (failure.reason) {
            .owned => |reason| self.allocator.free(reason),
            .static => {},
        },
        .dial, .cancel_dial, .flush, .settle, .retire_exporter, .need_gift_id, .release_capability => {},
    }
}

/// Preserve every already-promised terminal consequence plus the immediate
/// actions the caller is about to publish. The FIFO reuses a dead prefix before
/// growing its backing.
pub fn reserve(self: *Node, immediate: usize) !void {
    const redeem_promised = try self.redeems.promisedActions();
    const handoff_promised = std.math.add(
        usize,
        self.actions.proxy_reservations,
        redeem_promised,
    ) catch return error.OutOfMemory;
    const with_inline = std.math.add(
        usize,
        handoff_promised,
        self.inline_passable_batches.action_reservations,
    ) catch return error.OutOfMemory;
    const with_parked = std.math.add(
        usize,
        with_inline,
        self.actions.parked_reservations,
    ) catch return error.OutOfMemory;
    const total = std.math.add(usize, with_parked, immediate) catch
        return error.OutOfMemory;
    try self.actions.queue.reserve(self.allocator, total);
}

/// Take the action returned by `peekAction` off the queue, payload intact, on
/// a seat promised for its return. The Host parks an action whose recipient
/// cannot take another frame yet (ADR-0145). The seat is reserved before the
/// pop, so a refusal leaves the action on the queue, and `pushParked` can
/// never allocate.
pub fn parkPeekedAction(self: *Node) !Action {
    try reserve(self, 1);
    const action = self.actions.queue.pop(self.allocator) orelse return error.NoPendingAction;
    self.actions.parked_reservations += 1;
    return action;
}

/// Return a parked action to the queue on the seat its parking held.
pub fn pushParked(self: *Node, action: Action) void {
    std.debug.assert(self.actions.parked_reservations > 0);
    self.actions.parked_reservations -= 1;
    self.actions.queue.pushReserved(action);
}

/// Free a parked action that will never return (Host teardown), giving its
/// seat back with it.
pub fn freeParked(self: *Node, action: Action) void {
    std.debug.assert(self.actions.parked_reservations > 0);
    self.actions.parked_reservations -= 1;
    free(self, action);
}

/// Publish into capacity already held by `reserve` or a committed future seat.
pub fn pushReserved(self: *Node, action: Action) void {
    self.actions.queue.pushReserved(action);
}

/// Claim a contiguous range in the Node-wide external-effect ticket namespace.
/// Call only after every fallible acquisition and immediately before infallible
/// publication. The maximum remains the first unissued sentinel.
pub fn claimTicketRange(
    self: *Node,
    count: usize,
) error{CapabilitySpaceExhausted}!redeem_dials.PendingId {
    const amount = std.math.cast(u64, count) orelse
        return error.CapabilitySpaceExhausted;
    if (amount > std.math.maxInt(u64) - self.actions.next_ticket)
        return error.CapabilitySpaceExhausted;
    const first = self.actions.next_ticket;
    self.actions.next_ticket += amount;
    return first;
}

/// Commit future terminal action seats after their owning proxy rows become
/// infallible. Capacity was reserved before this counter advances.
pub fn commitProxyReservations(self: *Node, count: usize) void {
    self.actions.proxy_reservations = std.math.add(
        usize,
        self.actions.proxy_reservations,
        count,
    ) catch unreachable;
}

pub fn releaseProxyReservation(self: *Node) void {
    std.debug.assert(self.actions.proxy_reservations > 0);
    self.actions.proxy_reservations -= 1;
}

/// Spend one proxy's held action seat to drive the recipient Peer. This is
/// required even for a plain relayed value: listener fires are queued on a
/// sibling session that the home-session feed would not otherwise touch.
pub fn queueProxyFlush(self: *Node, peer_handle: PeerHandle) void {
    releaseProxyReservation(self);
    pushReserved(self, .{ .flush = peer_handle });
}

pub fn assertNoProxyReservations(self: *const Node) void {
    std.debug.assert(self.actions.proxy_reservations == 0);
}

pub fn hasAction(self: *const Node) bool {
    return self.actions.queue.unpopped().len != 0;
}

/// Borrow the next action without transferring or freeing it. Host uses this
/// two-phase form so a fallible Vat consequence commits before destructive pop.
pub fn peekAction(self: *const Node) ?Action {
    return self.actions.queue.peek();
}

/// Commit the action returned by `peekAction`, freeing any owned payload.
pub fn consumePeekedAction(self: *Node) error{NoPendingAction}!void {
    const action = self.actions.queue.pop(self.allocator) orelse
        return error.NoPendingAction;
    free(self, action);
}

/// Pop borrowed: the preceding action remains valid until this call retires it.
/// Returning a dial commits that exact attempt to the executor. Stale queued
/// attempts are discarded. Call `rollbackDialEffect` only when the executor
/// refuses before publishing any physical work.
pub fn nextAction(self: *Node) ?Action {
    if (self.actions.last) |last| {
        free(self, last);
        self.actions.last = null;
    }
    while (self.actions.queue.pop(self.allocator)) |action| {
        if (action == .dial and
            !self.beginDialEffect(action.dial.pending, action.dial.route_index))
        {
            free(self, action);
            continue;
        }
        self.actions.last = action;
        return action;
    }
    return null;
}
