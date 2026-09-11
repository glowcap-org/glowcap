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

pub fn Machine(comptime Self: type, comptime Signaling: type, comptime Connections: type) type {
    return struct {
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
                .{ .fd = self.signal_wake.read, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.readiness_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = net.poll.wait(&pfds, timeout_ms) catch |err| return err;

            _ = try harvestReadiness(self);
            return self.ready.drain(out);
        }
    };
}
