//! The ends of a `net.completion_resident`: one connection's close and
//! abort, and the drain that closes what the runtime left open and retires
//! every operation the backend still owes before any staging it borrows is
//! freed.

const std = @import("std");

const completion = @import("../completion/loop.zig");
const completions = @import("completions.zig");
const resident_mod = @import("../multiplexed_resident.zig");

const TeardownOutcome = resident_mod.TeardownOutcome;
const userData = completions.userData;

pub fn Machine(comptime Self: type) type {
    return struct {
        const Completions = completions.Machine(Self);

        /// The runtime's claim on connection `id` ends here. The row lives
        /// on, out of reach of every verb, until the backend retires the
        /// operations that borrow its staging.
        pub fn connClose(self: *Self, id: usize) TeardownOutcome {
            defer Completions.pump(self);
            const conn = self.conns.getPtr(id) orelse return .complete;
            if (conn.close == .closing) return .complete;
            // Readiness backends perform sends when polled, not when submitted.
            // Keep the socket open until every admitted byte has completed.
            conn.send_queued = false;
            Completions.startSend(self, id, conn);
            Completions.submitQueued(self);
            Completions.pump(self);
            if (conn.write_failure == null and
                (conn.sending or conn.front.items.len != conn.sent or conn.back.items.len != 0))
            {
                // The runtime reads nothing more from a closed wire, so a
                // buffer this row holds goes back to the pool now rather
                // than for as long as the partner takes to read the drain.
                releaseRecv(self, id, conn);
                conn.close = .draining;
                conn.owes_writable = true;
                return .pending;
            }
            return shutConn(self, id, conn);
        }

        /// Drop connection `id` now, whatever `connClose` was still sending.
        pub fn connAbort(self: *Self, id: usize) TeardownOutcome {
            defer Completions.pump(self);
            const conn = self.conns.getPtr(id) orelse return .complete;
            if (conn.close == .closing) return .complete;
            conn.send_queued = false;
            return shutConn(self, id, conn);
        }

        /// Return a held pool buffer and leave the starved queue.
        fn releaseRecv(self: *Self, id: usize, conn: *Self.Conn) void {
            if (conn.recv == .holding) {
                const held = conn.recv.holding.comp;
                conn.recv = .idle;
                Completions.recycle(self, held);
            }
            Completions.forgetStarved(self, id);
        }

        /// Release the row and shut its socket. The row lives on until the
        /// backend retires the operations still borrowing it.
        fn shutConn(self: *Self, id: usize, conn: *Self.Conn) TeardownOutcome {
            releaseRecv(self, id, conn);
            conn.close = .closing;
            self.backend.shutdownFd(conn.fd);
            var outcome: TeardownOutcome = .complete;
            if (self.backend.submitClose(userData(.close, id), conn.fd)) {
                conn.inflight += 1;
            } else |err| {
                self.backend.closeFd(conn.fd);
                outcome = .{ .failed = .init(err) };
                // The descriptor is closed and its armed operations complete
                // nowhere, so a row still counting them can never retire.
                // The resident is the smallest scope that can report that,
                // and its owner retires it.
                if (conn.inflight != 0) Completions.latch(self, err);
            }
            Completions.retireIfQuiet(self, id, conn);
            return outcome;
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
                if (conn.close == .closing) continue;
                if (conn.recv == .holding) {
                    // Every receive is closing, so no starved one is fed.
                    self.backend.recycleBorrowed(conn.recv.holding.comp);
                    conn.recv = .idle;
                }
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
