//! Where pancake meets a real byte stream.
//!
//! The protocol core (foundation, model, codec, session, engine) is synchronous
//! and does no I/O. This layer is where a host's `std.Io` drives an `engine.Peer`
//! over a live stream. `Connection` reads inbound bytes, lets the codec find frame
//! boundaries as it goes, and streams the peer's outbound frames back. It is not
//! part of the core, and it is the only layer allowed to touch `std.Io`.
//!
//! ## Bring your own transport (ADR-0030)
//!
//! A stream transport gives pancake a `*std.Io.Reader` and `*std.Io.Writer`.
//! `pumpOver` uses that pair for one peer step. `readFrameFrom` and
//! `writeFrameTo` use it for raw whole-frame I/O. Any transport that can provide
//! those interfaces can drive a peer here: TCP, TLS or Unix streams over `std.Io`,
//! or an in-memory pipe. `tcp` is the built-in TCP binding. It is the first
//! resident, not a requirement.
//!
//! A transport that is not a blocking `std.Io` stream, such as a callback or
//! datagram API, can drive the peer directly through
//! `engine.Peer.recvStreamPrefix` and `takeOutbound`. That is also how a language
//! binding runs a peer over its own async sockets through the C ABI's
//! `pancake_peer_recv_stream`.
//!
//! ## High-fan-out completion loop
//!
//! `completion` is a portable, direction-neutral `Loop` that multiplexes many
//! connections on one thread. It drives the same peer stream-input and
//! outbound-frame APIs from completion events and touches no `std.Io`. It is
//! generic over a platform backend: `uring` is the Linux io_uring backend, and
//! `kqueue` is the macOS/BSD backend. A Windows IOCP backend is not implemented.
//! `Loop` is the portable loop already bound to the host platform's backend.

const connection = @import("connection.zig");
const frame_stream = @import("frame_stream.zig");

pub const Connection = connection.Connection;
pub const Progress = connection.Progress;
pub const PumpError = connection.PumpError;
pub const pumpOver = connection.pumpOver;

pub const FrameStream = frame_stream.FrameStream;
pub const FrameError = frame_stream.FrameError;
pub const Spill = frame_stream.Spill;
pub const readFrameFrom = frame_stream.readFrameFrom;
pub const writeFrameTo = frame_stream.writeFrameTo;

pub const tcp = @import("tcp.zig");

/// The in-process netlayer (`inproc`): a second resident behind the same
/// contract, with no sockets. It proves the contract is transport-general rather
/// than socket-shaped, and gives tests a full OCapN conversation in one process.
/// See `inproc`.
pub const inproc = @import("inproc.zig");

/// The netlayer contract the driver dials and hosts against. `tcp` and
/// `inproc` are its first two residents. A transport is registered, never
/// privileged, so adding one touches no driver or core code.
pub const netlayer = @import("netlayer.zig");
pub const Netlayer = netlayer.Netlayer;
pub const NetlayerRegistry = netlayer.NetlayerRegistry;
pub const ListenConfig = netlayer.ListenConfig;
pub const Buffers = netlayer.Buffers;
pub const DialError = netlayer.DialError;
pub const ListenError = netlayer.ListenError;
pub const AcceptError = netlayer.AcceptError;
/// The pluggable listener the netlayer contract yields (`accept` into a peer).
/// The concrete bound TCP socket is `net_adapter.tcp.Listener`.
pub const Listener = netlayer.Listener;

/// The portable completion-loop server, generic over its platform backend. The
/// connection orchestration is OS-neutral; the platform completion primitive is a
/// `Backend` it is parameterized over.
pub const completion = @import("completion.zig");

/// The io_uring completion backend (Linux). Empty off Linux so other builds stay
/// clean; it implements the `completion` backend interface.
pub const uring = if (@import("builtin").os.tag == .linux) @import("uring.zig") else struct {};

/// The kqueue completion backend (macOS / BSD). Empty off Darwin. It implements
/// the same `completion` backend interface, bridging kqueue's readiness model to
/// the completion-shaped backend interface. A Windows (IOCP) backend is not
/// implemented.
pub const kqueue = if (@import("builtin").os.tag.isDarwin()) @import("kqueue.zig") else struct {};

/// The ready-to-use completion loop for the host platform: the portable
/// `completion.Loop` instantiated with this platform's backend. Linux uses
/// io_uring, macOS/BSD use kqueue; on any other platform this is an empty
/// struct — no completion backend is implemented there.
pub const Loop = if (@import("builtin").os.tag == .linux)
    completion.Loop(uring.Backend)
else if (@import("builtin").os.tag.isDarwin())
    completion.Loop(kqueue.Backend)
else
    struct {};
