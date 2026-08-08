//! The cross-thread wake channel: a nonblocking socketpair whose read half a
//! waiting thread polls — or arms a completion recv on, which is why it is a
//! socketpair and not a pipe — and whose write half any thread nudges. The
//! nudge is best-effort under the ADR-0089 invariant: a `WouldBlock` means
//! unread bytes already make the read half readable, so no wake is ever
//! lost. The off-turn settle mailbox (`driver.SettleMailbox`, ADR-0102) is
//! the first owner; the channel itself carries nudge bytes and nothing else.
//!
//! Platform-gated like the completion backends' socket helpers: Linux by raw
//! syscall (the loop links no libc there), Darwin through libc externs.
//! Allowlisted for the platform-namespace ban in `tools/check/arch_check.zig`
//! beside `socket_tcp.zig`.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;

// Darwin reaches the socket calls through libc; Linux uses raw syscalls and
// never references these externs (the `socket_tcp.zig` convention).
extern "c" fn socketpair(domain: c_uint, sock_type: c_uint, protocol: c_uint, sv: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;

pub const WakeChannel = struct {
    /// The half the owning thread waits on: readable while nudges are
    /// pending.
    read: i32,
    /// The half any thread nudges.
    write: i32,

    pub fn open() error{WakeChannelFailed}!WakeChannel {
        if (is_linux) {
            var sv: [2]i32 = undefined;
            const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &sv);
            if (linux.errno(rc) != .SUCCESS) return error.WakeChannelFailed;
            return .{ .read = sv[0], .write = sv[1] };
        }
        var sv: [2]c_int = undefined;
        // AF_UNIX and SOCK_STREAM are 1 on every BSD-lineage platform this
        // arm reaches (Darwin); Linux takes the syscall arm above.
        if (socketpair(1, 1, 0, &sv) < 0) return error.WakeChannelFailed;
        for (sv) |fd| {
            if (!setNonblockingC(fd)) {
                _ = close(sv[0]);
                _ = close(sv[1]);
                return error.WakeChannelFailed;
            }
        }
        return .{ .read = sv[0], .write = sv[1] };
    }

    /// Close both halves, on the owning thread, after every nudging thread
    /// has stopped.
    pub fn deinit(self: WakeChannel) void {
        closeFd(self.read);
        closeFd(self.write);
    }

    /// Wake the owner: one byte, best-effort under the nudge invariant.
    /// `MSG_NOSIGNAL` on Linux keeps a torn-down read half from raising
    /// SIGPIPE; teardown order (nudgers stop first) covers the rest.
    pub fn nudge(self: WakeChannel) void {
        const byte = [_]u8{1};
        if (is_linux) {
            _ = linux.sendto(self.write, &byte, byte.len, linux.MSG.NOSIGNAL, null, 0);
        } else {
            _ = send(self.write, &byte, byte.len, 0);
        }
    }

    /// Drain pending nudge bytes, on the owning thread, before acting on
    /// them: a nudge racing the drain leaves its byte unread, so the next
    /// wait wakes again rather than losing the signal.
    pub fn drain(self: WakeChannel) void {
        var sink: [64]u8 = undefined;
        while (true) {
            const n = recvSome(self.read, &sink);
            if (n < sink.len) return; // short read: drained (or faulted)
        }
    }
};

fn setNonblockingC(fd: c_int) bool {
    const c = std.c;
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    return c.fcntl(fd, c.F.SETFL, flags | nonblock) >= 0;
}

fn closeFd(fd: i32) void {
    if (is_linux) {
        _ = linux.close(fd);
    } else {
        _ = close(fd);
    }
}

/// Read up to `sink.len` pending bytes; zero on empty or fault — the caller
/// only needs "was it a full buffer" to keep draining.
fn recvSome(fd: i32, sink: []u8) usize {
    if (is_linux) {
        const rc = linux.recvfrom(fd, sink.ptr, sink.len, 0, null, null);
        if (linux.errno(rc) != .SUCCESS) return 0;
        return rc;
    }
    const n = recv(fd, sink.ptr, sink.len, 0);
    if (n < 0) return 0;
    return @intCast(n);
}
