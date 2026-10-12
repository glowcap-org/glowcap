//! The blocking accept-cancel gate: how a listener parked in `accept` or a
//! readiness wait is woken from another thread and joined before its storage
//! goes away.
//!
//! `shutdown(2)` does not reliably wake an `accept` parked on a listening
//! socket, and closing the descriptor under a parked wait is the BADF hazard
//! the netlayer contract's `waitAcceptable` exists to avoid. So a listener
//! polls its socket beside a private wake channel. `shutdown` latches
//! `stopping` and nudges the channel, the parked wait sees one or the other
//! and returns `ConnectionLost`, and `join` takes and releases the operation
//! lease so the caller knows no wait still reads listener state. The `tcp` and
//! `onion` listeners run it. The inproc listener has no socket to poll and
//! keeps its condition-variable shape. The iroh sidecar offers no descriptor,
//! so its accept seat polls in bounded slices instead. The keyed-relay box
//! waits on a background task rather than a socket.

const std = @import("std");

const poll = @import("poll.zig");
const wake_channel = @import("wake_channel.zig");

pub const WaitError = error{ ConnectionLost, WakeNudgeFailed, WakeDrainFailed };

const readable_mask = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;

pub const Gate = struct {
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},
    /// Serializes every accept and readiness wait, so `join` waits out the one
    /// in flight and a wait never runs against half-released storage.
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn open() error{WakeChannelFailed}!Gate {
        return .{ .wake = try wake_channel.WakeChannel.open() };
    }

    /// Close the wake channel. Call after `join`, when no nudging thread
    /// remains.
    pub fn deinit(self: *const Gate) void {
        self.wake.deinit();
    }

    /// Take the operation lease for one accept or readiness wait.
    pub fn lock(self: *Gate, io: std.Io) void {
        self.operation_gate.lockUncancelable(io);
    }

    pub fn unlock(self: *Gate, io: std.Io) void {
        self.operation_gate.unlock(io);
    }

    /// Under the lease, wait until `fd` is readable or `timeout_ms` passes (a
    /// negative timeout waits forever). Returns true when `fd` is readable and
    /// false on timeout. A shutdown that happened before the call or arrives
    /// during it returns `ConnectionLost`.
    ///
    /// The shutdown branch drains the wake channel before returning. The nudge
    /// byte is the only thing that ever makes the wake half readable, and the
    /// channel is level-triggered, so an undrained byte keeps the descriptor
    /// readable for the rest of the listener's life and hides a drain fault the
    /// close barrier is meant to report. Draining costs one syscall on a branch
    /// each waiter takes at most once, because every later wait returns at the
    /// `stopping` check before it polls.
    pub fn waitReadable(self: *Gate, fd: std.posix.fd_t, timeout_ms: i32) WaitError!bool {
        try self.wake_failure.check();
        if (self.stopping.load(.acquire)) return error.ConnectionLost;
        var fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wake.read, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = poll.wait(&fds, timeout_ms) catch return error.ConnectionLost;
        try self.wake_failure.check();
        if (self.stopping.load(.acquire) or fds[1].revents & readable_mask != 0) {
            self.wake.drain() catch |err| {
                self.wake_failure.record(err);
                return err;
            };
            return error.ConnectionLost;
        }
        return ready != 0 and fds[0].revents & readable_mask != 0;
    }

    /// Wake a parked wait without releasing anything. Idempotent, so a foreign
    /// runtime can cancel, join its accept lease, then release once.
    pub fn shutdown(self: *Gate) void {
        self.stopping.store(true, .release);
        _ = self.wake.nudge() catch |err| self.wake_failure.record(err);
    }

    /// Wait out the operation in flight after `shutdown`. When this returns no
    /// wait holds the lease, and the caller owns teardown.
    pub fn join(self: *Gate, io: std.Io) void {
        self.operation_gate.lockUncancelable(io);
        self.operation_gate.unlock(io);
    }

    /// The first wake fault this gate latched, for the close barrier's report.
    pub fn failure(self: *const Gate) ?wake_channel.Failure {
        return self.wake_failure.failure();
    }
};
