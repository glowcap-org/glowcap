//! Gifter-side answer interception and two-Peer give origination.

const model = @import("model");
const session_mod = @import("session");
const engine = @import("../../../mod.zig");
const actions = @import("../../actions.zig");
const node_mod = @import("../../../node.zig");
const passable_batches = @import("../../passable/batches.zig");
const membership = @import("../../peers/membership.zig");
const routes = @import("../../peers/routes.zig");
const recipe = @import("recipe.zig");
const tickets = @import("tickets.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;

/// Claim an application answer only when its fulfilled capability is homed on
/// another connection. Entropy is requested only after the answer is known to
/// need a gift; false leaves the ordinary resolution path untouched. Foreign
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
    try tickets.requestAnswer(self, peer_handle, route_id, target);
    return true;
}

pub fn interceptFulfilledRouteNamed(
    self: *Node,
    peer_handle: PeerHandle,
    answer: session_mod.AnswerTarget,
    route_id: model.CapabilityRouteId,
) !bool {
    if (!routeNeedsGift(self, peer_handle, route_id)) return false;
    try tickets.requestAnswer(self, peer_handle, route_id, answer);
    return true;
}

fn routeNeedsGift(self: *Node, peer_handle: PeerHandle, route_id: model.CapabilityRouteId) bool {
    const home = routes.homeOf(self, route_id) orelse return false;
    if (home == peer_handle) return false;
    if (routes.foreignRoute(self, route_id)) |enrolled|
        if (enrolled.reference == .far and enrolled.reference.far.kind == .promise) return false;
    return true;
}

/// Complete a live entropy request by depositing on the exporter and resolving
/// the claimed recipient answer, or by completing one delayed inline-Passable
/// occurrence. The two independent sessions may deliver either half first.
/// Unknown tickets stay idempotent even for malformed bytes; a live ticket
/// refuses malformed entropy before reserving consequences or consuming the
/// row, so the host can retry it.
pub fn provideGiftId(self: *Node, ticket: u64, gift_id: []const u8) !void {
    if (!tickets.contains(self, ticket)) return;
    if (gift_id.len != model.HANDOFF_GIFT_ID_BYTES) return error.InvalidArgument;
    // Reserve the largest consequence before consuming the ticket. From this
    // commit point the handoff either queues both flushes or settles broken.
    try actions.reserve(self, 2);
    const pending = tickets.take(self, ticket) orelse unreachable;
    switch (pending.dest) {
        .inline_gift => |staged| {
            passable_batches.provideGiftId(
                self,
                pending.recipient_peer,
                pending.route_id,
                staged,
                gift_id,
            );
            return;
        },
        .answer => |answer| {
            const routed = routes.route(self, .{ .routed = .{ .id = pending.route_id } }) orelse {
                failAnswerReserved(self, pending.recipient_peer, answer, "handoff origination failed: home connection is gone");
                return;
            };
            originateGive(
                self,
                pending.recipient_peer,
                routed.peer_handle,
                routed.reference,
                gift_id,
                answer,
                recipe.get(self, routed.peer_handle),
            ) catch {
                // The ticket is spent and no retry can reconstruct the claimed
                // answer, including after allocation failure.
                failAnswerReserved(self, pending.recipient_peer, answer, "handoff origination failed: resource unavailable");
                return;
            };
            actions.pushReserved(self, .{ .flush = routed.peer_handle });
            actions.pushReserved(self, .{ .flush = pending.recipient_peer });
        },
    }
}

/// Terminalize a live entropy request the embedder could not answer. The
/// destination must settle rather than leaving authority parked forever;
/// unknown or already-retired tickets remain idempotent no-ops.
pub fn giftIdFailed(self: *Node, ticket: u64) !void {
    if (!tickets.contains(self, ticket)) return;
    // Direct embedders may report before popping the request, so acquire the
    // terminal action seat independently of queue cursor state.
    try actions.reserve(self, 1);
    const pending = tickets.take(self, ticket) orelse unreachable;
    switch (pending.dest) {
        .answer => |answer| failAnswerReserved(
            self,
            pending.recipient_peer,
            answer,
            "handoff origination failed: gift-id entropy unavailable",
        ),
        .inline_gift => |staged| passable_batches.fail(
            self,
            staged.batch,
            error.GiftIdUnavailable,
        ),
    }
}

fn failAnswerReserved(
    self: *Node,
    recipient_peer: PeerHandle,
    answer: session_mod.AnswerTarget,
    reason: []const u8,
) void {
    actions.pushReserved(self, .{ .fail = .{
        .dest = .{ .served_answer = .{ .recipient_peer = recipient_peer, .answer = answer } },
        .reason = .{ .static = reason },
    } });
}

/// Queue the exporter deposit and recipient answer fulfillment as one prepared
/// transaction. Signing finishes before either queue is prepared, and the
/// exporter location is either the explicit override or the exact locator its
/// keyed session claimed. Both transports may still deliver either queue first.
fn originateGive(
    self: *Node,
    recipient_peer: PeerHandle,
    exporter_peer: PeerHandle,
    gifted: model.Reference,
    gift_id: []const u8,
    answer: session_mod.AnswerTarget,
    exporter_location: []const u8,
) !void {
    const recipient = membership.peerAt(self, recipient_peer) orelse
        return error.UnknownConnection;
    const exporter = membership.peerAt(self, exporter_peer) orelse
        return error.UnknownConnection;
    const recipient_key = recipient.session_state.partnerSessionKey() orelse
        return error.NoRecipientKey;
    const exporter_key = exporter.session_state.partnerSessionKey() orelse
        return error.NoExporterKey;
    const claimed = exporter.session_state.partnerLocatorRaw() orelse
        return error.NoExporterLocator;
    const give = try recipe.mint(
        self,
        recipient,
        recipient_peer,
        exporter_peer,
        gift_id,
        recipient_key,
        exporter_key,
        if (exporter_location.len != 0) exporter_location else claimed,
    );
    defer self.allocator.free(give);
    try engine.handoff_gifter.queueOriginatedGive(
        exporter,
        recipient,
        gift_id,
        gifted,
        give,
        .{ .answer = answer },
    );
}
