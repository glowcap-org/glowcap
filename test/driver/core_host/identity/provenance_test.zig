//! Partner-identity provenance: each leg reports the fact it holds, an
//! embedder's channel testimony reaches both sides, and a session that
//! proved nothing reports nothing.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../../../support/core_host.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const stream_framing = pancake.foundation.stream_framing;

const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const FairCounter = harness.FairCounter;
const Vendor = harness.Vendor;
const Introducer = harness.Introducer;
const host_pair = harness.host_pair;
const handshake_support = harness.handshake_support;
const Pair = harness.Pair;
const shuttle = harness.shuttle;
const shuttleAll = harness.shuttleAll;
const tcpLocator = harness.tcpLocator;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const publishAndOpenAcceptedOver = harness.publishAndOpenAcceptedOver;
const tcpSturdyref = harness.tcpSturdyref;
const onionLocator = harness.onionLocator;
const onionSturdyref = harness.onionSturdyref;
const ParkedDial = harness.ParkedDial;
const drainActions = harness.drainActions;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;
const retireClosingSession = harness.retireClosingSession;
const retireClosedSession = harness.retireClosedSession;
const Tagged = harness.Tagged;
const keyedDesignator = harness.keyedDesignator;
const TraceLog = harness.TraceLog;

test "partner identity: each leg reports the fact it holds, not the transport's name" {
    // Provenance is selected by the evidence one session holds, never by its
    // transport symbol (ADR-0105). Both legs below run `iroh` and neither
    // reports the same thing, because they hold different evidence: the dialer
    // was handed a verified remote by the code that realized the connection,
    // and the acceptor has no channel proof.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x3c)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = @as([32]u8, @splat(0x3d));
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const designator = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, "iroh", &designator, &.{});
    try client.ensureAdvertisedLocator("iroh");
    const dialed = try client.openDialedLocator(.{
        .transport = "iroh",
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    // What the iroh adapter installs off the QUIC handshake; the byte-fed core
    // is handed the proof rather than inferring one.
    dialed.served.port.peer.bindVerifiedChannelKey(crypto.SecretKey.fromSeed(server_seed).publicKey());
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    const bound = try client.partnerIdentity(pair.a);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, bound.provenance);
    try std.testing.expect(bound.durableIdentityAuthenticated());

    // The acceptor had no realizer to hand it a verified remote, so the
    // dialer's key-shaped claim remains unauthenticated.
    const unproved = try server.partnerIdentity(pair.b);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, unproved.provenance);
    try std.testing.expect(!unproved.durableIdentityAuthenticated());
    try std.testing.expectEqualStrings(&keyedDesignator(@as([32]u8, @splat(0x3c))), unproved.designator);
}

test "verified channel key: an embedder's testimony reaches provenance on both legs" {
    // The test above is this topology with nobody to speak for the acceptor.
    // Here the embedder says what its own transport proved, which is what a binding
    // hosting its own iroh listener holds and had no way to state. Both legs,
    // because the proof belongs to the connection rather than to a direction.
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x4c));
    var client = test_host.init(allocator, client_seed, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = @as([32]u8, @splat(0x4d));
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const server_designator = keyedDesignator(server_seed);
    const client_designator = keyedDesignator(client_seed);
    const accepted = try publishAndOpenAccepted(&server, "iroh", &server_designator, &.{});
    try client.ensureAdvertisedLocator("iroh");
    const dialed = try client.openDialedLocator(.{
        .transport = "iroh",
        .designator = &server_designator,
        .hints = model.Hints.emptyFalse(),
    });

    try client.bindVerifiedChannelKey(dialed, &server_designator);
    try server.bindVerifiedChannelKey(accepted, &client_designator);
    // The same statement made twice is still that statement.
    try server.bindVerifiedChannelKey(accepted, &client_designator);
    // One connection has one far end, so a second name for it is refused
    // rather than allowed to overwrite the first.
    try std.testing.expectError(
        error.ChannelKeyConflict,
        server.bindVerifiedChannelKey(accepted, &server_designator),
    );
    // A realizer's proof names a key; an address transport has none to give.
    try std.testing.expectError(
        error.InvalidChannelKey,
        server.bindVerifiedChannelKey(accepted, "127.0.0.1:9000"),
    );

    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    // The acceptor now reports the channel proof.
    const accepted_identity = try server.partnerIdentity(pair.b);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, accepted_identity.provenance);
    const bound = try client.partnerIdentity(pair.a);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, bound.provenance);

    // Too late to be the evidence it was for: the chokepoint that weighs a
    // partner's claim has already run.
    try std.testing.expectError(
        error.HandshakeAlreadyApplied,
        server.bindVerifiedChannelKey(accepted, &client_designator),
    );
}

test "partner identity: a session that does not verify its partner reports no identity" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x2a)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .verify_partner = false,
    });
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x2b)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .verify_partner = false,
    });
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7003", &dials);

    try std.testing.expectEqual(@as(usize, 0), client.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), client.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), server.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), server.partner_by_side.count());

    // The handshake completed and a key did arrive, so there are bytes here to
    // hand back. They are refused anyway: nothing checked them, and a caller
    // that could read them would have no way to tell them from proof.
    try std.testing.expectError(error.PartnerUnverified, client.partnerIdentity(pair.a));
}

test "partner identity: a session whose partner has not spoken yet reports no identity" {
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, @as([32]u8, @splat(0x3b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();

    // Accepted, but no partner bytes have been fed, so no `op:start-session`
    // has arrived and there is no key yet.
    const accepted = try publishAndOpenAccepted(&server, "tcp", "127.0.0.1:7004", "");
    try std.testing.expectError(error.HandshakeIncomplete, server.partnerIdentity(accepted));
}
