//! Direct relay-provider ownership scenarios. These meet the multiplexed C
//! table below the driver so event publication, claim, and release cannot be
//! made accidentally correct by a higher adapter.

const std = @import("std");
const glowcap = @import("glowcap");
const c = @import("c_abi_shared");
const relay_archive = @import("c_abi_net_transport_relay");
const ws_relay = @import("../support/ws_relay.zig");
const tls_server_pem = @embedFile("../net/fixtures/tls_server.pem");
const harness = @import("relay_provider/harness.zig");
const copiedTrustConfig = harness.copiedTrustConfig;
const keyedTable = harness.keyedTable;
const drain = harness.drain;

fn serveTailThenClose(
    io: std.Io,
    server: *std.Io.net.Server,
    upgraded: *std.atomic.Value(bool),
    send_tail: *std.atomic.Value(bool),
) !void {
    var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
    leg.wire();
    defer leg.close();
    try ws_relay.serveUpgrade(&leg);
    upgraded.store(true, .release);
    while (!send_tail.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .real);
    try ws_relay.writeServerFrame(&leg, .binary, "tail");
}

fn serveUpgradesUntilClose(io: std.Io, server: *std.Io.net.Server, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var leg: ws_relay.Leg = .{ .stream = try server.accept(io), .io = io };
        leg.wire();
        defer leg.close();
        try ws_relay.serveUpgrade(&leg);
        var payload: [64]u8 = undefined;
        while (true) _ = ws_relay.readClientFrame(&leg, &payload) catch break;
    }
}

test "relay C configuration validates its version and trust before construction" {
    const url = "ws://127.0.0.1:1/relay";
    var runtime: ?*relay_archive.GlowcapRelayRuntime = @ptrFromInt(@alignOf(usize));

    var config = copiedTrustConfig(url);
    config.abi_version += 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        relay_archive.glowcap_relay_runtime_new(&config, &runtime),
    );
    try std.testing.expectEqual(null, runtime);

    config = copiedTrustConfig(url);
    config.struct_size -= 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        relay_archive.glowcap_relay_runtime_new(&config, &runtime),
    );
    try std.testing.expectEqual(null, runtime);

    config = copiedTrustConfig(url);
    config.trust = relay_archive.GLOWCAP_RELAY_TRUST_SYSTEM;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        relay_archive.glowcap_relay_runtime_new(&config, &runtime),
    );
    try std.testing.expectEqual(null, runtime);

    config = copiedTrustConfig(url);
    config.trust_pem = null;
    config.trust_pem_len = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        relay_archive.glowcap_relay_runtime_new(&config, &runtime),
    );
    try std.testing.expectEqual(null, runtime);
}

test "relay C runtime copies PEM trust before construction returns" {
    const allocator = std.testing.allocator;
    const pem = try allocator.dupe(u8, @embedFile("../net/fixtures/tls_root.pem"));
    defer allocator.free(pem);
    const url = "ws://127.0.0.1:1/relay";
    var config = copiedTrustConfig(url);
    config.trust_pem = pem.ptr;
    config.trust_pem_len = pem.len;
    var runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_new(&config, &runtime),
    );
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(runtime, null, 0, null),
    ) catch unreachable;

    // The borrowed PEM is dead once construction returns. A runtime built
    // from the intact fixture still compares equal on parsed trust, so the
    // first runtime consumed its copy rather than the caller's buffer.
    @memset(pem, 0);
    const intact_config = copiedTrustConfig(url);
    var intact_runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_new(&intact_config, &intact_runtime),
    );
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(intact_runtime, null, 0, null),
    ) catch unreachable;

    var provider: c.GlowcapTransportProvider = undefined;
    var intact_provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_transport_provider(runtime, &provider),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_transport_provider(intact_runtime, &intact_provider),
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        provider.same_configuration.?(provider.lease_ctx, intact_provider.lease_ctx),
    );
}

test "relay provider equivalence includes the immutable trust snapshot" {
    const url = "ws://127.0.0.1:1/relay";
    var first_config = copiedTrustConfig(url);
    var same_config = copiedTrustConfig(url);
    var other_config = copiedTrustConfig(url);
    other_config.trust_pem = tls_server_pem.ptr;
    other_config.trust_pem_len = tls_server_pem.len;

    var first_runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    var same_runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    var other_runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_new(&first_config, &first_runtime),
    );
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(first_runtime, null, 0, null),
    ) catch unreachable;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_new(&same_config, &same_runtime),
    );
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(same_runtime, null, 0, null),
    ) catch unreachable;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_new(&other_config, &other_runtime),
    );
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(other_runtime, null, 0, null),
    ) catch unreachable;

    var first_provider: c.GlowcapTransportProvider = undefined;
    var same_provider: c.GlowcapTransportProvider = undefined;
    var other_provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_transport_provider(first_runtime, &first_provider),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_transport_provider(same_runtime, &same_provider),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_transport_provider(other_runtime, &other_provider),
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        first_provider.same_configuration.?(
            first_provider.lease_ctx,
            same_provider.lease_ctx,
        ),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        first_provider.same_configuration.?(
            first_provider.lease_ctx,
            other_provider.lease_ctx,
        ),
    );
}

test "relay C provider preserves the final tail until explicit connection release" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const listen_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var upgraded = std.atomic.Value(bool).init(false);
    var send_tail = std.atomic.Value(bool).init(false);
    defer send_tail.store(true, .release);
    var server_future = try io.concurrent(serveTailThenClose, .{ io, &server, &upgraded, &send_tail });
    defer _ = server_future.cancel(io) catch {};

    var url_store: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_store,
        "ws://localhost:{d}/relay",
        .{server.socket.address.getPort()},
    );
    const config = copiedTrustConfig(url);
    var runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_new(&config, &runtime),
    );
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(runtime, null, 0, null),
    ) catch unreachable;

    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_transport_provider(runtime, &provider),
    );
    const table = keyedTable(provider);
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x63)),
    );
    const designator = identity.publicKey().toDesignator();
    const transport = "keyed-relay";
    const locator: c.GlowcapLocatorView = .{
        .abi_version = c.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapLocatorView),
        .transport = transport.ptr,
        .transport_len = transport.len,
        .designator = &designator,
        .designator_len = designator.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = c.GLOWCAP_HINTS_MAP,
    };

    const request_id: u64 = 77;
    var failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.start_connect.?(table.ctx, request_id, &locator, null, &failure),
    );

    var records: [8]c.GlowcapMultiplexedReadyEvent = undefined;
    var early_subject: u64 = 0;
    var early_events: u32 = 0;
    var connect_ready = false;
    var rounds: usize = 0;
    while (!connect_ready and rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == request_id and event.events == c.GLOWCAP_MULTIPLEXED_EV_CONNECT)
                connect_ready = true
            else {
                early_subject = event.subject;
                early_events |= event.events;
            }
        }
        if (!connect_ready) try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    try std.testing.expect(connect_ready);

    var conn: u64 = 0;
    failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.finish_connect.?(table.ctx, request_id, &conn, &failure),
    );

    while (!upgraded.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .real);
    var tail: [4]u8 = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_TRANSPORT_WOULD_BLOCK,
        table.try_read.?(table.ctx, conn, &tail, tail.len),
    );
    table.conn_take_failure.?(table.ctx, conn, &failure);
    try std.testing.expectEqual(@as(i32, 0), failure.result);
    send_tail.store(true, .release);

    var connection_events: u32 = if (early_subject == conn) early_events else 0;
    rounds = 0;
    while (connection_events & c.GLOWCAP_MULTIPLEXED_EV_READABLE == 0 and rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == conn) connection_events |= event.events;
        }
        if (connection_events & c.GLOWCAP_MULTIPLEXED_EV_READABLE == 0)
            try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    try std.testing.expect(connection_events & c.GLOWCAP_MULTIPLEXED_EV_READABLE != 0);

    try std.testing.expectEqual(@as(isize, tail.len), table.try_read.?(table.ctx, conn, &tail, tail.len));
    try std.testing.expectEqualStrings("tail", &tail);
    try std.testing.expectEqual(@as(isize, 0), table.try_read.?(table.ctx, conn, &tail, tail.len));

    // EOF is observation, not ownership release: the connection remains a
    // valid byte source until the caller settles its conn_close obligation.
    try std.testing.expectEqual(@as(isize, 0), table.try_read.?(table.ctx, conn, &tail, tail.len));

    failure = c.transport_provider.emptyProviderFailure();
    table.conn_take_failure.?(table.ctx, conn, &failure);
    try std.testing.expectEqual(@as(i32, 0), failure.result);

    // Close is nonblocking: the first call transfers retirement to the
    // provider, EV_CLOSED proves the joined barrier, and the second call
    // claims and removes that exact tombstone. Neither result may reappear at
    // final provider release.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        table.conn_close.?(table.ctx, conn, &failure),
    );
    var close_ready = false;
    rounds = 0;
    while (!close_ready and rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == conn and event.events & c.GLOWCAP_MULTIPLEXED_EV_CLOSED != 0)
                close_ready = true;
        }
        if (!close_ready) try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    try std.testing.expect(close_ready);
    failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.conn_close.?(table.ctx, conn, &failure),
    );
    try std.testing.expectEqual(@as(i32, 0), failure.result);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.conn_close.?(table.ctx, conn, &failure),
    );
    try server_future.await(io);
}

test "relay C dial cancellation retires an unclaimed connection through its request id" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var server_future = try io.concurrent(serveUpgradesUntilClose, .{ io, &server, 1 });
    defer _ = server_future.cancel(io) catch {};

    var url_store: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_store,
        "ws://localhost:{d}/relay",
        .{server.socket.address.getPort()},
    );
    const config = copiedTrustConfig(url);
    var runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, relay_archive.glowcap_relay_runtime_new(&config, &runtime));
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(runtime, null, 0, null),
    ) catch unreachable;

    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, relay_archive.glowcap_relay_transport_provider(runtime, &provider));
    const table = keyedTable(provider);
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x64)),
    );
    const designator = identity.publicKey().toDesignator();
    const transport = "keyed-relay";
    const locator: c.GlowcapLocatorView = .{
        .abi_version = c.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapLocatorView),
        .transport = transport.ptr,
        .transport_len = transport.len,
        .designator = &designator,
        .designator_len = designator.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = c.GLOWCAP_HINTS_MAP,
    };
    const request_id: u64 = 78;
    var failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.start_connect.?(table.ctx, request_id, &locator, null, &failure),
    );

    var records: [8]c.GlowcapMultiplexedReadyEvent = undefined;
    var ready = false;
    var rounds: usize = 0;
    while (!ready and rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == request_id and event.events & c.GLOWCAP_MULTIPLEXED_EV_CONNECT != 0)
                ready = true;
        }
        if (!ready) try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    try std.testing.expect(ready);

    // The first call transfers cancellation without joining the driver. The
    // second EV_CONNECT is the operation's joined teardown recipient.
    try std.testing.expectEqual(c.GLOWCAP_OK, table.cancel_connect.?(table.ctx, request_id, &failure));
    ready = false;
    rounds = 0;
    while (!ready and rounds < 400) : (rounds += 1) {
        for (try drain(table, &records)) |event| {
            if (event.subject == request_id and event.events & c.GLOWCAP_MULTIPLEXED_EV_CONNECT != 0)
                ready = true;
        }
        if (!ready) try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
    try std.testing.expect(ready);
    failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_OK, table.cancel_connect.?(table.ctx, request_id, &failure));
    try std.testing.expectEqual(@as(i32, 0), failure.result);
    try std.testing.expectEqual(c.GLOWCAP_OK, table.cancel_connect.?(table.ctx, request_id, &failure));
    try server_future.await(io);
}

test "relay C listener cancellation and stop each settle through the route id" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin()))
        return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var server_future = try io.concurrent(serveUpgradesUntilClose, .{ io, &server, 2 });
    defer _ = server_future.cancel(io) catch {};

    var relay_store: [64]u8 = undefined;
    var register_store: [64]u8 = undefined;
    const port = server.socket.address.getPort();
    const relay_url = try std.fmt.bufPrint(&relay_store, "ws://localhost:{d}/relay", .{port});
    const register_url = try std.fmt.bufPrint(&register_store, "ws://localhost:{d}/register", .{port});
    var config = copiedTrustConfig(relay_url);
    config.register_url = register_url.ptr;
    config.register_url_len = register_url.len;
    var runtime: ?*relay_archive.GlowcapRelayRuntime = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, relay_archive.glowcap_relay_runtime_new(&config, &runtime));
    defer std.testing.expectEqual(
        c.GLOWCAP_OK,
        relay_archive.glowcap_relay_runtime_release(runtime, null, 0, null),
    ) catch unreachable;

    var provider: c.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, relay_archive.glowcap_relay_transport_provider(runtime, &provider));
    const table = keyedTable(provider);
    const identity = glowcap.foundation.crypto.SecretKey.fromSeed(
        @as([glowcap.foundation.crypto.SEED_BYTES]u8, @splat(0x65)),
    );
    const designator = identity.publicKey().toDesignator();
    const transport = "keyed-relay";
    var records: [8]c.GlowcapMultiplexedReadyEvent = undefined;

    const routes = [_]u64{ 81, 82 };
    for (routes, 0..) |route_id, index| {
        var result = std.mem.zeroes(c.GlowcapListenResult);
        var failure = c.transport_provider.emptyProviderFailure();
        try std.testing.expectEqual(c.GLOWCAP_OK, table.listen.?(
            table.ctx,
            route_id,
            transport.ptr,
            transport.len,
            &designator,
            designator.len,
            &designator,
            designator.len,
            null,
            &result,
            &failure,
        ));
        try std.testing.expectEqual(c.GLOWCAP_LISTEN_PENDING, result.state);

        var ready = false;
        var rounds: usize = 0;
        while (!ready and rounds < 400) : (rounds += 1) {
            for (try drain(table, &records)) |event| {
                if (event.subject == route_id and event.events & c.GLOWCAP_MULTIPLEXED_EV_LISTEN != 0)
                    ready = true;
            }
            if (!ready) try std.Io.sleep(io, .fromMilliseconds(5), .real);
        }
        try std.testing.expect(ready);

        var listener: ?*anyopaque = null;
        if (index == 0) {
            try std.testing.expectEqual(c.GLOWCAP_OK, table.cancel_listen.?(table.ctx, route_id, &failure));
        } else {
            try std.testing.expectEqual(
                c.GLOWCAP_OK,
                table.finish_listen.?(table.ctx, route_id, &listener, &failure),
            );
            try std.testing.expect(listener != null);
            try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, table.stop_listen.?(listener, &failure));
        }

        ready = false;
        rounds = 0;
        while (!ready and rounds < 400) : (rounds += 1) {
            for (try drain(table, &records)) |event| {
                if (event.subject == route_id and event.events & c.GLOWCAP_MULTIPLEXED_EV_LISTEN != 0)
                    ready = true;
            }
            if (!ready) try std.Io.sleep(io, .fromMilliseconds(5), .real);
        }
        try std.testing.expect(ready);
        failure = c.transport_provider.emptyProviderFailure();
        if (index == 0)
            try std.testing.expectEqual(c.GLOWCAP_OK, table.cancel_listen.?(table.ctx, route_id, &failure))
        else
            try std.testing.expectEqual(c.GLOWCAP_OK, table.stop_listen.?(listener, &failure));
        try std.testing.expectEqual(@as(i32, 0), failure.result);
        if (index == 0)
            try std.testing.expectEqual(c.GLOWCAP_OK, table.cancel_listen.?(table.ctx, route_id, &failure));
    }
    try server_future.await(io);
}
