//! Connection wait and backpressure deadline accounting.
//!
//! Every stamp, waiter count, over-high-water edge, and nearest-due cache is
//! written here. The close sweep remains in lifecycle so this accounting owner
//! never acquires descriptor or slot-retirement authority.

const std = @import("std");

/// Add an unsigned policy duration to the signed monotonic-clock domain.
/// Durations beyond the representable clock horizon wait until that horizon.
/// They never fire earlier and never trap while narrowing a valid option.
pub fn dueAt(stamp: i64, delay_ms: u64) i64 {
    std.debug.assert(stamp >= 0);
    const remaining: u64 = @intCast(std.math.maxInt(i64) - stamp);
    if (delay_ms >= remaining) return std.math.maxInt(i64);
    return stamp + @as(i64, @intCast(delay_ms));
}

/// Return the still-representable caller timeout, or Timeout once elapsed.
/// Expiry is decided in i64 before narrowing, so the longest i32 deadline can
/// never turn into a safety trap after it has already elapsed.
pub fn remainingCallerTimeout(deadline_ms: i32, elapsed_ms: i64) error{Timeout}!i32 {
    std.debug.assert(deadline_ms > 0);
    if (elapsed_ms >= @as(i64, deadline_ms)) return error.Timeout;
    return @intCast(@as(i64, deadline_ms) - @max(elapsed_ms, 0));
}

pub fn Machine(
    comptime Self: type,
    comptime CloseReason: type,
    comptime State: type,
    comptime Clock: type,
) type {
    return struct {
        const Conn = std.meta.Child(@FieldType(Self, "conns"));
        const Deadline = struct { due: i64, reason: CloseReason };

        pub fn pendingDeadline(self: *const Self, c: *const Conn) ?Deadline {
            const limit, const reason: CloseReason = switch (c.state) {
                .open => .{ self.park_kill_ms orelse return null, .park_kill },
                .draining => .{ self.drain_kill_ms orelse return null, .drain_kill },
                .free, .closing => return null,
            };
            if (c.waiting_since_ms == 0) return null;
            return .{ .due = dueAt(c.waiting_since_ms, limit), .reason = reason };
        }

        /// The one writer of `Conn.waiting_since_ms`, so `waiting_count` cannot
        /// drift from the number of stamped connections. Pass `0` for "not
        /// waiting".
        pub fn setWaiting(self: *Self, c: *Conn, stamp: i64) void {
            if ((c.waiting_since_ms == 0) != (stamp == 0)) {
                if (stamp == 0) self.waiting_count -= 1 else self.waiting_count += 1;
            }
            c.waiting_since_ms = stamp;
            // Folding a new deadline in is one comparison. A cleared one is
            // left in the cache: a stale entry can only make the
            // loop wake early, which costs a poll, while dropping one late
            // would miss a reap. `reapDeadlines` recomputes after any wake
            // that closes nothing.
            if (stamp != 0) {
                if (self.earliest_due_ms) |cached| {
                    const limit = limitFor(self, c) orelse return;
                    const due = dueAt(stamp, limit);
                    if (due < cached) self.earliest_due_ms = due;
                }
            }
        }

        /// The deadline this connection's state answers to, or null when its
        /// state has none configured.
        pub fn limitFor(self: *const Self, c: *const Conn) ?u64 {
            return switch (c.state) {
                .open => self.park_kill_ms,
                .draining => self.drain_kill_ms,
                .free, .closing => null,
            };
        }

        /// Recount this connection's contribution to `over_mark_count`.
        ///
        /// Edge-triggered, one owner, one comparison. Asking the question by
        /// walking every slot would put the `O(max_conns)` shape the deadline
        /// cache exists to avoid onto a path that runs once per armed read. The
        /// queue depth already funnels through this refresh, so the count can
        /// be maintained here instead.
        pub fn refreshOverMark(self: *Self, c: *Conn) void {
            const over = switch (c.state) {
                .open, .draining => State.pendingOut(c) > self.outbound_high_water_bytes,
                .free, .closing => false,
            };
            if (over == c.over_mark) return;
            c.over_mark = over;
            if (over) {
                self.over_mark_count += 1;
                return;
            }
            self.over_mark_count -= 1;
            // The last sink just came back under the mark, and the sources it
            // was throttling have no other resume trigger. Recorded here
            // because this is the one place that knows the *transition*. Asking
            // from the send paths instead means asking on every completed
            // write, and the answer is no in the healthy steady state, so each
            // reply would pay a walk to re-arm nothing. Recorded rather than
            // performed, for the reasons `drainFanInDirty` gives.
            if (self.fan_in_throttle and self.over_mark_count == 0) self.fan_in_dirty = true;
        }

        /// Recompute whether this connection is waiting on a deadline, and
        /// stamp or clear to match.
        ///
        /// Eligibility is owned by mutation, not read back from live state at
        /// reap time: every input, the read seat, the queue depth, the
        /// connection state, calls here when it changes. That is what lets
        /// the nearest-deadline cache be trusted, and it is what gives a
        /// fan-in victim its full grace: a connection that was somebody else's
        /// victim is stamped when it becomes a slow reader in its own right,
        /// not when it first parked.
        pub fn refreshWaiting(self: *Self, c: *Conn) void {
            refreshOverMark(self, c);
            const eligible = switch (c.state) {
                // Over the mark is the condition, not the seat. What throttles
                // every other connection is `over_mark_count`, and that is set
                // from the queue depth alone, `armOutbound` and `onSend`'s
                // drive both push a connection past the mark while its own recv
                // is still armed. Requiring `.parked` here meant such a
                // connection throttled the whole loop and carried no deadline,
                // so `waiting_count` stayed zero, the poll waited forever, and
                // nothing could arrive to end it. `refreshOverMark` ran one
                // line above, so this is fresh.
                .open => c.over_mark and self.park_kill_ms != null,
                .draining => self.drain_kill_ms != null,
                .free, .closing => false,
            };
            const is_drain = c.state == .draining;
            if (!eligible) {
                if (c.waiting_since_ms != 0) setWaiting(self, c, 0);
                return;
            }
            // Already waiting on the same question: leave the clock running.
            if (c.waiting_since_ms != 0 and c.waiting_is_drain == is_drain) return;
            // Either not waiting, or waiting on a different question than the
            // stamp was taken for. A park stamp carried into `.draining` would
            // be measured against `drain_kill_ms`, cutting the terminal flush
            // short by however long the connection had already been parked.
            setWaiting(self, c, 0);
            setWaiting(self, c, Clock.nowMonotonicMs());
            c.waiting_is_drain = is_drain;
        }

        /// Milliseconds until the nearest connection deadline, or null when
        /// none is pending. A deadline checked only after `poll` cannot fire
        /// on a quiet loop, so every enforced deadline is visible to the wait.
        pub fn nextDeadlineMs(self: *Self) ?i32 {
            const due = earliestDue(self) orelse return null;
            const remaining = due - Clock.nowMonotonicMs();
            return if (remaining <= 0) 0 else @intCast(@min(remaining, std.math.maxInt(i32)));
        }

        /// The nearest deadline, from the cache when it holds one.
        ///
        /// Zero waiters costs nothing, and one waiter costs a comparison
        /// rather than a walk of every slot. That difference is the whole
        /// point at the 500k destination, where a table walk before each poll
        /// and again after each batch is a million cold slot reads bought by
        /// one stalled partner.
        pub fn earliestDue(self: *Self) ?i64 {
            if (self.waiting_count == 0) {
                self.earliest_due_ms = null;
                return null;
            }
            if (self.earliest_due_ms) |due| return due;
            var earliest: ?i64 = null;
            for (self.conns) |*c| {
                const deadline = pendingDeadline(self, c) orelse continue;
                if (earliest == null or deadline.due < earliest.?) earliest = deadline.due;
            }
            // A stamped connection that yields no deadline would send this
            // walk over every slot on each poll, the cost this cache exists
            // to avoid, and silent, because nothing observable changes.
            std.debug.assert(earliest != null);
            self.earliest_due_ms = earliest;
            return earliest;
        }
    };
}
