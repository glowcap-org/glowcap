const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const crypto = pancake.foundation.crypto;
const syrup = pancake.ocapn.codec.syrup;
const cross_peer = @import("../support/cross_peer.zig");

fn repeated(comptime n: usize, byte: u8) [n]u8 {
    return [_]u8{byte} ** n;
}

const recipient_key = repeated(32, 0x42);
const gifter_session = repeated(32, 0xcc);
const gifter_side = repeated(32, 0x11);
const receiving_session = repeated(32, 0xdd);
const receiving_side = repeated(32, 0x22);
const give_signature = repeated(64, 0xaa);
const receive_signature = repeated(64, 0xbb);
const gift_id_a = repeated(32, 0x01);
const gift_id_b = repeated(32, 0x02);

fn giveWith(gift_id: []const u8) model.HandoffGive {
    return .{
        .recipient_key = recipient_key[0..],
        .exporter_location = "memory:exporter",
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = give_signature[0..],
    };
}

fn receiveWith(gift_id: []const u8, count: u64, signature: []const u8) model.HandoffReceive {
    return .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = count,
        .signed_give = giveWith(gift_id),
        .signature = signature,
    };
}

const RejectingVerifier = struct {
    fn verify(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }

    fn make() cross_peer.SignatureVerifier {
        return .{ .context = null, .verify_fn = verify };
    }
};

/// A real Ed25519 verifier that routes each handoff certificate to the right key —
/// the production shape ADR-0009 describes. A `desc:handoff-receive` payload is
/// verified with the recipient key; any other (`desc:handoff-give`) with the
/// gifter's session key. It distinguishes them by the leading record label, since
/// a receive record carries its own label before the give it embeds.
const RoutingVerifier = struct {
    gifter_key: crypto.PeerKey,
    recipient_key: crypto.PeerKey,

    fn verify(ctx: ?*anyopaque, payload: []const u8, signature: []const u8) bool {
        const self: *RoutingVerifier = @ptrCast(@alignCast(ctx.?));
        const label_at = std.mem.indexOf(u8, payload, "desc:handoff-") orelse return false;
        const key = if (std.mem.startsWith(u8, payload[label_at..], "desc:handoff-receive"))
            self.recipient_key
        else
            self.gifter_key;
        if (signature.len != crypto.SIGNATURE_BYTES) return false;
        const sig = crypto.Signature.fromBytes(signature[0..crypto.SIGNATURE_BYTES].*);
        crypto.verify(key, payload, sig) catch return false;
        return true;
    }

    fn make(self: *RoutingVerifier) cross_peer.SignatureVerifier {
        return .{ .context = self, .verify_fn = verify };
    }
};

/// A give signed by `gifter_secret` over its canonical bytes, naming `recipient`
/// as its recipient. The returned give borrows the caller-owned key/signature
/// slices, so they must outlive it.
fn signedGive(
    gift_id: []const u8,
    recipient: []const u8,
    gifter_secret: *const crypto.SecretKey,
    out_signed: *[]u8,
    out_sig: *crypto.Signature,
    allocator: std.mem.Allocator,
) !model.HandoffGive {
    var give: model.HandoffGive = .{
        .recipient_key = recipient,
        .exporter_location = "memory:exporter",
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = "",
    };
    out_signed.* = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    out_sig.* = crypto.sign(gifter_secret, out_signed.*);
    give.signature = out_sig.asBytes();
    return give;
}

test "third-party handoff authorizes a withdrawal under real Ed25519 with keys routed per certificate" {
    const allocator = std.testing.allocator;

    // Real keys: the gifter signs the give, the recipient signs the receive.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    // The receive embeds the signed give and is signed by the recipient.
    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // The exporter records the gifter's session key alongside the gift at deposit.
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, give, gifter_pub.asBytes());
    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.handoff, event.kind());
    }

    // The exporter builds its verifier from the key it stored at deposit (the
    // gifter's) and the recipient key carried in the give — no key conjured at
    // verify time. Both certificates verify, so the withdrawal is authorized.
    const stored_gifter = exporter.giftRegistry().giftGifterKey(gift_id_a[0..]).?;
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = try crypto.PeerKey.fromSlice(stored_gifter),
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make());
    try std.testing.expect(exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));
}

test "withdraw fulfills with the deposited capability, and a re-deposit replaces the first" {
    const allocator = std.testing.allocator;

    // Real keys: the gifter signs the give, the recipient signs the receive.
    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x71));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x72));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // Deposit the capability the exporter will hand back, keyed under the
    // gifter's session pubkey, on the peer's own gift registry.
    const deposited = model.Reference{ .far = .{ .import_position = 9 } };
    try peer.giftRegistry().depositOwned(
        allocator,
        peer.session_state.limits,
        gift_id_a[0..],
        deposited,
        gifter_pub.asBytes(),
    );

    // A second deposit of the same gift id replaces the first (the registry's
    // re-deposit contract): the withdraw below must yield this reference, not
    // the import-9 one.
    const redeposited = model.Reference{ .far = .{ .import_position = 10 } };
    try peer.giftRegistry().depositOwned(
        allocator,
        peer.session_state.limits,
        gift_id_a[0..],
        redeposited,
        gifter_pub.asBytes(),
    );

    // Withdraw it. `resolveForWithdraw` reads the gifted cap *after*
    // `applyWithdraw` marks the row withdrawn, which is why `giftedCap` does not
    // filter by the withdrawn flag — otherwise the resolution would break with
    // "gift not deposited" instead of fulfilling with the deposited reference.
    const handoff = model.Handoff{ .receive = receive };
    const view_handoff = model.view.Handoff.fromOwned(&handoff);
    const resolution_msg = switch (try engine.bootstrap.resolveForWithdraw(allocator, &peer.session_state, peer.giftRegistry(), .{
        .receive = view_handoff.receive,
        .answer = 5,
    })) {
        .settled => |msg| msg,
        .awaiting_deposit => return error.TestUnexpectedPending,
    };
    defer model.freeMessage(allocator, resolution_msg);

    try std.testing.expectEqual(@as(u64, 5), resolution_msg.resolve.answer);
    const fulfilled = switch (resolution_msg.resolve.resolution) {
        .fulfill => |arg| arg,
        .@"break" => return error.TestUnexpectedBreak,
    };
    try std.testing.expectEqual(@as(u64, 10), fulfilled.reference.far.import_position);
    try std.testing.expect(peer.giftRegistry().giftWithdrawn(gift_id_a[0..]));
}

test "a withdraw that arrives before its deposit parks and settles once the gift lands" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x61));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x62));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    // PreSpec carries a wire `op:resolve`, so the settled answer is observable
    // as one outbound frame without the V1.0 resolver-callback choreography.
    var exporter = engine.Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
        .wire_profile = model.WireProfile.pre_spec,
    }));
    defer exporter.deinit();
    try exporter.session_state.transitionToOpen();

    // The withdraw arrives on the wire before any deposit: `deposit-gift` and
    // `withdraw-gift` travel on different sessions, so this order is legal.
    var handoff_arg = model.Handoff{ .receive = receive };
    const frame = try syrup.encodeMessage(allocator, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
        .answer = 1,
    } });
    try exporter.feedInbound(frame);
    while ((try exporter.step()) != .idle) {}
    while (exporter.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }

    // Not refused, parked: no answer left the peer and the entry is held.
    try std.testing.expect(exporter.takeOutbound() == null);
    try std.testing.expectEqual(@as(usize, 1), exporter.pending_withdraws.items.len);
    try std.testing.expect(!exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));

    // The deposit lands on the vat's registry (in production, via the gifter's
    // session to this same vat).
    const deposited = model.Reference{ .far = .{ .import_position = 9 } };
    try exporter.giftRegistry().depositOwned(
        allocator,
        exporter.session_state.limits,
        gift_id_a[0..],
        deposited,
        gifter_pub.asBytes(),
    );

    // The next steps settle the parked withdraw: signature-verified, applied,
    // and answered with the deposited capability.
    while ((try exporter.step()) != .idle) {}
    var settled = exporter.takeOutbound() orelse return error.TestNoSettlement;
    defer settled.deinit();
    try std.testing.expectEqual(@as(usize, 0), exporter.pending_withdraws.items.len);
    try std.testing.expect(exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));
}

test "third-party handoff rejects a give signed by a key other than the recorded gifter" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x51));
    const forger_secret = crypto.SecretKey.fromSeed(repeated(32, 0x99));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x52));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    // The give is signed by the forger, not the gifter the exporter records.
    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &forger_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // The exporter records the *legitimate* gifter's key at deposit.
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, give, gifter_pub.asBytes());
    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
    }

    const stored_gifter = exporter.giftRegistry().giftGifterKey(gift_id_a[0..]).?;
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = try crypto.PeerKey.fromSlice(stored_gifter),
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    // The give signature was made by the forger, so it fails against the recorded
    // gifter key and the withdrawal is refused.
    try std.testing.expectError(
        cross_peer.Error.SignatureRejected,
        cross_peer.withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make()),
    );
    try std.testing.expect(!exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));
}

test "third-party handoff routes a give and authorizes a withdrawal across peers" {
    const allocator = std.testing.allocator;
    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]), "");

    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.handoff, event.kind());
    }
    try std.testing.expect(exporter.giftRegistry().giftDeposited(gift_id_a[0..]));
    try std.testing.expect(!exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        cross_peer.acceptingVerifier(),
    );

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(engine.EventKind.handoff, event.kind());
    }
    try std.testing.expect(exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));
}

test "third-party handoff rejects a replayed handoff count across peers" {
    const allocator = std.testing.allocator;
    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]), "");
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_b[0..]), "");

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 2, receive_signature[0..]),
        cross_peer.acceptingVerifier(),
    );

    try std.testing.expectError(session.Error.HandoffReplay, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_b[0..], 1, receive_signature[0..]),
        cross_peer.acceptingVerifier(),
    ));
    try std.testing.expect(!exporter.giftRegistry().giftWithdrawn(gift_id_b[0..]));
}

test "third-party handoff rejects a withdrawal whose signature fails verification" {
    const allocator = std.testing.allocator;
    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]), "");

    try std.testing.expectError(cross_peer.Error.SignatureRejected, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        RejectingVerifier.make(),
    ));
    try std.testing.expect(!exporter.giftRegistry().giftWithdrawn(gift_id_a[0..]));
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

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();

    // Deposit with no explicit gifter key: deliverGive falls back to the key the
    // exporter learned from the handshake.
    try cross_peer.deliverGive(&gx.p1, &recipient_from_gifter, &gx.p2, give, "");
    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
    }

    // The exporter recorded exactly the gifter's real session key, learned at
    // handshake — proof the key flowed from the session, not the call site.
    try std.testing.expectEqualSlices(u8, gifter_pub.asBytes(), gx.p2.giftRegistry().giftGifterKey(gift_id_a[0..]).?);

    const stored_gifter = gx.p2.giftRegistry().giftGifterKey(gift_id_a[0..]).?;
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = try crypto.PeerKey.fromSlice(stored_gifter),
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try cross_peer.withdrawGift(&recipient_to_exporter, &gx.p2, receive, verifier_ctx.make());
    try std.testing.expect(gx.p2.giftRegistry().giftWithdrawn(gift_id_a[0..]));
}

test "canonical handoff-give bytes are a stable Ed25519 signing domain an embedder can verify" {
    const allocator = std.testing.allocator;

    // The exact bytes the gifter's `desc:sig-envelope` signature covers. Before
    // this encoder existed, an embedder had no way to reconstruct them — so a
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
    // give it embeds — so the two signatures never share a payload.
    const receive = receiveWith(gift_id_a[0..], 1, receive_signature[0..]);
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    try std.testing.expect(!std.mem.eql(u8, signed, receive_signed));
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
