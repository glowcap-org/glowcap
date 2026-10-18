//! Handoff redeem route-bundle aliases.
//!
//! The parser and route-list limits live in `model.route_bundle` so handoff
//! fallback and id route-bundle locators cannot drift. This module keeps the
//! Node-facing error spelling and names.

const model = @import("model");
const session = @import("session");
const std = @import("std");

const id_route = session.id_route;

pub const Owned = model.RouteBundle;

pub const Error = error{ OutOfMemory, UnparseableExporterLocator, UnsupportedId };

pub fn parse(allocator: std.mem.Allocator, exporter_locator: []const u8) Error!Owned {
    const parsed = model.parseExporterRouteBundleUri(allocator, exporter_locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableExporterLocator,
    };
    return validated(allocator, parsed);
}

pub fn fromLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) Error!Owned {
    const parsed = model.route_bundle.fromPeerLocator(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableLocator => return error.UnparseableExporterLocator,
    };
    return validated(allocator, parsed);
}

/// Parse an owned locator into the dial plan, consuming the locator on every
/// outcome so an inbound give never clones a complete locator graph.
pub fn fromOwnedLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) Error!Owned {
    const parsed = model.route_bundle.fromOwnedPeerLocator(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableLocator => return error.UnparseableExporterLocator,
    };
    return validated(allocator, parsed);
}

/// Hold an `id` bundle to the identity-route rules, consuming it on refusal.
fn validated(allocator: std.mem.Allocator, parsed: Owned) Error!Owned {
    var owned = parsed;
    errdefer owned.deinit(allocator);
    if (owned.source == .id)
        id_route.validateBundle(owned) catch |err| switch (err) {
            error.UnparseableId => return error.UnparseableExporterLocator,
            error.UnsupportedId => return error.UnsupportedId,
        };
    return owned;
}

pub const demandedPartnerKey = id_route.demandedPartnerKey;
