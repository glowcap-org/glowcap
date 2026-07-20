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
//! `pumpOver` uses that pair for one peer step, and the `FrameStream` family
//! reads and writes raw whole frames over it. Any transport that can provide
//! those interfaces can drive a peer here: TCP, TLS or Unix streams over `std.Io`,
//! or an in-memory pipe. The residents live under `transport/`: `tcp` is the
//! built-in TCP binding, the first resident, not a requirement.
//!
//! A transport that is not a blocking `std.Io` stream, such as a callback or
//! datagram API, can drive the peer directly through
//! `engine.Peer.recvStreamPrefix` and `takeOutbound`. That is also how a language
//! binding runs a peer over its own async sockets through the C ABI's
//! `pancake_peer_recv_stream`.
//!
//! ## High-fan-out completion loop
//!
//! The `completion/` directory is a portable, direction-neutral `Loop` that
//! multiplexes many connections on one thread. It drives the same peer
//! stream-input and outbound-frame APIs from completion events and touches no
//! `std.Io`. It is generic over a platform backend: `completion/uring.zig` is the
//! Linux io_uring backend, and `completion/kqueue.zig` is the macOS/BSD backend.
//! A Windows IOCP backend is not implemented. `TcpLoop` is the portable loop
//! already bound to the host platform Backend plus `tcp.DialResolver`.

const connection = @import("connection.zig");
const frame_stream = @import("frame_stream.zig");
const loop_mod = @import("completion/loop.zig");

pub const Connection = connection.Connection;
pub const Progress = connection.Progress;
pub const pumpOver = connection.pumpOver;

pub const FrameStream = frame_stream.FrameStream;
pub const Spill = frame_stream.Spill;
pub const readFrameFrom = frame_stream.readFrameFrom;

/// The one monotonic elapsed-time source for every adapter deadline. See
/// `clock.zig`.
pub const clock = @import("clock.zig");

pub const tcp = @import("transport/tcp.zig");

/// The socket library: raw OS socket + stream plumbing beneath a netlayer,
/// gathered behind one name so a resident never reaches into `completion/` or a
/// sibling for it. See `socket.zig`.
pub const socket = @import("socket.zig");

/// Opt-in TCP keepalive (idle/interval/count). One public door: the socket
/// library. NAT hold-open / dead-remote-host reclaim — not orphan-process
/// reaping. See `socket.Keepalive`.
pub const Keepalive = socket.Keepalive;
/// Apply keepalive sockopts. Prefer `socket.applyKeepalive`; this name matches
/// older call sites without opening a second path into `completion/`.
pub const tcp_keepalive = struct {
    pub const apply = socket.applyKeepalive;
};

/// The keyed TCP netlayer (`keyed-tcp`): the same TCP sockets under a durable,
/// key-derived designator — the listener's Ed25519 public key in canonical
/// hex, with the socket address riding the `direct-addresses` hint — so a
/// partner re-dials the same designator across a process restart and the
/// driver pins the handshake to the dialed key (ADR-0075). See
/// `transport/tcp_keyed.zig`.
pub const tcp_keyed = @import("transport/tcp_keyed.zig");

/// The in-process netlayer (`inproc`): a second resident behind the same
/// contract, with no sockets. It proves the contract is transport-general rather
/// than socket-shaped, and gives tests a full OCapN conversation in one process.
/// See `transport/inproc.zig`.
pub const inproc = @import("transport/inproc.zig");

/// Shared `std.Io` Reader/Writer scaffolding for byte-source residents
/// (inproc, iroh). Pub because the out-of-graph iroh resident is its own
/// module root under `transport/` and cannot `@import("../stream_shim.zig")`
/// — that path sits outside its module directory (ADR-0040).
pub const stream_shim = @import("stream_shim.zig");

/// The netlayer contract the driver dials and hosts against, as its own named
/// namespace: `net.netlayer.Netlayer` is a transport behind a runtime vtable, a
/// `[]const Netlayer` is the set a host speaks, and `net.netlayer.resolve`
/// dispatches a transport symbol against that slice. `net.netlayer.Listener` is
/// the listener a netlayer yields. Residents include `tcp`, `keyed-tcp`,
/// `inproc`, and the sidecar `iroh` resident. A transport is one more element
/// in the slice, never privileged, so adding one touches no driver or core
/// code. The OCapN concept itself — the locator and its `transport` symbol —
/// lives in `model`; this is only its I/O realization.
pub const netlayer = @import("netlayer.zig");

/// The portable completion-loop server, generic over its platform backend. The
/// connection orchestration is OS-neutral; the platform completion primitive is a
/// `Backend` it is parameterized over. See `completion/loop.zig`.
pub const completion = loop_mod;

/// The io_uring completion backend (Linux). Empty off Linux so other builds stay
/// clean; it implements the `completion` backend interface and is reached
/// through `Loop` below.
const uring = if (@import("builtin").os.tag == .linux) @import("completion/uring.zig") else struct {};

/// The kqueue completion backend (macOS / BSD). Empty off Darwin. It implements
/// the same `completion` backend interface, bridging kqueue's readiness model to
/// the completion-shaped backend interface, and is reached through `Loop`
/// below. A Windows (IOCP) backend is not implemented.
const kqueue = if (@import("builtin").os.tag.isDarwin()) @import("completion/kqueue.zig") else struct {};

/// The ready-to-use TCP completion loop for the host platform: the portable
/// `completion.Loop` over the platform Backend plus `tcp.DialResolver` (OCapN
/// locator into `IpAddress`). Linux uses io_uring, macOS/BSD use kqueue; on any
/// other platform this is an empty struct. Named `TcpLoop` so it is not
/// confused with the generic `completion.Loop(Backend, Locator)`.
pub const TcpLoop = if (@import("builtin").os.tag == .linux)
    completion.Loop(uring.Backend, tcp.DialResolver)
else if (@import("builtin").os.tag.isDarwin())
    completion.Loop(kqueue.Backend, tcp.DialResolver)
else
    struct {};

/// The host platform's completion `Backend` (io_uring on Linux, kqueue on
/// macOS/BSD), the type `TcpLoop` is bound over. Exposed so an embedder that
/// needs a non-`tcp.DialResolver` locator grammar — a conformance transport
/// whose address lives in locator hints, say — can bind its own
/// `completion.Loop(net.Backend, CustomLocator)` without re-declaring the
/// per-OS backend selection. An empty struct off the supported platforms.
pub const Backend = if (@import("builtin").os.tag == .linux)
    uring.Backend
else if (@import("builtin").os.tag.isDarwin())
    kqueue.Backend
else
    struct {};
