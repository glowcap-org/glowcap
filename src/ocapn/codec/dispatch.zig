//! Sending each frame to the codec its session negotiated.
//!
//! The codec is chosen once per direct session, and the session remembers which
//! one as a `model.CodecId`. This boundary resolves that id against
//! `codec.registry`, at `comptime`, so the lookup unrolls to the same jump
//! table a hand-written switch would, with no runtime indirection, and that's
//! what lets the engine stay codec-neutral for the bytes it puts on the wire.
//! Whichever codec runs, decode hands back the same `model.view.Body` and
//! encode hands back an equivalent `Frame`, so the state machine above never
//! has to care which codec is underneath.
//!
//! One class of bytes does not come through here: the ones a
//! signature is defined over. Those are Syrup whatever the session negotiated,
//! because a give signed on one session is verified on another that negotiated
//! independently. They live behind `codec.signed`, which states that reason,
//! and `arch-check` refuses a codec named by name anywhere else above the
//! codec layer.
//!
//! The `*With` variants take an explicit registry so a test (or a consumer) can
//! drive dispatch over a custom codec set. The public functions use
//! `registry.active`, the built-ins plus whatever the root file added.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

const registry = @import("registry.zig");
const Spec = registry.Spec;

/// Union of every registered codec's decode/encode error set, plus
/// `UnknownCodec`. The engine folds this into its `DecodeError` alongside the
/// lazy-projection `model.view.ProjectError`.
pub const Error = registry.Error;
pub const EncodeError = registry.EncodeError;

/// Project the borrowed codec-neutral body from `frame` using `codec`.
pub fn decodeBody(codec: model.CodecId, frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyWith(registry.active, codec, frame);
}

pub fn decodeBodyForProfile(
    codec: model.CodecId,
    profile: model.CaptpVersion,
    frame: foundation.FrameView,
) Error!model.view.Body {
    var slab = model.view.ValueSlab.empty;
    var body: model.view.Body = undefined;
    try decodeBodyInto(codec, profile, frame, &slab, &body);
    return body;
}

/// `decodeBodyForProfile` writing the body into `body`, with `slab` lent
/// for the message's top-level argument list, so a codec that parses ahead
/// to find a list's end keeps what it parsed (ADR-0222) and the body is
/// written once, where it will live. The views in `slab` borrow `frame`.
/// On a refusal `body` is undefined.
pub fn decodeBodyInto(
    codec: model.CodecId,
    profile: model.CaptpVersion,
    frame: foundation.FrameView,
    slab: *model.view.ValueSlab,
    body: *model.view.Body,
) Error!void {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.decodeBodyInto(profile, frame, slab, body);
    }
    return error.UnknownCodec;
}

pub fn decodeBodyWith(
    comptime specs: []const Spec,
    codec: model.CodecId,
    frame: foundation.FrameView,
) registry.unionErrors(specs)!model.view.Body {
    var slab = model.view.ValueSlab.empty;
    var body: model.view.Body = undefined;
    inline for (specs) |spec| {
        if (codec == spec.id) {
            try spec.module.decodeBodyInto(.v1_0, frame, &slab, &body);
            return body;
        }
    }
    return error.UnknownCodec;
}

/// The wire frame shape `codec` produces and consumes: Syrup is a byte stream,
/// Cap'n Proto is word-aligned. A byte-stream framer needs this to materialize
/// the owned frame it retains from a decoded prefix. Returns `null` for an
/// unregistered codec, the same open-set input `decodeBody` rejects with
/// `UnknownCodec`, so a caller resolves the shape and a missing codec in one step.
pub fn frameShape(codec: model.CodecId) ?foundation.FrameShape {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.frame_shape;
    }
    return null;
}

/// Encode `message` for `codec` under `profile`.
pub fn encodeMessageForProfile(
    codec: model.CodecId,
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    message: model.Message,
) EncodeError!foundation.Frame {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.encodeMessageForProfile(allocator, profile, message);
    }
    return error.UnknownCodec;
}

/// Encode a borrowed `body` for `codec` under `profile`. The body is read
/// where it lies, whichever codec or owner backs it.
/// `values` is what the body's value tree encodes to when the caller walked
/// it with the codec's `meter`, or null for a codec that declares none.
pub fn encodeBodyForProfile(
    codec: model.CodecId,
    allocator: std.mem.Allocator,
    profile: model.CaptpVersion,
    body: *const model.view.Body,
    values: ?usize,
) EncodeError!foundation.Frame {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.encodeBodyForProfile(allocator, profile, body, values);
    }
    return error.UnknownCodec;
}
