//! Where pancake meets a real byte stream.
//!
//! The protocol core (foundation, model, codec, session, engine) is synchronous
//! and does no I/O. This layer is the seam where a host's `std.Io` actually drives
//! a `engine.Peer` over a live stream: `Connection` reads inbound bytes, lets the
//! codec find frame boundaries as it goes, and streams the peer's outbound frames
//! back. It isn't part of the core, and it's the one and only layer allowed to
//! touch `std.Io`.
//!
//! ## Bring your own transport (ADR-0030)
//!
//! The transport seam is a `*std.Io.Reader` / `*std.Io.Writer` pair — nothing
//! more. [`pumpOver`] (one step) and [`readFrameFrom`] / [`writeFrameTo`] (raw
//! whole-frame I/O) take that pair directly, so *any* transport that yields a
//! reader/writer — TCP, TLS or unix over `std.Io`, an in-memory pipe — drives a
//! peer with no change here. [`tcp`] is the built-in TCP binding (`Connection`
//! welds the pair to a socket); it is the example, not the requirement. A
//! transport that is not a blocking `std.Io` stream (a callback or datagram API)
//! drives the peer directly through `engine.Peer.recvStreamPrefix` /
//! `takeOutbound` — which is exactly how a language binding runs a peer over its
//! own async sockets via the C ABI's `pancake_peer_recv_stream`.

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
