//! Atomic home-listener and recipient admission for promise proxies.

const std = @import("std");

const model = @import("model");
const session_mod = @import("session");
const engine = @import("../../mod.zig");
const actions = @import("../actions.zig");
const node_mod = @import("../../node.zig");
const passable = @import("../passable.zig");
const topology = @import("topology.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

const failure_reason = "relayed promise could not be settled";

const PreparedHome = struct {
    key: topology.HomeKey,
    listener_export: model.ExportPosition,
    current_wire_pos: u64,
    message: model.Message,
    reservation: engine.Peer.PendingReservation,
    proxy: topology.Proxy,
    committed: bool = false,

    fn abandon(self: *PreparedHome, node: *Node) void {
        if (self.committed) return;
        if (node.peer(self.key.home)) |home| {
            home.cancelPendingReservation(self.reservation);
            releaseHomeListener(home, self.listener_export, self.current_wire_pos);
        }
        self.proxy.deinit(node.allocator);
        self.* = undefined;
    }

    fn commit(self: *PreparedHome, node: *Node, provisional: bool) void {
        self.proxy.provisional = provisional;
        // `prepare` found the home peer in this dispatch; only `abandon` may
        // run after it is gone.
        const home = node.peer(self.key.home) orelse unreachable;
        home.session_state.recordPreparedSend(self.message);
        home.pushPendingAssume(self.reservation, .{ .message = self.message });
        const listener_key: topology.ListenerKey = .{
            .home = self.key.home,
            .listener_export = self.listener_export.int(),
        };
        node.proxy_by_listener.putAssumeCapacity(listener_key, self.key);
        node.promise_proxies.putAssumeCapacity(self.key, self.proxy);
        node.proxy_by_source.putAssumeCapacity(.{
            .home = self.key.home,
            .wire_pos = self.current_wire_pos,
        }, self.key);
        actions.pushReserved(node, .{ .flush = self.key.home });
        self.committed = true;
    }
};

const Group = struct {
    count: usize = 0,
    prepared_home: ?PreparedHome = null,
};

const PreparedRecipient = struct {
    home_key: topology.HomeKey,
    peer: PeerHandle,
    projection: session_mod.Session.LocalPromiseProjection,
    failure_reason: []u8,
    committed: bool = false,

    fn abandon(self: *PreparedRecipient, node: *Node) void {
        if (self.committed) return;
        if (node.peer(self.peer)) |recipient|
            recipient.session_state.abandonLocalPromiseProjection(self.projection.export_position);
        node.allocator.free(self.failure_reason);
        self.* = undefined;
    }

    fn commit(self: *PreparedRecipient, node: *Node) void {
        // `Prepared.commit` commits the home before its recipients.
        const proxy = node.promise_proxies.getPtr(self.home_key) orelse unreachable;
        proxy.recipients.appendAssumeCapacity(.{
            .peer = self.peer,
            .export_position = self.projection.export_position,
            .target = self.projection.answer_target,
            .failure_reason = self.failure_reason,
        });
        self.committed = true;
    }
};

pub const Prepared = struct {
    /// Keyed like `Node.promise_proxies`, whose rows these become.
    groups: topology.Groups(Group),
    recipients: std.ArrayListUnmanaged(PreparedRecipient) = .empty,
    committed: bool = false,

    pub fn deinit(self: *Prepared, node: *Node) void {
        if (!self.committed) {
            for (self.recipients.items) |*recipient| recipient.abandon(node);
            var groups = self.groups.valueIterator();
            while (groups.next()) |group| if (group.prepared_home) |*home|
                home.abandon(node);
        }
        self.recipients.deinit(node.allocator);
        self.groups.deinit(node.allocator);
        self.* = undefined;
    }

    pub fn commit(self: *Prepared, node: *Node) void {
        self.commitAs(node, false);
    }

    /// Commit for a send inside an open provisional window (ADR-0058), and
    /// append one receipt per recipient so the window's outcome can keep or
    /// withdraw it. `receipts` has room for every recipient.
    pub fn commitProvisional(
        self: *Prepared,
        node: *Node,
        receipts: *std.ArrayListUnmanaged(Receipt),
    ) void {
        self.commitAs(node, true);
        for (self.recipients.items) |recipient| receipts.appendAssumeCapacity(.{
            .home_key = recipient.home_key,
            .peer = recipient.peer,
            .export_position = recipient.projection.export_position,
            .target = recipient.projection.answer_target,
        });
    }

    fn commitAs(self: *Prepared, node: *Node, provisional: bool) void {
        var groups = self.groups.valueIterator();
        while (groups.next()) |group| if (group.prepared_home) |*home|
            home.commit(node, provisional);
        for (self.recipients.items) |*recipient| recipient.commit(node);
        actions.commitProxyReservations(node, self.recipients.items.len);
        self.committed = true;
    }
};

/// One recipient a provisional send added to a promise proxy.
pub const Receipt = struct {
    home_key: topology.HomeKey,
    peer: PeerHandle,
    export_position: model.ExportPosition,
    target: session_mod.AnswerTarget,
};

/// The window that made the send committed: the recipient stays, and so does
/// a home that send created.
pub fn keep(self: *Node, receipt: Receipt) void {
    const proxy = self.promise_proxies.getPtr(receipt.home_key) orelse return;
    proxy.provisional = false;
}

/// The window that made the send was retracted. Its carrier is already gone
/// from the recipient Peer, which released the carrier's export retain, so
/// only the rows the commit created remain: the recipient's promise
/// projection, unless that release already collected it, its proxy entry,
/// and, when the window created the proxy and no recipient is left, the home
/// listener and its queued listen.
pub fn withdraw(self: *Node, receipt: Receipt) void {
    const proxy = self.promise_proxies.getPtr(receipt.home_key) orelse unreachable;
    const index = for (proxy.recipients.items, 0..) |recipient, i| {
        if (recipient.peer == receipt.peer and std.meta.eql(recipient.target, receipt.target))
            break i;
    } else unreachable;
    var removed = proxy.recipients.orderedRemove(index);
    topology.retireEscrow(self, &removed);
    // A settled projection belongs to its settlement: the carrier drain or
    // the partner's release collects it. Only the pending projection this
    // receipt admitted, still under the admitted stamp, is abandoned here.
    if (self.peer(receipt.peer)) |recipient| {
        const state = &recipient.session_state;
        if (state.answerTargetNamed(receipt.target.name)) |live| {
            if (std.meta.eql(live, receipt.target) and state.peekResolutionNamed(receipt.target.name) == null)
                state.abandonLocalPromiseProjection(receipt.export_position);
        }
    }
    if (!proxy.provisional or proxy.recipients.items.len != 0) return;

    var withdrawn = (self.promise_proxies.fetchRemove(receipt.home_key) orelse unreachable).value;
    topology.unindexProxy(self, receipt.home_key.home, &withdrawn);
    if (self.peer(receipt.home_key.home)) |home| {
        const listener = model.ExportPosition.from(withdrawn.listener_export);
        home.withdrawQueuedListen(listener);
        releaseHomeListener(home, listener, withdrawn.current_wire_pos);
    }
    withdrawn.deinit(self.allocator);
}

/// Give back a home listener that never fired: its settling claim or
/// resolver row, then the export it rode on.
fn releaseHomeListener(home: *engine.Peer, listener: model.ExportPosition, current_wire_pos: u64) void {
    if (home.session_state.captp_version == .next) {
        home.session_state.abandonPromiseSettlingListener(.from(current_wire_pos));
    } else {
        std.debug.assert(home.session_state.removeOutboundResolver(listener));
    }
    home.session_state.releaseUnsharedExport(listener);
}

/// The proxy a promise's home keys it under: its current wire position, or
/// the source row an earlier admission already indexed. status-allow: event or source ordering
fn homeKeyOf(self: *Node, promise: passable.PromiseProjection) !topology.HomeKey {
    const home = self.peer(promise.home) orelse return error.PeerGone;
    const source_key: topology.HomeKey = .{
        .home = promise.home,
        .wire_pos = home.session_state.promiseWirePosition(promise.source.import_position).int(),
    };
    return self.proxy_by_source.get(source_key) orelse source_key;
}

fn prepareHome(
    self: *Node,
    key: topology.HomeKey,
    wire_far: model.FarRef,
    recipient_count: usize,
) !PreparedHome {
    const home = self.peer(key.home) orelse return error.PeerGone;
    if (!home.sessionIsOpen()) return error.SessionNotOpen;
    const next = home.session_state.captp_version == .next;
    const settling_target = home.session_state.promiseWirePosition(wire_far.import_position);
    const listener = try home.session_state.allocateExport();
    {
        errdefer home.session_state.releaseUnsharedExport(listener);
        if (next) {
            if (!home.session_state.claimPromiseSettlingListener(settling_target, listener, null))
                return error.UnexpectedMessage;
        } else {
            home.session_state.installNodeSettlingResolver(listener);
        }
    }
    errdefer releaseHomeListener(home, listener, settling_target.int());
    const message: model.Message = .{ .listen = .{
        .target = .{ .far = model.FarRef.promise(settling_target.int()) },
        .listener = home.session_state.exportReference(listener).?,
        .mode = .settling_only,
    } };
    try home.session_state.admits(model.view.Body.fromOwned(&message));
    // A listen carries no argument tree, so its inventory is empty.
    try session_mod.validate.validateSend(&home.session_state, message, .none);
    const reservation = try home.reservePending(.{ .message = message });
    errdefer home.cancelPendingReservation(reservation);
    var proxy: topology.Proxy = .{
        .listener_export = listener.int(),
        .current_wire_pos = settling_target.int(),
    };
    errdefer proxy.deinit(self.allocator);
    try proxy.recipients.ensureUnusedCapacity(self.allocator, recipient_count);
    return .{
        .key = key,
        .listener_export = listener,
        .current_wire_pos = settling_target.int(),
        .message = message,
        .reservation = reservation,
        .proxy = proxy,
    };
}

fn prepareRecipient(
    self: *Node,
    recipient: *engine.Peer,
    recipient_peer: PeerHandle,
    home_key: topology.HomeKey,
) !PreparedRecipient {
    const projection = try recipient.session_state.allocateLocalPromiseProjection();
    errdefer recipient.session_state.abandonLocalPromiseProjection(projection.export_position);
    const reason = try self.allocator.dupe(u8, failure_reason);
    return .{
        .home_key = home_key,
        .peer = recipient_peer,
        .projection = projection,
        .failure_reason = reason,
    };
}

/// Prepare every promise occurrence in one Passable transaction. No home
/// listener or recipient row becomes visible until `Prepared.commit`.
pub fn prepare(
    self: *Node,
    recipient_peer: PeerHandle,
    promises: []passable.PromiseProjection,
) !Prepared {
    var prepared: Prepared = .{ .groups = .keyed(self.promise_proxies.multiplier) };
    errdefer prepared.deinit(self);
    if (promises.len == 0) return prepared;

    try prepared.groups.ensureUnusedCapacity(self.allocator, @intCast(promises.len));
    for (promises) |promise| {
        const foreign = Internal.foreignRoute(self, promise.route_id) orelse return error.RouteNotLowerable;
        if (foreign.peer_handle != promise.home or !std.meta.eql(foreign.far, promise.source))
            return error.RouteNotLowerable;
        const home_key = try homeKeyOf(self, promise);
        const entry = prepared.groups.getOrPutAssumeCapacity(home_key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.count += 1;
    }

    var new_homes: usize = 0;
    var groups = prepared.groups.iterator();
    while (groups.next()) |entry| {
        if (self.promise_proxies.getPtr(entry.key_ptr.*)) |proxy| {
            if (proxy.recipients.items.len + entry.value_ptr.count > topology.max_recipients)
                return error.ProxyRecipientCapExceeded;
            try proxy.recipients.ensureUnusedCapacity(self.allocator, entry.value_ptr.count);
        } else {
            if (entry.value_ptr.count > topology.max_recipients)
                return error.ProxyRecipientCapExceeded;
            new_homes += 1;
        }
    }
    try self.proxy_by_listener.ensureUnusedCapacity(self.allocator, @intCast(new_homes));
    try self.promise_proxies.ensureUnusedCapacity(self.allocator, @intCast(new_homes));
    try self.proxy_by_source.ensureUnusedCapacity(self.allocator, @intCast(new_homes));

    groups = prepared.groups.iterator();
    while (groups.next()) |entry| {
        if (self.promise_proxies.contains(entry.key_ptr.*)) continue;
        entry.value_ptr.prepared_home = try prepareHome(
            self,
            entry.key_ptr.*,
            model.FarRef.promise(entry.key_ptr.*.wire_pos),
            entry.value_ptr.count,
        );
    }

    try prepared.recipients.ensureTotalCapacityPrecise(self.allocator, promises.len);
    const recipient = self.peer(recipient_peer) orelse return error.PeerGone;
    for (promises) |*promise| {
        const home_key = try homeKeyOf(self, promise.*);
        const projected = try prepareRecipient(self, recipient, recipient_peer, home_key);
        prepared.recipients.appendAssumeCapacity(projected);
        promise.projected = .{ .near = model.NearRef.promise(projected.projection.export_position.int()) };
    }
    return prepared;
}

/// Top-level fulfillment uses the same prepare/commit package as recursive
/// Passable values, so it cannot create a second proxy admission protocol.
pub fn foreignPromiseFulfill(
    self: *Node,
    recipient_peer: PeerHandle,
    route_id: model.CapabilityRouteId,
) !?model.Reference {
    const home = Internal.homeOf(self, route_id) orelse return null;
    if (home == recipient_peer) return null;
    const enrolled = Internal.foreignRoute(self, route_id) orelse return null;
    if (enrolled.far.kind != .promise) return null;

    // One seat is the future recipient settlement drive; the other is the
    // possible first home-listener flush. Existing proxies leave the second
    // seat unused.
    try actions.reserve(self, 2);
    var projections = [_]passable.PromiseProjection{.{
        .route_id = route_id,
        .home = home,
        // No tree holds this projection: the caller takes `projected` as its
        // own by-value result, which is the root slot's meaning.
        .slot = .root,
        .original = .{ .routed = .{ .id = route_id, .kind = .promise } },
        .source = enrolled.far,
    }};
    var prepared = try prepare(self, recipient_peer, &projections);
    defer prepared.deinit(self);
    prepared.commit(self);
    return projections[0].projected.?;
}
