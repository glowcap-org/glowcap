//! Key event log: minting events and walking a log a stranger presents.
//!
//! An AID is the SAID of its inception event. This module is that log as
//! bytes: it renders an inception or a rotation, and it walks a presented
//! log to the verkey that is authoritative at the tip. The mutable
//! controller that appends those events lives in `identity.zig`.
//!
//! SAID rendering, keys, and the draft digest live in `said.zig`.

const std = @import("std");

const said_mod = @import("said.zig");

const Key = said_mod.Key;
const SAID_LEN = said_mod.SAID_LEN;
const SIG_LEN = said_mod.SIG_LEN;
const blank = said_mod.blank;
const saidOf = said_mod.saidOf;
const draftOf = said_mod.draftOf;
const decodeVerkey = said_mod.decodeVerkey;
const decodeSig = said_mod.decodeSig;
const verify = said_mod.verify;
const rotationPreimage = said_mod.rotationPreimage;
const nextKeyDigest = said_mod.nextKeyDigest;

pub const Error = said_mod.Error;

/// Why a presented key event log failed to bind a key to the AID it claims.
/// Each one is a refusal, and the host projects them all to a single typed
/// reason on the wire. They are separate here so a reader can see what the walk
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
    /// the log ends on, a retired pre-rotation key.
    RetiredKey,
} || Error;

/// What a rotation event says, apart from the SAID and signature it derives.
pub const RotationParts = struct {
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
pub fn mintRotation(
    allocator: std.mem.Allocator,
    parts: RotationParts,
) Error!struct { said: [SAID_LEN]u8, bytes: []u8 } {
    const draft = try renderRotation(allocator, parts, @splat(blank), @splat(blank));
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
/// has to earn its place, it names the event before it. It is signed by the key
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
        // bytes, so an edited event no longer hashes to the name it goes by. status-allow: lifecycle transition
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
            // the holder of the old key authorized the handover. status-allow: replacement state identity
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
/// already rotated away from fails here, which is the point, a pre-rotation key
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
