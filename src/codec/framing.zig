//! Stream-framing result shared by the codecs and their dispatch seam.
//!
//! A CapTP transport carries a stream of self-delimiting frames; the netlayer
//! never length-prefixes them at the transport (Invariant: the codec's own
//! grammar owns the frame boundary). To frame the stream, the active codec's
//! decoder is run over the front of a read buffer and reports one of these
//! verdicts. There is deliberately no separate boundary scanner — the decoder
//! that produces the body is the same code that reports where the frame ends,
//! so the two can never disagree and smuggle trailing bytes past validation.

const model = @import("../model/mod.zig");

/// Verdict of decoding the front of a byte buffer as one frame.
pub const Prefix = union(enum) {
    /// A complete frame was decoded; `body` borrows from the input buffer and
    /// `consumed` bytes form the frame (the caller advances past them).
    decoded: Decoded,
    /// The buffer ends inside a frame. Read more bytes and retry; the same
    /// bytes plus a continuation may complete it.
    incomplete,
    /// The bytes are structurally invalid as a frame and no continuation can
    /// fix them. The caller fails the connection closed.
    malformed,
    /// A frame decoded but exceeds the negotiated `max_frame_bytes` cap. The
    /// caller fails the connection closed (resource bound, ADR).
    too_large,

    pub const Decoded = struct {
        body: model.view.Body,
        consumed: usize,
    };
};
