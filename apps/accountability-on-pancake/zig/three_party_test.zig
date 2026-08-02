//! Three-party accountability: the introduction survives a handoff.
//!
//! Three in-memory peers prove the load-bearing claim: when A introduces B to C
//! via a three-party handoff, C's Episode attributes B (the true caller), not A
//! (the introducer). The capability that B reaches C through is distinct from
//! A's, so "who called" is answered by the reference itself.
//!
//! This is the in-memory protocol-level proof. The host application owns the
//! handoff routing itself (ADR-0009/ADR-0100). The engine keeps the
//! `cross_peer.SignatureVerifier` seam and each session's gift registry, and wires the
//! accountability Episode + Identity layers through `actors.Vat` on each peer.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const cross_peer = engine.cross_peer;
const crypto = pancake.foundation.crypto;
const syrup = pancake.ocapn.codec.syrup;

const identity = @import("identity.zig");
const accountable = @import("accountable.zig");
const affordance = @import("affordance.zig");
const log = @import("log.zig");

const AFFORDANCE_EXPORT: u64 = 5;

fn shuttleAndStep(from: *engine.Peer, to: *engine.Peer) !void {
    _ = try from.step();
    while (from.takeOutbound()) |frame| {
        try to.feedOwned(frame);
    }
    _ = try to.step();
}

fn drainEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |ev| {
        var e = ev;
        e.deinit();
    }
}

// --- Host-side handoff routing (ADR-0009) -------------------------------
//
// Sibling copy: `test/support/cross_peer.zig`. This fork verifies with a real
// Ed25519 RoutingVerifier and explicitly supplies the live gifter session's
// registry; the support module uses testOnlyAcceptingVerifier() for trusted
// tests.
//
// A `Peer` owns one direct session, so routing the give and withdraw legs
// across the gifter, recipient, and exporter sessions is the host's job,
// exactly what this application does here. The engine supplies the seams
// (`cross_peer.SignatureVerifier`, the session gift registries); the frames move by
// this wiring.

const RoutingError = error{
    SignatureRejected,
    NoOutboundFrame,
};

/// Encode the `from` peer's single pending message and dispatch it on `to`.
fn pumpFrame(from: *engine.Peer, to: *engine.Peer) !void {
    _ = try from.step();
    const frame = from.takeOutbound() orelse return RoutingError.NoOutboundFrame;
    try to.feedOwned(frame);
    _ = try to.step();
}

/// The gifter's two outbound legs: deposit the gift on its exporter session,
/// then deliver the signed give to the recipient.
fn deliverGive(
    gifter_peer: *engine.Peer,
    recipient: *engine.Peer,
    exporter_peer: *engine.Peer,
    give: model.HandoffGive,
) !void {
    try exporter_peer.giftRegistry().deposit(
        exporter_peer.allocator,
        exporter_peer.limits(),
        null,
        give.gift_id,
        give.recipient_key,
    );
    try gifter_peer.sendCopying(.{ .handoff = .{ .give = give } });
    try pumpFrame(gifter_peer, recipient);
}

/// The recipient's withdraw leg: verify both certificates over their canonical
/// signed bytes through the injected verifier, authorize the withdrawal against
/// the exporter's gift registry, then send the receive to the exporter.
fn withdrawGift(
    recipient: *engine.Peer,
    exporter_peer: *engine.Peer,
    gifter_gifts: *engine.bootstrap.GiftRegistry,
    receive: model.HandoffReceive,
    verifier: cross_peer.SignatureVerifier,
) !void {
    const allocator = exporter_peer.allocator;

    const give_signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, receive.signed_give);
    defer allocator.free(give_signed);
    if (!verifier.verify(give_signed, receive.signed_give.signature)) {
        return RoutingError.SignatureRejected;
    }

    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    if (!verifier.verify(receive_signed, receive.signature)) {
        return RoutingError.SignatureRejected;
    }

    // The exporter checks the receive against names it derives from the two
    // ends of the session the withdraw arrived on, never from the receive's own
    // words. Replay authority is the Receiver–Exporter session's scalar count,
    // while the exact gift remains in the Gifter–Exporter session registry.
    // These peers never handshake, so there is nothing to derive here.
    const registry = exporter_peer.giftRegistry();
    const expected: ?engine.handoff_names.ExpectedReceiver = derived: {
        const partner_key = exporter_peer.session_state.partnerSessionKey() orelse break :derived null;
        if (exporter_peer.session_state.localSessionKey()) |our_key| {
            break :derived try engine.handoff_names.ExpectedReceiver.derive(partner_key, our_key);
        }
        break :derived try engine.handoff_names.ExpectedReceiver.fromPartner(partner_key);
    };
    try registry.validateWithdrawEnvelope(receive, expected);
    try gifter_gifts.validateWithdrawGift(receive);
    _ = try registry.applyWithdraw(gifter_gifts, exporter_peer.allocator, null, receive);

    try recipient.sendCopying(.{ .handoff = .{ .receive = receive } });
    try pumpFrame(recipient, exporter_peer);
}

/// A real Ed25519 verifier that routes each handoff certificate to the right key
/// (ADR-0009): a `desc:handoff-receive` payload is checked against the recipient
/// key, and the embedded `desc:handoff-give` against the gifter's session key. The
/// exporter builds it from the live gifter session and the recipient key the
/// give names, no key is copied into a gift row. This is the production
/// shape, not a key-agnostic accept-all verifier: a forged or
/// mismatched certificate is rejected here, so the withdrawal that re-targets B's
/// session is itself attested, not merely asserted.
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

test "three-party handoff: C attributes B (the true caller), not A (the introducer)" {
    const allocator = std.testing.allocator;

    // The standard five-peer topology (ADR-0009/ADR-0100):
    //   gifter (A)        is gifter-to-recipient (A to B)
    //   recipient-from-A  is B's view of A's session
    //   recipient-to-C    is B's view of C's session
    //   exporter-from-A   receives the deposit on the A-C session
    //   exporter (C)      receives the withdrawal and B's later direct call
    //
    // A introduces B to C. After the handoff, B reaches C's Affordance
    // through a direct session. C's Episode must attribute B, not A.

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter_from_gifter = engine.Peer.init(allocator);
    defer exporter_from_gifter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // C (exporter) creates a KERI identity and accountability store.
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();
    const tio = io.io();

    var c_id = try identity.Identity.incept(allocator, tio);
    defer c_id.deinit();
    const data_dir = "apps/accountability-on-pancake/.data/three-party-test";
    var c_store = try accountable.Store.init(allocator, tio, &c_id, data_dir);
    defer c_store.deinit();

    // C publishes the Affordance.
    var served: usize = 0;
    var last_subject = [_]u8{0} ** identity.SAID_LEN;
    var c_vat = actors.Vat.init(allocator);
    defer c_vat.deinit();
    var c_port = actors.Port.init(allocator, &exporter);
    defer c_port.deinit(&c_vat);
    const aff = try c_vat.spawn(affordance.Affordance, .{
        .store = &c_store,
        .last_subject = &last_subject,
        .served = &served,
    });
    try c_port.bindExport(&c_vat, aff, AFFORDANCE_EXPORT);
    // This test routes the handoff by hand (B imports the affordance position
    // out-of-band after the withdrawal), so C grants the bound position
    // explicitly; a withdraw served through the engine's bootstrap responder
    // would grant it by marshaling the resolve instead.
    try exporter.exportObject(AFFORDANCE_EXPORT);

    // --- Three-party handoff: A introduces B to C, under real certificates ---
    // A (gifter) and B (recipient) hold real Ed25519 session keys. A signs the
    // give; B signs the receive that embeds it. Nothing here is a placeholder
    // signature, so C authorizes the withdrawal only because the certificates
    // actually verify.
    const gifter_secret = crypto.SecretKey.fromSeed([_]u8{0x51} ** 32);
    const recipient_secret = crypto.SecretKey.fromSeed([_]u8{0x52} ** 32);
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // B names the side it really is on the session it withdraws over.
    const recipient_side = try engine.handoff_recipient.sideName(recipient_pub.asBytes());

    const gift_id = [_]u8{0x42} ** 32;
    var give: model.HandoffGive = .{
        .recipient_key = recipient_pub.asBytes(),
        .exporter = .{ .transport = "memory", .designator = "C" },
        .gifter_exporter_session = &([_]u8{0} ** 32),
        .gifter_side = &([_]u8{0} ** 32),
        .gift_id = &gift_id,
        .signature = "",
    };
    const give_signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(give_signed);
    const give_sig = crypto.sign(&gifter_secret, give_signed);
    give.signature = give_sig.asBytes();

    // A deposits the gift in its A-C session and delivers the give certificate
    // to B. The row carries no copied session key.
    try deliverGive(&gifter, &recipient_from_gifter, &exporter_from_gifter, give);
    drainEvents(&recipient_from_gifter);
    drainEvents(&exporter);

    // B builds the receive over the signed give and signs it with its own key.
    var receive: model.HandoffReceive = .{
        .receiving_session = &([_]u8{0xdd} ** 32),
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    // C verifies both certificates with keys routed per ADR-0009 — the live A-C
    // session key and the recipient key the give names — then consumes from the
    // A-C gift table while recording replay on B-C.
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = gifter_pub,
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try withdrawGift(&recipient_to_exporter, &exporter, exporter_from_gifter.giftRegistry(), receive, verifier_ctx.make());
    drainEvents(&exporter);

    // After withdrawal, B can reach C directly. B's Vat sends to C's export.
    try recipient_to_exporter.importObject(AFFORDANCE_EXPORT);

    // --- B invokes the Affordance with its own KERI attestation ---
    // B rotates once before it calls, so the log C reads is a chain and not a
    // lone inception event: C has to walk the rotation, hold the pre-rotation
    // commitment, and land on the key B actually signs with.
    var b_id = try identity.Identity.incept(allocator, tio);
    defer b_id.deinit();
    _ = try b_id.rotate(tio);

    const request = "read-thermostat";
    const att = try affordance.Attestation.sign(allocator, b_id.current, &b_id.aid, request, false);

    // B sends via its Vat over the B-to-C (recipient_to_exporter) session.
    var b_vat = actors.Vat.init(allocator);
    defer b_vat.deinit();
    var b_port = actors.Port.init(allocator, &recipient_to_exporter);
    defer b_port.deinit(&b_vat);
    const ref: actors.Ref = .{ .far = model.FarRef.object(AFFORDANCE_EXPORT) };
    _ = try b_port.send(&b_vat, ref, .{
        .verb = affordance.invoke_verb,
        .args = &.{
            .{ .string = b_id.aidSlice() },
            .{ .string = &att.verkey },
            .{ .string = request },
            .{ .string = &att.signature },
            .{ .string = b_id.kelSlice() },
        },
    });

    // Shuttle B→C (deliver), step C, serve on C.
    try shuttleAndStep(&recipient_to_exporter, &exporter);
    while (exporter.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = c_port.serve(&c_vat, &e) catch {};
    }

    // C attributes the attested caller, B, not the introducer, A.
    try std.testing.expect(served == 1);
    try std.testing.expectEqualSlices(u8, b_id.aidSlice(), last_subject[0..identity.SAID_LEN]);

    // The Episode is verifiable and the transparency log is stable.
    const audited = try c_store.auditAll();
    try std.testing.expectEqual(@as(usize, 1), audited);
    const root = try c_store.currentRoot();
    _ = log.toHex(root);
}
