//! Opt-in TCP keepalive, explicit idle/interval/count, both socket paths.
//!
//! This is a kernel backstop, not an application-liveness detector. It serves:
//! (1) holding NAT/firewall mappings open on long-idle CapTP connections, and
//! (2) reclaiming local resources when the *remote host* is gone (crash, cable
//! pull, partition) and no clean TCP close arrives. It does **not** reap a
//! live-but-orphaned local process that still holds the socket, that process
//! ACKs probes. Fix that with process supervise/exit (and app heartbeats when
//! the protocol has them). Turning on `SO_KEEPALIVE` alone is also insufficient:
//! the OS idle default is measured in hours. When this option is set, all three
//! timers are required so the failure mode is chosen at the API boundary, not
//! inherited as a silent default.
//!
//! Configuration is transactional and fallible. If `SO_KEEPALIVE` enables but
//! a timer `setsockopt` then fails, keepalive is rolled back off and the refusal
//! reaches the caller. A requested liveness window is never silently absent or
//! left riding the OS multi-hour default. Platform differences
//! stay named: Linux `TCP_KEEPIDLE` vs
//! Darwin `TCP_KEEPALIVE` for the idle second. Option numbers are written as
//! named locals (not a platform OS module import) so this file stays under the
//! portable `std.posix` arch-check rule. The numbers match the kernel ABIs.

const std = @import("std");
const builtin = @import("builtin");

/// Opt-in TCP keepalive. Every field is required when this is set. There is no
/// "just enable keepalive" mode that rides the OS default (often multi-hour idle).
/// Callers set idle/interval/count for NAT hold-open or dead-remote-host reclaim.
/// See the module doc. Off by default.
pub const Keepalive = struct {
    /// Seconds of idle before the first probe.
    idle_sec: u32,
    /// Seconds between probes.
    interval_sec: u32,
    /// Failed probes before the kernel declares the peer dead.
    count: u32,
};

pub const ApplyError = std.posix.SetSockOptError || error{
    InvalidKeepalive,
    UnsupportedPlatform,
    KeepaliveRollbackFailed,
};

/// Apply `ka` on a connected (or about-to-connect) stream socket. Success means
/// every requested timer is active. Any refusal is returned after disabling a
/// partially enabled configuration.
pub fn apply(fd: std.posix.socket_t, ka: Keepalive) ApplyError!void {
    const enable: c_int = 1;
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.KEEPALIVE,
        std.mem.asBytes(&enable),
    );

    const idle = std.math.cast(c_int, ka.idle_sec) orelse
        return rollbackKeepalive(fd, error.InvalidKeepalive);
    const intvl = std.math.cast(c_int, ka.interval_sec) orelse
        return rollbackKeepalive(fd, error.InvalidKeepalive);
    const cnt = std.math.cast(c_int, ka.count) orelse
        return rollbackKeepalive(fd, error.InvalidKeepalive);

    // Idle option name differs: Linux `TCP_KEEPIDLE` vs Darwin `TCP_KEEPALIVE`.
    // Numbers from the Linux and Darwin TCP headers, keep them named here
    // rather than importing a platform OS module (banned in portable net sources).
    const idle_opt: c_int = switch (builtin.os.tag) {
        .linux => 4, // TCP_KEEPIDLE
        .macos, .ios, .tvos, .watchos, .visionos => 0x10, // TCP_KEEPALIVE
        // SO_KEEPALIVE is already on; unsupported OS must roll it back so we
        // never leave the socket on with multi-hour OS defaults (ADR-0081).
        else => return rollbackKeepalive(fd, error.UnsupportedPlatform),
    };
    const intvl_opt: c_int = switch (builtin.os.tag) {
        .linux => 5, // TCP_KEEPINTVL
        .macos, .ios, .tvos, .watchos, .visionos => 0x101, // TCP_KEEPINTVL
        else => return rollbackKeepalive(fd, error.UnsupportedPlatform),
    };
    const cnt_opt: c_int = switch (builtin.os.tag) {
        .linux => 6, // TCP_KEEPCNT
        .macos, .ios, .tvos, .watchos, .visionos => 0x102, // TCP_KEEPCNT
        else => return rollbackKeepalive(fd, error.UnsupportedPlatform),
    };

    // All three timers must take together. Leaving `SO_KEEPALIVE` enabled with a
    // timer unset would ride the OS multi-hour idle default under the appearance
    // of the caller's configured window, the silent-default state ADR-0081
    // forbids. On any timer failure, roll keepalive back off so the state is
    // exact: the full configured window, or nothing.
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, idle_opt, std.mem.asBytes(&idle)) catch |err|
        return rollbackKeepalive(fd, err);
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, intvl_opt, std.mem.asBytes(&intvl)) catch |err|
        return rollbackKeepalive(fd, err);
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, cnt_opt, std.mem.asBytes(&cnt)) catch |err|
        return rollbackKeepalive(fd, err);
}

/// Roll `SO_KEEPALIVE` back off after a timer `setsockopt` failed, so a partly
/// configured socket never rides the OS multi-hour idle default under the
/// appearance of the caller's window (ADR-0081). A rollback refusal is distinct:
/// the socket's liveness policy is now unknown and it must not be published as
/// a successfully configured connection.
fn rollbackKeepalive(fd: std.posix.socket_t, cause: ApplyError) ApplyError {
    const disable: c_int = 0;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&disable)) catch
        return error.KeepaliveRollbackFailed;
    return cause;
}
