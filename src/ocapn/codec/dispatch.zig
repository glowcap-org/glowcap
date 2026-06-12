//! Sending each frame to the codec its session negotiated.
//!
//! The codec is chosen once per direct session, and the session remembers which
//! one as a `model.CodecId`. This boundary resolves that id against
//! `codec.registry` — at `comptime`, so the lookup unrolls to the same jump
//! table a hand-written switch would, with no runtime indirection — and that's
//! what lets the engine stay codec-neutral: it never has to say `syrup` or
//! `capnp` itself. Whichever codec runs, decode hands back the same
//! `model.view.Body` and encode hands back an equivalent `Frame`, so the state
//! machine above never has to care which codec is underneath.
//!
//! The `*With` variants take an explicit registry so a test (or a consumer) can
//! drive dispatch over a custom codec set; the public functions use
//! `registry.active`, the built-ins plus whatever the root file added.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

pub const framing = @import("framing");
pub const Prefix = framing.Prefix;
pub const registry = @import("registry.zig");
const Spec = registry.Spec;

/// Union of every registered codec's decode/encode error set, plus
/// `UnknownCodec`. The engine folds this into its `DecodeError` alongside the
/// lazy-projection `model.view.ProjectError`.
pub const Error = registry.Error;

/// Project the borrowed codec-neutral body from `frame` using `codec`.
pub fn decodeBody(codec: model.CodecId, frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyWith(registry.active, codec, frame);
}

pub fn decodeBodyWith(
    comptime specs: []const Spec,
    codec: model.CodecId,
    frame: foundation.FrameView,
) registry.unionErrors(specs)!model.view.Body {
    inline for (specs) |spec| {
        if (codec == spec.id) return spec.module.decodeBody(frame);
    }
    return error.UnknownCodec;
}

/// Frame the front of `bytes` as one `codec` message, reporting consumed length
/// or a structural verdict (incomplete / malformed / too_large). This is the
/// stream-framing entry point: the active codec's own decoder finds the frame
/// boundary as it decodes, so there is no separate boundary scanner to disagree
/// with the decode. `max_frame_bytes` caps an accepted frame. `codec` is the
/// session's negotiated codec, so it is always registered.
pub fn decodePrefix(codec: model.CodecId, bytes: []const u8, max_frame_bytes: usize) Prefix {
    return decodePrefixWith(registry.active, codec, bytes, max_frame_bytes);
}

pub fn decodePrefixWith(
    comptime specs: []const Spec,
    codec: model.CodecId,
    bytes: []const u8,
    max_frame_bytes: usize,
) Prefix {
    inline for (specs) |spec| {
        if (codec == spec.id) return spec.module.decodePrefix(bytes, max_frame_bytes);
    }
    // `model.CodecId` is non-exhaustive (ADR-0026, open registry), so an
    // unregistered id is a representable input — a consumer that names a codec it
    // never registered. Fail closed like the sibling decoders rather than reach
    // an `unreachable`: an unknown codec cannot frame, so its bytes are malformed.
    return .malformed;
}

/// The wire frame shape `codec` produces and consumes: Syrup is a byte stream,
/// Cap'n Proto is word-aligned. A byte-stream framer needs this to materialize
/// the owned frame it retains from a decoded prefix. Returns `null` for an
/// unregistered codec — the same open-set input `decodeBody` rejects with
/// `UnknownCodec` — so a caller resolves the shape and a missing codec in one step.
pub fn frameShape(codec: model.CodecId) ?foundation.FrameShape {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.frame_shape;
    }
    return null;
}

/// Encode `message` for `codec` under `profile`. The error set is the union of
/// the registered codecs' named `EncodeError` sets plus `UnknownCodec`.
pub fn encodeMessageForProfile(
    codec: model.CodecId,
    allocator: std.mem.Allocator,
    profile: model.WireProfile,
    message: model.Message,
) !foundation.Frame {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.encodeMessageForProfile(allocator, profile, message);
    }
    return error.UnknownCodec;
}
