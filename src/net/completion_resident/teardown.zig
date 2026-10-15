//! The end of a `net.completion_resident`: close what the runtime left open
//! and retire every operation the backend still owes before any staging it
//! borrows is freed.

const std = @import("std");

const completion = @import("../completion/loop.zig");
const completions = @import("completions.zig");

const userData = completions.userData;

pub fn Machine(comptime Self: type) type {
    return struct {
        const Completions = completions.Machine(Self);

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
                if (conn.close != .open) continue;
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
