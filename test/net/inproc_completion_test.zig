//! The `inproc` completion adapter over the real platform backend: a dial is
//! accepted through the exchange, bytes cross both ways through bounded
//! rings, a full ring holds its writer until the reader drains it, and a
//! closed end reads as end of stream.

const std = @import("std");
const glowcap = @import("glowcap");

const net = glowcap.net;
const completion = net.completion;
const Exchange = net.inproc_completion.Exchange;
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
