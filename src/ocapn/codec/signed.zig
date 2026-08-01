//! The byte form OCapN signatures are defined over.
//!
//! It is Syrup, always, and it deliberately does **not** follow the session's
//! negotiated codec. A `desc:handoff-give` signed by a gifter on one session is
//! verified by an exporter on a different one, and those two sessions negotiate
//! their codecs independently. If the signed bytes followed the negotiation, a
//! give minted on a Cap'n Proto session would not verify on a Syrup one, and
//! three-party handoff would work only when all three parties happened to agree
//! on a wire format they never coordinate.
//!
//! So the signed envelope has one grammar, and `codec.dispatch` is not
//! consulted here. That is the precondition, not merely the motivation: every
//! other byte the engine emits goes through `dispatch` precisely so the
//! negotiated codec decides, and a reader who ports that pattern to these
//! functions breaks cross-codec handoff in a way no single-codec test would
//! catch.
//!
//! This module exists so the engine has one import that says all of the above,
//! rather than seventeen call sites reading as if Syrup were an incidental
//! choice at each one. `arch-check` holds the boundary: `codec.syrup` and
//! `codec.capnp` may be named only under `src/ocapn/codec/` and `src/oracle/`.

const syrup = @import("syrup");

// ── The signed location record ───────────────────────────────────────────────

/// Canonical Syrup bytes of a peer's location, as signed in `op:start-session`.
pub const locationBytes = syrup.canonicalLocationSignedBytes;

/// The same bytes from an already-encoded record, for a verifier holding the
/// verbatim span rather than a parsed locator.
pub const locationBytesRaw = syrup.canonicalLocationSignedBytesRaw;

/// Encode a `<ocapn-peer …>` record. A give embeds these verbatim, so this is
/// the only spelling that may reach a signed envelope.
pub const encodeLocatorRecord = syrup.encodePeerLocatorRecord;

/// Parse a verbatim `<ocapn-peer …>` record into an owned locator, the matching
/// decode of `encodeLocatorRecord`. A URI, or any other spelling, fails loud
/// here rather than being spliced into a give.
pub const readLocatorOwned = syrup.readLocatorOwned;

// ── The signed handoff envelopes ─────────────────────────────────────────────

/// Canonical Syrup bytes of a `desc:handoff-give`, the payload a gifter signs.
pub const giveBytes = syrup.canonicalHandoffGiveSignedBytes;

/// Canonical Syrup bytes of a borrowed `desc:handoff-give`.
pub const giveViewBytes = syrup.canonicalHandoffGiveViewSignedBytes;

/// Canonical Syrup bytes of a `desc:handoff-receive`, the payload a recipient
/// signs when it presents a gift to the exporter.
pub const receiveBytes = syrup.canonicalHandoffReceiveSignedBytes;

/// Canonical Syrup bytes of a borrowed `desc:handoff-receive`.
pub const receiveViewBytes = syrup.canonicalHandoffReceiveViewSignedBytes;

/// Wrap a give and its signature into the `<desc:sig-envelope …>` a recipient
/// receives.
pub const wrapGive = syrup.wrapSignedHandoffGive;

/// Decode a signed give envelope into an owned model value.
pub const decodeGiveOwned = syrup.decodeSignedHandoffGiveOwned;

/// The verbatim exporter-location span inside a give record. Verification runs
/// over the bytes as they arrived, never over a re-encode of the parsed value,
/// so a peer whose encoder differs in any detail still verifies.
pub const giveRecordRawLocation = syrup.handoffGiveRecordBytesRawLocation;
