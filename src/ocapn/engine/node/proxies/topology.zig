//! Promise-proxy topology and shortening across live Node peers.
//!
//! One stable home row owns one home listener and every recipient escrow.
//! Source and listener indexes are aliases into that row, never independent
//! lifecycle authorities.

const std = @import("std");

const model = @import("model");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

pub const max_recipients: usize = 1_024;

/// One recipient for an introducing-session foreign-promise proxy (ADR-0009).
/// `row_id` is stamped at enroll so a GC/re-register between enroll and fire
/// cannot satisfy a stale relay (same contract as `recordRelayedResolution`).
pub const Recipient = struct {
    peer: PeerHandle,
    import_pos: u64,
    row_id: u64,
    /// Admission escrow for the one terminal break this recipient is owed.
    /// Once the home fire is consumed, allocator pressure must not leave the
    /// relayed promise pending forever.
    failure_reason: ?[]u8,

    pub fn releaseFailure(self: *Recipient, allocator: std.mem.Allocator) void {
        if (self.failure_reason) |reason| allocator.free(reason);
        self.failure_reason = null;
    }

    pub fn takeFailure(self: *Recipient) []u8 {
        const reason = self.failure_reason orelse unreachable;
        self.failure_reason = null;
        return reason;
    }
};

/// Composite identity for a home-session wire import that is being proxied.
pub const HomeKey = struct {
    home: PeerHandle,
    wire_pos: u64,
};

/// Home-session listener export that receives the home `op:listen` fire.
pub const ListenerKey = struct {
    home: PeerHandle,
    listener_export: u64,
};

/// Armed introducing-session proxy: **one** home `op:listen`, one or more
/// recipient third-party import rows. On fire the Host lifts once; each
/// recipient then materializes its independently lowered tree through Node's
/// bounded Passable transaction. Never N home listens.
pub const Proxy = struct {
    listener_export: u64,
    current_wire_pos: u64,
    recipients: std.ArrayListUnmanaged(Recipient) = .empty,

    pub fn deinit(self: *Proxy, allocator: std.mem.Allocator) void {
        for (self.recipients.items) |*recipient| recipient.releaseFailure(allocator);
        self.recipients.deinit(allocator);
    }
};

pub const Proxies = std.AutoHashMapUnmanaged(HomeKey, Proxy);
pub const ByListener = std.AutoHashMapUnmanaged(ListenerKey, HomeKey);
pub const BySource = std.AutoHashMapUnmanaged(HomeKey, HomeKey);

pub fn prepareShortening(
    self: *Node,
    home: PeerHandle,
    source: u64,
    target: u64,
    _: u64,
    _: bool,
) !void {
    const source_root = self.proxy_by_source.get(.{ .home = home, .wire_pos = source }) orelse
        return error.UnexpectedMessage;
    const source_proxy = self.promise_proxies.get(source_root) orelse return error.UnexpectedMessage;
    const target_root = self.proxy_by_source.get(.{ .home = home, .wire_pos = target }) orelse return;
    if (std.meta.eql(target_root, source_root)) return;
    const target_proxy = self.promise_proxies.getPtr(target_root) orelse return error.UnexpectedMessage;
    if (target_proxy.recipients.items.len + source_proxy.recipients.items.len > max_recipients)
        return error.ProxyRecipientCapExceeded;
    try target_proxy.recipients.ensureUnusedCapacity(self.allocator, source_proxy.recipients.items.len);
}

pub fn commitShortening(
    self: *Node,
    home: PeerHandle,
    source: u64,
    target: u64,
    target_listener: u64,
    converges: bool,
) void {
    const source_key: HomeKey = .{ .home = home, .wire_pos = source };
    const target_key: HomeKey = .{ .home = home, .wire_pos = target };
    const source_root = self.proxy_by_source.get(source_key) orelse unreachable;
    if (self.proxy_by_source.get(target_key)) |target_root| {
        if (std.meta.eql(target_root, source_root)) return;
        const removed = self.promise_proxies.fetchRemove(source_root).?;
        var source_proxy = removed.value;
        const target_proxy = self.promise_proxies.getPtr(target_root).?;
        target_proxy.recipients.appendSliceAssumeCapacity(source_proxy.recipients.items);
        // Recipient rows own their terminal escrows. The append above is a
        // move into capacity reserved by `prepareShortening`; leave only the
        // source list's backing allocation for deinit.
        source_proxy.recipients.items.len = 0;
        std.debug.assert(self.proxy_by_source.remove(source_key));
        std.debug.assert(self.proxy_by_listener.remove(.{
            .home = home,
            .listener_export = source_proxy.listener_export,
        }));
        source_proxy.deinit(self.allocator);
        return;
    }

    std.debug.assert(self.proxy_by_source.remove(source_key));
    self.proxy_by_source.putAssumeCapacity(target_key, source_root);
    const proxy = self.promise_proxies.getPtr(source_root).?;
    proxy.current_wire_pos = target;
    if (converges and proxy.listener_export != target_listener) {
        std.debug.assert(self.proxy_by_listener.remove(.{
            .home = home,
            .listener_export = proxy.listener_export,
        }));
        self.proxy_by_listener.putAssumeCapacity(.{
            .home = home,
            .listener_export = target_listener,
        }, source_root);
        proxy.listener_export = target_listener;
    }
}

pub fn remove(self: *Node, key: HomeKey) void {
    if (self.promise_proxies.fetchRemove(key)) |kv| {
        var proxy = kv.value;
        deinitProxy(self, key, &proxy);
    }
}

pub fn deinitProxy(self: *Node, key: HomeKey, proxy: *Proxy) void {
    if (self.peer(key.home)) |home_peer| {
        const listener = model.ExportPosition.from(proxy.listener_export);
        if (home_peer.session_state.captp_version == .next) {
            if (home_peer.session_state.shorteningIncarnationForImport(.from(proxy.current_wire_pos))) |source|
                home_peer.session_state.detachPromiseSettlingNodeConsumer(source, listener);
        }
        home_peer.session_state.retireNodeSettlingResolver(listener);
    }
    const listener_key: ListenerKey = .{
        .home = key.home,
        .listener_export = proxy.listener_export,
    };
    std.debug.assert(self.proxy_by_listener.remove(listener_key));
    std.debug.assert(self.proxy_by_source.remove(.{
        .home = key.home,
        .wire_pos = proxy.current_wire_pos,
    }));
    deinitStorage(self, proxy);
}

pub fn deinitStorage(self: *Node, proxy: *Proxy) void {
    for (proxy.recipients.items) |*recipient| {
        if (recipient.failure_reason != null) actions.releaseProxyReservation(self);
    }
    proxy.deinit(self.allocator);
}
