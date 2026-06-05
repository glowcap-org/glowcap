//! Ed25519 + SHA-256 primitives for OCapN handshake and handoff signatures.
//!
//! These are the cryptographic operations the wire shapes require: signing the
//! `op:start-session` `acceptable-location-sig`, signing / verifying the
//! `desc:sig-envelope` handoff certificates, and the CapTP SHA256² derivations
//! of [`id.PeerId`] (Public Identifier) and [`id.SessionId`].
//!
//! Everything here is pure computation: no allocation, no I/O, no hidden global
//! state. It compiles to `wasm32` unchanged. The one operation that needs an
//! entropy source — generating a fresh key pair or gift id — is deliberately
//! *not* here: it lives at the adapter boundary, because entropy is I/O. The
//! core consumes a caller-supplied 32-byte seed ([`SecretKey.fromSeed`]) and a
//! caller-supplied gift id; the adapter owns where those bytes come from.
//!
//! Syrup encoding of these key / signature shapes lives in the Syrup codec;
//! this module owns only the raw byte math.

const std = @import("std");

const id = @import("id.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Width in bytes of an Ed25519 raw public key (the `q` value in the
/// OCapN-spec gcrypt s-expression form).
pub const PEER_KEY_BYTES: usize = 32;

/// Width in bytes of an Ed25519 raw signature (`r || s`).
pub const SIGNATURE_BYTES: usize = 64;

/// Width in bytes of the 32-byte secret seed a [`SecretKey`] is reconstructed
/// from.
pub const SEED_BYTES: usize = 32;

/// Width in bytes of a `gift-id` per CapTP `desc:handoff-give`.
pub const GIFT_ID_BYTES: usize = 32;

/// Failure surface for verification. Signing and key derivation from a valid
/// seed are infallible, so this only carries verify-side shapes.
pub const CryptoError = error{
    /// The signature does not match what `pubkey` would produce for `payload`.
    InvalidSignature,
    /// The public-key bytes do not decode to a point on the Ed25519 curve.
    MalformedKey,
    /// The signature bytes do not structurally form an Ed25519 signature.
    MalformedSignature,
};

/// A per-session Ed25519 public key (32-byte raw `q` value).
///
/// Verification material only; authority lives in `Reference`, never in a key.
pub const PeerKey = struct {
    bytes: [PEER_KEY_BYTES]u8,

    pub fn fromBytes(bytes: [PEER_KEY_BYTES]u8) PeerKey {
        return .{ .bytes = bytes };
    }

    /// Materialize a fixed-size key from a wire-borrowed slice (e.g. a decoded
    /// `session_pubkey` view). Ed25519 keys are fixed-width, so the boundary
    /// from `[]const u8` to `[32]u8` is the one unavoidable copy; this is where
    /// it lives, with the length check, so call sites stay slice-shaped.
    pub fn fromSlice(bytes: []const u8) CryptoError!PeerKey {
        if (bytes.len != PEER_KEY_BYTES) return CryptoError.MalformedKey;
        // Slice → fixed array via array-pointer deref (length checked by the
        // `[0..N]` bound). Ed25519 keys are taken by value, so this 32-byte
        // materialization is inherent to the primitive, same as std.crypto.
        return .{ .bytes = bytes[0..PEER_KEY_BYTES].* };
    }

    pub fn asBytes(self: *const PeerKey) []const u8 {
        return self.bytes[0..];
    }

    pub fn eql(self: PeerKey, other: PeerKey) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// A 64-byte Ed25519 signature (`r || s` per RFC 8032).
pub const Signature = struct {
    bytes: [SIGNATURE_BYTES]u8,

    pub fn fromBytes(bytes: [SIGNATURE_BYTES]u8) Signature {
        return .{ .bytes = bytes };
    }

    /// Materialize a fixed-size signature from the wire-borrowed `r` / `s`
    /// halves (Ed25519 `r || s` per RFC 8032, the shape the Syrup `sig-val`
    /// view exposes). See [`PeerKey.fromSlice`] for the fixed-width-boundary
    /// rationale; here the two 32-byte halves are joined into the 64-byte value.
    pub fn fromParts(r: []const u8, s: []const u8) CryptoError!Signature {
        const half = SIGNATURE_BYTES / 2;
        if (r.len != half or s.len != half) return CryptoError.MalformedSignature;
        // Join the two halves via array-pointer deref (lengths checked above).
        // The 64-byte materialization is inherent to the by-value `Signature`.
        var out: [SIGNATURE_BYTES]u8 = undefined;
        out[0..half].* = r[0..half].*;
        out[half..].* = s[0..half].*;
        return .{ .bytes = out };
    }

    pub fn asBytes(self: *const Signature) []const u8 {
        return self.bytes[0..];
    }
};

/// The secret half of an Ed25519 key pair.
///
/// Construct from a caller-supplied 32-byte seed ([`fromSeed`]). The seed is the
/// entropy boundary: generating one needs randomness (I/O), which the core does
/// not own. [`seed`] projects the seed back out for a caller that must carry the
/// key across a boundary; the projection is explicit so key-material duplication
/// stays visible.
pub const SecretKey = struct {
    keypair: Ed25519.KeyPair,

    /// Reconstruct a secret key from a 32-byte seed. The seed's provenance is
    /// the caller's responsibility; nothing here checks where it came from.
    pub fn fromSeed(seed_bytes: [SEED_BYTES]u8) CryptoError!SecretKey {
        const keypair = Ed25519.KeyPair.generateDeterministic(seed_bytes) catch
            return CryptoError.MalformedKey;
        return .{ .keypair = keypair };
    }

    /// Project the 32-byte secret seed for reconstruction via [`fromSeed`].
    pub fn seed(self: *const SecretKey) [SEED_BYTES]u8 {
        return self.keypair.secret_key.seed();
    }

    /// Derive the public-key half (cheap; Ed25519 carries it on the pair).
    pub fn publicKey(self: *const SecretKey) PeerKey {
        return .{ .bytes = self.keypair.public_key.toBytes() };
    }
};

/// Sign `payload` with `secret`, producing an Ed25519 signature.
///
/// For `desc:sig-envelope` flows the caller passes the Syrup-canonical bytes of
/// the inner object; canonicalization happens before this call.
///
/// Infallible: signing with a well-formed key pair cannot fail. The
/// `unreachable` documents that the underlying error arms (key mismatch,
/// identity element) are impossible for a key pair built from a valid seed.
pub fn sign(secret: *const SecretKey, payload: []const u8) Signature {
    const sig = secret.keypair.sign(payload, null) catch unreachable;
    return .{ .bytes = sig.toBytes() };
}

/// Verify that `sig` is `pubkey`'s signature over `payload`.
///
/// Returns `CryptoError.MalformedKey` if the public-key bytes are off-curve and
/// `CryptoError.InvalidSignature` if the bytes are well-shaped but do not match.
pub fn verify(pubkey: PeerKey, payload: []const u8, sig: Signature) CryptoError!void {
    const key = Ed25519.PublicKey.fromBytes(pubkey.bytes) catch
        return CryptoError.MalformedKey;
    const signature = Ed25519.Signature.fromBytes(sig.bytes);
    signature.verify(payload, key) catch return CryptoError.InvalidSignature;
}

/// Derive the OCapN-canonical Public Identifier for a `PeerKey`.
///
/// Per the CapTP spec § Public Identifier:
/// 1. Serialize the public key as the gcrypt s-expression
///    `[public-key [ecc [curve Ed25519] [flags eddsa] [q q_value]]]`.
/// 2. `SHA256(SHA256(...))` of that serialization (double-SHA256, matching
///    Goblins-Racket `our-side-id` and the OCapN Python suite).
///
/// The serialization is hand-rolled here against the byte-level Syrup spec to
/// keep `foundation` free of a codec dependency; it is byte-identical to what
/// the Syrup codec's canonical encoder produces for the same s-expression
/// (pinned by an oracle fixture).
pub fn derivePublicIdentifier(key: PeerKey) id.PeerId {
    // Stream the gcrypt s-expression straight into SHA256: each structural
    // token and the raw `q` bytes are hashed in place. No staging buffer, so
    // the key bytes are never copied — `update` reads them where they sit.
    var hasher = Sha256.init(.{});
    hasher.update("[");
    updateSymbol(&hasher, "public-key");
    hasher.update("[");
    updateSymbol(&hasher, "ecc");
    hasher.update("[");
    updateSymbol(&hasher, "curve");
    updateSymbol(&hasher, "Ed25519");
    hasher.update("]");
    hasher.update("[");
    updateSymbol(&hasher, "flags");
    updateSymbol(&hasher, "eddsa");
    hasher.update("]");
    hasher.update("[");
    updateSymbol(&hasher, "q");
    updateByteString(&hasher, key.asBytes());
    hasher.update("]");
    hasher.update("]");
    hasher.update("]");

    var inner: [Sha256.digest_length]u8 = undefined;
    hasher.final(&inner);
    const outer = sha256(inner[0..]);
    return id.PeerId.fromBytes(outer);
}

/// Derive the SHA256² `SessionId` for a pair of per-session public keys.
///
/// 1. Derive both `PeerId`s.
/// 2. Sort them byte-ascending (canonical pairing, independent of who is
///    local / remote).
/// 3. `outer = SHA256(SHA256("prot0" || first || second))`.
///
/// Both ends arrive at the same value because the sort eliminates the
/// initiator / acceptor asymmetry.
pub fn deriveSessionId(local_key: PeerKey, remote_key: PeerKey) id.SessionId {
    const id_a = derivePublicIdentifier(local_key);
    const id_b = derivePublicIdentifier(remote_key);

    const a = id_a.bytes;
    const b = id_b.bytes;
    const first, const second = if (std.mem.order(u8, &a, &b) == .gt)
        .{ b, a }
    else
        .{ a, b };

    var hasher = Sha256.init(.{});
    hasher.update("prot0");
    hasher.update(&first);
    hasher.update(&second);
    var inner: [Sha256.digest_length]u8 = undefined;
    hasher.final(&inner);
    const outer = sha256(inner[0..]);
    return id.SessionId.fromBytes(outer);
}

fn sha256(data: []const u8) [Sha256.digest_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &out, .{});
    return out;
}

/// Hash a Syrup symbol (`<len>'<bytes>`) directly into `hasher`.
fn updateSymbol(hasher: *Sha256, sym: []const u8) void {
    updateLen(hasher, sym.len);
    hasher.update("'");
    hasher.update(sym);
}

/// Hash a Syrup byte string (`<len>:<bytes>`) directly into `hasher`.
fn updateByteString(hasher: *Sha256, bytes: []const u8) void {
    updateLen(hasher, bytes.len);
    hasher.update(":");
    hasher.update(bytes);
}

/// Hash a decimal length prefix. The digits are formatted into a small stack
/// buffer (a `usize` is at most 20 decimal digits) then streamed in; this is
/// integer→ASCII formatting, not a copy of any wire payload.
fn updateLen(hasher: *Sha256, len: usize) void {
    var buf: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{len}) catch unreachable;
    hasher.update(text);
}
