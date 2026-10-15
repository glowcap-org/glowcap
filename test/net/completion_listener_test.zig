//! Zig completion-listener address policy. The generic loop owns whether to
//! listen and which port to request. The platform backend owns which local IPv4
//! interface is exposed.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const fixtures = @import("../support/completion_loop_fixtures.zig");

test "completion listener: configured wildcard address is reachable through loopback" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const backend = try glowcap.net.Backend.initWithListenerIp4(
        allocator,
        8,
        2,
        fixtures.frame_cap,
        .{ 0, 0, 0, 0 },
    );
    var loop = try glowcap.net.TcpLoop.initWithBackend(
        allocator,
        backend,
        fixtures.makeServerPeer,
        null,
        .{ .max_conns = 1, .listen = 0 },
    );
    defer loop.deinit();

    const listener = loop.listenerAddress().?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &listener.bytes);
    try std.testing.expect(listener.port != 0);
    try std.testing.expectEqual(listener.port, loop.port().?);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dial_address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(listener.port),
    };
    const stream = try std.Io.net.IpAddress.connect(&dial_address, io, .{
        .mode = .stream,
    });
    stream.close(io);
}
