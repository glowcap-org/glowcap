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
//! when the node has enrolled at least one foreign token (`Lowering.active`);
//! until then every send skips it for a single bool load, so a two-party peer
//! that never fetches a foreign capability pays nothing.

const std = @import("std");
const model = @import("model");
const engine = @import("mod.zig");

/// A reference names a node-local token whose home is not the connection it is
/// being emitted on, so it has no wire name here. Raised by the node's lowering
/// hook (`Node.lowerForConn`) and propagated out of the failed `Peer.send`.
pub const LoweringError = error{TokenNotLiftable};

/// Installed on a node-registered `Peer`: the hook that lowers one reference to
/// its wire form on the peer's connection. `ctx` and `peer_id` bind the call to
/// the node and the connection; `active` gates the walk so a node that has never
/// enrolled a foreign token pays only a bool load per send.
pub const Lowering = struct {
    ctx: *anyopaque,
    peer_id: engine.PeerId,
    active: *const bool,
    lower_fn: *const fn (ctx: *anyopaque, peer_id: engine.PeerId, reference: model.Reference) LoweringError!model.Reference,

    fn lower(self: Lowering, reference: model.Reference) LoweringError!model.Reference {
        return self.lower_fn(self.ctx, self.peer_id, reference);
    }
};

/// Lower every reference an outbound `message` carries to its wire form on the
/// lowering's connection, in place. The message is owned by the caller (the peer
/// about to enqueue it), so the walk rewrites its far references — plain POD
/// values — directly; the `@constCast`s reach into that owned argument heap,
/// never into borrowed wire bytes. A `TokenNotLiftable` from any position aborts
/// the whole send and leaves the caller to free the message.
pub fn lowerMessage(lowering: Lowering, message: *model.Message) LoweringError!void {
    switch (message.*) {
        .deliver => |*deliver| {
            deliver.target = try lowering.lower(deliver.target);
            if (deliver.resolve_me_desc) |desc| deliver.resolve_me_desc = try lowering.lower(desc);
            try lowerArguments(lowering, deliver.args);
        },
        .resolve => |*resolve| try lowerResolution(lowering, &resolve.resolution),
        .listen => |*listen| {
            listen.target = try lowering.lower(listen.target);
            listen.listener = try lowering.lower(listen.listener);
        },
        .get => |*get| get.receiver = try lowering.lower(get.receiver),
        .index => |*index| index.receiver = try lowering.lower(index.receiver),
        .untag => |*untag| untag.receiver = try lowering.lower(untag.receiver),
        // No reference positions (gc, start-session, abort), or references the
        // node minted from wire data rather than a token (a handoff's gifted
        // reference is resolved through `Node.provideGiftId` before origination).
        .gc_export, .gc_answer, .handoff, .start_session, .abort => {},
    }
}

/// Lower a bare owned resolution in place, the same walk `lowerMessage` runs on
/// a resolve's payload. `pub` for the one outbound path that bypasses `send`'s
/// chokepoint: a relayed resolution recorded by `Peer.applyRelayedResolution`
/// (ADR-0009), whose stored value later reaches the wire through the fire
/// carriers.
pub fn lowerResolution(lowering: Lowering, resolution: *model.Resolution) LoweringError!void {
    switch (resolution.*) {
        .fulfill => |*arg| try lowerArgument(lowering, arg),
        .@"break" => {},
    }
}

fn lowerArguments(lowering: Lowering, args: []const model.Argument) LoweringError!void {
    for (@constCast(args)) |*arg| try lowerArgument(lowering, arg);
}

fn lowerArgument(lowering: Lowering, arg: *model.Argument) LoweringError!void {
    switch (arg.*) {
        .reference => |reference| arg.* = .{ .reference = try lowering.lower(reference) },
        .list => |items| try lowerArguments(lowering, items),
        .set => |items| try lowerArguments(lowering, items),
        .tagged => |tagged| try lowerArguments(lowering, tagged.value),
        .@"struct" => |entries| for (@constCast(entries)) |*entry| try lowerArgument(lowering, &entry.value),
        // A handoff argument's references were minted by the node's handoff
        // machinery from wire data, never a token; every other arm is POD or bytes.
        else => {},
    }
}
