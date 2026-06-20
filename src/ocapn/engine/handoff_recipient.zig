//! Recipient-side handoff helpers (ADR-0009): session/side naming and signed
//! `desc:handoff-receive` construction. I/O-bound withdraw choreography stays in
//! the adapter; these are the crypto/session primitives any host needs.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const session_mod = @import("session");
const bootstrap = @import("bootstrap.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Double-SHA256 a gifter uses to derive a stable gift id from a swissnum.
pub fn sha256d(data: []const u8) [32]u8 {
    var once: [32]u8 = undefined;
    Sha256.hash(data, &once, .{});
    var twice: [32]u8 = undefined;
    Sha256.hash(&once, &twice, .{});
    return twice;
}

/// Goblins "side name" for a session public key — the OCapN Public Identifier
/// (`crypto.derivePublicIdentifier`), surfaced as its raw 32 bytes for the
/// handoff records that carry it. Single-sourced against the foundation
/// derivation so the side a handoff names can never drift from the side a
/// handshake derives. The key must be exactly a 32-byte Ed25519 public key — the
/// only width the protocol uses; any other length is `MalformedKey`.
pub fn sideName(key: []const u8) error{MalformedKey}![32]u8 {
    const peer_key = crypto.PeerKey.fromSlice(key) catch return error.MalformedKey;
    return crypto.derivePublicIdentifier(peer_key).bytes;
}

/// Goblins "session name" for two side names, the OCapN Session ID
/// (`crypto.sessionIdFromPeerIds`) computed from sides the caller already holds.
pub fn sessionName(side_a: [32]u8, side_b: [32]u8) [32]u8 {
    return crypto.sessionIdFromPeerIds(.fromBytes(side_a), .fromBytes(side_b)).bytes;
}

/// A signed `desc:handoff-receive` that owns its derived bytes. The session and
/// side names and the signature live inline, so the `model.HandoffReceive` that
/// `message` projects borrows only this value, no dangling stack references
/// once the builder returns. The caller holds the `SignedReceive` until the
/// withdraw it carries has been encoded, and keeps owning `give_bytes`.
pub const SignedReceive = struct {
    receiving_session: [32]u8,
    receiving_side: [32]u8,
    signature: [crypto.SIGNATURE_BYTES]u8,
    give_bytes: []const u8,
    handoff_count: u64,

    /// Project the borrowed wire `desc:handoff-receive`. The returned value
    /// borrows `self`, so `self` must outlive every use of it.
    pub fn message(self: *const SignedReceive) model.HandoffReceive {
        return .{
            .receiving_session = &self.receiving_session,
            .receiving_side = &self.receiving_side,
            .handoff_count = self.handoff_count,
            .signed_give = .{
                .recipient_key = "",
                .exporter_location = "",
                .gifter_exporter_session = "",
                .gifter_side = "",
                .gift_id = "",
                .signature = "",
                .raw_signed = self.give_bytes,
            },
            .signature = &self.signature,
        };
    }
};

/// Build a signed `desc:handoff-receive` embedding the gifter's exact give bytes,
/// returning a self-contained `SignedReceive` the caller keeps alive while it
/// encodes the withdraw. `secret` is the recipient's session key — the one the
/// gifter named as the give's recipient key — so the exporter verifies the
/// receive against it. The `handoff_count` is minted from `registry` against the
/// derived receiving session, so the monotonic replay counter is owned by the
/// vat-scoped registry here rather than re-tracked by every caller (ADR-0056).
pub fn signedReceiveFromGiveBytes(
    allocator: std.mem.Allocator,
    limits: session_mod.SessionLimits,
    registry: *bootstrap.GiftRegistry,
    secret: crypto.SecretKey,
    our_pubkey: crypto.PeerKey,
    exporter_partner_key: []const u8,
    give_bytes: []const u8,
) !SignedReceive {
    const our_side = try sideName(our_pubkey.asBytes());
    const exporter_side = try sideName(exporter_partner_key);
    const receiving_session = sessionName(our_side, exporter_side);
    const handoff_count = try registry.nextEmittedCount(allocator, limits, &receiving_session);
    var result: SignedReceive = .{
        .receiving_session = receiving_session,
        .receiving_side = our_side,
        .signature = [_]u8{0} ** crypto.SIGNATURE_BYTES,
        .give_bytes = give_bytes,
        .handoff_count = handoff_count,
    };
    const receive_signed = try codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, result.message());
    defer allocator.free(receive_signed);
    result.signature = crypto.sign(&secret, receive_signed).bytes;
    return result;
}
