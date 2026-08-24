//! Who may withdraw: real Ed25519 verification with keys routed per
//! certificate, refused foreign signers and replayed counts, the gifter key
//! learned from the handshake, canonical signing-domain bytes an embedder
//! can verify, and cross-codec re-encoding that still verifies.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const crypto = pancake.foundation.crypto;
const syrup = pancake.ocapn.codec.syrup;
const cross_peer = @import("../../support/cross_peer.zig");
const CountingAllocator = @import("../../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../../support/peer_fixture.zig");

const fixtures = @import("fixtures.zig");
const repeated = fixtures.repeated;
const recipient_key = fixtures.recipient_key;
const gifter_session = fixtures.gifter_session;
const gifter_side = fixtures.gifter_side;
const receiving_session = fixtures.receiving_session;
const receiving_side = fixtures.receiving_side;
const give_signature = fixtures.give_signature;
const receive_signature = fixtures.receive_signature;
const gift_id_a = fixtures.gift_id_a;
const gift_id_b = fixtures.gift_id_b;
const sideOf = fixtures.sideOf;
const GifterSessionFixture = fixtures.GifterSessionFixture;
const PermissiveGifterSessionFixture = fixtures.PermissiveGifterSessionFixture;
const giveWith = fixtures.giveWith;
const receiveWith = fixtures.receiveWith;
const RejectingVerifier = fixtures.RejectingVerifier;
const RoutingVerifier = fixtures.RoutingVerifier;
const signedGive = fixtures.signedGive;

test "third-party handoff authorizes a withdrawal under real Ed25519 with keys routed per certificate" {
    const allocator = std.testing.allocator;

    // Real keys: the gifter signs the give, the recipient signs the receive.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
    const recipient_side = sideOf(recipient_pub);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    // The receive embeds the signed give and is signed by the recipient.
    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var give_pair = try cross_peer.GivePair.init(allocator, give.recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, give);
    {
        var event = give_pair.recipient.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }

    // The exporter builds its verifier from the key it stored at deposit (the
    // gifter's) and the recipient key carried in the give, no key conjured at
    // verify time. Both certificates verify, so the withdrawal is authorized.
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "immediate deposited withdraw verifies the borrowed receive without ownership materialization" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x53));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x54));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);
    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var counter = CountingAllocator{ .backing = allocator };
    const measured = counter.allocator();
    var exporter = engine.Peer.init(measured);
    defer exporter.deinit();
    try exporter.giftRegistry().depositOwned(
        measured,
        exporter.session_state.limits,
        null,
        gift_id_a[0..],
        .{ .far = .{ .import_position = .from(9) } },
    );
    var gifter = GifterSessionFixture{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };
    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);

    counter.allocs = 0;
    var prepared = switch (try engine.bootstrap.resolveForWithdraw(
        measured,
        &exporter.session_state,
        exporter.giftRegistry(),
        gifter.resolver(),
        null,
        null,
        .{ .receive = view_handoff.receive, .answer = .fromWire(.from(1)) },
    )) {
        .settled => |settled| settled,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(measured);
            return error.TestUnexpectedPending;
        },
    };
    defer prepared.deinit(measured);

    // The two canonical signing-domain byte products are the only allocations.
    // An owned HandoffReceive projection would allocate each nested slice and
    // fail this exact budget before gift preparation begins.
    try std.testing.expectEqual(@as(usize, 2), counter.allocs);
}

test "borrowed handoff signing domains equal owned domains through both codecs" {
    const allocator = std.testing.allocator;
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x55));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x56));
    const recipient_pub = recipient_secret.publicKey();
    const recipient_side = sideOf(recipient_pub);

    var hint_entry = [_]model.HintEntry{.{
        .name = "direct-addresses",
        .value = .{ .string = "10.0.0.1:9049" },
    }};
    const hint_cases = [_]model.Hints{
        model.Hints.emptyMap(),
        model.Hints.emptyFalse(),
        .{ .entries = &hint_entry },
    };

    for (hint_cases) |hints| {
        var give: model.HandoffGive = .{
            .recipient_key = recipient_pub.asBytes(),
            .exporter = .{ .transport = "memory", .designator = "exporter", .hints = hints },
            .gifter_exporter_session = gifter_session[0..],
            .gifter_side = gifter_side[0..],
            .gift_id = gift_id_a[0..],
            .signature = "",
        };
        const give_signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
        defer allocator.free(give_signed);
        const give_sig = crypto.sign(&gifter_secret, give_signed);
        give.signature = give_sig.asBytes();
        var receive: model.HandoffReceive = .{
            .receiving_session = receiving_session[0..],
            .receiving_side = &recipient_side,
            .handoff_count = 1,
            .signed_give = give,
            .signature = "",
        };
        const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
        defer allocator.free(receive_signed);
        const receive_sig = crypto.sign(&recipient_secret, receive_signed);
        receive.signature = receive_sig.asBytes();

        for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
            var handoff = model.Handoff{ .receive = receive };
            var frame = try codec.dispatch.encodeMessageForProfile(
                codec_id,
                allocator,
                .v1_0,
                .{ .deliver = .{
                    .target = .{ .far = model.FarRef.object(1) },
                    .args = &.{.{ .handoff = &handoff }},
                } },
            );
            defer frame.deinit();
            const decoded = try codec.dispatch.decodeBody(codec_id, frame.view());
            const decoded_handoff = (try decoded.deliver.args.at(0)).handoff;
            try std.testing.expect(decoded_handoff == .receive);

            const borrowed_give = try codec.signed.giveViewBytes(allocator, decoded_handoff.receive.signed_give);
            defer allocator.free(borrowed_give);
            try std.testing.expectEqualSlices(u8, give_signed, borrowed_give);

            const borrowed_receive = try codec.signed.receiveViewBytes(allocator, decoded_handoff.receive);
            defer allocator.free(borrowed_receive);
            try std.testing.expectEqualSlices(u8, receive_signed, borrowed_receive);
        }
    }
}

test "third-party handoff rejects a give signed by a key other than the recorded gifter" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const forger_secret = crypto.SecretKey.fromSeed(repeated(32, 0x99));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
    const recipient_side = sideOf(recipient_pub);

    // The give is signed by the forger, not the gifter the exporter records.
    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &forger_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var give_pair = try cross_peer.GivePair.init(allocator, give.recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, give);
    {
        var event = give_pair.recipient.pollEvent().?;
        defer event.deinit();
    }

    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    // The give signature was made by the forger, so it fails against the recorded
    // gifter key and the withdrawal is refused.
    try std.testing.expectError(
        cross_peer.Error.SignatureRejected,
        cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make()),
    );
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "third-party handoff routes a give and authorizes a withdrawal across peers" {
    const allocator = std.testing.allocator;
    var give_pair = try cross_peer.GivePair.init(allocator, &recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, giveWith(gift_id_a[0..]));

    {
        var event = give_pair.recipient.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        cross_peer.testOnlyAcceptingVerifier(),
    );

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
    }
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "third-party handoff rejects a replayed handoff count across peers" {
    const allocator = std.testing.allocator;
    var give_pair = try cross_peer.GivePair.init(allocator, &recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, giveWith(gift_id_a[0..]));
    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, giveWith(gift_id_b[0..]));

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 2, receive_signature[0..]),
        cross_peer.testOnlyAcceptingVerifier(),
    );

    try std.testing.expectError(session.Error.HandoffReplay, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_b[0..], 1, receive_signature[0..]),
        cross_peer.testOnlyAcceptingVerifier(),
    ));
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_b[0..]));
}

test "third-party handoff rejects a withdrawal whose signature fails verification" {
    const allocator = std.testing.allocator;
    var give_pair = try cross_peer.GivePair.init(allocator, &recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, giveWith(gift_id_a[0..]));

    try std.testing.expectError(cross_peer.Error.SignatureRejected, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        RejectingVerifier.make(),
    ));
    try std.testing.expect(exporter.giftRegistry().giftLive(gift_id_a[0..]));
}

test "the exporter authorizes a withdrawal against the gifter key it learned from the handshake" {
    const allocator = std.testing.allocator;
    const pairing = engine.pairing;

    const gifter_seed = repeated(32, 0x51);
    const exporter_seed = repeated(32, 0x53);
    const gifter_secret = crypto.SecretKey.fromSeed(gifter_seed);
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    // A real keyed handshake for the gifter-to-exporter session, so the exporter
    // learns the gifter's session key from `op:start-session` — not from an
    // argument. gx.p1 is the gifter; gx.p2 is the exporter.
    var gx = try pairing.pairedWithKeys(allocator, gifter_seed, exporter_seed);
    defer gx.deinit();

    // A receive names the session it travels over, and this one is validated
    // against `gx.p2`'s session, whose other end is the gifter. The exporter
    // derives both names from that session's two keys and holds the receive to
    // them, so the fixture names the same pair. What the recipient key still
    // decides is the signature: the receive below is signed with it, and the
    // exporter verifies against the key the give carries.
    const withdrawing_side = sideOf(gifter_pub);
    const exporter_side = sideOf(crypto.SecretKey.fromSeed(exporter_seed).publicKey());
    const receiving_session_name = engine.handoff_recipient.sessionName(withdrawing_side, exporter_side);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = &receiving_session_name,
        .receiving_side = &withdrawing_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var give_pair = try cross_peer.GivePair.init(allocator, give.recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &gx.p2, give);
    {
        var event = give_pair.recipient.pollEvent().?;
        defer event.deinit();
    }

    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &gx.p2, receive, verifier_ctx.make());
    try std.testing.expect(!gx.p2.giftRegistry().giftLive(gift_id_a[0..]));
}

test "canonical handoff-give bytes are a stable Ed25519 signing domain an embedder can verify" {
    const allocator = std.testing.allocator;

    // The exact bytes the gifter's `desc:sig-envelope` signature covers. Before
    // this encoder existed, an embedder had no way to reconstruct them, so a
    // handoff signature could not be verified the way an op:start-session
    // location signature can. This proves the domain round-trips under real
    // Ed25519 and that it binds the whole record, not one field.
    const give = giveWith(gift_id_a[0..]);
    const signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(signed);

    const secret = crypto.SecretKey.fromSeed(repeated(32, 0x07));
    const sig = crypto.sign(&secret, signed);
    try crypto.verify(secret.publicKey(), signed, sig);

    // Change one field: the canonical bytes differ, so the prior signature no
    // longer verifies. A signature lifted from another envelope cannot pass.
    const tampered = giveWith(gift_id_b[0..]);
    const tampered_bytes = try syrup.canonicalHandoffGiveSignedBytes(allocator, tampered);
    defer allocator.free(tampered_bytes);
    try std.testing.expect(!std.mem.eql(u8, signed, tampered_bytes));
    try std.testing.expectError(
        crypto.CryptoError.InvalidSignature,
        crypto.verify(secret.publicKey(), tampered_bytes, sig),
    );

    // The receive certificate has its own canonical domain, distinct from the
    // give it embeds, so the two signatures never share a payload.
    const receive = receiveWith(gift_id_a[0..], 1, receive_signature[0..]);
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    try std.testing.expect(!std.mem.eql(u8, signed, receive_signed));
}

test "a signed handoff give re-encodes across codecs and its gifter signature still verifies (ADR-0009/ADR-0003)" {
    const allocator = std.testing.allocator;
    const dispatch = pancake.ocapn.codec.dispatch;

    // A give signed once, over its Syrup-canonical bytes, the gifter's actual
    // signing domain. `give_sig` must outlive every borrow of `give.signature`.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x07));
    const route_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = "ocapn://127.0.0.1%3A9001.tcp" },
    }};
    var give: model.HandoffGive = .{
        .recipient_key = recipient_key[0..],
        .exporter = .{
            .transport = model.transport.tcp,
            .designator = "127.0.0.1:9000",
            .hints = .{ .entries = &route_hints },
        },
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id_a[0..],
        .signature = "",
    };
    const give_signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(give_signed);
    const give_sig = crypto.sign(&gifter_secret, give_signed);
    give.signature = give_sig.asBytes();
    try crypto.verify(gifter_secret.publicKey(), give_signed, give_sig);

    const profile = model.CaptpVersion.v1_0;
    var handoff = model.Handoff{ .give = give };
    const message = model.Message{ .deliver = .{
        .target = .{ .far = model.FarRef.object(1) },
        .args = &.{.{ .handoff = &handoff }},
    } };

    // The cross-codec re-encode contract (ADR-0003 / ADR-0009): the signature
    // covers the *decoded* record's Syrup canonicalization, not the carrying
    // codec's bytes. So for every ordered pair of distinct codecs — encode in
    // the source, decode to a typed record, re-encode into the target codec,
    // decode again — re-deriving the signing domain reproduces the exact bytes
    // the gifter signed, and the carried signature still verifies over them.
    const codecs = [_]model.CodecId{ .syrup, .capnp };
    for (codecs) |source| {
        for (codecs) |target| {
            if (source == target) continue;

            var src_frame = try dispatch.encodeMessageForProfile(source, allocator, profile, message);
            defer src_frame.deinit();
            const src_body = try dispatch.decodeBody(source, src_frame.view());
            const src_owned = try src_body.toOwned(allocator);
            defer model.freeMessage(allocator, src_owned);

            // Put the decoded passable value into a fresh outbound deliver. The
            // source deliver's target has flipped to our perspective and cannot
            // itself be sent back out; the nested handoff is the value whose
            // codec-neutral representation this test proves.
            const outbound = model.Message{ .deliver = .{
                .target = .{ .far = model.FarRef.object(1) },
                .args = src_owned.deliver.args,
            } };
            var tgt_frame = try dispatch.encodeMessageForProfile(
                target,
                allocator,
                profile,
                outbound,
            );
            defer tgt_frame.deinit();
            const tgt_body = try dispatch.decodeBody(target, tgt_frame.view());
            const tgt_owned = try tgt_body.toOwned(allocator);
            defer model.freeMessage(allocator, tgt_owned);

            const decoded_give = tgt_owned.deliver.args[0].handoff.*.give;
            const recanonical = try syrup.canonicalHandoffGiveSignedBytes(allocator, decoded_give);
            defer allocator.free(recanonical);
            try std.testing.expectEqualSlices(u8, give_signed, recanonical);

            const carried = crypto.Signature.fromBytes(
                decoded_give.signature[0..crypto.SIGNATURE_BYTES].*,
            );
            try crypto.verify(gifter_secret.publicKey(), recanonical, carried);
        }
    }
}

test "handoff side-name helper enforces the 32-byte Ed25519 key contract" {
    const handoff = engine.handoff_recipient;

    // A 32-byte key produces a stable, deterministic side name.
    const key32 = repeated(32, 0x42);
    const side_a = try handoff.sideName(&key32);
    const side_b = try handoff.sideName(&key32);
    try std.testing.expectEqualSlices(u8, &side_a, &side_b);

    // Any other width is rejected fail-closed rather than producing a
    // Goblins-incompatible name or overflowing the rendering buffer.
    const short = repeated(31, 0x42);
    const long = repeated(33, 0x42);
    try std.testing.expectError(error.MalformedKey, handoff.sideName(&short));
    try std.testing.expectError(error.MalformedKey, handoff.sideName(&long));
}
