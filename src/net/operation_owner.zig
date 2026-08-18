//! Ownership for blocking adapter operations that must be cancelable by a
//! parent handle on another thread.
//!
//! `std.Io.Group` supplies structured cancellation, but `Group.cancel` joins its
//! tasks. A foreign runtime must request that cancellation without parking its
//! reactor. Cancellation capacity is therefore reserved when the owner is
//! created: one worker drains per-operation reap/cancel requests and performs
//! the final cancel-and-join at shutdown.
//! A raw thread is deliberate here: `std.Io.Group.async` is allowed to execute
//! eagerly under resource pressure, which would park construction on the wait.
//! `join` is the release barrier: after it returns no admitted task can still
//! touch the parent or its `std.Io` backend.

const std = @import("std");

const Io = std.Io;
const SpinLock = @import("sync.zig").SpinLock;

pub const OperationOwner = struct {
    const closing_bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const admission_mask = closing_bit - 1;

    io: Io,
    group: Io.Group = .init,
    /// High bit seals admission; low bits count callers between admission and
    /// `Group.concurrent`. Shutdown sets the high bit without waiting. The
    /// cancellation worker repeatedly cancels registered operations while the
    /// low bits drain, so a racing start is either included or refused, never
    /// stranded. Canceling first is load-bearing because `Group.concurrent`
    /// may run a blocking operation inline under resource pressure.
    admission: std.atomic.Value(usize) = .init(0),
    cancel_thread: ?std.Thread = null,
    cancel_ready: Io.Semaphore = .{ .permits = 0 },
    operation_mutex: SpinLock = .{},
    active_operations: ?*CancelableOperation = null,
    queued_head: ?*CancelableOperation = null,
    queued_tail: ?*CancelableOperation = null,

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
        try self.acquireAdmission();
        defer self.releaseAdmission();
        try self.group.concurrent(self.io, function, args);
    }

    /// Start one independently cancelable blocking operation. `operation` and
    /// `context` must remain alive until `retire` runs. Normal claim queues an
    /// await; cancellation queues a targeted `Group.cancel`, both on the
    /// owner's reserved worker so the caller never joins blocking I/O.
    pub fn startCancelable(
        self: *OperationOwner,
        operation: *CancelableOperation,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
        context: *anyopaque,
        retire: *const fn (*anyopaque) void,
    ) error{ Closing, ConcurrencyUnavailable }!void {
        try self.acquireAdmission();
        defer self.releaseAdmission();

        operation.* = .{
            .owner = self,
            .context = context,
            .retire_fn = retire,
        };
        self.operation_mutex.lock();
        operation.active_next = self.active_operations;
        self.active_operations = operation;
        self.operation_mutex.unlock();

        operation.group.concurrent(self.io, function, args) catch |err| {
            self.removeActiveOperation(operation);
            operation.* = undefined;
            return err;
        };
    }

    /// Queue normal retirement. False means no new queue entry was created:
    /// shutdown or another path already owns retirement, or this is not the
    /// operation's owner. A duplicate request is therefore an idempotent
    /// handoff rather than a process-fatal assertion.
    pub fn reap(self: *OperationOwner, operation: *CancelableOperation) bool {
        return self.queueOperation(operation, .reap);
    }

    /// Queue cancellation and retirement. False has the same already-owned
    /// meaning as `reap`; the operation still retires exactly once.
    pub fn cancel(self: *OperationOwner, operation: *CancelableOperation) bool {
        return self.queueOperation(operation, .cancel);
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
    }

    fn cancelWorker(self: *OperationOwner) void {
        while (true) {
            self.cancel_ready.waitUncancelable(self.io);
            const closing = self.admission.load(.acquire) & closing_bit != 0;
            if (closing) self.queueAllActiveForCancellation();
            self.drainOperationQueue();
            if (!closing) continue;

            // Cancel first, then wait out admission. Under resource pressure
            // `Group.concurrent` runs a blocking operation inline, so an
            // admission window lasts as long as its operation and only the
            // sweep above can end it: waiting for the window before issuing
            // the cancels deadlocked on exactly the caller the wait was for.
            // The remaining spin covers one racer's acquire-to-register
            // moment, and each pass re-sweeps so a registration that landed
            // after the previous sweep is taken rather than waited on.
            while (self.admission.load(.acquire) & admission_mask != 0) {
                self.queueAllActiveForCancellation();
                self.drainOperationQueue();
                // This is the acquire-to-register window only. A CPU hint is
                // infallible and avoids turning scheduler refusal into an
                // unreportable cancellation-worker failure.
                std.atomic.spinLoopHint();
            }
            self.queueAllActiveForCancellation();
            self.drainOperationQueue();

            self.operation_mutex.lock();
            const active = self.active_operations;
            self.operation_mutex.unlock();
            std.debug.assert(active == null);
            self.group.cancel(self.io);
            return;
        }
    }

    fn acquireAdmission(self: *OperationOwner) error{ Closing, ConcurrencyUnavailable }!void {
        var state = self.admission.load(.acquire);
        while (true) {
            if (state & closing_bit != 0) return error.Closing;
            if (state & admission_mask == admission_mask)
                return error.ConcurrencyUnavailable;
            if (self.admission.cmpxchgWeak(state, state + 1, .acquire, .monotonic)) |observed| {
                state = observed;
                continue;
            }
            return;
        }
    }

    fn queueOperation(self: *OperationOwner, operation: *CancelableOperation, disposition: CancelableOperation.Disposition) bool {
        self.operation_mutex.lock();
        if (operation.owner != self or operation.queued) {
            self.operation_mutex.unlock();
            return false;
        }
        operation.queued = true;
        operation.disposition = disposition;
        operation.queue_next = null;
        if (self.queued_tail) |tail| tail.queue_next = operation else self.queued_head = operation;
        self.queued_tail = operation;
        self.operation_mutex.unlock();
        self.cancel_ready.post(self.io);
        return true;
    }

    fn queueAllActiveForCancellation(self: *OperationOwner) void {
        self.operation_mutex.lock();
        var current = self.active_operations;
        while (current) |operation| : (current = operation.active_next) {
            if (operation.queued) continue;
            operation.queued = true;
            operation.disposition = .cancel;
            operation.queue_next = null;
            if (self.queued_tail) |tail| tail.queue_next = operation else self.queued_head = operation;
            self.queued_tail = operation;
        }
        self.operation_mutex.unlock();
    }

    fn drainOperationQueue(self: *OperationOwner) void {
        while (true) {
            self.operation_mutex.lock();
            const operation = self.queued_head orelse {
                self.queued_tail = null;
                self.operation_mutex.unlock();
                return;
            };
            self.queued_head = operation.queue_next;
            if (self.queued_head == null) self.queued_tail = null;
            self.operation_mutex.unlock();

            switch (operation.disposition) {
                // Shutdown may cancel a task just before its normal reap is
                // queued. `Canceled` still means the group joined and its
                // resources are gone; it is the one typed successful cleanup
                // outcome, not an erased arbitrary failure.
                .reap => operation.group.await(self.io) catch |err| switch (err) {
                    error.Canceled => {},
                },
                .cancel => operation.group.cancel(self.io),
            }
            const context = operation.context;
            const retire = operation.retire_fn;
            self.removeActiveOperation(operation);
            retire(context);
        }
    }

    fn removeActiveOperation(self: *OperationOwner, operation: *CancelableOperation) void {
        self.operation_mutex.lock();
        defer self.operation_mutex.unlock();
        var link = &self.active_operations;
        while (link.*) |candidate| {
            if (candidate == operation) {
                link.* = candidate.active_next;
                return;
            }
            link = &candidate.active_next;
        }
        unreachable;
    }
};

/// Intrusive task ownership embedded in an attempt. It adds no heap allocation;
/// the provider's one `OperationOwner` worker reaps or cancels it.
pub const CancelableOperation = struct {
    owner: *OperationOwner,
    group: Io.Group = .init,
    context: *anyopaque,
    retire_fn: *const fn (*anyopaque) void,
    active_next: ?*CancelableOperation = null,
    queue_next: ?*CancelableOperation = null,
    queued: bool = false,
    disposition: Disposition = .reap,

    const Disposition = enum { reap, cancel };
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
