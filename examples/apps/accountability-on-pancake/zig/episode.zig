//! An Episode: the signed, auditable record of one capability invocation.
//!
//! Application vocabulary, above pancake. Each invocation across the wire emits
//! an Episode: a small JSON-LD-shaped quad (subject = the *true* caller, predicate
//! = invoked, object = affordance + result, graph = the hosting vat's identity)
//! with bitemporal columns. The signing chain is the load-bearing part and is the
//! same one the Goblins worked example pins:
//!
//!   1. A per-Episode ephemeral Ed25519 keypair is drawn. Sigstore-style, the
//!      ephemeral secret never outlives this one signing operation.
//!   2. The ephemeral key signs the Episode payload.
//!   3. The signer identity's CURRENT (post-rotation) KERI verkey countersigns
//!      the ephemeral public key, anchoring the ephemeral identity to the KEL.
//!
//! An auditor verifies both links: the countersignature against the signer's
//! authoritative verkey, and the payload signature against the ephemeral key.
//! Revoke the AID and every past Episode still verifies for its time window;
//! compromise one ephemeral key and only one Episode is at risk.

const std = @import("std");

const identity = @import("identity.zig");

const enc = std.base64.url_safe_no_pad.Encoder;
const dec = std.base64.url_safe_no_pad.Decoder;

pub const Kind = enum {
    /// Emitted by the caller before delegating to the wire send: intent to invoke.
    attempt,
    /// Emitted by the host after the invocation resolves: the realized outcome.
    outcome,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .attempt => "Attempt",
            .outcome => "Outcome",
        };
    }
};

pub const Error = error{BadEpisode} || std.mem.Allocator.Error || identity.Error;

/// The semantic content of an Episode, borrowed for the duration of `emit`.
pub const Facts = struct {
    kind: Kind,
    /// The AID of the *true* caller this invocation is attributed to.
    subject: []const u8,
    affordance: []const u8,
    object: []const u8,
    /// The hosting vat's AID (the named graph).
    graph: []const u8,
    seq: u64,
    valid_time: i64,
    tx_time: i64,
};

/// The deterministic byte preimage the ephemeral key signs. A pipe-delimited
/// canonical form over the semantic fields, order-fixed so signer and auditor
/// hash the same bytes.
fn payloadBytes(buf: []u8, f: Facts) []const u8 {
    return std.fmt.bufPrint(buf, "{s}|{s}|invoked|{s}|{s}|{s}|{d}|{d}|{d}", .{
        f.kind.label(), f.subject, f.affordance, f.object, f.graph, f.seq, f.valid_time, f.tx_time,
    }) catch unreachable;
}

/// Emit one Episode line. Returns an owned JSON line (no trailing newline). The
/// `signer` provides the authoritative KERI key that countersigns the ephemeral.
pub fn emit(allocator: std.mem.Allocator, io: std.Io, signer: *const identity.Identity, f: Facts) Error![]u8 {
    const ephemeral = try identity.Key.random(io);

    var payload_buf: [1024]u8 = undefined;
    const payload = payloadBytes(&payload_buf, f);

    const payload_sig = ephemeral.sign(payload);
    const counter_sig = signer.current.sign(&ephemeral.verkey());

    var eph_b64: [1 + enc.calcSize(32)]u8 = undefined; // 'X' code + verkey
    eph_b64[0] = 'X';
    _ = enc.encode(eph_b64[1..], &ephemeral.verkey());

    var signer_vk_b64: [1 + enc.calcSize(32)]u8 = undefined;
    signer_vk_b64[0] = 'D';
    _ = enc.encode(signer_vk_b64[1..], &signer.current.verkey());

    var psig_b64: [enc.calcSize(64)]u8 = undefined;
    _ = enc.encode(&psig_b64, &payload_sig);
    var csig_b64: [enc.calcSize(64)]u8 = undefined;
    _ = enc.encode(&csig_b64, &counter_sig);

    return std.fmt.allocPrint(allocator,
        \\{{"@type":"Episode","kind":"{s}","subject":"{s}","predicate":"invoked","affordance":"{s}","object":"{s}","graph":"{s}","seq":{d},"valid_time":{d},"tx_time":{d},"ephemeral":"{s}","signer":"{s}","payload_sig":"{s}","counter_sig":"{s}"}}
    , .{
        f.kind.label(), f.subject,    f.affordance, f.object, f.graph,
        f.seq,          f.valid_time, f.tx_time,    eph_b64,  signer_vk_b64,
        psig_b64,       csig_b64,
    });
}

/// What an auditor recovers from an Episode line.
pub const Verified = struct {
    kind: []const u8,
    subject: []const u8,
    affordance: []const u8,
    object: []const u8,
    graph: []const u8,
};

/// Verify an Episode line end to end: recompute the payload, check the
/// countersignature of the ephemeral key against the signer's verkey, and check
/// the payload signature against the ephemeral key. The returned slices borrow
/// the parsed JSON, valid until `parsed.deinit()`.
pub fn verify(allocator: std.mem.Allocator, line: []const u8) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return Error.BadEpisode;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.BadEpisode,
    };

    const kind = strField(obj, "kind") orelse return Error.BadEpisode;
    const subject = strField(obj, "subject") orelse return Error.BadEpisode;
    const affordance = strField(obj, "affordance") orelse return Error.BadEpisode;
    const object = strField(obj, "object") orelse return Error.BadEpisode;
    const graph = strField(obj, "graph") orelse return Error.BadEpisode;
    const ephemeral_b64 = strField(obj, "ephemeral") orelse return Error.BadEpisode;
    const signer_b64 = strField(obj, "signer") orelse return Error.BadEpisode;
    const psig_b64 = strField(obj, "payload_sig") orelse return Error.BadEpisode;
    const csig_b64 = strField(obj, "counter_sig") orelse return Error.BadEpisode;
    const seq = intField(obj, "seq") orelse return Error.BadEpisode;
    const valid_time = intField(obj, "valid_time") orelse return Error.BadEpisode;
    const tx_time = intField(obj, "tx_time") orelse return Error.BadEpisode;

    const ephemeral = try decodeKey(ephemeral_b64);
    const signer_vk = try decodeKey(signer_b64);
    const psig = try decodeSig(psig_b64);
    const csig = try decodeSig(csig_b64);

    // Link 1: the signer's authoritative key countersigned this ephemeral key.
    try identity.verify(signer_vk, &ephemeral, csig);

    // Link 2: the ephemeral key signed exactly this payload.
    const f = Facts{
        .kind = if (std.mem.eql(u8, kind, "Attempt")) .attempt else .outcome,
        .subject = subject,
        .affordance = affordance,
        .object = object,
        .graph = graph,
        .seq = @intCast(seq),
        .valid_time = valid_time,
        .tx_time = tx_time,
    };
    var payload_buf: [1024]u8 = undefined;
    const payload = payloadBytes(&payload_buf, f);
    try identity.verify(ephemeral, payload, psig);
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Decode a `code`-prefixed base64url verkey (drop the 1-char derivation code).
fn decodeKey(b64: []const u8) Error![32]u8 {
    if (b64.len != 1 + enc.calcSize(32)) return Error.BadEpisode;
    var out: [32]u8 = undefined;
    dec.decode(&out, b64[1..]) catch return Error.BadEpisode;
    return out;
}

fn decodeSig(b64: []const u8) Error![64]u8 {
    if (b64.len != enc.calcSize(64)) return Error.BadEpisode;
    var out: [64]u8 = undefined;
    dec.decode(&out, b64) catch return Error.BadEpisode;
    return out;
}
