//! Gift-id entropy ticket ownership for gifter-side handoff origination.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const actions = @import("../../actions.zig");
const node_mod = @import("../../../node.zig");
const passable = @import("../../passable.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;

/// The delayed Passable occurrence completed by one gift-id draw.
pub const InlineTicket = struct {
    batch: passable.BatchId,
    gift_index: u32,
};

pub const Destination = union(enum) {
    answer: session_mod.AnswerTarget,
    inline_gift: InlineTicket,
};

pub const Pending = struct {
    recipient_peer: PeerHandle,
    route_id: model.CapabilityRouteId,
    dest: Destination,
};

/// The sole registry of live gift-id draws. It remains embedded in Node.
pub const State = struct {
    by_ticket: std.AutoHashMapUnmanaged(u64, Pending) = .empty,
};

pub fn deinit(self: *Node) void {
    self.gifts.tickets.by_ticket.deinit(self.allocator);
}

pub fn count(self: *const Node) usize {
    return self.gifts.tickets.by_ticket.count();
}

pub fn contains(self: *const Node, ticket: u64) bool {
    return self.gifts.tickets.by_ticket.contains(ticket);
}

pub fn ensureUnusedCapacity(self: *Node, count_in: u32) !void {
    try self.gifts.tickets.by_ticket.ensureUnusedCapacity(self.allocator, count_in);
}

/// Park one answer gift and publish its entropy request atomically. Capacity
/// and the action seat are acquired before the monotonic ticket is spent.
pub fn requestAnswer(
    self: *Node,
    recipient_peer: PeerHandle,
    route_id: model.CapabilityRouteId,
    answer: session_mod.AnswerTarget,
) !void {
    try ensureUnusedCapacity(self, 1);
    try actions.reserve(self, 1);
    const ticket = try actions.claimTicketRange(self, 1);
    self.gifts.tickets.by_ticket.putAssumeCapacity(ticket, .{
        .recipient_peer = recipient_peer,
        .route_id = route_id,
        .dest = .{ .answer = answer },
    });
    actions.pushReserved(self, .{ .need_gift_id = .{ .ticket = ticket } });
}

/// Publish one already-reserved inline gift ticket after every fallible batch
/// acquisition has completed.
pub fn publishInlineAssumeCapacity(
    self: *Node,
    ticket: u64,
    recipient_peer: PeerHandle,
    route_id: model.CapabilityRouteId,
    inline_gift: InlineTicket,
) void {
    self.gifts.tickets.by_ticket.putAssumeCapacity(ticket, .{
        .recipient_peer = recipient_peer,
        .route_id = route_id,
        .dest = .{ .inline_gift = inline_gift },
    });
}

pub fn take(self: *Node, ticket: u64) ?Pending {
    return if (self.gifts.tickets.by_ticket.fetchRemove(ticket)) |removed|
        removed.value
    else
        null;
}

/// Cancel exactly one inline batch in one allocation-free tombstone pass.
/// Removing the iterator's current row cannot move or allocate the backing.
pub fn cancelBatch(self: *Node, batch: passable.BatchId) void {
    var it = self.gifts.tickets.by_ticket.iterator();
    while (it.next()) |entry| switch (entry.value_ptr.dest) {
        .inline_gift => |staged| if (staged.batch == batch)
            self.gifts.tickets.by_ticket.removeByPtr(entry.key_ptr),
        .answer => {},
    };
}

/// Retire every claimed gift whose recipient membership disappeared.
pub fn retireRecipient(self: *Node, recipient_peer: PeerHandle) void {
    var it = self.gifts.tickets.by_ticket.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.recipient_peer != recipient_peer) continue;
        self.gifts.tickets.by_ticket.removeByPtr(entry.key_ptr);
    }
}

/// Terminal owner cancellation makes already-queued entropy actions stale.
pub fn cancelAll(self: *Node) void {
    self.gifts.tickets.by_ticket.clearRetainingCapacity();
}
