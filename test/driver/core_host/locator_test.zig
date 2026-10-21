//! The advertised locator snapshot: refused dials without one, opaque
//! designators, refused duplicate hints, explicit and candidate routes on
//! accept, byte-identical signatures on both ends, and hintless onion under
//! a non-baseline preference.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const SessionOpenFailingAllocator = harness.SessionOpenFailingAllocator;
const TaggedRow = harness.TaggedRow;
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

fn helloLocatorBytes(allocator: std.mem.Allocator, session: *HostSession) ![]u8 {
    var frame = (try session.takeOutbound()) orelse return error.MissingHello;
    defer frame.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
    if (body != .start_session) return error.MissingHello;
    const locator = try body.start_session.acceptable_location.toOwned(allocator);
    defer model.freePeerLocator(allocator, locator);
    return glowcap.ocapn.codec.signed.locationBytes(allocator, locator);
}

test "core host advertised locator: missing snapshot refuses dial and accept" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x70)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try std.testing.expectError(
        error.MissingAdvertisedLocator,
        host.openDialedLocator(tcpLocator("127.0.0.1:7090")),
    );
    try std.testing.expectError(
        error.MissingAdvertisedLocator,
        host.openAcceptedAdvertised("tcp"),
    );
}

test "session open allocation failures unwind before and after enrollment" {
    var failing = SessionOpenFailingAllocator{ .backing = std.testing.allocator };
    var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x71)), Host.Options.withFrameCap(frame_cap));
    failing.host = &host;
    defer host.deinit();
    try host.ensureAdvertisedLocator("tcp");

    inline for (.{
        SessionOpenFailingAllocator.Phase.before_enrollment,
        SessionOpenFailingAllocator.Phase.after_enrollment,
    }) |phase| {
        failing.arm(phase);
        try std.testing.expectError(error.OutOfMemory, host.openAcceptedAdvertised("tcp"));
        try std.testing.expect(failing.induced_failure);
        try std.testing.expectEqual(@as(usize, 0), host.sessions.count());
        try std.testing.expectEqual(@as(usize, 0), host.vat.ingresses.count());
        try std.testing.expectEqual(@as(usize, 0), host.pending_operations);
        try std.testing.expect((try host.takeAction()) == null);
    }

    const session = try host.openAcceptedAdvertised("tcp");
    try host.releaseSession(session);
}

test "core host advertised locator: address transport keeps a hex designator opaque" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x72)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const address_shaped_like_key = @as([crypto.PeerKey.designator_len]u8, @splat('a'));
    try host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = &address_shaped_like_key,
        .hints = model.Hints.emptyFalse(),
    });
    const stored = host.advertisedLocator("tcp") orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualSlices(u8, &address_shaped_like_key, stored.designator);

    const other_key = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x74))).publicKey().toDesignator();
    try std.testing.expectError(error.UnheldIdentity, host.setAdvertisedLocator(.{
        .transport = "iroh",
        .designator = &other_key,
        .hints = model.Hints.emptyFalse(),
    }));
}

test "core host advertised locator: duplicate caller hints are refused before storage" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x76)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_direct_addresses, .value = .{ .string = "127.0.0.1:7091" } },
        .{ .name = model.transport.hint_direct_addresses, .value = .{ .string = "127.0.0.1:7092" } },
    };
    try std.testing.expectError(error.DuplicateHintName, host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7091",
        .hints = .{ .entries = &hints },
    }));
    try std.testing.expect(host.advertisedLocator("tcp") == null);
}

test "core host advertised locator: excess caller hints are refused before storage" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x77)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var names: [model.max_locator_hint_count + 1][2]u8 = undefined;
    var hints: [model.max_locator_hint_count + 1]model.HintEntry = undefined;
    for (&hints, 0..) |*entry, index| {
        names[index] = .{ 'h', @intCast(index) };
        entry.* = .{ .name = &names[index], .value = .{ .boolean = true } };
    }
    try std.testing.expectError(error.TooManyHints, host.setAdvertisedLocator(.{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:7093",
        .hints = .{ .entries = &hints },
    }));
    try std.testing.expect(host.advertisedLocator(model.transport.tcp) == null);
}

test "core host advertised locator: explicit dial default publishes once" {
    const allocator = std.testing.allocator;
    const seed = @as([32]u8, @splat(0x73));
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const tcp = host.advertisedLocator("tcp") orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualStrings("127.0.0.1:0", tcp.designator);
    try std.testing.expectEqual(model.Hints.WireForm.map, tcp.hints.wire_form);
    try std.testing.expectEqual(@as(usize, 1), tcp.hints.entries.len);
    try std.testing.expectEqualStrings(model.transport.hint_features, tcp.hints.entries[0].name);
    try std.testing.expectEqualStrings(
        "pipelining,handoff,wire_delta,sturdyref,untag",
        tcp.hints.entries[0].value.string,
    );
    try std.testing.expectEqualStrings("tcp", host.acceptableLocator().?.transport);

    const own_key = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    try host.ensureAdvertisedLocator("iroh");
    const iroh = host.advertisedLocator("iroh") orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualSlices(u8, &own_key, iroh.designator);
    try std.testing.expectEqualStrings("tcp", host.acceptableLocator().?.transport);

    try std.testing.expect(try host.selectAdvertisedLocator("iroh"));
    try std.testing.expectEqualStrings("iroh", host.acceptableLocator().?.transport);
    try std.testing.expect(!try host.selectAdvertisedLocator("missing"));
    try std.testing.expectEqualStrings("iroh", host.acceptableLocator().?.transport);
    try host.removeAdvertisedLocator("iroh");
    try std.testing.expect(host.advertisedLocator("iroh") == null);
    try std.testing.expect(host.acceptableLocator() == null);
    try std.testing.expect(try host.selectAdvertisedLocator("tcp"));
    try std.testing.expectEqualStrings("tcp", host.acceptableLocator().?.transport);

    try host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7099",
        .hints = model.Hints.emptyFalse(),
    });
    try host.ensureAdvertisedLocator("tcp");
    try std.testing.expectEqualStrings(
        "127.0.0.1:7099",
        host.advertisedLocator("tcp").?.designator,
    );
}

test "core host advertised locator: an accept keeps an explicitly selected route and its hints" {
    const allocator = std.testing.allocator;
    const seed = @as([32]u8, @splat(0x77));
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    // The browser rendezvous shape: an explicit keyed-relay route whose
    // rendezvous-relay hint is what a handoff recipient needs to dial back.
    const own_key = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    const relay_hint = [_]model.HintEntry{
        .{ .name = "rendezvous-relay", .value = .{ .string = "ws://relay.example/relay" } },
    };
    try host.setAdvertisedLocator(.{
        .transport = "keyed-relay",
        .designator = &own_key,
        .hints = .{ .entries = &relay_hint },
    });

    // The accept-derived candidate is retained but must not displace policy:
    // the selection stays keyed-relay and its hint survives.
    try host.ensureAcceptAdvertisedLocator(.key, &own_key, "", "keyed-relay");
    const kept = host.acceptableLocator() orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualStrings("keyed-relay", kept.transport);
    var saw_relay_hint = false;
    for (kept.hints.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "rendezvous-relay")) saw_relay_hint = true;
    }
    try std.testing.expect(saw_relay_hint);
}

test "core host advertised locator: an accept with no selection installs its own candidate" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x78)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAcceptAdvertisedLocator(.address, "", "127.0.0.1:7100", "tcp");
    const selected = host.acceptableLocator() orelse return error.MissingAdvertisedLocator;
    try std.testing.expectEqualStrings("tcp", selected.transport);
    try std.testing.expectEqualStrings("127.0.0.1:7100", selected.designator);
}

test "core host advertised locator: a cross-transport route survives dial preparation and enters every hello" {
    const allocator = std.testing.allocator;
    const seed = @as([32]u8, @splat(0x75));
    var host = test_host.init(allocator, seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const own_key = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    const advertised: model.PeerLocator = .{
        .transport = "keyed-relay",
        .designator = &own_key,
        .hints = model.Hints.emptyFalse(),
    };
    try host.setAdvertisedLocator(advertised);
    // Opening the room connection prepares TCP as a dial fallback. It must not
    // replace the keyed-relay route other peers use to reach this host.
    try host.ensureAdvertisedLocator("tcp");

    const dialed = try host.openDialedLocator(tcpLocator("127.0.0.1:7090"));
    defer host.releaseSession(dialed) catch unreachable;
    const accepted = try host.openAcceptedAdvertised("tcp");
    defer host.releaseSession(accepted) catch unreachable;

    const expected = try glowcap.ocapn.codec.signed.locationBytes(allocator, host.acceptableLocator().?);
    defer allocator.free(expected);
    const dialed_location = try helloLocatorBytes(allocator, dialed);
    defer allocator.free(dialed_location);
    const accepted_location = try helloLocatorBytes(allocator, accepted);
    defer allocator.free(accepted_location);
    try std.testing.expectEqualSlices(u8, expected, dialed_location);
    try std.testing.expectEqualSlices(u8, expected, accepted_location);
}

test "core host handshake: a key dial accepts the partner's selected address route" {
    const allocator = std.testing.allocator;
    var dialer = test_host.init(allocator, @as([32]u8, @splat(0x76)), Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    const partner_seed = @as([32]u8, @splat(0x77));
    const partner_key = crypto.SecretKey.fromSeed(partner_seed).publicKey().toDesignator();

    try dialer.setAdvertisedLocator(tcpLocator("127.0.0.1:7092"));
    const session = try dialer.openDialedLocator(.{
        .transport = "iroh",
        .designator = &partner_key,
        .hints = model.Hints.emptyFalse(),
    });

    // The iroh channel reached the demanded key, while the peer asks future
    // sessions to use a TCP ingress. The hello's route is not a description of
    // this channel and therefore is not compared as though it were the dial
    // target.
    var hello = try handshake_support.signedHelloFrame(
        allocator,
        crypto.SecretKey.fromSeed(partner_seed),
        "tcp",
        "proxy.example:443",
        model.Hints.emptyFalse(),
    );
    defer hello.deinit();
    try dialer.feed(session, hello.view());
    try std.testing.expect(session.sessionOpen());
    try dialer.releaseSession(session);
}

test "core host advertised locator: dial and accept sign byte-identical snapshots" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x71)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var hints = [_]model.HintEntry{
        .{ .name = "route", .value = .{ .string = "published-once" } },
    };
    const advertised: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:7089",
        .hints = .{ .entries = &hints },
    };
    try host.setAdvertisedLocator(advertised);

    const dialed = try host.openDialedLocator(tcpLocator("127.0.0.1:7090"));
    defer host.releaseSession(dialed) catch unreachable;
    const accepted = try host.openAcceptedAdvertised("tcp");
    defer host.releaseSession(accepted) catch unreachable;

    const dial_bytes = try helloLocatorBytes(allocator, dialed);
    defer allocator.free(dial_bytes);
    const accept_bytes = try helloLocatorBytes(allocator, accepted);
    defer allocator.free(accept_bytes);
    const published_bytes = try glowcap.ocapn.codec.signed.locationBytes(allocator, host.acceptableLocator().?);
    defer allocator.free(published_bytes);

    try std.testing.expectEqualSlices(u8, published_bytes, dial_bytes);
    try std.testing.expectEqualSlices(u8, published_bytes, accept_bytes);
    try std.testing.expect(!std.mem.eql(u8, advertised.designator, "127.0.0.1:7090"));
}

test "core host advertised locator retains complete multi-hint snapshots" {
    const allocator = std.testing.allocator;
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.captp_version = .next;
    opts.codec = .capnp;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x78)), opts);
    defer host.deinit();

    const hints = [_]model.HintEntry{
        .{ .name = "route-a", .value = .{ .string = "one" } },
        .{ .name = "route-b", .value = .{ .string = "two" } },
        .{ .name = "route-c", .value = .{ .string = "three" } },
        .{ .name = "route-d", .value = .{ .string = "four" } },
    };
    try host.setAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7088",
        .hints = .{ .entries = &hints },
    });

    const stored = host.acceptableLocator().?;
    try std.testing.expectEqual(@as(usize, hints.len + 2), stored.hints.entries.len);
    for (hints) |expected| {
        const actual = for (stored.hints.entries) |candidate| {
            if (std.mem.eql(u8, expected.name, candidate.name)) break candidate;
        } else return error.MissingHint;
        try std.testing.expectEqualStrings(expected.value.string, actual.value.string);
    }
}

test "core host onion advertisement stays hintless and an onion accept defers its hello" {
    const allocator = std.testing.allocator;
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.captp_version = .next;
    opts.codec = .capnp;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x79)), opts);
    defer host.deinit();

    const service_id = @as([56]u8, @splat('a'));
    const supplied_hints = [_]model.HintEntry{.{
        .name = "must-not-escape",
        .value = .{ .string = "not part of the onion locator grammar" },
    }};
    const onion: model.PeerLocator = .{
        .transport = model.transport.onion,
        .designator = &service_id,
        .hints = .{ .entries = &supplied_hints },
    };
    try host.setAdvertisedLocator(onion);

    const stored = host.acceptableLocator().?;
    try std.testing.expectEqual(@as(usize, 0), stored.hints.entries.len);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, stored.hints.wire_form);

    // The accept sends no hello yet: on onion alone it waits for the status-allow: pending state or quoted runtime label
    // initiator's, which is the only thing that can say whether the partner
    // is glowcap and so which preference the answer may state (ADR-0042).
    const accepted = try host.openAcceptedAdvertised(model.transport.onion);
    defer host.releaseSession(accepted) catch unreachable;
    try std.testing.expect((try accepted.takeOutbound()) == null);
}

test "core host with the default profile answers an onion accept eagerly and bare" {
    const allocator = std.testing.allocator;
    // No upgraded profile configured: the deferred hello is ADR-0042's one
    // behavior change for a host that never asked for an upgrade, so this
    // host's onion accept says its bare hello at open, exactly as before the
    // mechanism existed, content and ordering both.
    var host = test_host.init(allocator, @as([32]u8, @splat(0x7a)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const service_id = @as([56]u8, @splat('b'));
    try host.setAdvertisedLocator(.{
        .transport = model.transport.onion,
        .designator = &service_id,
        .hints = model.Hints.emptyFalse(),
    });

    const accepted = try host.openAcceptedAdvertised(model.transport.onion);
    defer host.releaseSession(accepted) catch unreachable;
    const hello_location = try helloLocatorBytes(allocator, accepted);
    defer allocator.free(hello_location);
    const expected = try glowcap.ocapn.codec.signed.locationBytes(allocator, .{
        .transport = model.transport.onion,
        .designator = &service_id,
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, hello_location);
}
