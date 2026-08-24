//! Owned multi-route locator data.
//!
//! A bundle is one peer identity plus the ordered locator paths that can reach
//! it. The handoff fallback hint and the id route-bundle locator parse through
//! this owner so they cannot grow separate route limits or URI splitting rules.

const std = @import("std");

const model = @import("mod.zig");
const uri_shape = @import("uri_shape.zig");

pub const max_route_list_count: usize = 8;
pub const max_route_list_bytes: usize = 4 * 1024;

pub const Error = error{ OutOfMemory, UnparseableLocator };
pub const ViewError = error{UnparseableLocator};

pub const RouteUriView = struct {
    uri: []const u8,
    transport_encoded: []const u8,
    designator_encoded: []const u8,
    query_encoded: ?[]const u8,
};

/// Allocation-free route-list reader shared by Session admission and the
/// owned dial parser. URI and query-dictionary shape are complete here; a
/// transport owner applies its own designator and hint semantics afterward.
pub const RouteListIterator = struct {
    split: std.mem.SplitIterator(u8, .scalar),
    count: usize = 0,

    pub fn init(value: []const u8) ViewError!RouteListIterator {
        if (value.len == 0 or value.len > max_route_list_bytes)
            return error.UnparseableLocator;
        return .{ .split = std.mem.splitScalar(u8, value, '|') };
    }

    pub fn next(self: *RouteListIterator) ViewError!?RouteUriView {
        const raw = self.split.next() orelse return null;
        const uri = std.mem.trim(u8, raw, " \t");
        if (uri.len == 0) return error.UnparseableLocator;
        self.count += 1;
        if (self.count > max_route_list_count) return error.UnparseableLocator;
        return try inspectRouteUri(uri);
    }
};

/// Admit two route-list hints against the one aggregate byte budget. The
/// separator accounts for their logical concatenation without allocating it.
pub fn validateCombinedListBytes(first: []const u8, second: []const u8) ViewError!void {
    const separators: usize = @intFromBool(first.len != 0 and second.len != 0);
    const combined = std.math.add(usize, first.len, second.len) catch
        return error.UnparseableLocator;
    const total = std.math.add(usize, combined, separators) catch
        return error.UnparseableLocator;
    if (total > max_route_list_bytes) return error.UnparseableLocator;
}

fn decodedByte(bytes: []const u8, at: *usize) u8 {
    if (bytes[at.*] != '%') {
        defer at.* += 1;
        return bytes[at.*];
    }
    const value = std.fmt.parseInt(u8, bytes[at.* + 1 .. at.* + 3], 16) catch unreachable;
    at.* += 3;
    return value;
}

fn decodedEqual(left: []const u8, right: []const u8) bool {
    var left_at: usize = 0;
    var right_at: usize = 0;
    while (left_at < left.len and right_at < right.len) {
        if (decodedByte(left, &left_at) != decodedByte(right, &right_at)) return false;
    }
    return left_at == left.len and right_at == right.len;
}

fn decodedContains(bytes: []const u8, needle: u8) bool {
    var at: usize = 0;
    while (at < bytes.len) if (decodedByte(bytes, &at) == needle) return true;
    return false;
}

fn validateQuery(query: []const u8) ViewError!void {
    if (query.len == 0) return;
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, query, '&');
    while (segments.next()) |segment| {
        count += 1;
        if (count > model.max_locator_hint_count) return error.UnparseableLocator;
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse return error.UnparseableLocator;
        const name = segment[0..eq];
        if (name.len == 0) return error.UnparseableLocator;

        var prior_count: usize = 0;
        var prior = std.mem.splitScalar(u8, query, '&');
        while (prior_count + 1 < count) : (prior_count += 1) {
            const seen = prior.next() orelse unreachable;
            const seen_eq = std.mem.indexOfScalar(u8, seen, '=') orelse return error.UnparseableLocator;
            if (decodedEqual(seen[0..seen_eq], name)) return error.UnparseableLocator;
        }
    }
}

/// Validate the generic shape of one concrete dial path without allocating.
/// Transport-specific designator and hint semantics remain with their owner.
pub fn validateDialPathView(route: RouteUriView) ViewError!void {
    if (decodedEqual(route.transport_encoded, model.transport.id) or
        decodedContains(route.transport_encoded, '.'))
        return error.UnparseableLocator;
    const query = route.query_encoded orelse return;
    var segments = std.mem.splitScalar(u8, query, '&');
    while (segments.next()) |segment| {
        const eq = std.mem.indexOfScalar(u8, segment, '=') orelse unreachable;
        const name = segment[0..eq];
        if (decodedEqual(name, model.transport.hint_alt_locators))
            return error.UnparseableLocator;
    }
}

fn inspectRouteUri(uri_text: []const u8) ViewError!RouteUriView {
    const uri = uri_shape.inspect(uri_text) catch return error.UnparseableLocator;
    if (!std.mem.eql(u8, uri.scheme, "ocapn") or uri.path.len != 0)
        return error.UnparseableLocator;

    const host = uri.authority;
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return error.UnparseableLocator;
    const designator = host[0..dot];
    const transport_name = host[dot + 1 ..];
    if (designator.len == 0 or transport_name.len == 0) return error.UnparseableLocator;
    const query = uri.query;
    if (query) |value| try validateQuery(value);
    return .{
        .uri = uri_text,
        .transport_encoded = transport_name,
        .designator_encoded = designator,
        .query_encoded = query,
    };
}

/// One parsed dial path. Every field is owned by the enclosing bundle; `hints`
/// stays complete because transport-specific residents may consume entries the
/// generic dial planner does not know.
pub const Path = struct {
    transport: []const u8,
    designator: []const u8,
    hints: model.Hints,
};

pub const Source = enum {
    peer_locator,
    id,
};

/// Canonical peer identity plus ordered dial paths.
pub const Owned = struct {
    source: Source,
    identity: []u8,
    /// Stable source order. The index is the route's default dial rank and is
    /// preserved through Node actions and every binding-facing completion.
    paths: []Path,
    /// Prefix of `paths` whose authenticated channel must prove the outer `id`
    /// designator. Remaining paths are weak handoff fallbacks: they may redeem
    /// the gift that authorized their dial, but never establish this identity.
    identity_path_count: usize = 0,

    pub fn view(self: Owned, index: usize) model.PeerLocator {
        const path = self.paths[index];
        return .{
            .transport = path.transport,
            .designator = path.designator,
            .hints = path.hints,
        };
    }

    pub fn pathRequiresIdentity(self: Owned, index: usize) bool {
        return self.source == .id and index < self.identity_path_count;
    }

    /// Release only the paths when another owner adopts `identity`.
    pub fn deinitPaths(self: *const Owned, allocator: std.mem.Allocator) void {
        for (self.paths) |path| deinitPath(allocator, path);
        allocator.free(self.paths);
    }

    pub fn deinit(self: *const Owned, allocator: std.mem.Allocator) void {
        self.deinitPaths(allocator);
        allocator.free(self.identity);
    }
};

pub fn deinitPath(allocator: std.mem.Allocator, path: Path) void {
    allocator.free(path.transport);
    allocator.free(path.designator);
    model.freeHints(allocator, path.hints);
}

fn hintValuesEqual(left: model.HintValue, right: model.HintValue) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .string => |value| std.mem.eql(u8, value, right.string),
        .bytes => |value| std.mem.eql(u8, value, right.bytes),
        .boolean => |value| value == right.boolean,
        .integer => |value| value == right.integer,
    };
}

fn hintsEqual(left: model.Hints, right: model.Hints) bool {
    if (left.entries.len != right.entries.len) return false;
    for (left.entries) |left_entry| {
        var found = false;
        for (right.entries) |right_entry| {
            if (std.mem.eql(u8, left_entry.name, right_entry.name) and
                hintValuesEqual(left_entry.value, right_entry.value))
            {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn pathHintsEqual(left: Path, right: Path) bool {
    const known = model.transport.parseKnown(left.transport) orelse
        return hintsEqual(left.hints, right.hints);
    // An address-designator transport dials from the designator alone. Its
    // URI hints remain advisory metadata, while any top-level alt-locators
    // have already become explicit paths in this bundle.
    if (known.metadata().address_source == .designator) return true;
    return hintsEqual(left.hints, right.hints);
}

/// Whether two bundles would execute the same ordered physical dial plan.
/// Canonical peer identity deliberately excludes hints; pending work may share
/// that identity only when its retained route advice is also identical.
pub fn samePaths(left: Owned, right: Owned) bool {
    if (left.paths.len != right.paths.len or
        left.identity_path_count != right.identity_path_count) return false;
    for (left.paths, right.paths) |left_path, right_path| {
        if (!std.mem.eql(u8, left_path.transport, right_path.transport) or
            !std.mem.eql(u8, left_path.designator, right_path.designator) or
            !pathHintsEqual(left_path, right_path))
            return false;
    }
    return true;
}

fn locatorHasHint(locator: anytype, name: []const u8) bool {
    for (locator.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

pub fn locatorHasAlternativeHint(locator: anytype) bool {
    return locatorHasHint(locator, model.transport.hint_alt_locators);
}

fn hintValue(hints: model.Hints, name: []const u8) ?[]const u8 {
    for (hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        return switch (entry.value) {
            .string => |value| value,
            else => null,
        };
    }
    return null;
}

fn parsePath(allocator: std.mem.Allocator, route: RouteUriView) Error!Path {
    const parsed = model.uri.Internal.materializeInspectedPeer(
        allocator,
        route.transport_encoded,
        route.designator_encoded,
        route.query_encoded,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableLocator,
    };
    if (std.mem.eql(u8, parsed.transport, model.transport.id) or
        locatorHasAlternativeHint(parsed))
    {
        model.freePeerLocator(allocator, parsed);
        return error.UnparseableLocator;
    }
    return .{
        .transport = parsed.transport,
        .designator = parsed.designator,
        .hints = parsed.hints,
    };
}

const AcceptRoute = struct {
    fn validate(_: AcceptRoute, _: RouteUriView) error{}!void {}
};

fn appendUriList(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged(Path),
    value: []const u8,
    validator: anytype,
) !void {
    var list = RouteListIterator.init(value) catch return error.UnparseableLocator;
    while (list.next() catch return error.UnparseableLocator) |route| {
        if (paths.items.len >= max_route_list_count)
            return error.UnparseableLocator;
        try validator.validate(route);
        const path = try parsePath(allocator, route);
        var path_owned = true;
        errdefer if (path_owned) deinitPath(allocator, path);
        try paths.append(allocator, path);
        path_owned = false;
    }
}

fn identityForLocator(allocator: std.mem.Allocator, locator: model.PeerLocator) Error![]u8 {
    return model.uri.writePeer(allocator, .{
        .transport = locator.transport,
        .designator = locator.designator,
        .hints = model.Hints.emptyFalse(),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableLocator,
    };
}

fn fromOwnedPrimary(
    allocator: std.mem.Allocator,
    primary: model.PeerLocator,
    extra_hint_name: []const u8,
) Error!Owned {
    var primary_owned = true;
    errdefer if (primary_owned) model.freePeerLocator(allocator, primary);

    var paths: std.ArrayListUnmanaged(Path) = .empty;
    errdefer {
        for (paths.items) |path| deinitPath(allocator, path);
        paths.deinit(allocator);
    }

    try paths.append(allocator, .{
        .transport = primary.transport,
        .designator = primary.designator,
        .hints = primary.hints,
    });
    primary_owned = false;

    if (locatorHasHint(primary, extra_hint_name)) {
        const extras = hintValue(primary.hints, extra_hint_name) orelse
            return error.UnparseableLocator;
        try appendUriList(allocator, &paths, extras, AcceptRoute{});
    }

    const identity = try identityForLocator(allocator, primary);
    errdefer allocator.free(identity);
    return .{
        .source = .peer_locator,
        .identity = identity,
        .paths = try paths.toOwnedSlice(allocator),
    };
}

/// Parse the exporter URI a handoff give carried. The existing `alt-locators`
/// hint remains fallback advice; this function only moves its parser and limits
/// to the route-bundle authority.
pub fn fromExporterUri(
    allocator: std.mem.Allocator,
    exporter_locator: []const u8,
) Error!Owned {
    const primary = model.uri.parsePeer(allocator, exporter_locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnparseableLocator,
    };
    return fromOwnedPeerLocator(allocator, primary);
}

pub fn fromPeerLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) Error!Owned {
    if (std.mem.eql(u8, locator.transport, model.transport.id))
        return fromIdLocator(allocator, locator);
    model.validatePeerLocator(locator) catch return error.UnparseableLocator;
    const primary = model.clonePeerLocator(allocator, locator) catch return error.OutOfMemory;
    return fromOwnedPrimary(allocator, primary, model.transport.hint_alt_locators);
}

/// Build a route bundle by consuming an already-owned locator on every
/// outcome. Non-id primary storage moves directly into the first path; id
/// storage is released after its concrete route list has been materialized.
pub fn fromOwnedPeerLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) Error!Owned {
    if (std.mem.eql(u8, locator.transport, model.transport.id)) {
        defer model.freePeerLocator(allocator, locator);
        return fromIdLocator(allocator, locator);
    }
    model.validatePeerLocator(locator) catch {
        model.freePeerLocator(allocator, locator);
        return error.UnparseableLocator;
    };
    return fromOwnedPrimary(allocator, locator, model.transport.hint_alt_locators);
}

/// Parse the id locator skin. Its designator is the peer identity;
/// concrete carrier locators live in one required route-list hint.
pub fn fromIdLocator(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) Error!Owned {
    return fromIdLocatorWithPathSet(allocator, locator, .all, AcceptRoute{});
}

/// Parse only the identity-proving prefix while still validating any weak
/// fallback suffix. Sturdyrefs use this shape because fallback advice cannot
/// authorize the durable identity they name.
pub fn fromIdLocatorIdentityPaths(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) Error!Owned {
    return fromIdLocatorWithPathSet(allocator, locator, .identity, AcceptRoute{});
}

pub const Internal = struct {
    /// Materialize an id bundle while its session-owned identity rule validates
    /// each strong route from the same inspected URI view.
    pub fn fromIdLocatorChecked(
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
        validator: anytype,
    ) !Owned {
        return fromIdLocatorWithPathSet(allocator, locator, .all, validator);
    }

    pub fn fromIdLocatorIdentityPathsChecked(
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
        validator: anytype,
    ) !Owned {
        return fromIdLocatorWithPathSet(allocator, locator, .identity, validator);
    }
};

const IdPathSet = enum { all, identity };

fn fromIdLocatorWithPathSet(
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    path_set: IdPathSet,
    validator: anytype,
) !Owned {
    if (!std.mem.eql(u8, locator.transport, model.transport.id))
        return error.UnparseableLocator;
    model.validatePeerLocator(locator) catch return error.UnparseableLocator;
    const routes = hintValue(locator.hints, model.transport.hint_via) orelse
        return error.UnparseableLocator;
    const alternatives = if (locatorHasHint(locator, model.transport.hint_alt_locators))
        hintValue(locator.hints, model.transport.hint_alt_locators) orelse
            return error.UnparseableLocator
    else
        null;
    if (alternatives) |weak| try validateCombinedListBytes(routes, weak);

    var paths: std.ArrayListUnmanaged(Path) = .empty;
    errdefer {
        for (paths.items) |path| deinitPath(allocator, path);
        paths.deinit(allocator);
    }
    try appendUriList(allocator, &paths, routes, validator);
    if (paths.items.len == 0) return error.UnparseableLocator;
    const identity_path_count = paths.items.len;
    if (alternatives) |weak| switch (path_set) {
        .all => try appendUriList(allocator, &paths, weak, AcceptRoute{}),
        .identity => {
            var weak_paths = RouteListIterator.init(weak) catch return error.UnparseableLocator;
            while (weak_paths.next() catch return error.UnparseableLocator) |route|
                try validateDialPathView(route);
            if (identity_path_count + weak_paths.count > max_route_list_count)
                return error.UnparseableLocator;
        },
    };
    if (paths.items.len > max_route_list_count) return error.UnparseableLocator;

    const identity = try identityForLocator(allocator, .{
        .transport = locator.transport,
        .designator = locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    errdefer allocator.free(identity);
    return .{
        .source = .id,
        .identity = identity,
        .paths = try paths.toOwnedSlice(allocator),
        .identity_path_count = identity_path_count,
    };
}
