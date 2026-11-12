//! Local callable custody for an answer whose published root is a handoff.
//! The answer owns this cold ticket. The composition owns the actual callable.
const std = @import("std");
const model = @import("model");
const session = @import("session");
const node_mod = @import("../../node.zig");
const services = @import("../../node_services.zig");
const passable = @import("../passable.zig");
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;
const Node = node_mod.Node;
const Target = session.AnswerPayload.PipelineTarget;
const engine = @import("../../mod.zig");

/// The embedder binds a private callable export which forwards to `route`.
/// It owns an independent retain on that capability. The export has no wire
/// retains: only synthetic local delivery may reach it. Retirement arrives as
/// `release_pipeline_export`, including when the staged settlement fails.
/// Dispatch private deliveries and retirement in FIFO order. Event disposal
/// has no callable effect, so ignored retirements remain the binding owner
/// responsibility until teardown. Host supplies this composition.
pub const Projection = struct {
    pub const Result = Projected;
    ctx: ?*anyopaque,
    prepare: *const fn (?*anyopaque, PeerHandle, model.CapabilityRouteId, ?u64) services.OutboundStagingError!Projected,
};
pub const Projected = struct { near: model.NearRef, target: u64 };

/// One cold allocation and one reserved Event seat per projected object
/// answer. The AnswerPayload owns it. Its final release only publishes POD.
const Ticket = struct {
    target: Target,
    peer: *engine.Peer,
    local_target: u64,

    fn retire(target: *Target) void {
        const self: *Ticket = @fieldParentPtr("target", target);
        const peer = self.peer;
        peer.events.pushReserved(.{
            .payload = .{ .release_pipeline_export = .{ .near = target.near, .target = self.local_target } },
            .codec = peer.session_state.codec,
            .captp_version = peer.session_state.captp_version,
            .allocator = peer.allocator,
        });
        peer.allocator.destroy(self);
    }
};

/// Only a root object settlement changes its callable meaning when rewritten
/// as a give. Nested values and projected promises keep their ordinary path.
pub fn prepare(node: *Node, recipient: PeerHandle, payload: *passable.Outbound, gifts: []const passable.Gift) !?*Target {
    if (payload.* != .answer_settlement) return null;
    const projection = node.pipeline_projection orelse return null;
    const root = payload.resolutionRoot() orelse return null;
    for (gifts) |gift| {
        if (gift.slot != .root) continue;
        std.debug.assert(root.* == .reference);
        std.debug.assert(payload.answer_settlement.payload.pipeline_target == null);
        const peer = node.peer(recipient) orelse return error.PeerGone;
        try peer.events.reserve(peer.allocator);
        errdefer peer.events.cancelReservation();
        const ticket = try peer.allocator.create(Ticket);
        errdefer peer.allocator.destroy(ticket);
        const projected = try projection.prepare(projection.ctx, recipient, gift.route_id, gift.capability_lease);
        ticket.* = .{
            .target = .{ .near = projected.near, .retire = Ticket.retire },
            .peer = peer,
            .local_target = projected.target,
        };
        return &ticket.target;
    }
    return null;
}
