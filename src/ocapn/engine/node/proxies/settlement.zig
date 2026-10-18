//! Promise-proxy settlement, terminal break, and peer-lifecycle retirement.

const std = @import("std");

const model = @import("model");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");
const topology = @import("topology.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

pub fn isHomeListener(self: *const Node, home_peer: PeerHandle, listener_export: u64) bool {
    return self.proxy_by_listener.contains(.{ .home = home_peer, .listener_export = listener_export });
}

/// Peek → materialize → consume a proxy home-listener fire. Miss path never
/// allocates. Hit path takes ownership of the materialized resolution and
/// never returns false after `toOwned`.
pub fn claimProjectedListenerFire(
    self: *Node,
    allocator: std.mem.Allocator,
    home_peer: PeerHandle,
    listener_export: u64,
    view_res: model.view.Resolution,
) !bool {
    if (!isHomeListener(self, home_peer, listener_export)) return false;
    const owned = try view_res.toOwned(allocator);
    const consumed = consumeProjectedListenerFire(self, home_peer, listener_export, owned);
    std.debug.assert(consumed);
    return true;
}

/// Settle every live recipient of a consumed proxy fire with the break
/// escrowed when that recipient was admitted. No allocation is permitted
/// here: after the home fire is consumed there is no event to retry.
fn breakRecipients(self: *Node, row: *topology.Proxy) void {
    for (row.recipients.items) |*recipient| breakRecipient(self, recipient);
}

/// Settle a recipient's projection with the break escrowed at admission.
/// The guaranteed settlement stores the break even under outbound pressure,
/// so no allocation and no later event is needed.
pub fn breakRecipient(self: *Node, recipient: *topology.Recipient) void {
    const reason = recipient.takeFailure();
    const recip = self.peer(recipient.peer) orelse {
        self.allocator.free(reason);
        actions.releaseProxyReservation(self);
        return;
    };
    recip.breakAnswerTargetGuaranteed(recipient.target, reason);
    actions.queueProxyFlush(self, recipient.peer);
}

/// Settle a recipient's projection with the fire's value. A refusal before
/// commit spends the escrowed terminal break instead; after commit, only the
/// now-unneeded escrow is released.
pub fn settleRecipient(self: *Node, recipient: *topology.Recipient, resolution: model.Resolution) void {
    const recip = self.peer(recipient.peer) orelse {
        model.freeResolution(self.allocator, resolution);
        topology.retireEscrow(self, recipient);
        return;
    };
    recip.settleAnswerTargetGuaranteed(recipient.target, resolution) catch |err| switch (err) {
        // The projection was collected, settled, or its session closed: nobody holds it.
        error.InvalidReference, error.UnexpectedMessage, error.SessionClosed => {
            topology.retireEscrow(self, recipient);
            return;
        },
        else => {
            recip.recordFailure(err);
            return breakRecipient(self, recipient);
        },
    };
    recipient.releaseFailure(self.allocator);
    actions.queueProxyFlush(self, recipient.peer);
}

/// One recipient of a consumed proxy-listener fire. Host identity projection
/// remains above Node. This handle exposes only recipient identity and one
/// ownership-taking settlement operation.
pub const RelayRecipient = struct {
    node: *Node,
    recipient: *topology.Recipient,

    pub fn peerHandle(self: *const RelayRecipient) PeerHandle {
        return self.recipient.peer;
    }

    /// Materialize `resolution` into the recipient allocator, then settle it
    /// directly or transfer it into the shared bounded Passable transaction.
    /// False means the reserved terminal break was already delivered, or the
    /// projection is gone and the fire was moot.
    pub fn adopt(self: *RelayRecipient, resolution: model.Resolution) bool {
        const recipient_peer = self.node.peer(self.recipient.peer) orelse {
            breakRecipient(self.node, self.recipient);
            return false;
        };
        const owned = model.materializeResolutionForStore(recipient_peer.allocator, resolution) catch {
            breakRecipient(self.node, self.recipient);
            return false;
        };
        const begun = recipient_peer.session_state.beginAnswerSettlement(self.recipient.target) catch |err| {
            model.freeResolution(recipient_peer.allocator, owned);
            switch (err) {
                // The projection was collected or settled: nobody holds it.
                error.InvalidReference, error.UnexpectedMessage => topology.retireEscrow(self.node, self.recipient),
                else => breakRecipient(self.node, self.recipient),
            }
            return false;
        };
        var payload: Internal.InlinePassableOutbound = .{ .answer_settlement = .{
            .target = begun.target,
            .payload = begun.payload,
            .resolution = owned,
        } };
        const inventory = recipient_peer.inventoryResolution(owned) catch {
            payload.deinit(&recipient_peer.session_state);
            breakRecipient(self.node, self.recipient);
            return false;
        };
        defer inventory.deinit(recipient_peer.allocator);
        const staged = Internal.stageInlinePassable(
            self.node,
            self.recipient.peer,
            &payload,
            inventory,
            .{ .inbound_answer = begun.target },
            &self.recipient.failure_reason,
        ) catch {
            payload.deinit(&recipient_peer.session_state);
            breakRecipient(self.node, self.recipient);
            return false;
        };
        if (staged) {
            // The batch took the escrow and owns the terminal, and its own
            // completion seat drives the recipient.
            std.debug.assert(self.recipient.failure_reason == null);
            actions.releaseProxyReservation(self.node);
            return true;
        }
        // No cross-session projection: the guaranteed settlement begins the
        // answer again on its own path.
        recipient_peer.session_state.releaseAnswerPayload(begun.payload);
        settleRecipient(self.node, self.recipient, owned);
        return true;
    }
};

/// Consume one proxy-listener fire after the Host has lifted its value.
pub fn projectListenerFire(
    self: *Node,
    home_peer: PeerHandle,
    listener_export: u64,
    context: anytype,
    comptime project: anytype,
) bool {
    const home_key = self.proxy_by_listener.get(.{
        .home = home_peer,
        .listener_export = listener_export,
    }) orelse return false;
    const row = self.promise_proxies.getPtr(home_key) orelse return false;
    for (row.recipients.items) |*recipient| {
        var relay: RelayRecipient = .{ .node = self, .recipient = recipient };
        project(context, &relay);
        if (recipient.failure_reason != null) breakRecipient(self, recipient);
    }
    topology.remove(self, home_key);
    return true;
}

/// Consume a proxy fire whose owning Host could not lift/project. Every
/// recipient already owns a terminal seat, so failure is correlated and
/// allocation-free rather than escaping as a host-wide step error.
pub fn breakListenerFire(self: *Node, home_peer: PeerHandle, listener_export: u64) bool {
    const home_key = self.proxy_by_listener.get(.{
        .home = home_peer,
        .listener_export = listener_export,
    }) orelse return false;
    const row = self.promise_proxies.getPtr(home_key) orelse return false;
    breakRecipients(self, row);
    topology.remove(self, home_key);
    return true;
}

/// Consume a complete resolution already expressed in Node identity.
pub fn consumeProjectedListenerFire(
    self: *Node,
    home_peer: PeerHandle,
    listener_export: u64,
    resolution: model.Resolution,
) bool {
    if (!isHomeListener(self, home_peer, listener_export)) return false;
    defer model.freeResolution(self.allocator, resolution);
    const Projection = struct {
        resolution: model.Resolution,

        fn recipient(context: *@This(), relay: *RelayRecipient) void {
            _ = relay.adopt(context.resolution);
        }
    };
    var projection: Projection = .{ .resolution = resolution };
    return projectListenerFire(
        self,
        home_peer,
        listener_export,
        &projection,
        Projection.recipient,
    );
}

/// Logical session close is the proxy authority boundary. A home closure
/// spends every recipient's terminal escrow before removing the topology. A
/// recipient closure retires only that recipient and its reserved action.
/// `removePeer` repeats this operation safely if an embedder skips close.
pub fn sweepForPeer(self: *Node, peer_handle: PeerHandle) void {
    var it = self.promise_proxies.iterator();
    while (it.next()) |entry| {
        var remove = entry.key_ptr.home == peer_handle;
        if (remove) {
            breakRecipients(self, entry.value_ptr);
        } else {
            var i: usize = 0;
            while (i < entry.value_ptr.recipients.items.len) {
                if (entry.value_ptr.recipients.items[i].peer != peer_handle) {
                    i += 1;
                    continue;
                }
                var retired = entry.value_ptr.recipients.swapRemove(i);
                topology.retireEscrow(self, &retired);
            }
            remove = entry.value_ptr.recipients.items.len == 0;
        }
        if (!remove) continue;

        const key = entry.key_ptr.*;
        var proxy = entry.value_ptr.*;
        self.promise_proxies.removeByPtr(entry.key_ptr);
        topology.deinitProxy(self, key, &proxy);
    }
}

/// Node destruction breaks committed proxies while borrowed peers and their
/// stores are still live, then retires the topology. Node-owned peers are
/// subsequently destroyed. Borrowed peers retain the terminal settlement.
pub fn deinitAll(self: *Node) void {
    while (self.promise_proxies.count() != 0) {
        var it = self.promise_proxies.iterator();
        const entry = it.next().?;
        const key = entry.key_ptr.*;
        var proxy = entry.value_ptr.*;
        breakRecipients(self, entry.value_ptr);
        self.promise_proxies.removeByPtr(entry.key_ptr);
        topology.deinitProxy(self, key, &proxy);
    }
    actions.assertNoProxyReservations(self);
    self.promise_proxies.deinit(self.allocator);
    self.proxy_by_listener.deinit(self.allocator);
    self.proxy_by_source.deinit(self.allocator);
}
