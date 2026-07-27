//! The `op:start-session` handshake state, the session-owned half.
//!
//! Both peers exchange one `op:start-session` half (ADR-0006). The session
//! records whether each half has been seen and what the partner's half
//! carried, its session public key, its location designator, and the verbatim
//! `<ocapn-peer ...>` location bytes a gifter later embeds in a
//! `desc:handoff-give` (ADR-0009). Those are authoritative session state, so the
//! fields live on `Session`; this file owns the operations over them and
//! `Session` aliases each function as a method. Flipping `negotiating` to `open`
//! also installs the fixed bootstrap export, the one fallible step, so a failed
//! registration leaves the session untouched.

const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Both handshake halves observed, the precondition for `open`.
pub fn handshakeComplete(self: *const Session) bool {
    return self.handshake_local_sent and self.handshake_remote_received;
}

/// Moves the session from `Negotiating` to `Open`. It installs the fixed
/// bootstrap export at
/// `BOOTSTRAP_POSITION` (the only fallible step) then flips state, so a
/// failed registration leaves the session untouched. Called from the
/// `start_session` apply arms once both handshake halves are observed.
pub fn transitionToOpen(self: *Session) !void {
    try self.exports.register(self.allocator, model.ExportPosition.from(BOOTSTRAP_POSITION));
    // Reserve the bootstrap id: locally-allocated exports (resolver callbacks,
    // promises, gifts) start past it so `allocateExport` never aliases it.
    if (self.next_export_position <= BOOTSTRAP_POSITION) {
        self.next_export_position = BOOTSTRAP_POSITION + 1;
    }
    self.state = .open;
}

/// The partner's session public key, learned from its `op:start-session`, or
/// null if the partner's handshake half has not yet arrived with a key. An
/// embedder verifies the partner's signatures against it, for a
/// gifter-to-exporter session, this is the key the gifter's `desc:handoff-give`
/// is signed with, so the exporter can record it with a deposited gift.
pub fn partnerSessionKey(self: *const Session) ?[]const u8 {
    if (self.partner_session_key.len == 0) return null;
    return self.partner_session_key;
}

/// This side's own session public key, from the `op:start-session` half we
/// sent, or null if that half has not been sent or carried no key. An exporter
/// derives from it the session name an inbound `desc:handoff-receive` must
/// carry, so a withdrawal cannot claim to belong to a session it is not part of
/// (ADR-0009).
pub fn localSessionKey(self: *const Session) ?[]const u8 {
    if (self.local_session_key.len == 0) return null;
    return self.local_session_key;
}

/// The partner's location designator from its `op:start-session`, or null if
/// the handshake half has not arrived with one.
pub fn partnerDesignator(self: *const Session) ?[]const u8 {
    if (self.partner_designator.len == 0) return null;
    return self.partner_designator;
}

/// The partner's verbatim `<ocapn-peer ...>` location-record bytes from its
/// `op:start-session`, or null when the handshake half has not arrived with raw
/// bytes (the decode path captures them; an owned-message apply path does not).
/// A gifter embeds these as a `desc:handoff-give`'s exporter-location so a peer
/// comparing locations matches byte-for-byte (ADR-0009).
pub fn partnerLocatorRaw(self: *const Session) ?[]const u8 {
    if (self.partner_acceptable_location_raw.len == 0) return null;
    return self.partner_acceptable_location_raw;
}
