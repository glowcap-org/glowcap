//! One session per partner: crossed hellos condemn one loser per advertised
//! snapshot, duplicate dials refuse, partner-side indexes empty on release,
//! an authenticated channel collapses a crossed pair, and a sturdyref
//! survives restart.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../../support/core_host.zig");
const promise_capture = @import("../../support/capture.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const stream_framing = pancake.foundation.stream_framing;

const harness = @import("harness.zig");
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

test "core host: a crossed-hellos loser refuses every verb condemned; release still works" {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, @as([32]u8, @splat(0x3a)), Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0x3b)), Host.Options.withFrameCap(frame_cap));
    defer b.deinit();

    // Both sides dial the same partner designator: a's outbound dial is
    // registered when b's hello (signing that same designator as its own
    // dialable address) arrives on a's accepted connection, so the tiebreak
    // condemns exactly one of a's two connections.
    const designator = "127.0.0.1:7001";
    try a.ensureAdvertisedLocator("tcp");
    try b.setAdvertisedLocator(tcpLocator(designator));
    const a_dialed = try a.openDialedLocator(tcpLocator(designator));
    const a_accepted = try publishAndOpenAccepted(&a, "tcp", "127.0.0.1:7002", &.{});
    const b_dialed = try b.openDialedLocator(tcpLocator("127.0.0.1:7002"));

    var hello = (try b_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try a.feed(a_accepted, hello.view());
    const condemned = if (a_accepted.isTerminating()) a_accepted else a_dialed;
    try std.testing.expect(condemned.isTerminating());

    // Every verb that rides the condemned connection refuses, uniformly.
    const target = model.Reference{ .far = model.FarRef.object(1) };
    const condemned_err = driver.core.HostError.SessionCondemned;
    try std.testing.expectError(condemned_err, a.feed(condemned, .{ .bytes = "", .shape = .byte }));
    try std.testing.expectError(condemned_err, a.feedBytes(condemned, "x"));
    try std.testing.expectError(condemned_err, a.send(condemned, target, .{ .verb = "poke", .args = &.{} }));
    try std.testing.expectError(condemned_err, a.tell(condemned, target, .{ .verb = "poke", .args = &.{} }));
    try std.testing.expectError(condemned_err, a.fetch(condemned, "widget"));
    try std.testing.expectError(condemned_err, a.enliven(condemned, tcpSturdyref(designator, "widget")));
    try std.testing.expectError(condemned_err, a.exporterDialed(0, condemned));
    try std.testing.expectError(condemned_err, a.breakFarVows(condemned, "gone"));
    try std.testing.expectError(condemned_err, a.setExporterLocation(condemned, null));

    // The queued typed abort still drains — the embedder writes it before
    // closing — and the release path stays ungated.
    var abort_frame = (try condemned.takeOutbound()) orelse return error.MissingAbort;
    abort_frame.deinit();
    try a.releaseSession(condemned);
}

test "core host: a second dial to the same partner refuses SessionPairExists" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x3c)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const designator = "127.0.0.1:7011";
    try host.ensureAdvertisedLocator("tcp");
    const first = try host.openDialedLocator(tcpLocator(designator));
    try std.testing.expectError(driver.core.HostError.SessionPairExists, host.openDialedLocator(tcpLocator(designator)));

    // Crossed hellos may still open an accepted session beside the dial.
    _ = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7012", &.{});

    // After release, a fresh dial to the same partner is admitted again.
    try host.releaseSession(first);
    const again = try host.openDialedLocator(tcpLocator(designator));
    try host.releaseSession(again);
}

test "core host: transport loss unindexes a retained session before reconnect" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x6c)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const designator = "127.0.0.1:7013";
    try host.ensureAdvertisedLocator("tcp");
    const lost = try host.openDialedLocator(tcpLocator(designator));
    try host.transportClosed(lost, "transport gone");

    // The wrapper may retain the dead shell until it drains CLOSE. Physical
    // loss must nevertheless release the dial authority immediately.
    const reconnected = try host.openDialedLocator(tcpLocator(designator));
    try host.releaseSession(reconnected);
    try host.releaseSession(lost);
}

test "core host: equal designators on different transports remain distinct dials" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x5c)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    _ = try host.defineTransport(.{ .symbol = "test-alt", .designator_scheme = .address });

    const designator = "shared-endpoint";
    try host.ensureAdvertisedLocator("tcp");
    try host.ensureAdvertisedLocator("test-alt");
    const tcp = try host.openDialedLocator(.{
        .transport = "tcp",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    const alternate = try host.openDialedLocator(.{
        .transport = "test-alt",
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });

    try std.testing.expectEqual(tcp, host.dialedSessionFor("tcp", designator).?);
    try std.testing.expectEqual(alternate, host.dialedSessionFor("test-alt", designator).?);
    try host.releaseSession(tcp);
    try host.releaseSession(alternate);
}

test "core host: accepted tcp session's declared designator does not squat dial availability" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x3d)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x3e)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    try client.setAdvertisedLocator(tcpLocator("127.0.0.1:7013"));
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7014", &dials);
    // Server learned the client's self-declared tcp designator; that claim is
    // not verified ownership of the address, so a dial to it is admitted.
    // Post-handshake partner-key refuse settles the duplicate when the new
    // session's start-session arrives (ADR-0012).
    const back = try server.openDialedLocator(tcpLocator("127.0.0.1:7013"));
    try std.testing.expect(!back.isTerminating());
    try client.releaseSession(pair.a);
    try server.releaseSession(pair.b);
    try server.releaseSession(back);
}

test "core host: keyed dial to a verified partner session key refuses SessionPairExists" {
    const allocator = std.testing.allocator;

    const partner_seed = @as([32]u8, @splat(0x51));
    const partner_key = crypto.SecretKey.fromSeed(partner_seed).publicKey();
    const designator = partner_key.toDesignator();
    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "ocapn://{s}.iroh", .{designator[0..]});

    var dialer = test_host.init(allocator, @as([32]u8, @splat(0x52)), Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = test_host.init(allocator, partner_seed, Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const accepted = try publishAndOpenAccepted(&acceptor, "iroh", designator[0..], &.{});
    try dialer.ensureAdvertisedLocator("iroh");
    const loc = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc);
    const first = try dialer.openDialedLocator(loc);
    const pair = Pair{ .ah = &dialer, .a = first, .bh = &acceptor, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
    try std.testing.expect(first.sessionOpen());

    // Same key designator while the verified session is live: dial-time refuse.
    const loc_again = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc_again);
    try std.testing.expectError(
        driver.core.HostError.SessionPairExists,
        dialer.openDialedLocator(loc_again),
    );
    try dialer.releaseSession(first);
    try acceptor.releaseSession(accepted);
}

test "core host: dual accept settlement condemns the second session to the same partner key" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x3f)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = test_host.init(allocator, @as([32]u8, @splat(0x40)), Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7015", &.{});
    const second = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7016", &.{});
    // One peer hello fed to both accepted sessions: the first keeps the
    // partner key; the second is condemned at start-session (ADR-0012).
    try peer.ensureAdvertisedLocator("tcp");
    const peer_dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7015"));
    var hello = (try peer_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try host.feed(first, hello.view());
    try std.testing.expect(!first.isTerminating());
    try std.testing.expect(first.sessionOpen());
    try host.feed(second, hello.view());
    try std.testing.expect(second.isTerminating());
    try std.testing.expect(!second.sessionOpen());
    try host.releaseSession(first);
    try host.releaseSession(second);
    try peer.releaseSession(peer_dialed);
}

test "core host: partner-side index empties after enroll, learn, condemn, and release" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x53)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = test_host.init(allocator, @as([32]u8, @splat(0x54)), Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7020", &.{});
    const second = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7021", &.{});
    try peer.ensureAdvertisedLocator("tcp");
    const peer_dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7020"));
    var hello = (try peer_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try host.feed(first, hello.view());
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_side.count());
    try host.feed(second, hello.view());
    try std.testing.expect(second.isTerminating());
    try host.releaseSession(second);
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_side.count());
    try host.releaseSession(first);
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), host.dialed_by_target.count());
    try peer.releaseSession(peer_dialed);
}

test "core host: a burst of accepts before any start-session indexes every partner side without overflow" {
    // Regression (ADR-0012): `partner_by_side` reserves at its own insert
    // (`indexPartnerKey`), not at mint. A partner key is unknown until that
    // partner's `op:start-session` arrives, so every session minted before a
    // single start-session is fed stays un-indexed — a mint-time reservation
    // would never grow the map across those mints and would overflow
    // `putAssumeCapacity` once the burst passed the map's usable capacity.
    const allocator = std.testing.allocator;
    const n = 8; // past AutoHashMap's minimal usable capacity, the old overflow point
    var host = test_host.init(allocator, @as([32]u8, @splat(0x60)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var peers: [n]Host = undefined;
    var peers_inited: usize = 0;
    defer for (peers[0..peers_inited]) |*p| p.deinit();

    var accepted: [n]*HostSession = undefined;
    var dialed: [n]*HostSession = undefined;

    // Mint every accepted session (and its dialing partner) first: the whole
    // burst is un-indexed before one start-session is fed.
    for (0..n) |i| {
        peers[i] = test_host.init(allocator, @as([32]u8, @splat(@as(u8, @intCast(0x61 + i)))), Host.Options.withFrameCap(frame_cap));
        peers_inited += 1;
        var buf: [24]u8 = undefined;
        const designator = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{7100 + i});
        accepted[i] = try publishAndOpenAccepted(&host, "tcp", designator, &.{});
        try peers[i].ensureAdvertisedLocator("tcp");
        dialed[i] = try peers[i].openDialedLocator(tcpLocator(designator));
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());

    // Feed each partner's hello: each learns a distinct partner key and indexes
    // a fresh row. Under the mint-reservation bug the 7th insert overflowed the
    // 6 usable slots the single effective reservation had pinned.
    for (0..n) |i| {
        var hello = (try dialed[i].takeOutbound()) orelse return error.MissingHello;
        defer hello.deinit();
        try host.feed(accepted[i], hello.view());
        try std.testing.expect(accepted[i].sessionOpen());
        try std.testing.expect(!accepted[i].isTerminating());
    }
    try std.testing.expectEqual(@as(usize, n), host.partner_by_side.count());

    for (0..n) |i| {
        try host.releaseSession(accepted[i]);
        try peers[i].releaseSession(dialed[i]);
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());
}

test "session identity: crossed-hello ordering is per session over one advertised snapshot" {
    // ADR-0097 evidence item 9. The tiebreak is two operations over two
    // different identities, and fresh session keys are what force them apart:
    //
    //   * matching asks *which two attempts are racing*, and that is a
    //     question about the durable peer — both attempts name the same one;
    //   * ordering asks *which one survives*, and that is a question about
    //     session identity — the two sessions' own keys.
    //
    // While every session reused its host's durable key one value answered
    // both, so the split was invisible and a wrong reading still worked. Here
    // each host draws per-session keys, so the durable identities are equal on
    // both racing attempts and cannot order anything; only the session ids
    // can. Both ends must still converge on the same survivor.
    const allocator = std.testing.allocator;
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, @as([32]u8, @splat(0x01)), a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0xff)), b_opts);
    defer b.deinit();

    // Each side accepts on the address the other dials, so both crossed-hellos
    // tables match by durable peer and each end runs the tiebreak itself.
    const a_accept = try publishAndOpenAccepted(&a, "tcp", "127.0.0.1:9100", &.{});
    const b_accept = try publishAndOpenAccepted(&b, "tcp", "127.0.0.1:9101", &.{});
    const a_dialed = try a.openDialedLocator(tcpLocator("127.0.0.1:9101"));
    const b_dialed = try b.openDialedLocator(tcpLocator("127.0.0.1:9100"));

    // The teeth: no session's signing key is its host's durable key, so a
    // tiebreak reading durable keys would be comparing values this race never
    // uses — and, being equal across both of a host's sessions, could not
    // order them anyway. These assertions fail under key reuse.
    const a_durable = crypto.derivePublicIdentifier(a.node.secretKey().publicKey());
    const b_durable = crypto.derivePublicIdentifier(b.node.secretKey().publicKey());
    const a_dial_id = crypto.derivePublicIdentifier(a_dialed.sessionSecret().publicKey());
    const b_dial_id = crypto.derivePublicIdentifier(b_dialed.sessionSecret().publicKey());
    try std.testing.expect(!std.mem.eql(u8, &a_dial_id.bytes, &a_durable.bytes));
    try std.testing.expect(!std.mem.eql(u8, &b_dial_id.bytes, &b_durable.bytes));
    // And a host's own two connections differ from each other, which is what
    // makes "which session" a real question rather than a restatement of
    // "which host".
    const a_accept_id = crypto.derivePublicIdentifier(a_accept.sessionSecret().publicKey());
    try std.testing.expect(!std.mem.eql(u8, &a_dial_id.bytes, &a_accept_id.bytes));

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    // Each dialed hello lands on the peer's accepted session. Because dial and
    // accept now advertise the same Node snapshot, both crossed-hello tables
    // match and independently condemn the same physical connection. Only a
    // surviving dialed half may consume its partner's accepted hello.
    try b.feed(b_accept, a_hello.view());
    try a.feed(a_accept, b_hello.view());
    if (!b_dialed.isTerminating()) try b.feed(b_dialed, a_accept_hello.view());
    if (!a_dialed.isTerminating()) try a.feed(a_dialed, b_accept_hello.view());

    try std.testing.expect(a_accept.isTerminating() != a_dialed.isTerminating());
    try std.testing.expect(b_accept.isTerminating() != b_dialed.isTerminating());
    try std.testing.expectEqual(a_accept.isTerminating(), b_dialed.isTerminating());
    try std.testing.expectEqual(a_dialed.isTerminating(), b_accept.isTerminating());

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

test "core host: crossed hellos match the advertised route across different channel transports" {
    const allocator = std.testing.allocator;
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, @as([32]u8, @splat(0x11)), a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0xee)), b_opts);
    defer b.deinit();
    _ = try a.defineTransport(.{ .symbol = "test-alt", .designator_scheme = .address });
    _ = try b.defineTransport(.{ .symbol = "test-alt", .designator_scheme = .address });

    const a_locator: model.PeerLocator = .{
        .transport = "test-alt",
        .designator = "a-alt",
        .hints = model.Hints.emptyFalse(),
    };
    const b_locator = tcpLocator("127.0.0.1:9111");
    try a.setAdvertisedLocator(a_locator);
    try b.setAdvertisedLocator(b_locator);

    // A reaches B over TCP while B reaches A over test-alt. Each inbound
    // channel therefore differs from the transport in the partner's hello.
    const a_dialed = try a.openDialedLocator(b_locator);
    const b_accept = try b.openAcceptedAdvertised("tcp");
    const b_dialed = try b.openDialedLocator(a_locator);
    const a_accept = try a.openAcceptedAdvertised("test-alt");

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    try a.feed(a_accept, b_hello.view());
    try b.feed(b_accept, a_hello.view());
    if (!a_dialed.isTerminating()) try a.feed(a_dialed, b_accept_hello.view());
    if (!b_dialed.isTerminating()) try b.feed(b_dialed, a_accept_hello.view());

    try std.testing.expect(a_accept.isTerminating() != a_dialed.isTerminating());
    try std.testing.expect(b_accept.isTerminating() != b_dialed.isTerminating());
    try std.testing.expectEqual(a_accept.isTerminating(), b_dialed.isTerminating());
    try std.testing.expectEqual(a_dialed.isTerminating(), b_accept.isTerminating());

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

const CrossedPairProof = enum { none, authenticated_channel };

/// Exercise the same fresh-key crossed pair with and without realizer proof.
/// Four distinct session keys make the durable-peer directory the only possible
/// cross-connection match; a bare key designator cannot populate it, while a
/// channel-authenticated durable key can.
fn expectFreshKeyCrossedPair(transport: []const u8, proof: CrossedPairProof) !void {
    const allocator = std.testing.allocator;
    const a_seed = @as([32]u8, @splat(0x01));
    const b_seed = @as([32]u8, @splat(0xff));
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, a_seed, a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, b_seed, b_opts);
    defer b.deinit();

    const a_designator = crypto.SecretKey.fromSeed(a_seed).publicKey().toDesignator();
    const b_designator = crypto.SecretKey.fromSeed(b_seed).publicKey().toDesignator();

    const a_direct: []const u8 = if (std.mem.eql(u8, transport, "keyed-tcp")) "127.0.0.1:9200" else &.{};
    const b_direct: []const u8 = if (std.mem.eql(u8, transport, "keyed-tcp")) "127.0.0.1:9201" else &.{};
    const a_accept = try publishAndOpenAccepted(&a, transport, a_designator[0..], a_direct);
    const b_accept = try publishAndOpenAccepted(&b, transport, b_designator[0..], b_direct);
    const a_dialed = try a.openDialedLocator(.{
        .transport = transport,
        .designator = b_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    const b_dialed = try b.openDialedLocator(.{
        .transport = transport,
        .designator = a_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });

    if (proof == .authenticated_channel) {
        try a.bindVerifiedChannelKey(a_accept, &b_designator);
        try a.bindVerifiedChannelKey(a_dialed, &b_designator);
        try b.bindVerifiedChannelKey(b_accept, &a_designator);
        try b.bindVerifiedChannelKey(b_dialed, &a_designator);
    }

    const ids = [_][32]u8{
        crypto.derivePublicIdentifier(a_accept.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(a_dialed.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(b_accept.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(b_dialed.sessionSecret().publicKey()).bytes,
    };
    for (ids, 0..) |left, i| {
        for (ids[i + 1 ..]) |right| try std.testing.expect(!std.mem.eql(u8, &left, &right));
    }

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    try b.feed(b_accept, a_hello.view());
    try a.feed(a_accept, b_hello.view());
    try b.feed(b_dialed, a_accept_hello.view());
    try a.feed(a_dialed, b_accept_hello.view());

    switch (proof) {
        .none => {
            try std.testing.expect(!a_accept.isTerminating() and !a_dialed.isTerminating());
            try std.testing.expect(!b_accept.isTerminating() and !b_dialed.isTerminating());
        },
        .authenticated_channel => {
            try std.testing.expect(a_accept.isTerminating() != a_dialed.isTerminating());
            try std.testing.expect(b_accept.isTerminating() != b_dialed.isTerminating());
            try std.testing.expectEqual(a_accept.isTerminating(), b_dialed.isTerminating());
            try std.testing.expectEqual(a_dialed.isTerminating(), b_accept.isTerminating());
        },
    }

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

test "session identity: raw keyed transport cannot collapse crossed locator claims" {
    try expectFreshKeyCrossedPair("keyed-tcp", .none);
}

test "session identity: authenticated channel collapses a crossed pair to one shared survivor" {
    try expectFreshKeyCrossedPair("iroh", .authenticated_channel);
}

test "durable publication: a sturdyref issued before a restart still names a live object after it" {
    // What "durable bootstrap" actually requires of the library, and where the
    // storage belongs. The core is sync and no-I/O, so it cannot own a file;
    // what it owes instead is that a durable name be *reproducible*, and
    // `mintDurableSwiss` is a pure function of the caller's 16 entropy bytes.
    // An embedder that keeps those bytes therefore rebuilds the identical
    // sturdyref after a restart, and re-binds it to a freshly spawned actor.
    // The persistence is the embedder's, which is the only place it can be.
    const allocator = std.testing.allocator;
    const seed = @as([32]u8, @splat(0x7d));
    const entropy = @as([engine.durable_swiss_entropy_len]u8, @splat(0x5e));

    // Before the restart: publish, and keep the sturdyref a caller was handed.
    var issued: [engine.durable_swiss_len]u8 = undefined;
    {
        var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
        defer host.deinit();
        const swiss = try host.publishDurable(entropy, Widget, .{});
        issued = swiss.bytes;
    }

    // The restart: a new process, the same durable identity, the same stored
    // entropy, a new actor behind the name.
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const rebound = try host.publishDurable(entropy, Widget, .{});

    // The name a caller is still holding resolves to the rebound object.
    try std.testing.expectEqualSlices(u8, &issued, &rebound.bytes);

    // And it is a live publication on this host, not merely an equal string:
    // a partner session fetching that swiss reaches the actor.
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7e)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7331", &dials);
    var captured = CapturedRef{};
    const vow = try client.fetch(pair.a, &issued);
    try client.vowOn(vow, .{ .ctx = &captured, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);
    _ = try captured.require();
}
