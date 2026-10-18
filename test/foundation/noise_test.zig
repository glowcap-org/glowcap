//! The published cacophony test vectors drive `foundation.noise` byte for
//! byte, both roles, handshake and transport, so the state machine answers to
//! an authority outside this repository (ADR-0107, evidence item 1). Unit
//! tests beside the vectors cover what a fixed transcript cannot: refusal
//! paths, nonce exhaustion, rekey, record framing, and the Ed25519-to-X25519
//! conversion agreeing with itself across both halves of a key.
//!
//! Vector provenance: `noise_vectors/cacophony_xk_25519_chachapoly_blake2s.json`
//! is the single `Noise_XK_25519_ChaChaPoly_BLAKE2s` entry of the
//! cacophony-generated corpus vendored by the snow project, fetched 2026-08-09
//! from
//! https://raw.githubusercontent.com/mcginty/snow/master/tests/vectors/cacophony.txt
//! (sha256 3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae),
//! extracted by exact `protocol_name` match with every field verbatim.

const std = @import("std");
const glowcap = @import("glowcap");

const crypto = glowcap.foundation.crypto;
const noise = glowcap.foundation.noise;

const vector_json = @embedFile("noise_vectors/cacophony_xk_25519_chachapoly_blake2s.json");

const VectorMessage = struct {
    payload: []const u8,
    ciphertext: []const u8,
};

const Vector = struct {
    protocol_name: []const u8,
    init_prologue: []const u8,
    init_static: []const u8,
    init_ephemeral: []const u8,
    init_remote_static: []const u8,
    resp_prologue: []const u8,
    resp_static: []const u8,
    resp_ephemeral: []const u8,
    handshake_hash: []const u8,
    messages: []const VectorMessage,
};

fn hex32(hex: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    const written = try std.fmt.hexToBytes(&out, hex);
    try std.testing.expectEqual(@as(usize, 32), written.len);
    return out;
}

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    const written = try std.fmt.hexToBytes(out, hex);
    try std.testing.expectEqual(out.len, written.len);
    return out;
}

test "cacophony XK vector: both roles, all messages, byte for byte" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Vector, allocator, vector_json, .{});
    defer parsed.deinit();
    const vec = parsed.value;

    try std.testing.expectEqualStrings(noise.protocol_name, vec.protocol_name);
    try std.testing.expectEqual(@as(usize, 6), vec.messages.len);

    const init_static = crypto.X25519KeyMaterial.fromSecret(try hex32(vec.init_static));
    const init_ephemeral = crypto.X25519KeyMaterial.fromSecret(try hex32(vec.init_ephemeral));
    const resp_static = crypto.X25519KeyMaterial.fromSecret(try hex32(vec.resp_static));
    const resp_ephemeral = crypto.X25519KeyMaterial.fromSecret(try hex32(vec.resp_ephemeral));
    const init_remote_static = try hex32(vec.init_remote_static);

    // The vector's `init_remote_static` is the responder's public key; the
    // corpus is internally consistent about that, and this pins it.
    try std.testing.expectEqualSlices(u8, &resp_static.public, &init_remote_static);

    const prologue = try hexAlloc(allocator, vec.init_prologue);
    defer allocator.free(prologue);
    const resp_prologue = try hexAlloc(allocator, vec.resp_prologue);
    defer allocator.free(resp_prologue);
    try std.testing.expectEqualSlices(u8, prologue, resp_prologue);

    var initiator = noise.HandshakeState.initInitiator(
        &init_static,
        init_remote_static,
        &init_ephemeral,
        prologue,
    );
    var responder = noise.HandshakeState.initResponder(&resp_static, &resp_ephemeral, prologue);

    // The three handshake messages: initiator writes 0 and 2, responder 1.
    var out_buf: [1024]u8 = undefined;
    var payload_buf: [1024]u8 = undefined;
    for (vec.messages[0..3], 0..) |msg, index| {
        const payload = try hexAlloc(allocator, msg.payload);
        defer allocator.free(payload);
        const ciphertext = try hexAlloc(allocator, msg.ciphertext);
        defer allocator.free(ciphertext);

        const writer = if (index % 2 == 0) &initiator else &responder;
        const reader = if (index % 2 == 0) &responder else &initiator;
        const written = try writer.writeMessage(payload, &out_buf);
        try std.testing.expectEqualSlices(u8, ciphertext, written);
        const read_back = try reader.readMessage(ciphertext, &payload_buf);
        try std.testing.expectEqualSlices(u8, payload, read_back);
    }

    // The responder ends the handshake knowing the initiator's static point.
    try std.testing.expectEqualSlices(
        u8,
        &init_static.public,
        &responder.remoteStatic().?,
    );

    var init_keys = try initiator.split();
    var resp_keys = try responder.split();
    const expected_hash = try hex32(vec.handshake_hash);
    try std.testing.expectEqualSlices(u8, &expected_hash, &init_keys.handshake_hash);
    try std.testing.expectEqualSlices(u8, &expected_hash, &resp_keys.handshake_hash);

    // Transport messages keep the handshake's alternation going: the third
    // handshake message was the initiator's, so the responder speaks next.
    for (vec.messages[3..], 0..) |msg, index| {
        const payload = try hexAlloc(allocator, msg.payload);
        defer allocator.free(payload);
        const ciphertext = try hexAlloc(allocator, msg.ciphertext);
        defer allocator.free(ciphertext);

        const sender = if (index % 2 == 0) &resp_keys else &init_keys;
        const receiver = if (index % 2 == 0) &init_keys else &resp_keys;
        const sealed = try sender.send.encrypt("", payload, &out_buf);
        try std.testing.expectEqualSlices(u8, ciphertext, sealed);
        const opened = try receiver.recv.decrypt("", ciphertext, &payload_buf);
        try std.testing.expectEqualSlices(u8, payload, opened);
    }

    init_keys.send.deinit();
    init_keys.recv.deinit();
    resp_keys.send.deinit();
    resp_keys.recv.deinit();
}

/// A fresh deterministic handshake pair for the unit tests below. The seeds
/// only need to be distinct, not secret.
const Fixture = struct {
    init_static: crypto.X25519KeyMaterial,
    resp_static: crypto.X25519KeyMaterial,

    fn make() Fixture {
        return .{
            .init_static = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(0x11))),
            .resp_static = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(0x22))),
        };
    }

    fn initiator(self: *const Fixture, ephemeral_seed: u8, prologue: []const u8) noise.HandshakeState {
        const ephemeral = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(ephemeral_seed)));
        return noise.HandshakeState.initInitiator(
            &self.init_static,
            self.resp_static.public,
            &ephemeral,
            prologue,
        );
    }

    fn responder(self: *const Fixture, ephemeral_seed: u8, prologue: []const u8) noise.HandshakeState {
        const ephemeral = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(ephemeral_seed)));
        return noise.HandshakeState.initResponder(
            &self.resp_static,
            &ephemeral,
            prologue,
        );
    }
};

test "a prologue mismatch diverges the transcript and refuses the first payload" {
    const fixture = Fixture.make();
    var dialer = fixture.initiator(0x31, "noise-tcp\x00abc");
    var answerer = fixture.responder(0x41, "noise-tcp\x00abd");
    var msg: [256]u8 = undefined;
    var payload: [256]u8 = undefined;
    const written = try dialer.writeMessage("hello", &msg);
    try std.testing.expectError(
        noise.NoiseError.DecryptFailed,
        answerer.readMessage(written, &payload),
    );
    dialer.deinit();
    answerer.deinit();
}

test "a tampered third message is refused" {
    const fixture = Fixture.make();
    var dialer = fixture.initiator(0x31, "p");
    var answerer = fixture.responder(0x41, "p");
    var a_to_b: [256]u8 = undefined;
    var b_to_a: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const msg1 = try dialer.writeMessage("", &a_to_b);
    _ = try answerer.readMessage(msg1, &scratch);
    const msg2 = try answerer.writeMessage("", &b_to_a);
    _ = try dialer.readMessage(msg2, &scratch);
    const msg3 = try dialer.writeMessage("", &a_to_b);

    // Flip one bit inside the sealed static; the responder must refuse.
    var forged: [256]u8 = undefined;
    @memcpy(forged[0..msg3.len], msg3);
    forged[3] ^= 0x01;
    try std.testing.expectError(
        noise.NoiseError.DecryptFailed,
        answerer.readMessage(forged[0..msg3.len], &scratch),
    );
    dialer.deinit();
    answerer.deinit();
}

test "a recorded third message replayed at a fresh responder is refused" {
    const fixture = Fixture.make();
    var dialer = fixture.initiator(0x31, "p");
    var answerer = fixture.responder(0x41, "p");
    var msg1_buf: [256]u8 = undefined;
    var msg3_buf: [256]u8 = undefined;
    var b_to_a: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const msg1 = try dialer.writeMessage("", &msg1_buf);
    _ = try answerer.readMessage(msg1, &scratch);
    const msg2 = try answerer.writeMessage("", &b_to_a);
    _ = try dialer.readMessage(msg2, &scratch);
    const msg3 = try dialer.writeMessage("", &msg3_buf);

    // A second session at the same responder identity uses a fresh ephemeral,
    // so the recorded closer does not match any key it derived.
    var replay_target = fixture.responder(0x42, "p");
    _ = try replay_target.readMessage(msg1, &scratch);
    var replay_msg2: [256]u8 = undefined;
    _ = try replay_target.writeMessage("", &replay_msg2);
    try std.testing.expectError(
        noise.NoiseError.DecryptFailed,
        replay_target.readMessage(msg3, &scratch),
    );
    dialer.deinit();
    answerer.deinit();
    replay_target.deinit();
}

test "truncated and oversized handshake messages are refused by shape" {
    const fixture = Fixture.make();
    var answerer = fixture.responder(0x41, "p");
    var scratch: [70000]u8 = undefined;
    try std.testing.expectError(
        noise.NoiseError.MessageTooShort,
        answerer.readMessage(scratch[0..31], scratch[256..]),
    );
    try std.testing.expectError(
        noise.NoiseError.PayloadTooLong,
        answerer.readMessage(scratch[0 .. noise.max_message_bytes + 1], scratch[0..0]),
    );
    answerer.deinit();
}

test "a short handshake output buffer leaves the transcript retryable" {
    const fixture = Fixture.make();
    var dialer = fixture.initiator(0x31, "p");
    defer dialer.deinit();
    var answerer = fixture.responder(0x41, "p");
    defer answerer.deinit();
    var wire: [256]u8 = undefined;
    const msg1 = try dialer.writeMessage("identity payload", &wire);
    try std.testing.expectError(
        noise.NoiseError.BufferTooSmall,
        answerer.readMessage(msg1, &.{}),
    );
    var payload: [32]u8 = undefined;
    const opened = try answerer.readMessage(msg1, &payload);
    try std.testing.expectEqualStrings("identity payload", opened);
}

test "split before the third message is refused" {
    const fixture = Fixture.make();
    var dialer = fixture.initiator(0x31, "p");
    var msg: [256]u8 = undefined;
    _ = try dialer.writeMessage("", &msg);
    try std.testing.expectError(noise.NoiseError.HandshakeNotComplete, dialer.split());
    dialer.deinit();
}

test "nonce exhaustion refuses the reserved value in both directions" {
    var cipher = noise.CipherState.init(@as([32]u8, @splat(0x07)));
    cipher.n = std.math.maxInt(u64);
    var out: [64]u8 = undefined;
    try std.testing.expectError(noise.NoiseError.NonceExhausted, cipher.encrypt("", "x", &out));
    try std.testing.expectError(
        noise.NoiseError.NonceExhausted,
        cipher.decrypt("", out[0..17], &out),
    );

    cipher.n = std.math.maxInt(u64) - 2;
    try cipher.ensureNonceCapacity(2);
    try std.testing.expectError(noise.NoiseError.NonceExhausted, cipher.ensureNonceCapacity(3));
}

test "rekey preserves the nonce and keeps both directions in agreement" {
    var sender = noise.CipherState.init(@as([32]u8, @splat(0x07)));
    var receiver = noise.CipherState.init(@as([32]u8, @splat(0x07)));
    var sealed_buf: [64]u8 = undefined;
    var open_buf: [64]u8 = undefined;

    const before = try sender.encrypt("", "before rekey", &sealed_buf);
    _ = try receiver.decrypt("", before, &open_buf);
    try std.testing.expectEqual(@as(u64, 1), sender.n);
    try std.testing.expectEqual(@as(u64, 1), receiver.n);
    var stale = sender;
    sender.rekey();
    receiver.rekey();
    // Noise REKEY replaces k but does not reinitialize CipherState or n.
    try std.testing.expectEqual(@as(u64, 1), sender.n);
    try std.testing.expectEqual(@as(u64, 1), receiver.n);
    const sealed = try sender.encrypt("", "after rekey", &sealed_buf);
    const opened = try receiver.decrypt("", sealed, &open_buf);
    try std.testing.expectEqualStrings("after rekey", opened);
    // The pre-rekey key does not open what the rekeyed key seals.
    var stale_out: [64]u8 = undefined;
    try std.testing.expectError(
        noise.NoiseError.DecryptFailed,
        stale.decrypt("", sealed, &stale_out),
    );
    sender.deinit();
    receiver.deinit();
    stale.deinit();
}

test "record framing round-trips and holds its bounds" {
    var sender = noise.CipherState.init(@as([32]u8, @splat(0x09)));
    var receiver = noise.CipherState.init(@as([32]u8, @splat(0x09)));
    var record_buf: [512]u8 = undefined;
    var open_buf: [512]u8 = undefined;

    const record = try noise.sealRecord(&sender, "one captp frame", &record_buf);
    const body_len = noise.recordBodyLen(record[0..noise.record_header_bytes].*);
    try std.testing.expectEqual(record.len - noise.record_header_bytes, body_len);
    const opened = try noise.openRecord(&receiver, record[noise.record_header_bytes..], &open_buf);
    try std.testing.expectEqualStrings("one captp frame", opened);

    var big: [noise.max_record_plaintext_bytes + 1]u8 = undefined;
    @memset(&big, 0);
    var big_out: [noise.max_record_bytes + noise.record_header_bytes + 1]u8 = undefined;
    try std.testing.expectError(
        noise.NoiseError.PayloadTooLong,
        noise.sealRecord(&sender, &big, &big_out),
    );
    sender.deinit();
    receiver.deinit();
}

test "Ed25519 conversion agrees across both halves and both peers" {
    const alice = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0xA1)));
    const bob = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0xB2)));

    const alice_material = crypto.x25519FromSecretKey(&alice).?;
    const bob_material = crypto.x25519FromSecretKey(&bob).?;

    // The secret-side and public-side conversions land on the same point.
    try std.testing.expectEqualSlices(
        u8,
        &alice_material.public,
        &crypto.x25519FromPeerKey(alice.publicKey()).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &bob_material.public,
        &crypto.x25519FromPeerKey(bob.publicKey()).?,
    );

    // And Diffie-Hellman commutes across the converted pairs, which is the
    // property the whole handshake stands on.
    const ab = try std.crypto.dh.X25519.scalarmult(alice_material.secret, bob_material.public);
    const ba = try std.crypto.dh.X25519.scalarmult(bob_material.secret, alice_material.public);
    try std.testing.expectEqualSlices(u8, &ab, &ba);
}

test "a full handshake through converted durable keys settles both ways" {
    const dialer_identity = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0xC3)));
    const answerer_identity = crypto.SecretKey.fromSeed(@as([32]u8, @splat(0xD4)));
    const dialer_static = crypto.x25519FromSecretKey(&dialer_identity).?;
    const answerer_static = crypto.x25519FromSecretKey(&answerer_identity).?;
    const answerer_point = crypto.x25519FromPeerKey(answerer_identity.publicKey()).?;
    const dialer_ephemeral = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(0x51)));
    const answerer_ephemeral = crypto.X25519KeyMaterial.fromSecret(@as([32]u8, @splat(0x61)));

    var dialer = noise.HandshakeState.initInitiator(
        &dialer_static,
        answerer_point,
        &dialer_ephemeral,
        "noise-tcp\x00designator",
    );
    var answerer = noise.HandshakeState.initResponder(
        &answerer_static,
        &answerer_ephemeral,
        "noise-tcp\x00designator",
    );

    var a_to_b: [256]u8 = undefined;
    var b_to_a: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;

    // The third payload carries the dialer's Ed25519 key, the wire shape the
    // sealed channel uses to recover the designator the X25519 point cannot
    // give back.
    _ = try answerer.readMessage(try dialer.writeMessage("", &a_to_b), &scratch);
    _ = try dialer.readMessage(try answerer.writeMessage("", &b_to_a), &scratch);
    const identity_payload = try answerer.readMessage(
        try dialer.writeMessage(dialer_identity.publicKey().asBytes(), &a_to_b),
        &scratch,
    );

    const claimed = try crypto.PeerKey.fromSlice(identity_payload);
    try std.testing.expectEqualSlices(
        u8,
        &answerer.remoteStatic().?,
        &crypto.x25519FromPeerKey(claimed).?,
    );

    var dialer_keys = try dialer.split();
    var answerer_keys = try answerer.split();
    defer {
        dialer_keys.send.deinit();
        dialer_keys.recv.deinit();
        answerer_keys.send.deinit();
        answerer_keys.recv.deinit();
    }
    const sealed = try dialer_keys.send.encrypt("", "first sealed frame", &a_to_b);
    const opened = try answerer_keys.recv.decrypt("", sealed, &scratch);
    try std.testing.expectEqualStrings("first sealed frame", opened);
}
