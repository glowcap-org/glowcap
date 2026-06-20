//! Cross-codec re-encode of a three-party handoff, signature-preserving
//! (ADR-0009 / ADR-0003).
//!
//! A `desc:handoff-give` / `desc:handoff-receive` signature covers the
//! **Syrup-canonical encoding of the decoded record**, never the session codec's
//! bytes (`codec.syrup.canonicalHandoffGiveSignedBytes` is the signing domain,
//! and the verifier — `engine.bootstrap` — re-canonicalizes to Syrup before
//! `crypto.verify`). That is what makes a handoff portable across codecs: once a
//! `model.Handoff` is decoded, its typed fields and its raw signature bytes carry
//! everything a verification needs, so the record can be re-encoded into a
//! *different* wire codec and the signature still verifies on the far side.
//!
//! `reEncodeHandoff` names exactly that move: take a decoded handoff and the
//! target session's codec/profile, and produce the frame that session would put
//! on the wire — the signature riding along untouched in the decoded fields. It
//! is the seam a relay crosses when the gifter-to-exporter session and the
//! recipient-to-exporter session ran different codecs. The signing domain stays
//! Syrup; only the envelope's transport encoding changes.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");

/// Re-encode a decoded `handoff` into `target_codec` under `target_profile`,
/// preserving the signature bytes verbatim (they live in the decoded record's
/// `signature` / `raw_signed` fields, which this only moves, never re-derives).
/// The result is the `op:` frame the target session would emit; the caller owns
/// it. Propagates the codec's encode error if the target codec rejects the
/// record. `handoff` is borrowed: this reads its fields and copies what the
/// frame needs, leaving the caller's value intact to free.
pub fn reEncodeHandoff(
    allocator: std.mem.Allocator,
    handoff: model.Handoff,
    target_codec: model.CodecId,
    target_profile: model.WireProfile,
) !foundation.Frame {
    return codec.dispatch.encodeMessageForProfile(
        target_codec,
        allocator,
        target_profile,
        .{ .handoff = handoff },
    );
}
