//! Registered-peer ownership, liveness, export ranges, and Node services.

const std = @import("std");

const engine = @import("../../mod.zig");
const export_ranges = @import("../../export_ranges.zig");
const node_mod = @import("../../node.zig");
const gift_recipe = @import("../handoffs/gifts/recipe.zig");
const gift_tickets = @import("../handoffs/gifts/tickets.zig");
const routes = @import("routes.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

/// Who frees one registered peer after its Node membership ends.
pub const Ownership = enum {
    /// `registerPeer` allocated the peer; removal and Node teardown free it.
    node_owned,
    /// `registerPeerOver` adopted an embedder-owned peer and only unregisters it.
    borrowed,
};

/// One live peer plus its membership-owned lifecycle facts.
pub const Slot = struct {
    peer: *engine.Peer,
    /// Withdraws awaiting a resolve on this session. The count decides in O(1)
    /// whether a failed redeem was the last use of a redeem-only connection.
    pending_withdraw_count: u32 = 0,
    ownership: Ownership,
    /// Opened only to redeem a handoff and not yet selected by an application.
    provisional_exporter: bool = false,
};

/// Register one Node-owned, heap-pinned negotiating peer.
///
/// The embedder builds its live connection over `node.peer(id)`, whose address
/// remains stable for the membership lifetime. Negotiation options are applied
/// at construction, so the host never mutates session authority after the fact.
///
/// Export-range capacity and the range itself are acquired before membership
/// becomes visible. Every failure unwinds the peer and range, and the handle
/// only advances after the map row commits, so handles are never reused.
pub fn registerPeer(self: *Node, options: engine.Peer.NegotiatingOptions) !PeerHandle {
    if (self.next_peer_handle == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    const new_peer = try self.allocator.create(engine.Peer);
    new_peer.* = engine.Peer.initNegotiatingWith(self.allocator, options);
    errdefer {
        new_peer.node_services = null;
        new_peer.deinit();
        self.allocator.destroy(new_peer);
    }
    try export_ranges.applyExportRange(self, new_peer);
    errdefer export_ranges.recycleExportBase(self, new_peer.session_state.export_base);

    const handle: PeerHandle = .from(self.next_peer_handle);
    new_peer.node_services = services(self, handle);
    try self.peers.putNoClobber(self.allocator, handle, .{ .peer = new_peer, .ownership = .node_owned });
    self.next_peer_handle += 1;
    return handle;
}

/// Register an embedder-owned, stably pinned peer without taking ownership.
///
/// This is how a peer-owning completion loop joins Node routing without
/// surrendering its inline peer. The embedder must keep it alive until removal;
/// Node detaches services and membership but never frees the peer itself.
pub fn registerPeerOver(self: *Node, adopted: *engine.Peer) !PeerHandle {
    if (self.next_peer_handle == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
    try export_ranges.applyExportRange(self, adopted);
    errdefer export_ranges.recycleExportBase(self, adopted.session_state.export_base);
    const handle: PeerHandle = .from(self.next_peer_handle);
    adopted.node_services = services(self, handle);
    errdefer adopted.node_services = null;
    try self.peers.putNoClobber(self.allocator, handle, .{ .peer = adopted, .ownership = .borrowed });
    self.next_peer_handle += 1;
    return handle;
}

/// Remove one live peer and retire every Node fact that names its generation.
///
/// Cleanup remains allocation-free after membership disappears. Each child
/// authority owns its rows; this function fixes the ordering between them and
/// frees the peer only when the membership row says the Node owns it.
/// The monotonic handle remains burned, so a stale routed reference can only fail
/// closed and can never acquire a later session's meaning.
pub fn removePeer(self: *Node, peer_handle: PeerHandle) void {
    const live = self.peers.get(peer_handle) orelse return;
    // A recipient batch carries a reservation charged on this exact Peer.
    // Retire it while the Peer is still alive; exporter-side failures are
    // projected only after liveness disappears, so a retry cannot route back
    // through the closing exporter.
    Internal.retireInlinePassableRecipientBatchesForPeer(self, peer_handle);
    // Receiver-side dependencies must leave while the services back-pointer
    // is valid. This also makes an adopted peer safe to deinit later.
    live.peer.detachNodeServices();
    const removed = self.peers.fetchRemove(peer_handle) orelse return;
    // Mark only receivers that name this exact Gifter–Exporter session after
    // liveness disappears, so their retry observes closure.
    Internal.markGifterHandoffsChanged(self, peer_handle);
    // Give the range back before the peer goes, while it remains the only
    // record of the range this session held. Reclamation makes the slot bound
    // live sessions rather than all sessions over the Node's lifetime.
    export_ranges.recycleExportBase(self, removed.value.peer.session_state.export_base);
    if (removed.value.ownership == .node_owned) {
        removed.value.peer.deinit();
        self.allocator.destroy(removed.value.peer);
    }
    gift_recipe.removeForPeer(self, peer_handle);

    Internal.evictExporterCache(self, peer_handle);
    Internal.failWithdrawsForPeer(self, peer_handle);
    // Home-owned staged Passable work must fail while its foreign routes still
    // identify the exact projections and escrows that need retirement.
    Internal.failInlinePassableBatchesForHome(self, peer_handle);

    // A claimed gift whose recipient died has no settlement destination.
    gift_tickets.retireRecipient(self, peer_handle);

    routes.removeForPeer(self, &self.redeemed, peer_handle);
    routes.removeForPeer(self, &self.foreign_imports, peer_handle);
    // Proxies are last: their retirement may inspect route liveness, and no
    // later home fire may relay onto a peer or route generation now gone.
    Internal.sweepPromiseProxiesForPeer(self, peer_handle);
}

/// The live peer for `peer_handle`, or null after membership retirement. Presence
/// in the membership map is the sole liveness marker used by routing.
pub fn peer(self: *Node, peer_handle: PeerHandle) ?*engine.Peer {
    return peerAt(self, peer_handle);
}

pub fn peerAt(self: *Node, peer_handle: PeerHandle) ?*engine.Peer {
    const slot = self.peers.get(peer_handle) orelse return null;
    return slot.peer;
}

/// Bind this membership generation to the Node-owned cross-session services.
/// The lowering gate points at stable Node state, so a peer that never sees a
/// route skips the recursive outbound walk for one bool load.
pub fn services(self: *Node, peer_handle: PeerHandle) engine.NodeServices {
    return engine.NodeServices.bind(self, peer_handle, &self.route_lowering_active, .{
        .lower = routes.lowerForConn,
        .stage_outbound = Internal.stageOutbound,
        .staged_withdrawn = Internal.stagedWithdrawn,
        .provisional_closed = Internal.provisionalClosed,
        .local_object_projection = Node.localObjectProjection,
        .gifter_session_resolver = Node.gifterSessionResolver,
        .pending_withdraw_added = Internal.addHandoffWaiter,
        .pending_withdraw_removed = Internal.removeHandoffWaiter,
        .gift_deposited = Internal.markHandoffChanged,
        .session_closed = Internal.sessionClosed,
        .prepare_v1_emitted_handoff_count = Internal.prepareV1HandoffCount,
        .prepare_promise_shortening = Internal.prepareProxyPromiseShortening,
        .commit_promise_shortening = Internal.commitProxyPromiseShortening,
        .designator_scheme = Internal.designatorScheme,
    });
}
