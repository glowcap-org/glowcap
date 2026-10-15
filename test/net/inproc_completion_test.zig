//! The `inproc` completion adapter over the real platform backend: a dial is
//! accepted through the exchange, bytes cross both ways through bounded
//! rings, a full ring holds its writer until the reader drains it, and a
//! closed end reads as end of stream. A sink outlives a nudge counted against
//! it before its ends were released, and a writer nudges only a parked reader.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const completion = net.completion;
const Exchange = net.inproc_completion.Exchange;
const Sink = net.inproc_completion.Sink;
const Backend = net.inproc_completion.CompletionBackend(net.Backend);

const ring_bytes = 8;

fn pollOne(backend: *Backend, user_data: u64) !completion.Completion {
    var out: [8]completion.Completion = undefined;
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const n = try backend.poll(&out, 20);
        for (out[0..n]) |comp| {
            if (comp.user_data == user_data) return comp;
            std.debug.print("unexpected completion {d}\n", .{comp.user_data});
            return error.UnexpectedCompletion;
        }
    }
    return error.CompletionTimedOut;
}

fn expectRecv(backend: *Backend, fd: Backend.Fd, user_data: u64, expected: []const u8) !void {
    try backend.submitRecv(user_data, fd);
    const comp = try pollOne(backend, user_data);
    defer if (comp.borrowed.active()) backend.recycleBorrowed(comp);
    try std.testing.expectEqualStrings(expected, comp.borrowed.recvBytes() orelse "");
}

test "inproc completion: dial, bounded transfer both ways, backpressure, and end of stream" {
    const allocator = std.testing.allocator;
    var exchange = Exchange.init(allocator);
    defer exchange.deinit();
    exchange.ring_bytes = ring_bytes;
    var server = try Backend.init(allocator, .{ .exchange = &exchange }, 32, 4, 64);
    defer server.deinit();
    var client = try Backend.init(allocator, .{ .exchange = &exchange }, 32, 4, 64);
    defer client.deinit();

    const listen = try server.openListener(.{ .inproc = "alpha" });
    try server.submitAccept(1, listen);
    const client_fd = try client.startDial(2, .{ .inproc = "alpha" });
    try std.testing.expectEqual(@as(i32, 0), (try pollOne(&client, 2)).result);
    const accepted = try pollOne(&server, 1);
    try std.testing.expectEqual(@as(i32, 0), accepted.result);
    const server_fd = accepted.accepted_fd.?;

    // A ring holds `ring_bytes`, so the first send moves only that much.
    try client.submitSend(3, client_fd, "hello world!");
    try std.testing.expectEqual(@as(i32, ring_bytes), (try pollOne(&client, 3)).result);
    // The ring is full: the next send waits until the server drains it.
    try client.submitSend(4, client_fd, "rld!");
    var out: [4]completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 0), try client.poll(&out, 0));
    try expectRecv(&server, server_fd, 5, "hello wo");
    try std.testing.expectEqual(@as(i32, 4), (try pollOne(&client, 4)).result);
    try expectRecv(&server, server_fd, 6, "rld!");

    try server.submitSend(7, server_fd, "pong");
    try std.testing.expectEqual(@as(i32, 4), (try pollOne(&server, 7)).result);
    try expectRecv(&client, client_fd, 8, "pong");

    try client.submitClose(9, client_fd);
    try std.testing.expectEqual(@as(i32, 0), (try pollOne(&client, 9)).result);
    try server.submitRecv(10, server_fd);
    try std.testing.expectEqual(@as(i32, 0), (try pollOne(&server, 10)).result);
    try server.submitClose(11, server_fd);
    _ = try pollOne(&server, 11);
}

test "inproc completion: a dial to a designator nobody serves is refused" {
    const allocator = std.testing.allocator;
    var exchange = Exchange.init(allocator);
    defer exchange.deinit();
    var client = try Backend.init(allocator, .{ .exchange = &exchange }, 32, 4, 64);
    defer client.deinit();
    try std.testing.expectError(error.ConnectionRefused, client.startDial(1, .{ .inproc = "nobody" }));
}

/// A nudge counted under a link lock and sent after a delay, as a writer
/// preempted between releasing the lock and sending would do.
const LateNudge = struct {
    sink: *Sink,
    landed: std.atomic.Value(bool) = .init(false),

    fn send(self: *LateNudge) void {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
        self.landed.store(true, .release);
        _ = self.sink.wake.nudge() catch |err| self.sink.wake_failure.record(err);
        _ = self.sink.nudging.fetchSub(1, .release);
    }
};

test "inproc exchange: a sink's destroy waits for a nudge counted before its ends were released" {
    const allocator = std.testing.allocator;
    const sink = try Sink.create(allocator);
    _ = sink.nudging.fetchAdd(1, .monotonic);
    var late = LateNudge{ .sink = sink };
    const nudger = try std.Thread.spawn(.{}, LateNudge.send, .{&late});
    sink.destroy(allocator);
    try std.testing.expect(late.landed.load(.acquire));
    nudger.join();
}

/// Whether `fd` reports readable without waiting.
fn readableNow(fd: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, 0) > 0;
}

test "inproc completion: a writer nudges only a parked reader" {
    const allocator = std.testing.allocator;
    var exchange = Exchange.init(allocator);
    defer exchange.deinit();
    var server = try Backend.init(allocator, .{ .exchange = &exchange }, 32, 4, 64);
    defer server.deinit();
    var client = try Backend.init(allocator, .{ .exchange = &exchange }, 32, 4, 64);
    defer client.deinit();

    const listen = try server.openListener(.{ .inproc = "beta" });
    try server.submitAccept(1, listen);
    const client_fd = try client.startDial(2, .{ .inproc = "beta" });
    try std.testing.expectEqual(@as(i32, 0), (try pollOne(&client, 2)).result);
    const server_fd = (try pollOne(&server, 1)).accepted_fd.?;

    // A reader that reaps is looking: the writer sends no nudge, and the
    // reader's next pass settles the news on its own.
    var out: [4]completion.Completion = undefined;
    try server.submitRecv(5, server_fd);
    _ = try server.peek(&out);
    try client.submitSend(3, client_fd, "ping");
    try std.testing.expectEqual(@as(i32, 4), (try pollOne(&client, 3)).result);
    try std.testing.expect(!try readableNow(server.sink.wake.read));
    try std.testing.expectEqual(@as(usize, 1), try server.peek(&out));
    try std.testing.expectEqual(@as(u64, 5), out[0].user_data);
    try std.testing.expectEqualStrings("ping", out[0].borrowed.recvBytes() orelse "");
    server.recycleBorrowed(out[0]);

    // A reader that flushed is parked: the writer nudges, and the wait
    // consumes that nudge (the wake stays armed when none came).
    try server.submitRecv(6, server_fd);
    try server.flush();
    try client.submitSend(4, client_fd, "pong");
    try std.testing.expectEqual(@as(i32, 4), (try pollOne(&client, 4)).result);
    const second = try pollOne(&server, 6);
    try std.testing.expectEqualStrings("pong", second.borrowed.recvBytes() orelse "");
    server.recycleBorrowed(second);
    try std.testing.expect(!server.wake_armed);

    // A reader that parks over news it has not reaped nudges itself.
    try server.submitRecv(7, server_fd);
    _ = try server.peek(&out);
    try client.submitSend(8, client_fd, "last");
    try std.testing.expectEqual(@as(i32, 4), (try pollOne(&client, 8)).result);
    try server.flush();
    const third = try pollOne(&server, 7);
    try std.testing.expectEqualStrings("last", third.borrowed.recvBytes() orelse "");
    server.recycleBorrowed(third);
    try std.testing.expect(!server.wake_armed);

    try client.submitClose(9, client_fd);
    _ = try pollOne(&client, 9);
    try server.submitClose(10, server_fd);
    _ = try pollOne(&server, 10);
}
