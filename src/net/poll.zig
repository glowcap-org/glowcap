//! The one raw `poll(2)` owner shared by blocking net residents, readiness
//! backends, and the host's aggregate descriptor wait. Raw OS outcomes are
//! classified here once, so no caller re-derives which errno is a transport
//! fault, which is kernel pressure, and which means the wait itself was
//! malformed.
//!
//! `std.posix.poll` is not used: it restarts an interrupted wait with the
//! caller's whole timeout and treats `EINVAL` as unreachable, and the host
//! must pace a temporary resource refusal instead of aborting on it.

const std = @import("std");
const builtin = @import("builtin");

const clock = @import("clock.zig");

const posix = std.posix;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const WaitError = error{
    /// The kernel could not allocate the wait's internal tables (Linux
    /// `ENOMEM`, Darwin `EAGAIN`). Memory returns as other work finishes, so a
    /// later wait on the same rows may succeed. No row was examined.
    SystemResources,
    /// The wait itself is malformed: more rows than `nfds_t` can count, or
    /// more than the kernel accepts (`EINVAL`). No retry changes that.
    InvalidWait,
    /// Any other errno, including Linux `EAGAIN`. Waiting does not recover
    /// it, and nothing is printed: the caller owns the diagnostic.
    Unexpected,
};

/// Poll `fds` for up to `timeout_ms` and return the number of ready rows. Any
/// negative timeout waits forever (`-1` at the syscall), and zero never blocks.
/// A wait interrupted by a signal resumes for the time left on the kernel's
/// monotonic clock, never for the caller's whole timeout again. The remainder
/// is whole milliseconds, the finest `poll` takes, and never exceeds the
/// caller's timeout. Once the deadline has passed, one last nonblocking poll
/// asks for readiness, and an interruption of that ends the wait as quiet, so
/// repeated interruptions never extend a finite wait.
pub fn wait(fds: []posix.pollfd, timeout_ms: i32) WaitError!usize {
    const rows = try rowCount(fds.len);
    const budget: i32 = if (timeout_ms < 0) -1 else timeout_ms;
    const deadline_ms: i64 = if (budget > 0) nowMs() +| budget else 0;
    var remaining = budget;
    var final = false;
    while (true) {
        switch (syscall(fds.ptr, rows, remaining)) {
            .ready => |count| return count,
            .errno => |err| switch (err) {
                .INTR => {
                    if (budget < 0) continue;
                    if (final or budget == 0) return 0;
                    const left = deadline_ms - nowMs();
                    if (left > 0) {
                        remaining = @intCast(@min(left, budget));
                    } else {
                        remaining = 0;
                        final = true;
                    }
                },
                .NOMEM => return error.SystemResources,
                .AGAIN => return if (is_darwin) error.SystemResources else error.Unexpected,
                .INVAL => return error.InvalidWait,
                .FAULT => unreachable,
                // `posix.unexpectedErrno` prints the errno and a stack trace on a
                // Debug target. The typed cause climbs to the caller, which owns
                // any diagnostic.
                else => return error.Unexpected,
            },
        }
    }
}

/// The row count as the kernel takes it. Linux declares `nfds` an unsigned
/// 32-bit integer while Zig's `nfds_t` there is a `usize`, so a count only the
/// wider type holds would reach the syscall truncated. It is refused instead.
fn rowCount(len: usize) WaitError!posix.nfds_t {
    const uapi = std.math.cast(u32, len) orelse return error.InvalidWait;
    return @intCast(uapi);
}

fn nowMs() i64 {
    if (builtin.is_test) if (testing.virtualNowMs()) |virtual| return virtual;
    return clock.nowMonotonicMs();
}

const Outcome = union(enum) { ready: usize, errno: posix.E };

/// The syscall owner. A test build first consults the scoped errno script.
fn syscall(fds: [*]posix.pollfd, rows: posix.nfds_t, timeout_ms: i32) Outcome {
    if (builtin.is_test) if (testing.take(timeout_ms)) |injected| return .{ .errno = injected };
    const rc = posix.system.poll(fds, rows, timeout_ms);
    return switch (posix.errno(rc)) {
        .SUCCESS => .{ .ready = @intCast(rc) },
        else => |err| .{ .errno = err },
    };
}

/// Scoped errno injection at the syscall owner, for the thread that holds the
/// guard. A scripted call returns its errno without reaching the kernel and a
/// later call reaches it, so the rows, descriptors, and readiness a test waits
/// on stay real. The guard also owns a virtual monotonic clock that each
/// scripted errno advances, so a test states how long an interruption took
/// without waiting for it. Absent from every non-test build.
pub const testing = if (builtin.is_test) struct {
    const max_recorded = 16;

    pub const Script = struct {
        /// Errnos the next raw polls return, in order, before the kernel is
        /// consulted again.
        errnos: []const posix.E,
        used: usize = 0,
        /// The `timeout_ms` of the first `max_recorded` raw polls under the
        /// guard, scripted or not, and how many polls ran in all.
        timeouts: [max_recorded]i32 = undefined,
        calls: usize = 0,
        /// The wait's clock under the guard, in milliseconds.
        now_ms: i64 = 0,
        /// Time each scripted errno takes to arrive, as a poll spends before
        /// a signal interrupts it.
        scripted_ms: i32 = 0,
    };

    threadlocal var active: ?*Script = null;

    fn virtualNowMs() ?i64 {
        const script = active orelse return null;
        return script.now_ms;
    }

    /// `rowCount`, for the count bound's own test.
    pub const rowCount = wait_rowCount;

    fn take(timeout_ms: i32) ?posix.E {
        const script = active orelse return null;
        if (script.calls < max_recorded) script.timeouts[script.calls] = timeout_ms;
        script.calls += 1;
        if (script.used == script.errnos.len) return null;
        defer script.used += 1;
        script.now_ms += script.scripted_ms;
        return script.errnos[script.used];
    }

    const Guard = struct {
        previous: ?*Script,
        pub fn deinit(self: Guard) void {
            active = self.previous;
        }
    };

    pub fn inject(script: *Script) Guard {
        const guard: Guard = .{ .previous = active };
        active = script;
        return guard;
    }
} else struct {};

const wait_rowCount = rowCount;
