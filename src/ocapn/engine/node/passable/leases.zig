//! Outbound capability leases for inline-Passable projection.
//!
//! A Host lowering transaction retains projected local capabilities before it
//! enters `Peer.send`/`tell`. Inline Passable staging claims exactly the leases
//! it adopts, so rollback can release only the still-host-owned retains.

const std = @import("std");

const model = @import("model");
const engine = @import("../../mod.zig");
const node_mod = @import("../../node.zig");
const peer_routes = @import("../peers/routes.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

pub const Lease = struct {
    route_id: model.CapabilityRouteId,
    capability: u64,
    claimed: bool = false,
};

pub const ProjectionRoute = struct {
    route_id: model.CapabilityRouteId,
    home: PeerHandle,
    source: model.FarRef,
    kind: enum { object, promise },
};

pub fn begin(self: *Node, leases: []Lease) void {
    std.debug.assert(self.outbound_staging_leases == null);
    self.outbound_staging_leases = leases;
}

pub fn end(self: *Node) void {
    std.debug.assert(self.outbound_staging_leases != null);
    self.outbound_staging_leases = null;
}

pub fn claim(self: *Node, route_id: model.CapabilityRouteId) ?u64 {
    const leases = self.outbound_staging_leases orelse return null;
    for (leases) |*lease| {
        if (lease.route_id != route_id or lease.claimed) continue;
        lease.claimed = true;
        return lease.capability;
    }
    return null;
}

pub fn unclaim(self: *Node, route_id: model.CapabilityRouteId, capability_raw: u64) void {
    // Only a capability `claim` answered is unclaimed, inside the same
    // `begin`/`end` window.
    const leases = self.outbound_staging_leases orelse unreachable;
    for (leases) |*lease| {
        if (lease.route_id != route_id or lease.capability != capability_raw or !lease.claimed) continue;
        lease.claimed = false;
        return;
    }
    unreachable;
}

pub fn inlineProjectionRoute(
    self: *Node,
    recipient_peer: PeerHandle,
    reference: model.Reference,
) engine.node_services.OutboundStagingError!?ProjectionRoute {
    const route_id = peer_routes.routeIdOf(reference) orelse return null;
    const gift_route = peer_routes.routeById(self, route_id) orelse return error.RouteNotLowerable;
    if (gift_route.peer_handle == recipient_peer) return null;
    const routed = switch (reference) {
        .routed => |value| value,
        else => return error.RouteNotLowerable,
    };
    return .{
        .route_id = route_id,
        .home = gift_route.peer_handle,
        .source = gift_route.far,
        .kind = switch (routed.kind) {
            .object => .object,
            .promise => .promise,
        },
    };
}
