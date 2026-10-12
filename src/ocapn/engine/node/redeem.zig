//! Recipient-side handoff redemption state.
//!
//! The aggregate stays inline in `Node`: dial scheduling owns exporter
//! identity and connection selection, while withdrawals own the exact
//! exporter-answer rows. Their one-way transition is a successful dial
//! beginning one tracked withdrawal per waiter.

const std = @import("std");

const node_mod = @import("../node.zig");
const dials = @import("redeem/dials.zig");
const withdrawals = @import("redeem/withdrawals.zig");
const model = @import("model");

const Node = node_mod.Node;
const PeerHandle = @import("../peer_handle.zig").PeerHandle;

/// Where one redeemed give settles. An answer is the traditional returned
/// handoff. A deferred id is Host-owned promise authority for a give found
/// inline in a Passable value. The sans-I/O node carries the opaque id back in
/// exactly one terminal action.
pub const Destination = union(enum) {
    answer: struct { recipient_peer: PeerHandle, answer: model.AnswerPosition },
    deferred: struct { recipient_peer: PeerHandle, id: u64 },
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
pub fn failureDestination(dest: Destination) Node.FailureDestination {
    return switch (dest) {
        .answer => |answer| .{ .answer = .{
            .recipient_peer = answer.recipient_peer,
            .answer = answer.answer,
        } },
        .deferred => |deferred| .{ .deferred = .{
            .recipient_peer = deferred.recipient_peer,
            .id = deferred.id,
        } },
    };
}

/// Every mutable fact in one Node's recipient-side redeem scheduler.
/// The aggregate is embedded. It adds no box, callback object, or indirection.
pub const State = struct {
    dials: dials.State = .{},
    withdrawals: withdrawals.State = .{},

    /// Future terminal action seats already promised by admitted redeems.
    pub fn promisedActions(self: *const State) error{OutOfMemory}!usize {
        return std.math.add(
            usize,
            self.dials.waiter_action_reservations,
            self.withdrawals.rows.count(),
        ) catch error.OutOfMemory;
    }
};

/// Retire the two child authorities in their existing order. Dial identity and
/// waiter bytes leave before the plain pending-withdraw index is released.
pub fn deinit(self: *Node) void {
    dials.deinit(self);
    withdrawals.deinit(self);
}
