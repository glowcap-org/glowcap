//! Tracked exporter withdrawals and their exact terminal claim.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
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
    /// The withdraw answer's identity, so a resolve names this row only
    /// while the question it answers is the one this row asked.
    row_id: u64,
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
    if (candidate.pending == 0) destroyRouteAdvice(self, candidate);
}

fn releaseRouteAdvice(self: *Node, advice: ?*RouteAdvice) void {
    const candidate = advice orelse return;
    std.debug.assert(candidate.pending != 0);
    candidate.pending -= 1;
    if (candidate.pending == 0) destroyRouteAdvice(self, candidate);
}

fn destroyRouteAdvice(self: *Node, candidate: *RouteAdvice) void {
    if (candidate.location) |location| self.allocator.free(location);
    self.allocator.destroy(candidate);
}

/// Queue a terminal failure carrying an owned copy of `reason`, and the
/// retirement of `retire` under the same reservation.
pub fn queueFailure(self: *Node, dest: redeem.Destination, reason: []const u8, retire: ?PeerHandle) !void {
    const owned = try self.allocator.dupe(u8, reason);
    errdefer self.allocator.free(owned);
    try actions.reserve(self, if (retire != null) 2 else 1);
    actions.pushReserved(self, .{ .fail = .{
        .dest = redeem.failureDestination(dest),
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
        return queueFailure(self, dest, "handoff redeem failed: exporter session is gone", null);
    const session = slot.peer;
    try self.redeems.withdrawals.rows.ensureUnusedCapacity(self.allocator, 1);
    // One immediate flush plus this pending redeem's eventual close failure.
    try actions.reserve(self, 2);
    // Sign with the introducing session: the give named that identity as its
    // recipient_key. The exporter session supplies its own side/session names.
    var recipient_secret = Internal.sessionSecret(self, redeem.recipientPeer(dest)) orelse
        return queueFailure(self, dest, "handoff redeem failed: introducing session is gone", null);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&recipient_secret));
    const withdraw_answer = try session.allocateAnswer();
    session.sendWithdrawGift(
        recipient_secret,
        give,
        withdraw_answer.position,
    ) catch |err| {
        // The send refused before the partner saw the position.
        session.session_state.abandonOutboundAnswer(withdraw_answer.position);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var buf: [256]u8 = undefined;
        return queueFailure(self, dest, redeem.failureMessage(&buf, @errorName(err)), null);
    };
    self.redeems.withdrawals.rows.putAssumeCapacity(
        .{ .peer_handle = exporter_peer, .answer = withdraw_answer.position.int() },
        .{ .dest = dest, .row_id = withdraw_answer.row_id, .route_advice = route_advice },
    );
    if (route_advice) |advice| advice.pending += 1;
    std.debug.assert(slot.pending_withdraw_count < std.math.maxInt(u32));
    slot.pending_withdraw_count += 1;
    actions.pushReserved(self, .{ .flush = exporter_peer });
}

/// Offer an exporter resolve to the exact pending-withdraw authority. A
/// matching row is consumed only after its settlement consequence commits.
pub fn claim(self: *Node, peer_handle: PeerHandle, answer: session_mod.OutboundAnswerTarget, outcome: Outcome) !bool {
    const key: Key = .{ .peer_handle = peer_handle, .answer = answer.position.int() };
    const rows = &self.redeems.withdrawals.rows;
    const pending = rows.get(key) orelse return false;
    if (pending.row_id != answer.row_id) return false;
    // `peer_handle` is the session that delivered this resolve, so it is live.
    const slot = self.peers.getPtr(peer_handle) orelse unreachable;
    std.debug.assert(slot.pending_withdraw_count != 0);
    // A failed final use of a redeem-only exporter retires it in the same
    // reservation.
    const retire: ?PeerHandle = if (slot.provisional_exporter and
        slot.pending_withdraw_count == 1) peer_handle else null;
    switch (outcome) {
        .far => |far_id| {
            // Reserve route and action capacity before enrollment, so
            // allocation failure leaves the withdraw retriable and strands no
            // route whose settlement was never published.
            try self.redeemed.ensureUnusedCapacity(self.allocator, 1);
            try actions.reserve(self, 1);
            if (pending.route_advice) |advice| {
                if (advice.location != null)
                    try gift_recipe.reserveDiscoveredSlot(self, peer_handle);
            }
            const route_id = try peer_routes.enrollRedeemed(self, peer_handle, model.FarRef.object(far_id));
            actions.pushReserved(self, .{ .settle = .{ .dest = pending.dest, .route_id = route_id } });
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
            try queueFailure(self, pending.dest, redeem.failureMessage(&buf, reason), retire);
        },
        .not_capability => try queueFailure(
            self,
            pending.dest,
            "withdraw-gift did not resolve to a capability",
            retire,
        ),
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
