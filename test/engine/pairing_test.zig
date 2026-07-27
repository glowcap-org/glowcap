const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const codec = pancake.ocapn.codec;
const pairing = engine.pairing;

const crypto = foundation.crypto;

fn offersShareCaptpVersion(local: engine.negotiation.Offer, remote: engine.negotiation.Offer) bool {
    for (local.captp_versions) |lp| {
        for (remote.captp_versions) |rp| {
            if (lp == rp) return true;
        }
    }
    return false;
}

/// Test helper: `negotiate` + `pairedNegotiated` (pairing keeps `pairedWithOffers` private).
fn pairedWithOffers(
    allocator: std.mem.Allocator,
    local: engine.negotiation.Offer,
    remote: engine.negotiation.Offer,
) !pairing.Pair {
    const negotiated = engine.negotiation.negotiate(local, remote) orelse {
        if (offersShareCaptpVersion(local, remote)) return pairing.Error.NoSharedCodec;
        return pairing.Error.NoSharedCaptpVersion;
    };
    return pairing.pairedNegotiated(allocator, negotiated);
}

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

    // p1 imports p2's bootstrap export, then delivers against it.
    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
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
    const secret1 = crypto.SecretKey.fromSeed([_]u8{0x11} ** crypto.SEED_BYTES);
    const secret2 = crypto.SecretKey.fromSeed([_]u8{0x22} ** crypto.SEED_BYTES);

    // Each side proactively signs and queues its own keyed start-session, exactly
    // as a real handshake (and a live Goblins partner) does.
    try p1.sendKeyedStartSession(.v1_0, loc1, secret1);
    try p2.sendKeyedStartSession(.v1_0, loc2, secret2);

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

test "sendKeyedStartSession rejects a version outside the peer profile" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .captp_version = model.CaptpVersion.v1_0 });
    defer peer.deinit();

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    const secret = crypto.SecretKey.fromSeed([_]u8{0x33} ** crypto.SEED_BYTES);

    try std.testing.expectError(
        session.Error.CaptpVersionMismatch,
        peer.sendKeyedStartSession(.next, loc, secret),
    );
    try std.testing.expect(!peer.session_state.handshake_local_sent);
}

test "v1.0 resolve round-trips as a resolver-callback deliver across paired peers" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
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
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(resolver_export)), pair.p2.session_state.resolverForInboundAnswer(.from(42)));

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

test "pairedWithOffers builds both peers with the negotiated (intersected) features" {
    const allocator = std.testing.allocator;
    // One side withholds handoff + sturdyref; the intersection must too, on both
    // peers, so neither exercises a capability the other did not advertise.
    const local: engine.negotiation.Offer = .{
        .captp_versions = &.{.v1_0},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const remote: engine.negotiation.Offer = .{
        .captp_versions = &.{.v1_0},
        .codecs = &.{.syrup},
        // full minus handoff + sturdyref.
        .features = .{
            .pipelining = true,
            .handoff = false,
            .wire_delta = true,
            .sturdyref = false,
        },
    };

    var pair = try pairedWithOffers(allocator, local, remote);
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
    const local: engine.negotiation.Offer = .{ .captp_versions = &.{.next}, .codecs = &.{.capnp}, .features = model.FeatureSet.full() };
    const remote: engine.negotiation.Offer = .{ .captp_versions = &.{.next}, .codecs = &.{.syrup}, .features = model.FeatureSet.full() };
    try std.testing.expectError(
        pairing.Error.NoSharedCodec,
        pairedWithOffers(allocator, local, remote),
    );
}

test "pairedWithOffers rejects offers that share no profile" {
    const allocator = std.testing.allocator;
    const local: engine.negotiation.Offer = .{
        .captp_versions = &.{model.CaptpVersion.next},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const remote: engine.negotiation.Offer = .{
        .captp_versions = &.{model.CaptpVersion.v1_0},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    try std.testing.expectError(
        pairing.Error.NoSharedCaptpVersion,
        pairedWithOffers(allocator, local, remote),
    );
}

test "pairedWithOffers carries the negotiated profile onto both sessions" {
    const allocator = std.testing.allocator;
    const local: engine.negotiation.Offer = .{
        .captp_versions = &.{model.CaptpVersion.next},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const remote: engine.negotiation.Offer = .{
        .captp_versions = &.{model.CaptpVersion.next},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };

    var pair = try pairedWithOffers(allocator, local, remote);
    defer pair.deinit();

    inline for (.{ &pair.p1, &pair.p2 }) |peer| {
        try std.testing.expectEqual(model.CaptpVersion.next, peer.session_state.captp_version);
        try std.testing.expectEqual(model.CodecId.syrup, peer.session_state.codec);
        try std.testing.expectEqual(session.State.open, peer.session_state.state);
    }
}

test "next Syrup peers authenticate start-session before opening" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .codec = .syrup,
    });
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .codec = .syrup,
    });
    defer p2.deinit();

    const loc1: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:11", .hints = model.Hints.emptyFalse() };
    const loc2: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:12", .hints = model.Hints.emptyFalse() };
    const secret1 = crypto.SecretKey.fromSeed([_]u8{0x77} ** crypto.SEED_BYTES);
    const secret2 = crypto.SecretKey.fromSeed([_]u8{0x88} ** crypto.SEED_BYTES);

    try p1.sendKeyedStartSession(.next, loc1, secret1);
    try p2.sendKeyedStartSession(.next, loc2, secret2);
    try std.testing.expect(!p1.sessionIsOpen());
    try std.testing.expect(!p2.sessionIsOpen());

    if (try pairing.shuttleUntilQuiescent(&p1, &p2) != .quiescent) {
        return error.HandshakeDidNotQuiesce;
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.next, p1.session_state.captp_version);
    try std.testing.expectEqual(model.CaptpVersion.next, p2.session_state.captp_version);
    try std.testing.expect(p1.session_state.partnerSessionKey() != null);
    try std.testing.expect(p2.session_state.partnerSessionKey() != null);
}

test "next Cap'n Proto peers authenticate start-session before opening" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .codec = .capnp,
    });
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = model.CaptpVersion.next,
        .codec = .capnp,
    });
    defer p2.deinit();

    const loc1: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:21", .hints = model.Hints.emptyFalse() };
    const loc2: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:22", .hints = model.Hints.emptyFalse() };
    const secret1 = crypto.SecretKey.fromSeed([_]u8{0x99} ** crypto.SEED_BYTES);
    const secret2 = crypto.SecretKey.fromSeed([_]u8{0xaa} ** crypto.SEED_BYTES);

    try p1.sendKeyedStartSession(.next, loc1, secret1);
    try p2.sendKeyedStartSession(.next, loc2, secret2);

    if (try pairing.shuttleUntilQuiescent(&p1, &p2) != .quiescent) {
        return error.HandshakeDidNotQuiesce;
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.next, p1.session_state.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, p1.session_state.codec);
    try std.testing.expect(p1.session_state.partnerSessionKey() != null);
    try std.testing.expect(p2.session_state.partnerSessionKey() != null);
}

/// Offers that negotiate the Cap'n Proto codec on both peers.
fn capnpOffer() engine.negotiation.Offer {
    return .{ .captp_versions = &.{.next}, .codecs = &.{.capnp}, .features = model.FeatureSet.full() };
}

test "pairedWithOffers carries the negotiated codec onto a live Cap'n Proto session" {
    const allocator = std.testing.allocator;
    var pair = try pairedWithOffers(allocator, capnpOffer(), capnpOffer());
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
    var pair = try pairedWithOffers(allocator, capnpOffer(), capnpOffer());
    defer pair.deinit();

    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
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
    // The wire frame is Cap'n Proto's word shape, not Syrup's byte shape.
    try std.testing.expectEqual(foundation.FrameShape.word, frame.view().shape);
    try pair.p2.feedOwned(frame);
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
    const v1_capnp: engine.negotiation.Offer = .{
        .captp_versions = &.{.v1_0},
        .codecs = &.{.capnp},
        .features = model.FeatureSet.full(),
    };
    var pair = try pairedWithOffers(allocator, v1_capnp, v1_capnp);
    defer pair.deinit();

    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
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
    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(resolver_export)), pair.p2.session_state.resolverForInboundAnswer(.from(42)));

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

    // `view()` reprojects the resolver-callback deliver as the semantic Resolve,
    // proving the V1.0 translation is codec-blind: same SessionTrace as Syrup.
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
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
    // over this location, the signature does not match the claimed key.
    var sender = engine.Peer.initNegotiating(allocator);
    defer sender.deinit();

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9", .hints = model.Hints.emptyFalse() };
    const honest = crypto.SecretKey.fromSeed([_]u8{0x33} ** crypto.SEED_BYTES);
    const imposter = crypto.SecretKey.fromSeed([_]u8{0x44} ** crypto.SEED_BYTES);

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
    try verifier.feedOwned(forged);
    try std.testing.expectError(error.InvalidStartSessionSignature, verifier.step());
    try std.testing.expectEqual(session.State.negotiating, verifier.session_state.state);

    // The refusal is fail-loud: a typed op:abort is queued for the partner.
    var abort_frame = verifier.takeOutbound().?;
    defer abort_frame.deinit();
    const view = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expectEqual(model.AbortKind.invalid_start_session_signature, view.abort.kind);
}

test "after a refused op:start-session the byte stream may retry: a valid hello is admitted" {
    const allocator = std.testing.allocator;

    // Pins the ADR-0083 keep-negotiating exception end to end: a handshake
    // refusal aborts without closing the negotiating session, so the same byte
    // stream may carry a corrected hello (the spec draft's abort text says
    // sever; pancake leaves severing to the adapter, and the retry grants
    // nothing a first valid hello would not, since every hello verifies in
    // full).
    // docs/community-review.md names the divergence.
    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9", .hints = model.Hints.emptyFalse() };
    const honest = crypto.SecretKey.fromSeed([_]u8{0x33} ** crypto.SEED_BYTES);
    const imposter = crypto.SecretKey.fromSeed([_]u8{0x44} ** crypto.SEED_BYTES);
    const signed = try codec.syrup.canonicalLocationSignedBytes(allocator, loc);
    defer allocator.free(signed);

    // First hello: valid signature, but not by the advertised key. Refused,
    // abort queued, state stays negotiating.
    {
        var sender = engine.Peer.initNegotiating(allocator);
        defer sender.deinit();
        const sig = crypto.sign(&honest, signed);
        try sender.sendCopying(.{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = imposter.publicKey().asBytes() },
            .acceptable_location = loc,
            .acceptable_location_sig = .{ .bytes = sig.asBytes() },
        } });
        _ = try sender.step();
        try verifier.feedOwned(sender.takeOutbound().?);
        try std.testing.expectError(error.InvalidStartSessionSignature, verifier.step());
        try std.testing.expectEqual(session.State.negotiating, verifier.session_state.state);
        var abort_frame = verifier.takeOutbound().?;
        abort_frame.deinit();
    }

    // Second hello on the same session: honestly signed by the advertised key,
    // admitted in full, exactly as a first valid hello would have been.
    {
        var sender = engine.Peer.initNegotiating(allocator);
        defer sender.deinit();
        const sig = crypto.sign(&honest, signed);
        try sender.sendCopying(.{ .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = honest.publicKey().asBytes() },
            .acceptable_location = loc,
            .acceptable_location_sig = .{ .bytes = sig.asBytes() },
        } });
        _ = try sender.step();
        try verifier.feedOwned(sender.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try verifier.step());
        try std.testing.expect(verifier.session_state.handshake_remote_received);
        try std.testing.expectEqual(session.State.negotiating, verifier.session_state.state);
        while (verifier.pollEvent()) |event_value| {
            var event = event_value;
            event.deinit();
        }
    }
}

test "a pinned peer refuses an op:start-session from any key but the expected one, and the session never opens" {
    const allocator = std.testing.allocator;

    // The verifier is a dialer that resolved a key-designator locator: it pins
    // the partner's session identity to the key it dialed. The sender's
    // handshake is honestly signed — the signature verifies — but under a
    // different key, which is exactly the relay/squat case the pin refuses.
    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    var sender = engine.Peer.initNegotiating(allocator);
    defer sender.deinit();

    const sender_secret = crypto.SecretKey.fromSeed([_]u8{0x77} ** crypto.SEED_BYTES);
    const expected_secret = crypto.SecretKey.fromSeed([_]u8{0x88} ** crypto.SEED_BYTES);
    verifier.expectPartnerKey(expected_secret.publicKey());

    const loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:9", .hints = model.Hints.emptyFalse() };
    try sender.sendKeyedStartSession(.v1_0, loc, sender_secret);
    _ = try sender.step();
    const hello = sender.takeOutbound().?;

    try verifier.feedOwned(hello);
    try std.testing.expectError(error.PartnerKeyMismatch, verifier.step());
    try std.testing.expectEqual(session.State.negotiating, verifier.session_state.state);

    // The refusal is fail-loud and rides the handshake abort domain.
    var abort_frame = verifier.takeOutbound().?;
    defer abort_frame.deinit();
    const view = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expectEqual(model.AbortKind.invalid_start_session_signature, view.abort.kind);
}

test "a pinned peer opens when the partner's start-session carries exactly the expected key" {
    const allocator = std.testing.allocator;

    var p1 = engine.Peer.initNegotiating(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.initNegotiating(allocator);
    defer p2.deinit();

    const secret1 = crypto.SecretKey.fromSeed([_]u8{0x11} ** crypto.SEED_BYTES);
    const secret2 = crypto.SecretKey.fromSeed([_]u8{0x22} ** crypto.SEED_BYTES);
    // Each side pins the other's real key: both handshakes must still open.
    p1.expectPartnerKey(secret2.publicKey());
    p2.expectPartnerKey(secret1.publicKey());

    const loc1: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    const loc2: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:2", .hints = model.Hints.emptyFalse() };
    try p1.sendKeyedStartSession(.v1_0, loc1, secret1);
    try p2.sendKeyedStartSession(.v1_0, loc2, secret2);

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

/// The exact `<ocapn-peer …>` record a hint-sending partner (a Goblins
/// `tcp-testing-only` netlayer) puts in its `op:start-session`. The wire bytes
/// are spelled out verbatim rather than produced by pancake's encoder, because
/// the point under test is verification over the *received* bytes — whatever
/// hint spelling the partner chose — not over a re-encode.
const hinted_locator_bytes = "<10'ocapn-peer3'tcp14\"127.0.0.1:9001{4\"host9\"127.0.0.14\"port9001+}>";

/// Build the complete keyed `op:start-session` frame a partner would send for
/// `hinted_locator_bytes` (optionally tampered after signing), signed with
/// `secret` over the canonical `<my-location …>` wrapping of the locator bytes.
fn hintedStartSessionFrame(
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    locator_bytes: []const u8,
) !foundation.Frame {
    const signed_domain = try codec.syrup.canonicalLocationSignedBytesRaw(allocator, hinted_locator_bytes);
    defer allocator.free(signed_domain);
    const sig = crypto.sign(&secret, signed_domain);
    const sig_bytes = sig.asBytes();
    const pubkey = secret.publicKey();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<16'op:start-session3\"1.0");
    try out.appendSlice(allocator, "[10'public-key[3'ecc[5'curve7'Ed25519][5'flags5'eddsa][1'q32:");
    try out.appendSlice(allocator, pubkey.asBytes());
    try out.appendSlice(allocator, "]]]");
    try out.appendSlice(allocator, locator_bytes);
    try out.appendSlice(allocator, "[7'sig-val[5'eddsa[1'r32:");
    try out.appendSlice(allocator, sig_bytes[0..32]);
    try out.appendSlice(allocator, "][1's32:");
    try out.appendSlice(allocator, sig_bytes[32..64]);
    try out.appendSlice(allocator, "]]]>");
    const storage = try out.toOwnedSlice(allocator);
    return foundation.Frame.initOwned(allocator, storage, .byte, .fromByteUnits(1));
}

test "a verifying peer accepts a hinted-locator handshake (signature checked on received bytes)" {
    const allocator = std.testing.allocator;
    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    const partner_secret = crypto.SecretKey.fromSeed([_]u8{0x55} ** crypto.SEED_BYTES);
    const verifier_secret = crypto.SecretKey.fromSeed([_]u8{0x66} ** crypto.SEED_BYTES);
    const verifier_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:9002",
        .hints = model.Hints.emptyFalse(),
    };

    try verifier.sendKeyedStartSession(.v1_0, verifier_loc, verifier_secret);
    _ = try verifier.step();
    var hello = verifier.takeOutbound().?;
    hello.deinit();

    // The partner's hello carries hint entries in its locator. Borrowed decode
    // projects them through `BorrowedHints`, but the signing domain is the
    // received `acceptable_location_raw` octets — re-encoding the structured
    // locator can miss the partner's exact spelling and fail a valid signature.
    const frame = try hintedStartSessionFrame(allocator, partner_secret, hinted_locator_bytes);
    try verifier.feedOwned(frame);
    _ = try verifier.step();
    try std.testing.expect(verifier.sessionIsOpen());
}

test "a verifying peer refuses a hinted-locator handshake whose hint bytes were tampered" {
    const allocator = std.testing.allocator;
    var verifier = engine.Peer.initNegotiating(allocator);
    defer verifier.deinit();
    verifier.verify_partner_handshake = true;

    const partner_secret = crypto.SecretKey.fromSeed([_]u8{0x55} ** crypto.SEED_BYTES);
    const verifier_secret = crypto.SecretKey.fromSeed([_]u8{0x66} ** crypto.SEED_BYTES);
    const verifier_loc: model.PeerLocator = .{
        .transport = "tcp",
        .designator = "127.0.0.1:9002",
        .hints = model.Hints.emptyFalse(),
    };

    try verifier.sendKeyedStartSession(.v1_0, verifier_loc, verifier_secret);
    _ = try verifier.step();
    var hello = verifier.takeOutbound().?;
    hello.deinit();

    // Flip one digit inside the hint map after signing. The frame stays
    // structurally valid, so only a signature computed over the received hint
    // bytes can notice, proving the hints participate in the signed domain.
    const tampered = try allocator.dupe(u8, hinted_locator_bytes);
    defer allocator.free(tampered);
    tampered[std.mem.lastIndexOfScalar(u8, tampered, '1').?] = '2';
    const frame = try hintedStartSessionFrame(allocator, partner_secret, tampered);
    try verifier.feedOwned(frame);
    try std.testing.expectError(error.InvalidStartSessionSignature, verifier.step());
    try std.testing.expectEqual(session.State.negotiating, verifier.session_state.state);
}

test "the handshake records each partner's session key for later signature checks" {
    const allocator = std.testing.allocator;
    const p1_seed = [_]u8{0x11} ** crypto.SEED_BYTES;
    const p2_seed = [_]u8{0x22} ** crypto.SEED_BYTES;

    var pair = try pairing.pairedWithKeys(allocator, p1_seed, p2_seed);
    defer pair.deinit();

    // Each side should have learned the other's session public key from the
    // partner's op:start-session, the key an embedder verifies the partner's
    // signatures against (e.g. a gifter's handoff-give on a gifter-to-exporter
    // session, ADR-0009).
    const p1_pub = (crypto.SecretKey.fromSeed(p1_seed)).publicKey();
    const p2_pub = (crypto.SecretKey.fromSeed(p2_seed)).publicKey();

    const p1_learned = pair.p1.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    const p2_learned = pair.p2.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    try std.testing.expectEqualSlices(u8, p2_pub.asBytes(), p1_learned);
    try std.testing.expectEqualSlices(u8, p1_pub.asBytes(), p2_learned);
}

test "v1.0 resolver-callback accepts a record-shaped break reason (Goblins interop), not only desc:error" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // p1 calls the partner bootstrap, allocating answer 42 and a resolver export.
    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(42),
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    const resolver_export = pair.p1.session_state.next_export_position - 1;

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(deliver_frame);
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
    try pair.p2.session_state.registerImport(.from(resolver_export));
    try pair.p2.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(resolver_export) } },
        .args = &.{ .{ .symbol = "break" }, .{ .tagged = .{ .tag = "exn:fail:mystery", .value = &.{} } } },
        .answer = null,
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const break_frame = pair.p2.takeOutbound().?;
    try pair.p1.feedOwned(break_frame);
    // Before the fix this faulted (MalformedView → dispatch error); now p1
    // surfaces a resolve-break carrying the record's tag as the reason.
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expect(view.resolve.resolution == .@"break");
    try std.testing.expectEqualSlices(u8, "exn:fail:mystery", view.resolve.resolution.@"break".message);
}

test "v1.0 resolver-callback break encodes its reason as a bare Symbol, the shape Goblins unmarshals" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // p1 calls the partner bootstrap with an answer, minting a resolver export.
    try pair.p1.session_state.registerImport(.from(session.BOOTSTRAP_POSITION));
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(42),
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        event.deinit();
    }

    // p2 breaks the answer. On the V1.0 wire this becomes a resolver-callback
    // deliver whose break payload must be a bare Symbol: Goblins' unmarshal
    // table has no `<error …>` record (an unknown record tag raises
    // `captp-unknown-record-rag` and the break is lost), while a Symbol passes
    // its unmarshaller untouched, the same payload shape the `op:listen`
    // listener fire uses.
    try pair.p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .@"break" = .{ .message = "unknown swissnum" } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const break_frame = pair.p2.takeOutbound().?;
    {
        // Pin the wire shape before handing the frame on.
        const body = try codec.dispatch.decodeBody(.syrup, break_frame.view());
        try std.testing.expect(body == .deliver);
        try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
        const tag = try body.deliver.args.at(0);
        try std.testing.expect(tag == .symbol);
        try std.testing.expectEqualSlices(u8, "break", tag.symbol);
        const payload = try body.deliver.args.at(1);
        try std.testing.expect(payload == .symbol);
        try std.testing.expectEqualSlices(u8, "unknown swissnum", payload.symbol);
    }

    // Symmetry: the receiving pancake peer projects the same semantic break it
    // accepted before the shape change.
    try pair.p1.feedOwned(break_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expect(view.resolve.resolution == .@"break");
    try std.testing.expectEqualSlices(u8, "unknown swissnum", view.resolve.resolution.@"break".message);
}
