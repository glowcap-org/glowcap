//! The keyed handshake to open: paired peers drive `op:start-session` to an
//! open session with bootstrap export, advertised features and locator hints
//! survive the signed hello, and every non-baseline, duplicate-hint, or
//! unregistered-codec shape is refused before it is sent or signed.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const codec = pancake.ocapn.codec;
const pairing = engine.pairing;
const handshake = @import("../../support/handshake.zig");

const crypto = foundation.crypto;

const pairing_support = @import("harness.zig");
const pairedWithOffers = pairing_support.pairedWithOffers;

test "paired factory drives the handshake to open with bootstrap export" {
    const allocator = std.testing.allocator;
    var pair = try pairing.paired(allocator);
    defer pair.deinit();

    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);
    try std.testing.expectEqual(session.State.open, pair.p2.session_state.state);
    try std.testing.expect(pair.p1.session_state.hasExport(.from(session.BOOTSTRAP_POSITION)));
    try std.testing.expect(pair.p2.session_state.hasExport(.from(session.BOOTSTRAP_POSITION)));
    try std.testing.expect(pair.p1.session_state.handshakeComplete());
    try std.testing.expect(pair.p2.session_state.handshakeComplete());
    try std.testing.expect(pair.p1.pollEvent() == null);
    try std.testing.expect(pair.p2.pollEvent() == null);
}

test "paired peers can exchange traffic once open" {
    const allocator = std.testing.allocator;
    var pair = try pairing.paired(allocator);
    defer pair.deinit();

    // p1 delivers against p2's permanently addressable bootstrap export.
    try pair.p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = null,
            .resolve_me_desc = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    const frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    var event = pair.p2.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
}

test "sendKeyedStartSession drives two negotiating peers to an open session" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.initNegotiating(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiating(allocator);
    defer p2.deinit();

    const loc1: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    const loc2: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:2", .hints = model.Hints.emptyFalse() };
    const secret1 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x11)));
    const secret2 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x22)));

    // Each side proactively signs and queues its own keyed start-session, exactly
    // as a real handshake (and a live Goblins partner) does.
    try p1.sendKeyedStartSession(loc1, secret1);
    try p2.sendKeyedStartSession(loc2, secret2);

    // Shuttle the handshake frames between the two peers until both are open.
    var i: usize = 0;
    while (i < 8 and !(p1.sessionIsOpen() and p2.sessionIsOpen())) : (i += 1) {
        _ = try p1.step();
        _ = try p2.step();
        while (p1.takeOutbound()) |frame| try p2.feedOwned(frame);
        while (p2.takeOutbound()) |frame| try p1.feedOwned(frame);
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
}

test "sendKeyedStartSession advertises non-baseline features into the signed hello" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.initNegotiating(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiatingWith(allocator, .{
        .features = model.FeatureSet.minimum(),
    });
    defer p2.deinit();

    const loc1: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:11", .hints = model.Hints.emptyFalse() };
    const loc2: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:12", .hints = model.Hints.emptyFalse() };
    const secret1 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x12)));
    const secret2 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x23)));

    try p1.sendKeyedStartSession(loc1, secret1);
    try p2.sendKeyedStartSession(loc2, secret2);

    var i: usize = 0;
    while (i < 8 and !(p1.sessionIsOpen() and p2.sessionIsOpen())) : (i += 1) {
        _ = try p1.step();
        _ = try p2.step();
        while (p1.takeOutbound()) |frame| try p2.feedOwned(frame);
        while (p2.takeOutbound()) |frame| try p1.feedOwned(frame);
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
    try std.testing.expectEqual(model.FeatureSet.minimum(), p1.session_state.features);
    try std.testing.expectEqual(model.FeatureSet.minimum(), p2.session_state.features);
    // The recorded partner preference is what the partner's hello stated: p2
    // stated minimum features, while the default Pancake peer stated its
    // ordinary default offer.
    try std.testing.expectEqual(model.FeatureSet.minimum(), p1.session_state.partner_preference.features);
    try std.testing.expectEqual(model.Preference{}, p2.session_state.partner_preference);
}

test "v1.0 hello advertisement strips next-only features" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .v1_0,
        .codec = .syrup,
        .features = model.FeatureSet.full(),
    });
    defer peer.deinit();

    const loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:13",
        .hints = model.Hints.emptyFalse(),
    };
    var storage: engine.Peer.HelloHints = .{};
    defer storage.deinit(allocator);

    const advertised = try peer.advertisedLocator(loc, &storage);
    const stated = try session.parsePreferenceHints(advertised.hints);
    try std.testing.expectEqual(model.CaptpVersion.v1_0, stated.captp_version);
    try std.testing.expect(stated.features.untag);
    try std.testing.expect(!stated.features.multi_location);
}

test "hello hint stamping refuses an over-limit result before allocation" {
    var names: [model.max_locator_hint_count][2]u8 = undefined;
    var entries: [model.max_locator_hint_count]model.HintEntry = undefined;
    for (&entries, 0..) |*entry, index| {
        names[index] = .{ 'h', @intCast(index) };
        entry.* = .{ .name = &names[index], .value = .{ .boolean = true } };
    }
    var storage: engine.Peer.HelloHints = .{};
    var empty_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&empty_storage);

    try std.testing.expectError(error.TooManyHints, storage.extend(
        fixed.allocator(),
        .{
            .transport = model.transport.tcp,
            .designator = "127.0.0.1:13",
            .hints = .{ .entries = &entries },
        },
        .{ .captp_version = .next },
        true,
    ));
    try std.testing.expect(storage.allocated_entries == null);
}

test "sendKeyedStartSession preserves arbitrary locator hint maps" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
    });
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiating(allocator);
    defer p2.deinit();

    const hints = [_]model.HintEntry{
        .{ .name = "route-a", .value = .{ .string = "one" } },
        .{ .name = "route-b", .value = .{ .string = "two" } },
        .{ .name = "route-c", .value = .{ .integer = 3 } },
        .{ .name = "route-d", .value = .{ .boolean = true } },
    };
    const loc1: model.PeerLocator = .{
        .transport = "test",
        .designator = "peer-one",
        .hints = .{ .entries = &hints },
    };
    const loc2: model.PeerLocator = .{
        .transport = "test",
        .designator = "peer-two",
        .hints = model.Hints.emptyFalse(),
    };
    try p1.sendKeyedStartSession(loc1, crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x31))));
    try p2.sendKeyedStartSession(loc2, crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x32))));

    var i: usize = 0;
    while (i < 8 and !(p1.sessionIsOpen() and p2.sessionIsOpen())) : (i += 1) {
        _ = try p1.step();
        _ = try p2.step();
        while (p1.takeOutbound()) |frame| try p2.feedOwned(frame);
        while (p2.takeOutbound()) |frame| try p1.feedOwned(frame);
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
    var event = p2.pollEvent().?;
    defer event.deinit();
    const received = (try event.view()).start_session.acceptable_location;
    const received_hints = try received.hints.toOwned(allocator);
    defer model.freeHints(allocator, received_hints);
    try std.testing.expectEqual(@as(usize, hints.len + 3), received_hints.entries.len);
    for (hints) |expected| {
        const actual = for (received_hints.entries) |candidate| {
            if (std.mem.eql(u8, expected.name, candidate.name)) break candidate;
        } else return error.MissingHint;
        switch (expected.value) {
            .string => |value| try std.testing.expectEqualStrings(value, actual.value.string),
            .bytes => |value| try std.testing.expectEqualSlices(u8, value, actual.value.bytes),
            .boolean => |value| try std.testing.expectEqual(value, actual.value.boolean),
            .integer => |value| try std.testing.expectEqual(value, actual.value.integer),
        }
    }
}

test "a hello naming anything but the baseline version is refused before it is sent" {
    // `sendKeyedStartSession` cannot produce one: it names the baseline and
    // carries the preference in a hint, so the disagreement this guards
    // against is unrepresentable through the verb. A hand-built message can
    // still reach `send`, and that is the path checked here — a peer
    // preferring `next` must still greet with the baseline, or a partner that
    // knows only the baseline aborts instead of negotiating down to it.
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .captp_version = model.CaptpVersion.next });
    defer peer.deinit();

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    try std.testing.expectError(session.Error.CaptpVersionMismatch, peer.sendCopying(.{
        .start_session = .{
            .captp_version = .next,
            .session_pubkey = .{ .bytes = &@as([32]u8, @splat(0)) },
            .acceptable_location = loc,
            .acceptable_location_sig = .{ .bytes = &@as([64]u8, @splat(0)) },
        },
    }));
    try std.testing.expect(!peer.session_state.handshake_local_sent);
}

test "a negotiated fallback retains its hello under the baseline profile" {
    const allocator = std.testing.allocator;
    var receiver = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
    });
    defer receiver.deinit();
    var sender = engine.Peer.initNegotiating(allocator);
    defer sender.deinit();

    const locator: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:2",
        .hints = model.Hints.emptyFalse(),
    };
    try sender.sendKeyedStartSession(
        locator,
        crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x42))),
    );
    try std.testing.expectEqual(engine.StepOutcome.progress, try sender.step());
    try receiver.feedOwned(sender.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());

    try std.testing.expectEqual(model.CaptpVersion.v1_0, receiver.session_state.captp_version);
    var event = receiver.pollEvent().?;
    defer event.deinit();
    const hello = (try event.view()).start_session;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, hello.captp_version);
    try std.testing.expectEqualStrings(locator.designator, hello.acceptable_location.designator);
}

test "negotiation uses the local preference actually stated on the wire" {
    const allocator = std.testing.allocator;
    var receiver = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
        .features = model.FeatureSet.full(),
    });
    defer receiver.deinit();

    try receiver.sendCopying(handshake.startSession("tcp", "127.0.0.1:1"));
    try std.testing.expect(receiver.session_state.handshake_local_sent);
    try std.testing.expectEqual(model.Preference.baseline, receiver.session_state.local_preference);

    var feature_bytes: [model.FeatureSet.wire_string_max_len]u8 = undefined;
    const features = try model.FeatureSet.full().toWireString(&feature_bytes);
    const remote_hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.wireString() } },
        .{ .name = model.transport.hint_codec, .value = .{ .string = "0" } },
        .{ .name = model.transport.hint_features, .value = .{ .string = features } },
    };
    const remote = try handshake.signedHelloFrame(
        allocator,
        crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x4b))),
        "tcp",
        "127.0.0.1:2",
        .{ .entries = &remote_hints },
    );
    try receiver.feedOwned(remote);
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());

    try std.testing.expect(receiver.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.v1_0, receiver.session_state.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, receiver.codecId());
    try std.testing.expect(!receiver.session_state.features.multi_location);
}

test "remote-first handshake settles after the local wire preference is sent" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
        .features = model.FeatureSet.full(),
    });
    defer peer.deinit();

    var remote_feature_bytes: [model.FeatureSet.wire_string_max_len]u8 = undefined;
    const remote_features = try model.FeatureSet.full().toWireString(&remote_feature_bytes);
    const remote_hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_captp_version, .value = .{ .string = model.CaptpVersion.next.wireString() } },
        .{ .name = model.transport.hint_codec, .value = .{ .string = "0" } },
        .{ .name = model.transport.hint_features, .value = .{ .string = remote_features } },
    };
    const remote = try handshake.signedHelloFrame(
        allocator,
        crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x4c))),
        "tcp",
        "127.0.0.1:3",
        .{ .entries = &remote_hints },
    );
    try peer.feedOwned(remote);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expect(!peer.sessionIsOpen());

    const local: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:4",
        .hints = model.Hints.emptyFalse(),
    };
    try peer.sendKeyedStartSession(
        local,
        crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x4d))),
    );

    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.next, peer.session_state.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, peer.codecId());
    try std.testing.expect(peer.session_state.features.multi_location);
}

test "a pre-settlement abort uses the baseline wire pair" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
    });
    defer peer.deinit();

    try std.testing.expectError(
        error.MalformedFrame,
        peer.recvBorrowed(.{ .bytes = "not a syrup frame", .shape = .byte }),
    );
    try std.testing.expectEqual(session.State.closed, peer.session_state.state);

    var frame = peer.takeOutbound() orelse return error.MissingAbort;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.v1_0, frame.view());
    try std.testing.expect(body == .abort);
    try std.testing.expectEqual(model.AbortKind.malformed_frame, body.abort.kind);
}

test "exact keyed start-session refuses an unstamped non-baseline profile" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
    });
    defer peer.deinit();

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x44)));
    try std.testing.expectError(
        session.Error.MalformedMessage,
        peer.sendKeyedStartSessionExact(loc, secret),
    );
    try std.testing.expect(!peer.session_state.handshake_local_sent);
}

test "exact keyed start-session refuses duplicate locator hints before signing" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();

    const hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_direct_addresses, .value = .{ .string = "127.0.0.1:1" } },
        .{ .name = model.transport.hint_direct_addresses, .value = .{ .string = "127.0.0.1:2" } },
    };
    const loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = .{ .entries = &hints },
    };
    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x45)));
    try std.testing.expectError(
        session.Error.MalformedMessage,
        peer.sendKeyedStartSessionExact(loc, secret),
    );
    try std.testing.expect(!peer.session_state.handshake_local_sent);
}

test "keyed start-session refuses an unregistered preferred codec before signing" {
    const allocator = std.testing.allocator;
    const unknown: model.CodecId = @fromBackingInt(@intCast(0xfffe));
    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x46)));
    const loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    };

    var ordinary = engine.Peer.initNegotiatingWith(allocator, .{ .codec = unknown });
    defer ordinary.deinit();
    try std.testing.expectError(error.UnknownCodec, ordinary.sendKeyedStartSession(loc, secret));
    try std.testing.expect(!ordinary.session_state.handshake_local_sent);

    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_codec,
        .value = .{ .string = "65534" },
    }};
    const exact_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = .{ .entries = &hints },
    };
    var exact = engine.Peer.initNegotiatingWith(allocator, .{ .codec = unknown });
    defer exact.deinit();
    try std.testing.expectError(error.UnknownCodec, exact.sendKeyedStartSessionExact(exact_loc, secret));
    try std.testing.expect(!exact.session_state.handshake_local_sent);
}

test "a signed hello advertising an unknown codec falls back before dispatch" {
    const allocator = std.testing.allocator;
    const local_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x47)));
    const remote_secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x48)));

    var peer = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = .next,
        .codec = .capnp,
    });
    defer peer.deinit();

    const local: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:1",
        .hints = model.Hints.emptyFalse(),
    };
    try peer.sendKeyedStartSession(local, local_secret);
    _ = try peer.step();
    var local_hello = peer.takeOutbound().?;
    local_hello.deinit();

    const remote_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_codec,
        .value = .{ .string = "65534" },
    }};
    const remote_hello = try handshake.signedHelloFrame(
        allocator,
        remote_secret,
        "tcp",
        "127.0.0.1:2",
        .{ .entries = &remote_hints },
    );
    try peer.feedOwned(remote_hello);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expect(peer.sessionIsOpen());
    try std.testing.expectEqual(model.CodecId.syrup, peer.codecId());
    try std.testing.expect(codec.registry.contains(peer.codecId()));

    var hello_event = peer.pollEvent().?;
    hello_event.deinit();

    const deliver = try codec.syrup.encodeMessageForProfile(allocator, .v1_0, .{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
            .args = &.{.{ .bytes = "still syrup" }},
            .answer = null,
            .resolve_me_desc = null,
        },
    });
    try peer.feedOwned(deliver);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var deliver_event = peer.pollEvent().?;
    defer deliver_event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, deliver_event.kind());
}

test "v1.0 resolve round-trips as a resolver-callback deliver across paired peers" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    try pair.p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = .from(42),
            .resolve_me_desc = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    const resolver_export = pair.p1.session_state.next_export_position - 1;
    try std.testing.expect(resolver_export != session.BOOTSTRAP_POSITION);
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(42)), pair.p1.session_state.answerForResolverExport(.from(resolver_export)));

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(resolver_export)), pair.p2.session_state.resolverForInboundAnswer(.fromWire(.from(42))));

    try pair.p2.sendCopying(.{
        .resolve = .{
            .answer = .from(42),
            .resolution = .{ .fulfill = .{ .bytes = "pong" } },
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const resolve_frame = pair.p2.takeOutbound().?;
    try pair.p1.feedOwned(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());

    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expectEqualSlices(u8, "pong", view.resolve.resolution.fulfill.bytes);
}
