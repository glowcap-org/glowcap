//! The socket library: the raw OS socket and stream plumbing a netlayer resident
//! sits on top of, gathered behind one name.
//!
//! A netlayer is a locator transport symbol (`tcp`, `keyed-tcp`, `inproc`,
//! `iroh`); its job is CapTP over a byte stream. The OS plumbing beneath it —
//! opening and binding sockets, packing sockaddrs, the nonblocking and keepalive
//! options, the pinned reader/writer stream wrapper — is a different concern, and
//! it lives here. Residents reach socket bits through `net.socket`, never by
//! importing `completion/` internals or `@import`-ing a sibling file, so "tcp
//! logic" cannot leak back into a netlayer or across a module boundary. The
//! implementation files live under `completion/`; this module is the boundary
//! that names them as one library.

const socket_tcp = @import("completion/socket_tcp.zig");
const keepalive = @import("completion/tcp_keepalive.zig");
const stream_shim = @import("stream_shim.zig");

/// Raw IPv4 TCP socket primitives, parameterized on a comptime OS: open a
/// socket or a bound listener, pack a `sockaddr_in`, mark a fd nonblocking.
pub const Os = socket_tcp.Os;
pub const Ip4 = socket_tcp.Ip4;
pub const ip4FromTarget = socket_tcp.ip4FromTarget;
pub const SockaddrIn = socket_tcp.SockaddrIn;
pub const sockaddrIn4 = socket_tcp.sockaddrIn4;
pub const loopbackIp4 = socket_tcp.loopbackIp4;
pub const openSocket = socket_tcp.openSocket;
pub const openListener = socket_tcp.openListener;
pub const setNonblocking = socket_tcp.setNonblocking;
pub const sendNonblocking = socket_tcp.sendNonblocking;

/// Opt-in TCP keepalive. `Keepalive{idle_sec,interval_sec,count}` is required in
/// full when set (no silent OS default); `applyKeepalive` writes the sockopts.
/// The rationale is NAT hold-open and dead-remote-host reclaim, not reaping a
/// live orphaned process — see `completion/tcp_keepalive.zig`.
pub const Keepalive = keepalive.Keepalive;
pub const applyKeepalive = keepalive.apply;

/// The stream wrapper a transport-generic `Connection` borrows, pinned so its
/// reader/writer interfaces hold a stable address.
pub const Shim = stream_shim.Shim;
