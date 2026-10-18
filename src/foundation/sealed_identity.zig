//! Identity binding for ADR-0107's Noise channel.
//!
//! Noise authenticates X25519 static keys. Glowcap names peers with Ed25519,
//! so the handshake payload proves the exact Ed25519 encoding, role, initial
//! transcript, and authenticated X25519 static together. This module owns that
//! statement and the transport/designator prologue. `sealed.zig` owns stream
//! progression and record storage.

const std = @import("std");

const crypto = @import("crypto.zig");
const noise = @import("noise.zig");

/// The byte joining transport symbol and responder designator in the Noise
/// prologue. Neither input may contain zero, so the split is unambiguous.
const prologue_separator: u8 = 0;

pub const proof_bytes: usize = crypto.peer_key_bytes + crypto.signature_bytes;

/// The longest transport symbol a prologue holds. A Host refuses a
/// sealed-channel transport profile past this bound when it is defined, so
/// `TransportTooLong` names a symbol that never passed that door.
pub const max_transport_bytes: usize = 32;

/// A transport symbol at its bound, the separator, and a designator.
pub const prologue_max_bytes: usize = max_transport_bytes + 1 + crypto.PeerKey.designator_len;

const proof_domain = "glowcap sealed identity proof v1";
const statement_bytes = proof_domain.len + 1 + noise.key_bytes +
    crypto.peer_key_bytes + noise.key_bytes;

fn statement(
    role: noise.Role,
    context: [noise.key_bytes]u8,
    identity: crypto.PeerKey,
    static: [noise.key_bytes]u8,
) [statement_bytes]u8 {
    var out: [statement_bytes]u8 = undefined;
    var at: usize = 0;
    @memcpy(out[at..][0..proof_domain.len], proof_domain);
    at += proof_domain.len;
    out[at] = @backingInt(role);
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
    static: [noise.key_bytes]u8,
    context: [noise.key_bytes]u8,
) [proof_bytes]u8 {
    const public = identity.publicKey();
    const signed = statement(role, context, public, static);
    const signature = crypto.sign(identity, &signed);
    var out: [proof_bytes]u8 = undefined;
    out[0..crypto.peer_key_bytes].* = public.bytes;
    out[crypto.peer_key_bytes..].* = signature.bytes;
    return out;
}

pub fn verifyProof(
    proof: []const u8,
    role: noise.Role,
    context: [noise.key_bytes]u8,
    static: [noise.key_bytes]u8,
    expected: ?crypto.PeerKey,
) error{IdentityMismatch}!crypto.PeerKey {
    if (proof.len != proof_bytes) return error.IdentityMismatch;
    const peer = crypto.PeerKey.fromBytes(proof[0..crypto.peer_key_bytes].*);
    if (expected) |key| {
        if (!peer.eql(key)) return error.IdentityMismatch;
    }
    const mapped = crypto.x25519FromPeerKey(peer) orelse return error.IdentityMismatch;
    if (!std.mem.eql(u8, &mapped, &static)) return error.IdentityMismatch;
    const signature = crypto.Signature.fromBytes(
        proof[crypto.peer_key_bytes..][0..crypto.signature_bytes].*,
    );
    const signed = statement(role, context, peer, static);
    crypto.verify(peer, &signed, signature) catch return error.IdentityMismatch;
    return peer;
}

pub fn buildPrologue(
    buf: *[prologue_max_bytes]u8,
    transport: []const u8,
    designator: *const [crypto.PeerKey.designator_len]u8,
) error{TransportTooLong}![]const u8 {
    if (transport.len > max_transport_bytes) return error.TransportTooLong;
    @memcpy(buf[0..transport.len], transport);
    buf[transport.len] = prologue_separator;
    @memcpy(buf[transport.len + 1 ..][0..designator.len], designator);
    return buf[0 .. transport.len + 1 + designator.len];
}
