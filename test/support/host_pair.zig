//! The byte-fed `driver_core.Host` pair harness shared by the driver
//! core-host tests: a dialed/accepted session pair, frame shuttling in both
//! directions, and a bounded pump to quiescence. A test whose pump must also
//! answer host actions (gift ids, parked dials) keeps that drain local and
//! interleaves it with `shuttleAll`.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

pub const Pair = struct { ah: *Host, a: *HostSession, bh: *Host, b: *HostSession };

/// Move every queued frame across the pair, both directions; a feed error
/// surfaces to the caller (often the assertion under test).
pub fn shuttle(pair: Pair) !bool {
    var moved = false;
    while (try pair.a.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try pair.bh.feed(pair.b, frame.view());
        moved = true;
    }
    while (try pair.b.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try pair.ah.feed(pair.a, frame.view());
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

/// Open a dialed/accepted pair between two hosts and drive the keyed
/// handshake open over fed bytes (shuttle-only; no host actions expected).
pub fn openPair(dialer: *Host, acceptor: *Host, designator: []const u8) !Pair {
    const accepted = try acceptor.openAccepted("tcp", designator, &.{});
    const dialed = try dialer.openDialedLocator(tcpLocator(designator));
    const pair = Pair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpToQuiescence(&.{pair});
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
    return pair;
}
