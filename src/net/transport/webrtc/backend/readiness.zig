//! Ordered WebRTC readiness harvest and completion publication.

const std = @import("std");
const net = @import("net");
const sidecar = @import("../sidecar.zig");

const completion = net.completion;
const ReadyEvent = sidecar.ReadyEvent;
const ev_open = sidecar.ev_open;
const ev_candidate = sidecar.ev_candidate;
const ev_readable = sidecar.ev_readable;
const ev_writable = sidecar.ev_writable;
const ev_closed = sidecar.ev_closed;

/// A foreign descriptor a host asked the backend to report once, such as a
/// resident's wake channel.
pub const ForeignPoll = struct { user_data: u64, fd: i32, interest: completion.Interest };

pub fn Machine(comptime Self: type, comptime Signaling: type, comptime Connections: type) type {
    return struct {
        /// One descriptor that reads ready whenever `poll` has work.
        pub fn readinessFd(self: *const Self) i32 {
            return self.ready_set.descriptor();
        }

        /// Every operation reaches the sidecar or the inbox when submitted.
        pub fn flush(_: *Self) !void {}

        /// Nothing here waits on a timer.
        pub fn waitBoundMs(_: *const Self, requested_ms: i32) i32 {
            return requested_ms;
        }

        /// Report `fd` once through `poll`, consuming nothing. One foreign
        /// poll is armed at a time.
        pub fn submitPoll(self: *Self, user_data: u64, fd: i32, interest: completion.Interest) !void {
            if (self.foreign_poll != null) return error.AlreadyPolling;
            try self.ready.ensureUnusedCapacity(self.allocator, 1);
            try self.ready_set.add(fd);
            // tolerant: unwinding this call's own membership; a refused
            // removal leaves one idle member that `deinit` releases.
            errdefer self.ready_set.remove(fd) catch {};
            if (interest == .writable) try self.ready_set.setInterest(fd, .write);
            self.foreign_poll = .{ .user_data = user_data, .fd = fd, .interest = interest };
        }

        /// Retire an armed foreign poll; false when `target` names another.
        pub fn cancelForeignPoll(self: *Self, cancel_user_data: u64, target_user_data: u64, fd: i32) !bool {
            const armed = self.foreign_poll orelse return false;
            if (armed.user_data != target_user_data or armed.fd != fd) return false;
            try self.ready.ensureUnusedCapacity(self.allocator, 2);
            try self.ready_set.remove(fd);
            self.foreign_poll = null;
            self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
            self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
            return true;
        }

        fn harvestForeignPoll(self: *Self) !void {
            const armed = self.foreign_poll orelse return;
            const events: i16 = if (armed.interest == .readable) std.posix.POLL.IN else std.posix.POLL.OUT;
            var pfd = [_]std.posix.pollfd{.{ .fd = armed.fd, .events = events, .revents = 0 }};
            _ = try net.poll.wait(&pfd, 0);
            if (pfd[0].revents == 0) return;
            try self.ready.ensureUnusedCapacity(self.allocator, 1);
            try self.ready_set.remove(armed.fd);
            self.foreign_poll = null;
            self.ready.appendAssumeCapacity(.{ .user_data = armed.user_data, .result = 0 });
        }

        fn dispatchReady(self: *Self, ev: ReadyEvent) !void {
            const fd = self.by_id.get(ev.subject) orelse return;
            if (self.pending_dials.getPtr(fd)) |row| {
                if (ev.events & ev_candidate != 0) Signaling.pumpLocalCandidates(self, fd, &row.peer) catch |err| return Signaling.failDial(self, fd, err);
                if (ev.events & ev_closed != 0) return Signaling.failDial(self, fd, channelTerminalCause(&row.peer));
                if (ev.events & ev_open != 0) return Signaling.finishDial(self, fd);
                return;
            }
            if (self.adopting.getPtr(fd)) |row| {
                if (ev.events & ev_candidate != 0) Signaling.pumpLocalCandidates(self, fd, &row.peer) catch |err| return Signaling.failAdopt(self, fd, err);
                if (ev.events & ev_closed != 0) {
                    return Signaling.failAdopt(self, fd, channelTerminalCause(&row.peer));
                }
                if (ev.events & ev_open != 0) return Signaling.openAdopted(self, fd);
                return;
            }
            const entry = self.conns.getPtr(fd) orelse return;
            if (ev.events & ev_candidate != 0) Signaling.pumpLocalCandidates(self, fd, &entry.peer) catch |err| {
                Connections.failOpenConnection(self, entry, err);
                return;
            };
            if (ev.events & (ev_readable | ev_closed) != 0) {
                entry.pending.readable_hint = true;
                if (entry.pending.read_ud != null) Connections.completeRecv(self, entry);
            }
            // A closed channel settles a parked write as readily as a parked
            // read: the try-write reports the close, and the shared machine
            // latches it, exactly as the iroh backend handles its own edge.
            if (ev.events & (ev_writable | ev_closed) != 0) {
                entry.pending.writable_hint = true;
                if (entry.pending.write_ud != null) Connections.completeSend(self, entry);
            }
        }

        fn channelTerminalCause(peer: *const sidecar.Peer) anyerror {
            peer.checkOpen() catch |err| return switch (err) {
                error.Closed => error.WebRtcChannelClosed,
                error.Failed => error.WebRtcChannelFailed,
                error.WouldBlock => error.WebRtcChannelFailed,
            };
            return error.WebRtcChannelFailed;
        }

        /// Non-blocking harvest: drain the signaling wake and apply the thread-safe
        /// queue first (so a row registered this round can claim the events drained
        /// this round), then drain resident readiness records.
        fn harvestReadiness(self: *Self) !bool {
            try self.signal_wake_failure.check();
            try harvestForeignPoll(self);
            var pfds = [_]std.posix.pollfd{
                .{ .fd = self.signal_wake.read, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.readiness_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = net.poll.wait(&pfds, 0) catch |err| return err;
            var woke = false;
            if (pfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
                self.signal_wake.drain() catch |err| {
                    self.signal_wake_failure.record(err);
                    return err;
                };
                woke = true;
            }
            try Signaling.drainSignalIn(
                self,
            );

            if (pfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
                var events_buf: [256]ReadyEvent = undefined;
                // One readiness record can complete both a pending read and write;
                // reserve before consuming any record.
                try self.ready.ensureUnusedCapacity(self.allocator, events_buf.len * 2);
                while (true) {
                    const n = try self.resident.drainReady(&events_buf);
                    if (n == 0) break;
                    for (events_buf[0..n]) |ev| try dispatchReady(self, ev);
                    if (n < events_buf.len) break;
                    try self.ready.ensureUnusedCapacity(self.allocator, events_buf.len * 2);
                }
            }
            return woke;
        }

        pub fn poll(self: *Self, out: []completion.Completion, timeout_ms: i32) !usize {
            const pre_wake = try harvestReadiness(self);
            {
                const n = self.ready.drain(out);
                if (n > 0) return n;
            }
            // The wake may have carried only loop-external state (stop) or
            // signaling work that did not complete a connection yet. Either way,
            // the owner loop must get a turn before this backend blocks again.
            if (pre_wake) return 0;

            var pfds = [_]std.posix.pollfd{
                .{ .fd = self.ready_set.descriptor(), .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = net.poll.wait(&pfds, timeout_ms) catch |err| return err;

            _ = try harvestReadiness(self);
            return self.ready.drain(out);
        }
    };
}
