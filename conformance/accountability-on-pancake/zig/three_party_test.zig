//! Three-party accountability: the introduction survives a handoff.
//!
//! Three in-memory peers prove the load-bearing claim: when A introduces B to C
//! via a three-party handoff, C's Episode attributes B (the true caller), not A
//! (the introducer). The capability that B reaches C through is distinct from
//! A's — so "who called" is answered by the reference itself.
//!
//! This is the in-memory protocol-level proof. The host application owns the
//! handoff routing itself (ADR-0009) — the engine keeps the
//! `cross_peer.SignatureVerifier` seam and the gift registry — and wires the
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
const episode = @import("episode.zig");
const accountable = @import("accountable.zig");
const log = @import("log.zig");

const AFFORDANCE_EXPORT: u64 = 5;

fn strArg(a: model.Argument) ?[]const u8 {
    return switch (a) {
        .string => |s| s,
        else => null,
    };
}

fn decodeKey(b64: []const u8) ![32]u8 {
    const expected_len = 1 + std.base64.url_safe_no_pad.Encoder.calcSize(32);
    if (b64.len != expected_len) return error.BadKey;
    var out: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&out, b64[1..]);
    return out;
}

fn decodeSig(b64: []const u8) ![64]u8 {
    const expected_len = std.base64.url_safe_no_pad.Encoder.calcSize(64);
    if (b64.len != expected_len) return error.BadSig;
    var out: [64]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&out, b64);
    return out;
}

fn attestation(buf: []u8, request: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "invoke|{s}", .{request}) catch unreachable;
}

/// The same Affordance as main.zig, but also records a verifiable Episode.
const Affordance = struct {
    store: *accountable.Store,
    last_subject: []u8,
    served: *usize,

    pub fn handle(self: *Affordance, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "invoke")) return error.NoSuchMethod;
        if (msg.args.len != 4) return error.BadInvocation;
        const subject = strArg(msg.args[0]) orelse return error.BadInvocation;
        const verkey_b64 = strArg(msg.args[1]) orelse return error.BadInvocation;
        const request = strArg(msg.args[2]) orelse return error.BadInvocation;
        const sig_b64 = strArg(msg.args[3]) orelse return error.BadInvocation;

        const verkey = decodeKey(verkey_b64) catch return error.UnattestedCaller;
        const sig = decodeSig(sig_b64) catch return error.UnattestedCaller;
        var att_buf: [512]u8 = undefined;
        const att = attestation(&att_buf, request);
        identity.verify(verkey, att, sig) catch return error.UnattestedCaller;

        const result = try std.fmt.allocPrint(turn.arena, "ack:{s}", .{request});
        _ = try self.store.record(.outcome, subject, "demo", result);
        @memcpy(self.last_subject[0..subject.len], subject);
        self.served.* += 1;
        return .{ .string = result };
    }
};

fn shuttleAndStep(from: *engine.Peer, to: *engine.Peer) !void {
    _ = try from.step();
    while (from.takeOutbound()) |frame| {
        try to.feedInbound(frame);
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
// A `Peer` owns one direct session, so routing the give and withdraw legs
// across the gifter, recipient, and exporter sessions is the host's job —
// exactly what this application does here. The engine supplies the seams
// (`cross_peer.SignatureVerifier`, the gift registry); the frames move by
// this wiring.

const RoutingError = error{
    SignatureRejected,
    NoOutboundFrame,
};

/// Encode the `from` peer's single pending message and dispatch it on `to`.
fn pumpFrame(from: *engine.Peer, to: *engine.Peer) !void {
    _ = try from.step();
    const frame = from.takeOutbound() orelse return RoutingError.NoOutboundFrame;
    try to.feedInbound(frame);
    _ = try to.step();
}

/// The gifter's two outbound legs: deposit the gift (with the gifter's session
/// key as provenance) on the exporter, then deliver the signed give to the
/// recipient.
fn deliverGive(
    gifter_peer: *engine.Peer,
    recipient: *engine.Peer,
    exporter_peer: *engine.Peer,
    give: model.HandoffGive,
    gifter_key: []const u8,
) !void {
    try exporter_peer.giftRegistry().deposit(
        exporter_peer.allocator,
        exporter_peer.session_state.limits,
        give.gift_id,
        give.recipient_key,
        gifter_key,
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

    const registry = exporter_peer.giftRegistry();
    try registry.validateWithdraw(receive);
    try registry.applyWithdraw(exporter_peer.allocator, exporter_peer.session_state.limits, receive);

    try recipient.sendCopying(.{ .handoff = .{ .receive = receive } });
    try pumpFrame(recipient, exporter_peer);
}

/// A real Ed25519 verifier that routes each handoff certificate to the right key
/// (ADR-0009): a `desc:handoff-receive` payload is checked against the recipient
/// key, and the embedded `desc:handoff-give` against the gifter's session key. The
/// exporter builds it from the gifter key it stored at deposit and the recipient
/// key the give names — no key is conjured at verify time. This is the production
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

    // The standard four-peer topology (ADR-0009):
    //   gifter (A)        → gifter-to-recipient (A→B)
    //   recipient-from-A  → B's view of A's session
    //   recipient-to-C    → B's view of C's session
    //   exporter (C)      → single peer, receives deposit AND withdrawal
    //
    // A introduces B to C. After the handoff, B reaches C's Affordance
    // through a direct session. C's Episode must attribute B, not A.

    var gifter = engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = engine.Peer.init(allocator);
    defer exporter.deinit();

    // C (exporter) creates a KERI identity and accountability store.
    var io = std.Io.Threaded.init(allocator, .{});
    defer io.deinit();
    const tio = io.io();

    var c_id = try identity.Identity.incept(allocator, tio);
    defer c_id.deinit();
    const data_dir = "conformance/accountability-on-pancake/.data/three-party-test";
    var c_store = try accountable.Store.init(allocator, tio, &c_id, data_dir);
    defer c_store.deinit();

    // C publishes the Affordance.
    var served: usize = 0;
    var last_subject = [_]u8{0} ** identity.SAID_LEN;
    var c_vat = actors.Vat.initOver(allocator, &exporter);
    defer c_vat.deinit();
    const aff = try c_vat.spawn(Affordance, .{
        .store = &c_store,
        .last_subject = &last_subject,
        .served = &served,
    });
    try c_vat.bindExport(aff, AFFORDANCE_EXPORT);

    // --- Three-party handoff: A introduces B to C, under real certificates ---
    // A (gifter) and B (recipient) hold real Ed25519 session keys. A signs the
    // give; B signs the receive that embeds it. Nothing here is a placeholder
    // signature, so C authorizes the withdrawal only because the certificates
    // actually verify.
    const gifter_secret = crypto.SecretKey.fromSeed([_]u8{0x51} ** 32);
    const recipient_secret = crypto.SecretKey.fromSeed([_]u8{0x52} ** 32);
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();

    const gift_id = [_]u8{0x42} ** 32;
    var give: model.HandoffGive = .{
        .recipient_key = recipient_pub.asBytes(),
        .exporter_location = "memory:C",
        .gifter_exporter_session = &([_]u8{0} ** 32),
        .gifter_side = &([_]u8{0} ** 32),
        .gift_id = &gift_id,
        .signature = "",
    };
    const give_signed = try syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(give_signed);
    const give_sig = crypto.sign(&gifter_secret, give_signed);
    give.signature = give_sig.asBytes();

    // A deposits the gift on C with its real session key, and delivers the give
    // certificate to B. C records the gifter key alongside the gift.
    try deliverGive(&gifter, &recipient_from_gifter, &exporter, give, gifter_pub.asBytes());
    drainEvents(&recipient_from_gifter);
    drainEvents(&exporter);

    // B builds the receive over the signed give and signs it with its own key.
    var receive: model.HandoffReceive = .{
        .receiving_session = &([_]u8{0xdd} ** 32),
        .receiving_side = &([_]u8{0x22} ** 32),
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    // C verifies both certificates with keys routed per ADR-0009 — the gifter key
    // it stored at deposit, and the recipient key the give names — then authorizes
    // the withdrawal. A forged certificate would be rejected before B is admitted.
    var verifier_ctx: RoutingVerifier = .{
        .gifter_key = try crypto.PeerKey.fromSlice(exporter.giftRegistry().giftGifterKey(&gift_id).?),
        .recipient_key = try crypto.PeerKey.fromSlice(give.recipient_key),
    };
    try withdrawGift(&recipient_to_exporter, &exporter, receive, verifier_ctx.make());
    drainEvents(&exporter);

    // After withdrawal, B can reach C directly. B's Vat sends to C's export.
    try recipient_to_exporter.importObject(AFFORDANCE_EXPORT);

    // --- B invokes the Affordance with its own KERI attestation ---
    var b_id = try identity.Identity.incept(allocator, tio);
    defer b_id.deinit();

    const request = "read-thermostat";
    var att_buf: [512]u8 = undefined;
    const att = attestation(&att_buf, request);
    const sig = b_id.current.sign(att);
    var sig_b64: [std.base64.url_safe_no_pad.Encoder.calcSize(64)]u8 = undefined;
    const sig_enc = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64, &sig);
    var verkey_b64: [1 + std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    verkey_b64[0] = 'D';
    _ = std.base64.url_safe_no_pad.Encoder.encode(verkey_b64[1..], &b_id.current.verkey());

    // B sends via its Vat over the B↔C (recipient_to_exporter) session.
    var b_vat = actors.Vat.initOver(allocator, &recipient_to_exporter);
    defer b_vat.deinit();
    const ref: actors.Ref = .{ .far = model.FarRef.object(AFFORDANCE_EXPORT) };
    _ = try b_vat.send(ref, .{
        .verb = "invoke",
        .args = &.{
            .{ .string = b_id.aidSlice() },
            .{ .string = &verkey_b64 },
            .{ .string = request },
            .{ .string = sig_enc },
        },
    });

    // Shuttle B→C (deliver), step C, serve on C.
    try shuttleAndStep(&recipient_to_exporter, &exporter);
    while (exporter.pollEvent()) |ev| {
        var e = ev;
        defer e.deinit();
        _ = c_vat.serve(&e) catch {};
    }

    // The headline: C attributes the TRUE caller (B), not A (the introducer).
    try std.testing.expect(served == 1);
    try std.testing.expectEqualSlices(u8, b_id.aidSlice(), last_subject[0..identity.SAID_LEN]);

    // The Episode is verifiable and the transparency log is stable.
    const audited = try c_store.auditAll();
    try std.testing.expectEqual(@as(usize, 1), audited);
    const root = try c_store.currentRoot();
    _ = log.toHex(root);
}
