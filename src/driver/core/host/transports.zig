//! Host transport semantics and advertised-route configuration.
//!
//! The Host retains the state; this internal owner validates immutable
//! transport profiles and projects/selects the complete locators its sessions
//! advertise. The supported verbs remain direct aliases on `Host`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const sessions = @import("../sessions.zig");
const vocab = @import("../vocab.zig");
const admission = @import("admission.zig");

const Host = host_mod.Host;
const HostError = host_mod.HostError;
const crypto = foundation.crypto;

/// Complete one advertised locator with this Host's profile and identity
/// policy, returning caller-owned storage. This is the preparation edge
/// used when another owner must project the exact value the Host retains.
pub fn prepareAdvertisedLocator(
    self: *Host,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) !model.PeerLocator {
    try admission.admitConfigurationMutation(self);
    if ((try self.transportProfile(locator.transport)).dial_shape == .route_bundle)
        return HostError.UnknownTransport;
    if (try designatorScheme(self, locator.transport) == .key)
        try sessions.refuseUnheldIdentity(self, locator.designator);
    var hint_storage: engine.Peer.HelloHints = .{};
    defer hint_storage.deinit(self.allocator);
    const complete = try hint_storage.extend(self.allocator, locator, .{
        .captp_version = self.opts.captp_version,
        .codec = self.opts.codec,
        .features = self.opts.features,
    }, false);
    return model.clonePeerLocator(allocator, complete);
}

/// Retain an already prepared locator without changing acceptable-location
/// policy. The caller retains ownership; the node deep-copies it.
pub fn retainPreparedAdvertisedLocator(self: *Host, locator: model.PeerLocator) !void {
    try admission.admitConfigurationMutation(self);
    try self.node.retainAdvertisedLocator(locator);
}

/// Complete and retain a route without selecting it.
pub fn retainAdvertisedLocator(self: *Host, locator: model.PeerLocator) !void {
    const complete = try prepareAdvertisedLocator(self, self.allocator, locator);
    defer model.freePeerLocator(self.allocator, complete);
    try retainPreparedAdvertisedLocator(self, complete);
}

/// Publish and select this node's complete acceptable location. The node
/// retains snapshots for other transports so deployment policy can select
/// a different route later (ADR-0109).
pub fn setAdvertisedLocator(self: *Host, locator: model.PeerLocator) !void {
    const complete = try prepareAdvertisedLocator(self, self.allocator, locator);
    defer model.freePeerLocator(self.allocator, complete);
    try self.node.setAdvertisedLocator(complete);
}

/// Retain the dial-only default for `transport` once, if an adapter has
/// not already supplied a complete locator. This does not displace an
/// acceptable location already selected for another transport. It becomes
/// the selection only when the node has none. Key transports use this
/// node's public key. Address transports use the unreachable-client
/// placeholder; a reachable adapter must publish its complete locator.
pub fn ensureAdvertisedLocator(self: *Host, transport: []const u8) !void {
    try admission.admitConfigurationMutation(self);
    if ((try self.transportProfile(transport)).dial_shape == .route_bundle)
        return HostError.UnknownTransport;
    var key_designator: [crypto.PeerKey.designator_len]u8 = undefined;
    const designator = switch (try designatorScheme(self, transport)) {
        .key => blk: {
            key_designator = self.node.secretKey().publicKey().toDesignator();
            break :blk key_designator[0..];
        },
        .address => vocab.unreachable_client_designator,
    };
    var hint_storage: engine.Peer.HelloHints = .{};
    defer hint_storage.deinit(self.allocator);
    const complete = try hint_storage.extend(self.allocator, .{
        .transport = transport,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .{
        .captp_version = self.opts.captp_version,
        .codec = self.opts.codec,
        .features = self.opts.features,
    }, false);
    try self.node.ensureAdvertisedLocator(complete);
}

/// Stop retaining a locator for `transport`. If it was selected, the node
/// has no acceptable location until one is explicitly set or ensured;
/// another retained route is never selected by map iteration order.
/// Already-open sessions keep the hello snapshot they signed when opened.
pub fn removeAdvertisedLocator(self: *Host, transport: []const u8) error{ ReenteredHost, WrongThread, HostClosing }!void {
    try admission.admitConfigurationMutation(self);
    self.node.removeAdvertisedLocator(transport);
}

/// Retire a route while unwinding or closing the driver operation that
/// owned it. Unlike the application verb above, terminal cleanup remains
/// legal after Host admission is sealed.
pub fn retireAdvertisedLocator(self: *Host, transport: []const u8) void {
    admission.assertOwner(self);
    self.node.removeAdvertisedLocator(transport);
}

/// Select a complete locator already retained for `transport`. This is the
/// allocation-free policy operation used when a host has several active
/// listener routes. Returns false when no such route is retained.
pub fn selectAdvertisedLocator(self: *Host, transport: []const u8) HostError!bool {
    try admission.admitConfigurationMutation(self);
    return self.node.selectAdvertisedLocator(transport);
}

/// Borrow this node's published locator for `transport`.
pub fn advertisedLocator(self: *const Host, transport: []const u8) ?model.PeerLocator {
    return self.node.advertisedLocator(transport);
}

/// Define the complete semantics of a transport for this Host. Definitions
/// are immutable and live until Host teardown; provider occupancy belongs
/// to the I/O-owning driver, so removing a provider cannot erase semantics
/// from a still-live session. Repeating the same definition is idempotent.
pub fn defineTransport(
    self: *Host,
    profile: model.transport.Metadata,
) error{ OutOfMemory, TransportSemanticsConflict, InvalidTransportName, WrongThread }![]const u8 {
    var canonical: [1][]const u8 = undefined;
    try defineTransports(self, &.{profile}, &canonical);
    return canonical[0];
}

/// Define a package's transport semantics as one transaction. Validation,
/// map capacity, and owned symbol bytes are complete before the first
/// profile becomes visible; `canonical` receives Host-owned names.
pub fn defineTransports(
    self: *Host,
    profiles: []const model.transport.Metadata,
    canonical: [][]const u8,
) error{ OutOfMemory, TransportSemanticsConflict, InvalidTransportName, WrongThread }!void {
    try admission.checkOwnerIfClaimed(self);
    std.debug.assert(canonical.len == profiles.len);
    const Addition = struct {
        profile: model.transport.Metadata,
        owned_symbol: ?[]u8 = null,
    };
    const additions = try self.allocator.alloc(Addition, profiles.len);
    defer self.allocator.free(additions);
    var addition_count: usize = 0;

    for (profiles) |profile| {
        model.transport.validateSymbol(profile.symbol) catch return error.InvalidTransportName;
        if (model.transport.parseKnown(profile.symbol)) |known| {
            const known_profile = known.metadata();
            if (!known_profile.eql(profile)) return error.TransportSemanticsConflict;
            continue;
        }
        if (self.transport_profiles.get(profile.symbol)) |existing| {
            if (!existing.eql(profile)) return error.TransportSemanticsConflict;
            continue;
        }
        var already_added = false;
        for (additions[0..addition_count]) |addition| {
            if (!std.mem.eql(u8, addition.profile.symbol, profile.symbol)) continue;
            if (!addition.profile.eql(profile)) return error.TransportSemanticsConflict;
            already_added = true;
            break;
        }
        if (already_added) continue;
        additions[addition_count] = .{ .profile = profile };
        addition_count += 1;
    }

    const map_additions = std.math.cast(u32, addition_count) orelse return error.OutOfMemory;
    try self.transport_profiles.ensureUnusedCapacity(self.allocator, map_additions);
    var owned_count: usize = 0;
    errdefer for (additions[0..owned_count]) |addition| self.allocator.free(addition.owned_symbol.?);
    for (additions[0..addition_count]) |*addition| {
        addition.owned_symbol = try self.allocator.dupe(u8, addition.profile.symbol);
        owned_count += 1;
    }
    for (additions[0..addition_count]) |addition| {
        var owned_profile = addition.profile;
        owned_profile.symbol = addition.owned_symbol.?;
        self.transport_profiles.putAssumeCapacity(owned_profile.symbol, owned_profile);
    }
    for (profiles, canonical) |profile, *name| {
        if (model.transport.parseKnown(profile.symbol)) |known| {
            name.* = known.metadata().symbol;
        } else {
            name.* = self.transport_profiles.get(profile.symbol).?.symbol;
        }
    }
}

pub fn transportProfile(self: *const Host, transport: []const u8) HostError!model.transport.Metadata {
    if (self.transport_profiles.get(transport)) |profile| return profile;
    if (model.transport.parseKnown(transport)) |known| return known.metadata();
    return HostError.UnknownTransport;
}

pub fn designatorScheme(self: *const Host, transport: []const u8) HostError!model.transport.DesignatorScheme {
    return (try transportProfile(self, transport)).designator_scheme;
}

/// Borrow the route subsequent hellos advertise, independent of the
/// transport carrying those sessions.
pub fn acceptableLocator(self: *const Host) ?model.PeerLocator {
    return self.node.acceptableLocator();
}
