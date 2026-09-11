const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const net = glowcap.net;

test "keepalive apply configures a connected stream" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try net.tcp.Listener.bind(io, addr);
    defer listener.deinit();
    const bound = listener.localAddress();

    const ka: net.Keepalive = .{ .idle_sec = 30, .interval_sec = 10, .count = 3 };

    const client_stream = try std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream });
    defer client_stream.close(io);
    try net.socket.applyKeepalive(client_stream.socket.handle, ka);
}

test "invalid keepalive rolls SO_KEEPALIVE back off and reports refusal" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try net.tcp.Listener.bind(io, addr);
    defer listener.deinit();
    const client_stream = try std.Io.net.IpAddress.connect(&listener.localAddress(), io, .{ .mode = .stream });
    defer client_stream.close(io);

    try std.testing.expectError(error.InvalidKeepalive, net.socket.applyKeepalive(client_stream.socket.handle, .{
        .idle_sec = std.math.maxInt(u32),
        .interval_sec = 10,
        .count = 3,
    }));

    const sys = std.posix.system;
    var enabled: c_int = 1;
    var len: std.posix.socklen_t = @sizeOf(c_int);
    try std.testing.expectEqual(@as(c_int, 0), sys.getsockopt(
        client_stream.socket.handle,
        sys.SOL.SOCKET,
        sys.SO.KEEPALIVE,
        @ptrCast(&enabled),
        &len,
    ));
    try std.testing.expectEqual(@as(c_int, 0), enabled);
}

test "StreamOptions default leaves keepalive null" {
    const opts: net.tcp.StreamOptions = .{};
    try std.testing.expect(opts.keepalive == null);
}

test "Loop Options default leaves keepalive null" {
    const opts: net.completion.Options = .{};
    try std.testing.expect(opts.keepalive == null);
}
