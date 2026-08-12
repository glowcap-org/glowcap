//! Ownership for blocking adapter operations that must be cancelable by a
//! parent handle on another thread.
//!
//! `std.Io.Group` supplies structured cancellation, but `Group.cancel` joins its
//! tasks. A foreign runtime must request that cancellation without parking its
//! reactor. Cancellation capacity is therefore reserved when the owner is
//! created: one worker waits for shutdown, then performs the cancel-and-join.
//! A raw thread is deliberate here: `std.Io.Group.async` is allowed to execute
//! eagerly under resource pressure, which would park construction on the wait.
//! `join` is the release barrier: after it returns no admitted task can still
//! touch the parent or its `std.Io` backend.

const std = @import("std");

const Io = std.Io;

pub const OperationOwner = struct {
    const closing_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const admission_mask = closing_bit - 1;

    io: Io,
    group: Io.Group = .init,
    /// High bit seals admission; low bits count callers between admission and
    /// `Group.concurrent`. Shutdown sets the high bit without waiting. The
    /// cancellation worker waits for the low bits to drain before canceling the
    /// group, so a racing start is either included or refused, never stranded.
    admission: std.atomic.Value(usize) = .init(0),
    cancel_thread: ?std.Thread = null,
    cancel_ready: Io.Semaphore = .{ .permits = 0 },
    admission_drained: Io.Semaphore = .{ .permits = 0 },

    /// Initialize at the owner's final address. Reserving the cancellation
    /// worker here makes `shutdown` infallibly nonblocking later; callers must
    /// refuse construction if concurrency is unavailable. This is one worker
    /// per blocking operation owner, not per connection or session.
    pub fn init(self: *OperationOwner, io: Io) error{ConcurrencyUnavailable}!void {
        self.* = .{ .io = io };
        self.cancel_thread = std.Thread.spawn(.{}, cancelWorker, .{self}) catch
            return error.ConcurrencyUnavailable;
    }

    /// Admit one task while the owner is open. The task's arguments must remain
    /// alive until its own completion signal fires.
    pub fn start(
        self: *OperationOwner,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) error{ Closing, ConcurrencyUnavailable }!void {
        var state = self.admission.load(.acquire);
        while (true) {
            if (state & closing_bit != 0) return error.Closing;
            std.debug.assert(state & admission_mask != admission_mask);
            if (self.admission.cmpxchgWeak(state, state + 1, .acquire, .monotonic)) |observed| {
                state = observed;
                continue;
            }
            break;
        }
        defer self.releaseAdmission();
        try self.group.concurrent(self.io, function, args);
    }

    /// Seal admission and request cancellation without waiting on the caller's
    /// thread. Idempotent, lock-free, and allocation-free: the worker was reserved
    /// by `init`, so resource pressure or a racing admission cannot turn
    /// shutdown into a synchronous group join.
    pub fn shutdown(self: *OperationOwner) void {
        const previous = self.admission.fetchOr(closing_bit, .acq_rel);
        if (previous & closing_bit != 0) return;
        self.cancel_ready.post(self.io);
    }

    /// Complete shutdown and join every admitted task. Call exactly once before
    /// releasing the owner storage or the `Io` implementation it borrows.
    pub fn join(self: *OperationOwner) void {
        self.shutdown();
        if (self.cancel_thread) |thread| {
            thread.join();
            self.cancel_thread = null;
        }
    }

    fn releaseAdmission(self: *OperationOwner) void {
        const previous = self.admission.fetchSub(1, .release);
        std.debug.assert(previous & admission_mask != 0);
        if (previous == closing_bit | 1) self.admission_drained.post(self.io);
    }

    fn cancelWorker(self: *OperationOwner) void {
        self.cancel_ready.waitUncancelable(self.io);
        if (self.admission.load(.acquire) & admission_mask != 0)
            self.admission_drained.waitUncancelable(self.io);
        self.group.cancel(self.io);
    }
};

/// One task-to-caller completion edge. Result fields written before `signal`
/// are visible after `wait`; the task and caller may use different OS threads.
pub const OperationLatch = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    finished: bool = false,

    pub fn signal(self: *OperationLatch, io: Io) void {
        self.mutex.lockUncancelable(io);
        self.finished = true;
        self.condition.signal(io);
        self.mutex.unlock(io);
    }

    pub fn wait(self: *OperationLatch, io: Io) void {
        self.mutex.lockUncancelable(io);
        while (!self.finished) self.condition.waitUncancelable(io, &self.mutex);
        self.mutex.unlock(io);
    }
};
