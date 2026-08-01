//! The verdict a codec gives back when it tries to frame a byte stream.
//!
//! A CapTP transport is just a stream of self-delimiting frames. The netlayer
//! never adds a length prefix of its own; the codec's grammar is what marks where
//! a frame ends. So to pull a frame off the front of a read buffer, we run the
//! active codec's decoder over it, and it answers with one of these verdicts.
//!
//! The same code that decodes the body is the code that says where the frame
//! ends, so the two can't disagree and let trailing bytes slip past validation.
//! A resumable scan does run ahead of the decoder (`StreamScan` below), but it
//! answers only whether a whole frame could be there yet and never names where
//! one ends, so there is still exactly one source of that verdict. A stream
//! consumer reaches both through `codec.dispatch.framePrefix`, which is the
//! only framing entry point it needs.

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

/// At or below this many pending bytes `dispatch.framePrefix` decodes on every
/// ask instead of consulting the scan.
///
/// The scan answers "can a whole frame be here yet", which a balance walk can
/// tell; it cannot tell whether the bytes inside a record are well formed,
/// because that is the decoder's job. So withholding the decoder also delays
/// the refusal of a malformed frame until the walk reaches the cap. Under this
/// bound the re-walk is too small to matter and prompt refusal is worth more;
/// above it the quadratic is what matters and the refusal waits. A frame the
/// scan withholds is still bounded by the incomplete-at-cap rule.
pub const scan_threshold_bytes: usize = 4096;

/// How far a codec has got deciding whether the front of a growing buffer
/// holds a whole frame yet.
///
/// A stream consumer appends bytes and asks again, and without this it asks by
/// re-running the decoder from byte zero every time. For a self-delimiting
/// grammar that costs a walk of everything received so far, so a frame arriving
/// in N chunks is walked N times: work quadratic in the frame size, over a
/// chunk size the sender picks. Carrying the scan's position across the retries
/// makes it linear instead.
///
/// `scanStream` answers `need_more` when the codec has consumed every byte
/// available and the frame is still open, which no continuation of the decoder
/// could have framed either; anything else, including bytes it cannot classify,
/// answers `ready` and the decoder speaks as it always has. So the decoder
/// remains the only authority on what a frame is: the verdict here cannot name
/// a length, so a wrong scan can cost a wasted decode and nothing else.
///
/// It does not follow that withholding is free. A withheld decode withholds the
/// decoder's own `too_large` refusal with it, so whoever withholds owes the
/// frame cap in its place; `dispatch.framePrefix` is where that is paid, which
/// is why a consumer calls that rather than this.
///
/// One scan tracks one frame. Reset it whenever the *front* of the prefix it
/// reads moves, which is when a frame is consumed. Moving the pending bytes to
/// different storage does not move that front, so a reader that spills a
/// partial frame into its own buffer keeps the cursor: what the scan holds is
/// how far into this frame it walked, not where the bytes live.
pub const StreamScan = struct {
    /// Where to resume, always a position between elements, never inside one.
    cursor: usize = 0,
    /// Open containers at `cursor`; zero before the frame's first byte. A
    /// `u32` because this rides in every connection's slot and the codecs cap
    /// decode nesting orders of magnitude below that; a frame deep enough to
    /// overflow it cannot be decoded anyway.
    depth: u32 = 0,
    /// Set once the scan has handed the question to the decoder for good.
    settled: bool = false,

    pub const Verdict = enum {
        /// Every available byte is consumed and the frame is still open, so
        /// there is nothing for the decoder to find. Skip it.
        need_more,
        /// Ask the decoder.
        ready,
    };

    pub fn reset(self: *StreamScan) void {
        self.* = .{};
    }

    /// Hand the question to the decoder, now and for every later ask about
    /// this frame.
    /// Codec implementors only: a stream consumer touches nothing here but
    /// `reset`, and reaches even that through `dispatch.framePrefix`.
    pub fn settle(self: *StreamScan) Verdict {
        self.settled = true;
        return .ready;
    }

    /// Remember a between-elements position to resume from.
    pub fn park(self: *StreamScan, cursor: usize, depth: u32) Verdict {
        self.cursor = cursor;
        self.depth = depth;
        return .need_more;
    }
};
