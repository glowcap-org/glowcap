const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.model;
const engine = pancake.engine;
const session = pancake.session;
const codec = pancake.codec;
const pairing = engine.pairing;

const crypto = foundation.crypto;

test "paired factory drives the handshake to open with bootstrap export" {
    const allocator = std.testing.allocator;
    var pair = try pairing.paired(allocator);
    defer pair.deinit();

    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);
    try std.testing.expectEqual(session.State.open, pair.p2.session_state.state);
    try std.testing.expect(pair.p1.session_state.hasExport(session.BOOTSTRAP_EXPORT_ID));
    try std.testing.expect(pair.p2.session_state.hasExport(session.BOOTSTRAP_EXPORT_ID));
    try std.testing.expect(pair.p1.session_state.handshakeComplete());
    try std.testing.expect(pair.p2.session_state.handshakeComplete());
    try std.testing.expect(pair.p1.pollEvent() == null);
    try std.testing.expect(pair.p2.pollEvent() == null);
}

test "paired peers can exchange traffic once open" {
    const allocator = std.testing.allocator;
    var pair = try pairing.paired(allocator);
    defer pair.deinit();

    // p1 imports p2's bootstrap export, then delivers against it.
    try pair.p1.session_state.registerImport(session.BOOTSTRAP_EXPORT_ID);
    try pair.p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = null,
            .resolve_me_desc = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    const frame = pair.p1.takeOutbound().?;
    try pair.p2.feedInbound(frame);
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
    const secret1 = try crypto.SecretKey.fromSeed([_]u8{0x11} ** crypto.SEED_BYTES);
    const secret2 = try crypto.SecretKey.fromSeed([_]u8{0x22} ** crypto.SEED_BYTES);

    // Each side proactively signs and queues its own keyed start-session, exactly
    // as a real handshake (and a live Goblins partner) does.
    try p1.sendKeyedStartSession(.v1_0, loc1, secret1);
    try p2.sendKeyedStartSession(.v1_0, loc2, secret2);

    // Shuttle the handshake frames between the two peers until both are open.
    var i: usize = 0;
    while (i < 8 and !(p1.sessionIsOpen() and p2.sessionIsOpen())) : (i += 1) {
        _ = try p1.step();
        _ = try p2.step();
        while (p1.takeOutbound()) |frame| try p2.feedInbound(frame);
        while (p2.takeOutbound()) |frame| try p1.feedInbound(frame);
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
}

test "v1.0 resolve round-trips as a resolver-callback deliver across paired peers" {
    const allocator = std.testing.allocator;
    var pair = try pairing.paired(allocator);
    defer pair.deinit();

    try pair.p1.session_state.registerImport(session.BOOTSTRAP_EXPORT_ID);
    try pair.p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = 42,
            .resolve_me_desc = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    const resolver_export = pair.p1.session_state.next_export_id - 1;
    try std.testing.expect(resolver_export != session.BOOTSTRAP_EXPORT_ID);
    try std.testing.expectEqual(@as(?u64, 42), pair.p1.session_state.answerForResolverExport(resolver_export));

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedInbound(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    try std.testing.expectEqual(@as(?u64, resolver_export), pair.p2.session_state.resolverForInboundAnswer(42));

    try pair.p2.sendCopying(.{
        .resolve = .{
            .answer = 42,
            .resolution = .{ .fulfill = .{ .bytes = "pong" } },
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const resolve_frame = pair.p2.takeOutbound().?;
    try pair.p1.feedInbound(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());

    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer);
    try std.testing.expectEqualSlices(u8, "pong", view.resolve.resolution.fulfill.bytes);
}

test "pairedWithOffers builds both peers with the negotiated (intersected) features" {
    const allocator = std.testing.allocator;
    // One side withholds handoff + sturdyref; the intersection must too, on both
    // peers, so neither exercises a capability the other did not advertise.
    const local: engine.negotiation.Offer = .{
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const remote: engine.negotiation.Offer = .{
        .codecs = &.{.syrup},
        // full minus handoff + sturdyref.
        .features = .{
            .pipelining = true,
            .handoff = false,
            .wire_delta = true,
            .sturdyref = false,
            .stream = true,
            .equality = true,
        },
    };

    var pair = try pairing.pairedWithOffers(allocator, local, remote);
    defer pair.deinit();

    inline for (.{ &pair.p1, &pair.p2 }) |peer| {
        try std.testing.expectEqual(session.State.open, peer.session_state.state);
        try std.testing.expect(peer.session_state.features.pipelining);
        try std.testing.expect(peer.session_state.features.wire_delta);
        // Withheld by the intersection.
        try std.testing.expect(!peer.session_state.features.handoff);
        try std.testing.expect(!peer.session_state.features.sturdyref);
    }
}

test "pairedWithOffers rejects offers that share no codec" {
    const allocator = std.testing.allocator;
    const local: engine.negotiation.Offer = .{ .codecs = &.{.capnp}, .features = model.FeatureSet.full() };
    const remote: engine.negotiation.Offer = .{ .codecs = &.{.syrup}, .features = model.FeatureSet.full() };
    try std.testing.expectError(
        pairing.Error.NoSharedCodec,
        pairing.pairedWithOffers(allocator, local, remote),
    );
}

/// Offers that negotiate the Cap'n Proto codec on both peers.
fn capnpOffer() engine.negotiation.Offer {
    return .{ .codecs = &.{.capnp}, .features = model.FeatureSet.full() };
}

test "pairedWithOffers carries the negotiated codec onto a live Cap'n Proto session" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedWithOffers(allocator, capnpOffer(), capnpOffer());
    defer pair.deinit();

    // The handshake itself rode Cap'n Proto: both sessions record `.capnp` and
    // reached `open` decoding word-shaped frames through the dispatch boundary.
    inline for (.{ &pair.p1, &pair.p2 }) |peer| {
        try std.testing.expectEqual(model.CodecId.capnp, peer.session_state.codec);
        try std.testing.expectEqual(session.State.open, peer.session_state.state);
        try std.testing.expect(peer.session_state.handshakeComplete());
    }
}

test "paired Cap'n Proto peers exchange a deliver (parity with Syrup)" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedWithOffers(allocator, capnpOffer(), capnpOffer());
    defer pair.deinit();

    try pair.p1.session_state.registerImport(session.BOOTSTRAP_EXPORT_ID);
    try pair.p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = null,
            .resolve_me_desc = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    const frame = pair.p1.takeOutbound().?;
    // The wire frame is Cap'n Proto's word shape, not Syrup's byte shape.
    try std.testing.expectEqual(foundation.FrameShape.word, frame.view().shape);
    try pair.p2.feedInbound(frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    var event = pair.p2.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    // The borrowed neutral view projects the deliver over the capnp frame.
    const view = try event.view();
    try std.testing.expectEqual(@as(usize, 1), try view.deliver.args.len());
    try std.testing.expectEqualSlices(u8, "ping", (try view.deliver.args.at(0)).bytes);
}

test "v1.0 resolve round-trips as a resolver-callback deliver over Cap'n Proto" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedWithOffers(allocator, capnpOffer(), capnpOffer());
    defer pair.deinit();

    try pair.p1.session_state.registerImport(session.BOOTSTRAP_EXPORT_ID);
    try pair.p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = 42,
            .resolve_me_desc = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    const resolver_export = pair.p1.session_state.next_export_id - 1;
    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedInbound(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    try std.testing.expectEqual(@as(?u64, resolver_export), pair.p2.session_state.resolverForInboundAnswer(42));

    try pair.p2.sendCopying(.{
        .resolve = .{
            .answer = 42,
            .resolution = .{ .fulfill = .{ .bytes = "pong" } },
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const resolve_frame = pair.p2.takeOutbound().?;
    try pair.p1.feedInbound(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());

    // `view()` reprojects the resolver-callback deliver as the semantic Resolve,
    // proving the V1.0 translation is codec-blind: same SessionTrace as Syrup.
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer);
    try std.testing.expectEqualSlices(u8, "pong", view.resolve.resolution.fulfill.bytes);
}

test "pairedWithKeys verifies real Ed25519 start-session signatures" {
    const allocator = std.testing.allocator;
    const p1_seed = [_]u8{0x11} ** crypto.SEED_BYTES;
    const p2_seed = [_]u8{0x22} ** crypto.SEED_BYTES;

    // Returning without `InvalidStartSessionSignature` means each side's
    // partner signature verified over the real sign → encode → wire → decode
    // round-trip (the partner's inbound start-session frame view).
    var pair = try pairing.pairedWithKeys(allocator, p1_seed, p2_seed);
    defer pair.deinit();

    try std.testing.expectEqual(session.State.open, pair.p1.session_state.state);
    try std.testing.expectEqual(session.State.open, pair.p2.session_state.state);
    try std.testing.expect(pair.p1.session_state.handshakeComplete());
    try std.testing.expect(pair.p2.session_state.handshakeComplete());
    try std.testing.expect(pair.p1.pollEvent() == null);
    try std.testing.expect(pair.p2.pollEvent() == null);
}

test "a verifying peer aborts an op:start-session whose signature does not match the claimed key" {
    const allocator = std.testing.allocator;

    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    // A sender that emits a structurally valid keyed start-session, but advertises
    // one key while carrying a signature only a *different* key could have made
    // over this location — the signature does not match the claimed key.
    var sender = engine.Peer.initNegotiating(allocator);
    defer sender.deinit();

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9", .hints = model.Hints.emptyFalse() };
    const honest = try crypto.SecretKey.fromSeed([_]u8{0x33} ** crypto.SEED_BYTES);
    const imposter = try crypto.SecretKey.fromSeed([_]u8{0x44} ** crypto.SEED_BYTES);

    const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, loc);
    defer allocator.free(signed);
    const sig = crypto.sign(&honest, signed);

    try sender.sendCopying(.{ .start_session = .{
        .captp_version = .v1_0,
        .session_pubkey = .{ .bytes = imposter.publicKey().asBytes() },
        .acceptable_location = loc,
        .acceptable_location_sig = .{ .bytes = sig.asBytes() },
    } });
    _ = try sender.step();
    const forged = sender.takeOutbound().?;

    // The verifier refuses the forged handshake and does not open the session.
    try verifier.feedInbound(forged);
    try std.testing.expectError(error.InvalidStartSessionSignature, verifier.step());
    try std.testing.expect(!verifier.sessionIsOpen());

    // The refusal is fail-loud: a typed op:abort is queued for the partner.
    var abort_frame = verifier.takeOutbound().?;
    defer abort_frame.deinit();
    const view = try codec.syrup.decodeView(abort_frame.view());
    try std.testing.expectEqual(model.AbortKind.invalid_start_session_signature, view.abort.kind);
}

test "verifying peers complete a keyed handshake over a hinted locator (signature checked on received bytes)" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.initNegotiating(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiating(allocator);
    defer p2.deinit();
    p1.verify_partner_handshake = true;
    p2.verify_partner_handshake = true;

    // Locators carrying real hints (host/port) — exactly what an OCapN
    // `tcp-testing-only` netlayer puts on the wire. The borrowed locator decode
    // does not retain these hints, so verification must check the signature over
    // the *received* `<ocapn-peer …>` bytes, not a re-encode of the decoded
    // locator. If it re-encoded, the dropped hints would fail every signature.
    const h1 = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
        .{ .name = "port", .value = .{ .integer = 9001 } },
    };
    const h2 = [_]model.HintEntry{
        .{ .name = "host", .value = .{ .string = "127.0.0.1" } },
        .{ .name = "port", .value = .{ .integer = 9002 } },
    };
    const loc1: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9001", .hints = .{ .entries = &h1 } };
    const loc2: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9002", .hints = .{ .entries = &h2 } };
    const secret1 = try crypto.SecretKey.fromSeed([_]u8{0x55} ** crypto.SEED_BYTES);
    const secret2 = try crypto.SecretKey.fromSeed([_]u8{0x66} ** crypto.SEED_BYTES);

    try p1.sendKeyedStartSession(.v1_0, loc1, secret1);
    try p2.sendKeyedStartSession(.v1_0, loc2, secret2);

    var i: usize = 0;
    while (i < 8 and !(p1.sessionIsOpen() and p2.sessionIsOpen())) : (i += 1) {
        _ = try p1.step();
        _ = try p2.step();
        while (p1.takeOutbound()) |frame| try p2.feedInbound(frame);
        while (p2.takeOutbound()) |frame| try p1.feedInbound(frame);
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
}

test "the handshake records each partner's session key for later signature checks" {
    const allocator = std.testing.allocator;
    const p1_seed = [_]u8{0x11} ** crypto.SEED_BYTES;
    const p2_seed = [_]u8{0x22} ** crypto.SEED_BYTES;

    var pair = try pairing.pairedWithKeys(allocator, p1_seed, p2_seed);
    defer pair.deinit();

    // Each side should have learned the other's session public key from the
    // partner's op:start-session — the key an embedder verifies the partner's
    // signatures against (e.g. a gifter's handoff-give on a gifter-to-exporter
    // session, ADR-0009).
    const p1_pub = (try crypto.SecretKey.fromSeed(p1_seed)).publicKey();
    const p2_pub = (try crypto.SecretKey.fromSeed(p2_seed)).publicKey();

    const p1_learned = pair.p1.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    const p2_learned = pair.p2.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    try std.testing.expectEqualSlices(u8, p2_pub.asBytes(), p1_learned);
    try std.testing.expectEqualSlices(u8, p1_pub.asBytes(), p2_learned);
}

test "v1.0 resolver-callback accepts a record-shaped break reason (Goblins interop), not only desc:error" {
    const allocator = std.testing.allocator;
    var pair = try pairing.paired(allocator);
    defer pair.deinit();

    // p1 calls the partner bootstrap, allocating answer 42 and a resolver export.
    try pair.p1.session_state.registerImport(session.BOOTSTRAP_EXPORT_ID);
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = session.BOOTSTRAP_EXPORT_ID } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = 42,
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    const resolver_export = pair.p1.session_state.next_export_id - 1;

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedInbound(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        event.deinit();
    }

    // A real Goblins promise that breaks from a thrown exception marshals the
    // reason as a record, not a desc:error. Simulate that shape: deliver
    // `['break, <exn:fail:mystery>]` to p1's resolver export (the V1.0
    // resolver-callback form), where the reason is a tagged record. pancake
    // cannot *emit* this (its breaks are desc:error), so it is sent by hand.
    try pair.p2.session_state.registerImport(resolver_export);
    try pair.p2.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_id = resolver_export } },
        .args = &.{ .{ .symbol = "break" }, .{ .tagged = .{ .tag = "exn:fail:mystery", .value = &.{} } } },
        .answer = null,
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const break_frame = pair.p2.takeOutbound().?;
    try pair.p1.feedInbound(break_frame);
    // Before the fix this faulted (MalformedView → dispatch error); now p1
    // surfaces a resolve-break carrying the record's tag as the reason.
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer);
    try std.testing.expect(view.resolve.resolution == .break_);
    try std.testing.expectEqualSlices(u8, "exn:fail:mystery", view.resolve.resolution.break_.message);
}
