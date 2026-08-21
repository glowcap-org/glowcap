//! Open DataChannel byte-completion authority.

const std = @import("std");
const foundation = @import("foundation");
const net = @import("net");
const sidecar = @import("../sidecar.zig");

const completion = net.completion;
const crypto = foundation.crypto;
const Peer = sidecar.Peer;

pub const Pending = struct {
    read_ud: ?u64 = null,
    write_ud: ?u64 = null,
    write_bytes: ?[]const u8 = null,
    readable_hint: bool = false,
    writable_hint: bool = false,
};

pub const Entry = struct {
    peer: Peer,
    pending: Pending = .{},
    /// The first signaling or sidecar failure discovered while open.
    terminal_failure: ?anyerror = null,
};

pub fn Machine(comptime Self: type, comptime Fd: type) type {
    return struct {
        pub fn recycleBorrowed(self: *Self, comp: completion.Completion) void {
            self.buffer_pool.release(@intCast(comp.borrowed.token));
        }

        /// The signaling-authorized remote identity for `fd`'s connection
        /// (ADR-0105): the key the exchange was scoped to, which is the dialed
        /// designator on the offer leg and the adopted peer's `authorizeRemote` on
        /// the answer leg. Null when the signaling owner named no identity.
        pub fn verifiedChannelKey(self: *Self, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
            const entry = self.conns.getPtr(fd) orelse return null;
            const key = entry.peer.authorized_remote orelse return null;
            return key.bytes;
        }

        pub fn entryPtr(self: *Self, fd: Fd) !*Entry {
            return self.conns.getPtr(fd) orelse error.InvalidFd;
        }

        /// Requires one unused ready-queue seat. A would-block attempt consumes no
        /// seat and keeps the caller's read pending.
        pub fn completeRecv(self: *Self, entry: *Entry) void {
            const ud = entry.pending.read_ud orelse return;
            var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
            if (entry.terminal_failure) |err| {
                comp.failure = err;
                entry.pending.read_ud = null;
                self.ready.appendAssumeCapacity(comp);
                return;
            }
            if (self.buffer_pool.acquire()) |idx| {
                const buf = self.buffer_pool.buffer(idx);
                if (entry.peer.tryReceivePacket(buf)) |n| {
                    comp.result = @intCast(n);
                    comp.borrowed = .recv(buf[0..n], idx);
                    // More may still be buffered: leave the hint so the next
                    // submitRecv completes without waiting for another edge.
                    entry.pending.readable_hint = true;
                } else |err| switch (err) {
                    error.WouldBlock => {
                        // Edge spent without bytes: keep the pending recv; a later
                        // readable will retry.
                        self.buffer_pool.release(idx);
                        entry.pending.readable_hint = false;
                        return;
                    },
                    error.Closed => {
                        comp.result = 0;
                        self.buffer_pool.release(idx);
                        entry.pending.readable_hint = false;
                    },
                    error.BufferTooSmall, error.Failed => {
                        self.buffer_pool.release(idx);
                        entry.pending.readable_hint = false;
                        comp.failure = error.WebRtcReadFailed;
                    },
                }
            } else {
                comp.recv_no_buffer = true;
                // Keep the hint: the loop re-arms once a buffer recycles.
            }
            entry.pending.read_ud = null;
            self.ready.appendAssumeCapacity(comp);
        }

        /// Requires one unused ready-queue seat. A would-block attempt consumes no
        /// seat and keeps the caller's write pending.
        pub fn completeSend(self: *Self, entry: *Entry) void {
            const ud = entry.pending.write_ud orelse return;
            const bytes = entry.pending.write_bytes orelse return;
            if (entry.terminal_failure) |err| {
                entry.pending.write_ud = null;
                entry.pending.write_bytes = null;
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = err });
                return;
            }
            var result: i32 = -1;
            var failure: ?anyerror = null;
            if (entry.peer.trySendPacket(bytes)) |n| {
                result = @intCast(n);
                entry.pending.writable_hint = true;
            } else |err| switch (err) {
                error.WouldBlock => {
                    entry.pending.writable_hint = false;
                    return;
                },
                error.BufferTooSmall, error.Closed, error.Failed => {
                    entry.pending.writable_hint = false;
                    failure = error.WebRtcWriteFailed;
                },
            }
            entry.pending.write_ud = null;
            entry.pending.write_bytes = null;
            self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = result, .failure = failure });
        }

        pub fn submitRecv(self: *Self, user_data: u64, fd: Fd) !void {
            const entry = try entryPtr(self, fd);
            if (entry.pending.read_ud != null) return error.AlreadyReading;
            try self.ready.ensureUnusedCapacity(self.allocator, 1);
            entry.pending.read_ud = user_data;
            if (entry.pending.readable_hint or entry.terminal_failure != null) completeRecv(self, entry);
        }

        pub fn submitSend(self: *Self, user_data: u64, fd: Fd, bytes: []const u8) !void {
            const entry = try entryPtr(self, fd);
            if (entry.pending.write_ud != null) return error.AlreadyWriting;
            try self.ready.ensureUnusedCapacity(self.allocator, 1);
            entry.pending.write_ud = user_data;
            entry.pending.write_bytes = bytes;
            // Always attempt once: a seeded writable_hint or a live edge may
            // already allow the write; would_block parks until the next edge.
            completeSend(self, entry);
        }

        pub fn submitCancel(
            self: *Self,
            cancel_user_data: u64,
            target_user_data: u64,
            fd: Fd,
        ) !void {
            const entry = try entryPtr(self, fd);
            const target_pending = if (entry.pending.read_ud) |ud| blk: {
                if (ud != target_user_data) return error.InvalidCancelTarget;
                break :blk true;
            } else false;
            try self.ready.ensureUnusedCapacity(
                self.allocator,
                1 + @as(usize, @intFromBool(target_pending)),
            );
            if (target_pending) {
                entry.pending.read_ud = null;
                self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
            }
            // With no pending row, completeRecv already queued the target.
            self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
        }

        pub fn failOpenConnection(self: *Self, entry: *Entry, cause: anyerror) void {
            if (entry.terminal_failure == null) {
                entry.terminal_failure = cause;
                entry.peer.close();
            }
            if (entry.pending.read_ud != null) completeRecv(self, entry);
            if (entry.pending.write_ud != null) completeSend(self, entry);
        }
    };
}
