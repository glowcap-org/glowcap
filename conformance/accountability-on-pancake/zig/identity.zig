//! KERI-anchored identity, living strictly above pancake.
//!
//! This is application vocabulary — an autonomic identifier (AID) with a key
//! event log (KEL), pre-rotation, and rotation. It never enters pancake's
//! protocol surface; pancake hosts the codec-neutral CapTP boundary and knows
//! nothing about identity. The accountability application binds an identity to a
//! peer here, above the `Peer`/`Vat` line, exactly as the project guardrails
//! require.
//!
//! Fidelity, stated honestly: the cryptography is real. An AID is self-certifying
//! — it is derived from the inception event, which commits to the current Ed25519
//! verkey and to a *digest* of the next verkey (pre-rotation: the next key is
//! committed before it is ever exposed). Rotation reveals the committed next key,
//! signs the new event with the current key, and commits to a fresh next digest.
//! These are the load-bearing KERI properties.
//!
//! What is NOT claimed: byte-for-byte CESR / keripy conformance. The AID is an
//! `E`-prefixed Blake3-256 SAID rendered as base64url, which is KERI-*shaped* but
//! does not reproduce keripy's exact CESR pre-pad alignment, so the `keripy`
//! oracle in `conformance/keri-conformance/` would not verify these identifiers.
//! Closing that gap is tracked in the friction log, not faked here.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;

pub const DIGEST_BYTES = 32;
pub const SEED_BYTES = 32;

/// A base64url-no-pad rendering of a 32-byte digest is 43 chars; an AID or SAID
/// carries a 1-char derivation code in front of it, for 44 total.
pub const SAID_LEN = 44;

pub const Error = error{
    BadSeed,
    BadSignature,
    KelClosed,
} || std.mem.Allocator.Error;

/// One Ed25519 keypair plus the 32-byte seed it can be rebuilt from. Seeds are
/// the only secret; everything else is public.
pub const Key = struct {
    pair: Ed25519.KeyPair,
    seed: [SEED_BYTES]u8,

    pub fn fromSeed(seed: [SEED_BYTES]u8) Error!Key {
        const pair = Ed25519.KeyPair.generateDeterministic(seed) catch return Error.BadSeed;
        return .{ .pair = pair, .seed = seed };
    }

    pub fn random(io: std.Io) Error!Key {
        var seed: [SEED_BYTES]u8 = undefined;
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

/// The mutable identity: an AID, its current/next key state, and an append-only
/// KEL. It owns its KEL storage and frees it on `deinit`.
pub const Identity = struct {
    allocator: std.mem.Allocator,
    aid: [SAID_LEN]u8,
    /// The currently-authoritative signing key (the most recent rotation).
    current: Key,
    /// The pre-committed next key, ready to become current on the next rotation.
    next: Key,
    /// Monotonic sequence number of the latest key event (0 = inception).
    sn: u64 = 0,
    /// The KEL as appended JSON-LD event lines; the canonical local record.
    kel: std.ArrayList(u8) = .empty,

    /// Incept a fresh identity. Two keypairs are drawn: the current signer and
    /// the pre-rotated next signer (only the digest of whose verkey the
    /// inception event exposes). The AID is the SAID of the inception event.
    pub fn incept(allocator: std.mem.Allocator, io: std.Io) Error!Identity {
        const current = try Key.random(io);
        const next = try Key.random(io);
        return inceptFrom(allocator, current, next);
    }

    /// Incept from caller-supplied keys (deterministic; used by tests).
    pub fn inceptFrom(allocator: std.mem.Allocator, current: Key, next: Key) Error!Identity {
        var self = Identity{
            .allocator = allocator,
            .aid = undefined,
            .current = current,
            .next = next,
        };

        // The inception event commits to the current verkey and to the digest of
        // the next verkey (pre-rotation). Its SAID is computed over the event
        // with the `i`/`d` fields zero-filled, then substituted back — the
        // standard self-addressing dance.
        const next_digest = nextKeyDigest(next.verkey());
        var placeholder: [SAID_LEN]u8 = .{'#'} ** SAID_LEN;
        const draft = try self.renderInception(allocator, placeholder, next_digest);
        defer allocator.free(draft);
        const said_digest = blake3(draft);
        encodeSaid('E', said_digest, &self.aid);
        placeholder = self.aid;

        const event = try self.renderInception(allocator, placeholder, next_digest);
        defer allocator.free(event);
        try self.appendEvent(event);
        return self;
    }

    pub fn deinit(self: *Identity) void {
        self.kel.deinit(self.allocator);
    }

    pub fn aidSlice(self: *const Identity) []const u8 {
        return self.aid[0..];
    }

    /// Rotate: the pre-committed next key becomes current, a fresh next key is
    /// drawn and pre-committed, and a `rot` event signed by the *old* current
    /// key is appended. Returns the new event's SAID.
    pub fn rotate(self: *Identity, io: std.Io) Error![SAID_LEN]u8 {
        const old_current = self.current;
        const new_current = self.next;
        const new_next = try Key.random(io);

        self.sn += 1;
        const next_digest = nextKeyDigest(new_next.verkey());

        var said_buf: [SAID_LEN]u8 = .{'#'} ** SAID_LEN;
        const draft = try self.renderRotation(self.allocator, said_buf, new_current.verkey(), next_digest, old_current);
        defer self.allocator.free(draft);
        const said_digest = blake3(draft);
        encodeSaid('E', said_digest, &said_buf);

        const event = try self.renderRotation(self.allocator, said_buf, new_current.verkey(), next_digest, old_current);
        defer self.allocator.free(event);
        try self.appendEvent(event);

        self.current = new_current;
        self.next = new_next;
        return said_buf;
    }

    fn appendEvent(self: *Identity, event_json: []const u8) Error!void {
        try self.kel.appendSlice(self.allocator, event_json);
        try self.kel.append(self.allocator, '\n');
    }

    /// The next-key commitment is a digest over the next verkey — the
    /// pre-rotation discipline: commit to the key before exposing it.
    fn nextKeyDigest(next_verkey: [32]u8) [SAID_LEN]u8 {
        var out: [SAID_LEN]u8 = undefined;
        encodeSaid('E', blake3(&next_verkey), &out);
        return out;
    }

    fn renderInception(
        self: *const Identity,
        allocator: std.mem.Allocator,
        said: [SAID_LEN]u8,
        next_digest: [SAID_LEN]u8,
    ) Error![]u8 {
        var verkey_b64: [SAID_LEN]u8 = undefined;
        encodeSaid('D', self.current.verkey(), &verkey_b64);
        return std.fmt.allocPrint(allocator,
            \\{{"v":"KERIa","t":"icp","d":"{s}","i":"{s}","s":"0","kt":"1","k":["{s}"],"nt":"1","n":["{s}"]}}
        , .{ said, said, verkey_b64, next_digest });
    }

    fn renderRotation(
        self: *const Identity,
        allocator: std.mem.Allocator,
        said: [SAID_LEN]u8,
        new_verkey: [32]u8,
        next_digest: [SAID_LEN]u8,
        signer: Key,
    ) Error![]u8 {
        var verkey_b64: [SAID_LEN]u8 = undefined;
        encodeSaid('D', new_verkey, &verkey_b64);
        // The rotation is signed by the retiring current key, proving authority
        // to rotate; the signature rides as a CESR-shaped base64url field.
        var preimage_buf: [256]u8 = undefined;
        const preimage = std.fmt.bufPrint(&preimage_buf, "{s}|{s}|{s}", .{ said, verkey_b64, next_digest }) catch unreachable;
        const sig = signer.sign(preimage);
        // base64url-no-pad of 64 bytes is 86 chars, not the padded 88; a padded-size
        // buffer would trail two uninitialized bytes into the KEL record.
        var sig_b64: [std.base64.url_safe_no_pad.Encoder.calcSize(64)]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64, &sig);
        return std.fmt.allocPrint(allocator,
            \\{{"v":"KERIa","t":"rot","d":"{s}","i":"{s}","s":"{d}","kt":"1","k":["{s}"],"nt":"1","n":["{s}"],"sig":"{s}"}}
        , .{ said, self.aid, self.sn, verkey_b64, next_digest, sig_b64 });
    }
};
