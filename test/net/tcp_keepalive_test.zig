const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");
const net = pancake.net;

test "keepalive apply is a no-crash setsockopt on a connected stream" {
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
    // Best-effort apply must not panic; SO_KEEPALIVE + idle/interval/count land.
    net.socket.applyKeepalive(client_stream.socket.handle, ka);
}

test "StreamOptions default leaves keepalive null" {
    const opts: net.tcp.StreamOptions = .{};
    try std.testing.expect(opts.keepalive == null);
}

test "Loop Options default leaves keepalive null" {
    const opts: net.completion.Options = .{};
    try std.testing.expect(opts.keepalive == null);
}
