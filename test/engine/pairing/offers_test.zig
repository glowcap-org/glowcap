//! Negotiated offers onto live sessions: intersected features, profile and
//! codec carried onto both peers, next Syrup and Cap'n Proto authenticating
//! before opening, and Cap'n Proto deliver/resolve parity with Syrup.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const codec = glowcap.ocapn.codec;
const pairing = engine.pairing;
const handshake = @import("../../support/handshake.zig");

const crypto = foundation.crypto;

const pairing_support = @import("harness.zig");
const pairedWithOffers = pairing_support.pairedWithOffers;

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
    const secret1 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x77)));
    const secret2 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x88)));

    try p1.sendKeyedStartSession(loc1, secret1);
    try p2.sendKeyedStartSession(loc2, secret2);
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
    const secret1 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x99)));
    const secret2 = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0xaa)));

    try p1.sendKeyedStartSession(loc1, secret1);
    try p2.sendKeyedStartSession(loc2, secret2);

    if (try pairing.shuttleUntilQuiescent(&p1, &p2) != .quiescent) {
        return error.HandshakeDidNotQuiesce;
    }

    try std.testing.expect(p1.sessionIsOpen());
    try std.testing.expect(p2.sessionIsOpen());
    try std.testing.expectEqual(model.CaptpVersion.next, p1.session_state.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, p1.session_state.codec);
    try std.testing.expect(p1.session_state.partnerSessionKey() != null);
    try std.testing.expect(p2.session_state.partnerSessionKey() != null);

    const retained = p1.session_state.partnerLocatorRaw() orelse return error.MissingPartnerLocator;
    var cursor: usize = 0;
    const decoded = try engine.readLocatorOwned(allocator, retained, &cursor);
    defer model.freePeerLocator(allocator, decoded);
    try std.testing.expectEqual(retained.len, cursor);
    try std.testing.expectEqualStrings(loc2.transport, decoded.transport);
    try std.testing.expectEqualStrings(loc2.designator, decoded.designator);
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

    try pair.p1.sendBorrowed(.{
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
    const view = event.view();
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

    try pair.p1.sendBorrowed(.{
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
    try std.testing.expectEqual(@as(?model.ImportPosition, .from(resolver_export)), pair.p2.session_state.resolverForInboundAnswer(.fromWire(.from(42))));

    try pair.p2.sendBorrowed(.{
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
    const view = event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expectEqualSlices(u8, "pong", view.resolve.resolution.fulfill.bytes);
}

test "pairedWithKeys verifies real Ed25519 start-session signatures" {
    const allocator = std.testing.allocator;
    const p1_seed = @as([crypto.SEED_BYTES]u8, @splat(0x11));
    const p2_seed = @as([crypto.SEED_BYTES]u8, @splat(0x22));

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
