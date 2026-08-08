//! Sending each frame to the codec its session negotiated.
//!
//! The codec is chosen once per direct session, and the session remembers which
//! one as a `model.CodecId`. This boundary resolves that id against
//! `codec.registry` — at `comptime`, so the lookup unrolls to the same jump
//! table a hand-written switch would, with no runtime indirection — and that's
//! what lets the engine stay codec-neutral for the bytes it puts on the wire.
//! Whichever codec runs, decode hands back the same `model.view.Body` and
//! encode hands back an equivalent `Frame`, so the state machine above never
//! has to care which codec is underneath.
//!
//! One class of bytes deliberately does not come through here: the ones a
//! signature is defined over. Those are Syrup whatever the session negotiated,
//! because a give signed on one session is verified on another that negotiated
//! independently. They live behind `codec.signed`, which states that reason,
//! and `arch-check` refuses a codec named by name anywhere else above the
//! codec layer.
//!
//! The `*With` variants take an explicit registry so a test (or a consumer) can
//! drive dispatch over a custom codec set; the public functions use
//! `registry.active`, the built-ins plus whatever the root file added.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");

const framing = @import("framing");
pub const Prefix = framing.Prefix;
pub const Boundary = framing.Boundary;
const registry = @import("registry.zig");
const Spec = registry.Spec;

/// Union of every registered codec's decode/encode error set, plus
/// `UnknownCodec`. The engine folds this into its `DecodeError` alongside the
/// lazy-projection `model.view.ProjectError`.
pub const Error = registry.Error;

/// Project the borrowed codec-neutral body from `frame` using `codec`.
pub fn decodeBody(codec: model.CodecId, frame: foundation.FrameView) Error!model.view.Body {
    return decodeBodyWith(registry.active, codec, frame);
}

pub fn decodeBodyForProfile(
    codec: model.CodecId,
    profile: model.CaptpVersion,
    frame: foundation.FrameView,
) Error!model.view.Body {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.decodeBodyForProfile(profile, frame);
    }
    return error.UnknownCodec;
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
/// boundary as it decodes, so nothing else gets to disagree with it about where
/// a frame ends. `scanStream` below is a filter in front of this, not a second
/// opinion: it only withholds the question while no whole frame can be there
/// yet. `max_frame_bytes` caps an accepted frame. `codec` is the
/// session's negotiated codec, so it is always registered.
pub fn decodePrefix(codec: model.CodecId, bytes: []const u8, max_frame_bytes: usize) Prefix {
    return decodePrefixWith(registry.active, codec, bytes, max_frame_bytes);
}

pub fn decodePrefixForProfile(
    codec: model.CodecId,
    profile: model.CaptpVersion,
    bytes: []const u8,
    max_frame_bytes: usize,
) Prefix {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.decodePrefixForProfile(profile, bytes, max_frame_bytes);
    }
    return .malformed;
}

/// Frame the front of a growing stream buffer without projecting a semantic
/// body: the one entry point a peer-less byte-stream consumer calls.
///
/// A consumer appends bytes and asks again. Asking `decodePrefix` every time
/// re-walks the frame from its first byte on every read, which is work
/// quadratic in the frame's size over a chunk size the sender picks, so a
/// resumable scan runs ahead of the decoder and carries its position in
/// `scan`. Three obligations come with that, and every one of them lives here
/// rather than in each caller:
///
/// - Withholding the decoder withholds the decoder's own `too_large` refusal
///   along with it. A prefix that has reached the cap can never complete
///   within it, so the refusal is restated here. Without it a partner opens a
///   record, never closes it, and grows the consumer's buffer without end.
/// - Below `scan_threshold_bytes` the re-walk is too small to be worth
///   delaying a malformed frame's refusal for, so the scan is skipped.
/// - Once a frame is complete the front of the buffer moves, so the scan's
///   position is void and it is reset.
///
/// `scan` is per stream, not per buffer: successive calls must describe the
/// same stream front. The buffer may grow or move storage — a partial frame
/// spilling into its own storage keeps the cursor, because what the scan holds
/// is how far into this frame it walked, not where the bytes live. A consumer
/// that re-points at a different stream calls `scan.reset()` first.
pub fn framePrefix(
    codec: model.CodecId,
    bytes: []const u8,
    scan: *framing.StreamScan,
    max_frame_bytes: usize,
) Boundary {
    if (bytes.len > framing.scan_threshold_bytes and
        scanStream(codec, bytes, scan, max_frame_bytes) == .need_more)
    {
        return if (bytes.len >= max_frame_bytes) .too_large else .incomplete;
    }
    const prefix = framePrefixWith(registry.active, codec, bytes, max_frame_bytes);
    if (prefix == .complete) scan.reset();
    // A codec refuses a prefix *longer* than the cap, which leaves the prefix
    // that is exactly the cap and still open. It cannot complete within the cap
    // either, so it is refused here rather than read past. Consumers used to
    // carry this as a second, wider mirror of their own, which is how the two
    // engine entry points came to differ by a single byte.
    if (prefix == .incomplete and bytes.len >= max_frame_bytes) return .too_large;
    return prefix;
}

pub fn framePrefixWith(
    comptime specs: []const Spec,
    codec: model.CodecId,
    bytes: []const u8,
    max_frame_bytes: usize,
) Boundary {
    inline for (specs) |spec| {
        if (codec == spec.id) return spec.module.framePrefix(bytes, max_frame_bytes);
    }
    return .malformed;
}

pub fn framePrefixForProfile(
    codec: model.CodecId,
    profile: model.CaptpVersion,
    bytes: []const u8,
    scan: *framing.StreamScan,
    max_frame_bytes: usize,
) Prefix {
    if (bytes.len > framing.scan_threshold_bytes and
        scanStream(codec, bytes, scan, max_frame_bytes) == .need_more)
    {
        return if (bytes.len >= max_frame_bytes) .too_large else .incomplete;
    }
    const prefix = decodePrefixForProfile(codec, profile, bytes, max_frame_bytes);
    if (prefix == .decoded) scan.reset();
    if (prefix == .incomplete and bytes.len >= max_frame_bytes) return .too_large;
    return prefix;
}

/// Whether it is worth asking `decodePrefix` yet, for a codec that can answer
/// more cheaply than by decoding. `framePrefix` above is what a stream consumer
/// calls; this is the step it runs first, public for the codec tests that drive
/// the scan directly. A codec that declares its frame length up
/// front already answers in constant time and says `ready` always; one with a
/// self-delimiting grammar carries `scan` across the retries so a frame
/// arriving in pieces is walked once rather than once per piece.
pub fn scanStream(
    codec: model.CodecId,
    bytes: []const u8,
    scan: *framing.StreamScan,
    max_frame_bytes: usize,
) framing.StreamScan.Verdict {
    return scanStreamWith(registry.active, codec, bytes, scan, max_frame_bytes);
}

pub fn scanStreamWith(
    comptime specs: []const Spec,
    codec: model.CodecId,
    bytes: []const u8,
    scan: *framing.StreamScan,
    max_frame_bytes: usize,
) framing.StreamScan.Verdict {
    inline for (specs) |spec| {
        if (codec == spec.id) {
            if (!@hasDecl(spec.module, "scanStream")) return .ready;
            return spec.module.scanStream(bytes, scan, max_frame_bytes);
        }
    }
    // An unregistered codec cannot frame; let `framePrefix` say so.
    return .ready;
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
    // unregistered id is a representable input, a consumer that names a codec it
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
    profile: model.CaptpVersion,
    message: model.Message,
) !foundation.Frame {
    inline for (registry.active) |spec| {
        if (codec == spec.id) return spec.module.encodeMessageForProfile(allocator, profile, message);
    }
    return error.UnknownCodec;
}
