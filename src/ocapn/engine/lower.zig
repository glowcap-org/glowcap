//! Lowering node-local foreign-import tokens to their wire reference at the one
//! outbound chokepoint (`Peer.send`), so a synthetic token never reaches the
//! wire in any position (ADR-0069).
//!
//! A `Node` hands the application a synthetic far token for a redeemed handoff
//! capability or a fetched foreign import, drawn from a reserved id range above
//! any wire import position. That token is a node-local name: it means something
//! only inside the node's routing tables, and it must be swapped for the real
//! wire reference before it is encoded onto the connection it is homed on. Rather
//! than patch every place a reference is emitted — a send target, a forwarded
//! target, a resolution, an argument — the peer lowers every reference in an
//! outbound message here, in the one place all outbound messages funnel through.
//! A token whose home is another connection has no wire name here and fails
//! closed with `TokenNotLiftable`, so a routing bug becomes a loud error instead
//! of a synthetic id on the wire.
//!
//! Lowering is a plain value substitution. A far reference owns no heap, so a
//! token becomes its wire far in place with no allocation. The walk runs only
//! when the node has enrolled at least one foreign token
//! (`NodeServices.lowering_active`);
//! until then every send skips it for a single bool load, so a two-party peer
//! that never fetches a foreign capability pays nothing.

const model = @import("model");
const services_mod = @import("node_services.zig");
const NodeServices = services_mod.NodeServices;

/// A reference names a node-local token whose home is not the connection it is
/// being emitted on, so it has no wire name here. Raised by the node's lowering
/// hook (`Node.lowerForConn`) and propagated out of the failed `Peer.send`.
/// Lower every reference an outbound `message` carries to its wire form on the
/// lowering's connection, in place. The message is owned by the caller (the peer
/// about to enqueue it), so the walk rewrites its far references — plain POD
/// values — directly; the `@constCast`s reach into that owned argument heap,
/// never into borrowed wire bytes. A `TokenNotLiftable` from any position aborts
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
        // A handoff argument's references were minted by the node's handoff
        // machinery from wire data, never a token; every other arm is POD or bytes.
        else => {},
    }
}
