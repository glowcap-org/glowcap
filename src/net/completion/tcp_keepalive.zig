//! Opt-in TCP keepalive — explicit idle/interval/count, both socket paths.
//!
//! This is a kernel backstop, not an application-liveness detector. It serves:
//! (1) holding NAT/firewall mappings open on long-idle CapTP connections, and
//! (2) reclaiming local resources when the *remote host* is gone (crash, cable
//! pull, partition) and no clean TCP close arrives. It does **not** reap a
//! live-but-orphaned local process that still holds the socket — that process
//! ACKs probes; fix that with process supervise/exit (and app heartbeats when
//! the protocol has them). Turning on `SO_KEEPALIVE` alone is also insufficient:
//! the OS idle default is measured in hours. When this option is set, all three
//! timers are required so the failure mode is chosen at the API boundary, not
//! inherited as a silent default.
//!
//! Applied best-effort (same posture as `TCP_NODELAY`): a stream whose options
//! cannot be set still works; the caller asked for detection, not a hard fail on
//! exotic sockets. Best-effort does not mean a wrong window is left active,
//! though: if `SO_KEEPALIVE` enables but a timer `setsockopt` then fails,
//! keepalive is rolled back off rather than left riding the OS multi-hour
//! default under the appearance of the configured window. Platform differences
//! stay named: Linux `TCP_KEEPIDLE` vs
//! Darwin `TCP_KEEPALIVE` for the idle second. Option numbers are written as
//! named locals (not a platform OS module import) so this file stays under the
//! portable `std.posix` arch-check rule; the numbers match the kernel ABIs.

const std = @import("std");
const builtin = @import("builtin");

/// Opt-in TCP keepalive. Every field is required when this is set — there is no
/// "just enable keepalive" mode that rides the OS default (often multi-hour idle).
/// Callers set idle/interval/count for NAT hold-open or dead-remote-host reclaim;
/// see the module doc. Off by default.
pub const Keepalive = struct {
    /// Seconds of idle before the first probe.
    idle_sec: u32,
    /// Seconds between probes.
    interval_sec: u32,
    /// Failed probes before the kernel declares the peer dead.
    count: u32,
};

/// Apply `ka` on a connected (or about-to-connect) stream socket. Best-effort:
/// failures are swallowed the way `TCP_NODELAY` is — the socket remains usable.
pub fn apply(fd: std.posix.socket_t, ka: Keepalive) void {
    const enable: c_int = 1;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.KEEPALIVE,
        std.mem.asBytes(&enable),
    ) catch return;

    const idle: c_int = @intCast(ka.idle_sec);
    const intvl: c_int = @intCast(ka.interval_sec);
    const cnt: c_int = @intCast(ka.count);

    // Idle option name differs: Linux `TCP_KEEPIDLE` vs Darwin `TCP_KEEPALIVE`.
    // Numbers from the Linux and Darwin TCP headers — keep them named here
    // rather than importing a platform OS module (banned in portable net sources).
    const idle_opt: c_int = switch (builtin.os.tag) {
        .linux => 4, // TCP_KEEPIDLE
        .macos, .ios, .tvos, .watchos, .visionos => 0x10, // TCP_KEEPALIVE
        // SO_KEEPALIVE is already on; unsupported OS must roll it back so we
        // never leave the socket on with multi-hour OS defaults (ADR-0081).
        else => return disableKeepalive(fd),
    };
    const intvl_opt: c_int = switch (builtin.os.tag) {
        .linux => 5, // TCP_KEEPINTVL
        .macos, .ios, .tvos, .watchos, .visionos => 0x101, // TCP_KEEPINTVL
        else => return disableKeepalive(fd),
    };
    const cnt_opt: c_int = switch (builtin.os.tag) {
        .linux => 6, // TCP_KEEPCNT
        .macos, .ios, .tvos, .watchos, .visionos => 0x102, // TCP_KEEPCNT
        else => return disableKeepalive(fd),
    };

    // All three timers must take together. Leaving `SO_KEEPALIVE` enabled with a
    // timer unset would ride the OS multi-hour idle default under the appearance
    // of the caller's configured window — the silent-default state ADR-0081
    // forbids. On any timer failure, roll keepalive back off so the state stays
    // honest: the full configured window, or nothing.
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, idle_opt, std.mem.asBytes(&idle)) catch return disableKeepalive(fd);
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, intvl_opt, std.mem.asBytes(&intvl)) catch return disableKeepalive(fd);
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, cnt_opt, std.mem.asBytes(&cnt)) catch return disableKeepalive(fd);
}

/// Roll `SO_KEEPALIVE` back off after a timer `setsockopt` failed, so a partly
/// configured socket never rides the OS multi-hour idle default under the
/// appearance of the caller's window (ADR-0081). Best-effort: disabling an
/// option that just enabled cannot realistically fail, and if it did the stream
/// still works.
fn disableKeepalive(fd: std.posix.socket_t) void {
    const disable: c_int = 0;
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&disable)) catch {};
}
