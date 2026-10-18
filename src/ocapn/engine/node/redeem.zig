//! Recipient-side handoff redemption state.
//!
//! The aggregate stays inline in `Node`: dial scheduling owns exporter
//! identity and connection selection, while withdrawals own the exact
//! exporter-answer rows. Their one-way transition is a successful dial
//! beginning one tracked withdrawal per waiter.

const std = @import("std");

const node_actions = @import("actions.zig");
const node_mod = @import("../node.zig");
const dials = @import("redeem/dials.zig");
const withdrawals = @import("redeem/withdrawals.zig");
const model = @import("model");

const Node = node_mod.Node;
const PeerHandle = @import("../peer_handle.zig").PeerHandle;

/// Where one redeemed give settles. The sans-I/O node carries a deferred
/// id back in exactly one terminal action.
pub const Destination = union(enum) {
    answer: node_actions.AnswerDestination,
    deferred: node_actions.DeferredDestination,
};

pub fn recipientPeer(dest: Destination) PeerHandle {
    return switch (dest) {
        .answer => |answer| answer.recipient_peer,
        .deferred => |deferred| deferred.recipient_peer,
    };
}

/// Project a redeem settlement target into the action-owned failure shape.
/// This is cross-file vocabulary only. `Node.FailureDestination` remains the
/// supported action type.
/// Format a redeem failure's reason for its waiters: the transport detail
/// when it fits `buf`, the bare failure otherwise.
pub fn failureMessage(buf: *[256]u8, reason: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "handoff redeem failed: {s}", .{reason}) catch "handoff redeem failed";
}

pub fn failureDestination(dest: Destination) Node.FailureDestination {
    return switch (dest) {
        .answer => |answer| .{ .answer = answer },
        .deferred => |deferred| .{ .deferred = deferred },
    };
}

/// Every mutable fact in one Node's recipient-side redeem scheduler.
/// The aggregate is embedded. It adds no box, callback object, or indirection.
pub const State = struct {
    dials: dials.State = .{},
    withdrawals: withdrawals.State = .{},

    /// Future terminal action seats already promised by admitted redeems.
    pub fn promisedActions(self: *const State) usize {
        return self.dials.waiter_action_reservations + self.withdrawals.rows.count();
    }
};

/// Retire the two child authorities in their existing order. Dial identity and
/// waiter bytes leave before the plain pending-withdraw index is released.
pub fn deinit(self: *Node) void {
    dials.deinit(self);
    withdrawals.deinit(self);
}
