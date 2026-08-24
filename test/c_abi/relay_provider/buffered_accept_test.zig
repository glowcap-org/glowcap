//! Relay C readiness for bytes already below the kernel's sight: admission
//! starts behind a consumed data header, and later control frames can leave the
//! following data buffered while their reply owns write progress.

const std = @import("std");
const pancake = @import("pancake");
const c = @import("c_abi_shared");
const relay_archive = @import("c_abi_net_transport_relay");
const ws_relay = @import("../../support/ws_relay.zig");
const harness = @import("harness.zig");

fn serveBufferedRegistration(
    io: std.Io,
    server: *std.Io.net.Server,
    replacement_ready: *std.atomic.Value(bool),
    connection_claimed: *std.atomic.Value(bool),
    data_drained: *std.atomic.Value(bool),
    close_answered: *std.atomic.Value(bool),
) !void {
    var admitted: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    admitted.wire();
    defer admitted.close();
    try ws_relay.serveUpgrade(&admitted);
    try ws_relay.writeServerFrame(&admitted, .binary, "message-one");

    while (!connection_claimed.load(.acquire))
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    try ws_relay.stageServerFrame(&admitted, .ping, "hb");
    try ws_relay.stageServerFrame(&admitted, .binary, "message-two");
    try admitted.writer.interface.flush();
    var response_buf: [16]u8 = undefined;
    const pong = try ws_relay.readClientFrame(&admitted, &response_buf);
    if (pong.opcode != .pong) return error.ExpectedPong;
    if (!std.mem.eql(u8, "hb", pong.payload)) return error.ExpectedPongPayload;

    while (!data_drained.load(.acquire))
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    try ws_relay.writeServerFrame(&admitted, .close, &.{});
    const close = try ws_relay.readClientFrame(&admitted, &response_buf);
    if (close.opcode != .close) return error.ExpectedAcceptedClose;
    close_answered.store(true, .release);

    // Accept starts the listener's replacement registration immediately. Hold
    // that route until the test has claimed the buffered connection event.
    var replacement: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    replacement.wire();
    defer replacement.close();
    try ws_relay.serveUpgrade(&replacement);
    replacement_ready.store(true, .release);
    const stop = ws_relay.readClientFrame(&replacement, &response_buf) catch |err| switch (err) {
        // Listener cancellation is deliberately abortive: no application byte
        // channel was admitted from this registration, so EOF is its normal
        // carrier barrier.
        error.EndOfStream => return,
        else => return err,
    };
    if (stop.opcode != .close) return error.ExpectedRegistrationClose;
    try ws_relay.writeServerFrame(&replacement, .close, &.{});
}

test "relay C accept publishes payload buffered by the registered listener" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var replacement_ready = std.atomic.Value(bool).init(false);
    var connection_claimed = std.atomic.Value(bool).init(false);
    var data_drained = std.atomic.Value(bool).init(false);
    var close_answered = std.atomic.Value(bool).init(false);
    var relay = try io.concurrent(serveBufferedRegistration, .{
        io,
        &server,
        &replacement_ready,
        &connection_claimed,
        &data_drained,
        &close_answered,
    });
    defer _ = relay.cancel(io) catch {};

    const port = server.socket.address.getPort();
    var relay_store: [64]u8 = undefined;
    var register_store: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_store, "ws://localhost:{d}/relay", .{port});
    const register_url = try std.fmt.bufPrint(&register_store, "ws://localhost:{d}/register", .{port});
    var config = harness.copiedTrustConfig(relay_url);
    config.register_url = register_url.ptr;
    config.register_url_len = register_url.len;
    var runtime: ?*relay_archive.PancakeRelayRuntime = null;
    try std.testing.expectEqual(c.PANCAKE_OK, relay_archive.pancake_relay_runtime_new(&config, &runtime));
    defer {
        var diagnostic: [512]u8 = undefined;
        var diagnostic_len: usize = 0;
        const result = relay_archive.pancake_relay_runtime_release(
            runtime,
            &diagnostic,
            diagnostic.len,
            &diagnostic_len,
        );
        if (result != c.PANCAKE_OK)
            std.debug.print("relay runtime release: {s}\n", .{diagnostic[0..diagnostic_len]});
        std.testing.expectEqual(c.PANCAKE_OK, result) catch unreachable;
    }

    var provider: c.PancakeTransportProvider = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, relay_archive.pancake_relay_transport_provider(runtime, &provider));
    const table = harness.keyedTable(provider);
    const identity = pancake.foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x71)));
    const designator = identity.publicKey().toDesignator();
    const transport = "keyed-relay";
    const route_id: u64 = 91;
    var result = std.mem.zeroes(c.PancakeListenResult);
    var failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.PANCAKE_OK, table.listen.?(
        table.ctx,
        route_id,
        transport.ptr,
        transport.len,
        &designator,
        designator.len,
        null,
        &result,
        &failure,
    ));
    try std.testing.expectEqual(c.PANCAKE_LISTEN_PENDING, result.state);
    _ = try harness.waitForEvent(io, table, route_id, c.PANCAKE_MULTIPLEXED_EV_LISTEN);

    var listener: ?*anyopaque = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.finish_listen.?(table.ctx, route_id, &listener, &failure),
    );
    _ = try harness.waitForEvent(io, table, route_id, c.PANCAKE_MULTIPLEXED_EV_ACCEPT);

    var conn: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, table.finish_accept.?(listener, &conn, &failure));
    _ = try harness.waitForEvent(io, table, conn, c.PANCAKE_MULTIPLEXED_EV_READABLE);
    var payload: [11]u8 = undefined;
    try std.testing.expectEqual(
        @as(isize, payload.len),
        table.try_read.?(table.ctx, conn, &payload, payload.len),
    );
    try std.testing.expectEqualStrings("message-one", &payload);
    connection_claimed.store(true, .release);

    _ = try harness.waitForEvent(io, table, conn, c.PANCAKE_MULTIPLEXED_EV_READABLE);
    try std.testing.expectEqual(
        c.PANCAKE_MULTIPLEXED_WOULD_BLOCK,
        table.try_read.?(table.ctx, conn, &payload, payload.len),
    );

    // The ping response wakes the control reactor. Its flush republishes both
    // write capacity and the binary frame already buffered behind the ping;
    // no further carrier byte is sent to manufacture a POLLIN edge.
    const resumed = try harness.waitForEventRecord(
        io,
        table,
        conn,
        c.PANCAKE_MULTIPLEXED_EV_WRITABLE,
    );
    try std.testing.expect(resumed & c.PANCAKE_MULTIPLEXED_EV_READABLE != 0);
    try std.testing.expect(resumed & c.PANCAKE_MULTIPLEXED_EV_WRITABLE != 0);
    try std.testing.expectEqual(
        @as(isize, payload.len),
        table.try_read.?(table.ctx, conn, &payload, payload.len),
    );
    try std.testing.expectEqualStrings("message-two", &payload);
    data_drained.store(true, .release);

    _ = try harness.waitForEvent(io, table, conn, c.PANCAKE_MULTIPLEXED_EV_READABLE);
    try std.testing.expectEqual(@as(isize, 0), table.try_read.?(table.ctx, conn, &payload, payload.len));
    while (!close_answered.load(.acquire))
        try std.Io.sleep(io, .fromMilliseconds(1), .real);

    while (!replacement_ready.load(.acquire))
        try std.Io.sleep(io, .fromMilliseconds(1), .real);
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, table.stop_listen.?(listener, &failure));
    _ = try harness.waitForEvent(io, table, route_id, c.PANCAKE_MULTIPLEXED_EV_LISTEN);
    try std.testing.expectEqual(c.PANCAKE_OK, table.stop_listen.?(listener, &failure));

    relay.await(io) catch |err| {
        std.debug.print("relay test server: {s}\n", .{@errorName(err)});
        return err;
    };

    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, table.conn_close.?(table.ctx, conn, &failure));
    _ = try harness.waitForEvent(io, table, conn, c.PANCAKE_MULTIPLEXED_EV_CLOSED);
    const close_result = table.conn_close.?(table.ctx, conn, &failure);
    if (close_result != c.PANCAKE_OK) std.debug.print(
        "connection close: {d} {s}\n",
        .{ close_result, failure.primary_name.?[0..failure.primary_name_len] },
    );
    try std.testing.expectEqual(c.PANCAKE_OK, close_result);
}
