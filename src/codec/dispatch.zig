//! Sending each frame to the codec its session negotiated.
//!
//! The codec is chosen once per direct session, and the session remembers which
//! one as a `model.CodecId`. This small boundary switches on that, and that's
//! what lets the engine stay codec-neutral: it never has to say `syrup` or
//! `capnp` itself. Whichever arm runs, decode hands back the same
//! `model.view.Body` and encode hands back an equivalent `Frame`, so the state
//! machine above never has to care which codec is underneath.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const syrup = @import("syrup/mod.zig");
const capnp = @import("capnp/mod.zig");

pub const framing = @import("framing.zig");
pub const Prefix = framing.Prefix;

/// Union of both codecs' decode error sets. The engine folds this into its
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

/// The wire frame shape `codec` produces and consumes: Syrup is a byte stream,
/// Cap'n Proto is word-aligned. A byte-stream framer needs this
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
