//! Node-local capability route enrollment, generation, lowering, and release.

const std = @import("std");

const model = @import("model");
const engine = @import("../../mod.zig");
const node_mod = @import("../../node.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

/// One node-local route: the live session that holds the real import and the
/// wire reference there. A row is plain data, so enrollment and retirement
/// allocate nothing.
pub const Route = struct {
    peer_handle: PeerHandle,
    far: model.FarRef,
};

pub const ForeignEnrollmentReceipt = struct {
    activated_lowering: bool,
    home: PeerHandle,
    position: model.ImportPosition,
    route_id: model.CapabilityRouteId,
};

pub const ForeignEnrollment = struct {
    reference: model.Reference,
    abandon: ?ForeignEnrollmentReceipt,
};

/// Where a routed deliver lands.
pub const Routed = struct {
    peer_handle: PeerHandle,
    target: model.Reference,
};

/// Remove routes tied to a dying peer without allocating during teardown.
pub fn removeForPeer(routes: *std.AutoHashMapUnmanaged(model.CapabilityRouteId, Route), peer_handle: PeerHandle) void {
    var it = routes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.peer_handle != peer_handle) continue;
        // Removing the iterator's current row tombstones the slot without
        // moving or allocating.
        routes.removeByPtr(entry.key_ptr);
    }
}

/// The node-local route id `reference` names, or null for every wire reference.
/// The explicit union arm, never arithmetic over a wire position, is the
/// namespace discriminator.
pub fn routeIdOf(reference: model.Reference) ?model.CapabilityRouteId {
    return switch (reference) {
        .routed => |routed| routed.id,
        else => null,
    };
}

/// The route `reference` names only when it is a live redeemed handoff route.
/// Foreign-import routes share the counter but remain Node routing identities.
/// A Host lift may consume only this narrower redeemed family.
pub fn redeemedRouteId(self: *const Node, reference: model.Reference) ?model.CapabilityRouteId {
    const route_id = routeIdOf(reference) orelse return null;
    return if (self.redeemed.contains(route_id)) route_id else null;
}

/// Enroll a redeemed capability under a fresh Node route and return its id.
///
/// A routed reference carrying the id later swaps to `far` on the exporter
/// peer. Capacity is reserved by the caller, so nothing here can fail after
/// the exhaustion check.
pub fn enrollRedeemed(self: *Node, exporter_peer: PeerHandle, far: model.FarRef) error{CapabilitySpaceExhausted}!model.CapabilityRouteId {
    if (self.next_route_id.int() == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    const route_id = self.next_route_id;
    self.redeemed.putAssumeCapacity(route_id, .{ .peer_handle = exporter_peer, .far = far });
    self.next_route_id = .from(route_id.int() + 1);
    // The per-peer outbound walk also turns a redeemed route used as Passable
    // data into an inline give. Once a route escapes, keep its cheap gate on.
    self.route_lowering_active = true;
    return route_id;
}

/// Resolve any node-local route id to its route row. Redeemed and foreign
/// imports use the same shape so sends and re-gifts share one address
/// substitution.
pub fn routeById(self: *Node, id: model.CapabilityRouteId) ?Route {
    if (self.redeemed.get(id)) |redeemed| return redeemed;
    return foreignRoute(self, id);
}

/// Resolve a foreign route only while its import generation still owns it.
/// A missing or different session memo means the partner released and perhaps
/// reused that import position. Every reader takes this check before addressing
/// the position under its old meaning.
pub fn foreignRoute(self: *Node, id: model.CapabilityRouteId) ?Route {
    const foreign = self.foreign_imports.get(id) orelse return null;
    const home = Internal.peerAt(self, foreign.peer_handle) orelse return null;
    if (home.session_state.foreignRouteIdFor(foreign.far.import_position) != id) return null;
    return foreign;
}

/// The exporter peer a redeemed or foreign-import route names. This is the
/// deterministic answer to where a handoff capability lives, never a guess
/// based on whichever dial happens to be in flight.
pub fn exporterPeerFor(self: *Node, reference: model.Reference) ?PeerHandle {
    const found = routeById(self, routeIdOf(reference) orelse return null) orelse return null;
    return found.peer_handle;
}

/// Prepare a fetched far import under a node-unique route id.
///
/// Re-enrollment returns the import authority's existing generation and
/// allocates nothing. A fresh enrollment publishes the Session memo before the
/// map row. Abandonment can discard both preparations without reusing the id.
/// The enrolled row also owns reference kind: a caller cannot relabel the same
/// import by presenting another kind on a later fetch.
pub fn prepareForeignEnrollment(self: *Node, home: PeerHandle, far: model.FarRef) !ForeignEnrollment {
    const home_peer = self.peer(home) orelse return error.UnknownPeer;
    if (home_peer.session_state.foreignRouteIdFor(far.import_position)) |existing| {
        const enrolled_kind = if (self.foreign_imports.get(existing)) |row| row.far.kind else far.kind;
        return .{
            .reference = .{ .routed = .{ .id = existing, .kind = enrolled_kind } },
            .abandon = null,
        };
    }
    if (!home_peer.session_state.holdsImport(far.import_position)) return error.UnknownImport;
    if (self.next_route_id.int() == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    try self.foreign_imports.ensureUnusedCapacity(self.allocator, 1);
    const route_id = self.next_route_id;
    try home_peer.session_state.noteForeignRouteId(far.import_position, route_id);
    self.foreign_imports.putAssumeCapacity(route_id, .{ .peer_handle = home, .far = far });
    self.next_route_id = .from(route_id.int() + 1);
    const activated_lowering = !self.route_lowering_active;
    self.route_lowering_active = true;
    return .{
        .reference = .{ .routed = .{ .id = route_id, .kind = far.kind } },
        .abandon = .{
            .activated_lowering = activated_lowering,
            .home = home,
            .position = far.import_position,
            .route_id = route_id,
        },
    };
}

/// Abandon a fresh enrollment before it becomes observable, burning its id.
/// The route and Session memo are the only published preparation. No prior
/// authority is reconstructed and stale ids never gain a new meaning.
pub fn abandonForeignEnrollment(self: *Node, abandoned: ForeignEnrollmentReceipt) void {
    // `prepareForeignEnrollment` minted this receipt on a live home in the same
    // dispatch, and published the route it names.
    const home = self.peer(abandoned.home) orelse unreachable;
    std.debug.assert(home.session_state.foreignRouteIdFor(abandoned.position) == abandoned.route_id);
    home.session_state.abandonForeignRouteId(abandoned.position, abandoned.route_id);
    const removed = self.foreign_imports.fetchRemove(abandoned.route_id) orelse unreachable;
    std.debug.assert(removed.value.peer_handle == abandoned.home);
    if (abandoned.activated_lowering) {
        std.debug.assert(self.foreign_imports.count() == 0);
        self.route_lowering_active = false;
    }
}

/// Enroll a fetched far import and publish its canonical route immediately.
pub fn enrollForeign(self: *Node, home: PeerHandle, far: model.FarRef) !model.Reference {
    return (try prepareForeignEnrollment(self, home, far)).reference;
}

/// The connection a fetched capability route lives on.
pub fn homeOf(self: *Node, route_id: model.CapabilityRouteId) ?PeerHandle {
    return (foreignRoute(self, route_id) orelse return null).peer_handle;
}

/// Whether a raw reference lacks an argument name on `default_peer`. A foreign
/// import is foreign only away from its home. A redeemed or unknown route is
/// foreign everywhere and therefore fails closed on raw verbs.
pub fn argIsForeign(self: *Node, default_peer: PeerHandle, reference: model.Reference) bool {
    const id = routeIdOf(reference) orelse return false;
    if (foreignRoute(self, id)) |found| return found.peer_handle != default_peer;
    return true;
}

/// Lower a routed reference at the one outbound chokepoint.
///
/// Ordinary wire references return after one exhaustive tag check. Routed
/// references pay the map lookup, and only a route homed on this connection
/// can lower. The returned far reference is plain data and moves without
/// allocation. Cross-session redirect and re-gifting are outside this
/// function. They choose another session and are owned by the driver and
/// resolve interceptor.
pub fn lowerForConn(self: *Node, peer_handle: PeerHandle, reference: model.Reference) engine.LoweringError!model.Reference {
    const id = routeIdOf(reference) orelse return reference;
    const found = routeById(self, id) orelse return error.RouteNotLowerable;
    if (found.peer_handle != peer_handle) return error.RouteNotLowerable;
    return .{ .far = found.far };
}

/// Resolve a target to the connection and real reference that carries it.
pub fn routeReference(self: *Node, default_peer: PeerHandle, target: model.Reference) ?Routed {
    if (routeIdOf(target)) |id| return routeCapability(self, id);
    return .{ .peer_handle = default_peer, .target = target };
}

/// Resolve a route with no default connection to fall back to. A missing home
/// or retired generation returns null rather than putting a Node-local id on
/// the wire.
pub fn routeCapability(self: *Node, route_id: model.CapabilityRouteId) ?Routed {
    const found = routeById(self, route_id) orelse return null;
    if (Internal.peerAt(self, found.peer_handle) == null) return null;
    return .{ .peer_handle = found.peer_handle, .target = .{ .far = found.far } };
}

/// Retire a route once its real wire import generation is no longer live. status-allow: lifecycle transition
/// Partial releases leave the route intact while the session row exists. Once
/// it is gone, retaining the route would let an old capability address a newly
/// reused import position.
pub fn retireReleasedRoute(self: *Node, route_id: model.CapabilityRouteId) void {
    if (self.redeemed.get(route_id)) |row| {
        const home = Internal.peerAt(self, row.peer_handle) orelse return;
        if (home.session_state.hasImport(row.far.import_position)) return;
        std.debug.assert(self.redeemed.remove(route_id));
    } else if (self.foreign_imports.get(route_id)) |row| {
        const home = Internal.peerAt(self, row.peer_handle) orelse return;
        // A reused row may exist here. The generation, not presence,
        // decides whether this route still belongs to it.
        if (home.session_state.foreignRouteIdFor(row.far.import_position) == route_id) return;
        std.debug.assert(self.foreign_imports.remove(route_id));
    }
}

/// Consume a redeemed route when the Host lifts its real import incarnation.
/// This transfers identity authority to the Host. Keeping the Node row would
/// leave a second stale-capable handle. Foreign routes remain session-owned.
pub fn consumeRedeemedRoute(self: *Node, route_id: model.CapabilityRouteId) bool {
    return self.redeemed.remove(route_id);
}
