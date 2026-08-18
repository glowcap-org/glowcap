//! Identity binding for ADR-0107's Noise channel.
//!
//! Noise authenticates X25519 static keys. Pancake names peers with Ed25519,
//! so the handshake payload proves the exact Ed25519 encoding, role, initial
//! transcript, and authenticated X25519 static together. This module owns that
//! statement and the transport/designator prologue; `sealed.zig` owns stream
//! progression and record storage.

const std = @import("std");

const crypto = @import("crypto.zig");
const noise = @import("noise.zig");

/// The byte joining transport symbol and responder designator in the Noise
/// prologue. Neither input may contain zero, so the split is unambiguous.
const prologue_separator: u8 = 0;

pub const proof_bytes: usize = crypto.PEER_KEY_BYTES + crypto.SIGNATURE_BYTES;

/// Room for the longest transport symbol beside a 64-hex-digit designator.
pub const prologue_max_bytes: usize = 96;

const proof_domain = "pancake sealed identity proof v1";
const statement_bytes = proof_domain.len + 1 + noise.KEY_BYTES +
    crypto.PEER_KEY_BYTES + noise.KEY_BYTES;

fn statement(
    role: noise.Role,
    context: [noise.KEY_BYTES]u8,
    identity: crypto.PeerKey,
    static: [noise.KEY_BYTES]u8,
) [statement_bytes]u8 {
    var out: [statement_bytes]u8 = undefined;
    var at: usize = 0;
    @memcpy(out[at..][0..proof_domain.len], proof_domain);
    at += proof_domain.len;
    out[at] = @intFromEnum(role);
    at += 1;
    @memcpy(out[at..][0..context.len], &context);
    at += context.len;
    @memcpy(out[at..][0..identity.bytes.len], &identity.bytes);
    at += identity.bytes.len;
    @memcpy(out[at..][0..static.len], &static);
    return out;
}

pub fn makeProof(
    identity: *const crypto.SecretKey,
    role: noise.Role,
    static: [noise.KEY_BYTES]u8,
    context: [noise.KEY_BYTES]u8,
) [proof_bytes]u8 {
    const public = identity.publicKey();
    const signed = statement(role, context, public, static);
    const signature = crypto.sign(identity, &signed);
    var out: [proof_bytes]u8 = undefined;
    out[0..crypto.PEER_KEY_BYTES].* = public.bytes;
    out[crypto.PEER_KEY_BYTES..].* = signature.bytes;
    return out;
}

pub fn verifyProof(
    proof: []const u8,
    role: noise.Role,
    context: [noise.KEY_BYTES]u8,
    static: [noise.KEY_BYTES]u8,
    expected: ?crypto.PeerKey,
) error{IdentityMismatch}!crypto.PeerKey {
    if (proof.len != proof_bytes) return error.IdentityMismatch;
    const peer = crypto.PeerKey.fromBytes(proof[0..crypto.PEER_KEY_BYTES].*);
    if (expected) |key| {
        if (!peer.eql(key)) return error.IdentityMismatch;
    }
    const mapped = crypto.x25519FromPeerKey(peer) orelse return error.IdentityMismatch;
    if (!std.mem.eql(u8, &mapped, &static)) return error.IdentityMismatch;
    const signature = crypto.Signature.fromBytes(
        proof[crypto.PEER_KEY_BYTES..][0..crypto.SIGNATURE_BYTES].*,
    );
    const signed = statement(role, context, peer, static);
    crypto.verify(peer, &signed, signature) catch return error.IdentityMismatch;
    return peer;
}

pub fn buildPrologue(
    buf: *[prologue_max_bytes]u8,
    transport: []const u8,
    designator: []const u8,
) []const u8 {
    std.debug.assert(transport.len + 1 + designator.len <= buf.len);
    @memcpy(buf[0..transport.len], transport);
    buf[transport.len] = prologue_separator;
    @memcpy(buf[transport.len + 1 ..][0..designator.len], designator);
    return buf[0 .. transport.len + 1 + designator.len];
}
