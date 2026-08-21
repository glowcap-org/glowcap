//! Node-local capability route enrollment, generation, lowering, and release.

const std = @import("std");

const model = @import("model");
const engine = @import("../../mod.zig");
const node_mod = @import("../../node.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

/// One node-local route to a live session and its real wire reference. The Node
/// owns `reference` and frees it at route retirement or teardown.
pub const Route = struct {
    peer_handle: PeerHandle,
    reference: model.Reference,
};

pub const ForeignEnrollmentRollback = struct {
    activated_lowering: bool,
    home: PeerHandle,
    position: model.ImportPosition,
    route_id: model.CapabilityRouteId,
};

pub const ForeignEnrollment = struct {
    reference: model.Reference,
    rollback: ?ForeignEnrollmentRollback,
};

/// Where a routed deliver lands.
pub const Routed = struct {
    peer_handle: PeerHandle,
    target: model.Reference,
};

/// Remove routes tied to a dying peer without allocating during teardown.
pub fn removeForPeer(
    self: *Node,
    routes: *std.AutoHashMapUnmanaged(model.CapabilityRouteId, Route),
    peer_handle: PeerHandle,
) void {
    var it = routes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.peer_handle != peer_handle) continue;
        const owned = entry.value_ptr.reference;
        // Removing the iterator's current row tombstones the slot without
        // moving or allocating. Free only after the table releases ownership.
        routes.removeByPtr(entry.key_ptr);
        model.freeReference(self.allocator, owned);
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
/// Foreign-import routes share the counter but remain Node routing identities;
/// a Host lift may consume only this narrower redeemed family.
pub fn redeemedRouteId(self: *const Node, reference: model.Reference) ?model.CapabilityRouteId {
    const route_id = routeIdOf(reference) orelse return null;
    return if (self.redeemed.contains(route_id)) route_id else null;
}

/// Enroll a redeemed capability under a fresh Node route.
///
/// The returned explicit routed reference later swaps to `reference` on the
/// exporter peer. The Node clones and owns that real reference; the caller
/// retains its own.
///
/// Capacity is reserved by the caller, so cloning is the only fallible step
/// before commit. The id advances only after the owned reference is installed.
pub fn enrollRedeemed(self: *Node, exporter_peer: PeerHandle, reference: model.Reference) !model.Reference {
    if (self.next_route_id.int() == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    const owned = try model.cloneReference(self.allocator, reference);
    const route_id = self.next_route_id;
    self.redeemed.putAssumeCapacity(route_id, .{ .peer_handle = exporter_peer, .reference = owned });
    self.next_route_id = .from(route_id.int() + 1);
    // The per-peer outbound walk also turns a redeemed route used as Passable
    // data into an inline give. Once a route escapes, keep its cheap gate on.
    self.route_lowering_active = true;
    return .{ .routed = .{ .id = route_id, .kind = .object } };
}

/// Resolve any node-local route to its route row. Redeemed and foreign imports
/// use the same shape so sends and re-gifts share one address substitution.
pub fn route(self: *Node, reference: model.Reference) ?Route {
    const id = routeIdOf(reference) orelse return null;
    if (self.redeemed.get(id)) |redeemed| return redeemed;
    return foreignRoute(self, id);
}

/// Resolve a foreign route only while its import generation still owns it.
/// A missing or different session memo means the partner released and perhaps
/// reused that import position; every reader takes this check before addressing
/// the position under its old meaning.
pub fn foreignRoute(self: *Node, id: model.CapabilityRouteId) ?Route {
    const foreign = self.foreign_imports.get(id) orelse return null;
    const home = Internal.peerAt(self, foreign.peer_handle) orelse return null;
    const position = switch (foreign.reference) {
        .far => |far| far.import_position,
        else => return null,
    };
    if (home.session_state.foreignRouteIdFor(position) != id) return null;
    return foreign;
}

/// The exporter peer a redeemed or foreign-import route names. This is the
/// deterministic answer to where a handoff capability lives, never a guess
/// based on whichever dial happens to be in flight.
pub fn exporterPeerFor(self: *Node, reference: model.Reference) ?PeerHandle {
    const found = route(self, reference) orelse return null;
    return found.peer_handle;
}

/// Prepare a fetched far import under a node-unique route id.
///
/// Re-enrollment returns the import row's existing generation and allocates
/// nothing. A fresh enrollment publishes the session memo before the map row;
/// rollback can therefore restore both authorities without reusing the id.
/// The enrolled row also owns reference kind: a caller cannot relabel the same
/// import by presenting another kind on a later fetch.
pub fn prepareForeignEnrollment(self: *Node, home: PeerHandle, wire: model.Reference) !ForeignEnrollment {
    const far = switch (wire) {
        .far => |value| value,
        else => return error.NotAFarReference,
    };
    const home_peer = self.peer(home) orelse return error.UnknownPeer;
    const kind = far.kind;
    if (home_peer.session_state.foreignRouteIdFor(far.import_position)) |existing| {
        const enrolled_kind = if (self.foreign_imports.get(existing)) |row|
            switch (row.reference) {
                .far => |enrolled_far| enrolled_far.kind,
                else => kind,
            }
        else
            kind;
        return .{
            .reference = .{ .routed = .{ .id = existing, .kind = enrolled_kind } },
            .rollback = null,
        };
    }
    if (!home_peer.session_state.hasImport(far.import_position)) return error.UnknownImport;
    if (self.next_route_id.int() == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    try self.foreign_imports.ensureUnusedCapacity(self.allocator, 1);
    const route_id = self.next_route_id;
    try home_peer.session_state.noteForeignRouteId(far.import_position, route_id);
    self.foreign_imports.putAssumeCapacity(route_id, .{ .peer_handle = home, .reference = wire });
    self.next_route_id = .from(route_id.int() + 1);
    const activated_lowering = !self.route_lowering_active;
    self.route_lowering_active = true;
    return .{
        .reference = .{ .routed = .{ .id = route_id, .kind = kind } },
        .rollback = .{
            .activated_lowering = activated_lowering,
            .home = home,
            .position = far.import_position,
            .route_id = route_id,
        },
    };
}

/// Undo a fresh enrollment before it becomes observable, burning its id. Only
/// the route and import-row memo roll back, so stale ids never gain a new
/// meaning even when the larger transaction fails.
pub fn rollbackForeignEnrollment(self: *Node, rollback: ForeignEnrollmentRollback) void {
    const home = self.peer(rollback.home) orelse unreachable;
    std.debug.assert(home.session_state.foreignRouteIdFor(rollback.position) == rollback.route_id);
    home.session_state.abandonForeignRouteId(rollback.position, rollback.route_id);
    const removed = self.foreign_imports.fetchRemove(rollback.route_id) orelse unreachable;
    std.debug.assert(removed.value.peer_handle == rollback.home);
    model.freeReference(self.allocator, removed.value.reference);
    if (rollback.activated_lowering) {
        std.debug.assert(self.foreign_imports.count() == 0);
        self.route_lowering_active = false;
    }
}

/// Enroll a fetched far import and publish its canonical route immediately.
pub fn enrollForeign(self: *Node, home: PeerHandle, wire: model.Reference) !model.Reference {
    return (try prepareForeignEnrollment(self, home, wire)).reference;
}

/// The connection a fetched capability route lives on.
pub fn homeOf(self: *Node, route_id: model.CapabilityRouteId) ?PeerHandle {
    if (foreignRoute(self, route_id)) |found| return found.peer_handle;
    return null;
}

/// Whether a raw reference lacks an argument name on `default_peer`. A foreign
/// import is foreign only away from its home; a redeemed or unknown route is
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
/// can lower. The returned far reference is POD and moves without allocation.
/// Cross-session redirect and re-gifting are deliberately outside this
/// function; they choose another session and are owned by the driver and
/// resolve interceptor.
pub fn lowerForConn(self: *Node, peer_handle: PeerHandle, reference: model.Reference) engine.LoweringError!model.Reference {
    if (routeIdOf(reference) == null) return reference;
    const found = route(self, reference) orelse return error.RouteNotLowerable;
    if (found.peer_handle != peer_handle) return error.RouteNotLowerable;
    return found.reference;
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
    const found = route(self, .{ .routed = .{ .id = route_id } }) orelse return null;
    if (Internal.peerAt(self, found.peer_handle) == null) return null;
    return .{ .peer_handle = found.peer_handle, .target = found.reference };
}

/// Retire a route once its real wire import generation is no longer live.
/// Partial releases leave the route intact while the session row exists. Once
/// it is gone, retaining the route would let an old capability address a newly
/// reused import position.
pub fn retireReleasedRoute(self: *Node, route_id: model.CapabilityRouteId) void {
    const kind: enum { redeemed, foreign } = if (self.redeemed.contains(route_id))
        .redeemed
    else if (self.foreign_imports.contains(route_id))
        .foreign
    else
        return;
    const route_row = switch (kind) {
        .redeemed => self.redeemed.get(route_id).?,
        .foreign => self.foreign_imports.get(route_id).?,
    };
    const home = Internal.peerAt(self, route_row.peer_handle) orelse return;
    const position = switch (route_row.reference) {
        .far => |far| far.import_position,
        else => return,
    };
    switch (kind) {
        .redeemed => {
            if (home.session_state.hasImport(position)) return;
            const removed = self.redeemed.fetchRemove(route_id).?;
            model.freeReference(self.allocator, removed.value.reference);
        },
        .foreign => {
            // A reused row may exist here. The generation, not presence,
            // decides whether this route still belongs to it.
            if (home.session_state.foreignRouteIdFor(position) == route_id) return;
            const removed = self.foreign_imports.fetchRemove(route_id).?;
            model.freeReference(self.allocator, removed.value.reference);
        },
    }
}

/// Consume a redeemed route when the Host lifts its real import incarnation.
/// This transfers identity authority to the Host; keeping the Node row would
/// leave a second stale-capable handle. Foreign routes remain session-owned.
pub fn consumeRedeemedRoute(self: *Node, route_id: model.CapabilityRouteId) bool {
    const removed = self.redeemed.fetchRemove(route_id) orelse return false;
    model.freeReference(self.allocator, removed.value.reference);
    return true;
}
