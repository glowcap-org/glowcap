//! Lowering explicit Node-local capability routes to their wire references at
//! the one outbound chokepoint (`Peer.send`), so `Reference.routed` never
//! reaches a codec (ADR-0069).
//!
//! A routed reference names a Node table row, not a position in any CapTP
//! session. Before encoding on its home session, the Node replaces it with the
//! real session-scoped reference. Rather than patch every place a reference is
//! emitted, a send target, forwarded target, resolution, or nested argument,
//! the peer walks each outbound message here. A route homed elsewhere has no
//! wire name on this connection and fails closed with `RouteNotLowerable`.
//!
//! Lowering is a plain POD substitution and adds no allocation. The walk runs
//! only after the node has minted its first route (`NodeServices.loweringActive`).
//! Until then every send skips it for a single bool load, so a two-party peer
//! that never fetches a foreign capability pays nothing.

const model = @import("model");
const session = @import("session");
const services_mod = @import("node_services.zig");
const NodeServices = services_mod.NodeServices;

/// Lower every reference an outbound `message` carries to its wire form on the
/// lowering's connection, in place. The message is owned by the caller (the
/// peer about to enqueue it), so the pass rewrites its references directly
/// through the slots its inventory lists. A `RouteNotLowerable` from any
/// position aborts the whole send and leaves the caller to free the message.
pub fn lowerMessage(services: NodeServices, message: *model.Message, inventory: session.Inventory) services_mod.LoweringError!void {
    return session.inventory.mapMessageReferences(message, inventory, services, NodeServices.lower);
}

/// Lower a bare owned resolution in place, the same pass `lowerMessage` runs
/// on a resolve's payload. `pub` for the outbound path that bypasses `send`'s
/// chokepoint: an answer settlement, whose stored value later reaches the
/// wire through the fire carriers.
pub fn lowerResolution(services: NodeServices, resolution: *model.Resolution, inventory: session.Inventory) services_mod.LoweringError!void {
    return session.inventory.mapResolutionReferences(resolution, inventory, services, NodeServices.lower);
}
