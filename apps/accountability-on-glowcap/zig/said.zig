//! SAID, verkey, and signature encoding for the accountability identity.
//!
//! Minting a key event and walking a presented log hash and sign the same
//! bytes. This module is that shared leaf: Ed25519 keys, CESR-shaped
//! base64url SAIDs, draft blanking, and the rotation preimage. The AID/KEL
//! controller lives in `identity.zig`, walking a presented log lives in `kel.zig`.
//!
//! What is NOT claimed: byte-for-byte CESR / keripy conformance. An `E`-prefixed
//! Blake3-256 SAID rendered as base64url is KERI-*shaped* but does not reproduce
//! keripy's exact CESR pre-pad alignment.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;

pub const DIGEST_BYTES = 32;
pub const seed_bytes = 32;

/// A base64url-no-pad rendering of a 32-byte digest is 43 chars. An AID or SAID
/// carries a 1-char derivation code in front of it, for 44 total.
pub const SAID_LEN = 44;

/// A base64url-no-pad Ed25519 signature is 86 chars, with no derivation code.
pub const SIG_LEN = std.base64.url_safe_no_pad.Encoder.calcSize(64);

pub const Error = error{
    BadSeed,
    BadSignature,
} || std.mem.Allocator.Error;

/// One Ed25519 keypair plus the 32-byte seed it can be rebuilt from. Seeds are
/// the only secret. Everything else is public.
pub const Key = struct {
    pair: Ed25519.KeyPair,
    seed: [seed_bytes]u8,

    pub fn fromSeed(seed: [seed_bytes]u8) Error!Key {
        const pair = Ed25519.KeyPair.generateDeterministic(seed) catch return Error.BadSeed;
        return .{ .pair = pair, .seed = seed };
    }

    pub fn random(io: std.Io) Error!Key {
        var seed: [seed_bytes]u8 = undefined;
        io.random(&seed);
        return fromSeed(seed);
    }

    pub fn verkey(self: Key) [32]u8 {
        return self.pair.public_key.toBytes();
    }

    pub fn sign(self: Key, payload: []const u8) [64]u8 {
        const sig = self.pair.sign(payload, null) catch unreachable;
        return sig.toBytes();
    }
};

/// Verify `sig` over `payload` against raw 32-byte Ed25519 `verkey` bytes.
pub fn verify(verkey: [32]u8, payload: []const u8, sig: [64]u8) Error!void {
    const key = Ed25519.PublicKey.fromBytes(verkey) catch return Error.BadSignature;
    const signature = Ed25519.Signature.fromBytes(sig);
    signature.verify(payload, key) catch return Error.BadSignature;
}

const b64 = std.base64.url_safe_no_pad;

/// Decode a derivation-`code`-prefixed base64url verkey (the CESR-shaped `D…`
/// rendering) back to its raw 32 Ed25519 public-key bytes, dropping the code.
pub fn decodeVerkey(coded: []const u8) error{BadKey}![32]u8 {
    if (coded.len != 1 + b64.Encoder.calcSize(32)) return error.BadKey;
    var out: [32]u8 = undefined;
    b64.Decoder.decode(&out, coded[1..]) catch return error.BadKey;
    return out;
}

/// Decode a base64url-no-pad Ed25519 signature back to its raw 64 bytes.
pub fn decodeSig(encoded: []const u8) error{BadSig}![64]u8 {
    if (encoded.len != b64.Encoder.calcSize(64)) return error.BadSig;
    var out: [64]u8 = undefined;
    b64.Decoder.decode(&out, encoded) catch return error.BadSig;
    return out;
}

/// Render a 32-byte digest as a `code`-prefixed base64url SAID, e.g. an AID
/// (`E…`) or a next-key digest commitment (`E…`).
pub fn encodeSaid(code: u8, digest: [DIGEST_BYTES]u8, out: *[SAID_LEN]u8) void {
    out[0] = code;
    const enc = std.base64.url_safe_no_pad.Encoder;
    _ = enc.encode(out[1..], &digest);
}

fn blake3(data: []const u8) [DIGEST_BYTES]u8 {
    var out: [DIGEST_BYTES]u8 = undefined;
    Blake3.hash(data, &out, .{});
    return out;
}

/// The character that stands in a self-referential field while the digest over
/// that field's own event is being computed.
pub const blank = '#';

/// The SAID of a key event: an `E`-coded Blake3 digest over the event's *draft*
/// bytes. The draft is the event with the two fields the digest cannot cover
/// filled with `blank` runs: the SAID slot itself, and any signature computed
/// from that SAID. Widths are fixed, so blanking is byte-exact.
///
/// This is the one derivation for both directions. `incept` and `rotate` hash
/// the draft they render. A verifier hashes the draft `draftOf` rebuilds from a
/// received event. Nothing else may derive a SAID.
pub fn saidOf(draft: []const u8) [SAID_LEN]u8 {
    var out: [SAID_LEN]u8 = undefined;
    encodeSaid('E', blake3(draft), &out);
    return out;
}

/// Rebuild the draft bytes a received event's SAID was computed over. Caller
/// owns the result.
///
/// The signature is blanked before the SAID, not after: a signature's 86 base64
/// characters could in principle contain the 44 of the SAID, and blanking the
/// SAID first would leave that occurrence unmatched and only part of the
/// signature filled.
pub fn draftOf(
    allocator: std.mem.Allocator,
    event: []const u8,
    said: []const u8,
    sig: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const draft = try allocator.dupe(u8, event);
    if (sig) |s| blankRuns(draft, s);
    blankRuns(draft, said);
    return draft;
}

/// Fill every occurrence of `needle` in `bytes` with `blank`, in place. The fill
/// is the same width as what it replaces, so the draft and the event are the
/// same length.
fn blankRuns(bytes: []u8, needle: []const u8) void {
    if (needle.len == 0) return;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, from, needle)) |at| {
        @memset(bytes[at..][0..needle.len], blank);
        from = at + needle.len;
    }
}

/// The bytes a rotation's signature covers: the event's own SAID, the key it
/// reveals, and the digest of the key it commits to next. The SAID is a digest
/// over every other field the event carries, including the predecessor it
/// names, so signing these three commits to the whole event. Renderer and
/// verifier both build the preimage here so the two cannot drift.
pub fn rotationPreimage(
    buf: *[3 * SAID_LEN + 2]u8,
    said: []const u8,
    verkey_b64: []const u8,
    next_digest: []const u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "{s}|{s}|{s}", .{ said, verkey_b64, next_digest }) catch unreachable;
}

/// The next-key commitment: a digest over the next verkey, which is the
/// pre-rotation discipline itself: commit to the key before exposing it. An
/// event writes it. A verifier recomputes it over the key a later event reveals.
pub fn nextKeyDigest(next_verkey: [32]u8) [SAID_LEN]u8 {
    var out: [SAID_LEN]u8 = undefined;
    encodeSaid('E', blake3(&next_verkey), &out);
    return out;
}

test "a D-coded verkey round-trips" {
    const key = try Key.fromSeed(@as([seed_bytes]u8, @splat(0x01)));
    var coded: [SAID_LEN]u8 = undefined;
    encodeSaid('D', key.verkey(), &coded);
    try std.testing.expectEqual(key.verkey(), try decodeVerkey(&coded));
}

test "a signature round-trips through base64url" {
    const key = try Key.fromSeed(@as([seed_bytes]u8, @splat(0x02)));
    const sig = key.sign("preimage");
    var encoded: [SIG_LEN]u8 = undefined;
    _ = b64.Encoder.encode(&encoded, &sig);
    try std.testing.expectEqual(sig, try decodeSig(&encoded));
    try verify(key.verkey(), "preimage", sig);
}
