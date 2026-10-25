//! The shared harness of the `net.completion_resident` tests: two residents
//! over the platform TCP backend, a loopback pair between them, the readiness
//! records each holds, and the park that waits for one.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const model = glowcap.ocapn.model;
const er = net.multiplexed_resident;

pub fn Harness(comptime Backend: type) type {
    return struct {
        pub const Resident = net.completion_resident.Resident(Backend, net.tcp.CompletionPolicy(Backend));

        pub const Events = struct {
            resident: net.MultiplexedResident,
            seen: std.ArrayListUnmanaged(er.ReadyEvent) = .empty,

            /// Wait on the readiness descriptor until a record names `subject` with
            /// any of `events`, keeping every drained record.
            pub fn await(self: *Events, subject: usize, events: u32) !void {
                const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
                while (true) {
                    if (try self.take(subject, events)) return;
                    if (net.clock.nowMonotonicMs() >= deadline) return error.RecordNeverArrived;
                    _ = try park(self.resident, 10);
                }
            }
            /// Drain the records ready now and claim one naming `subject` with any of
            /// `events`, without waiting.
            pub fn take(self: *Events, subject: usize, events: u32) !bool {
                var out: [16]er.ReadyEvent = undefined;
                for (try self.resident.drainReady(&out)) |event| try self.seen.append(std.testing.allocator, event);
                for (self.seen.items, 0..) |event, index| if (event.subject == subject and event.events & events != 0) {
                    _ = self.seen.orderedRemove(index);
                    return true;
                };
                return false;
            }

            pub fn deinit(self: *Events) void {
                self.seen.deinit(std.testing.allocator);
            }
        };

        /// How long one wait may take. The kernel work behind every wait here is
        /// loopback delivery, so this is a hang bound, not an expected duration.
        pub const wait_budget_ms: i64 = 10_000;
        pub fn open() !Resident {
            return Resident.init(std.testing.allocator, try Backend.init(std.testing.allocator, 64, 8, 4096), .{
                .send_window_bytes = 16 << 10,
                .spare_send_buffers = 2,
            });
        }

        pub fn fill(out: []u8, offset: usize) void {
            for (out, offset..) |*byte, i| byte.* = @truncate(i *% 131);
        }

        pub fn retire(resident: *Resident) void {
            resident.closeAndDrain(2_000) catch |err| std.debug.panic("completion resident drain failed: {t}", .{err});
            resident.deinit();
        }

        /// One accepted loopback connection between two residents, with the
        /// listener's locator the caller frees.
        pub const Pair = struct {
            listener: *anyopaque,
            locator: model.PeerLocator,
            server_conn: usize,
            client_conn: usize,
        };

        pub fn connectPair(
            allocator: std.mem.Allocator,
            server: *Resident,
            client: *Resident,
            server_events: *Events,
            client_events: *Events,
        ) !Pair {
            const server_ops = server.resident().vtable;
            const client_ops = client.resident().vtable;
            const route = 7;
            const listener = switch (server_ops.listen.?.listen(server, route, model.transport.tcp, .{ .designator = "127.0.0.1:0" })) {
                .admitted => |admitted| admitted.ready,
                .failed => |failure| return failure.cause,
            };
            const locator = switch (server_ops.listen.?.local_locator(server, listener, model.transport.tcp, allocator)) {
                .locator => |locator| locator,
                .failed => |failure| return failure.cause,
            };
            errdefer model.freePeerLocator(allocator, locator);

            try std.testing.expect(client_ops.dial.?.start_connect(client, 2, locator, .{}, .application) == .admitted);
            try client_events.await(2, er.ev_connect);
            const client_conn = switch (client_ops.dial.?.finish_connect(client, 2)) {
                .connected => |id| id,
                .failed => |failure| return failure.chain.cause,
            };
            try server_events.await(route, er.ev_accept);
            const server_conn = switch (server_ops.listen.?.finish_accept(server, listener)) {
                .connection => |id| id.?,
                .failed => |failure| return failure.chain.cause,
            };
            return .{ .listener = listener, .locator = locator, .server_conn = server_conn, .client_conn = client_conn };
        }

        /// Write `chunk` through the client and read all of it back through the
        /// server, waiting on readiness between would-block answers.
        pub fn roundTrip(client: *Resident, client_conn: usize, server: *Resident, server_conn: usize, server_events: *Events, chunk: []const u8) !void {
            const client_ops = client.resident().vtable;
            const server_ops = server.resident().vtable;
            try std.testing.expectEqual(@as(isize, @intCast(chunk.len)), client_ops.try_write(client, client_conn, chunk));
            client_ops.flush_writes.?(client, client_conn);
            client.resident().beforeWait(.caller);
            var received: [1024]u8 = undefined;
            var read: usize = 0;
            while (read < chunk.len) {
                const n = server_ops.try_read(server, server_conn, received[0 .. chunk.len - read]);
                if (n == er.would_block) {
                    try server_events.await(server_conn, er.ev_readable);
                    continue;
                }
                try std.testing.expect(n > 0);
                const got: usize = @intCast(n);
                try std.testing.expectEqualSlices(u8, chunk[read..][0..got], received[0..got]);
                read += got;
            }
        }

        /// The runtime's park, in miniature: hand staged work to the kernel, take a
        /// record the resident already holds, else wait on the descriptor. True
        /// means a service would find something.
        pub fn park(resident: net.MultiplexedResident, timeout_ms: i32) !bool {
            resident.beforeWait(.park);
            if (resident.readyPending()) return true;
            var fds = [_]std.posix.pollfd{.{ .fd = resident.readinessFd(), .events = std.posix.POLL.IN, .revents = 0 }};
            return try std.posix.poll(&fds, timeout_ms) > 0;
        }

        /// Whether `fd` reports readable without waiting.
        pub fn readableNow(fd: std.posix.fd_t) !bool {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            return try std.posix.poll(&fds, 0) > 0;
        }
    };
}
