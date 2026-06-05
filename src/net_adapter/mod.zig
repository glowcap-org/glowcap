//! Byte-stream network adapter — the `std.Io`-bound layer above the no-I/O core.
//!
//! pancake's protocol core (`foundation` / `model` / `codec` / `session` /
//! `runtime`) is sync and owns no I/O. This layer is the seam where a host's
//! `std.Io` capability drives a `runtime.Peer` over a real byte stream:
//! [`Connection`] folds inbound bytes into frames (one-parser framing) and
//! streams the peer's outbound frames back. It is **not** a core layer; it is
//! the only layer permitted to touch `std.Io`.

const connection = @import("connection.zig");
const frame_stream = @import("frame_stream.zig");

pub const Connection = connection.Connection;
pub const Progress = connection.Progress;
pub const PumpError = connection.PumpError;
pub const pumpOver = connection.pumpOver;

pub const FrameStream = frame_stream.FrameStream;
pub const FrameError = frame_stream.FrameError;
pub const readFrameFrom = frame_stream.readFrameFrom;
pub const writeFrameTo = frame_stream.writeFrameTo;
pub const fillStep = frame_stream.fillStep;

pub const tcp = @import("tcp.zig");
pub const Listener = tcp.Listener;
