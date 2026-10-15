//! Tracked exporter withdrawals and their exact terminal claim.

const std = @import("std");

const model = @import("model");
const node_mod = @import("../../node.zig");
const actions = @import("../actions.zig");
const gift_recipe = @import("../handoffs/gifts/recipe.zig");
const redeem = @import("../redeem.zig");
const peer_routes = @import("../peers/routes.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

const exporter_closed_reason = "handoff redeem failed: exporter connection closed";

pub const Key = struct {
    peer_handle: PeerHandle,
    answer: u64,
};

pub const Pending = struct {
    dest: redeem.Destination,
    route_advice: ?*RouteAdvice = null,
};

pub const RouteAdvice = struct {
    location: ?[]u8 = null,
    pending: usize = 0,
};

pub const State = struct {
    /// One row per exporter answer that must not surface to the application.
    rows: std.AutoHashMapUnmanaged(Key, Pending) = .empty,
};

pub const Outcome = union(enum) {
    far: u64,
    broken: []const u8,
    not_capability,
};

pub fn deinit(self: *Node) void {
    var rows = self.redeems.withdrawals.rows.valueIterator();
    while (rows.next()) |pending| releaseRouteAdvice(self, pending.route_advice);
    self.redeems.withdrawals.rows.deinit(self.allocator);
}

pub fn createEmptyRouteAdvice(self: *Node) !*RouteAdvice {
    const advice = try self.allocator.create(RouteAdvice);
    advice.* = .{};
    return advice;
}

/// Release a candidate that no successfully queued withdrawal adopted.
pub fn finishRouteAdviceSetup(self: *Node, advice: ?*RouteAdvice) void {
    const candidate = advice orelse return;
    if (candidate.pending != 0) return;
    if (candidate.location) |location| self.allocator.free(location);
    self.allocator.destroy(candidate);
}

fn releaseRouteAdvice(self: *Node, advice: ?*RouteAdvice) void {
    const candidate = advice orelse return;
    std.debug.assert(candidate.pending != 0);
    candidate.pending -= 1;
    if (candidate.pending != 0) return;
    if (candidate.location) |location| self.allocator.free(location);
    self.allocator.destroy(candidate);
}

/// Queue a terminal failure carrying an owned copy of `reason`.
pub fn queueFailure(self: *Node, dest: redeem.Destination, reason: []const u8) !void {
    const owned = try self.allocator.dupe(u8, reason);
    errdefer self.allocator.free(owned);
    try actions.reserve(self, 1);
    actions.pushReserved(self, .{ .fail = .{
        .dest = redeem.failureDestination(dest),
        .reason = .{ .owned = owned },
    } });
}

/// Commit one failed withdrawal and, when it was the final use of a
/// redeem-only exporter, retire that exporter in the same reservation.
fn queueWithdrawFailure(
    self: *Node,
    pending: Pending,
    reason: []const u8,
    retire: ?PeerHandle,
) !void {
    const owned = try self.allocator.dupe(u8, reason);
    errdefer self.allocator.free(owned);
    try actions.reserve(self, if (retire != null) 2 else 1);
    actions.pushReserved(self, .{ .fail = .{
        .dest = redeem.failureDestination(pending.dest),
        .reason = .{ .owned = owned },
    } });
    if (retire) |peer_handle| actions.pushReserved(self, .{ .retire_exporter = peer_handle });
}

/// Send one withdraw on a live exporter session and record it pending.
/// Capacity and the future close-failure seat are reserved before the peer
/// queues the withdraw: once it is on the wire, tracking cannot fail.
pub fn begin(
    self: *Node,
    exporter_peer: PeerHandle,
    dest: redeem.Destination,
    give: []const u8,
    route_advice: ?*RouteAdvice,
) !void {
    const slot = self.peers.getPtr(exporter_peer) orelse
        return queueFailure(self, dest, "handoff redeem failed: exporter session is gone");
    const session = slot.peer;
    try self.redeems.withdrawals.rows.ensureUnusedCapacity(self.allocator, 1);
    // One immediate flush plus this pending redeem's eventual close failure.
    try actions.reserve(self, 2);
    const withdraw_answer = try session.allocateAnswer();
    // Sign with the introducing session: the give named that identity as its
    // recipient_key. The exporter session supplies its own side/session names.
    var recipient_secret = Internal.sessionSecret(self, redeem.recipientPeer(dest)) orelse
        return queueFailure(self, dest, "handoff redeem failed: introducing session is gone");
    defer std.crypto.secureZero(u8, std.mem.asBytes(&recipient_secret));
    session.sendWithdrawGift(
        recipient_secret,
        give,
        model.AnswerPosition.from(withdraw_answer),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var buf: [128]u8 = undefined;
            const reason = std.fmt.bufPrint(
                &buf,
                "handoff redeem failed: {s}",
                .{@errorName(err)},
            ) catch "handoff redeem failed";
            return queueFailure(self, dest, reason);
        },
    };
    self.redeems.withdrawals.rows.putAssumeCapacity(
        .{ .peer_handle = exporter_peer, .answer = withdraw_answer },
        .{ .dest = dest, .route_advice = route_advice },
    );
    if (route_advice) |advice| advice.pending += 1;
    std.debug.assert(slot.pending_withdraw_count < std.math.maxInt(u32));
    slot.pending_withdraw_count += 1;
    actions.pushReserved(self, .{ .flush = exporter_peer });
}

/// Offer an exporter resolve to the exact pending-withdraw authority. A
/// matching row is consumed only after its settlement consequence commits.
pub fn claim(self: *Node, peer_handle: PeerHandle, answer: u64, outcome: Outcome) !bool {
    const key: Key = .{ .peer_handle = peer_handle, .answer = answer };
    const rows = &self.redeems.withdrawals.rows;
    const pending = rows.get(key) orelse return false;
    // `peer_handle` is the session that delivered this resolve, so it is live.
    const slot = self.peers.getPtr(peer_handle) orelse unreachable;
    std.debug.assert(slot.pending_withdraw_count != 0);
    switch (outcome) {
        .far => |far_id| {
            // Reserve route and action capacity before enrollment clones, so
            // allocation failure leaves the withdraw retriable and strands no
            // route whose settlement was never published.
            try self.redeemed.ensureUnusedCapacity(self.allocator, 1);
            try actions.reserve(self, 1);
            if (pending.route_advice) |advice| {
                if (advice.location != null)
                    try gift_recipe.reserveDiscoveredSlot(self, peer_handle);
            }
            const enrolled = try peer_routes.enrollRedeemed(
                self,
                peer_handle,
                .{ .far = model.FarRef.object(far_id) },
            );
            actions.pushReserved(self, .{ .settle = .{
                .dest = pending.dest,
                .route_id = enrolled.routed.id,
            } });
            if (pending.route_advice) |advice| {
                if (advice.location) |location| {
                    gift_recipe.putDiscoveredReserved(self, peer_handle, location);
                    advice.location = null;
                }
            }
            slot.provisional_exporter = false;
        },
        .broken => |reason| {
            var buf: [256]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buf,
                "handoff redeem failed: {s}",
                .{reason},
            ) catch "handoff redeem failed";
            const retire: ?PeerHandle = if (slot.provisional_exporter and
                slot.pending_withdraw_count == 1) peer_handle else null;
            try queueWithdrawFailure(self, pending, message, retire);
        },
        .not_capability => {
            const retire: ?PeerHandle = if (slot.provisional_exporter and
                slot.pending_withdraw_count == 1) peer_handle else null;
            try queueWithdrawFailure(
                self,
                pending,
                "withdraw-gift did not resolve to a capability",
                retire,
            );
        },
    }
    releaseRouteAdvice(self, pending.route_advice);
    slot.pending_withdraw_count -= 1;
    std.debug.assert(rows.remove(key));
    return true;
}

/// Fail every withdrawal whose exporter membership just disappeared. Each row
/// already owns a terminal action seat, so teardown remains allocation-free.
pub fn failForPeer(self: *Node, peer_handle: PeerHandle) void {
    var it = self.redeems.withdrawals.rows.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.peer_handle != peer_handle) continue;
        const pending = entry.value_ptr.*;
        actions.pushReserved(self, .{ .fail = .{
            .dest = redeem.failureDestination(pending.dest),
            .reason = .{ .static = exporter_closed_reason },
        } });
        releaseRouteAdvice(self, pending.route_advice);
        // Queue the infallible consequence first, then tombstone the iterator's
        // current row; removal cannot allocate or move the backing.
        self.redeems.withdrawals.rows.removeByPtr(entry.key_ptr);
    }
}
