//! Exporter-location ownership and signed give recipe construction.

const std = @import("std");

const model = @import("model");
const engine = @import("../../../mod.zig");
const node_mod = @import("../../../node.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;

const Locations = struct {
    explicit: ?[]u8 = null,
    discovered: ?[]u8 = null,

    fn deinit(self: Locations, allocator: std.mem.Allocator) void {
        if (self.explicit) |location| allocator.free(location);
        if (self.discovered) |location| allocator.free(location);
    }

    fn effective(self: Locations) []const u8 {
        return self.explicit orelse self.discovered orelse "";
    }
};

/// Canonical locator records, embedded in the Node aggregate. Explicit
/// application policy and routes discovered through verified redemption retain
/// separate authority even though give construction consumes one effective
/// location.
pub const State = struct {
    by_exporter: std.AutoHashMapUnmanaged(PeerHandle, Locations) = .empty,
};

pub fn deinit(self: *Node) void {
    var it = self.gifts.recipe.by_exporter.valueIterator();
    while (it.next()) |locations| locations.deinit(self.allocator);
    self.gifts.recipe.by_exporter.deinit(self.allocator);
}

/// Record the verbatim exporter locator embedded in gives for `peer_handle` when
/// its session record is not itself dialable. `location` is borrowed and
/// copied. `null` clears the override back to the session's signed record.
pub fn set(self: *Node, peer_handle: PeerHandle, location: ?model.PeerLocator) !void {
    const loc = location orelse {
        const locations = self.gifts.recipe.by_exporter.getPtr(peer_handle) orelse return;
        if (locations.explicit) |previous| self.allocator.free(previous);
        locations.explicit = null;
        if (locations.discovered == null)
            std.debug.assert(self.gifts.recipe.by_exporter.remove(peer_handle));
        return;
    };
    if (std.mem.eql(u8, loc.transport, model.transport.id))
        _ = try self.validateIdRouteLocator(loc);
    // Gives embed canonical Syrup locator-record bytes; no URI spelling can
    // cross this authority boundary.
    const owned = try engine.encodePeerLocatorRecord(self.allocator, loc);
    errdefer self.allocator.free(owned);
    const present = self.gifts.recipe.by_exporter.contains(peer_handle);
    if (!present)
        try self.gifts.recipe.by_exporter.ensureUnusedCapacity(self.allocator, 1);
    if (present) {
        const locations = self.gifts.recipe.by_exporter.getPtr(peer_handle).?;
        if (locations.explicit) |previous| self.allocator.free(previous);
        locations.explicit = owned;
    } else {
        self.gifts.recipe.by_exporter.putAssumeCapacity(peer_handle, .{ .explicit = owned });
    }
}

/// Reserve the row needed to adopt route advice after a successful `id`
/// withdrawal. Existing rows need no capacity. `putDiscoveredReserved` owns
/// the first-writer rule for an existing discovered route.
pub fn reserveDiscoveredSlot(self: *Node, peer_handle: PeerHandle) !void {
    if (self.gifts.recipe.by_exporter.contains(peer_handle)) return;
    try self.gifts.recipe.by_exporter.ensureUnusedCapacity(self.allocator, 1);
}

pub fn needsDiscovered(self: *const Node, peer_handle: PeerHandle) bool {
    const locations = self.gifts.recipe.by_exporter.get(peer_handle) orelse return true;
    return locations.discovered == null;
}

/// Consume canonical locator-record bytes after `reserveDiscoveredSlot`.
/// Explicit policy remains effective while the discovered route waits
/// underneath it.
pub fn putDiscoveredReserved(self: *Node, peer_handle: PeerHandle, location_bytes: []u8) void {
    if (self.gifts.recipe.by_exporter.getPtr(peer_handle)) |locations| {
        if (locations.discovered == null) {
            locations.discovered = location_bytes;
            return;
        }
        self.allocator.free(location_bytes);
        return;
    }
    self.gifts.recipe.by_exporter.putAssumeCapacity(peer_handle, .{ .discovered = location_bytes });
}

/// Replace the discovered recipe with one complete route just verified by
/// enlivenment. A sturdyref is authored as one `(location, swiss)` authority.
/// If listener state changed since an earlier dial, its location is the newer
/// advice and later gives must not stay pinned to the old route. Explicit
/// application policy remains effective above it.
pub fn replaceDiscovered(self: *Node, peer_handle: PeerHandle, location: model.PeerLocator) !void {
    const owned = try engine.encodePeerLocatorRecord(self.allocator, location);
    errdefer self.allocator.free(owned);
    if (self.gifts.recipe.by_exporter.getPtr(peer_handle)) |locations| {
        if (locations.discovered) |previous| self.allocator.free(previous);
        locations.discovered = owned;
        return;
    }
    try self.gifts.recipe.by_exporter.ensureUnusedCapacity(self.allocator, 1);
    self.gifts.recipe.by_exporter.putAssumeCapacity(peer_handle, .{ .discovered = owned });
}

pub fn get(self: *const Node, peer_handle: PeerHandle) []const u8 {
    const locations = self.gifts.recipe.by_exporter.get(peer_handle) orelse return "";
    return locations.effective();
}

pub fn removeForPeer(self: *Node, peer_handle: PeerHandle) void {
    if (self.gifts.recipe.by_exporter.fetchRemove(peer_handle)) |previous|
        previous.value.deinit(self.allocator);
}

/// Mint before either Peer queue is prepared, so signing/encoding failure
/// cannot leave stale session reservations.
pub fn mint(
    self: *Node,
    recipient: *engine.Peer,
    recipient_peer: PeerHandle,
    exporter_peer: PeerHandle,
    gift_id: []const u8,
    recipient_key: []const u8,
    exporter_key: []const u8,
    exporter_loc: []const u8,
) ![]u8 {
    const secret = Internal.sessionSecret(self, exporter_peer) orelse
        return error.RouteNotLowerable;
    const exporter = self.peer(exporter_peer) orelse return error.RouteNotLowerable;
    const exporter_session_location = exporter.session_state.partnerLocatorRaw() orelse
        return error.RouteNotLowerable;
    const policy: engine.handoff_gifter.RecipientLocatorPolicy = .{
        .known_glowcap = recipient.session_state.partnerKnownGlowcap(),
        .route_vocabulary = recipient.session_state.captp_version == .next and
            recipient.session_state.features.multi_location,
        .session_transport = Internal.sessionTransport(self, recipient_peer),
    };
    return engine.handoff_gifter.mintGive(
        self.allocator,
        secret,
        gift_id,
        recipient_key,
        exporter_key,
        exporter_loc,
        policy,
        .{
            .route_vocabulary = exporter.session_state.captp_version == .next and
                exporter.session_state.features.multi_location,
            .session_location = exporter_session_location,
        },
    );
}
