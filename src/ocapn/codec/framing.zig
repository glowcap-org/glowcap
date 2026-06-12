//! The verdict a codec gives back when it tries to frame a byte stream.
//!
//! A CapTP transport is just a stream of self-delimiting frames. The netlayer
//! never adds a length prefix of its own; the codec's grammar is what marks where
//! a frame ends. So to pull a frame off the front of a read buffer, we run the
//! active codec's decoder over it, and it answers with one of these verdicts.
//!
//! There's deliberately no separate "find the boundary" scanner. The same code
//! that decodes the body is the code that says where the frame ends, so the two
//! can't disagree and let trailing bytes slip past validation.

const model = @import("model");

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
    /// caller fails the connection closed; ADR-0029 owns this cap-during-scan
    /// resource bound.
    too_large,

    pub const Decoded = struct {
        body: model.view.Body,
        consumed: usize,
    };
};
