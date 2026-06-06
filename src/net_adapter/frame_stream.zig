//! Moving whole frames over a `std.Io` byte stream, without a peer involved.
//!
//! A `Connection` reads frames straight into a `engine.Peer` and applies them.
//! A `FrameStream` sits one level lower: read one whole frame off the wire as an
//! owned `Frame`, or write one, and that's it. It's what the host-driven C ABI
//! endpoint is built on. There, the C host owns the peer and runs the loop itself
//! (read a frame, feed it, step, take the outbound, write it), so all this layer
//! does is frame the inbound bytes. It applies no authority of its own.
//!
//! The framing is still the one parser: the active codec's decoder marks where a
//! frame ends (`codec.dispatch.decodePrefix`). And the edge cases the codec can't
//! decide on its own, a clean EOF versus one in the middle of a frame, or a buffer
//! that fills up without holding a whole frame, are all settled in a single place
//! (`fillStep`), which the `Connection` pump shares too so the two can't drift
//! apart.
//!
//! The frame operations themselves are free functions over a type-erased reader
//! and writer (`readFrameFrom` / `writeFrameTo`), so we test them with
//! `Reader.fixed` and `Writer.fixed` across both codecs without a socket.
//! `FrameStream` is just the thin socket-backed binding on top.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const codec = @import("../codec/mod.zig");
const engine = @import("../engine/mod.zig");

const net = std.Io.net;

/// Outcome of reading one frame off the stream. A malformed / oversize frame is
/// a transport-fatal condition here (there is no session to project an abort
/// onto — that is the host peer's job once the frame is fed in); the concrete
/// `ReadFailed` cause is preserved on the stream reader.
pub const FrameError = error{
    /// Clean EOF on a frame boundary — the peer closed gracefully.
    Closed,
    /// EOF arrived mid-frame.
    TruncatedFrame,
    /// The bytes are not a structurally valid frame.
    MalformedFrame,
    /// A frame would exceed `max_frame_bytes` (cap-on-parse or buffer-full).
    FrameTooLarge,
    /// The underlying read or write failed.
    ConnectionLost,
} || std.mem.Allocator.Error;

/// The stream-edge conditions a single blocking read can hit, independent of the
/// codec's verdict over the bytes it produces. Shared by [`readFrameFrom`] and
/// the `Connection` pump.
pub const FillError = error{ TruncatedFrame, FrameTooLarge, ConnectionLost };

pub const Fill = enum { filled, closed };

/// One blocking read into `r`, deciding only the conditions the codec does not:
/// a full buffer that still holds no frame cannot fit one (`FrameTooLarge`); a
/// clean EOF on a frame boundary is `.closed`; an EOF with bytes still buffered
/// is a mid-frame truncation; a read fault is `ConnectionLost`. The codec
/// verdict over `r.buffered()` is the caller's — this owns only the byte-supply
/// edge, so frame-boundary truth lives in one parser and stream-edge truth lives
/// in one function.
pub fn fillStep(r: *std.Io.Reader) FillError!Fill {
    // A full read buffer that has not yielded a frame cannot fit one within the
    // cap — fail loud before `fillMore` would have to over-read (and before its
    // rebase would assert).
    if (r.buffer.len > 0 and r.bufferedLen() == r.buffer.len) return error.FrameTooLarge;

    r.fillMore() catch |err| switch (err) {
        error.EndOfStream => return if (r.bufferedLen() == 0) .closed else error.TruncatedFrame,
        error.ReadFailed => return error.ConnectionLost,
    };
    return .filled;
}

/// Block until one whole `codec_id` frame is available on `r`, returning it as an
/// owned `Frame` (a shape-correct copy lifted out of the read buffer, so the
/// buffer is free to advance). `Closed` is returned on a graceful boundary EOF.
pub fn readFrameFrom(
    r: *std.Io.Reader,
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
) FrameError!foundation.Frame {
    while (true) {
        if (r.bufferedLen() > 0) {
            switch (codec.dispatch.decodePrefix(codec_id, r.buffered(), max_frame_bytes)) {
                .decoded => |decoded| {
                    const view: foundation.FrameView = .{
                        .bytes = r.buffered()[0..decoded.consumed],
                        .shape = codec.dispatch.frameShape(codec_id),
                    };
                    // The one shape-aware owned copy (8-aligned for `word`).
                    const frame = engine.ownedFrameFromView(allocator, view) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // decodePrefix already accepted the frame, so a shape
                        // violation cannot occur; classify defensively.
                        error.InvalidFrameShape => return error.MalformedFrame,
                    };
                    r.toss(decoded.consumed);
                    return frame;
                },
                .incomplete => {},
                .malformed => return error.MalformedFrame,
                .too_large => return error.FrameTooLarge,
            }
        }

        switch (try fillStep(r)) {
            .filled => {},
            .closed => return error.Closed,
        }
    }
}

/// Write one frame's bytes and flush. `bytes` are borrowed for the call.
pub fn writeFrameTo(w: *std.Io.Writer, bytes: []const u8) FrameError!void {
    w.writeAll(bytes) catch return error.ConnectionLost;
    w.flush() catch return error.ConnectionLost;
}

/// The thin socket-backed binding of the frame operations above: a stream's
/// reader/writer plus the codec that delimits its frames.
pub const FrameStream = struct {
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    io: std.Io,
    /// The codec whose grammar delimits frames on this stream.
    codec_id: model.CodecId,
    /// Cap on an accepted frame. Slice-1 sizes the read buffer to this, so any
    /// admissible frame fits whole; a smaller read buffer would surface an
    /// admissible-but-larger-than-buffer frame as `FrameTooLarge`.
    max_frame_bytes: usize,

    pub fn initStream(
        io: std.Io,
        stream: net.Stream,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) FrameStream {
        return .{
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .io = io,
            .codec_id = codec_id,
            .max_frame_bytes = max_frame_bytes,
        };
    }

    pub fn deinit(self: *FrameStream) void {
        self.reader.stream.close(self.io);
    }

    /// Block for one whole frame as an owned `Frame`; `Closed` on graceful EOF.
    pub fn readFrame(self: *FrameStream, allocator: std.mem.Allocator) FrameError!foundation.Frame {
        return readFrameFrom(&self.reader.interface, allocator, self.codec_id, self.max_frame_bytes);
    }

    /// Write one frame's borrowed bytes and flush.
    pub fn writeFrame(self: *FrameStream, bytes: []const u8) FrameError!void {
        return writeFrameTo(&self.writer.interface, bytes);
    }

    /// The concrete read failure behind the last `ConnectionLost`, if any. The C
    /// boundary surfaces this via `pancake_last_error`.
    pub fn lastReadError(self: *const FrameStream) ?net.Stream.Reader.Error {
        return self.reader.err;
    }

    pub fn lastWriteError(self: *const FrameStream) ?net.Stream.Writer.Error {
        return self.writer.err;
    }
};
