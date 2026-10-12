//! Promise-proxy settlement, terminal break, and peer-lifecycle retirement.

const std = @import("std");

const model = @import("model");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");
const topology = @import("topology.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

const RelayedSlot = struct { import_pos: u64, row_id: u64 };

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
    std.debug.assert(consumeProjectedListenerFire(
        self,
        home_peer,
        listener_export,
        owned,
    ));
    return true;
}

/// Settle every live recipient of a consumed proxy fire with the break
/// escrowed when that recipient was admitted. No allocation is permitted
/// here: after the home fire is consumed there is no event to retry.
fn breakRecipients(self: *Node, row: *topology.Proxy) void {
    for (row.recipients.items) |*recipient| breakRecipient(self, recipient);
}

fn breakRelayedOwned(self: *Node, peer_handle: PeerHandle, slot: RelayedSlot, reason: []u8) void {
    const recip = self.peer(peer_handle) orelse {
        self.allocator.free(reason);
        actions.releaseProxyReservation(self);
        return;
    };
    // `applyRelayedResolution` consumes the resolution on every outcome,
    // including an error after the store commits. Freeing it here would
    // double-free that stored settlement.
    recip.applyRelayedResolutionGuaranteed(
        model.ImportPosition.from(slot.import_pos),
        slot.row_id,
        .{ .@"break" = .{ .message = reason } },
    ) catch |err| recip.emitFailure(err);
    actions.queueProxyFlush(self, peer_handle);
}

pub fn breakRecipient(self: *Node, recipient: *topology.Recipient) void {
    breakRelayedOwned(
        self,
        recipient.peer,
        .{ .import_pos = recipient.import_pos, .row_id = recipient.row_id },
        recipient.takeFailure(),
    );
}

/// Move one resolution into a recipient store. If validation or storage
/// refuses it before commit, use the already-reserved terminal break. After
/// commit, only release the now-unneeded escrow.
pub fn settleRecipient(self: *Node, recipient: *topology.Recipient, resolution: model.Resolution) void {
    const recip = self.peer(recipient.peer) orelse {
        model.freeResolution(self.allocator, resolution);
        recipient.releaseFailure(self.allocator);
        actions.releaseProxyReservation(self);
        return;
    };
    recip.applyRelayedResolutionGuaranteed(
        model.ImportPosition.from(recipient.import_pos),
        recipient.row_id,
        resolution,
    ) catch |err| recip.recordFailure(err);
    if (recip.session_state.importedPromiseResolution(.from(recipient.import_pos)) != null)
        recipient.releaseFailure(self.allocator)
    else
        return breakRecipient(self, recipient);
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
    /// False means the reserved terminal break was already delivered.
    pub fn adopt(self: *RelayRecipient, resolution: model.Resolution) bool {
        const recipient_peer = self.node.peer(self.recipient.peer) orelse {
            breakRecipient(self.node, self.recipient);
            return false;
        };
        const owned = model.materializeResolutionForStore(recipient_peer.allocator, resolution) catch {
            breakRecipient(self.node, self.recipient);
            return false;
        };
        var payload: Internal.InlinePassablePayload = .{ .relayed_resolution = owned };
        var destination: Internal.InlinePassableDestination = .{ .relayed = self.recipient.* };
        self.recipient.failure_reason = null;
        const staged = Internal.stageInlinePassable(
            self.node,
            self.recipient.peer,
            &payload,
            &destination,
            null,
        ) catch {
            self.recipient.* = destination.relayed;
            payload.deinit(recipient_peer.allocator, &recipient_peer.session_state);
            breakRecipient(self.node, self.recipient);
            return false;
        };
        if (staged) return true;

        self.recipient.* = destination.relayed;
        settleRecipient(self.node, self.recipient, payload.relayed_resolution);
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
                if (entry.value_ptr.recipients.items[i].peer == peer_handle) {
                    if (entry.value_ptr.recipients.items[i].failure_reason != null)
                        actions.releaseProxyReservation(self);
                    entry.value_ptr.recipients.items[i].releaseFailure(self.allocator);
                    entry.value_ptr.recipients.items[i] = entry.value_ptr.recipients.items[entry.value_ptr.recipients.items.len - 1];
                    entry.value_ptr.recipients.items.len -= 1;
                } else {
                    i += 1;
                }
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
