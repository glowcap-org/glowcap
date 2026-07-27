//! The two names a three-party handoff is addressed by (ADR-0009).
//!
//! A handoff record names the side that is redeeming and the session the
//! redemption belongs to. Both are derived from session public keys, never read
//! off the wire and trusted: the recipient derives them to build a
//! `desc:handoff-receive`, and the exporter derives them again to check that the
//! receive it was handed names the parties it actually came from. They live in
//! their own leaf so both sides can share one derivation without the recipient
//! builder and the exporter's gift registry having to import each other.

const crypto = @import("foundation").crypto;

/// The OCapN Public Identifier for a session public key (Goblins calls it the
/// "side name"): `crypto.derivePublicIdentifier`, surfaced as raw 32 bytes for the
/// handoff records that carry it. Single-sourced against the foundation
/// derivation so the side a handoff names can never drift from the side a
/// handshake derives. The key must be exactly a 32-byte Ed25519 public key — the
/// only width the protocol uses; any other length is `MalformedKey`.
pub fn sideName(key: []const u8) error{MalformedKey}![32]u8 {
    const peer_key = crypto.PeerKey.fromSlice(key) catch return error.MalformedKey;
    return crypto.derivePublicIdentifier(peer_key).bytes;
}

/// The OCapN Session ID for two side names (Goblins's "session name"),
/// (`crypto.sessionIdFromPeerIds`) computed from sides the caller already holds.
/// The derivation sorts its two inputs, so both ends of a session compute the
/// same name without agreeing on an order first.
pub fn sessionName(side_a: [32]u8, side_b: [32]u8) [32]u8 {
    return crypto.sessionIdFromPeerIds(.fromBytes(side_a), .fromBytes(side_b)).bytes;
}

/// The receiver identity an inbound `desc:handoff-receive` must name, derived
/// from the keys of the session the withdraw arrived on.
///
/// The two names in a receive belong to the *recipient-to-exporter* session, not
/// to the gifter's. A recipient may hold a different session key on each of its
/// connections: it signs the receive with the key the gifter named in the give,
/// while naming the side and session of the connection it is withdrawing over.
/// So the exporter derives these from its own key and the partner key its
/// handshake established, which are the two ends of that very session.
///
/// Deriving rather than reading is what makes the replay counter safe. That
/// counter lives in a registry shared by every session on the host, and a peer
/// that could choose its key would set another pair's counter to `maxInt(u64)`
/// and refuse their handoffs for the life of the process. A partner key comes
/// from an authenticated handshake, so no peer can present another's.
pub const ExpectedReceiver = struct {
    /// The withdrawing partner's side name. The exporter keys the replay
    /// counter by this rather than by the name the receive carries.
    side: [32]u8,
    /// The session name the receive must carry, or null when this side sent no
    /// keyed `op:start-session` and so cannot say which of its own keys the
    /// partner addressed. The side above is derived either way, so the counter
    /// is unforgeable whether or not this one is known.
    session: ?[32]u8,

    /// Derive from the withdrawing session's partner key alone, for a session
    /// that carries no key of its own. Must be a 32-byte Ed25519 public key.
    pub fn fromPartner(partner_key: []const u8) error{MalformedKey}!ExpectedReceiver {
        return .{ .side = try sideName(partner_key), .session = null };
    }

    /// Derive from both ends of the withdrawing session. Both must be 32-byte
    /// Ed25519 public keys.
    pub fn derive(partner_key: []const u8, our_key: []const u8) error{MalformedKey}!ExpectedReceiver {
        const partner_side = try sideName(partner_key);
        const our_side = try sideName(our_key);
        return .{
            .side = partner_side,
            .session = sessionName(partner_side, our_side),
        };
    }
};
