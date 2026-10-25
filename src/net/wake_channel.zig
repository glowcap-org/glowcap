//! The cross-thread wake channel: a nonblocking socketpair whose read half a
//! waiting thread polls, or arms a completion recv on, which is why it is a
//! socketpair and not a pipe, and whose write half any thread nudges.
//! A `WouldBlock` nudge is safely coalesced: unread bytes already make the
//! read half readable, so no wake is lost. Every other send or receive fault
//! is returned to the owner. A broken channel cannot masquerade as a
//! coalesced wake. The off-turn settle mailbox (`driver.SettleMailbox`,
//! ADR-0014) is the first owner. The channel itself carries nudge bytes and
//! nothing else.
//!
//! Platform-gated like the completion backends' socket helpers: Linux by raw
//! syscall (the loop links no libc there), Darwin through libc externs.
//! Allowlisted for the platform-namespace ban in `tools/check/arch_check.zig`
//! beside `socket_tcp.zig`.

const std = @import("std");
const builtin = @import("builtin");

const socket = @import("socket.zig");

const linux = std.os.linux;
const is_linux = builtin.os.tag == .linux;

pub const Failure = error{ WakeNudgeFailed, WakeDrainFailed };

/// One allocation-free, cross-thread first-failure latch for owners whose
/// wake calls cannot return directly (shutdown hooks and foreign callbacks).
/// The owning operation reads it at its next step or close barrier.
pub const FailureLatch = struct {
    const State = enum(u8) { healthy, nudge_failed, drain_failed };

    state: std.atomic.Value(u8) = .init(@backingInt(State.healthy)),

    pub fn record(self: *FailureLatch, cause: Failure) void {
        const next: State = switch (cause) {
            error.WakeNudgeFailed => .nudge_failed,
            error.WakeDrainFailed => .drain_failed,
        };
        _ = self.state.cmpxchgStrong(
            @backingInt(State.healthy),
            @backingInt(next),
            .release,
            .monotonic,
        );
    }

    pub fn failure(self: *const FailureLatch) ?Failure {
        return switch (self.state.load(.acquire)) {
            @backingInt(State.healthy) => null,
            @backingInt(State.nudge_failed) => error.WakeNudgeFailed,
            @backingInt(State.drain_failed) => error.WakeDrainFailed,
            // Corrupt or incompletely initialized adapter state is itself a
            // contained wake failure, never grounds for a process panic.
            else => error.WakeDrainFailed,
        };
    }

    pub fn check(self: *const FailureLatch) Failure!void {
        if (self.failure()) |err| return err;
    }
};

// Darwin reaches the socket calls through libc; Linux uses raw syscalls and
// never references these externs (the `socket_tcp.zig` convention).
extern "c" fn socketpair(domain: c_uint, sock_type: c_uint, protocol: c_uint, sv: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern "c" fn shutdown(fd: c_int, how: c_int) c_int;

pub const WakeChannel = struct {
    /// The half the owning thread waits on: readable while nudges are
    /// pending.
    read: i32,
    /// The half any thread nudges.
    write: i32,

    pub fn open() error{WakeChannelFailed}!WakeChannel {
        if (is_linux) {
            var sv: [2]i32 = undefined;
            const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &sv);
            if (linux.errno(rc) != .SUCCESS) return error.WakeChannelFailed;
            return .{ .read = sv[0], .write = sv[1] };
        }
        var sv: [2]c_int = undefined;
        // AF_UNIX and SOCK_STREAM are 1 on every BSD-lineage platform this
        // arm reaches (Darwin); Linux takes the syscall arm above.
        if (socketpair(1, 1, 0, &sv) < 0) return error.WakeChannelFailed;
        for (sv) |fd| {
            if (!socket.setNonblocking(fd) or !socket.setNoSigpipe(fd) or !socket.setCloseOnExec(fd)) {
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

    pub const NudgeResult = enum {
        sent,
        coalesced,
    };

    /// Wake the owner with one byte. A full nonblocking channel is success
    /// with a distinct `coalesced` result because an unread byte already
    /// makes the owner wakeable. Every other fault is reported.
    /// `MSG_NOSIGNAL` on Linux keeps a torn-down read half from raising
    /// SIGPIPE. Teardown order (nudgers stop first) covers the rest.
    pub fn nudge(self: WakeChannel) error{WakeNudgeFailed}!NudgeResult {
        const byte = [_]u8{1};
        while (true) {
            if (is_linux) {
                const rc = linux.sendto(self.write, &byte, byte.len, linux.MSG.NOSIGNAL, null, 0);
                switch (linux.errno(rc)) {
                    .SUCCESS => if (rc == byte.len) return .sent else {
                        retireWrite(self.write);
                        return error.WakeNudgeFailed;
                    },
                    .AGAIN => return .coalesced,
                    .INTR => continue,
                    else => {
                        retireWrite(self.write);
                        return error.WakeNudgeFailed;
                    },
                }
            }
            const rc = send(self.write, &byte, byte.len, 0);
            if (rc >= 0) {
                if (rc == byte.len) return .sent;
                retireWrite(self.write);
                return error.WakeNudgeFailed;
            }
            switch (std.c.errno(rc)) {
                .AGAIN => return .coalesced,
                .INTR => continue,
                else => {
                    retireWrite(self.write);
                    return error.WakeNudgeFailed;
                },
            }
        }
    }

    /// Drain pending nudge bytes, on the owning thread, before acting on
    /// them: a nudge racing the drain leaves its byte unread, so the next
    /// wait wakes again rather than losing the signal.
    pub fn drain(self: WakeChannel) error{WakeDrainFailed}!void {
        var sink: [64]u8 = undefined;
        while (true) {
            if (is_linux) {
                const rc = linux.recvfrom(self.read, &sink, sink.len, 0, null, null);
                switch (linux.errno(rc)) {
                    .SUCCESS => if (rc == 0) return error.WakeDrainFailed,
                    .AGAIN => return,
                    .INTR => continue,
                    else => return error.WakeDrainFailed,
                }
            } else {
                const rc = recv(self.read, &sink, sink.len, 0);
                if (rc == 0) return error.WakeDrainFailed;
                if (rc > 0) continue;
                switch (std.c.errno(rc)) {
                    .AGAIN => return,
                    .INTR => continue,
                    else => return error.WakeDrainFailed,
                }
            }
        }
    }
};

fn closeFd(fd: i32) void {
    if (is_linux) {
        _ = linux.close(fd);
    } else {
        _ = close(fd);
    }
}

/// Make a fatal write fault level-visible to a waiter before reporting it.
/// Keeping the descriptor open avoids fd reuse races with the owner's later
/// `deinit`. Shutting down its write direction makes the peer read half reach
/// EOF/HUP after any already queued nudge bytes.
fn retireWrite(fd: i32) void {
    if (is_linux) {
        _ = linux.shutdown(fd, linux.SHUT.WR);
    } else {
        _ = shutdown(fd, std.c.SHUT.WR);
    }
}
