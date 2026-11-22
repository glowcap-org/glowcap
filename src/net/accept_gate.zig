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

const failure = @import("netlayer/failure.zig");
const poll = @import("poll.zig");
const socket = @import("socket.zig");
const wake_channel = @import("wake_channel.zig");

pub const AcceptMode = enum { wait, ready };

/// `ConnectionLost` is the listener shutting down. A refused poll keeps its
/// own cause, as do the wake channel's faults.
pub const WaitError = error{ ConnectionLost, WakeNudgeFailed, WakeDrainFailed } || poll.WaitError;

/// A wait's failures, or the kernel refusing the accept itself on a listener
/// that stays open.
pub const AcceptError = WaitError || socket.AcceptRefusal;

/// The netlayer contract's name for a gate failure. Shutdown and the wake
/// faults keep theirs, and the kernel refusing the accept or its wait is
/// `AcceptRefused`: the listener is still open. The gate allocates nothing, so
/// its `OutOfMemory` is the kernel's.
pub fn classify(err: AcceptError) failure.AcceptError {
    return switch (err) {
        error.ConnectionLost => error.ConnectionLost,
        error.WakeNudgeFailed => error.WakeNudgeFailed,
        error.WakeDrainFailed => error.WakeDrainFailed,
        error.OutOfMemory,
        error.SystemResources,
        error.InvalidWait,
        error.Unexpected,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => error.AcceptRefused,
    };
}

/// Whether `err` is one of the gate's own failures, for a caller whose error
/// set merges the gate's with its own.
pub fn owns(comptime err: anyerror) bool {
    for (@typeInfo(AcceptError).error_set.error_names.?) |name| {
        if (std.mem.eql(u8, name, @errorName(err))) return true;
    }
    return false;
}

const readable_mask = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;

pub const Gate = struct {
    wake: wake_channel.WakeChannel,
    wake_failure: wake_channel.FailureLatch = .{},
    /// Serializes every accept and readiness wait, so `join` waits out the one
    /// in flight and a wait never runs against half-released storage.
    operation_gate: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set under the operation lease on the first event-driven accept.
    nonblocking: bool = false,

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
    /// during it returns `ConnectionLost`, and a refused poll its own cause.
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
        const ready = try poll.wait(&fds, timeout_ms);
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

    /// Under the listener lease, take one ready socket. A peer can disappear
    /// between readiness and accept. The caller then has no stream to claim.
    pub fn acceptStream(self: *Gate, io: std.Io, server: *std.Io.net.Server, mode: AcceptMode) AcceptError!socket.ReadyAccept {
        const fd = server.socket.handle;
        if (mode == .wait) {
            if (!try self.waitReadable(fd, -1)) return .would_block;
        } else {
            try self.wake_failure.check();
            if (self.stopping.load(.acquire)) return error.ConnectionLost;
            if (!self.nonblocking) {
                if (!socket.setNonblocking(fd)) return error.ConnectionLost;
                self.nonblocking = true;
            }
        }
        return socket.acceptQueued(io, fd);
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

    /// Whether an accept or readiness wait holds the operation lease. A wait
    /// takes the lease before it reads `stopping`, so a `shutdown` after this
    /// reads true reaches that wait, at its check or through the nudge. Tests
    /// read it to close under a held wait. It reads the lease the gate
    /// already keeps, so the wait path pays nothing for it.
    pub fn leaseHeld(self: *Gate, io: std.Io) bool {
        if (!self.operation_gate.tryLock()) return true;
        self.operation_gate.unlock(io);
        return false;
    }

    /// The first wake fault this gate latched, for the close barrier's report.
    pub fn failure(self: *const Gate) ?wake_channel.Failure {
        return self.wake_failure.failure();
    }
};
