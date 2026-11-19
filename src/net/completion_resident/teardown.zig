//! The ends of a `net.completion_resident`: one connection's close and
//! abort, and the drain that closes what the runtime left open and retires
//! every operation the backend still owes before any staging it borrows is
//! freed.

const std = @import("std");

const completion = @import("../completion/loop.zig");
const failures = @import("failures.zig");
const completions = @import("completions.zig");
const carrier_failure = @import("../carrier_failure.zig");
const foundation = @import("foundation");
const resident_mod = @import("../multiplexed_resident.zig");

const TeardownOutcome = resident_mod.TeardownOutcome;
const userData = completions.userData;

pub fn Machine(comptime Self: type) type {
    return struct {
        const Completions = completions.Machine(Self);

        /// The runtime's claim on connection `id` ends here. The row lives
        /// on, out of reach of every verb, until the backend retires the
        /// operations that borrow its staging.
        ///
        /// `awaited` on a connection that holds a close seat keeps the
        /// provider's close open until its result is claimed by the next
        /// `awaited` call, which then returns it by value. `no_wait` hands
        /// the provider close to its own sink.
        pub fn connClose(self: *Self, id: usize, mode: resident_mod.CloseMode) TeardownOutcome {
            defer Completions.pump(self);
            const conn = self.conns.getPtr(id) orelse return .complete;
            if (conn.close == .closing) return closingOutcome(self, id, conn, mode);
            if (conn.close == .open) {
                // The caller has taken its live snapshot. Nothing more
                // reads this wire, even during the first close's reap.
                conn.close = .draining;
                releaseRecv(self, id, conn);
            }
            // Readiness backends perform sends when polled, not when submitted.
            // Keep the socket open until every admitted byte has completed.
            if (conn.send == .queued) conn.send = .idle;
            Completions.startSend(self, id, conn);
            Completions.submitQueued(self);
            Completions.reap(self, if (mode == .awaited) conn else null);
            // A failed send owes no bytes. A refused later append still
            // leaves the earlier prefix to drain.
            if (conn.send == .armed or conn.front.items.len != conn.sent or conn.back.items.len != 0) {
                conn.owes_writable = true;
                return .pending;
            }
            return shutConn(self, id, conn, mode);
        }

        /// Drop connection `id` now, whatever `connClose` was still sending.
        /// `mode` names who receives a result that is already claimable: the
        /// caller, or the provider's sink when the wire was detached.
        pub fn connAbort(self: *Self, id: usize, mode: resident_mod.CloseMode) TeardownOutcome {
            defer Completions.pump(self);
            const conn = self.conns.getPtr(id) orelse return .complete;
            if (conn.close == .closing) {
                // An abort delivers a result that is ready to `mode`'s
                // recipient and otherwise gives up the wait: it never reports
                // pending. A held close the caller stops awaiting still
                // reports the write that failed while it drained. A claimable
                // result is claimed by `closingOutcome` itself.
                const fresh = if (mode == .awaited and conn.close_wait != .claimable) takeFreshWrite(self, id, conn) else null;
                return withFresh(fresh, closingOutcome(self, id, conn, if (conn.close_wait == .claimable) mode else .no_wait));
            }
            if (conn.send == .queued) conn.send = .idle;
            const fresh = if (mode == .awaited) takeFreshWrite(self, id, conn) else null;
            releaseRecv(self, id, conn);
            return withFresh(fresh, shutConn(self, id, conn, .no_wait));
        }

        /// A second close call on a closing row. An awaiting caller sees
        /// `pending` until the backend reports the provider handle quiet,
        /// then receives its close result and the row is released. A caller
        /// that stopped waiting hands the provider close to its own sink.
        fn closingOutcome(self: *Self, id: usize, conn: *Self.Conn, mode: resident_mod.CloseMode) TeardownOutcome {
            switch (conn.close_wait) {
                .none => return .complete,
                .awaited => {
                    if (mode == .awaited) return .pending;
                    settle(self, conn.fd);
                    conn.close_wait = .none;
                    return .complete;
                },
                .claimable => {
                    conn.close_wait = .none;
                    const reported = if (mode == .awaited) blk: {
                        // The row and its handle are still here: the write
                        // that failed while draining is read before the
                        // provider close runs, and the close result follows it.
                        var slot = takeFreshWrite(self, id, conn);
                        if (claim(self, conn.fd)) |closed| foundation.latchFailure(&slot, closed);
                        break :blk slot;
                    } else blk: {
                        settle(self, conn.fd);
                        break :blk null;
                    };
                    Completions.retireIfQuiet(self, id, conn);
                    return if (reported) |report| .{ .failed = report } else .complete;
                },
            }
        }

        /// Return any held receive borrow and leave the starved queue.
        fn releaseRecv(self: *Self, id: usize, conn: *Self.Conn) void {
            const borrowed = switch (conn.recv) {
                .holding => |held| held.comp,
                .draining_failure => |comp| comp,
                else => null,
            };
            if (borrowed) |held| {
                conn.recv = .idle;
                Completions.recycle(self, held);
            }
            Completions.forgetStarved(self, id);
        }

        /// Release the row and shut its socket. The row lives on until the
        /// backend retires the operations still borrowing it.
        fn shutConn(self: *Self, id: usize, conn: *Self.Conn, mode: resident_mod.CloseMode) TeardownOutcome {
            conn.close = .closing;
            self.backend.shutdownFd(conn.fd);
            var outcome: TeardownOutcome = .complete;
            const awaited = mode == .awaited and conn.close_seat;
            // A close with no seat releases the provider handle when it is
            // submitted, so its fresh write is read first. A seat keeps the
            // handle until the claim.
            var fresh = if (mode == .awaited and !awaited) takeFreshWrite(self, id, conn) else null;
            const submitted = if (awaited) submitAwaited(self, id, conn) else self.backend.submitClose(userData(.close, id), conn.fd);
            if (submitted) {
                conn.inflight += 1;
                if (awaited) {
                    conn.close_wait = .awaited;
                    outcome = .pending;
                }
            } else |err| {
                // A refused submission changed nothing, so a seat's handle
                // is still owned.
                if (awaited) fresh = takeFreshWrite(self, id, conn);
                self.backend.closeFd(conn.fd);
                outcome = .{ .failed = .init(err) };
                // The descriptor is closed and its armed operations complete
                // nowhere, so a row still counting them can never retire.
                // The resident is the smallest scope that can report that,
                // and its owner retires it.
                if (conn.inflight != 0) Completions.latch(self, err);
            }
            Completions.retireIfQuiet(self, id, conn);
            return withFresh(fresh, outcome);
        }

        /// A write failure the close was first to see: one that arose after
        /// the runtime's snapshot, so nothing has claimed it. Healthy rows
        /// cost this check alone.
        fn takeFreshWrite(self: *Self, id: usize, conn: *Self.Conn) ?carrier_failure.Report {
            if (conn.failures.write != .failed) return null;
            return failures.claim(self, id, conn);
        }

        /// A close that is not pending ends with the write that failed first.
        fn withFresh(fresh: ?carrier_failure.Report, outcome: TeardownOutcome) TeardownOutcome {
            var slot: ?carrier_failure.Report = fresh orelse return outcome;
            switch (outcome) {
                .pending => unreachable, // the caller keeps a fresh write on the row while pending
                .complete => {},
                .failed => |later| foundation.latchFailure(&slot, later),
            }
            return .{ .failed = slot.? };
        }

        fn submitAwaited(self: *Self, id: usize, conn: *Self.Conn) !void {
            if (comptime !@hasDecl(@TypeOf(self.backend), "submitCloseAwaited")) unreachable;
            return self.backend.submitCloseAwaited(userData(.close, id), conn.fd);
        }

        /// A row only waits when its backend declares the awaited verbs.
        fn settle(self: *Self, fd: Self.Fd) void {
            if (comptime !@hasDecl(@TypeOf(self.backend), "settleNoWait")) unreachable;
            self.backend.settleNoWait(fd);
        }

        fn claim(self: *Self, fd: Self.Fd) ?carrier_failure.Report {
            if (comptime !@hasDecl(@TypeOf(self.backend), "claimClose")) unreachable;
            return self.backend.claimClose(fd);
        }

        pub fn closeAndDrain(self: *Self, timeout_ms: u32) !void {
            try closeOpen(self);
            var out: [64]completion.Completion = undefined;
            var waited_ms: u32 = 0;
            while (owesCompletions(self)) {
                if (waited_ms >= timeout_ms) return error.TimedOut;
                const n = try self.backend.poll(&out, 10);
                if (n == 0) waited_ms += 10;
                for (out[0..n]) |comp| Completions.dispatch(self, comp);
            }
            retireQuiet(self);
            // Every dial is settled with its descriptor closed.
            self.dials.clearRetainingCapacity();
            // `closeOpen` stopped every listener, so no accept holds a seat.
            std.debug.assert(self.accept_seats == 0 and self.rearm_owed_count == 0 and self.close_seats == 0);
            self.records.clearRetainingCapacity();
            std.debug.assert(self.drained());
        }

        /// Idempotent, so a failed drain can run again.
        fn closeOpen(self: *Self) !void {
            while (self.listeners.count() != 0) {
                var listeners = self.listeners.valueIterator();
                // tolerant: a refused close submission closes the descriptor
                // at once, and the listener is retired either way.
                _ = Self.stopListen(self, listeners.next().?.*);
            }
            self.starved.clearRetainingCapacity();
            var conns = self.conns.iterator();
            while (conns.next()) |entry| {
                const conn = entry.value_ptr;
                if (conn.close == .closing) {
                    // The waiting caller is gone: finish the provider close
                    // through its sink instead of leaving it claimable.
                    if (conn.close_wait != .none) {
                        settle(self, conn.fd);
                        conn.close_wait = .none;
                    }
                    continue;
                }
                releaseRecv(self, entry.key_ptr.*, conn);
                conn.close = .closing;
                self.backend.shutdownFd(conn.fd);
                if (self.backend.submitClose(userData(.close, entry.key_ptr.*), conn.fd)) {
                    conn.inflight += 1;
                } else |_| {
                    // tolerant: the descriptor closes here instead, and its
                    // owed operations still retire through the drain.
                    self.backend.closeFd(conn.fd);
                }
            }
            var dials = self.dials.iterator();
            while (dials.next()) |entry| {
                const dial = entry.value_ptr;
                switch (dial.state) {
                    .connecting => {
                        dial.state = .cancelling;
                        // Shut the connect down first: the queued connect
                        // holds the socket past the descriptor's close.
                        self.backend.shutdownFd(dial.fd);
                        if (self.backend.submitClose(userData(.dial_close, entry.key_ptr.*), dial.fd)) {
                            dial.inflight += 1;
                        } else |_| {
                            // tolerant: the descriptor closes here instead, and
                            // its connect still retires through the drain.
                            self.backend.closeFd(dial.fd);
                        }
                    },
                    .connected, .failed => {
                        self.backend.closeFd(dial.fd);
                        dial.state = .cancelled;
                    },
                    .cancelling, .cancelled => {},
                }
            }
        }

        fn owesCompletions(self: *const Self) bool {
            if (self.closing_listeners != 0 or self.listen_waits != 0) return true;
            var conns = self.conns.valueIterator();
            while (conns.next()) |conn| if (conn.inflight != 0) return true;
            var dials = self.dials.valueIterator();
            while (dials.next()) |dial| if (dial.inflight != 0) return true;
            return false;
        }

        /// Rows whose descriptor closed without an owed completion.
        fn retireQuiet(self: *Self) void {
            while (true) {
                var conns = self.conns.iterator();
                const quiet = while (conns.next()) |entry| {
                    if (entry.value_ptr.inflight == 0) break entry.key_ptr.*;
                } else return;
                Completions.retireIfQuiet(self, quiet, self.conns.getPtr(quiet).?);
            }
        }
    };
}
