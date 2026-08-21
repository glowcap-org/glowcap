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
//! These are the load-bearing KERI properties. SAID rendering, keys, and the
//! draft digest live in `said.zig`. Minting a rotation and walking a presented
//! log live in `kel.zig`.
//!
//! What is NOT claimed: byte-for-byte CESR / keripy conformance. The AID is an
//! `E`-prefixed Blake3-256 SAID rendered as base64url, which is KERI-*shaped* but
//! does not reproduce keripy's exact CESR pre-pad alignment, so the `keripy`
//! oracle in `conformance/keri-conformance/` would not verify these identifiers.
//! Closing that gap is a known boundary, not faked here.

const std = @import("std");

const said_mod = @import("said.zig");
const kel_mod = @import("kel.zig");

const Key = said_mod.Key;
const SAID_LEN = said_mod.SAID_LEN;
const SEED_BYTES = said_mod.SEED_BYTES;
const blank = said_mod.blank;
const encodeSaid = said_mod.encodeSaid;
const saidOf = said_mod.saidOf;
const nextKeyDigest = said_mod.nextKeyDigest;

pub const Error = kel_mod.Error;
pub const LogError = kel_mod.LogError;
pub const currentVerkey = kel_mod.currentVerkey;
pub const verifyBinding = kel_mod.verifyBinding;

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
        var placeholder: [SAID_LEN]u8 = @splat(blank);
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

        const event = try kel_mod.mintRotation(self.allocator, .{
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

// --- The walk, shown refusing --------------------------------------------------
//
// `currentVerkey` is the check that decides whether a host will attribute an
// Episode at all, so each way it can refuse gets a test. A log a stranger hands
// over is attacker-controlled input; these are the shapes an attacker would try.
// The tests forge with the same minting the honest path uses, so a forged event
// is well-formed in every respect except the one under test.

const testing = std.testing;

fn seededKey(seed_byte: u8) !Key {
    return Key.fromSeed(@as([SEED_BYTES]u8, @splat(seed_byte)));
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
    parts: kel_mod.RotationParts,
) ![]u8 {
    const rot = try kel_mod.mintRotation(allocator, parts);
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

    const parts: kel_mod.RotationParts = .{
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

    const rot = try kel_mod.mintRotation(allocator, .{
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
