//! The per-peer composition link a `Node` installs.
//!
//! A Peer owns one CapTP session. The link names the Node the Peer joined and
//! the handle the Node knows it by, so the Peer reaches the Node's
//! cross-session facilities: outbound capability-route lowering, Host-local
//! object projection, live gifter lookup, authority-neutral parked-withdraw
//! scheduling, and V1 compatibility count issuance. The Node is the one
//! implementation, so each facility is a direct call.

const std = @import("std");
const codec = @import("codec");
const model = @import("model");
const session = @import("session");
const bootstrap = @import("bootstrap.zig");
const passable = @import("node/passable.zig");
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("peer_handle.zig").PeerHandle;

pub const LoweringError = error{RouteNotLowerable};
/// A staged batch encodes its carrier when it finishes (ADR-0064), so the
/// encoder's refusals join the staging set.
pub const OutboundStagingError = std.mem.Allocator.Error || session.Error || codec.dispatch.EncodeError || error{
    RouteNotLowerable,
    QueueCapExceeded,
    CapabilitySpaceExhausted,
    OutboundBackpressure,
    MalformedView,
    ExportRangeExhausted,
    ProxyRecipientCapExceeded,
    PeerGone,
    SessionNotOpen,
};
pub const HandoffCountError = error{HandoffCountExhausted};
pub const PromiseShorteningError = std.mem.Allocator.Error || error{
    UnexpectedMessage,
    ProxyRecipientCapExceeded,
};

/// Scheduler-only identity for one gift dependency. The BLAKE3 tag keeps
/// partner-chosen gift ids out of the Node's coordination tables while the
/// gifter PeerHandle preserves session scope. This is never capability authority:
/// the exact signed give and exact registry key are checked again at withdraw,
/// so a digest collision can only cause an extra bounded wake.
pub const HandoffDependency = struct {
    gifter: PeerHandle,
    gift_tag: [16]u8,

    pub fn init(gifter: PeerHandle, gift_id: []const u8) HandoffDependency {
        var gift_tag: [16]u8 = undefined;
        std.crypto.hash.Blake3.hash(gift_id, &gift_tag, .{});
        return .{ .gifter = gifter, .gift_tag = gift_tag };
    }
};

/// How a provisional window closed: its committed sends are kept, or
/// retracted and withdrawn newest first.
pub const ProvisionalClose = enum { keep, retract };

pub const NodeServices = struct {
    node: *Node,
    peer_handle: PeerHandle,

    /// Node-wide gate for the outbound token walk only: set once the node
    /// mints its first capability route (ADR-0026), so a peer that never sees
    /// a route skips the recursive walk for one bool load.
    pub fn loweringActive(self: NodeServices) bool {
        return self.node.route_lowering_active;
    }

    pub fn lower(self: NodeServices, reference: model.Reference) LoweringError!model.Reference {
        return Node.lowerForConn(self.node, self.peer_handle, reference);
    }

    /// Transfer an owned semantic payload into Node staging when one of its
    /// Passable values needs cross-session projection. `true` means the Node
    /// adopted the complete payload. `false` leaves it with the caller.
    pub fn stageOutbound(self: NodeServices, outbound: *passable.Outbound, inventory: session.Inventory) OutboundStagingError!bool {
        return Internal.stageOutbound(self.node, self.peer_handle, outbound, inventory);
    }

    /// A retracted provisional window removed the row of a carrier the Node
    /// is still staging (ADR-0058). The Node fails that batch.
    pub fn stagedWithdrawn(self: NodeServices, batch: passable.BatchId) void {
        Internal.stagedWithdrawn(self.node, self.peer_handle, batch);
    }

    /// The Peer's provisional window closed (ADR-0058), after the Peer kept
    /// or retracted its own rows. The Node keeps or withdraws what the
    /// window's sends committed beyond them.
    pub fn provisionalClosed(self: NodeServices, outcome: ProvisionalClose) void {
        Internal.provisionalClosed(self.node, self.peer_handle, outcome);
    }

    pub fn localObjectProjection(self: NodeServices) ?bootstrap.gifts.LocalObjectProjection {
        return self.node.localObjectProjection();
    }

    pub fn gifterSessionResolver(self: NodeServices) ?bootstrap.gifts.GifterSessionResolver {
        return self.node.gifterSessionResolver();
    }

    pub fn pendingWithdrawAdded(self: NodeServices, dependency: HandoffDependency) std.mem.Allocator.Error!void {
        try Internal.addHandoffWaiter(self.node, self.peer_handle, dependency);
    }

    pub fn pendingWithdrawRemoved(self: NodeServices, dependency: HandoffDependency) void {
        Internal.removeHandoffWaiter(self.node, self.peer_handle, dependency);
    }

    pub fn giftDeposited(self: NodeServices, gift_id: []const u8) void {
        Internal.markHandoffChanged(self.node, HandoffDependency.init(self.peer_handle, gift_id));
    }

    pub fn sessionClosed(self: NodeServices) void {
        Internal.sessionClosed(self.node, self.peer_handle);
    }

    /// An inbound answer a Host capability promise subscribes to has settled
    /// (ADR-0068). Publishes on the seat the subscription promised.
    pub fn answerSettled(self: NodeServices, promise: u64) void {
        self.node.publishPromiseSettled(promise);
    }

    pub fn prepareV1EmittedHandoffCount(self: NodeServices) HandoffCountError!bootstrap.gifts.PreparedHandoffCount {
        return Internal.prepareV1HandoffCount(self.node);
    }

    pub fn preparePromiseShortening(self: NodeServices, source: u64, target: u64) PromiseShorteningError!void {
        return Internal.prepareProxyPromiseShortening(self.node, self.peer_handle, source, target);
    }

    pub fn commitPromiseShortening(self: NodeServices, source: u64, target: u64, target_listener: u64, converges: bool) void {
        Internal.commitProxyPromiseShortening(self.node, self.peer_handle, source, target, target_listener, converges);
    }

    pub fn designatorScheme(self: NodeServices, transport: []const u8) ?model.transport.DesignatorScheme {
        return Internal.designatorScheme(self.node, transport);
    }
};
