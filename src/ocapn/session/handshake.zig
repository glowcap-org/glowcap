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

const std = @import("std");

const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;
const BOOTSTRAP_POSITION = session.BOOTSTRAP_POSITION;

/// Both handshake halves observed, the precondition for `open`.
pub fn handshakeComplete(self: *const Session) bool {
    return self.handshake_local_sent and self.handshake_remote_received;
}

/// Whether an inbound `op:start-session` would be the partner's handshake
/// half, rather than a duplicate or a hello arriving on an already-open or
/// closed session. `validateStartSession` refuses those two cases with their
/// own typed errors and is the authority that stops them; this reads the same
/// two fields as a plain question, for the engine's pre-open checks. They ask
/// it because signature verification and the durable-claim demand are
/// expensive and stateful, and neither belongs to a frame the session will
/// refuse a few steps later (`engine.inbound.applyDecodedOwnedFrame`).
pub fn awaitsPartnerHello(self: *const Session) bool {
    return self.state == .negotiating and !self.handshake_remote_received;
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

/// Whether this partner is known to be pancake by any signal: the dial- or
/// mirror-minted knowledge (`Session.partner_known_pancake`, ADR-0118), or a
/// hello that stated a non-baseline preference on any transport — only
/// pancake stamps the `pancake/*` hints. The give path reads this for the
/// recipient: a known-pancake recipient keeps the exporter's profile-hinted
/// location and can upgrade its redeem session; anyone else gets the
/// dialable bare form.
pub fn partnerKnownPancake(self: *const Session) bool {
    return self.partner_known_pancake or
        !std.meta.eql(self.partner_preference, model.Preference.baseline);
}

/// Whether this side's configured preference asks for a non-baseline CapTP
/// version or codec — ADR-0118's one opt-in, read where behavior would
/// otherwise change for a peer that never asked for an upgrade (the onion
/// accept's deferred hello). Features are deliberately not part of the
/// test: every peer offers the full ignorable feature set by default, so
/// features alone opt nothing in.
pub fn statesUpgradedProfile(self: *const Session) bool {
    const baseline = model.Preference.baseline;
    return self.preferred.captp_version != baseline.captp_version or
        self.preferred.codec != baseline.codec;
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
