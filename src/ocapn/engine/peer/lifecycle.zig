//! Construction, posture, Node detachment, and teardown for one Peer.
//!
//! Peer remains the state aggregate. This module owns the only complete
//! constructor/retirement pairing and the Node-dependent authority retirement
//! that must run while projection callbacks are still valid.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const bootstrap = @import("../bootstrap.zig");
const engine = @import("../mod.zig");

const Peer = engine.Peer;

/// Negotiated knobs shared by construction and pre-byte adoption posture.
pub const NegotiatingOptions = struct {
    captp_version: model.CaptpVersion = model.Preference.default_offer.captp_version,
    codec: model.CodecId = model.Preference.default_offer.codec,
    features: model.FeatureSet = model.Preference.default_offer.features,
    limits: session.SessionLimits = .{},
    /// Verify the partner's `op:start-session` signature. Stub-key in-process
    /// fixtures are the only callers that disable it.
    verify_partner_handshake: bool = true,
    /// Shared staged-plus-encoded outbound ceiling. Null leaves a raw Peer
    /// unlimited until a Host installs its explicit waterline.
    outbound_high_water_bytes: ?usize = null,
    /// A fresh secret for this session's wire-keyed tables, mixed into the
    /// multiplier the node keyed at registration (ADR-0218). Null keeps the
    /// node's multiplier, for a peer no host postures.
    wire_hash_salt: ?u64 = null,
};

/// Peer over an already-open V1.0 Session. Real connections negotiate instead.
pub fn init(allocator: std.mem.Allocator) Peer {
    return initWithSession(allocator, session.Session.init(allocator));
}

/// Peer awaiting `op:start-session` on the V1.0/Syrup interoperability floor.
pub fn initNegotiating(allocator: std.mem.Allocator) Peer {
    return initNegotiatingWith(allocator, .{});
}

/// Construct a blank negotiating Peer and apply every option through the same
/// posture verb used by Host adoption. Export ranges remain Node-owned.
pub fn initNegotiatingWith(allocator: std.mem.Allocator, options: NegotiatingOptions) Peer {
    var peer = initWithSession(
        allocator,
        session.Session.initWith(allocator, .{ .negotiating = true }),
    );
    reposture(&peer, options);
    return peer;
}

/// Apply negotiating posture before the first byte moves.
pub fn reposture(self: *Peer, options: NegotiatingOptions) void {
    std.debug.assert(self.session_state.state == .negotiating);
    std.debug.assert(self.outbound.isEmpty() and self.pending_send.isEmpty());
    self.session_state.codec = options.codec;
    self.session_state.captp_version = options.captp_version;
    self.session_state.preferred = session.Session.preferenceOf(
        options.captp_version,
        options.codec,
        options.features,
    );
    self.session_state.features = options.features;
    self.session_state.limits = options.limits;
    if (options.wire_hash_salt) |salt| {
        self.session_state.keyWireTables(foundation.identity_hash.saltedMultiplier(
            self.session_state.wire_hash_multiplier,
            salt,
        ));
    }
    self.verify_partner_handshake = options.verify_partner_handshake;
    self.outbound_budget = options.outbound_high_water_bytes orelse std.math.maxInt(usize);
}

/// Adopt a caller-built Session. Peer owns it until `deinit`.
pub fn initWithSession(allocator: std.mem.Allocator, session_state: session.Session) Peer {
    return .{
        .allocator = allocator,
        .session_state = session_state,
        .inbound = .{},
        .pending_send = .{},
        .outbound = .{},
        .events = .{},
    };
}

/// Free every allocation still owned by the Peer, including queued carriers,
/// Node-dependent gifts, parked withdraws, and the authoritative Session.
pub fn deinit(self: *Peer) void {
    std.debug.assert(self.pending_send_reservations == 0);
    clearPendingWithdraws(self);
    detachNodeServices(self);
    for (self.inbound.pending()) |*frame| frame.deinit();
    self.inbound.deinit(self.allocator);

    for (self.pending_send.pending()) |*pending| pending.item.deinit(self);
    self.pending_send.deinit(self.allocator);

    for (self.outbound.pending()) |*frame| frame.deinit();
    self.outbound.deinit(self.allocator);

    for (self.events.pending()) |*event| event.deinit();
    self.events.deinit(self.allocator);

    self.gift_registry.deinit(self.allocator, localObjectProjection(self));
    self.session_state.deinit();
}

pub fn giftRegistry(self: *Peer) *bootstrap.gifts.GiftRegistry {
    return &self.gift_registry;
}

/// Exact Host-local gift projection when this Peer belongs to a Node.
pub fn localObjectProjection(self: *const Peer) ?bootstrap.gifts.LocalObjectProjection {
    const services = self.node_services orelse return null;
    return services.localObjectProjection();
}

pub fn gifterSessionResolver(self: *const Peer) ?bootstrap.gifts.GifterSessionResolver {
    const services = self.node_services orelse return null;
    return services.gifterSessionResolver();
}

pub fn pendingWithdrawCount(self: *const Peer) usize {
    return self.pending_withdraw_count;
}

pub fn pendingWithdrawCapacity(self: *const Peer) usize {
    return self.pending_withdraws.capacity();
}

/// Retire Node-dependent authority before severing the borrowed service link.
pub fn detachNodeServices(self: *Peer) void {
    const services = self.node_services orelse return;
    var dependencies = self.pending_withdraws.keyIterator();
    while (dependencies.next()) |dependency| services.pendingWithdrawRemoved(dependency.*);
    self.pending_handoff_change = null;
    retireGiftRegistry(self);
    self.node_services = null;
}

/// Retire every gift this session registered and leave an empty registry.
pub fn retireGiftRegistry(self: *Peer) void {
    self.gift_registry.deinit(self.allocator, self.localObjectProjection());
    self.gift_registry = .{};
}

/// Retire every parked receive and its scheduler registration. Kept public to
/// this internal module graph so the close/session-authority path can reuse the
/// exact teardown without acquiring another ownership walk.
pub fn clearPendingWithdraws(self: *Peer) void {
    const services = self.node_services;
    var groups = self.pending_withdraws.iterator();
    while (groups.next()) |entry| {
        if (services) |link| link.pendingWithdrawRemoved(entry.key_ptr.*);
        for (entry.value_ptr.rows.items) |*pending| pending.receive.deinit(self.allocator);
        entry.value_ptr.rows.deinit(self.allocator);
    }
    self.pending_withdraws.deinit(self.allocator);
    self.pending_withdraws = .empty;
    self.pending_withdraw_count = 0;
    self.pending_withdraw_bytes = 0;
    self.pending_handoff_change = null;
}
