//! The control session's reply bounds, driven against a scripted Tor daemon.
//!
//! A control reply is bounded twice: by the number of lines it may carry
//! (`max_reply_lines`) and by the bytes of each line (`control.max_line_bytes`,
//! counted up to the line feed, so the carriage return is part of the line).
//! `ADD_ONION` bounds the returned key as well (`service_key_cap`). Each test
//! runs a reply exactly at its bound, which the session admits, and one unit
//! past it, which the session refuses with `ReplyTooLong` rather than
//! truncating or reading on.

const std = @import("std");
const glowcap = @import("glowcap");

const onion = glowcap.net.onion;
const session = onion.session;
const ip = std.Io.net;

/// A real version 3 id, from the pinned Goblins source.
const service_id = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";

const max_lines = session.max_reply_lines;
const max_line_bytes = onion.control.max_line_bytes;

/// What the scripted daemon writes after each request it reads.
const Script = struct {
    /// Written verbatim after `AUTHENTICATE` arrives.
    auth_reply: []const u8,
    /// Written verbatim after `ADD_ONION` arrives, when the test sends one.
    add_reply: ?[]const u8 = null,
};

/// Which conversation the test runs after connecting.
const Conversation = enum { authenticate, add_onion };

fn skipRequestLine(reader: *std.Io.Reader) anyerror!void {
    while ((try reader.takeByte()) != '\n') {}
}

fn scriptedDaemon(io: std.Io, listener: *glowcap.net.tcp.Listener, script: Script) anyerror!void {
    const stream = try listener.acceptStream();
    defer stream.close(io);

    var read_buf: [256]u8 = undefined;
    var write_buf: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    try skipRequestLine(r);
    try w.writeAll(script.auth_reply);
    try w.flush();
    if (script.add_reply) |add_reply| {
        try skipRequestLine(r);
        try w.writeAll(add_reply);
        try w.flush();
    }

    // The session closes the stream once it has read all it will accept, so
    // the next read ends. A reset is the same close with unread bytes left in
    // the client's window, and a byte would mean the session kept talking.
    if (r.takeByte()) |_| return error.UnexpectedRequest else |_| {
        // tolerant: end of stream or a reset both mean the client closed, and
        // the verdict under test is the client's own return value.
    }
}

/// Connect to a scripted daemon, run `conversation`, and return the length of
/// the key `ADD_ONION` returned (zero for `authenticate`) or the session's
/// refusal. The daemon's own failure takes precedence over the session's.
fn converse(io: std.Io, script: Script, conversation: Conversation) anyerror!usize {
    var listener = try glowcap.net.tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    var endpoint_text: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_text, "{f}", .{listener.localAddress()});

    var daemon = try io.concurrent(scriptedDaemon, .{ io, &listener, script });
    const verdict = converseOnce(io, endpoint, conversation);
    try daemon.await(io);
    return verdict;
}

fn converseOnce(io: std.Io, endpoint: []const u8, conversation: Conversation) anyerror!usize {
    var ctrl: session.ControlSession = undefined;
    // A failed `open` closes its own stream, so only a successful one is closed here.
    try ctrl.open(io, try onion.Endpoint.parse(endpoint), .none);
    defer ctrl.close();
    switch (conversation) {
        .authenticate => return 0,
        .add_onion => {
            const forward = "127.0.0.1:9";
            const service = try ctrl.addOnion(try onion.Endpoint.parse(forward), forward, "");
            return service.key.len;
        },
    }
}

/// `head`, then `fillers` copies of `filler`, then the closing `250 OK`.
/// Every line is a success line, so the reply is `fillers` plus the lines of
/// `head` plus one long.
fn reply(allocator: std.mem.Allocator, head: []const u8, fillers: usize, filler: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, head);
    for (0..fillers) |_| try out.appendSlice(allocator, filler);
    try out.appendSlice(allocator, "250 OK\r\n");
    return out.toOwnedSlice(allocator);
}

test "an authenticate reply of max_reply_lines lines is admitted and one more is refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const at_bound = try reply(allocator, "", max_lines - 1, "250-Info=x\r\n");
    defer allocator.free(at_bound);
    try std.testing.expectEqual(@as(usize, 0), try converse(io, .{ .auth_reply = at_bound }, .authenticate));

    const past_bound = try reply(allocator, "", max_lines, "250-Info=x\r\n");
    defer allocator.free(past_bound);
    try std.testing.expectError(
        error.ReplyTooLong,
        converse(io, .{ .auth_reply = past_bound }, .authenticate),
    );
}

test "an ADD_ONION reply of max_reply_lines lines is admitted and one more is refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const head = "250-ServiceID=" ++ service_id ++ "\r\n";
    const at_bound = try reply(allocator, head, max_lines - 2, "250-Flags=x\r\n");
    defer allocator.free(at_bound);
    try std.testing.expectEqual(@as(usize, 0), try converse(io, .{
        .auth_reply = "250 OK\r\n",
        .add_reply = at_bound,
    }, .add_onion));

    const past_bound = try reply(allocator, head, max_lines - 1, "250-Flags=x\r\n");
    defer allocator.free(past_bound);
    try std.testing.expectError(error.ReplyTooLong, converse(io, .{
        .auth_reply = "250 OK\r\n",
        .add_reply = past_bound,
    }, .add_onion));
}

test "a returned private key of service_key_cap bytes is admitted and one more is refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for ([_]usize{ session.service_key_cap, session.service_key_cap + 1 }) |key_len| {
        const key = try allocator.alloc(u8, key_len);
        defer allocator.free(key);
        @memset(key, 'k');
        const head = try std.fmt.allocPrint(
            allocator,
            "250-ServiceID={s}\r\n250-PrivateKey={s}\r\n",
            .{ service_id, key },
        );
        defer allocator.free(head);
        const add_reply = try reply(allocator, head, 0, "");
        defer allocator.free(add_reply);

        const verdict = converse(io, .{ .auth_reply = "250 OK\r\n", .add_reply = add_reply }, .add_onion);
        if (key_len == session.service_key_cap) {
            try std.testing.expectEqual(session.service_key_cap, try verdict);
        } else {
            try std.testing.expectError(error.ReplyTooLong, verdict);
        }
    }
}

test "a reply line of max_line_bytes before its line feed is admitted and one more byte is refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The line is `250 `, filler, then the carriage return the reader counts
    // before it sees the line feed.
    const prefix = "250 ";
    for ([_]usize{ max_line_bytes - prefix.len - 1, max_line_bytes - prefix.len }) |filler_len| {
        const line = try allocator.alloc(u8, prefix.len + filler_len + 2);
        defer allocator.free(line);
        @memcpy(line[0..prefix.len], prefix);
        @memset(line[prefix.len..][0..filler_len], 'x');
        @memcpy(line[prefix.len + filler_len ..], "\r\n");

        const verdict = converse(io, .{ .auth_reply = line }, .authenticate);
        if (filler_len == max_line_bytes - prefix.len - 1) {
            try std.testing.expectEqual(@as(usize, 0), try verdict);
        } else {
            try std.testing.expectError(error.ReplyTooLong, verdict);
        }
    }
}
