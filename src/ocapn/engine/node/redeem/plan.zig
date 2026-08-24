//! Handoff redeem route-bundle aliases.
//!
//! The parser and route-list limits live in `model.route_bundle` so handoff
//! fallback and id route-bundle locators cannot drift. This module keeps the
//! Node-facing error spelling and names.

const model = @import("model");
const session = @import("session");
const std = @import("std");

const id_route = session.id_route;

pub const Path = model.RoutePath;
pub const Owned = model.RouteBundle;

pub fn parse(
    allocator: std.mem.Allocator,
    exporter_locator: []const u8,
) error{ OutOfMemory, UnparseableExporterLocator, UnsupportedId }!Owned {
    var parsed = model.parseExporterRouteBundleUri(allocator, exporter_locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableExporterLocator,
    };
    errdefer parsed.deinit(allocator);
    if (parsed.source == .id)
        id_route.validateBundle(parsed) catch |err| switch (err) {
            error.UnparseableId => return error.UnparseableExporterLocator,
            error.UnsupportedId => return error.UnsupportedId,
        };
    return parsed;
}

pub fn fromLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) error{ OutOfMemory, UnparseableExporterLocator, UnsupportedId }!Owned {
    var parsed = model.route_bundle.fromPeerLocator(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableLocator => return error.UnparseableExporterLocator,
    };
    errdefer parsed.deinit(allocator);
    if (parsed.source == .id)
        id_route.validateBundle(parsed) catch |err| switch (err) {
            error.UnparseableId => return error.UnparseableExporterLocator,
            error.UnsupportedId => return error.UnsupportedId,
        };
    return parsed;
}

/// Parse an owned locator into the dial plan, consuming the locator on every
/// outcome so an inbound give never clones a complete locator graph.
pub fn fromOwnedLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) error{ OutOfMemory, UnparseableExporterLocator, UnsupportedId }!Owned {
    var parsed = model.route_bundle.fromOwnedPeerLocator(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableLocator => return error.UnparseableExporterLocator,
    };
    errdefer parsed.deinit(allocator);
    if (parsed.source == .id)
        id_route.validateBundle(parsed) catch |err| switch (err) {
            error.UnparseableId => return error.UnparseableExporterLocator,
            error.UnsupportedId => return error.UnsupportedId,
        };
    return parsed;
}

pub const demandedPartnerKey = id_route.demandedPartnerKey;
