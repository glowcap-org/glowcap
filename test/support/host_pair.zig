//! The byte-fed `driver_core.Host` pair harness shared by the driver
//! core-host tests: a dialed/accepted session pair, frame shuttling in both
//! directions, and a bounded pump to quiescence. A test whose pump must also
//! answer host actions (gift ids, parked dials) keeps that drain local and
//! interleaves it with `shuttleAll`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

pub const Pair = struct { ah: *Host, a: *HostSession, bh: *Host, b: *HostSession };

fn acceptsInbound(session: *const HostSession) bool {
    return switch (session.lifecyclePhase()) {
        .active, .finishing => true,
        .cancel_pending, .terminating => false,
    };
}

/// Move every queued frame across the pair, both directions; a feed error
/// surfaces to the caller (often the assertion under test).
pub fn shuttle(pair: Pair) !bool {
    var moved = false;
    while (try pair.a.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        if (acceptsInbound(pair.b)) try pair.bh.feed(pair.b, frame.view());
        moved = true;
    }
    while (try pair.b.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        if (acceptsInbound(pair.a)) try pair.ah.feed(pair.a, frame.view());
        moved = true;
    }
    return moved;
}

/// Move every queued frame across every wired pair, both directions. Returns
/// whether anything moved.
pub fn shuttleAll(pairs: []const Pair) !bool {
    var moved = false;
    for (pairs) |pair| {
        if (try shuttle(pair)) moved = true;
    }
    return moved;
}

/// Pump shuttles until the whole network is quiescent, bounded so a
/// ping-pong bug fails loud instead of spinning forever.
pub fn pumpToQuiescence(pairs: []const Pair) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        if (!try shuttleAll(pairs)) return;
    }
    return error.PumpDidNotQuiesce;
}

pub fn tcpLocator(designator: []const u8) model.PeerLocator {
    return .{ .transport = "tcp", .designator = designator, .hints = model.Hints.emptyFalse() };
}

/// Model a listener adapter in tests: publish its complete locator, then open
/// an accepted session from that snapshot.
pub fn publishAndOpenAccepted(host: *Host, transport: []const u8, designator: []const u8, direct_addresses: []const u8) !*HostSession {
    var entries: [1]model.HintEntry = undefined;
    try host.setAdvertisedLocator(.{
        .transport = transport,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses(direct_addresses, &entries),
    });
    return host.openAcceptedAdvertised(transport);
}

/// The adopted-peer counterpart to `publishAndOpenAccepted`.
pub fn publishAndOpenAcceptedOver(host: *Host, peer: *glowcap.ocapn.engine.Peer, transport: []const u8, designator: []const u8, direct_addresses: []const u8) !*HostSession {
    var entries: [1]model.HintEntry = undefined;
    try host.setAdvertisedLocator(.{
        .transport = transport,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses(direct_addresses, &entries),
    });
    return host.openAcceptedAdvertisedOver(peer, transport);
}

/// Open a dialed/accepted pair between two hosts and drive the keyed
/// handshake open over fed bytes (shuttle-only; no host actions expected).
pub fn openPair(dialer: *Host, acceptor: *Host, designator: []const u8) !Pair {
    try dialer.ensureAdvertisedLocator("tcp");
    try acceptor.setAdvertisedLocator(tcpLocator(designator));
    const accepted = try acceptor.openAcceptedAdvertised("tcp");
    const dialed = try dialer.openDialedLocator(tcpLocator(designator));
    const pair = Pair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpToQuiescence(&.{pair});
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
    return pair;
}
