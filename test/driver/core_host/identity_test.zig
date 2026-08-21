//! What identity each leg may claim: the keyed handshake proves session
//! continuity but not durable identity, and every session signs with its
//! own key.

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

test "core host: two hosts complete the keyed handshake over fed bytes" {
    const allocator = std.testing.allocator;
    var a = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
    defer b.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try openPair(allocator, &a, &b, "127.0.0.1:7001", &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
}

test "core host: keyed-tcp handshake leaves durable identity unauthenticated" {
    const allocator = std.testing.allocator;
    const acceptor_seed = @as([32]u8, @splat(0x2b));
    var dialer = test_host.init(allocator, @as([32]u8, @splat(0x2a)), Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = test_host.init(allocator, acceptor_seed, Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();

    const designator = crypto.SecretKey.fromSeed(acceptor_seed).publicKey().toDesignator();
    const accepted = try publishAndOpenAccepted(&acceptor, "keyed-tcp", designator[0..], "127.0.0.1:7777");
    try dialer.ensureAdvertisedLocator("keyed-tcp");
    const dialed = try dialer.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &dialer, .a = dialed, .bh = &acceptor, .b = accepted };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
}

test "core host: a host that never listens still advertises its key on a key transport" {
    // The defect a WebRTC direct message showed: a browser Host never starts a
    // listener, so it never sets a self designator, and its dialing hello
    // signed the unreachable-client placeholder. That is a `tcp` *address*, on
    // a transport whose designator grammar is a key, so the far end could
    // attribute nothing and every consumer downstream honestly reported that
    // it knew nobody.
    //
    // There is exactly one legal value here and the host can derive it, so it
    // does (`sessions.advertisedDesignator`). Held over `webrtc` because that
    // is where it was found, and the same derivation serves `iroh`,
    // `keyed-tcp`, and `keyed-relay`.
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x7a));
    const server_seed = @as([32]u8, @splat(0x7b));
    var client = test_host.init(allocator, client_seed, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    // The browser peer has no listener to publish an address from, and the
    // answering member is reached by signaling.
    const server_designator = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, "webrtc", &server_designator, &.{});
    try client.ensureAdvertisedLocator("webrtc");
    const dialed = try client.openDialedLocator(.{
        .transport = "webrtc",
        .designator = &server_designator,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());

    // The browser still advertises its key rather than an unreachable address,
    // but this byte-fed path supplies no channel proof for that claim.
    const client_designator = keyedDesignator(client_seed);
    const seen = try server.partnerIdentity(pair.b);
    try std.testing.expectEqualStrings(&client_designator, seen.designator);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    try std.testing.expect(!seen.durableIdentityAuthenticated());
}

test "core host: verified session directory authenticates an early handoff gifter" {
    const allocator = std.testing.allocator;
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x0d)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7003", &dials);
    const exporter_peer = pair.b.served.port.peer;
    const gifter_key = exporter_peer.session_state.partnerSessionKey().?;
    const exporter_key = exporter_peer.session_state.localSessionKey().?;
    const gifter_side = try engine.handoff_names.sideName(gifter_key);
    const exporter_side = try engine.handoff_names.sideName(exporter_key);
    const session_name = engine.handoff_names.sessionName(gifter_side, exporter_side);

    const resolver = exporter.node.gifterSessionResolver().?;
    const resolved = resolver.resolve(resolver.ctx, gifter_side, &session_name) orelse
        return error.MissingGifterKey;
    try std.testing.expectEqualSlices(u8, gifter_key, &resolved.key);
    try std.testing.expectEqual(exporter_peer.giftRegistry(), resolved.gifts);
    var wrong_session = session_name;
    wrong_session[0] ^= 0xff;
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side, &wrong_session) == null);

    try exporter.releaseSession(pair.b);
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side, &session_name) == null);
    try gifter.releaseSession(pair.a);
}

test "session identity: an old handoff certificate cannot resolve against a session opened after reconnect" {
    // ADR-0097 evidence item 10, the property fresh per-session keys exist to
    // provide. A `desc:handoff-give` names its gifter–exporter session by the
    // side names derived from both ends' session keys. While every session in a
    // host reused that host's durable key those names were a function of the
    // two *hosts*, so reconnecting the same pair rebuilt the identical names
    // and a stale certificate resolved against the replacement session. With a
    // key per session the names are a function of the session, and the
    // old certificate resolves against nothing.
    //
    // Liveness is deliberately not what makes this pass: a live session
    // between the same durable peers exists throughout the final assertions.
    // The sibling test above already covers "the session closed"; this one
    // covers "a different session is open in its place", which is the case
    // reconnect actually produces and the one key reuse got wrong.
    //
    // Out of scope, and stated rather than implied: replaying a whole captured
    // keyed-TCP hello can revive its own static session claim on another
    // cleartext connection. Fresh keys isolate *honest* reconnects; they do not
    // make a cleartext channel replay-safe, which ADR-0075 records.
    const allocator = std.testing.allocator;
    const opts = Host.Options.withFrameCap(frame_cap);
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x0c)), opts);
    defer gifter.deinit();
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x0d)), opts);
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    // The first connection, and the certificate names it would carry.
    const first = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7321", &dials);
    const first_peer = first.b.served.port.peer;
    const old_gifter_side = try engine.handoff_names.sideName(first_peer.session_state.partnerSessionKey().?);
    const old_exporter_side = try engine.handoff_names.sideName(first_peer.session_state.localSessionKey().?);
    const old_session = engine.handoff_names.sessionName(old_gifter_side, old_exporter_side);

    const resolver = exporter.node.gifterSessionResolver().?;
    try std.testing.expect(resolver.resolve(resolver.ctx, old_gifter_side, &old_session) != null);

    // Honest reconnect: both halves go away and the same two hosts, with the
    // same durable identities, open a fresh connection.
    try exporter.releaseSession(first.b);
    try gifter.releaseSession(first.a);
    const second = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7322", &dials);
    const second_peer = second.b.served.port.peer;
    const new_gifter_side = try engine.handoff_names.sideName(second_peer.session_state.partnerSessionKey().?);
    const new_exporter_side = try engine.handoff_names.sideName(second_peer.session_state.localSessionKey().?);
    const new_session = engine.handoff_names.sessionName(new_gifter_side, new_exporter_side);

    // The teeth: the replacement session really does have different names.
    // Without this the refusal below could pass for the wrong reason, and
    // under key reuse this is exactly the assertion that fails.
    try std.testing.expect(!std.mem.eql(u8, &old_gifter_side, &new_gifter_side));
    try std.testing.expect(!std.mem.eql(u8, &old_session, &new_session));

    // The property itself: the stale certificate's names resolve to nothing,
    // while a live session to the same durable peer is open and resolving.
    try std.testing.expect(resolver.resolve(resolver.ctx, old_gifter_side, &old_session) == null);
    try std.testing.expect(resolver.resolve(resolver.ctx, new_gifter_side, &new_session) != null);

    // Nor can the stale side name borrow the new session by naming it: the
    // resolver matches the pair, so neither half of an old certificate can be
    // mixed with a current one.
    try std.testing.expect(resolver.resolve(resolver.ctx, old_gifter_side, &new_session) == null);
    try std.testing.expect(resolver.resolve(resolver.ctx, new_gifter_side, &old_session) == null);

    // This is also the whole of "and must not consume a new deposit with the
    // same gift id" (ADR-0097 item 10). A withdrawal reaches a gift registry
    // only through this resolver — it is what hands back the `gifts` a
    // consuming withdraw operates on — so a certificate whose names resolve to
    // nothing never reaches any registry, and a gift deposited on the
    // replacement session under a reused id is unreachable by it rather than
    // defended against after the fact.
    const live = resolver.resolve(resolver.ctx, new_gifter_side, &new_session).?;
    try std.testing.expectEqual(second_peer.giftRegistry(), live.gifts);

    try exporter.releaseSession(second.b);
    try gifter.releaseSession(second.a);
}

test "core host: a claimed designator cannot condemn our own dial to it" {
    const allocator = std.testing.allocator;

    // The tiebreak matches an inbound partner's *claimed* location against the
    // dials we have outstanding. A signature proves the partner holds its
    // session key; it proves nothing about where the partner says it lives. On
    // a transport whose designator is a key, the two must agree, or any peer
    // that can open a connection could name a designator we are dialing and
    // make us condemn our own verified outbound session to it, repeatedly, for
    // an exporter it never has to reach or hold a key for.
    var victim = test_host.init(allocator, @as([32]u8, @splat(0x77)), Host.Options.withFrameCap(frame_cap));
    defer victim.deinit();
    var us = test_host.init(allocator, @as([32]u8, @splat(0x01)), Host.Options.withFrameCap(frame_cap));
    defer us.deinit();
    var attacker = test_host.init(allocator, @as([32]u8, @splat(0xff)), Host.Options.withFrameCap(frame_cap));
    defer attacker.deinit();

    // The attacker only wins the tiebreak when our identifier sorts lower, so
    // the scenario needs that ordering to be the interesting one.
    const our_pid = crypto.derivePublicIdentifier(us.node.secretKey().publicKey());
    const attacker_pid = crypto.derivePublicIdentifier(attacker.node.secretKey().publicKey());
    try std.testing.expect(std.mem.order(u8, &our_pid.bytes, &attacker_pid.bytes) == .lt);

    // The victim's keyed designator: the identity we are dialing.
    var victim_designator: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&victim_designator, "{x}", .{victim.node.secretKey().publicKey().bytes});

    const keyed_locator: pancake.ocapn.model.PeerLocator = .{
        .transport = "keyed-tcp",
        .designator = &victim_designator,
        .hints = pancake.ocapn.model.Hints.emptyFalse(),
    };
    const our_designator = us.node.secretKey().publicKey().toDesignator();
    var our_hint = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:9200" },
    }};
    try us.setAdvertisedLocator(.{
        .transport = "keyed-tcp",
        .designator = &our_designator,
        .hints = .{ .entries = &our_hint },
    });
    try us.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:9100",
        .hints = model.Hints.emptyFalse(),
    });
    const our_dial = try us.openDialedLocator(keyed_locator);

    // A host of ours will not publish that locator: a key-designator transport
    // may name only the durable identity this node holds (ADR-0105).
    var attacker_hint = [_]model.HintEntry{.{
        .name = model.transport.hint_direct_addresses,
        .value = .{ .string = "127.0.0.1:9201" },
    }};
    try std.testing.expectError(
        error.UnheldIdentity,
        attacker.setAdvertisedLocator(.{
            .transport = "keyed-tcp",
            .designator = &victim_designator,
            .hints = .{ .entries = &attacker_hint },
        }),
    );

    // A hostile peer is not bound by our seams, so the attack is built by
    // hand: an `op:start-session` claiming the victim's designator as its own
    // location, signed with the attacker's own session key.
    const our_accepted = try us.openAcceptedAdvertised("tcp");
    var claim = try handshake_support.signedHelloFrame(
        allocator,
        attacker.node.secretKey(),
        "keyed-tcp",
        &victim_designator,
        pancake.ocapn.model.Hints.emptyFalse(),
    );
    defer claim.deinit();

    try us.feed(our_accepted, claim.view());

    // Crossed-hello matching does not treat a key-shaped designator as a peer
    // identity unless it is the session key that signed the hello, so this
    // unproved claim cannot condemn the dial to the real victim.
    try std.testing.expect(!our_dial.isTerminating());

    try us.releaseSession(our_accepted);
    try us.releaseSession(our_dial);
}

test "core host: a key-shaped address remains an address for crossed hellos" {
    const allocator = std.testing.allocator;
    var us = test_host.init(allocator, @as([32]u8, @splat(0x01)), Host.Options.withFrameCap(frame_cap));
    defer us.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0xff)), Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();

    const our_pid = crypto.derivePublicIdentifier(us.node.secretKey().publicKey());
    const partner_pid = crypto.derivePublicIdentifier(partner.node.secretKey().publicKey());
    try std.testing.expect(std.mem.order(u8, &our_pid.bytes, &partner_pid.bytes) == .lt);

    const address = partner.node.secretKey().publicKey().toDesignator();
    try us.setAdvertisedLocator(tcpLocator("127.0.0.1:9120"));
    const dialed = try us.openDialedLocator(tcpLocator(&address));
    const accepted = try us.openAcceptedAdvertised("tcp");

    // Byte shape cannot change an address transport into a key transport. The
    // signed claim matches the address we dialed, so ordinary crossed-hello
    // ordering applies even though a different session key signed it.
    var hello = try handshake_support.signedHelloFrame(
        allocator,
        partner.node.secretKey(),
        "tcp",
        &address,
        model.Hints.emptyFalse(),
    );
    defer hello.deinit();
    try us.feed(accepted, hello.view());
    try std.testing.expect(dialed.isTerminating());
    try std.testing.expect(!accepted.isTerminating());

    try us.releaseSession(accepted);
    try us.releaseSession(dialed);
}

// `Host.partnerIdentity` keeps three facts distinct: the session key verified
// by the `op:start-session` signature, the designator claimed by the partner's
// acceptable location, and the provenance of any durable identity proof.
// Success means the handshake signature was verified; it does not make the
// advertised designator an authenticated durable identity. Only provenance
// from an authenticated channel establishes that stronger fact.
//
// The tests below cover the verified-session requirement, the claimed locator
// representation, and the provenance distinction. Transport-specific channel
// proof is covered separately by the verified-channel tests.
//
// The designator for the host built on `seed`: that host's Ed25519 public key
// in canonical hexadecimal form.

test "partner identity: a verified tcp session reports the key its handshake proved" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = @as([32]u8, @splat(0x0b));
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    // The dialer learned the acceptor's per-session key by verifying its
    // signature. It is distinct from the server's durable identity seed.
    const seen = try client.partnerIdentity(pair.a);
    const expected_key = pair.b.sessionSecret().publicKey();
    try std.testing.expectEqualSlices(u8, expected_key.asBytes(), seen.session_key);
    try std.testing.expect(!expected_key.eql(crypto.SecretKey.fromSeed(server_seed).publicKey()));
    try std.testing.expectEqualStrings("127.0.0.1:7001", seen.designator);

    // `tcp` designates a socket address. The signature covers it, but the key
    // does not determine it, so the key question has no claim to make here and
    // false is the correct answer rather than a failure.
    try std.testing.expect(!seen.designatorIsSessionKey());

    // And the three facts stay distinct (ADR-0097): an address transport
    // proves no durable identity, so provenance says so rather than the
    // caller inferring it from the diagnostic above.
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    try std.testing.expect(!seen.durableIdentityAuthenticated());
}

test "onion identity: a dial authenticates the sturdyref target, not a durable CapTP peer" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";
    try client.ensureAdvertisedLocator(model.transport.onion);
    try server.setAdvertisedLocator(onionLocator(service_id));
    const accepted = try server.openAcceptedAdvertised(model.transport.onion);
    const dialed = try client.openDialedLocator(onionLocator(service_id));
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // Tor proved the service named by the dial target. It did not prove that
    // the service's forwarded endpoint owns the durable identity in the CapTP
    // hello, so the two facts stay distinct.
    const identity = try client.partnerIdentity(dialed);
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, identity.provenance);

    const enlivened = try client.enlivenWithPolicy(
        dialed,
        onionSturdyref(service_id, "durable-widget"),
        .checked,
    );
    try std.testing.expectEqual(driver.core.PeerProvenance.dial_target, enlivened.provenance);
    var fetch = (try dialed.takeOutbound()) orelse return error.MissingFetch;
    fetch.deinit();
}

test "partner identity: keyed-tcp reports its claimed designator without authenticating it" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x1a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = @as([32]u8, @splat(0x1b));
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const designator = keyedDesignator(server_seed);
    const accepted = try publishAndOpenAccepted(&server, "keyed-tcp", &designator, "127.0.0.1:7002");
    try client.ensureAdvertisedLocator("keyed-tcp");
    const dialed = try client.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    // The advertised durable name and the fresh session key remain separately
    // observable.
    const seen = try client.partnerIdentity(pair.a);
    try std.testing.expectEqualStrings(&designator, seen.designator);
    try std.testing.expect(!seen.designatorIsSessionKey());

    // The comparison is over canonical hex, not raw key bytes: the designator
    // is twice the key's length, so a raw-bytes comparison cannot match.
    try std.testing.expectEqual(seen.session_key.len * 2, seen.designator.len);

    // keyed-tcp supplies no channel proof, so the claimed key remains
    // unauthenticated.
    try std.testing.expectEqual(driver.core.DurableProvenance.unauthenticated, seen.provenance);
    try std.testing.expect(!seen.durableIdentityAuthenticated());
}

test "session identity: a host signs each session with that session's own key" {
    // ADR-0097 step 4's structural half. Which key signs a session comes from
    // the Host's required session root, and every consumer — the keyed hello
    // and the handoff records naming the session — reads it through the
    // session rather than reaching for the node's durable key. Pointing the
    // source at distinct per-session seeds is the whole of the fresh-key
    // switch, so this drives it to prove the seam actually carries.
    const allocator = std.testing.allocator;

    const opts = Host.Options.withFrameCap(frame_cap);
    const durable_seed = @as([32]u8, @splat(0x4a));
    var host = test_host.init(allocator, durable_seed, opts);
    defer host.deinit();

    // Two connections accepted on one listener, which is the simultaneous case
    // a real host sees: same advertised identity, different sessions.
    const first = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7301", &.{});
    const second = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7301", &.{});

    // Two sessions in one host, two different signing keys — and neither is
    // the host's durable key, which stays the node's own identity.
    const durable = crypto.SecretKey.fromSeed(durable_seed).publicKey();
    const first_key = first.sessionSecret().publicKey();
    const second_key = second.sessionSecret().publicKey();
    try std.testing.expect(!first_key.eql(second_key));
    try std.testing.expect(!first_key.eql(durable));
    try std.testing.expect(!second_key.eql(durable));

    // And the hello each session signed carries its own key, so the seam
    // reaches the wire rather than stopping at the accessor.
    var frame = first.served.port.peer.takeOutbound().?;
    defer frame.deinit();
    const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
    try std.testing.expectEqualSlices(u8, first_key.asBytes(), view.start_session.session_pubkey);

    // Both sessions are open at once, so this is the simultaneous case and not
    // two successive ones reusing a slot (ADR-0097 item 1). What stays equal
    // across them is the durable identity: each advertises the host's own
    // designator, which is the name a partner knows this host by, while the
    // keys above differ per connection.
    var second_frame = second.served.port.peer.takeOutbound().?;
    defer second_frame.deinit();
    const second_view = try pancake.ocapn.codec.syrup.decodeBody(second_frame.view());
    try std.testing.expectEqualSlices(u8, second_key.asBytes(), second_view.start_session.session_pubkey);
    try std.testing.expectEqualStrings(
        view.start_session.acceptable_location.designator,
        second_view.start_session.acceptable_location.designator,
    );
}

test "session identity: a give is signed by its session's key, not the host's durable key" {
    // The deepest coupling ADR-0097 step 4 has to move. A `desc:handoff-give`
    // names the gifter-exporter *session*, so its `gifter_side` must derive
    // from that session's key. While every session reuses its host's durable
    // key the two are the same bytes and a durable-key signature looks
    // correct; under distinct per-session keys they diverge, and only a
    // genuinely session-scoped signer still names the side the exporter
    // derives from the key it verified.
    const allocator = std.testing.allocator;

    const opts = Host.Options.withFrameCap(frame_cap);
    const durable_seed = @as([32]u8, @splat(0x4b));
    var gifter = test_host.init(allocator, durable_seed, opts);
    defer gifter.deinit();
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x4c)), opts);
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7311", &dials);

    // The gifter's side of this session, as the exporter will derive it: from
    // the key that signed the hello it verified.
    const session_key = pair.b.served.port.peer.session_state.partnerSessionKey().?;
    const from_session = try engine.handoff_names.sideName(session_key);
    const durable = crypto.SecretKey.fromSeed(durable_seed).publicKey();
    const from_durable = try engine.handoff_names.sideName(durable.asBytes());

    // The two really are different names here, so the assertion below has
    // teeth rather than passing on coincidence.
    try std.testing.expect(!std.mem.eql(u8, &from_session, &from_durable));

    // And the key the node signs this session's handoff records with is the
    // session's own, so the side it writes is `from_session`.
    const signer = pair.a.sessionSecret().publicKey();
    try std.testing.expectEqualSlices(u8, session_key, signer.asBytes());
}
