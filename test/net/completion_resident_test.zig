//! `net.completion_resident` connections over the platform TCP backend,
//! driven through its `MultiplexedResident` vtable with no runtime: a bounded
//! send window refuses with `would_block` and owes one `ev_writable`, partial
//! reads copy out of one held receive, a receive that completed since the last
//! pump is read without a would-block turn, an idle connection holds no
//! staging, an abort ends a close the partner never reads, and
//! `closeAndDrain` retires everything still open.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const harness = @import("completion_resident/harness.zig");

const net = glowcap.net;
const model = glowcap.ocapn.model;
const er = net.multiplexed_resident;

// Exercise readiness-driven sends on Linux even when io_uring is available.
comptime {
    _ = Tests(net.Backend);
    if (builtin.os.tag == .linux) _ = Tests(net.epoll_white_box.TestBackend);
}

fn Tests(comptime Backend: type) type {
    return struct {
        const H = harness.Harness(Backend);
        const Resident = H.Resident;
        const Events = H.Events;
        const open = H.open;
        const retire = H.retire;
        const connectPair = H.connectPair;
        const fill = H.fill;
        const roundTrip = H.roundTrip;
        const park = H.park;
        const readableNow = H.readableNow;
        const wait_budget_ms = H.wait_budget_ms;

        /// Weigh any growth before raising it. Stated under runtime safety, where each staging list header carries std's
        /// one-word pointer-stability lock.
        const completion_resident_connection_state_bytes: usize = 152;

        test "completion resident connection row holds its pinned size" {
            if (!std.debug.runtime_safety) return error.SkipZigTest;
            try std.testing.expectEqual(completion_resident_connection_state_bytes, Resident.connection_state_bytes);
        }

        test "completion resident reads a receive that completed since its last pump without a would-block turn" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;

            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);
            const client_ops = client.resident().vtable;
            const server_ops = server.resident().vtable;

            // Consume one held receive completely, which queues the row's re-arm
            // for the park.
            var chunk: [1024]u8 = undefined;
            fill(&chunk, 0);
            try roundTrip(&client, pair.client_conn, &server, pair.server_conn, &server_events, &chunk);
            try std.testing.expect(server.conns.get(pair.server_conn).?.recv == .queued);

            // The next bytes complete the receive the park arms. Once the server's readiness
            // descriptor reports the completion, one `try_read` copies them: the
            // resident pumps before answering instead of owing a would-block turn.
            fill(&chunk, chunk.len);
            try std.testing.expectEqual(@as(isize, chunk.len), client_ops.try_write(&client, pair.client_conn, &chunk));
            client_ops.flush_writes.?(&client, pair.client_conn);
            client.resident().beforeWait(.caller);
            const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
            while (!try park(server.resident(), 10)) {
                if (net.clock.nowMonotonicMs() >= deadline) return error.ReceiveNeverCompleted;
            }
            var received: [1024]u8 = undefined;
            const n = server_ops.try_read(&server, pair.server_conn, &received);
            try std.testing.expect(n > 0);
            const got: usize = @intCast(n);
            try std.testing.expectEqualSlices(u8, chunk[0..got], received[0..got]);
        }

        test "completion resident reports records it holds between a verb and its service" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;

            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);
            const client_ops = client.resident().vtable;
            const server_ops = server.resident().vtable;

            var chunk: [256]u8 = undefined;
            fill(&chunk, 0);
            try std.testing.expectEqual(@as(isize, chunk.len), client_ops.try_write(&client, pair.client_conn, &chunk));
            client_ops.flush_writes.?(&client, pair.client_conn);
            client.resident().beforeWait(.caller);
            const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
            while (!try park(server.resident(), 10)) {
                if (net.clock.nowMonotonicMs() >= deadline) return error.ReceiveNeverCompleted;
            }

            // A service with no room reaps the completion and keeps its record. The
            // descriptor is quiet now, because the kernel holds nothing, so the
            // resident reports the record it holds instead.
            var none: [0]er.ReadyEvent = undefined;
            try std.testing.expectEqual(@as(usize, 0), try server_ops.drain_ready(&server, &none));
            try std.testing.expect(server.resident().readyPending());
            try std.testing.expect(!try readableNow(server.resident().readinessFd()));

            // A service that takes every record leaves nothing to report.
            var out: [4]er.ReadyEvent = undefined;
            const taken = try server_ops.drain_ready(&server, &out);
            try std.testing.expectEqual(@as(usize, 1), taken);
            try std.testing.expectEqual(pair.server_conn, out[0].subject);
            try std.testing.expect(!server.resident().readyPending());
            try std.testing.expect(!try readableNow(server.resident().readinessFd()));
        }

        test "a consumed receive re-arms at the park, not as the verb returns" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;
            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);
            const client_ops = client.resident().vtable;
            const server_ops = server.resident().vtable;

            // One chunk through: the server consumes it, which frees its receive
            // slot inside a verb.
            var chunk: [64]u8 = undefined;
            fill(&chunk, 0);
            try roundTrip(&client, pair.client_conn, &server, pair.server_conn, &server_events, &chunk);

            // The verb returns to its caller. A second chunk lands in the server's
            // socket, where no receive is armed to complete for it: the descriptor
            // stays quiet however long the caller stays away.
            server.resident().beforeWait(.caller);
            try std.testing.expectEqual(@as(isize, chunk.len), client_ops.try_write(&client, pair.client_conn, &chunk));
            client_ops.flush_writes.?(&client, pair.client_conn);
            client.resident().beforeWait(.caller);
            try std.testing.expect(!try readableNow(server.resident().readinessFd()));
            try std.testing.expect(!server.resident().readyPending());

            // The park arms it, and the chunk the socket already holds completes.
            const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
            while (!try park(server.resident(), 10)) {
                if (net.clock.nowMonotonicMs() >= deadline) return error.ReceiveNeverCompleted;
            }
            var received: [64]u8 = undefined;
            try std.testing.expectEqual(@as(isize, chunk.len), server_ops.try_read(&server, pair.server_conn, &received));
            try std.testing.expectEqualSlices(u8, &chunk, &received);
        }

        test "completion resident parks in its own queue and a watched descriptor wakes it" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            var resident = try open();
            defer retire(&resident);
            const wake = try net.wake_channel.WakeChannel.open();
            defer wake.deinit();
            const ops = resident.resident();
            try std.testing.expect(ops.parks());
            try ops.watch(wake.read);

            // The caller owns the deadline: signals may end an empty turn early.
            ops.beforeWait(.park);
            const park_deadline = net.clock.nowMonotonicMs() + 20;
            while (true) {
                const remaining = park_deadline - net.clock.nowMonotonicMs();
                if (remaining <= 0) break;
                try std.testing.expect(!ops.park(@intCast(remaining)));
            }

            // A nudge from another thread ends the park. The watch consumed
            // nothing: the channel still reads ready for the owner to drain.
            const nudger = try std.Thread.spawn(.{}, struct {
                fn run(channel: net.wake_channel.WakeChannel) void {
                    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
                    _ = channel.nudge() catch {};
                }
            }.run, .{wake});
            defer nudger.join();
            try std.testing.expect(ops.park(@intCast(wait_budget_ms)));
            try std.testing.expect(!ops.readyPending());
            try std.testing.expect(try readableNow(wake.read));
            try wake.drain();

            // The next park arms the watch again as it begins, so a nudge that
            // landed before it, even one a verb's reap already saw, ends it at once.
            _ = try wake.nudge();
            ops.beforeWait(.park);
            ops.reap();
            try std.testing.expect(ops.park(@intCast(wait_budget_ms)));
            try wake.drain();
        }

        test "completion resident holds every flushed batch of a turn for one send at the park" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;

            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const client_ops = client.resident().vtable;
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);

            // Two batches in one turn, as a reply and the release that follows it.
            const first = "<10'op:deliver>";
            const second = "<13'op:gc-exports>";
            try std.testing.expectEqual(@as(isize, first.len), client_ops.try_write(&client, pair.client_conn, first));
            client_ops.flush_writes.?(&client, pair.client_conn);
            try std.testing.expectEqual(@as(isize, second.len), client_ops.try_write(&client, pair.client_conn, second));
            client_ops.flush_writes.?(&client, pair.client_conn);
            const conn = client.conns.getPtr(pair.client_conn).?;
            try std.testing.expect(!conn.sending);
            try std.testing.expectEqual(first.len + second.len, conn.back.items.len);

            // The park is the one place a send starts, and it takes the whole
            // staged batch.
            client.resident().beforeWait(.caller);
            try std.testing.expect(!conn.send_queued);
            try std.testing.expectEqual(@as(usize, 0), conn.back.items.len);

            const server_ops = server.resident().vtable;
            var received: [64]u8 = undefined;
            var read: usize = 0;
            while (read < first.len + second.len) {
                const n = server_ops.try_read(&server, pair.server_conn, received[read..]);
                if (n == er.would_block) {
                    try server_events.await(pair.server_conn, er.ev_readable);
                    continue;
                }
                try std.testing.expect(n > 0);
                read += @intCast(n);
            }
            try std.testing.expectEqualStrings(first ++ second, received[0..read]);
        }

        test "a close sends the batch it flushed before it shuts the socket" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;

            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const client_ops = client.resident().vtable;
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);

            // An abort and the close that follows it in one turn: the batch is
            // still staged for the park when the close shuts the socket.
            const abort = "<8'op:abort>";
            try std.testing.expectEqual(@as(isize, abort.len), client_ops.try_write(&client, pair.client_conn, abort));
            client_ops.flush_writes.?(&client, pair.client_conn);
            try std.testing.expect(client.conns.getPtr(pair.client_conn).?.send_queued);
            try std.testing.expect(client_ops.conn_close(&client, pair.client_conn) == .complete);

            // The partner reads the abort, then end of stream.
            const server_ops = server.resident().vtable;
            var received: [64]u8 = undefined;
            var read: usize = 0;
            while (true) {
                const n = server_ops.try_read(&server, pair.server_conn, received[read..]);
                if (n == er.would_block) {
                    try server_events.await(pair.server_conn, er.ev_readable);
                    continue;
                }
                if (n == 0) break;
                try std.testing.expect(n > 0);
                read += @intCast(n);
            }
            try std.testing.expectEqualStrings(abort, received[0..read]);
        }

        test "completion resident bounds its send window, owes writable, and drains on close" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;

            var server = try open();
            defer retire(&server);
            var client = try open();
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const server_ops = server.resident().vtable;
            const client_ops = client.resident().vtable;
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);
            const client_conn = pair.client_conn;
            const server_conn = pair.server_conn;

            // A user-authored option the resident cannot honor is refused, not dropped.
            const keepalive: u8 = 1;
            try std.testing.expect(client_ops.dial.?.start_connect(&client, 1, pair.locator, .{ .data = &keepalive, .size = 1 }, .application) == .failed);

            // Write without reading until the kernel's socket buffers and the
            // window fill and the resident refuses.
            var chunk: [16 << 10]u8 = undefined;
            var written: usize = 0;
            while (true) {
                if (written > 256 << 20) return error.WindowNeverFilled;
                fill(&chunk, written);
                const n = client_ops.try_write(&client, client_conn, &chunk);
                client_ops.flush_writes.?(&client, client_conn);
                client.resident().beforeWait(.caller);
                if (n == er.would_block) break;
                try std.testing.expect(n > 0 and n <= chunk.len);
                written += @intCast(n);
            }

            // Read everything back in small pieces, which walk each held receive,
            // writing the tail once the owed `ev_writable` arrives. The kernel
            // accepts the refused send only after the server's reads free a share of
            // the socket's send queue, so the server keeps reading while the client
            // collects the record without waiting: a wait on the client's descriptor
            // alone would stop the reads that free the queue.
            const total = written + 3 * chunk.len;
            var read: usize = 0;
            var received: [1000]u8 = undefined;
            var expected: [1000]u8 = undefined;
            var writable_seen = false;
            const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
            while (read < total) {
                if (net.clock.nowMonotonicMs() >= deadline) return error.RecordNeverArrived;
                _ = try park(client.resident(), 0);
                if (!writable_seen) writable_seen = try client_events.take(client_conn, er.ev_writable);
                while (writable_seen and written < total) {
                    fill(&chunk, written);
                    const want = @min(chunk.len, total - written);
                    const sent = client_ops.try_write(&client, client_conn, chunk[0..want]);
                    client_ops.flush_writes.?(&client, client_conn);
                    client.resident().beforeWait(.caller);
                    if (sent == er.would_block) break;
                    written += @intCast(sent);
                }
                const n = server_ops.try_read(&server, server_conn, &received);
                if (n == er.would_block) {
                    _ = try park(server.resident(), 1);
                    continue;
                }
                try std.testing.expect(n > 0);
                const got: usize = @intCast(n);
                fill(expected[0..got], read);
                try std.testing.expectEqualSlices(u8, expected[0..got], received[0..got]);
                read += got;
            }
            try std.testing.expect(writable_seen);

            // Once the backend has every byte, the connection holds no staging; its
            // buffers wait in the resident's bounded spare list.
            const send_deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
            while (client.conns.get(client_conn).?.sending) {
                if (net.clock.nowMonotonicMs() >= send_deadline) return error.SendNeverCompleted;
                var fds = [_]std.posix.pollfd{.{ .fd = client.resident().readinessFd(), .events = std.posix.POLL.IN, .revents = 0 }};
                _ = try std.posix.poll(&fds, 10);
                var out: [16]er.ReadyEvent = undefined;
                for (try client.resident().drainReady(&out)) |event| try client_events.seen.append(allocator, event);
            }
            const idle = client.conns.get(client_conn).?;
            try std.testing.expectEqual(@as(usize, 0), idle.front.capacity + idle.back.capacity);
            try std.testing.expect(client.spare_sends.items.len <= 2);

            // The client closes; the server sees end of stream once.
            try std.testing.expect(client_ops.conn_close(&client, client_conn) == .complete);
            while (true) {
                if (net.clock.nowMonotonicMs() >= deadline) return error.RecordNeverArrived;
                const end = server_ops.try_read(&server, server_conn, &received);
                if (end == er.would_block) {
                    try server_events.await(server_conn, er.ev_readable);
                    continue;
                }
                try std.testing.expectEqual(@as(isize, 0), end);
                break;
            }
            try std.testing.expectEqual(@as(?glowcap.foundation.FailureChain, null), server_ops.take_failure.?(&server, server_conn));

            // The server's connection and listener stay open for `retire`, whose
            // drain closes them and waits for every owed operation.
        }

        test "an abort ends a close whose partner never reads" {
            if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
            const allocator = std.testing.allocator;

            var server = try open();
            defer retire(&server);
            // A window far past what two shrunken socket buffers hold, so the
            // close has bytes left to drain.
            var client = try Resident.init(allocator, try Backend.init(allocator, 64, 8, 4096), .{
                .send_window_bytes = 512 << 10,
                .spare_send_buffers = 2,
            });
            defer retire(&client);
            var server_events = Events{ .resident = server.resident() };
            defer server_events.deinit();
            var client_events = Events{ .resident = client.resident() };
            defer client_events.deinit();
            const client_ops = client.resident().vtable;
            const pair = try connectPair(allocator, &server, &client, &server_events, &client_events);
            defer model.freePeerLocator(allocator, pair.locator);

            const small = std.mem.toBytes(@as(c_int, 4096));
            try std.posix.setsockopt(client.conns.getPtr(pair.client_conn).?.fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &small);
            try std.posix.setsockopt(server.conns.getPtr(pair.server_conn).?.fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &small);

            var chunk: [16 << 10]u8 = undefined;
            fill(&chunk, 0);
            var staged: usize = 0;
            while (staged < 512 << 10) {
                const n = client_ops.try_write(&client, pair.client_conn, &chunk);
                try std.testing.expect(n > 0);
                staged += @intCast(n);
            }
            client_ops.flush_writes.?(&client, pair.client_conn);

            // The partner reads nothing, so the close waits on the drain, and
            // the draining row holds no read buffer for it.
            try std.testing.expect(client_ops.conn_close(&client, pair.client_conn) == .pending);
            const conn = client.conns.getPtr(pair.client_conn).?;
            try std.testing.expect(conn.close == .draining);
            try std.testing.expect(conn.recv != .holding);

            // The abort releases the row whatever is left to send.
            try std.testing.expect(client_ops.conn_abort.?(&client, pair.client_conn) == .complete);
            if (client.conns.getPtr(pair.client_conn)) |row| try std.testing.expect(row.close == .closing);

            // The partner sees the stream end.
            const server_ops = server.resident().vtable;
            var sink: [4096]u8 = undefined;
            while (true) {
                const n = server_ops.try_read(&server, pair.server_conn, &sink);
                if (n == er.would_block) {
                    try server_events.await(pair.server_conn, er.ev_readable);
                    continue;
                }
                if (n <= 0) break;
            }
        }
    };
}
