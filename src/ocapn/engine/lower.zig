//! Lowering explicit Node-local capability routes to their wire references at
//! the one outbound chokepoint (`Peer.send`), so `Reference.routed` never
//! reaches a codec (ADR-0069).
//!
//! A routed reference names a Node table row, not a position in any CapTP
//! session. Before encoding on its home session, the Node replaces it with the
//! real session-scoped reference. Rather than patch every place a reference is
//! emitted — a send target, forwarded target, resolution, or nested argument —
//! the peer walks each outbound message here. A route homed elsewhere has no
//! wire name on this connection and fails closed with `RouteNotLowerable`.
//!
//! Lowering is a plain POD substitution and adds no allocation. The walk runs
//! only after the node has minted its first route (`NodeServices.lowering_active`);
//! until then every send skips it for a single bool load, so a two-party peer
//! that never fetches a foreign capability pays nothing.

const model = @import("model");
const services_mod = @import("node_services.zig");
const NodeServices = services_mod.NodeServices;

/// A reference names a Node-local route whose home is not the connection it is
/// being emitted on, so it has no wire name here. Raised by the node's lowering
/// hook (`Node.lowerForConn`) and propagated out of the failed `Peer.send`.
/// Lower every reference an outbound `message` carries to its wire form on the
/// lowering's connection, in place. The message is owned by the caller (the peer
/// about to enqueue it), so the walk rewrites its references directly; the
/// `@constCast`s reach into that owned argument heap,
/// never into borrowed wire bytes. A `RouteNotLowerable` from any position aborts
/// the whole send and leaves the caller to free the message.
pub fn lowerMessage(services: NodeServices, message: *model.Message) services_mod.LoweringError!void {
    switch (message.*) {
        .deliver => |*deliver| {
            deliver.target = try services.lower(deliver.target);
            if (deliver.resolve_me_desc) |desc| deliver.resolve_me_desc = try services.lower(desc);
            try lowerArguments(services, deliver.args);
        },
        .resolve => |*resolve| try lowerResolution(services, &resolve.resolution),
        .listen => |*listen| {
            listen.target = try services.lower(listen.target);
            listen.listener = try services.lower(listen.listener);
        },
        .get => |*get| get.receiver = try services.lower(get.receiver),
        .index => |*index| index.receiver = try services.lower(index.receiver),
        .untag => |*untag| untag.receiver = try services.lower(untag.receiver),
        // No reference positions.
        .gc_export, .gc_answer, .start_session, .abort => {},
    }
}

/// Lower a bare owned resolution in place, the same walk `lowerMessage` runs on
/// a resolve's payload. `pub` for the one outbound path that bypasses `send`'s
/// chokepoint: a relayed resolution recorded by `Peer.applyRelayedResolution`
/// (ADR-0009), whose stored value later reaches the wire through the fire
/// carriers.
pub fn lowerResolution(services: NodeServices, resolution: *model.Resolution) services_mod.LoweringError!void {
    switch (resolution.*) {
        .fulfill => |*arg| try lowerArgument(services, arg),
        .@"break" => {},
    }
}

fn lowerArguments(services: NodeServices, args: []const model.Argument) services_mod.LoweringError!void {
    for (@constCast(args)) |*arg| try lowerArgument(services, arg);
}

fn lowerArgument(services: NodeServices, arg: *model.Argument) services_mod.LoweringError!void {
    switch (arg.*) {
        .reference => |reference| arg.* = .{ .reference = try services.lower(reference) },
        .list => |items| try lowerArguments(services, items),
        .set => |items| try lowerArguments(services, items),
        .tagged => |tagged| try lowerArguments(services, tagged.value),
        .@"struct" => |entries| for (@constCast(entries)) |*entry| try lowerArgument(services, &entry.value),
        // Handoff records carry their own typed certificate fields rather than
        // semantic `Reference` values; every other arm is POD or bytes.
        else => {},
    }
}
