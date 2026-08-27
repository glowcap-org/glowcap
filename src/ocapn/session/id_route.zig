//! Identity-route admission shared by Session state and engine dialing.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

const crypto = foundation.crypto;

pub const Error = error{ UnparseableId, UnsupportedId };

pub fn parseLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) (std.mem.Allocator.Error || Error)!model.RouteBundle {
    return parseLocatorPaths(allocator, locator, .all);
}

/// Parse the identity-proving paths a sturdyref may use. Weak fallback advice
/// is validated but excluded from the returned dial plan.
pub fn parseSturdyrefLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) (std.mem.Allocator.Error || Error)!model.RouteBundle {
    return parseLocatorPaths(allocator, locator, .identity);
}

const PathSet = enum { all, identity };

fn parseLocatorPaths(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    path_set: PathSet,
) (std.mem.Allocator.Error || Error)!model.RouteBundle {
    if (!std.mem.eql(u8, locator.transport, model.transport.id))
        return error.UnparseableId;
    const expected = crypto.PeerKey.fromDesignator(locator.designator) orelse
        return error.UnparseableId;
    const validator = IdentityRouteValidator{ .expected = expected };
    const bundle = switch (path_set) {
        .all => model.route_bundle.Internal.fromIdLocatorChecked(allocator, locator, validator),
        .identity => model.route_bundle.Internal.fromIdLocatorIdentityPathsChecked(allocator, locator, validator),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableId => return error.UnparseableId,
        error.UnsupportedId => return error.UnsupportedId,
        error.UnparseableLocator => return error.UnparseableId,
    };
    return bundle;
}

const IdentityRouteValidator = struct {
    expected: crypto.PeerKey,

    pub fn validate(self: IdentityRouteValidator, route: model.route_bundle.RouteUriView) Error!void {
        try validateRoute(route, self.expected);
    }
};

/// Validate an identity locator without materializing its route list. Session
/// admission uses this on borrowed codec views; dial planning follows it with
/// the owned parser above.
pub fn validateLocator(locator: anytype) Error!?crypto.PeerKey {
    if (!std.mem.eql(u8, locator.transport, model.transport.id)) return null;
    const expected = crypto.PeerKey.fromDesignator(locator.designator) orelse
        return error.UnparseableId;
    const routes = hintString(locator.hints, model.transport.hint_via) orelse
        return error.UnparseableId;
    if (routes.len == 0 or routes.len > model.route_bundle.max_route_list_bytes)
        return error.UnparseableId;

    var list = model.route_bundle.RouteListIterator.init(routes) catch return error.UnparseableId;
    while (list.next() catch return error.UnparseableId) |route|
        try validateRoute(route, expected);
    var route_count = list.count;

    if (try hasHint(locator.hints, model.transport.hint_alt_locators)) {
        const weak = hintString(locator.hints, model.transport.hint_alt_locators) orelse
            return error.UnparseableId;
        model.route_bundle.validateCombinedListBytes(routes, weak) catch
            return error.UnparseableId;
        var alternatives = model.route_bundle.RouteListIterator.init(weak) catch
            return error.UnparseableId;
        while (alternatives.next() catch return error.UnparseableId) |route| {
            model.route_bundle.validateDialPathView(route) catch return error.UnparseableId;
            route_count += 1;
            if (route_count > model.route_bundle.max_route_list_count)
                return error.UnparseableId;
        }
    }
    return expected;
}

fn hasHint(hints: anytype, name: []const u8) Error!bool {
    if (comptime @hasDecl(@TypeOf(hints), "findNamed"))
        return (hints.findNamed(name) catch return error.UnparseableId) != null;
    for (hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn hintString(hints: anytype, name: []const u8) ?[]const u8 {
    if (comptime @hasDecl(@TypeOf(hints), "findNamed")) {
        const value = hints.findNamed(name) catch return null;
        return switch (value orelse return null) {
            .string => |text| text,
            else => null,
        };
    }
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        return switch (entry.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn validateRoute(route: model.route_bundle.RouteUriView, expected: crypto.PeerKey) Error!void {
    model.route_bundle.validateDialPathView(route) catch return error.UnparseableId;
    if (std.mem.indexOfScalar(u8, route.designator_encoded, '%') != null or
        std.mem.indexOfScalar(u8, route.transport_encoded, '%') != null)
        return error.UnparseableId;

    try validateCarrier(route.transport_encoded, route.designator_encoded, expected);
}

fn validateCarrier(transport: []const u8, designator: []const u8, expected: crypto.PeerKey) Error!void {
    const known = model.transport.parseKnown(transport) orelse return error.UnsupportedId;
    if (known == .id or !known.metadata().provesKeyDesignator())
        return error.UnsupportedId;
    const route_key = crypto.PeerKey.fromDesignator(designator) orelse return error.UnsupportedId;
    if (!route_key.eql(expected)) return error.UnsupportedId;
}

/// The durable key an id bundle's identity demands, or null when the bundle
/// carries no identity to demand. The identity URI is read back through the
/// same splitter that admits every route URI, so its shape has exactly one
/// owner and cannot drift from what `writePeer` produces.
pub fn demandedPartnerKey(bundle: model.RouteBundle) ?crypto.PeerKey {
    if (bundle.source != .id) return null;
    var list = model.route_bundle.RouteListIterator.init(bundle.identity) catch return null;
    const route = (list.next() catch return null) orelse return null;
    if (!std.mem.eql(u8, route.transport_encoded, model.transport.id)) return null;
    return crypto.PeerKey.fromDesignator(route.designator_encoded);
}

pub fn validateBundle(bundle: model.RouteBundle) Error!void {
    const expected = demandedPartnerKey(bundle) orelse return error.UnparseableId;
    if (bundle.identity_path_count == 0 or
        bundle.identity_path_count > bundle.paths.len) return error.UnparseableId;
    for (bundle.paths[0..bundle.identity_path_count]) |path|
        try validateCarrier(path.transport, path.designator, expected);
}
