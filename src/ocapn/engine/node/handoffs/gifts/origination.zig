//! Gifter-side root answers use the same Passable transaction as nested gifts.

const model = @import("model");
const session_mod = @import("session");
const node_mod = @import("../../../node.zig");
const passable_batches = @import("../../passable/batches.zig");
const membership = @import("../../peers/membership.zig");
const routes = @import("../../peers/routes.zig");
const tickets = @import("tickets.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;

/// Claim an application answer only when its fulfilled capability is homed on
/// another connection. Entropy is requested only after the answer is known to
/// need a gift. `false` leaves the ordinary resolution path untouched. Foreign
/// promise routes remain proxy-owned and are not gifted here.
pub fn interceptFulfilledRoute(
    self: *Node,
    peer_handle: PeerHandle,
    answer: u64,
    route_id: model.CapabilityRouteId,
) !bool {
    if (!routeNeedsGift(self, peer_handle, route_id)) return false;
    const recipient = membership.peer(self, peer_handle) orelse return error.UnknownConnection;
    const target = recipient.session_state.answerTargetNamed(.fromWire(.from(answer))) orelse
        return error.InvalidReference;
    return interceptFulfilledRouteNamed(self, peer_handle, target, route_id);
}

pub fn interceptFulfilledRouteNamed(
    self: *Node,
    peer_handle: PeerHandle,
    answer: session_mod.AnswerTarget,
    route_id: model.CapabilityRouteId,
) !bool {
    if (!routeNeedsGift(self, peer_handle, route_id)) return false;
    const recipient = membership.peer(self, peer_handle) orelse return error.UnknownConnection;
    try recipient.sendAnswerTargetResolutionCopying(answer, .{ .fulfill = .{ .reference = .{
        .routed = .{ .id = route_id, .kind = .object },
    } } });
    return true;
}

fn routeNeedsGift(self: *Node, peer_handle: PeerHandle, route_id: model.CapabilityRouteId) bool {
    const enrolled = routes.foreignRoute(self, route_id) orelse return false;
    return enrolled.peer_handle != peer_handle and enrolled.far.kind != .promise;
}

/// Complete one delayed Passable occurrence. Root answers and nested gifts
/// share its transaction and lifetime. The two independent sessions may
/// deliver either half first.
/// Unknown tickets stay idempotent even for malformed bytes. A live ticket
/// refuses malformed entropy before reserving consequences or consuming the
/// row, so the host can retry it.
pub fn provideGiftId(self: *Node, ticket: u64, gift_id: []const u8) !void {
    if (!tickets.contains(self, ticket)) return;
    if (gift_id.len != model.handoff_gift_id_bytes) return error.InvalidArgument;
    // The staged batch already reserved its completion and failure actions.
    const pending = tickets.take(self, ticket) orelse unreachable;
    passable_batches.provideGiftId(
        self,
        pending.recipient_peer,
        pending.route_id,
        pending.staged,
        gift_id,
    );
}

/// Terminalize a live entropy request the embedder could not answer. The
/// destination must settle rather than leaving authority parked forever.
/// Unknown or already-retired tickets remain idempotent no-ops.
pub fn giftIdFailed(self: *Node, ticket: u64) !void {
    if (!tickets.contains(self, ticket)) return;
    const pending = tickets.take(self, ticket) orelse unreachable;
    passable_batches.fail(self, pending.staged.batch, error.GiftIdUnavailable);
}
