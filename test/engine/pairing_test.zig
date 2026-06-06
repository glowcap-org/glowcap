const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.model;
const engine = pancake.engine;
const session = pancake.session;
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
