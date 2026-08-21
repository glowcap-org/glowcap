//! Exporter-location ownership and signed give recipe construction.

const std = @import("std");

const model = @import("model");
const engine = @import("../../../mod.zig");
const node_mod = @import("../../../node.zig");

const Node = node_mod.Node;
const Internal = node_mod.Internal;
const PeerHandle = @import("../../../peer_handle.zig").PeerHandle;

/// Canonical locator-record overrides, embedded in the Node aggregate.
pub const State = struct {
    by_exporter: std.AutoHashMapUnmanaged(PeerHandle, []u8) = .empty,
};

pub fn deinit(self: *Node) void {
    var it = self.gifts.recipe.by_exporter.valueIterator();
    while (it.next()) |location_bytes| self.allocator.free(location_bytes.*);
    self.gifts.recipe.by_exporter.deinit(self.allocator);
}

/// Record the verbatim exporter locator embedded in gives for `peer_handle` when
/// its session record is not itself dialable. `location` is borrowed and
/// copied; null clears the override back to the session's signed record.
pub fn set(self: *Node, peer_handle: PeerHandle, location: ?model.PeerLocator) !void {
    const loc = location orelse {
        if (self.gifts.recipe.by_exporter.fetchRemove(peer_handle)) |previous|
            self.allocator.free(previous.value);
        return;
    };
    // Gives embed canonical Syrup locator-record bytes; no URI spelling can
    // cross this authority boundary.
    const owned = try engine.encodePeerLocatorRecord(self.allocator, loc);
    errdefer self.allocator.free(owned);
    if (!self.gifts.recipe.by_exporter.contains(peer_handle))
        try self.gifts.recipe.by_exporter.ensureUnusedCapacity(self.allocator, 1);
    if (self.gifts.recipe.by_exporter.fetchPutAssumeCapacity(peer_handle, owned)) |previous|
        self.allocator.free(previous.value);
}

pub fn get(self: *const Node, peer_handle: PeerHandle) []const u8 {
    return self.gifts.recipe.by_exporter.get(peer_handle) orelse "";
}

pub fn removeForPeer(self: *Node, peer_handle: PeerHandle) void {
    if (self.gifts.recipe.by_exporter.fetchRemove(peer_handle)) |previous|
        self.allocator.free(previous.value);
}

/// Mint before either Peer queue is prepared, so signing/encoding failure
/// cannot leave stale session reservations.
pub fn mint(
    self: *Node,
    exporter_peer: PeerHandle,
    gift_id: []const u8,
    recipient_key: []const u8,
    exporter_key: []const u8,
    exporter_loc: []const u8,
    recipient_known_pancake: bool,
) ![]u8 {
    const secret = Internal.sessionSecret(self, exporter_peer) orelse
        return error.RouteNotLowerable;
    return engine.handoff_gifter.mintGive(
        self.allocator,
        secret,
        gift_id,
        recipient_key,
        exporter_key,
        exporter_loc,
        recipient_known_pancake,
    );
}
