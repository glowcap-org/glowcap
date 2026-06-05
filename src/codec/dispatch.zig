//! Codec dispatch seam — routes a frame to its session's negotiated codec.
//!
//! Invariant 4: codec selection is per direct session. The session records the
//! negotiated [`model.CodecId`]; this seam switches on it so the runtime stays
//! codec-neutral — it never names `syrup` or `capnp` directly. Both arms
//! produce the identical [`model.view.Body`] on decode and an equivalent wire
//! [`foundation.Frame`] on encode, so the state machine above is codec-blind
//! (Invariant 1).

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const syrup = @import("syrup/mod.zig");
const capnp = @import("capnp/mod.zig");

pub const framing = @import("framing.zig");
pub const Prefix = framing.Prefix;

/// Union of both codecs' decode error sets. The runtime folds this into its
/// `DecodeError` alongside the lazy-projection [`model.view.ProjectError`].
pub const Error = syrup.Error || capnp.Error;

/// Project the borrowed codec-neutral body from `frame` using `codec`.
pub fn decodeBody(codec: model.CodecId, frame: foundation.FrameView) Error!model.view.Body {
    return switch (codec) {
        .syrup => syrup.decodeBody(frame),
        .capnp => capnp.decodeBody(frame),
    };
}

/// Frame the front of `bytes` as one `codec` message, reporting consumed length
/// or a structural verdict (incomplete / malformed / too_large). This is the
/// stream-framing entry point: the active codec's own decoder finds the frame
/// boundary as it decodes, so there is no separate boundary scanner to disagree
/// with the decode. `max_frame_bytes` caps an accepted frame.
pub fn decodePrefix(codec: model.CodecId, bytes: []const u8, max_frame_bytes: usize) Prefix {
    return switch (codec) {
        .syrup => syrup.decodePrefix(bytes, max_frame_bytes),
        .capnp => capnp.decodePrefix(bytes, max_frame_bytes),
    };
}

/// The wire frame shape `codec` produces and consumes (Invariant 4): Syrup is
/// a byte stream, Cap'n Proto is word-aligned. A byte-stream framer needs this
/// to materialize the owned frame it retains from a decoded prefix.
pub fn frameShape(codec: model.CodecId) foundation.FrameShape {
    return switch (codec) {
        .syrup => .byte,
        .capnp => .word,
    };
}

/// Encode `message` for `codec` under `profile`. The error set is inferred as
/// the union of the two codecs' encode errors (Syrup's is the inferred
/// allocating set; Cap'n Proto's is its explicit one).
pub fn encodeMessageForProfile(
    codec: model.CodecId,
    allocator: std.mem.Allocator,
    profile: model.WireProfile,
    message: model.Message,
) !foundation.Frame {
    return switch (codec) {
        .syrup => syrup.encodeMessageForProfile(allocator, profile, message),
        .capnp => capnp.encodeMessageForProfile(allocator, profile, message),
    };
}
