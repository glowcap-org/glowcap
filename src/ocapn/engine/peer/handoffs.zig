//! Peer-local three-party handoff admission, parking, and settlement.
//!
//! The Session and gift registry retain protocol authority. This module owns
//! the bounded scheduler-facing transaction that parks a verified early
//! withdrawal, wakes only its exact dependency, and retires each owned receive
//! after its settlement has entered the ordinary outbound path.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const bootstrap = @import("../bootstrap.zig");
const engine = @import("../mod.zig");
const handoff_gifter = @import("../handoff_gifter.zig");
const handoff_recipient = @import("../handoff_recipient.zig");
const node_services = @import("../node_services.zig");
const outbound = @import("../outbound.zig");

const Peer = engine.Peer;

/// One inbound `withdraw-gift` parked until its gift is deposited (ADR-0039).
/// Owns `receive`. Freed when the withdrawal settles or at Peer teardown.
pub const PendingWithdraw = struct {
    receive: bootstrap.PendingReceive,
    answer: model.AnswerName,
};

/// Parked receives sharing one exact scheduler identity. The signed gift id
/// remains in every owned receive. The fixed-size key only selects the bounded
/// group to retry after a deposit or gifter close.
pub const PendingWithdrawGroup = struct {
    rows: std.ArrayListUnmanaged(PendingWithdraw) = .empty,
};

/// Commit a prepared withdrawal settlement. Preparation owns the one outbound
/// clone and accepted replay count. The message publishes before the gift
/// moves, so a send refusal leaves the gift retryable.
pub fn sendWithdrawSettled(self: *Peer, prepared_in: bootstrap.PreparedWithdraw) !void {
    var prepared = prepared_in;
    defer prepared.deinit(self.allocator);
    try outbound.enqueueAnswerResolutionOwned(
        self,
        prepared.answer,
        try prepared.takeResolution(),
    );
    prepared.apply(self.allocator, self.localObjectProjection(), self.giftRegistry());
}

/// The peer handle a Host composition scopes this session's handoffs under,
/// or null for a standalone peer.
pub fn peerHandleScope(self: *const Peer) ?engine.PeerHandle {
    return if (self.node_services) |services| services.peer_handle else null;
}

/// Admit one verified early withdrawal, held to the session's pending-withdraw
/// count and byte caps, without half-installing replay authority or a Node
/// scheduler row on OOM. A new group reserves its row, its map seat, and its
/// scheduler row before anything moves, so the tail after acceptance is
/// infallible.
pub fn parkPendingWithdraw(
    self: *Peer,
    receive: bootstrap.PendingReceive,
    answer: model.AnswerName,
    gifter_peer_handle: engine.PeerHandle,
) !void {
    if (self.pending_withdraw_count >= self.session_state.limits.max_pending_withdraws)
        return error.PendingWithdrawCapExceeded;
    if (receive.retainedBytes() > self.session_state.limits.max_frame_bytes -| self.pending_withdraw_bytes)
        return error.PendingWithdrawCapExceeded;
    const dependency = node_services.HandoffDependency.init(gifter_peer_handle, receive.gift_id);
    if (self.pending_withdraws.getPtr(dependency)) |group| {
        try group.rows.ensureUnusedCapacity(self.allocator, 1);
    } else {
        var group: PendingWithdrawGroup = .{};
        errdefer group.rows.deinit(self.allocator);
        try group.rows.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_withdraws.ensureUnusedCapacity(self.allocator, 1);
        if (self.node_services) |services| try services.pendingWithdrawAdded(dependency);
        self.pending_withdraws.putAssumeCapacity(dependency, group);
    }
    const group = self.pending_withdraws.getPtr(dependency).?;
    self.giftRegistry().acceptValidatedPendingWithdraw(receive.handoff_count);
    group.rows.appendAssumeCapacity(.{ .receive = receive, .answer = answer });
    self.pending_withdraw_count += 1;
    self.pending_withdraw_bytes += receive.retainedBytes();
}

/// Record the exact scheduler wake the Host will drive next. The Host consumes
/// changes one at a time and reaches quiescence between them. A distinct second
/// dependency here would violate that composition.
pub fn noteHandoffChange(self: *Peer, dependency: node_services.HandoffDependency) void {
    std.debug.assert(
        self.pending_handoff_change == null or
            std.meta.eql(self.pending_handoff_change.?, dependency),
    );
    self.pending_handoff_change = dependency;
}

/// Queue the recipient half of a three-party handoff.
pub fn sendWithdrawGift(
    self: *Peer,
    secret: foundation.crypto.SecretKey,
    give_bytes: []const u8,
    answer: model.AnswerPosition,
) !void {
    return handoff_recipient.sendWithdrawGift(self, secret, give_bytes, answer);
}

/// Queue `deposit-gift` to this exporter session's bootstrap object.
pub fn sendDepositGift(self: *Peer, gift_id: []const u8, gifted: model.Reference) !void {
    return handoff_gifter.sendDepositGift(self, gift_id, gifted);
}

/// Resolve `answer` with a signed `desc:handoff-give`.
pub fn sendResolveHandoffGive(
    self: *Peer,
    answer: session.AnswerTarget,
    give_bytes: []const u8,
) !void {
    return handoff_gifter.sendResolveHandoffGive(self, answer, give_bytes);
}

/// Retry the exact parked group whose gift changed. A standalone Peer with a
/// custom resolver has no Node scheduler, so it retains the explicit-drive
/// fallback and scans groups. Production Node compositions never pay it.
pub fn settlePendingWithdraws(self: *Peer) !void {
    if (self.pending_withdraw_count == 0) {
        self.pending_handoff_change = null;
        return;
    }
    if (self.node_services != null) {
        const dependency = self.pending_handoff_change orelse return;
        try settlePendingWithdrawGroup(self, dependency);
        self.pending_handoff_change = null;
        return;
    }

    // Removing the iterator's current entry only tombstones that slot; it
    // neither reallocates nor moves backing, so iteration needs no partner-sized
    // auxiliary key copy.
    var it = self.pending_withdraws.iterator();
    while (it.next()) |entry| try settlePendingWithdrawGroup(self, entry.key_ptr.*);
}

fn settlePendingWithdrawGroup(
    self: *Peer,
    dependency: node_services.HandoffDependency,
) !void {
    const group = self.pending_withdraws.getPtr(dependency) orelse return;
    var index: usize = 0;
    while (index < group.rows.items.len) {
        const entry = &group.rows.items[index];
        const scope = self.peerHandleScope();
        const settled_withdraw = (try bootstrap.resolvePendingWithdraw(
            self.allocator,
            self.gifterSessionResolver(),
            self.localObjectProjection(),
            scope,
            entry.receive,
            entry.answer,
        )) orelse {
            index += 1;
            continue;
        };
        try sendWithdrawSettled(self, settled_withdraw);
        var settled = group.rows.swapRemove(index);
        self.pending_withdraw_bytes -= settled.receive.retainedBytes();
        settled.receive.deinit(self.allocator);
        self.pending_withdraw_count -= 1;
    }
    if (group.rows.items.len != 0) return;

    if (self.node_services) |services| services.pendingWithdrawRemoved(dependency);
    const removed = self.pending_withdraws.fetchRemove(dependency).?;
    var empty_group = removed.value;
    empty_group.rows.deinit(self.allocator);
}
