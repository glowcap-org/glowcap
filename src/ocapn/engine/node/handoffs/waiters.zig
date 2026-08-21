//! Exact-gift handoff waiter scheduling across live Node peers.

const std = @import("std");

const node_mod = @import("../../node.zig");
const node_services = @import("../../node_services.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;
const HandoffDependency = node_services.HandoffDependency;

const no_change = std.math.maxInt(usize);
const Receivers = std.AutoHashMapUnmanaged(PeerHandle, void);

pub const Iterator = struct {
    inner: Receivers.KeyIterator,

    pub fn next(self: *Iterator) ?PeerHandle {
        const receiver = self.inner.next() orelse return null;
        return receiver.*;
    }
};

/// Scheduler-only dependencies for withdrawals awaiting one exact gift on one
/// live gifter session. A receiver owns at most one group for this key, so the
/// receiver set needs no duplicate count.
const Group = struct {
    receivers: Receivers = .empty,
    changed_index: usize = no_change,
};

/// All exact gift groups rooted in one live Gifter–Exporter session. Making
/// the gifter the outer key means session close touches only its own groups;
/// unrelated tenants never enter that teardown path.
const GifterGroups = struct {
    gifts: std.AutoHashMapUnmanaged([16]u8, Group) = .empty,
};

/// Aggregate storage stays inline in `Node`; this module is its sole lifecycle
/// owner and does not add a second scheduler object or indirection.
pub const Gifters = std.AutoHashMapUnmanaged(PeerHandle, GifterGroups);
pub const Changes = std.ArrayListUnmanaged(HandoffDependency);

pub fn deinit(self: *Node) void {
    var gifter_it = self.handoff_waiters.valueIterator();
    while (gifter_it.next()) |gifter| {
        var gift_it = gifter.gifts.valueIterator();
        while (gift_it.next()) |group_entry| group_entry.receivers.deinit(self.allocator);
        gifter.gifts.deinit(self.allocator);
    }
    self.handoff_waiters.deinit(self.allocator);
    self.handoff_changes.deinit(self.allocator);
}

pub fn add(self: *Node, receiver: PeerHandle, dependency: HandoffDependency) std.mem.Allocator.Error!void {
    if (group(self, dependency)) |waiters| {
        if (waiters.receivers.contains(receiver)) return;
        try waiters.receivers.ensureUnusedCapacity(self.allocator, 1);
        waiters.receivers.putAssumeCapacity(receiver, {});
        return;
    }

    var waiters: Group = .{};
    errdefer waiters.receivers.deinit(self.allocator);
    try waiters.receivers.ensureUnusedCapacity(self.allocator, 1);
    // One reserved change slot per exact gift group makes every later
    // authority notification infallible.
    try self.handoff_changes.ensureTotalCapacity(self.allocator, self.handoff_group_count + 1);
    waiters.receivers.putAssumeCapacity(receiver, {});

    if (self.handoff_waiters.getPtr(dependency.gifter)) |gifter| {
        try gifter.gifts.ensureUnusedCapacity(self.allocator, 1);
        gifter.gifts.putAssumeCapacity(dependency.gift_tag, waiters);
        self.handoff_group_count += 1;
        return;
    }

    var gifter: GifterGroups = .{};
    errdefer gifter.gifts.deinit(self.allocator);
    try gifter.gifts.ensureUnusedCapacity(self.allocator, 1);
    try self.handoff_waiters.ensureUnusedCapacity(self.allocator, 1);
    gifter.gifts.putAssumeCapacity(dependency.gift_tag, waiters);
    self.handoff_waiters.putAssumeCapacity(dependency.gifter, gifter);
    self.handoff_group_count += 1;
}

pub fn remove(self: *Node, receiver: PeerHandle, dependency: HandoffDependency) void {
    const gifter = self.handoff_waiters.getPtr(dependency.gifter) orelse return;
    const waiters = gifter.gifts.getPtr(dependency.gift_tag) orelse return;
    std.debug.assert(waiters.receivers.remove(receiver));
    if (waiters.receivers.count() != 0) return;
    if (waiters.changed_index != no_change) removeChange(self, waiters.changed_index);
    waiters.receivers.deinit(self.allocator);
    std.debug.assert(gifter.gifts.remove(dependency.gift_tag));
    self.handoff_group_count -= 1;
    if (gifter.gifts.count() == 0) {
        gifter.gifts.deinit(self.allocator);
        std.debug.assert(self.handoff_waiters.remove(dependency.gifter));
    }
    // Return a burst all the way to zero instead of retaining the Node's
    // historical scheduler high-water until teardown. A live gifter's gift
    // map retains its own peak capacity; the memory rule names that bounded
    // active-group tradeoff.
    if (self.handoff_waiters.count() == 0) {
        self.handoff_waiters.deinit(self.allocator);
        self.handoff_waiters = .empty;
        std.debug.assert(self.handoff_group_count == 0);
        self.handoff_changes.deinit(self.allocator);
        self.handoff_changes = .empty;
    }
}

pub fn markChanged(self: *Node, dependency: HandoffDependency) void {
    const waiters = group(self, dependency) orelse return;
    if (waiters.changed_index != no_change) return;
    std.debug.assert(self.handoff_changes.items.len < self.handoff_changes.capacity);
    waiters.changed_index = self.handoff_changes.items.len;
    self.handoff_changes.appendAssumeCapacity(dependency);
}

/// A gifter close invalidates every gift dependency rooted in that exact
/// session. Each group reserved one change slot when admitted, so marking all
/// of them remains allocation-free at the authority transition.
pub fn markGifterClosed(self: *Node, gifter: PeerHandle) void {
    const groups = self.handoff_waiters.getPtr(gifter) orelse return;
    var it = groups.gifts.iterator();
    while (it.next()) |entry| {
        markChanged(self, .{ .gifter = gifter, .gift_tag = entry.key_ptr.* });
    }
}

/// Peek one exact changed dependency without consuming it. Each Host shell
/// reserves its dirty-queue seat at mint, and each gift group reserves this
/// marker at admission, so notifying every receiver and consuming the marker
/// are both infallible.
pub fn nextChange(self: *const Node) ?HandoffDependency {
    return if (self.handoff_changes.items.len == 0)
        null
    else
        self.handoff_changes.items[self.handoff_changes.items.len - 1];
}

pub fn countForGifter(self: *const Node, gifter: PeerHandle) usize {
    const groups = self.handoff_waiters.get(gifter) orelse return 0;
    var total: usize = 0;
    var it = groups.gifts.valueIterator();
    while (it.next()) |waiters| total += waiters.receivers.count();
    return total;
}

pub fn iterate(self: *Node, dependency: HandoffDependency) Iterator {
    const waiters = group(self, dependency) orelse return .{
        .inner = Receivers.empty.keyIterator(),
    };
    return .{ .inner = waiters.receivers.keyIterator() };
}

pub fn consume(self: *Node, dependency: HandoffDependency) void {
    const waiters = group(self, dependency) orelse return;
    if (waiters.changed_index == no_change) return;
    removeChange(self, waiters.changed_index);
    waiters.changed_index = no_change;
}

fn removeChange(self: *Node, index: usize) void {
    const last = self.handoff_changes.items.len - 1;
    const moved = self.handoff_changes.items[last];
    const removed = self.handoff_changes.swapRemove(index);
    std.debug.assert(group(self, removed).?.changed_index == index);
    if (index != last) group(self, moved).?.changed_index = index;
}

fn group(self: *Node, dependency: HandoffDependency) ?*Group {
    const gifter = self.handoff_waiters.getPtr(dependency.gifter) orelse return null;
    return gifter.gifts.getPtr(dependency.gift_tag);
}
