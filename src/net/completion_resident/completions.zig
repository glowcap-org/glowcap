//! The completion side of `net.completion_resident`: arming receives and
//! sends, turning backend completions into ready records, and keeping the
//! readiness descriptor readable while records wait.

const std = @import("std");

const completion = @import("../completion/loop.zig");
const failure_projection = @import("../completion/failure_projection.zig");
const resident_mod = @import("../multiplexed_resident.zig");

/// Completion user_data: the operation kind in the top byte, the row id
/// below. A row id is a connection id, a dial's request id, or a listener
/// token, by kind.
pub const Kind = enum(u8) { wake, connect, dial_close, recv, send, close, accept, listen_close, listen_ready };

pub fn userData(kind: Kind, id: usize) u64 {
    return (@as(u64, @backingInt(kind)) << 56) | @as(u64, @intCast(id));
}

fn kindOf(user_data: u64) Kind {
    return @fromBackingInt(@intCast(@as(u8, @intCast(user_data >> 56))));
}

fn idOf(user_data: u64) usize {
    return @intCast(user_data & ((@as(u64, 1) << 56) - 1));
}

/// The wake readiness poll and the cancel that retires it.
pub const wake_poll = 0;
pub const wake_cancel = 1;

pub fn Machine(comptime Self: type) type {
    return struct {
        const Conn = Self.Conn;
        const Listener = Self.Listener;
        const Fd = Self.Fd;

        /// Keep the first resident-wide failure. `drain_ready` reports it.
        pub fn latch(self: *Self, err: anyerror) void {
            if (self.failure == null) self.failure = err;
        }

        pub fn armRecv(self: *Self, id: usize, conn: *Conn) void {
            if (conn.close != .open or conn.recv != .idle) return;
            self.backend.submitRecv(userData(.recv, id), conn.fd) catch |err| {
                conn.recv = .{ .failed = err };
                record(self, id, resident_mod.ev_readable);
                return;
            };
            conn.recv = .armed;
            conn.inflight += 1;
        }

        pub fn startSend(self: *Self, id: usize, conn: *Conn) void {
            if (conn.sending or conn.close != .open) return;
            if (conn.front.items.len == conn.sent) {
                if (conn.back.items.len == 0) return;
                std.mem.swap(std.ArrayListUnmanaged(u8), &conn.front, &conn.back);
                retireStaging(self, &conn.back);
                conn.sent = 0;
            }
            self.backend.submitSend(userData(.send, id), conn.fd, conn.front.items[conn.sent..]) catch |err| {
                conn.write_failure = err;
                record(self, id, resident_mod.ev_writable);
                return;
            };
            conn.sending = true;
            conn.inflight += 1;
        }

        pub fn armAccept(self: *Self, listener: *Listener) !void {
            if (listener.accept_armed) return;
            try self.backend.submitAccept(userData(.accept, listener.token), listener.fd);
            listener.accept_armed = true;
        }

        /// Take every completion the backend has, without waiting.
        pub fn pump(self: *Self) void {
            var out: [64]completion.Completion = undefined;
            var turns: usize = 0;
            while (turns < 64) : (turns += 1) {
                const n = self.backend.poll(&out, 0) catch |err| {
                    latch(self, err);
                    break;
                };
                for (out[0..n]) |comp| dispatch(self, comp);
                if (n < out.len) break;
            }
            signalRecords(self);
            // The runtime waits on the descriptor next, and it reports only
            // operations the backend has handed to the kernel.
            self.backend.flush() catch |err| {
                latch(self, err);
            };
        }

        pub fn dispatch(self: *Self, comp: completion.Completion) void {
            const id = idOf(comp.user_data);
            switch (kindOf(comp.user_data)) {
                .wake => {
                    // A readiness poll consumes nothing: drain the nudge here,
                    // so records still waiting need another.
                    if (id == wake_poll) {
                        self.wake_armed = false;
                        self.wake_cancel_submitted = false;
                        self.wake_nudged = false;
                        if (comp.result >= 0) self.wake.drain() catch |err| latch(self, err);
                    }
                },
                .connect => {
                    const dial = self.dials.getPtr(id) orelse return;
                    dial.inflight -= 1;
                    switch (dial.state) {
                        .connecting => {
                            if (comp.result < 0) {
                                dial.state = .{ .failed = failure_projection.primary(comp, error.ConnectionRefused) };
                                keepChain(self, .dial_failures, id, comp);
                            } else dial.state = .connected;
                            record(self, id, resident_mod.ev_connect);
                        },
                        .cancelling => if (dial.inflight == 0) {
                            dial.state = .cancelled;
                            record(self, id, resident_mod.ev_connect);
                        },
                        else => {},
                    }
                    recycle(self, comp);
                },
                .dial_close => {
                    const dial = self.dials.getPtr(id) orelse return;
                    dial.inflight -= 1;
                    if (dial.inflight == 0) {
                        dial.state = .cancelled;
                        record(self, id, resident_mod.ev_connect);
                    }
                },
                .recv => {
                    const conn = self.conns.getPtr(id) orelse {
                        recycle(self, comp);
                        return;
                    };
                    conn.inflight -= 1;
                    if (conn.close != .open) {
                        recycle(self, comp);
                        return retireIfQuiet(self, id, conn);
                    }
                    if (comp.recv_no_buffer) {
                        conn.recv = .starved;
                        self.starved.append(self.allocator, id) catch {
                            conn.recv = .{ .failed = error.SystemResources };
                            record(self, id, resident_mod.ev_readable);
                        };
                        return;
                    }
                    if (comp.result > 0) {
                        conn.recv = .{ .holding = .{ .comp = comp, .offset = 0 } };
                    } else {
                        if (comp.result < 0) {
                            conn.recv = .{ .failed = failure_projection.primary(comp, error.ConnectionLost) };
                            keepChain(self, .conn_failures, id, comp);
                        } else conn.recv = .eof;
                        recycle(self, comp);
                    }
                    record(self, id, resident_mod.ev_readable);
                },
                .send => {
                    const conn = self.conns.getPtr(id) orelse return;
                    conn.inflight -= 1;
                    conn.sending = false;
                    if (conn.close == .open and comp.result <= 0) {
                        conn.write_failure = failure_projection.primary(comp, error.ConnectionLost);
                        keepChain(self, .conn_failures, id, comp);
                    }
                    recycle(self, comp);
                    if (conn.close != .open) return retireIfQuiet(self, id, conn);
                    if (comp.result <= 0) {
                        record(self, id, resident_mod.ev_writable | resident_mod.ev_readable);
                        return;
                    }
                    // A packet leaves whole or not at all.
                    if (self.backend.wireFraming(conn.fd) == .message and
                        @as(usize, @intCast(comp.result)) != conn.front.items.len - conn.sent)
                    {
                        conn.write_failure = error.WriteFailed;
                        record(self, id, resident_mod.ev_writable | resident_mod.ev_readable);
                        return;
                    }
                    conn.sent += @intCast(comp.result);
                    if (conn.sent == conn.front.items.len) {
                        retireStaging(self, &conn.front);
                        conn.sent = 0;
                    }
                    startSend(self, id, conn);
                    if (conn.owes_writable) {
                        conn.owes_writable = false;
                        record(self, id, resident_mod.ev_writable);
                    }
                },
                .close => {
                    const conn = self.conns.getPtr(id) orelse return;
                    conn.inflight -= 1;
                    retireIfQuiet(self, id, conn);
                },
                .listen_close => self.closing_listeners -= 1,
                .listen_ready => {
                    self.listen_waits -= 1;
                    // A listener stopped during setup finds no row.
                    const listener = self.listeners.get(id) orelse return;
                    listener.setup = if (comp.result < 0)
                        .{ .failed = failure_projection.primary(comp, error.ListenFailed) }
                    else
                        .ready;
                    record(self, listener.route, resident_mod.ev_listen);
                },
                .accept => {
                    const listener = self.listeners.get(id) orelse {
                        // A stopped listener's canceled accept, or one that
                        // won the race with the stop.
                        if (comp.result >= 0) self.backend.closeFd(acceptedFd(comp));
                        return;
                    };
                    listener.accept_armed = false;
                    if (comp.result >= 0) {
                        listener.accepted.append(self.allocator, acceptedFd(comp)) catch
                            self.backend.closeFd(acceptedFd(comp));
                        record(self, listener.route, resident_mod.ev_accept);
                    }
                    armAccept(self, listener) catch |err| {
                        latch(self, err);
                    };
                },
            }
        }

        fn acceptedFd(comp: completion.Completion) Fd {
            return comp.accepted_fd orelse comp.result;
        }

        pub fn retireIfQuiet(self: *Self, id: usize, conn: *Conn) void {
            if (conn.close == .closing and conn.inflight == 0) releaseConn(self, id, conn);
        }

        fn releaseConn(self: *Self, id: usize, conn: *Conn) void {
            retireStaging(self, &conn.front);
            retireStaging(self, &conn.back);
            std.debug.assert(self.conns.remove(id));
            // idempotent: only a failed, unclaimed row kept a chain.
            _ = self.conn_failures.remove(id);
        }

        /// Copy the structured failure a backend lent with `comp` before the
        /// borrow returns. The first failure per row wins.
        fn keepChain(self: *Self, comptime table: enum { conn_failures, dial_failures }, id: usize, comp: completion.Completion) void {
            const chain = comp.borrowed.failureChain() orelse return;
            const slot = @field(self, @tagName(table)).getOrPut(self.allocator, id) catch return; // best-effort: the scalar cause remains.
            if (!slot.found_existing) slot.value_ptr.* = chain.*;
        }

        /// Return a drained staging buffer to the spare list, or free it when
        /// the list is full or the buffer outgrew a spare.
        fn retireStaging(self: *Self, staging: *std.ArrayListUnmanaged(u8)) void {
            if (staging.capacity == 0) return;
            if (staging.capacity <= self.options.spare_send_bytes and
                self.spare_sends.items.len < self.spare_sends.capacity)
            {
                staging.clearRetainingCapacity();
                self.spare_sends.appendAssumeCapacity(staging.*);
            } else staging.deinit(self.allocator);
            staging.* = .empty;
        }

        /// Return a completion's pool buffer, if it holds one, and hand the
        /// freed buffer to a starved receive.
        pub fn recycle(self: *Self, comp: completion.Completion) void {
            if (!comp.borrowed.active()) return;
            self.backend.recycleBorrowed(comp);
            feedStarved(self);
        }

        fn feedStarved(self: *Self) void {
            while (self.starved.pop()) |id| {
                const conn = self.conns.getPtr(id) orelse continue;
                if (conn.recv != .starved) continue;
                conn.recv = .idle;
                armRecv(self, id, conn);
                return;
            }
        }

        pub fn forgetStarved(self: *Self, id: usize) void {
            for (self.starved.items, 0..) |queued, index| if (queued == id) {
                std.debug.assert(self.starved.swapRemove(index) == id);
                return;
            };
        }

        fn record(self: *Self, subject: usize, events: u32) void {
            self.records.append(self.allocator, .{ .subject = subject, .events = events }) catch {
                latch(self, error.OutOfMemory);
            };
        }

        /// Keep the descriptor readable while records wait.
        pub fn signalRecords(self: *Self) void {
            if (self.records.items.len == 0 or self.wake_nudged) return;
            armWake(self);
            // A coalesced nudge already left the descriptor readable.
            _ = self.wake.nudge() catch |err| {
                latch(self, err);
                return;
            };
            self.wake_nudged = true;
        }

        pub fn armWake(self: *Self) void {
            if (self.wake_armed) return;
            self.backend.submitPoll(userData(.wake, wake_poll), self.wake.read, .readable) catch |err| {
                latch(self, err);
                return;
            };
            self.wake_armed = true;
        }
    };
}
