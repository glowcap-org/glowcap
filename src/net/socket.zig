//! The socket library: the raw OS socket and stream plumbing a netlayer resident
//! sits on top of, gathered behind one name.
//!
//! A netlayer is a locator transport symbol (`tcp`, `keyed-tcp`, `inproc`,
//! `iroh`). Its job is CapTP over a byte stream. The OS plumbing beneath it,
//! opening and binding sockets, packing sockaddrs, stream options, and the
//! pinned reader/writer stream wrapper, is a different concern, and
//! it lives here. Residents reach socket bits through `net.socket`, never by
//! importing `completion/` internals or `@import`-ing a sibling file, so "tcp
//! logic" cannot leak back into a netlayer or across a module boundary. The
//! implementation files live under `completion/`. This module is the boundary
//! that names them as one library.

const std = @import("std");
const socket_tcp = @import("completion/socket_tcp.zig");
const keepalive = @import("completion/tcp_keepalive.zig");

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
pub const openListenerReuseAddr = socket_tcp.openListenerReuseAddr;
pub const BoundListener = socket_tcp.BoundListener;
pub const boundIp4 = socket_tcp.boundIp4;
pub const setNonblocking = socket_tcp.setNonblocking;
pub const setNoSigpipe = socket_tcp.setNoSigpipe;
pub const sendNonblocking = socket_tcp.sendNonblocking;
pub const receiveNonblocking = socket_tcp.receiveNonblocking;

/// Opt-in TCP keepalive. `Keepalive{idle_sec,interval_sec,count}` is required in
/// full when set (no silent OS default). `applyKeepalive` writes the sockopts.
/// The rationale is NAT hold-open and dead-remote-host reclaim, not reaping a
/// live orphaned process, see `completion/tcp_keepalive.zig`.
pub const Keepalive = keepalive.Keepalive;
pub const ConfigurationError = std.posix.SetSockOptError || keepalive.ApplyError;
pub const applyKeepalive = keepalive.apply;

/// Disable Nagle on a connected TCP stream. Callers choose whether refusal is
/// fatal: direct TCP residents require this latency contract, while carrier
/// hops may keep a functional connection and accept lower throughput.
pub fn applyNodelay(fd: std.posix.socket_t) std.posix.SetSockOptError!void {
    try std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    );
}
