//! `net.completion_resident` over the platform TCP backend, driven through
//! its `MultiplexedResident` vtable with no runtime: a bounded send window
//! refuses with `would_block` and owes one `ev_writable`, partial reads copy
//! out of one held receive, a receive that completed since the last pump is
//! read without a would-block turn, an idle connection holds no staging, and
//! `closeAndDrain` retires everything still open.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const net = glowcap.net;
const model = glowcap.ocapn.model;
const er = net.multiplexed_resident;

const Resident = net.completion_resident.Resident(net.Backend, net.tcp.CompletionPolicy(net.Backend));

const Events = struct {
    resident: net.MultiplexedResident,
    seen: std.ArrayListUnmanaged(er.ReadyEvent) = .empty,

    /// Wait on the readiness descriptor until a record names `subject` with
    /// any of `events`, keeping every drained record.
    fn await(self: *Events, subject: usize, events: u32) !void {
        const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
        while (true) {
            if (try self.take(subject, events)) return;
            if (net.clock.nowMonotonicMs() >= deadline) return error.RecordNeverArrived;
            var fds = [_]std.posix.pollfd{.{ .fd = self.resident.readinessFd(), .events = std.posix.POLL.IN, .revents = 0 }};
            _ = try std.posix.poll(&fds, 10);
        }
    }
    /// Drain the records ready now and claim one naming `subject` with any of
    /// `events`, without waiting.
    fn take(self: *Events, subject: usize, events: u32) !bool {
        var out: [16]er.ReadyEvent = undefined;
        for (try self.resident.drainReady(&out)) |event| try self.seen.append(std.testing.allocator, event);
        for (self.seen.items, 0..) |event, index| if (event.subject == subject and event.events & events != 0) {
            _ = self.seen.orderedRemove(index);
            return true;
        };
        return false;
    }

    fn deinit(self: *Events) void {
        self.seen.deinit(std.testing.allocator);
    }
};

/// How long one wait may take. The kernel work behind every wait here is
/// loopback delivery, so this is a hang bound, not an expected duration.
const wait_budget_ms: i64 = 10_000;
fn open() !Resident {
    return Resident.init(std.testing.allocator, try net.Backend.init(std.testing.allocator, 64, 8, 4096), .{
        .send_window_bytes = 16 << 10,
        .spare_send_buffers = 2,
    });
}

/// `docs/ladder.md` records this row. Weigh any growth there too. Stated
/// under runtime safety, where each staging list header carries std's
/// one-word pointer-stability lock.
const completion_resident_connection_state_bytes: usize = 152;

test "completion resident connection row holds its pinned size" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    try std.testing.expectEqual(completion_resident_connection_state_bytes, Resident.connection_state_bytes);
}

fn fill(out: []u8, offset: usize) void {
    for (out, offset..) |*byte, i| byte.* = @truncate(i *% 131);
}

fn retire(resident: *Resident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("completion resident drain failed: {t}", .{err});
    resident.deinit();
}

/// One accepted loopback connection between two residents, with the
/// listener's locator the caller frees.
const Pair = struct {
    listener: *anyopaque,
    locator: model.PeerLocator,
    server_conn: usize,
    client_conn: usize,
};

fn connectPair(
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

    try std.testing.expect(client_ops.dial.?.start_connect(client, 2, locator, .{}) == .admitted);
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
fn roundTrip(client: *Resident, client_conn: usize, server: *Resident, server_conn: usize, server_events: *Events, chunk: []const u8) !void {
    const client_ops = client.resident().vtable;
    const server_ops = server.resident().vtable;
    try std.testing.expectEqual(@as(isize, @intCast(chunk.len)), client_ops.try_write(client, client_conn, chunk));
    client_ops.flush_writes.?(client, client_conn);
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

    // Consume one held receive completely, which re-arms the row.
    var chunk: [1024]u8 = undefined;
    fill(&chunk, 0);
    try roundTrip(&client, pair.client_conn, &server, pair.server_conn, &server_events, &chunk);
    try std.testing.expect(server.conns.get(pair.server_conn).?.recv == .armed);

    // The next bytes complete the armed receive. Once the server's readiness
    // descriptor reports the completion, one `try_read` copies them: the
    // resident pumps before answering instead of owing a would-block turn.
    fill(&chunk, chunk.len);
    try std.testing.expectEqual(@as(isize, chunk.len), client_ops.try_write(&client, pair.client_conn, &chunk));
    client_ops.flush_writes.?(&client, pair.client_conn);
    const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
    while (true) {
        var fds = [_]std.posix.pollfd{.{ .fd = server.resident().readinessFd(), .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 10) > 0) break;
        if (net.clock.nowMonotonicMs() >= deadline) return error.ReceiveNeverCompleted;
    }
    var received: [1024]u8 = undefined;
    const n = server_ops.try_read(&server, pair.server_conn, &received);
    try std.testing.expect(n > 0);
    const got: usize = @intCast(n);
    try std.testing.expectEqualSlices(u8, chunk[0..got], received[0..got]);
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
    try std.testing.expect(client_ops.dial.?.start_connect(&client, 1, pair.locator, .{ .data = &keepalive, .size = 1 }) == .failed);

    // Write without reading until the kernel's socket buffers and the
    // window fill and the resident refuses.
    var chunk: [16 << 10]u8 = undefined;
    var written: usize = 0;
    while (true) {
        if (written > 256 << 20) return error.WindowNeverFilled;
        fill(&chunk, written);
        const n = client_ops.try_write(&client, client_conn, &chunk);
        client_ops.flush_writes.?(&client, client_conn);
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
    while (read < total) {
        if (!writable_seen) writable_seen = try client_events.take(client_conn, er.ev_writable);
        while (writable_seen and written < total) {
            fill(&chunk, written);
            const want = @min(chunk.len, total - written);
            const sent = client_ops.try_write(&client, client_conn, chunk[0..want]);
            client_ops.flush_writes.?(&client, client_conn);
            if (sent == er.would_block) break;
            written += @intCast(sent);
        }
        const n = server_ops.try_read(&server, server_conn, &received);
        if (n == er.would_block) {
            try server_events.await(server_conn, er.ev_readable);
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
    try server_events.await(server_conn, er.ev_readable);
    try std.testing.expectEqual(@as(isize, 0), server_ops.try_read(&server, server_conn, &received));
    try std.testing.expectEqual(@as(?glowcap.foundation.FailureChain, null), server_ops.take_failure.?(&server, server_conn));

    // The server's connection and listener stay open for `retire`, whose
    // drain closes them and waits for every owed operation.
}
