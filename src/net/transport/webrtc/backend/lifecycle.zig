//! Cross-phase WebRTC descriptor retirement.

const std = @import("std");

pub fn Machine(comptime Self: type, comptime Fd: type) type {
    return struct {
        pub fn closeFd(self: *Self, fd: Fd) void {
            if (fd == Self.listen_fd) return;
            if (self.pending_dials.fetchRemove(fd)) |kv| {
                var row = kv.value;
                std.debug.assert(self.by_id.remove(@backingInt(row.peer.id())));
                row.peer.deinit();
                self.allocator.free(row.designator);
                return;
            }
            if (self.adopting.fetchRemove(fd)) |kv| {
                var row = kv.value;
                std.debug.assert(self.by_id.remove(@backingInt(row.peer.id())));
                row.peer.deinit();
                return;
            }
            if (self.conns.fetchRemove(fd)) |kv| {
                var entry = kv.value;
                std.debug.assert(self.by_id.remove(@backingInt(entry.peer.id())));
                entry.peer.deinit();
            }
        }

        /// Required Backend contract. WebRTC has no OS recv to unblock.
        pub fn shutdownFd(self: *Self, fd: Fd) void {
            _ = self;
            _ = fd;
        }

        pub fn submitClose(self: *Self, user_data: u64, fd: Fd) !void {
            try self.ready.ensureUnusedCapacity(self.allocator, 3);
            if (fd == Self.listen_fd) {
                // Cancel a pending accept so Loop.closeAndDrain cannot hang on an
                // idle acceptor; the listen sentinel is not a real conn entry.
                if (self.accept_ud) |ud| {
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                    self.accept_ud = null;
                }
                for (self.accept_stash.items) |*outcome| switch (outcome.*) {
                    .connected => |*held| {
                        std.debug.assert(self.by_id.remove(@backingInt(held.peer.id())));
                        held.peer.deinit();
                    },
                    .failed => {},
                };
                self.accept_stash.clearRetainingCapacity();
                self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.pending_dials.fetchRemove(fd)) |kv| {
                var row = kv.value;
                std.debug.assert(self.by_id.remove(@backingInt(row.peer.id())));
                row.peer.deinit();
                self.allocator.free(row.designator);
                self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = -1 });
                self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.adopting.fetchRemove(fd)) |kv| {
                var row = kv.value;
                std.debug.assert(self.by_id.remove(@backingInt(row.peer.id())));
                row.peer.deinit();
                self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
                return;
            }
            if (self.conns.getPtr(fd)) |entry| {
                if (entry.pending.read_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                if (entry.pending.write_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                entry.pending = .{};
                std.debug.assert(self.by_id.remove(@backingInt(entry.peer.id())));
                var peer = entry.peer;
                peer.deinit();
                std.debug.assert(self.conns.remove(fd));
            }
            self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
        }
    };
}
