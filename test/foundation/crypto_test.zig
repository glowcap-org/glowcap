const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const PeerKey = pancake.foundation.PeerKey;
const SecretKey = pancake.foundation.SecretKey;
const CryptoError = pancake.foundation.CryptoError;

const SEED_A = [_]u8{7} ** 32;
const SEED_B = [_]u8{9} ** 32;

fn hex32(comptime s: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "sign then verify roundtrips" {
    const secret = SecretKey.fromSeed(SEED_A);
    const pubkey = secret.publicKey();
    const payload = "the quick brown fox jumps over the lazy dog";
    const sig = crypto.sign(&secret, payload);
    try crypto.verify(pubkey, payload, sig);
}

test "verify rejects tampered payload" {
    const secret = SecretKey.fromSeed(SEED_A);
    const sig = crypto.sign(&secret, "original payload");
    try std.testing.expectError(
        CryptoError.InvalidSignature,
        crypto.verify(secret.publicKey(), "tampered payload", sig),
    );
}

test "verify rejects wrong pubkey" {
    const secret_a = SecretKey.fromSeed(SEED_A);
    const secret_b = SecretKey.fromSeed(SEED_B);
    const payload = "hello";
    const sig = crypto.sign(&secret_a, payload);
    try std.testing.expectError(
        CryptoError.InvalidSignature,
        crypto.verify(secret_b.publicKey(), payload, sig),
    );
}

test "verify rejects bit-flipped signature" {
    const secret = SecretKey.fromSeed(SEED_A);
    const payload = "hello";
    var sig = crypto.sign(&secret, payload);
    sig.bytes[0] ^= 0x01;
    try std.testing.expectError(
        CryptoError.InvalidSignature,
        crypto.verify(secret.publicKey(), payload, sig),
    );
}

test "verify with arbitrary bytes returns typed error, never panics" {
    const pubkey = PeerKey.fromBytes([_]u8{0} ** 32);
    const sig = crypto.Signature.fromBytes([_]u8{0} ** 64);
    const result = crypto.verify(pubkey, "payload", sig);
    try std.testing.expect(std.meta.isError(result));
}

test "secret key seed round-trips to the same public key" {
    const secret = SecretKey.fromSeed(SEED_A);
    const seed = secret.seed();
    const reconstructed = SecretKey.fromSeed(seed);
    try std.testing.expect(secret.publicKey().eql(reconstructed.publicKey()));
}

test "public key for fixed seed matches known answer" {
    const secret = SecretKey.fromSeed(SEED_A);
    try std.testing.expectEqualSlices(
        u8,
        &hex32("ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"),
        secret.publicKey().asBytes(),
    );
}

test "derivePublicIdentifier matches externally-computed SHA256 double-hash" {
    // Known answer computed independently (Node crypto) over the OCapN gcrypt
    // s-expression for the fixed-seed public key, cross-checks the hand-rolled
    // Syrup canonical encoding and the double-SHA256 against a second toolchain.
    const secret = SecretKey.fromSeed(SEED_A);
    const peer_id = crypto.derivePublicIdentifier(secret.publicKey());
    try std.testing.expectEqualSlices(
        u8,
        &hex32("14ae19923f3db01381d0b288a271ed3a1486d4805e04c4f8a48142af3750c3bd"),
        peer_id.asBytes(),
    );
}

test "derivePublicIdentifier is deterministic and key-dependent" {
    const key_a = (SecretKey.fromSeed(SEED_A)).publicKey();
    const key_b = (SecretKey.fromSeed(SEED_B)).publicKey();
    try std.testing.expect(
        crypto.derivePublicIdentifier(key_a).eql(crypto.derivePublicIdentifier(key_a)),
    );
    try std.testing.expect(
        !crypto.derivePublicIdentifier(key_a).eql(crypto.derivePublicIdentifier(key_b)),
    );
}

test "deriveSessionId matches externally-computed known answer" {
    const key_a = (SecretKey.fromSeed(SEED_A)).publicKey();
    const key_b = (SecretKey.fromSeed(SEED_B)).publicKey();
    const session = crypto.deriveSessionId(key_a, key_b);
    try std.testing.expectEqualSlices(
        u8,
        &hex32("c82ee84990a789fa8e1f14d910d1c5cbfd245814dd3a32740bbe309e31f1c2ed"),
        session.asBytes(),
    );
}

test "deriveSessionId is symmetric in peer order" {
    const key_a = (SecretKey.fromSeed(SEED_A)).publicKey();
    const key_b = (SecretKey.fromSeed(SEED_B)).publicKey();
    try std.testing.expect(
        crypto.deriveSessionId(key_a, key_b).eql(crypto.deriveSessionId(key_b, key_a)),
    );
}

test "deriveSessionId differs from either constituent peer id" {
    const key_a = (SecretKey.fromSeed(SEED_A)).publicKey();
    const key_b = (SecretKey.fromSeed(SEED_B)).publicKey();
    const session = crypto.deriveSessionId(key_a, key_b);
    try std.testing.expect(!session.eql(blk: {
        const pid = crypto.derivePublicIdentifier(key_a);
        break :blk pancake.foundation.SessionId.fromBytes(pid.bytes);
    }));
    try std.testing.expect(!session.eql(blk: {
        const pid = crypto.derivePublicIdentifier(key_b);
        break :blk pancake.foundation.SessionId.fromBytes(pid.bytes);
    }));
}
