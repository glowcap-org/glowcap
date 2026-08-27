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
    next: bool,
    message: model.Message,
    reservation: engine.Peer.PendingReservation,
    proxy: topology.Proxy,
    committed: bool = false,

    fn abandon(self: *PreparedHome, node: *Node) void {
        if (self.committed) return;
        if (node.peer(self.key.home)) |home| {
            home.cancelPendingReservation(self.reservation);
            if (self.next) {
                home.session_state.abandonPromiseSettlingListener(.from(self.current_wire_pos));
            } else {
                std.debug.assert(home.session_state.removeOutboundResolver(self.listener_export));
            }
            home.session_state.releaseUnsharedExport(self.listener_export);
        }
        self.proxy.deinit(node.allocator);
        self.* = undefined;
    }

    fn commit(self: *PreparedHome, node: *Node) void {
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
    export_position: model.ExportPosition,
    import_position: model.ImportPosition,
    row_id: u64,
    failure_reason: []u8,
    committed: bool = false,

    fn abandon(self: *PreparedRecipient, node: *Node) void {
        if (self.committed) return;
        if (node.peer(self.peer)) |recipient| {
            recipient.session_state.abandonUnsharedThirdPartyImport(self.import_position);
            recipient.session_state.releaseUnsharedExport(self.export_position);
        }
        node.allocator.free(self.failure_reason);
        self.* = undefined;
    }

    fn commit(self: *PreparedRecipient, node: *Node) void {
        const proxy = node.promise_proxies.getPtr(self.home_key) orelse unreachable;
        proxy.recipients.appendAssumeCapacity(.{
            .peer = self.peer,
            .import_pos = self.import_position.int(),
            .row_id = self.row_id,
            .failure_reason = self.failure_reason,
        });
        self.committed = true;
    }
};

pub const Prepared = struct {
    groups: std.AutoHashMapUnmanaged(topology.HomeKey, Group) = .empty,
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
        var groups = self.groups.valueIterator();
        while (groups.next()) |group| if (group.prepared_home) |*home|
            home.commit(node);
        for (self.recipients.items) |*recipient| recipient.commit(node);
        actions.commitProxyReservations(node, self.recipients.items.len);
        self.committed = true;
    }
};

fn prepareHome(
    self: *Node,
    key: topology.HomeKey,
    wire_far: model.FarRef,
    recipient_count: usize,
) !PreparedHome {
    const home = self.peer(key.home) orelse return error.PeerGone;
    if (!home.sessionIsOpen()) return error.session_not_open;
    const next = home.session_state.captp_version == .next;
    const settling_target = if (next)
        home.session_state.shortenedPromiseTarget(wire_far.import_position)
    else
        wire_far.import_position;
    const listener = try home.session_state.allocateExport();
    errdefer home.session_state.releaseUnsharedExport(listener);
    if (next) {
        if (!(try home.session_state.claimPromiseSettlingListener(settling_target, listener, null)))
            return error.UnexpectedMessage;
    } else {
        try home.session_state.installNodeSettlingResolver(listener);
    }
    errdefer if (next) {
        home.session_state.abandonPromiseSettlingListener(settling_target);
    } else {
        std.debug.assert(home.session_state.removeOutboundResolver(listener));
    };
    const message: model.Message = .{ .listen = .{
        .target = .{ .far = model.FarRef.promise(settling_target.int()) },
        .listener = session_mod.slot.toReference(home.session_state.exportSlot(listener).?).?,
        .mode = .settling_only,
    } };
    try home.session_state.admits(model.view.Body.fromOwned(&message));
    try session_mod.validate.validateSend(&home.session_state, message);
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
        .next = next,
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
    host_bytes: []const u8,
) !PreparedRecipient {
    const export_position = try recipient.session_state.allocatePromiseExport();
    errdefer recipient.session_state.releaseUnsharedExport(export_position);
    const import_position = model.ImportPosition.from(export_position.int());
    try recipient.session_state.installThirdPartyImport(import_position, host_bytes);
    errdefer recipient.session_state.abandonUnsharedThirdPartyImport(import_position);
    const reason = try self.allocator.dupe(u8, failure_reason);
    return .{
        .home_key = home_key,
        .peer = recipient_peer,
        .export_position = export_position,
        .import_position = import_position,
        .row_id = recipient.session_state.importedPromiseRowId(import_position).?,
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
    var prepared: Prepared = .{};
    errdefer prepared.deinit(self);
    if (promises.len == 0) return prepared;

    try prepared.groups.ensureUnusedCapacity(self.allocator, @intCast(promises.len));
    for (promises) |promise| {
        const foreign = Internal.foreignRoute(self, promise.route_id) orelse return error.RouteNotLowerable;
        if (foreign.peer_handle != promise.home or foreign.reference != .far or
            !std.meta.eql(foreign.reference.far, promise.source))
            return error.RouteNotLowerable;
        const home = self.peer(promise.home) orelse return error.PeerGone;
        const current_wire_pos = if (home.session_state.captp_version == .next)
            home.session_state.shortenedPromiseTarget(promise.source.import_position).int()
        else
            promise.source.import_position.int();
        const source_key: topology.HomeKey = .{ .home = promise.home, .wire_pos = current_wire_pos };
        const home_key = self.proxy_by_source.get(source_key) orelse source_key;
        const entry = prepared.groups.getOrPutAssumeCapacity(home_key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.count = std.math.add(
            usize,
            entry.value_ptr.count,
            1,
        ) catch return error.ProxyRecipientCapExceeded;
    }

    var new_homes: usize = 0;
    var groups = prepared.groups.iterator();
    while (groups.next()) |entry| {
        if (self.promise_proxies.getPtr(entry.key_ptr.*)) |proxy| {
            const total_recipients = std.math.add(
                usize,
                proxy.recipients.items.len,
                entry.value_ptr.count,
            ) catch return error.ProxyRecipientCapExceeded;
            if (total_recipients > topology.max_recipients)
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
        const home = self.peer(promise.home) orelse return error.PeerGone;
        const current_wire_pos = if (home.session_state.captp_version == .next)
            home.session_state.shortenedPromiseTarget(promise.source.import_position).int()
        else
            promise.source.import_position.int();
        const source_key: topology.HomeKey = .{ .home = promise.home, .wire_pos = current_wire_pos };
        const home_key = self.proxy_by_source.get(source_key) orelse source_key;
        const host_bytes = home.session_state.partnerDesignator() orelse
            return error.MissingPartnerDesignator;
        const projected = try prepareRecipient(
            self,
            recipient,
            recipient_peer,
            home_key,
            host_bytes,
        );
        prepared.recipients.appendAssumeCapacity(projected);
        promise.projected = .{ .near = model.NearRef.promise(projected.export_position.int()) };
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
    const wire_far = switch (enrolled.reference) {
        .far => |f| f,
        else => return null,
    };
    if (wire_far.kind != .promise) return null;

    // One seat is the future recipient settlement drive; the other is the
    // possible first home-listener flush. Existing proxies leave the second
    // seat unused.
    try actions.reserve(self, 2);
    var projections = [_]passable.PromiseProjection{.{
        .route_id = route_id,
        .home = home,
        .original = .{ .routed = .{ .id = route_id, .kind = .promise } },
        .source = wire_far,
    }};
    var prepared = try prepare(self, recipient_peer, &projections);
    defer prepared.deinit(self);
    prepared.commit(self);
    return projections[0].projected.?;
}
