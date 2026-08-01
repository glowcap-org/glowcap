//! KERI-anchored identity, living strictly above pancake.
//!
//! This is application vocabulary — an autonomic identifier (AID) with a key
//! event log (KEL), pre-rotation, and rotation. It never enters pancake's
//! protocol surface; pancake hosts the codec-neutral CapTP boundary and knows
//! nothing about identity. The accountability application binds an identity to a
//! peer here, above the `Peer`/`Vat` line, exactly as the project guardrails
//! require.
//!
//! Fidelity: the cryptography is real. An AID is
//! self-certifying: it is derived from the inception event, which commits to the
//! current Ed25519 verkey and to a *digest* of the next verkey (pre-rotation:
//! the next key is committed before it is ever exposed). Rotation reveals the
//! committed next key, signs the new event with the current key, and commits to
//! a fresh next digest.
//! These are the load-bearing KERI properties.
//!
//! The log is also read, not only written. `currentVerkey` walks a log a stranger
//! presents and returns the key that speaks for the AID now, which is how a host
//! decides whether a presented key belongs to the identifier it claims.
//!
//! What is NOT claimed: byte-for-byte CESR / keripy conformance. The AID is an
//! `E`-prefixed Blake3-256 SAID rendered as base64url, which is KERI-*shaped* but
//! does not reproduce keripy's exact CESR pre-pad alignment, so the `keripy`
//! oracle in `conformance/keri-conformance/` would not verify these identifiers.
//! Closing that gap is a known boundary, not faked here.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake3 = std.crypto.hash.Blake3;

pub const DIGEST_BYTES = 32;
pub const SEED_BYTES = 32;

/// A base64url-no-pad rendering of a 32-byte digest is 43 chars; an AID or SAID
/// carries a 1-char derivation code in front of it, for 44 total.
pub const SAID_LEN = 44;

/// A base64url-no-pad Ed25519 signature is 86 chars, with no derivation code.
pub const SIG_LEN = std.base64.url_safe_no_pad.Encoder.calcSize(64);

pub const Error = error{
    BadSeed,
    BadSignature,
    KelClosed,
} || std.mem.Allocator.Error;

/// Why a presented key event log failed to bind a key to the AID it claims.
/// Each one is a refusal, and the host projects them all to a single typed
/// reason on the wire; they are separate here so a reader can see what the walk
/// actually checks.
pub const LogError = error{
    /// Not a log, or an event missing the fields a key event must carry.
    MalformedLog,
    /// An event's SAID is not the digest of the event's own bytes.
    SaidMismatch,
    /// The log does not open with an inception event.
    NotInception,
    /// The inception event's SAID is not the AID being claimed.
    AidMismatch,
    /// A rotation does not follow its predecessor: wrong sequence number, or it
    /// names a prior event that is not the one before it.
    BrokenChain,
    /// A rotation reveals a key its predecessor did not commit to.
    BrokenPreRotation,
    /// A rotation is not signed by the key it retires.
    BadRotationSignature,
    /// The log verifies, but the key presented with the request is not the one
    /// the log ends on — a retired pre-rotation key.
    RetiredKey,
} || Error;

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
const blank = '#';

/// The SAID of a key event: an `E`-coded Blake3 digest over the event's *draft*
/// bytes. The draft is the event with the two fields the digest cannot cover
/// filled with `blank` runs: the SAID slot itself, and any signature computed
/// from that SAID. Widths are fixed, so blanking is byte-exact.
///
/// This is the one derivation for both directions. `incept` and `rotate` hash
/// the draft they render; a verifier hashes the draft `draftOf` rebuilds from a
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
fn draftOf(
    allocator: std.mem.Allocator,
    event: []const u8,
    said: []const u8,
    sig: ?[]const u8,
) Error![]u8 {
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
fn rotationPreimage(
    buf: *[3 * SAID_LEN + 2]u8,
    said: []const u8,
    verkey_b64: []const u8,
    next_digest: []const u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "{s}|{s}|{s}", .{ said, verkey_b64, next_digest }) catch unreachable;
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
    /// The SAID of the latest key event. The next rotation names it as its
    /// predecessor, which is what makes the log a chain.
    said: [SAID_LEN]u8 = undefined,
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
        // with the `i`/`d` fields zero-filled, then substituted back, the
        // standard self-addressing dance.
        const next_digest = nextKeyDigest(next.verkey());
        var placeholder: [SAID_LEN]u8 = .{blank} ** SAID_LEN;
        const draft = try self.renderInception(allocator, placeholder, next_digest);
        defer allocator.free(draft);
        self.aid = saidOf(draft);
        self.said = self.aid;
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

    /// The key event log as it goes on the wire: one JSON event per line. A
    /// verifier walks these bytes with `currentVerkey` to learn which key speaks
    /// for this AID right now.
    pub fn kelSlice(self: *const Identity) []const u8 {
        return self.kel.items;
    }

    /// Rotate: the pre-committed next key becomes current, a fresh next key is
    /// drawn and pre-committed, and a `rot` event signed by the *old* current
    /// key is appended. Returns the new event's SAID.
    pub fn rotate(self: *Identity, io: std.Io) Error![SAID_LEN]u8 {
        const old_current = self.current;
        const new_current = self.next;
        const new_next = try Key.random(io);

        const prior = self.said;
        self.sn += 1;
        const next_digest = nextKeyDigest(new_next.verkey());

        var verkey_b64: [SAID_LEN]u8 = undefined;
        encodeSaid('D', new_current.verkey(), &verkey_b64);

        const event = try mintRotation(self.allocator, .{
            .aid = self.aid,
            .sn = self.sn,
            .prior = prior,
            .verkey_b64 = verkey_b64,
            .next_digest = next_digest,
            .signer = old_current,
        });
        defer self.allocator.free(event.bytes);
        try self.appendEvent(event.bytes);

        self.current = new_current;
        self.next = new_next;
        self.said = event.said;
        return event.said;
    }

    fn appendEvent(self: *Identity, event_json: []const u8) Error!void {
        try self.kel.appendSlice(self.allocator, event_json);
        try self.kel.append(self.allocator, '\n');
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
};

/// What a rotation event says, apart from the SAID and signature it derives.
const RotationParts = struct {
    aid: [SAID_LEN]u8,
    sn: u64,
    /// The SAID of the event this one follows.
    prior: [SAID_LEN]u8,
    /// The `D`-coded key this rotation reveals as current.
    verkey_b64: [SAID_LEN]u8,
    /// The commitment to the key that comes after it.
    next_digest: [SAID_LEN]u8,
    /// The key that signs, which for a well-formed rotation is the one it retires.
    signer: Key,
};

/// Mint one rotation event: render the draft with the SAID and the signature
/// blanked, hash it, sign that SAID, and render again with both filled in. Two
/// passes, because the event carries both its own SAID and a signature over that
/// SAID. Caller owns the returned bytes.
fn mintRotation(
    allocator: std.mem.Allocator,
    parts: RotationParts,
) Error!struct { said: [SAID_LEN]u8, bytes: []u8 } {
    const draft = try renderRotation(allocator, parts, .{blank} ** SAID_LEN, .{blank} ** SIG_LEN);
    defer allocator.free(draft);
    const said = saidOf(draft);

    var preimage_buf: [3 * SAID_LEN + 2]u8 = undefined;
    const preimage = rotationPreimage(&preimage_buf, &said, &parts.verkey_b64, &parts.next_digest);
    var sig_b64: [SIG_LEN]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64, &parts.signer.sign(preimage));

    return .{ .said = said, .bytes = try renderRotation(allocator, parts, said, sig_b64) };
}

/// Render one rotation event. `p` names the predecessor, which is what a
/// verifier follows to know the log is a chain and not a pile of events. The
/// signature rides as a CESR-shaped base64url field.
fn renderRotation(
    allocator: std.mem.Allocator,
    parts: RotationParts,
    said: [SAID_LEN]u8,
    sig_b64: [SIG_LEN]u8,
) Error![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"v":"KERIa","t":"rot","d":"{s}","i":"{s}","s":"{d}","p":"{s}","kt":"1","k":["{s}"],"nt":"1","n":["{s}"],"sig":"{s}"}}
    , .{ said, parts.aid, parts.sn, parts.prior, parts.verkey_b64, parts.next_digest, sig_b64 });
}

/// Walk a presented key event log and return the verkey that is authoritative at
/// its tip.
///
/// This is the check that binds a key to an identifier. An AID is the SAID of
/// its own inception event, so the log proves the binding by construction: the
/// event that names the first key *is* the identifier. From there each rotation
/// has to earn its place — it names the event before it, it is signed by the key
/// it retires, and the key it reveals has to match the digest its predecessor
/// committed to. That last one is pre-rotation, and this application commits one
/// key deep (`nt` is 1), so the walk holds it to that depth and no further.
///
/// `allocator` is scratch: everything this borrows dies with the call.
pub fn currentVerkey(allocator: std.mem.Allocator, kel: []const u8, aid: []const u8) LogError![32]u8 {
    if (aid.len != SAID_LEN) return LogError.AidMismatch;

    var current: [32]u8 = undefined;
    var next_commitment: [SAID_LEN]u8 = undefined;
    var prior_said: [SAID_LEN]u8 = undefined;
    var seen: u64 = 0;

    var lines = std.mem.splitScalar(u8, kel, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch
            return LogError.MalformedLog;
        defer parsed.deinit();
        const event = switch (parsed.value) {
            .object => |o| o,
            else => return LogError.MalformedLog,
        };

        const t = strField(event, "t") orelse return LogError.MalformedLog;
        const said = strField(event, "d") orelse return LogError.MalformedLog;
        const controller = strField(event, "i") orelse return LogError.MalformedLog;
        const sn = strField(event, "s") orelse return LogError.MalformedLog;
        // One current key and one next-key commitment: the width this
        // application models, and a log that carries more is refused rather
        // than silently read as if it carried one.
        const key_b64 = soleOf(event, "k") orelse return LogError.MalformedLog;
        const next_b64 = soleOf(event, "n") orelse return LogError.MalformedLog;
        const sig_b64 = strField(event, "sig");

        if (said.len != SAID_LEN or controller.len != SAID_LEN) return LogError.MalformedLog;
        if (next_b64.len != SAID_LEN) return LogError.MalformedLog;
        if (sig_b64) |s| if (s.len != SIG_LEN) return LogError.MalformedLog;
        const verkey = decodeVerkey(key_b64) catch return LogError.MalformedLog;

        // Every event is self-addressing: its SAID is the digest of its own
        // bytes, so an edited event no longer hashes to the name it goes by.
        const draft = try draftOf(allocator, line, said, sig_b64);
        defer allocator.free(draft);
        if (!std.mem.eql(u8, &saidOf(draft), said)) return LogError.SaidMismatch;

        if (seen == 0) {
            if (!std.mem.eql(u8, t, "icp")) return LogError.NotInception;
            if (!std.mem.eql(u8, sn, "0")) return LogError.BrokenChain;
            // The inception event's SAID is the identifier, so it stands in both
            // the `d` and `i` slots, and it must be the AID being claimed.
            if (!std.mem.eql(u8, said, controller)) return LogError.MalformedLog;
            if (!std.mem.eql(u8, said, aid)) return LogError.AidMismatch;
        } else {
            if (!std.mem.eql(u8, t, "rot")) return LogError.MalformedLog;
            if (!std.mem.eql(u8, controller, aid)) return LogError.AidMismatch;

            var sn_buf: [24]u8 = undefined;
            const expected_sn = std.fmt.bufPrint(&sn_buf, "{d}", .{seen}) catch unreachable;
            if (!std.mem.eql(u8, sn, expected_sn)) return LogError.BrokenChain;

            const prior = strField(event, "p") orelse return LogError.BrokenChain;
            if (!std.mem.eql(u8, prior, &prior_said)) return LogError.BrokenChain;

            // Pre-rotation: the key this event reveals is only admissible if its
            // predecessor committed to this exact key before anyone had seen it.
            if (!std.mem.eql(u8, &nextKeyDigest(verkey), &next_commitment)) {
                return LogError.BrokenPreRotation;
            }

            // The rotation is signed by the key it retires, which is what proves
            // the holder of the old key authorized the handover.
            const sig = decodeSig(sig_b64 orelse return LogError.MalformedLog) catch
                return LogError.MalformedLog;
            var preimage_buf: [3 * SAID_LEN + 2]u8 = undefined;
            const preimage = rotationPreimage(&preimage_buf, said, key_b64, next_b64);
            verify(current, preimage, sig) catch return LogError.BadRotationSignature;
        }

        current = verkey;
        next_commitment = next_b64[0..SAID_LEN].*;
        prior_said = said[0..SAID_LEN].*;
        seen += 1;
    }

    if (seen == 0) return LogError.MalformedLog;
    return current;
}

/// Prove that a presented key really speaks for the AID presented alongside it:
/// the log must derive that AID and must end on that key. A key the log has
/// already rotated away from fails here, which is the point — a pre-rotation key
/// that leaked after its rotation buys its holder nothing.
pub fn verifyBinding(
    allocator: std.mem.Allocator,
    kel: []const u8,
    aid: []const u8,
    presented: [32]u8,
) LogError!void {
    const current = try currentVerkey(allocator, kel, aid);
    if (!std.mem.eql(u8, &current, &presented)) return LogError.RetiredKey;
}

/// The next-key commitment: a digest over the next verkey, which is the
/// pre-rotation discipline itself — commit to the key before exposing it. An
/// event writes it; a verifier recomputes it over the key a later event reveals.
fn nextKeyDigest(next_verkey: [32]u8) [SAID_LEN]u8 {
    var out: [SAID_LEN]u8 = undefined;
    encodeSaid('E', blake3(&next_verkey), &out);
    return out;
}

fn strField(event: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = event.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// The single string in a one-element JSON array, the shape `k` and `n` carry.
fn soleOf(event: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = event.get(key) orelse return null;
    const arr = switch (v) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len != 1) return null;
    return switch (arr.items[0]) {
        .string => |s| s,
        else => null,
    };
}

// --- The walk, shown refusing --------------------------------------------------
//
// `currentVerkey` is the check that decides whether a host will attribute an
// Episode at all, so each way it can refuse gets a test. A log a stranger hands
// over is attacker-controlled input; these are the shapes an attacker would try.
// The tests forge with the same minting the honest path uses, so a forged event
// is well-formed in every respect except the one under test.

const testing = std.testing;

fn seededKey(seed_byte: u8) !Key {
    return Key.fromSeed(.{seed_byte} ** SEED_BYTES);
}

fn codedVerkey(key: Key) [SAID_LEN]u8 {
    var out: [SAID_LEN]u8 = undefined;
    encodeSaid('D', key.verkey(), &out);
    return out;
}

/// One inception event plus one rotation, as a log's bytes. The rotation's parts
/// are the test's to choose, so a test can break exactly one of them.
fn logWithRotation(
    allocator: std.mem.Allocator,
    icp: []const u8,
    parts: RotationParts,
) ![]u8 {
    const rot = try mintRotation(allocator, parts);
    defer allocator.free(rot.bytes);
    return std.fmt.allocPrint(allocator, "{s}{s}\n", .{ icp, rot.bytes });
}

test "a presented log binds the key its rotations end on" {
    const allocator = testing.allocator;
    const first = try seededKey(0x01);
    const committed = try seededKey(0x02);
    const after = try seededKey(0x03);

    var id = try Identity.inceptFrom(allocator, first, committed);
    defer id.deinit();

    // The inception event alone: the key it names is current.
    try verifyBinding(allocator, id.kelSlice(), id.aidSlice(), first.verkey());
    try testing.expectError(
        LogError.RetiredKey,
        verifyBinding(allocator, id.kelSlice(), id.aidSlice(), committed.verkey()),
    );

    const parts: RotationParts = .{
        .aid = id.aid,
        .sn = 1,
        .prior = id.said,
        .verkey_b64 = codedVerkey(committed),
        .next_digest = nextKeyDigest(after.verkey()),
        .signer = first,
    };
    const log = try logWithRotation(allocator, id.kelSlice(), parts);
    defer allocator.free(log);

    // After the rotation the committed key is current, and the key that signed
    // that rotation is retired.
    try verifyBinding(allocator, log, id.aidSlice(), committed.verkey());
    try testing.expectError(
        LogError.RetiredKey,
        verifyBinding(allocator, log, id.aidSlice(), first.verkey()),
    );
}

test "a log that does not derive the claimed AID is refused" {
    const allocator = testing.allocator;
    var mine = try Identity.inceptFrom(allocator, try seededKey(0x11), try seededKey(0x12));
    defer mine.deinit();
    var theirs = try Identity.inceptFrom(allocator, try seededKey(0x21), try seededKey(0x22));
    defer theirs.deinit();

    // Naming somebody else's AID while presenting your own log, the attack the
    // signed subject alone could not catch.
    try testing.expectError(
        LogError.AidMismatch,
        currentVerkey(allocator, mine.kelSlice(), theirs.aidSlice()),
    );
}

test "an edited event no longer hashes to the name it goes by" {
    const allocator = testing.allocator;
    var id = try Identity.inceptFrom(allocator, try seededKey(0x31), try seededKey(0x32));
    defer id.deinit();

    const edited = try std.mem.replaceOwned(u8, allocator, id.kelSlice(), "\"s\":\"0\"", "\"s\":\"9\"");
    defer allocator.free(edited);
    try testing.expectError(
        LogError.SaidMismatch,
        currentVerkey(allocator, edited, id.aidSlice()),
    );
}

test "a log must open with an inception event" {
    const allocator = testing.allocator;
    const first = try seededKey(0x41);
    const committed = try seededKey(0x42);
    var id = try Identity.inceptFrom(allocator, first, committed);
    defer id.deinit();

    const rot = try mintRotation(allocator, .{
        .aid = id.aid,
        .sn = 1,
        .prior = id.said,
        .verkey_b64 = codedVerkey(committed),
        .next_digest = nextKeyDigest((try seededKey(0x43)).verkey()),
        .signer = first,
    });
    defer allocator.free(rot.bytes);

    // The rotation on its own proves nothing: there is no event to derive the
    // AID from, so there is nothing binding the chain to the identifier.
    try testing.expectError(
        LogError.NotInception,
        currentVerkey(allocator, rot.bytes, id.aidSlice()),
    );
}

test "a rotation must name the event before it" {
    const allocator = testing.allocator;
    const first = try seededKey(0x51);
    const committed = try seededKey(0x52);
    var id = try Identity.inceptFrom(allocator, first, committed);
    defer id.deinit();

    var elsewhere = id.aid;
    elsewhere[SAID_LEN - 1] = if (elsewhere[SAID_LEN - 1] == 'A') 'B' else 'A';

    const log = try logWithRotation(allocator, id.kelSlice(), .{
        .aid = id.aid,
        .sn = 1,
        .prior = elsewhere,
        .verkey_b64 = codedVerkey(committed),
        .next_digest = nextKeyDigest((try seededKey(0x53)).verkey()),
        .signer = first,
    });
    defer allocator.free(log);

    try testing.expectError(
        LogError.BrokenChain,
        currentVerkey(allocator, log, id.aidSlice()),
    );
}

test "a rotation must reveal the key its predecessor committed to" {
    const allocator = testing.allocator;
    const first = try seededKey(0x61);
    const committed = try seededKey(0x62);
    const uncommitted = try seededKey(0x63);
    var id = try Identity.inceptFrom(allocator, first, committed);
    defer id.deinit();

    // The holder of the current key rotating to a key it never pre-committed:
    // pre-rotation is what makes that inadmissible, so the log is refused even
    // though the rotation is properly signed.
    const log = try logWithRotation(allocator, id.kelSlice(), .{
        .aid = id.aid,
        .sn = 1,
        .prior = id.said,
        .verkey_b64 = codedVerkey(uncommitted),
        .next_digest = nextKeyDigest((try seededKey(0x64)).verkey()),
        .signer = first,
    });
    defer allocator.free(log);

    try testing.expectError(
        LogError.BrokenPreRotation,
        currentVerkey(allocator, log, id.aidSlice()),
    );
}

test "a rotation must be signed by the key it retires" {
    const allocator = testing.allocator;
    const first = try seededKey(0x71);
    const committed = try seededKey(0x72);
    var id = try Identity.inceptFrom(allocator, first, committed);
    defer id.deinit();

    // Signed by the key being revealed rather than the one being retired, which
    // is what a holder of the new key alone could produce.
    const log = try logWithRotation(allocator, id.kelSlice(), .{
        .aid = id.aid,
        .sn = 1,
        .prior = id.said,
        .verkey_b64 = codedVerkey(committed),
        .next_digest = nextKeyDigest((try seededKey(0x73)).verkey()),
        .signer = committed,
    });
    defer allocator.free(log);

    try testing.expectError(
        LogError.BadRotationSignature,
        currentVerkey(allocator, log, id.aidSlice()),
    );
}

test "a log with no events is not a log" {
    const allocator = testing.allocator;
    var id = try Identity.inceptFrom(allocator, try seededKey(0x81), try seededKey(0x82));
    defer id.deinit();

    try testing.expectError(
        LogError.MalformedLog,
        currentVerkey(allocator, "", id.aidSlice()),
    );
    try testing.expectError(
        LogError.MalformedLog,
        currentVerkey(allocator, "not json\n", id.aidSlice()),
    );
}
