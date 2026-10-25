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
pub const Kind = enum(u8) { connect, dial_close, recv, send, close, accept, listen_close, listen_ready, watch };

/// One descriptor whose readiness wakes the park (`watch`). Rows are never
/// removed: a completion names its row by index.
pub const Watch = struct { fd: i32, armed: bool };

pub fn userData(kind: Kind, id: usize) u64 {
    return (@as(u64, @backingInt(kind)) << 56) | @as(u64, @intCast(id));
}

fn kindOf(user_data: u64) Kind {
    return @fromBackingInt(@intCast(@as(u8, @intCast(user_data >> 56))));
}

fn idOf(user_data: u64) usize {
    return @intCast(user_data & ((@as(u64, 1) << 56) - 1));
}

/// Whether an accept refusal outlives the arrival it was reported for. The
/// arrival itself failing (reset before accept took it, or refusing a socket
/// option) leaves the next one unaffected, so the listener accepts again.
/// Every other refusal (descriptor quota, memory, a dead listener) would
/// complete again for as long as the arrival waits, so the unknown case is
/// the persistent one.
pub fn acceptRefusalPersists(err: anyerror) bool {
    return switch (err) {
        error.ConnectionAborted, error.SocketConfigurationFailed => false,
        else => true,
    };
}

pub fn Machine(comptime Self: type) type {
    return struct {
        const Conn = Self.Conn;
        const Listener = Self.Listener;
        const Fd = Self.Fd;

        /// Keep the first resident-wide failure. `drain_ready` reports it.
        pub fn latch(self: *Self, err: anyerror) void {
            if (self.failure == null) self.failure = err;
        }

        /// Queue the connection's receive for the `beforeWait` that precedes
        /// a park. A verb that frees the receive slot ends with the re-arm
        /// held here, so the submit it needs rides the park's.
        pub fn armRecv(self: *Self, id: usize, conn: *Conn) void {
            if (conn.close != .open or conn.recv != .idle) return;
            self.recv_queue.append(self.allocator, id) catch {
                // The queue is the only allocation on this path; a refusal
                // arms this receive alone rather than losing it.
                return startRecv(self, id, conn);
            };
            conn.recv = .queued;
        }

        fn startRecv(self: *Self, id: usize, conn: *Conn) void {
            self.backend.submitRecv(userData(.recv, id), conn.fd) catch |err| {
                conn.recv = .{ .failed = err };
                record(self, id, resident_mod.ev_readable);
                return;
            };
            conn.recv = .armed;
            conn.inflight += 1;
        }

        pub fn startSend(self: *Self, id: usize, conn: *Conn) void {
            if (conn.sending or conn.close == .closing) return;
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

        /// Turn every completion the backend already holds into held bytes,
        /// records, and re-armed operations. The runtime's `reap` and
        /// `drain_ready` verbs and `beforeWait` run it, and a read verb runs
        /// it first when no receive is held, so bytes that landed since the
        /// last pump answer now. A verb that only arms or stages leaves what
        /// it armed to the reap at the turn's end: each pump walks every
        /// wrapped backend, so one per verb would cost the round trip more
        /// than it finds. It submits nothing: the backend keeps what the verb
        /// armed until `beforeWait`, and a record reaped here waits in
        /// `records`, which `ready_pending` reports.
        pub fn pump(self: *Self) void {
            var out: [64]completion.Completion = undefined;
            var turns: usize = 0;
            while (turns < 64) : (turns += 1) {
                const n = self.backend.peek(&out) catch |err| {
                    latch(self, err);
                    break;
                };
                for (out[0..n]) |comp| dispatch(self, comp);
                if (n < out.len) break;
            }
        }

        /// The turn is ending: start every send a batch left staged, and
        /// before a park every queued receive, and hand the queue to the
        /// kernel in one submit. What that submit completes inline (a
        /// loopback send finishes inside it) is reaped now, so a completion
        /// that leaves no record does not wake the park. The reap can arm
        /// more (a fed starved receive, a wrapped backend's next step), so
        /// the queue is handed over once more; a submit with nothing queued
        /// costs no syscall. Before the caller runs, the queued receives
        /// stay queued, so a turn that only consumed a reply submits nothing.
        pub fn beforeWait(self: *Self, after: resident_mod.AfterTurn) void {
            // Writes queued during the turn start now and go to the kernel in
            // one submit. A receive re-arm waits until a park. That is safe
            // because nothing can arrive for a re-armed receive until the
            // kernel has the request, and the runtime always calls
            // `beforeWait` before it parks (ADR-0060).
            for (self.send_queue.items) |id| {
                const conn = self.conns.getPtr(id) orelse continue;
                if (!conn.send_queued) continue;
                conn.send_queued = false;
                startSend(self, id, conn);
            }
            self.send_queue.clearRetainingCapacity();
            if (after == .park) startQueuedRecvs(self);
            submitQueued(self);
            pump(self);
            if (after == .park) startQueuedRecvs(self);
            submitQueued(self);
        }

        fn startQueuedRecvs(self: *Self) void {
            for (self.recv_queue.items) |id| {
                const conn = self.conns.getPtr(id) orelse continue;
                if (conn.close != .open or conn.recv != .queued) continue;
                conn.recv = .idle;
                startRecv(self, id, conn);
            }
            self.recv_queue.clearRetainingCapacity();
        }

        /// Park in the backend's own queue until a completion lands, a
        /// watched descriptor reads ready, or `timeout_ms` passes, and turn
        /// what arrived into records. True when something arrived, or when
        /// the wait failed and `ready_pending` now reports the failure.
        /// `beforeWait` ran first, so the turn's queue is in the kernel.
        /// The watches are armed here, as the park begins: a descriptor
        /// that reads ready now ends the park at once, where a watch armed
        /// earlier would have been reaped by a verb and left the park status-allow: event or source ordering
        /// asleep beside the wake it announced.
        pub fn park(self: *Self, timeout_ms: i32) bool {
            armWatches(self);
            var out: [64]completion.Completion = undefined;
            const n = self.backend.poll(&out, timeout_ms) catch |err| {
                latch(self, err);
                return true;
            };
            for (out[0..n]) |comp| dispatch(self, comp);
            if (n == out.len) pump(self);
            return n != 0;
        }

        /// Wake the next park when `fd` reads ready, consuming nothing from
        /// it. Each park arms the watch once and its completion disarms it,
        /// so one event posts one completion and a descriptor that stays
        /// readable posts no more until the next park.
        pub fn watch(self: *Self, fd: i32) error{OutOfMemory}!void {
            for (self.watches.items) |row| if (row.fd == fd) return;
            try self.watches.append(self.allocator, .{ .fd = fd, .armed = false });
        }

        fn armWatches(self: *Self) void {
            for (self.watches.items, 0..) |*row, index| {
                if (row.armed) continue;
                self.backend.submitPoll(userData(.watch, index), row.fd, .readable) catch |err| {
                    latch(self, err);
                    return;
                };
                row.armed = true;
            }
        }

        /// Hand every armed operation to the kernel now. A backend that
        /// submits as it arms makes this free.
        pub fn submitQueued(self: *Self) void {
            self.backend.flush() catch |err| {
                latch(self, err);
            };
        }

        /// Start `conn`'s staged bytes at the next `beforeWait`, so every
        /// batch of the turn leaves in one send. A message-framed connection
        /// starts now: its batch is one packet, and the packet boundary is the
        /// batch boundary.
        pub fn queueSend(self: *Self, id: usize, conn: *Conn) void {
            if (self.backend.wireFraming(conn.fd) == .message) return startSend(self, id, conn);
            if (conn.send_queued or conn.sending or conn.close != .open) return;
            if (conn.front.items.len == conn.sent and conn.back.items.len == 0) return;
            self.send_queue.append(self.allocator, id) catch {
                // The queue is the only allocation on this path; a refusal
                // sends this batch alone rather than losing it.
                return startSend(self, id, conn);
            };
            conn.send_queued = true;
        }

        pub fn dispatch(self: *Self, comp_in: completion.Completion) void {
            var comp = comp_in;
            const id = idOf(comp.user_data);
            const kind = kindOf(comp.user_data);
            // The backend reads ENOBUFS as an empty receive pool, since it
            // cannot tell which operation completed. On any other operation
            // it is the kernel short of socket memory, a failure with a cause.
            if (comp.recv_no_buffer and kind != .recv) {
                comp.recv_no_buffer = false;
                comp.failure = error.SystemResources;
            }
            switch (kind) {
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
                    if (conn.close != .closing and comp.result <= 0) {
                        conn.write_failure = failure_projection.primary(comp, error.ConnectionLost);
                        keepChain(self, .conn_failures, id, comp);
                    }
                    recycle(self, comp);
                    if (conn.close == .closing) return retireIfQuiet(self, id, conn);
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
                .watch => {
                    const row = &self.watches.items[id];
                    row.armed = false;
                    // The runtime owns a watched descriptor for the
                    // resident's whole life, so a watch that fails is a
                    // wake the runtime would never get again.
                    if (comp.result < 0) latch(self, comp.failure orelse error.WatchFailed);
                    recycle(self, comp);
                },
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
                    } else {
                        const err = failure_projection.primary(comp, error.AcceptFailed);
                        if (acceptRefusalPersists(err)) {
                            // Re-arming would complete with the same refusal
                            // for as long as the arrival waits, so hand it to
                            // the runtime through the claim verb.
                            if (listener.accept_failure == null) listener.accept_failure = err;
                            record(self, listener.route, resident_mod.ev_accept);
                            return;
                        }
                    }
                    // Past the unclaimed bound the listener waits for a
                    // claim, which re-arms it (`finishAccept`).
                    if (listener.accepted.items.len < Self.max_unclaimed_accepts)
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
    };
}
