//! Route completion at the Host seam: selected physical paths, authenticated
//! identity requirements, and route-advice publication after withdrawal.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const crypto = glowcap.foundation.crypto;
const Host = driver.core.Host;

const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const tcpLocator = harness.tcpLocator;
const ParkedDial = harness.ParkedDial;
const openPair = harness.openPair;
const keyedDesignator = harness.keyedDesignator;
const nextRouteOptions = harness.nextRouteOptions;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const Pair = harness.Pair;
const pumpToQuiescence = harness.pumpToQuiescence;

test "core host: pending completion must match the selected physical route" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x5f)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.setAdvertisedLocator(tcpLocator("127.0.0.1:7599"));
    const staged = try host.node.stageDial("ocapn://127.0.0.1%3A7600.tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7601"));
    defer host.releaseSession(session) catch {};
    try std.testing.expectError(
        driver.core.HostError.PeerIdentityMismatch,
        host.exporterDialed(staged.pending, 0, session),
    );
    try std.testing.expect(host.pendingDial(staged.pending, 0) != null);
}

test "core host: id pending dial requires authenticated channel identity before caching exporter" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x60)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.setAdvertisedLocator(tcpLocator("127.0.0.1:7600"));
    const key = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x61))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh",
        .{ key[0..], key[0..] },
    );
    defer allocator.free(id_locator);

    const staged = try host.node.stageDial(id_locator);
    const ticket = staged.pending;
    const view = host.pendingDial(ticket, 0) orelse return error.MissingPendingDial;
    try std.testing.expectEqualStrings(model.transport.iroh, view.locator.transport);
    try std.testing.expect(view.demanded_partner_key != null);

    const session = try host.openDialedLocator(view.locator);
    defer host.releaseSession(session) catch {};
    try std.testing.expectError(
        driver.core.HostError.PeerIdentityUnverified,
        host.exporterDialed(ticket, 0, session),
    );
    try std.testing.expect(host.pendingDial(ticket, 0) != null);
}

test "core host: public dial completion refuses an authenticated accepted session" {
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x65));
    const remote_seed = @as([32]u8, @splat(0x66));
    var client = test_host.init(allocator, client_seed, nextRouteOptions());
    defer client.deinit();
    var remote = test_host.init(allocator, remote_seed, nextRouteOptions());
    defer remote.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const client_key = keyedDesignator(client_seed);
    const remote_key = keyedDesignator(remote_seed);
    const accepted = try publishAndOpenAccepted(&client, model.transport.iroh, &client_key, &.{});
    defer client.releaseSession(accepted) catch {};
    try remote.ensureAdvertisedLocator(model.transport.iroh);
    const dialed = try remote.openDialedLocator(.{
        .transport = model.transport.iroh,
        .designator = &client_key,
        .hints = model.Hints.emptyFalse(),
    });
    defer remote.releaseSession(dialed) catch {};
    try client.bindVerifiedChannelKey(accepted, &remote_key);
    try remote.bindVerifiedChannelKey(dialed, &client_key);
    const pair = Pair{ .ah = &remote, .a = dialed, .bh = &client, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &remote }, &.{pair}, &dials);
    try std.testing.expect(accepted.sessionOpen());

    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh",
        .{ remote_key[0..], remote_key[0..] },
    );
    defer allocator.free(id_locator);
    const staged = try client.node.stageDial(id_locator);

    try std.testing.expectError(
        driver.core.HostError.PeerIdentityMismatch,
        client.exporterDialed(staged.pending, 0, accepted),
    );
    try std.testing.expect(client.pendingDial(staged.pending, 0) != null);
}

test "core host: weak id fallback dials only its own concrete identity" {
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x62));
    const server_seed = @as([32]u8, @splat(0x63));
    var client = test_host.init(allocator, client_seed, nextRouteOptions());
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, nextRouteOptions());
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const outer_key = keyedDesignator(@as([32]u8, @splat(0x64)));
    const server_key = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, model.transport.keyed_tcp, &server_key, &.{});
    try client.ensureAdvertisedLocator(model.transport.keyed_tcp);
    const locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh&alt-locators=ocapn%3A%2F%2F{s}.keyed-tcp",
        .{ outer_key[0..], outer_key[0..], server_key[0..] },
    );
    defer allocator.free(locator);

    const staged = try client.node.stageDial(locator);
    const ticket = staged.pending;
    _ = try client.nextAction();
    try client.dialFailed(ticket, 0, "identity route unavailable");
    _ = try client.nextAction();
    const weak = client.pendingDial(ticket, 1) orelse return error.MissingPendingDial;
    try std.testing.expectEqualStrings(model.transport.keyed_tcp, weak.locator.transport);
    try std.testing.expect(weak.demanded_partner_key == null);
    try std.testing.expect(!weak.authenticated_partner_required);

    const dialed = try client.openPendingDial(ticket, 1) orelse return error.MissingPendingDial;
    const demanded = dialed.served.port.peer.demandedPartnerKey() orelse return error.MissingDemandedKey;
    try std.testing.expect(demanded.eql(crypto.PeerKey.fromDesignator(server_key[0..]).?));
    try std.testing.expect(!demanded.eql(crypto.PeerKey.fromDesignator(outer_key[0..]).?));

    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(try client.exporterDialed(ticket, 1, dialed));
    try std.testing.expect(client.pendingDial(ticket, 1) == null);
}

test "core host: baseline introducing sessions cannot redeem id vocabulary out of band" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x72)), nextRouteOptions());
    defer client.deinit();
    var introducer = test_host.init(allocator, @as([32]u8, @splat(0x73)), Host.Options.withFrameCap(frame_cap));
    defer introducer.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const introducing_pair = try openPair(allocator, &client, &introducer, "127.0.0.1:7603", &dials);
    const exporter_key = keyedDesignator(@as([32]u8, @splat(0x74)));
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh",
        .{ exporter_key[0..], exporter_key[0..] },
    );
    defer allocator.free(id_locator);

    try introducing_pair.a.served.port.peer.session_state.installOutboundAnswer(.from(47));
    try std.testing.expectError(
        error.FeatureNotNegotiated,
        client.acceptGive(introducing_pair.a, 47, "give-id", id_locator),
    );
    try std.testing.expect((try client.nextAction()) == null);
}

test "core host: a malformed id give cannot retain route advice" {
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x77));
    const exporter_seed = @as([32]u8, @splat(0x78));
    var client = test_host.init(allocator, client_seed, nextRouteOptions());
    defer client.deinit();
    var exporter = test_host.init(allocator, exporter_seed, nextRouteOptions());
    defer exporter.deinit();
    var introducer = test_host.init(allocator, @as([32]u8, @splat(0x79)), nextRouteOptions());
    defer introducer.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const introducing_pair = try openPair(allocator, &client, &introducer, "127.0.0.1:7602", &dials);
    const client_key = keyedDesignator(client_seed);
    const exporter_key = keyedDesignator(exporter_seed);
    const accepted = try publishAndOpenAccepted(&exporter, model.transport.iroh, &exporter_key, &.{});
    try client.ensureAdvertisedLocator(model.transport.iroh);

    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh&alt-locators=ocapn%3A%2F%2Fbaseline-service.onion",
        .{ exporter_key[0..], exporter_key[0..] },
    );
    defer allocator.free(id_locator);
    // Model the pending introducing question on both ends of the session.
    try introducing_pair.a.served.port.peer.session_state.installOutboundAnswer(.from(46));
    try introducing_pair.b.served.port.peer.session_state.installInboundAnswer(.from(46));
    try client.acceptGive(introducing_pair.a, 46, "give-id", id_locator);
    const action = (try client.nextAction()).?;
    try std.testing.expect(action == .dial);

    const dialed = try client.openPendingDial(action.dial.ticket, 0) orelse return error.MissingPendingDial;
    try client.bindVerifiedChannelKey(dialed, &exporter_key);
    try exporter.bindVerifiedChannelKey(accepted, &client_key);
    const exporter_pair = Pair{ .ah = &client, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(
        allocator,
        &.{ &client, &exporter, &introducer },
        &.{ introducing_pair, exporter_pair },
        &dials,
    );
    _ = try client.exporterDialed(action.dial.ticket, 0, dialed);

    try std.testing.expect(client.node.gifts.recipe.by_exporter.get(dialed.peer_handle) == null);
}
