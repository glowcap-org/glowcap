//! Where glowcap meets a real byte stream.
//!
//! The protocol core (foundation, model, codec, session, engine) is synchronous
//! and does no I/O. This layer is where a host's `std.Io` drives an `engine.Peer`
//! over a live stream. `Connection` unwraps the byte-stream envelope, applies each
//! body as one whole frame, and writes outbound frames through the same envelope.
//! It is not part of the core; `net` and the driver adapters own `std.Io`.
//!
//! ## Bring your own transport (ADR-0030)
//!
//! A stream transport gives glowcap a `*std.Io.Reader` and `*std.Io.Writer`.
//! `pumpOver` uses that pair for one peer step, and the `FrameStream` family
//! reads and writes one outer-framed codec frame at a time. Any transport that
//! can provide those interfaces can drive a peer here: TCP, TLS or Unix streams
//! over `std.Io`, or an in-memory pipe. The residents live under `transport/`.
//! `tcp` owns the native provider and its plain, keyed, and Noise profiles, not
//! a requirement of the protocol core.
//!
//! A transport that is not a blocking `std.Io` stream, such as a callback or
//! datagram API, can drive the peer directly through
//! `engine.Peer.recvStreamPrefix` and `takeOutbound`. That is also how a language
//! binding runs a Host session over its own async sockets through the byte-fed
//! C Host ABI.
//!
//! ## High-fan-out completion loop
//!
//! The `completion/` directory is a portable, direction-neutral `Loop` that
//! multiplexes many connections on one thread. It drives the same peer
//! stream-input and outbound-frame APIs from completion events and touches no
//! `std.Io`. It is generic over a platform backend: `completion/uring.zig` is the
//! Linux io_uring backend, and `completion/kqueue.zig` is the Darwin backend.
//! A Windows IOCP backend is not implemented. `TcpLoop` is the portable loop
//! already bound to the host platform Backend plus `tcp.DialResolver`.

const codec = @import("codec");
const connection = @import("connection.zig");
const frame_stream = @import("frame_stream.zig");
const loop_mod = @import("completion/loop.zig");

pub const Connection = connection.Connection;
pub const ConnectionCloseProgress = connection.CloseProgress;
pub const WaitInterest = connection.WaitInterest;
pub const Progress = connection.Progress;
pub const pumpOver = connection.pumpOver;
pub const waitAnyReadable = connection.waitAnyReadable;
pub const waitAny = connection.waitAny;
pub const classifyApplyError = connection.classifyApplyError;

pub const FrameStream = frame_stream.FrameStream;
/// Where stream bytes wait when they have arrived but do not yet make a whole
/// frame. Shared with the byte-fed host tier as `foundation.Spill`; at this tier
/// it is the bounded overflow behind a read buffer (ADR-0041).
pub const Spill = frame_stream.Spill;
/// What a drained spill keeps here: nothing. See `frame_stream.spill_retain_bytes`.
pub const spill_retain_bytes = frame_stream.spill_retain_bytes;
/// Fill a spill from a `std.Io.Reader`, the reader-shaped half of
/// `Spill.absorbBytes` that `foundation` cannot hold because it is core.
pub const absorbFrom = frame_stream.absorbFrom;
/// The resumable frame-boundary scan `readFrameFrom` carries between reads, so
/// a frame arriving in pieces is walked once rather than once per read.
pub const StreamScan = codec.framing.StreamScan;
pub const readFrameFrom = frame_stream.readFrameFrom;
pub const writeFrameTo = frame_stream.writeFrameTo;
pub const writeFrameBytes = frame_stream.writeFrameBytes;
pub const appendFrameBytes = frame_stream.appendFrameBytes;
pub const outerPrefix = frame_stream.outerPrefix;
pub const frameShape = codec.dispatch.frameShape;

/// The one monotonic elapsed-time source for every adapter deadline. See
/// `clock.zig`.
pub const clock = @import("clock.zig");

/// Shared `poll(2)` wrappers for blocking residents and readiness backends.
pub const poll = @import("poll.zig");

/// Transport-neutral TLS engine state and buffer-ownership contract. Concrete
/// engines live at the adapter edge; TCP remains a raw byte transport.
pub const tls = struct {
    pub const engine = @import("tls/engine.zig");
    pub const pollable_stream = @import("tls/pollable_stream.zig");
    pub const runtime = @import("tls/runtime.zig");
    pub const runtime_owner = @import("tls/runtime_owner.zig");
    pub const transform = @import("tls/transform.zig");
};

/// The native TCP transport provider and its `plain`, `keyed`, and `noise`
/// profiles. The namespace owns their shared socket realization and fixed
/// provider composition; drivers consume it without enumerating the profiles.
pub const tcp = @import("transport/tcp.zig");

/// The `onion` netlayer, the one transport symbol the OCapN draft standardizes:
/// the two headless byte helpers (SOCKS5 out, the Tor control protocol for
/// hosting), the streams that carry them, and the resident that dials and accepts
/// over the netlayer contract (ADR-0108). Reached through a Tor daemon the
/// deployment runs; glowcap starts none.
pub const onion = @import("transport/onion/mod.zig");

/// The socket library: raw OS socket + stream plumbing beneath a netlayer,
/// gathered behind one name so a resident never reaches into `completion/` or a
/// sibling for it. See `socket.zig`.
pub const socket = @import("socket.zig");

/// Short-critical-section spin-lock for adapter-level synchronization. The
/// sans-io core bans `std.atomic`; net and transport C-ABI adapters share this
/// home. See `sync.zig`.
pub const sync = @import("sync.zig");

/// The cross-thread wake channel: a nonblocking socketpair a waiting thread
/// polls (or arms a completion recv on) and any thread nudges. `WouldBlock` is
/// explicit coalesced success; every other write or drain fault is returned
/// and first-failure latched by owners under ADR-0089. The off-turn settle
/// mailbox rides it (ADR-0102). See `wake_channel.zig`.
pub const wake_channel = @import("wake_channel.zig");
pub const operation_owner = @import("operation_owner.zig");
pub const OperationOwner = operation_owner.OperationOwner;
pub const CancelableOperation = operation_owner.CancelableOperation;
pub const OperationLatch = operation_owner.OperationLatch;
pub const TransportOperationCompletion = @import("transport/operation_completion.zig").Completion;

/// Opt-in TCP keepalive (idle/interval/count). One public door: the socket
/// library. NAT hold-open / dead-remote-host reclaim — not orphan-process
/// reaping. See `socket.Keepalive`.
pub const Keepalive = socket.Keepalive;

/// The in-process netlayer (`inproc`): a second resident behind the same
/// contract, with no sockets. It proves the contract is transport-general rather
/// than socket-shaped, and gives tests a full OCapN conversation in one process.
/// See `transport/inproc.zig`.
pub const inproc = @import("transport/inproc.zig");

/// The relay provider and its `keyed-relay` and `noise-relay` profiles. One
/// configured package owns both realizations, including locator construction,
/// WebSocket rendezvous, registration, and readiness.
pub const relay = @import("transport/relay.zig");

/// Sans-I/O RFC 6455 client protocol machinery shared by relay transports.
/// Relay implementations import the leaf by relative path to avoid a
/// `net` -> `relay` -> `net` cycle; consumers reach it here.
pub const websocket = @import("websocket.zig");

/// The sealing completion-backend adapter (`noise-relay`, ADR-0107): wraps
/// any completion backend so a `.sealed` dial target completes the Noise_XK
/// handshake before the loop hears the connect completed, then seals sends
/// into records and lends opened record plaintext to the recv seat. The
/// loop-tier owner of the sealed channel, composing
/// `foundation.sealed.SealedChannel`. See `transport/noise_completion.zig`.
pub const noise_completion = @import("transport/noise_completion.zig");

/// Shared `std.Io` Reader/Writer scaffolding for byte-source residents
/// (inproc, iroh). Pub because the out-of-graph iroh resident is its own
/// module root under `transport/` and cannot `@import("../stream_shim.zig")`
/// — that path sits outside its module directory (ADR-0040).
pub const stream_shim = @import("stream_shim.zig");

/// The netlayer contract the driver dials and hosts against, as its own named
/// namespace: `net.netlayer.Netlayer` is a transport behind a runtime vtable, a
/// `[]const Netlayer` is the set a host speaks, and `net.netlayer.resolve`
/// dispatches a transport symbol against that slice. `net.netlayer.Listener` is
/// the listener a netlayer yields. Providers compose related realizations into
/// the slice; `net.tcp.Provider`, for example, owns plain, keyed, and sealed TCP.
/// Adding a profile changes its provider, not the driver or bindings. The OCapN
/// concept itself — the locator and its `transport` symbol —
/// lives in `model`; this is only its I/O realization.
pub const netlayer = @import("netlayer.zig");
pub const OperationOptions = netlayer.OperationOptions;

/// The multiplexed-resident contract (ADR-0112): a transport that multiplexes
/// its connections behind one readiness descriptor — the iroh and WebRTC
/// shape — as a runtime vtable a `driver.HostRuntime` hosts beside its
/// per-descriptor wires.
pub const multiplexed_resident = @import("multiplexed_resident.zig");
pub const MultiplexedResident = multiplexed_resident.MultiplexedResident;
pub const MultiplexedDialRawStartOutcome = multiplexed_resident.RawDialStartOutcome;
pub const MultiplexedDialRawFinishOutcome = multiplexed_resident.RawDialFinishOutcome;
pub const MultiplexedExternalClaimRawOutcome = multiplexed_resident.RawExternalClaimOutcome;

/// The aggregate readiness set (ADR-0112): every descriptor a poll-shaped
/// HostRuntime waits on, mirrored into one kernel set whose own fd an embedder
/// parks on.
pub const readiness = @import("readiness.zig");
pub const ReadySet = readiness.ReadySet;

/// The portable completion-loop server, generic over its platform backend. The
/// connection orchestration is OS-neutral; the platform completion primitive is a
/// `Backend` it is parameterized over. See `completion/loop.zig`.
pub const completion = loop_mod;
/// Stable phase and exact causal chain reported by transport carriers. The
/// owning operation supplies lifecycle identity when it projects this fact.
pub const carrier_failure = @import("carrier_failure.zig");

/// The io_uring completion backend (Linux). Empty off Linux so other builds stay
/// clean; it implements the `completion` backend interface and is reached
/// through `Loop` below.
const uring = if (@import("builtin").os.tag == .linux) @import("completion/uring.zig") else struct {};
/// Test-only access to Linux backend invariants; empty in production builds.
pub const uring_white_box = if (@import("builtin").is_test and @import("builtin").os.tag == .linux)
    uring.white_box
else
    struct {};

/// The kqueue completion backend (Darwin). Empty off Darwin. It implements
/// the same `completion` backend interface, bridging kqueue's readiness model to
/// the completion-shaped backend interface, and is reached through `Loop`
/// below. A Windows (IOCP) backend is not implemented.
const kqueue = if (@import("builtin").os.tag.isDarwin()) @import("completion/kqueue.zig") else struct {};
pub const kqueue_white_box = if (@import("builtin").is_test and @import("builtin").os.tag.isDarwin())
    kqueue.white_box
else
    struct {};

/// The ready-to-use TCP completion loop for the host platform: the portable
/// `completion.Loop` over the platform Backend plus `tcp.DialResolver` (OCapN
/// locator into `IpAddress`). Linux uses io_uring, Darwin uses kqueue; on any
/// other platform this is an empty struct. Named `TcpLoop` so it is not
/// confused with the generic `completion.Loop(Backend, DialResolver)`.
pub const TcpLoop = if (@import("builtin").os.tag == .linux)
    completion.Loop(uring.Backend, tcp.DialResolver)
else if (@import("builtin").os.tag.isDarwin())
    completion.Loop(kqueue.Backend, tcp.DialResolver)
else
    struct {};

/// The host platform's completion `Backend` (io_uring on Linux, kqueue on
/// macOS/BSD), the type `TcpLoop` is bound over. Exposed so an embedder that
/// needs a non-`tcp.DialResolver` locator grammar can bind its own
/// `completion.Loop(net.Backend, CustomDialResolver)` without re-declaring the
/// per-OS backend selection. The OCapN conformance harness does exactly that
/// (`conformance/ocapn-conformance/glowcap_peer.zig`), binding a locator whose
/// address lives in the locator hints. `Backend.initWithListenerIp4` selects a
/// native listener interface before the value is moved into `TcpLoop`; the
/// ordinary constructor deliberately defaults to loopback. An empty struct off
/// the supported platforms.
pub const Backend = if (@import("builtin").os.tag == .linux)
    uring.Backend
else if (@import("builtin").os.tag.isDarwin())
    kqueue.Backend
else
    struct {};

/// The host platform backend wrapped with native onion dials and onion-service
/// publication (ADR-0108). Construct `Backend`, move it into
/// `OnionBackend.initOnion` with the deployment's Tor endpoints, then pass the
/// result to `OnionLoop.initWithBackend`.
pub const OnionBackend = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    onion.completion.CompletionBackend(Backend)
else
    struct {};

/// The dial resolver paired with `OnionBackend`: `onion` designators become
/// SOCKS targets while the platform resolver continues to own TCP designators.
pub const OnionDialResolver = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    onion.completion.DialResolver(tcp.DialResolver, Backend)
else
    struct {};

/// The ready-to-use native onion completion loop. Tor conversations stay in
/// `OnionBackend`; `completion.Loop` and `driver.Bridge` remain transport-blind.
pub const OnionLoop = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    completion.Loop(OnionBackend, OnionDialResolver)
else
    struct {};

/// The host platform backend wrapped with native keyed-relay outbound dials.
/// TCP accept/dial still ride the platform backend directly; `keyed-relay`
/// dials are evented WebSocket client legs to a configured relay. Use
/// `initWithBackend` with `relay.CompletionBackend(Backend).initWithRelay`
/// when constructing the loop so the relay URL, WebSocket entropy, and optional
/// send-staging commitment are explicit deployment state.
pub const KeyedRelayBackend = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    relay.CompletionBackend(Backend)
else
    struct {};

/// A completion loop whose locator grammar includes `tcp`, `keyed-tcp`, and
/// outbound `keyed-relay`, so `driver.Bridge` can keep rendezvous redemption on
/// the native scale path instead of its blocking side-wire fallback.
pub const KeyedRelayLoop = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    completion.Loop(KeyedRelayBackend, relay.DialResolver)
else
    struct {};

/// The keyed-relay backend wrapped with sealing `noise-relay` dials
/// (ADR-0107). Construct the relay backend with `initWithRelay`, then wrap it
/// with `noise_completion.CompletionBackend(...).initSealing` so the durable
/// identity and channel-entropy seed are explicit deployment state, and hand
/// the result to `NoiseRelayLoop.initWithBackend`.
pub const NoiseRelayBackend = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    noise_completion.CompletionBackend(KeyedRelayBackend)
else
    struct {};

/// A completion loop whose locator grammar adds sealed `noise-relay` dials to
/// `KeyedRelayLoop`'s `tcp` / `keyed-tcp` / `keyed-relay` set, so a native
/// peer reaches a relay-registered responder over a channel the relay cannot
/// read.
pub const NoiseRelayLoop = if (@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())
    completion.Loop(NoiseRelayBackend, noise_completion.DialResolver(NoiseRelayBackend, relay.DialResolver))
else
    struct {};
