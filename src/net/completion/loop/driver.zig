//! Completion-batch driver and loop-global dispatch ordering.
//!
//! One poll turn settles adapter work and owed retirement before sizing the
//! wait, consumes every earned completion exactly once, repairs buffer/deadline
//! ordering, then surfaces the first loop-global failure. Public driver methods
//! are direct aliases on Loop. This module owns no runtime object.

const std = @import("std");
const clock = @import("../../clock.zig");
const contract = @import("../contract.zig");
const failure_projection = @import("../failure_projection.zig");
const configuration = @import("configuration.zig");
const state = @import("state.zig");
const affinity = @import("affinity.zig");
const deadline_math = @import("connections/deadlines.zig");

pub fn Machine(
    comptime Self: type,
    comptime Deadlines: type,
    comptime Lifecycle: type,
    comptime Flow: type,
    comptime Admission: type,
    comptime Wake: type,
) type {
    return struct {
        const Completion = contract.Completion;
        const Stop = configuration.Stop;

        /// One turn of the loop: settle deferred work, wait, dispatch, sweep.
        ///
        /// The three drivers (`run`, `runUntil`, `closeAndDrain`) differ only
        /// in when they stop and whether the caller has a deadline of its own,
        /// so the body lives here once. Three copies means a fix can land in one
        /// and not the others, and what goes missing that way is a sweep no
        /// driver announces it is skipping.
        ///
        /// The order matters. Deferred work is drained *before* the
        /// wait is sized, because draining it can create the deadline the wait
        /// must not sleep through. `caller_deadline_ms` is the driver's own
        /// bound, or null for "wait as long as the connections allow".
        pub fn pollOnce(self: *Self, caller_deadline_ms: ?i32) !void {
            // Per-poll batch cap, independent of
            // `BackendOptions.queue_entries`: a deeper completion queue drains across
            // more polls, while the fixed stack batch keeps this
            // allocation-free.
            const poll_batch = 256;
            var completions: [poll_batch]Completion = undefined;

            Flow.drainFanInDirty(self);
            // Owed closes are this loop's own work, not the backend's, so they
            // run before the wait rather than after it. On a backend whose
            // `shutdownFd` cannot cancel, iroh's is a documented no-op, the
            // ops these closes retire are the only reason some connections
            // ever complete, and sleeping first can mean sleeping on them.
            try Lifecycle.retryPendingCloses(self);
            try Lifecycle.retryListenerClose(self);
            var wake_cancel_refusal: ?anyerror = null;
            if (self.shutting_down) {
                Wake.retryWakeCancel(self) catch |err| {
                    wake_cancel_refusal = err;
                };
            } else {
                try Wake.retryWakeRearm(self);
            }

            // One adapter turn per loop turn. A continuation asks only for a
            // zero-time poll, not another callback in this stack frame, so
            // ready network completions remain interleaved with adapter work.
            const adapter_ran = if (!self.shutting_down) blk: {
                const on_loop_turn = self.on_loop_turn orelse break :blk false;
                break :blk try on_loop_turn(self.make_ctx);
            } else false;

            // Wake for whichever comes first: the caller's own deadline or the
            // nearest connection deadline the reaper below enforces.
            var timeout: i32 = if (Deadlines.nextDeadlineMs(self)) |conn_due|
                (if (caller_deadline_ms) |caller| @min(caller, conn_due) else conn_due)
            else
                (caller_deadline_ms orelse -1);
            // Still owed one: the backend could not admit it, which is an
            // allocation failure and therefore transient. Bound the wait so
            // the retry above comes round again, instead of parking on a
            // completion that cannot arrive until it does.
            if (self.pending_close_submits != 0 or
                (self.listener_close_fd != null and !self.listener_close_pending) or
                self.wake_rearm_pending or
                self.wake_cancel_submit_pending)
            {
                timeout = if (timeout < 0) state.close_retry_ms else @min(timeout, state.close_retry_ms);
            }
            if (adapter_ran) timeout = 0;

            const n = try self.backend.poll(&completions, timeout);
            // A backend that reports more than it was given would have the
            // sweeps below read past the batch. The contract says "up to
            // `out.len`"; this is where that is consumed, so this is where it
            // is checked.
            std.debug.assert(n <= completions.len);
            // Held, not propagated yet. The three sweeps below repair what the status-allow: pending state or quoted runtime label
            // batch left behind, a connection parked buffer-starved after its
            // recycle already ran, a deadline that came due, and a dispatch
            // failure is loop-global, so for some of those connections this is
            // the last turn there is.
            const dispatched = dispatchBatch(self, completions[0..n]);
            // Every pool buffer this batch carried has been recycled, so re-arm
            // whatever parked buffer-starved during the batch. A starved
            // completion can be dispatched after the recycle that should have
            // resumed it; this sweep closes that ordering gap.
            Flow.resumeStarved(self, .all);
            Lifecycle.reapDeadlines(self);
            Flow.drainFanInDirty(self);
            // A refused wake cancel may race the target recv already becoming
            // ready. Dispatch that completion before returning the refusal so
            // shutdown can still make progress and a retry can finish safely.
            // The refusal remains observable even when the race made the
            // cancellation unnecessary.
            if (wake_cancel_refusal) |err| return err;
            try dispatched;
        }

        /// Run the loop until `stop` says to return: `.forever` for a
        /// production server or dialer, `.{ .after_closed = n }` to return once
        /// `n` connections have been fully served and closed (the test-shaped
        /// stop condition). Per-connection failures close only their
        /// connection. The errors that escape here are loop-global, namely a
        /// backend poll failure, listener accept failure, or listener accept
        /// re-arm failure.
        pub fn run(self: *Self, stop: Stop) !void {
            const claimed = affinity.latch(self);
            if (comptime std.debug.runtime_safety) std.debug.assert(claimed);
            defer affinity.release(self);
            try Admission.ensureAccepting(self);
            while (switch (stop) {
                .forever => true,
                .after_closed => |n| self.closed_count < n,
            }) try pollOnce(self, null);
        }

        /// Drive the loop until `done` is true. Same poll/dispatch body as
        /// `run` until the flag a Host vow callback (or peer teardown) sets.
        /// Call from the loop-owner thread, the same affinity as `dial`.
        ///
        /// `deadline_ms` bounds wall-clock wait time from the first poll:
        /// `0` is unbounded (prior behavior). A positive value polls with the
        /// remaining milliseconds and returns `error.Timeout` if the deadline
        /// elapses while `done` is still false, the same contract as
        /// `Connection.runUntil`.
        ///
        /// If `done` is set from another thread, that thread must also wake
        /// this loop's `poll`: nudge the armed wake channel (`armWake`. A
        /// `driver.SettleMailbox.wake` is the sanctioned entry), call a
        /// userspace backend's explicit stopper wake when it exposes one, or,
        /// on a listening loop with no wake armed, a connect-and-drop against
        /// the bound port. A flag set from a serve/vow callback on this thread
        /// needs no wake, the next loop iteration sees it.
        ///
        /// After return, slots may still hold armed recvs. Call `closeAndDrain`
        /// before `deinit`.
        pub fn runUntil(self: *Self, done: *const std.atomic.Value(bool), deadline_ms: i32) !void {
            const claimed = affinity.latch(self);
            if (comptime std.debug.runtime_safety) std.debug.assert(claimed);
            defer affinity.release(self);
            try Admission.ensureAccepting(self);
            const deadline_start: ?i64 = if (deadline_ms > 0) clock.nowMonotonicMs() else null;
            while (!done.load(.acquire)) {
                const caller_timeout: ?i32 = if (deadline_start) |start| blk: {
                    const elapsed = clock.nowMonotonicMs() - start;
                    break :blk try deadline_math.remainingCallerTimeout(deadline_ms, elapsed);
                } else null;
                try pollOnce(self, caller_timeout);
            }
            // closeAndDrain is separate: callers that need a clean deinit invoke
            // it after runUntil (same thread), once CapTP work is done.
        }

        /// Close every open connection and the listen handle, then poll until
        /// every slot is free. After this returns, `deinit` is safe: no armed
        /// recv can hang the drain because each close retires pending ops
        /// (Backend contract). Call from the loop-owner thread, typically
        /// after `runUntil` returns, or after an early `run` return that left
        /// slots live.
        pub fn closeAndDrain(self: *Self) !void {
            const claimed = affinity.latch(self);
            if (comptime std.debug.runtime_safety) std.debug.assert(claimed);
            defer affinity.release(self);
            // The close sweep below is idempotent, it touches only `.open` and
            // `.draining` slots, so a drain that failed part-way can be
            // retried. Returning early on the second call instead left the
            // caller no way to finish, and `deinit` then asserts on the ops
            // still in flight, or in a release build frees an outbound buffer
            // the backend is still writing from.
            const first = !self.shutting_down;
            self.shutting_down = true;
            // Do not set tearing_down yet: closeConn must still submitClose. status-allow: pending state or quoted runtime label
            // freeConnCtx skips drainActions while shutting_down.

            // Cancel a pending accept and close the listen handle first so the
            // drain poll cannot block forever on an idle acceptor. Null the
            // field before submit so `deinit` does not double-close; Backends
            // must yield an accept completion (result < 0) when one was armed.
            if (first) {
                // A queued re-arm owns no backend operation, so retiring it is
                // immediate. An admitted recv does own one and must be canceled
                // explicitly: the wake fd belongs to the mailbox, not this loop.
                self.wake_rearm_pending = false;
                if (self.wake_armed) {
                    self.wake_cancel_submit_pending = true;
                } else {
                    self.wake = null;
                }
                if (self.listen_fd) |fd| {
                    self.listen_fd = null;
                    self.listener_close_fd = fd;
                    // Listener submitClose owns both cancellation of the armed
                    // accept and descriptor release. shutdown is still useful
                    // to readiness backends, but io_uring cancels the exact
                    // accept request because shutdown(2) on a listening socket
                    // is not a portable cancellation mechanism.
                    self.backend.shutdownFd(fd);
                }
            }

            for (self.conns, 0..) |*c, slot| {
                // Hard close: skip the abort flush. `closeConn` owns shutdown
                // and close submission together on every terminal path.
                if (c.state == .open or c.state == .draining) {
                    Lifecycle.closeConn(self, slot, c);
                }
            }

            // The two sweeps `pollOnce` adds are provable no-ops here:
            // `drainFanInDirty` returns on `shutting_down`, and every stamp is
            // cleared by `closeConn`, so the reaper finds nothing.
            // The listener close and the canceled accept are distinct backend
            // operations and may complete in either order. Keep polling until
            // both retire; clearing accept_armed at submit time can otherwise
            // leave a late accept completion queued past deinit.
            while (anyBusy(self) or self.listener_close_fd != null or self.accept_armed or
                self.wake_armed or self.wake_cancel_submit_pending or self.wake_cancel_pending)
                try pollOnce(self, null);
            self.wake = null;
        }

        /// Dispatch every completion in a batch, then surface the first
        /// error.
        ///
        /// `try` inside the loop would abandon the completions behind the
        /// failing one. Each of those is the only chance to retire its op and,
        /// for a recv, to recycle its pooled buffer: dropping them leaves
        /// `ops_in_flight` above zero, so `closeAndDrain` waits on work that
        /// can never complete and `deinit` trips its in-flight assertion. The
        /// batch is consumed exactly once, whatever any one completion does.
        pub fn dispatchBatch(self: *Self, batch: []const Completion) !void {
            var first_err: ?anyerror = null;
            for (batch) |c| dispatch(self, c) catch |err| {
                if (first_err == null) first_err = err;
            };
            if (first_err) |err| return err;
        }

        pub fn anyBusy(self: *const Self) bool {
            return self.live_count != 0;
        }

        pub fn dispatch(self: *Self, comp: Completion) !void {
            const slot = state.slotOf(comp.user_data);
            switch (state.opOf(comp.user_data)) {
                // The out-of-band wake (ADR-0014): recycle the pool buffer
                // that carried the nudge bytes, run the armed handler on this
                // owning thread, and re-arm. No slot belongs to it.
                .wake => {
                    std.debug.assert(self.wake_armed);
                    self.wake_armed = false;
                    if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                    // Shutdown owns no callbacks and no new recv submissions.
                    // The separate cancel completion may arrive before or after
                    // this target completion, so each retires only its own seat.
                    if (self.shutting_down) {
                        // If cancellation was still being refused, the target
                        // completed naturally and there is no cancel operation
                        // left to submit or drain.
                        self.wake_cancel_submit_pending = false;
                        return;
                    }
                    // A momentarily empty buffer pool completes a recv with
                    // no data and a negative result, which is transient
                    // pressure and not a closed channel. The connection arm
                    // parks and re-arms for exactly this; the wake must too,
                    // or one starved poll deafens it for the loop's life.
                    if (comp.recv_no_buffer) {
                        self.wake_rearm_pending = true;
                    } else {
                        try Wake.onWakeCompletion(self, comp.result);
                    }
                },
                .wake_cancel => {
                    std.debug.assert(self.wake_cancel_pending);
                    self.wake_cancel_pending = false;
                    if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                },
                // The only handler that may fail the loop: an accept operation
                // or dead re-arm is loop-global. Every per-connection handler
                // resolves its own failures by closing that one connection.
                .accept => {
                    defer if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                    try Admission.onAccept(self, comp);
                },
                .connect => {
                    Admission.onConnect(self, slot, comp);
                    if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                    Lifecycle.retireConnOp(self, slot);
                },
                // Each per-connection op decrements its in-flight count after the
                // handler runs; the last one on a closing connection reclaims it.
                .recv => {
                    // Consume the borrowed pool bytes, recycle the buffer,
                    // exactly once per completion that carried one, on every
                    // verdict, then act on the verdict.
                    const verdict = Flow.onRecvConsume(self, slot, comp);
                    if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                    Flow.onRecvFinish(self, slot, verdict);
                    Lifecycle.retireConnOp(self, slot);
                },
                .send => {
                    Flow.onSend(self, slot, comp);
                    if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                    Lifecycle.retireConnOp(self, slot);
                },
                .close => {
                    // close(2) releases the descriptor whatever it reports, so
                    // a failure is recorded and never retried against a number
                    // the kernel may already have reissued.
                    if (comp.result < 0 and slot < self.conns.len) {
                        failure_projection.record(&self.conns[slot].peer, comp, error.CloseFailed);
                    }
                    if (slot == self.conns.len) {
                        self.listener_close_pending = false;
                        self.listener_close_fd = null;
                    }
                    if (comp.borrowed.active()) Flow.recycleBorrowedPayload(self, comp);
                    Lifecycle.retireConnOp(self, slot);
                },
            }
        }
    };
}
