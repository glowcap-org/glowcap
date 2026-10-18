//! Exact relay stream failures at the Zig owner boundary.

const std = @import("std");
const glowcap = @import("glowcap");
const ws_relay = @import("../support/ws_relay.zig");

const relay = glowcap.net.relay;

fn serveMaskedFrame(io: std.Io, server: *std.Io.net.Server) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
    // RFC 6455 forbids a server-to-client mask. The stream must retain this
    // protocol cause rather than publish the reader's coarse ReadFailed arm.
    try leg.writer.interface.writeAll(&.{ 0x82, 0x81, 1, 2, 3, 4, 'x' ^ 1 });
    try leg.writer.interface.flush();
}

test "relay stream failure is exact and claim-once" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const listen_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var server_future = try io.concurrent(serveMaskedFrame, .{ io, &server });
    defer _ = server_future.cancel(io) catch {};

    var url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buffer,
        "ws://localhost:{d}/relay",
        .{server.socket.address.getPort()},
    );
    var resident = try relay.Resident.init(allocator, io, url);
    defer _ = resident.deinit();
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.seed_bytes]u8, @splat(0x72)),
    );
    const designator = identity.publicKey().toDesignator();
    var connection = try resident.dialRaw(.{
        .transport = relay.transport_name,
        .designator = &designator,
    });
    defer _ = connection.close();

    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, connection.read(&byte));
    const failure = connection.takeFailure().?;
    try std.testing.expectEqualStrings("ProtocolViolation", failure.primaryName());
    try std.testing.expect(connection.takeFailure() == null);
    try server_future.await(io);
}
