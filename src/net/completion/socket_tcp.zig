//! Shared IPv4 TCP socket helpers for the platform completion backends.
//!
//! `kqueue` (Darwin) and `uring` (Linux) both open IPv4 listeners with
//! `SO_REUSEADDR`, mint outbound stream sockets, and pack an `IpAddress` into a
//! connect sockaddr. Those policies live here once. Platform differences stay
//! explicit via comptime OS: Darwin marks fds nonblocking for readiness (and
//! carries the BSD `sockaddr_in` len byte); Linux leaves fds blocking because
//! io_uring's accept/connect are completion-based.

const std = @import("std");
const builtin = @import("builtin");
const completion = @import("loop.zig");

const linux = std.os.linux;

/// Which platform socket ABI the helpers drive. Call sites pass a comptime
/// value matching the backend (`kqueue` as `.darwin`, `uring` as `.linux`).
pub const Os = enum {
    darwin,
    linux,
};

/// IPv4 host + port extracted from a platform `ConnectTarget`.
pub const Ip4 = struct {
    bytes: [4]u8,
    port: u16,
};

pub fn ip4FromTarget(target: std.Io.net.IpAddress) error{AddressFamilyUnsupported}!Ip4 {
    return switch (target) {
        .ip4 => |ip4| .{ .bytes = ip4.bytes, .port = ip4.port },
        .ip6 => error.AddressFamilyUnsupported,
    };
}

/// Platform `sockaddr_in` for bind/connect. Darwin's leading `len` byte is
/// absent on Linux — keep both layouts named, never papered over.
pub fn SockaddrIn(comptime os: Os) type {
    return switch (os) {
        .darwin => extern struct {
            len: u8 = @sizeOf(@This()),
            family: u8 = af_inet,
            port: u16, // network byte order
            addr: u32, // network byte order
            zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .linux => extern struct {
            family: linux.sa_family_t = linux.AF.INET,
            port: u16, // network byte order
            addr: u32, // network byte order
            zero: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
}

pub fn sockaddrIn4(comptime os: Os, ip4: Ip4) SockaddrIn(os) {
    return .{
        .port = std.mem.nativeToBig(u16, ip4.port),
        .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &ip4.bytes, .big)),
    };
}

pub fn loopbackIp4(port: u16) Ip4 {
    return .{ .bytes = .{ 127, 0, 0, 1 }, .port = port };
}

/// Open an outbound IPv4 TCP socket. Darwin sets `O_NONBLOCK` (kqueue readiness)
/// and `SO_NOSIGPIPE` (no process-global signal on a torn-down peer); Linux
/// does not because io_uring owns async connect and send SQEs do not raise
/// SIGPIPE into the process.
pub fn openSocket(comptime os: Os) !i32 {
    const fd = try openStream(os);
    errdefer closeFd(os, fd);
    if (os == .darwin) {
        if (!setNonblocking(fd)) return error.SocketFailed;
        if (!setNoSigpipe(fd)) return error.SocketFailed;
    }
    return fd;
}

/// Bind+listen on `ip4` with `SO_REUSEADDR` so a pinned-port restart can reclaim
/// a socket still in TIME_WAIT. Do not set `SO_REUSEPORT`: a
/// listener represents one identity-bearing OCapN Host, so concurrent address
/// sharing would let the kernel route dials to different peers. Darwin also
/// marks the listener nonblocking so stale readiness never parks the loop in
/// `accept(2)`.
pub fn openListener(comptime os: Os, ip4: Ip4) !i32 {
    const fd = try openStream(os);
    errdefer closeFd(os, fd);
    if (os == .darwin) {
        if (!setNonblocking(fd)) return error.SocketFailed;
    }
    try setReuseAddr(os, fd);
    var addr = sockaddrIn4(os, ip4);
    try bind(os, fd, &addr);
    try listen(os, fd, completion.listen_backlog);
    return fd;
}

/// A bound, listening IPv4 fd plus the resolved local port (for `bind(0)`).
pub const BoundListener = struct { fd: i32, port: u16 };

/// Bind+listen on `ip4` with `SO_REUSEADDR` alone and blocking semantics, for
/// the blocking TCP tier. `SO_REUSEPORT` stays off for `openListener`'s
/// identity reason. `SO_REUSEADDR` here is a restart contract with two
/// generations: the kernel lets a bind reclaim a port whose previous owner
/// left sockets in TIME_WAIT only when the old and the new listener both set
/// the option, so every blocking-tier listener sets it unconditionally. A
/// predecessor without it parks the port for the full TIME_WAIT minute, which
/// is how a stateful server restarted onto its pinned port used to fail
/// under load. The fd stays blocking on both platforms: the blocking tier
/// wants `accept(2)` to park its caller.
pub fn openListenerReuseAddr(comptime os: Os, ip4: Ip4, backlog: u31) !BoundListener {
    const fd = try openStream(os);
    errdefer closeFd(os, fd);
    try setReuseAddr(os, fd);
    var addr = sockaddrIn4(os, ip4);
    try bind(os, fd, &addr);
    try listen(os, fd, backlog);
    return .{ .fd = fd, .port = (try boundIp4(os, fd)).port };
}

/// The local IPv4 address of a bound socket, resolving a `bind(0)` port draw.
/// `addr` already occupies network-order bytes in memory; `@bitCast` preserves
/// those bytes on either host endian rather than interpreting the integer.
pub fn boundIp4(comptime os: Os, fd: i32) !Ip4 {
    var out: SockaddrIn(os) = undefined;
    switch (os) {
        .darwin => {
            const c = std.c;
            var len: c.socklen_t = @sizeOf(SockaddrIn(os));
            if (c.getsockname(fd, @ptrCast(&out), &len) < 0) return error.SocketFailed;
        },
        .linux => {
            var len: u32 = @sizeOf(SockaddrIn(os));
            try checkLinux(linux.getsockname(fd, @ptrCast(&out), &len), error.SocketFailed);
        },
    }
    return .{
        .bytes = @bitCast(out.addr),
        .port = std.mem.bigToNative(u16, out.port),
    };
}

/// Set `O_NONBLOCK` on an fd. Every fd the kqueue backend submits on must be
/// nonblocking: readiness can go stale, and a blocking `send`/`accept` would
/// park the whole loop. Accepted fds need this too (Darwin does not inherit
/// the flag across `accept(2)`). Linux io_uring callers do not use this.
pub fn setNonblocking(fd: i32) bool {
    const c = std.c;
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    return c.fcntl(fd, c.F.SETFL, flags | nonblock) >= 0;
}

/// Suppress SIGPIPE for Darwin sockets the kqueue backend writes. Linux send
/// completions do not need a socket option here, and the generic blocking TCP
/// resident still owns its own stream policy.
pub fn setNoSigpipe(fd: i32) bool {
    const c = std.c;
    const enable: c_int = 1;
    return c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &enable, @sizeOf(c_int)) >= 0;
}

/// Disable Nagle on a loop connection, dialed or accepted, matching the
/// blocking TCP resident's unconditional stream policy. CapTP frames are
/// small and the protocol does its own batching, so coalescing buys nothing;
/// with Nagle on, a reply written while an earlier reply is still unacked
/// waits out the peer's delayed-ACK timer, which turns a pipelined
/// conversation into one ~40ms round per unit on loopback.
pub fn setNodelay(comptime os: Os, fd: i32) bool {
    switch (os) {
        .darwin => {
            const c = std.c;
            const enable: c_int = 1;
            return c.setsockopt(fd, c.IPPROTO.TCP, std.posix.TCP.NODELAY, &enable, @sizeOf(c_int)) >= 0;
        },
        .linux => {
            const enable: u32 = 1;
            const rc = linux.setsockopt(
                fd,
                linux.IPPROTO.TCP,
                std.posix.TCP.NODELAY,
                std.mem.asBytes(&enable),
                @sizeOf(u32),
            );
            return linux.errno(rc) == .SUCCESS;
        },
    }
}

pub const SendError = error{ WouldBlock, SendFailed };
pub const ReceiveError = error{ WouldBlock, ReceiveFailed };

/// Receive one nonblocking prefix. A zero count is the peer's transport EOF;
/// transient pressure remains distinct from terminal failure.
pub fn receiveNonblocking(fd: i32, bytes: []u8) ReceiveError!usize {
    while (true) {
        if (builtin.os.tag == .linux) {
            const rc = linux.recvfrom(fd, bytes.ptr, bytes.len, linux.MSG.DONTWAIT, null, null);
            return switch (linux.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .AGAIN => error.WouldBlock,
                .INTR => continue,
                else => error.ReceiveFailed,
            };
        }
        const rc = std.c.recv(fd, bytes.ptr, bytes.len, std.c.MSG.DONTWAIT);
        if (rc >= 0) return @intCast(rc);
        return switch (std.c.errno(rc)) {
            .AGAIN => error.WouldBlock,
            .INTR => continue,
            else => error.ReceiveFailed,
        };
    }
}

/// Send one nonblocking prefix without allowing a torn-down socket to raise
/// SIGPIPE. Platform syscall details stay in the socket layer; transport
/// residents see only progress, transient pressure, or terminal failure.
pub fn sendNonblocking(fd: i32, bytes: []const u8) SendError!usize {
    while (true) {
        if (builtin.os.tag == .linux) {
            const rc = linux.sendto(
                fd,
                bytes.ptr,
                bytes.len,
                linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL,
                null,
                0,
            );
            return switch (linux.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .AGAIN => error.WouldBlock,
                .INTR => continue,
                else => error.SendFailed,
            };
        }
        const rc = std.c.send(fd, bytes.ptr, bytes.len, std.c.MSG.DONTWAIT);
        if (rc >= 0) return @intCast(rc);
        return switch (std.c.errno(rc)) {
            .AGAIN => error.WouldBlock,
            .INTR => continue,
            else => error.SendFailed,
        };
    }
}

const af_inet: c_uint = 2;
const sock_stream: c_uint = 1;

// socket(2) / close(2) are not re-exported as public from std.c; Darwin needs
// the declarations. Linux helpers use `linux.*` instead and never call these.
extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

fn openStream(comptime os: Os) !i32 {
    switch (os) {
        .darwin => {
            const fd = socket(af_inet, sock_stream, 0);
            if (fd < 0) return error.SocketFailed;
            return fd;
        },
        .linux => {
            const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
            try checkLinux(fd_rc, error.SocketFailed);
            return @intCast(fd_rc);
        },
    }
}

fn setReuseAddr(comptime os: Os, fd: i32) !void {
    switch (os) {
        .darwin => {
            const c = std.c;
            const enable: c_int = 1;
            if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &enable, @sizeOf(c_int)) < 0)
                return error.SocketFailed;
        },
        .linux => {
            const enable: u32 = 1;
            try checkLinux(linux.setsockopt(
                fd,
                linux.SOL.SOCKET,
                linux.SO.REUSEADDR,
                std.mem.asBytes(&enable),
                @sizeOf(u32),
            ), error.SocketFailed);
        },
    }
}

fn bind(comptime os: Os, fd: i32, addr: *SockaddrIn(os)) !void {
    switch (os) {
        .darwin => {
            const c = std.c;
            if (c.bind(fd, @ptrCast(addr), @sizeOf(SockaddrIn(os))) < 0) {
                // Name the one actionable fault, exactly as the Linux arm
                // does: a caller retrying a pinned-port restart must tell
                // "held" from a fatal misconfig.
                if (c._errno().* == @backingInt(c.E.ADDRINUSE)) return error.AddressInUse;
                return error.BindFailed;
            }
        },
        .linux => {
            try checkLinux(linux.bind(fd, @ptrCast(addr), @sizeOf(SockaddrIn(os))), error.BindFailed);
        },
    }
}

fn listen(comptime os: Os, fd: i32, backlog: u31) !void {
    switch (os) {
        .darwin => {
            const c = std.c;
            if (c.listen(fd, backlog) < 0) return error.ListenFailed;
        },
        .linux => {
            try checkLinux(linux.listen(fd, backlog), error.ListenFailed);
        },
    }
}

fn closeFd(comptime os: Os, fd: i32) void {
    switch (os) {
        .darwin => _ = close(fd),
        .linux => _ = linux.close(fd),
    }
}

/// The typed setup-fault set both OS siblings speak: the actionable errno axis
/// plus the per-operation fallback. The Linux path once collapsed every
/// unrecognized fault to one `SyscallFailed`, losing which syscall failed while
/// the kqueue sibling already named each; `checkLinux` now takes the operation's
/// fallback so both name the operation (ADR-0081, contract 1).
const CheckError = error{
    AddressInUse,
    PermissionDenied,
    AddressNotAvailable,
    SocketFailed,
    BindFailed,
    ListenFailed,
};

fn checkLinux(rc: usize, comptime fallback: CheckError) CheckError!void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        // Name the actionable bind/listen faults so openListener's caller can
        // tell "my prior socket is in TIME_WAIT / a squatter holds the port"
        // (retry on another port) from a fatal misconfig (fail hard) — the
        // decision a keyed-tcp restart and a reconnecting client must make
        // (ADR-0081). Everything else names the operation that failed.
        .ADDRINUSE => error.AddressInUse,
        .ACCES => error.PermissionDenied,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        else => fallback,
    };
}
