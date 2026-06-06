//! The Ed25519 and SHA-256 work that OCapN's signatures need, and nothing more.
//!
//! Three jobs live here. We sign the `acceptable-location-sig` that rides on
//! `op:start-session`. We sign and check the `desc:sig-envelope` certificates a
//! handoff carries. And we derive a peer's and a session's identity using the
//! double-SHA256 the CapTP spec calls for, which gives us `PeerId` and
//! `SessionId`.
//!
//! It's all pure math. Nothing here allocates, does I/O, or keeps global state,
//! and it builds for `wasm32` as-is. There's one thing you won't find: making
//! fresh randomness. Generating a key pair or a gift id needs entropy, and
//! entropy is I/O, so that stays out at the adapter boundary. Down here we take a
//! 32-byte seed you hand us (`SecretKey.fromSeed`) and a gift id you hand us. You
//! decide where those bytes come from.
//!
//! Turning these keys and signatures into Syrup is the codec's job. This module
//! only does the byte math.

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

/// The ways verification can go wrong. Signing and deriving a key from a good
/// seed can't fail, so everything here is about checking someone else's bytes.
pub const CryptoError = error{
    /// The signature does not match what `pubkey` would produce for `payload`.
    InvalidSignature,
    /// The public-key bytes do not decode to a point on the Ed25519 curve.
    MalformedKey,
    /// The signature bytes do not structurally form an Ed25519 signature.
    MalformedSignature,
};

/// A per-session Ed25519 public key: the raw 32-byte `q` value.
///
/// It's only ever used to check signatures. A key never grants authority. That
/// always lives in a `Reference`.
pub const PeerKey = struct {
    bytes: [PEER_KEY_BYTES]u8,

    pub fn fromBytes(bytes: [PEER_KEY_BYTES]u8) PeerKey {
        return .{ .bytes = bytes };
    }

    /// Pull a fixed-size key out of a borrowed wire slice, like a decoded
    /// `session_pubkey`. Ed25519 keys are a fixed 32 bytes, so going from a slice
    /// to a `[32]u8` means one small copy. It happens here, behind the length
    /// check, so callers get to keep passing slices around.
    pub fn fromSlice(bytes: []const u8) CryptoError!PeerKey {
        if (bytes.len != PEER_KEY_BYTES) return CryptoError.MalformedKey;
        // Copy the slice into a fixed array; the `[0..N]` bound checks the
        // length. Ed25519 wants the key by value, so this 32-byte copy is just
        // part of the primitive, same as in std.crypto.
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

    /// Build a fixed-size signature from its two borrowed halves, `r` and `s`.
    /// An Ed25519 signature is `r || s` (RFC 8032), which is the shape the Syrup
    /// `sig-val` view hands you. Same fixed-width copy as `PeerKey.fromSlice`;
    /// here the two 32-byte halves get joined into one 64-byte value.
    pub fn fromParts(r: []const u8, s: []const u8) CryptoError!Signature {
        const half = SIGNATURE_BYTES / 2;
        if (r.len != half or s.len != half) return CryptoError.MalformedSignature;
        // Join the two halves (the lengths were checked just above). The 64-byte
        // copy is inherent to a by-value `Signature`.
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
/// You build one from a 32-byte seed you supply (`fromSeed`). The seed is where
/// entropy lives: making a fresh one needs randomness, and the core doesn't do
/// randomness. If you need to carry the key across a boundary, `seed` hands the
/// bytes back out. That's deliberately a named call, so copying key material
/// never happens by accident.
pub const SecretKey = struct {
    keypair: Ed25519.KeyPair,

    /// Rebuild a secret key from a 32-byte seed. Where the seed came from is on
    /// you; nothing here checks it.
    pub fn fromSeed(seed_bytes: [SEED_BYTES]u8) CryptoError!SecretKey {
        const keypair = Ed25519.KeyPair.generateDeterministic(seed_bytes) catch
            return CryptoError.MalformedKey;
        return .{ .keypair = keypair };
    }

    /// Hand back the 32-byte seed, so you can rebuild this key later with `fromSeed`.
    pub fn seed(self: *const SecretKey) [SEED_BYTES]u8 {
        return self.keypair.secret_key.seed();
    }

    /// Get the matching public key. It's cheap; Ed25519 keeps it on the pair.
    pub fn publicKey(self: *const SecretKey) PeerKey {
        return .{ .bytes = self.keypair.public_key.toBytes() };
    }
};

/// Sign `payload` with `secret` and get back an Ed25519 signature.
///
/// For the `desc:sig-envelope` flows, hand in the Syrup-canonical bytes of the
/// inner object. You canonicalize before you call this, not after.
///
/// This can't fail. Signing with a well-formed key pair always works, and the
/// `unreachable` says exactly that: the errors underneath (a key mismatch, an
/// identity element) can't happen for a key built from a valid seed.
pub fn sign(secret: *const SecretKey, payload: []const u8) Signature {
    const sig = secret.keypair.sign(payload, null) catch unreachable;
    return .{ .bytes = sig.toBytes() };
}

/// Check that `sig` really is `pubkey`'s signature over `payload`.
///
/// You get `CryptoError.MalformedKey` if the public-key bytes aren't a point on
/// the curve, and `CryptoError.InvalidSignature` if they're shaped right but
/// just don't match.
pub fn verify(pubkey: PeerKey, payload: []const u8, sig: Signature) CryptoError!void {
    const key = Ed25519.PublicKey.fromBytes(pubkey.bytes) catch
        return CryptoError.MalformedKey;
    const signature = Ed25519.Signature.fromBytes(sig.bytes);
    signature.verify(payload, key) catch return CryptoError.InvalidSignature;
}

/// Work out the OCapN Public Identifier for a `PeerKey`.
///
/// The CapTP spec spells out two steps. First, write the public key as the
/// gcrypt s-expression `[public-key [ecc [curve Ed25519] [flags eddsa] [q
/// q_value]]]`. Then hash that twice with SHA256. That double hash is exactly
/// what Goblins-Racket's `our-side-id` and the OCapN Python suite both do.
///
/// We hand-roll the serialization right here, against the Syrup byte spec, so
/// `foundation` doesn't have to depend on a codec. It comes out byte-for-byte
/// identical to what the Syrup codec would produce for the same s-expression,
/// and an oracle fixture keeps it honest.
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

/// Work out the `SessionId` for a pair of per-session public keys.
///
/// Derive both `PeerId`s, sort the two byte-ascending so it doesn't matter which
/// side is local, then double-SHA256 over `"prot0"` followed by the first and
/// the second. Because of the sort, both ends land on the same value even though
/// one side dialed and the other answered.
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
