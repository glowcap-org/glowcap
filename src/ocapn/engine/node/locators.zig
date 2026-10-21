//! Node-owned advertised locator snapshots and acceptable-route selection.
//!
//! The Catalog owns one complete locator per transport and one selected key
//! borrowed from that map. Node remains the aggregate and supported API index.
//! This internal module owns the catalog's mutation and lifetime invariants.

const std = @import("std");

const model = @import("model");
const node_mod = @import("../node.zig");

const Node = node_mod.Node;

/// One Node's retained locator snapshots and explicit deployment selection.
/// Map keys alias the corresponding value's owned `transport` bytes. The
/// selected transport, when present, aliases one of those same owned keys.
pub const Catalog = struct {
    by_transport: std.StringHashMapUnmanaged(model.PeerLocator) = .empty,
    selected_transport: ?[]const u8 = null,

    /// Release every retained snapshot. Keys and selection are borrowed from
    /// the values, so only each complete locator is freed.
    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        var it = self.by_transport.valueIterator();
        while (it.next()) |locator| model.freePeerLocator(allocator, locator.*);
        self.by_transport.deinit(allocator);
    }
};

/// Replace and select the complete locator for its transport. The caller may
/// pass a locator borrowed from this same Catalog: retainCanonical returns the
/// replacement's owned key before releasing the old snapshot, so selection status-allow: replacement state identity
/// never reads caller storage after replacement.
pub fn setAdvertisedLocator(self: *Node, locator: model.PeerLocator) !void {
    self.locators.selected_transport = try retainCanonical(self, locator);
}

/// Replace the retained snapshot for `locator.transport` without changing
/// which transport is selected. If this transport was already selected, keep
/// it selected through the replacement and retarget the borrowed key slice.
pub fn retainAdvertisedLocator(self: *Node, locator: model.PeerLocator) !void {
    _ = try retainCanonical(self, locator);
}

/// Retain `locator` as a fallback without displacing an existing selection.
/// If no route is selected, this first fallback becomes the selection.
pub fn ensureAdvertisedLocator(self: *Node, locator: model.PeerLocator) !void {
    try model.validatePeerLocator(locator);
    if (self.locators.by_transport.get(locator.transport)) |stored| {
        if (self.locators.selected_transport == null)
            self.locators.selected_transport = stored.transport;
        return;
    }

    const owned = try model.view.PeerLocator.fromOwned(&locator).toOwned(self.allocator);
    errdefer model.freePeerLocator(self.allocator, owned);
    try self.locators.by_transport.putNoClobber(self.allocator, owned.transport, owned);
    if (self.locators.selected_transport == null)
        self.locators.selected_transport = owned.transport;
}

/// Remove one retained transport. Removing the selected locator leaves no
/// acceptable route. Another snapshot is never selected by map iteration.
pub fn removeAdvertisedLocator(self: *Node, transport: []const u8) void {
    const removed = self.locators.by_transport.fetchRemove(transport) orelse return;
    if (self.locators.selected_transport) |selected| {
        if (std.mem.eql(u8, selected, transport)) self.locators.selected_transport = null;
    }
    model.freePeerLocator(self.allocator, removed.value);
}

/// Select a retained locator without allocation. An unknown transport leaves
/// the Catalog unchanged.
pub fn selectAdvertisedLocator(self: *Node, transport: []const u8) bool {
    const stored = self.locators.by_transport.get(transport) orelse return false;
    self.locators.selected_transport = stored.transport;
    return true;
}

/// Borrow one retained snapshot until that transport is replaced or removed,
/// or until the Node is deinitialized.
pub fn advertisedLocator(self: *const Node, transport: []const u8) ?model.PeerLocator {
    return self.locators.by_transport.get(transport);
}

/// Borrow the explicitly selected acceptable location under the same lifetime
/// as `advertisedLocator`.
pub fn acceptableLocator(self: *const Node) ?model.PeerLocator {
    return self.locators.by_transport.get(self.locators.selected_transport orelse return null);
}

/// Deep-copy a snapshot before mutating the Catalog and return the canonical
/// retained key. Allocation failure preserves the previous row and selection.
/// This is the sole durable locator copy: callers lend their bytes and hello
/// hint scratch only through retention. Copying before replacement is required
/// because input may alias the previous row that commit releases.
fn retainCanonical(self: *Node, locator: model.PeerLocator) ![]const u8 {
    try model.validatePeerLocator(locator);
    const owned = try model.view.PeerLocator.fromOwned(&locator).toOwned(self.allocator);
    errdefer model.freePeerLocator(self.allocator, owned);

    const entry = try self.locators.by_transport.getOrPut(self.allocator, owned.transport);
    if (!entry.found_existing) {
        entry.value_ptr.* = owned;
        return owned.transport;
    }

    const was_selected = if (self.locators.selected_transport) |selected|
        std.mem.eql(u8, selected, entry.value_ptr.*.transport)
    else
        false;
    const previous = entry.value_ptr.*;
    entry.key_ptr.* = owned.transport;
    entry.value_ptr.* = owned;
    if (was_selected) self.locators.selected_transport = owned.transport;
    model.freePeerLocator(self.allocator, previous);
    return owned.transport;
}
