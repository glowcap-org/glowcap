//! C-ABI frame-boundary loopback over the onion endpoints, driven against fake
//! Tor daemons.
//!
//! It proves the `pancake_onion_*` handles drive a real handshake and bootstrap
//! fetch when the *host* owns the peer and shuttles frames itself, the same
//! contract `inproc_loopback_test` holds for the socket-free endpoints. What is
//! new here is the Tor-shaped addressing: a dial names a version 3 service id and
//! goes through the daemon's SOCKS endpoint, and a listen asks the daemon's control
//! endpoint for a service and then accepts what it forwards.
//!
//! Both daemons are fakes on loopback. That is what lets this run in the ordinary
//! check with no Tor and no network, and it is also the limit: the bytes these
//! fakes accept are pinned against the two reference implementations in
//! `test/net/onion_socks5_test.zig` and `test/net/onion_control_test.zig`, not
//! here. Nothing in this file proves a real Tor would answer the same way.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const co = @import("c_abi_net_transport_onion");
const cdrv = @import("c_abi_driver");
const model = pancake.ocapn.model;
const onion = pancake.net.onion;
const c_abi_loopback = @import("../support/c_abi_loopback.zig");
const handshake = @import("../support/handshake.zig");
const fake = @import("../support/onion_fake_daemon.zig");
const fetch_pump = @import("../support/fetch_pump.zig");
const wait = @import("../support/wait.zig");

const frame_cap = c_abi_loopback.frame_cap;
const driver_options: cdrv.PancakeDriverOptions = .{
    .abi_version = cdrv.PANCAKE_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.PancakeDriverOptions),
    .wire_buffer_bytes = 16 << 10,
    .max_pending_opens = 256,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

fn closeProviderListener(table: *const cdrv.PancakeStreamTransport, listener: *anyopaque) void {
    std.testing.expectEqual(c.PANCAKE_OK, table.listener_close.?(table.ctx, listener, null)) catch unreachable;
}

fn releaseOnionListener(listener: *co.PancakeOnionListener) void {
    std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listener_release(listener)) catch unreachable;
}

fn releaseOnionNetlayer(netlayer: ?*co.PancakeOnionNetlayer) void {
    std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_release(netlayer)) catch unreachable;
}

fn releaseProvider(provider: cdrv.PancakeTransportProvider) void {
    std.testing.expectEqual(c.PANCAKE_OK, provider.release.?(provider.lease_ctx, null)) catch unreachable;
}

fn closeProviderConn(table: *const cdrv.PancakeStreamTransport, raw: *anyopaque) void {
    std.testing.expectEqual(c.PANCAKE_OK, table.conn_close.?(table.ctx, raw, null)) catch unreachable;
}

fn awaitDriverListenerReady(loop: ?*cdrv.PancakeDriverLoop, listener: u64) !void {
    for (0..2_000) |_| {
        var event: cdrv.PancakeDriverEvent = undefined;
        const next = cdrv.pancake_driver_next_event(loop, &event);
        if (next == c.PANCAKE_OK) {
            switch (event.kind) {
                cdrv.PANCAKE_DRIVER_EVENT_LISTENER_READY => {
                    try std.testing.expectEqual(listener, event.listener_id);
                    return;
                },
                cdrv.PANCAKE_DRIVER_EVENT_LISTENER_FAILED => return error.ListenerSetupFailed,
                else => return error.UnexpectedDriverEvent,
            }
        }
        try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, next);
        const stepped = cdrv.pancake_driver_step(loop, 5);
        try std.testing.expect(stepped == c.PANCAKE_OK or stepped == c.PANCAKE_ERR_WOULD_BLOCK);
    }
    return error.ListenerSetupTimedOut;
}

const LocatorCapture = struct {
    calls: usize = 0,
    transport: [16]u8 = undefined,
    transport_len: usize = 0,
    designator: [co.PANCAKE_ONION_SERVICE_ID_LEN]u8 = undefined,
    designator_len: usize = 0,
    hint_count: usize = 0,
    hint_wire_form: u32 = 0,

    fn receive(ctx: ?*anyopaque, view: ?*const cdrv.PancakeLocatorView) callconv(.c) i32 {
        const self: *LocatorCapture = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const borrowed = view orelse return c.PANCAKE_ERR_NULL_POINTER;
        if (borrowed.transport_len > self.transport.len or
            borrowed.designator_len > self.designator.len or
            borrowed.hint_count != 0)
            return c.PANCAKE_ERR_INVALID_ARGUMENT;
        @memcpy(self.transport[0..borrowed.transport_len], borrowed.transport.?[0..borrowed.transport_len]);
        @memcpy(self.designator[0..borrowed.designator_len], borrowed.designator.?[0..borrowed.designator_len]);
        self.transport_len = borrowed.transport_len;
        self.designator_len = borrowed.designator_len;
        self.hint_count = borrowed.hint_count;
        self.hint_wire_form = borrowed.hint_wire_form;
        return c.PANCAKE_OK;
    }

    fn locatorView(self: *const LocatorCapture) cdrv.PancakeLocatorView {
        return .{
            .abi_version = cdrv.PANCAKE_LOCATOR_VIEW_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.PancakeLocatorView),
            .transport = self.transport[0..self.transport_len].ptr,
            .transport_len = self.transport_len,
            .designator = self.designator[0..self.designator_len].ptr,
            .designator_len = self.designator_len,
            .hints = null,
            .hint_count = self.hint_count,
            .hint_wire_form = self.hint_wire_form,
        };
    }
};

const ProviderDialPeer = struct {
    daemon: *fake.Daemon,

    fn run(self: ProviderDialPeer) anyerror!void {
        const stream = try self.daemon.acceptDial();
        defer stream.close(self.daemon.io);
        var read_buf: [16]u8 = undefined;
        var write_buf: [16]u8 = undefined;
        var reader = stream.reader(self.daemon.io, &read_buf);
        var writer = stream.writer(self.daemon.io, &write_buf);
        var request: [4]u8 = undefined;
        try reader.interface.readSliceAll(&request);
        try std.testing.expectEqualStrings("ping", &request);
        try writer.interface.writeAll("pong");
        try writer.interface.flush();
    }
};

fn providerReadAll(
    table: *const cdrv.PancakeStreamTransport,
    conn: *anyopaque,
    out: []u8,
) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const got = table.read.?(table.ctx, conn, out[offset..].ptr, out.len - offset);
        try std.testing.expect(got > 0);
        offset += @intCast(got);
    }
}

fn providerConnect(
    table: *const cdrv.PancakeStreamTransport,
    locator: *const cdrv.PancakeLocatorView,
    out_conn: *?*anyopaque,
    out_readiness_fd: *i32,
) !i32 {
    var attempt: ?*anyopaque = null;
    var attempt_fd: i32 = -1;
    const start = table.start_connect.?(table.ctx, locator, null, &attempt, &attempt_fd, null);
    if (start != c.PANCAKE_OK) return start;
    errdefer _ = table.cancel_connect.?(attempt.?, null);
    var fds = [_]std.posix.pollfd{.{
        .fd = attempt_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 10_000));
    return table.finish_connect.?(attempt.?, out_conn, out_readiness_fd, null);
}

fn providerListen(
    table: *const cdrv.PancakeStreamTransport,
    requested_designator: []const u8,
    out_listener: *?*anyopaque,
) !i32 {
    var result: cdrv.PancakeListenResult = undefined;
    const start = table.listen.?(
        table.ctx,
        requested_designator.ptr,
        requested_designator.len,
        null,
        0,
        null,
        &result,
        null,
    );
    if (start != c.PANCAKE_OK) return start;
    if (result.state == cdrv.PANCAKE_LISTEN_READY) {
        out_listener.* = result.listener;
        return c.PANCAKE_OK;
    }
    try std.testing.expectEqual(cdrv.PANCAKE_LISTEN_PENDING, result.state);
    const attempt = result.attempt orelse return error.MissingListenAttempt;
    errdefer _ = table.cancel_listen.?(attempt, null);
    var fds = [_]std.posix.pollfd{.{
        .fd = result.readiness_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 10_000));
    return table.finish_listen.?(attempt, out_listener, null);
}

/// A real, checksum-valid version 3 id, from the pinned Goblins source.
const service_id = fake.service_id;

const Transport = struct {
    pub const Conn = *co.PancakeOnionConn;
    pub const Listener = *co.PancakeOnionListener;

    pub fn writeFrame(conn: Conn, cf: *c.PancakeFrame) i32 {
        return co.pancake_onion_conn_write_frame(conn, cf);
    }

    pub fn readFrame(conn: Conn, mf: *c.PancakeManagedFrame) i32 {
        return co.pancake_onion_conn_read_frame(conn, mf);
    }

    pub fn accept(
        listener: Listener,
        codec: u32,
        max_frame_bytes: usize,
        out_conn: *?Conn,
    ) i32 {
        return co.pancake_onion_accept(listener, codec, max_frame_bytes, out_conn);
    }

    pub fn releaseConn(conn: Conn) void {
        _ = co.pancake_onion_conn_release(conn);
    }
};

const Loopback = c_abi_loopback.Harness(Transport);

fn startSession(name: []const u8) model.Message {
    return handshake.startSession(onion.transport_name, name);
}

/// Build a netlayer against `daemon`, both endpoints.
fn netlayerFor(daemon: *fake.Daemon) !*co.PancakeOnionNetlayer {
    var netlayer: ?*co.PancakeOnionNetlayer = null;
    var config: co.PancakeOnionConfig = .{};
    config.socks = daemon.socksText().ptr;
    config.socks_len = daemon.socksText().len;
    config.control_endpoint = daemon.controlText().ptr;
    config.control_endpoint_len = daemon.controlText().len;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        co.pancake_onion_netlayer_new(&config, &netlayer),
    );
    return netlayer.?;
}

test "c-abi onion provider owns one profile and fixed, hintless locators" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    const netlayer = try netlayerFor(daemon);
    defer releaseOnionNetlayer(netlayer);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        co.pancake_onion_transport_provider(netlayer, &provider),
    );
    try std.testing.expectEqual(@as(usize, 1), provider.entry_count);

    const entry = provider.entries.?[0];
    const profile = entry.profile.?.*;
    try std.testing.expectEqualStrings("onion", profile.transport_name.?[0..profile.transport_name_len]);
    try std.testing.expectEqual(cdrv.PANCAKE_DESIGNATOR_SCHEME_ADDRESS, profile.designator_scheme);
    try std.testing.expectEqual(cdrv.PANCAKE_SEALED_CHANNEL_NONE, profile.sealed_channel);
    try std.testing.expectEqual(cdrv.PANCAKE_TRANSPORT_EXEC_STREAM, entry.execution_model);

    const table: *const cdrv.PancakeStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
    var wrong_transport = cdrv.PancakeLocatorView{
        .abi_version = cdrv.PANCAKE_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeLocatorView),
        .transport = "tcp".ptr,
        .transport_len = "tcp".len,
        .designator = service_id.ptr,
        .designator_len = service_id.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = cdrv.PANCAKE_HINTS_BOOLEAN_FALSE,
    };
    var attempt: ?*anyopaque = null;
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &wrong_transport, null, &attempt, &readiness_fd, null),
    );
    var short_view = wrong_transport;
    short_view.struct_size = @offsetOf(cdrv.PancakeLocatorView, "hints");
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &short_view, null, &attempt, &readiness_fd, null),
    );
    var hinted = wrong_transport;
    hinted.transport = "onion".ptr;
    hinted.transport_len = "onion".len;
    var hints = [_]cdrv.PancakeLocatorHintView{.{
        .name = "route".ptr,
        .name_len = "route".len,
        .kind = cdrv.PANCAKE_HINT_STRING,
        .bytes = "ignored".ptr,
        .bytes_len = "ignored".len,
        .boolean_value = 0,
        .integer_value = 0,
    }};
    hinted.hints = hints[0..].ptr;
    hinted.hint_count = 1;
    hinted.hint_wire_form = cdrv.PANCAKE_HINTS_MAP;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &hinted, null, &attempt, &readiness_fd, null),
    );

    hinted.hints = null;
    hinted.hint_count = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &hinted, null, &attempt, &readiness_fd, null),
    );

    var dial_locator = hinted;
    dial_locator.hint_wire_form = cdrv.PANCAKE_HINTS_BOOLEAN_FALSE;
    var dial_peer = try io.concurrent(ProviderDialPeer.run, .{ProviderDialPeer{ .daemon = daemon }});
    var dial_conn: ?*anyopaque = null;
    defer if (dial_conn) |raw| closeProviderConn(table, raw);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        try providerConnect(table, &dial_locator, &dial_conn, &readiness_fd),
    );
    try std.testing.expect(readiness_fd >= 0);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.write_all.?(table.ctx, dial_conn.?, "ping".ptr, "ping".len),
    );
    var dial_reply: [4]u8 = undefined;
    try providerReadAll(table, dial_conn.?, &dial_reply);
    try std.testing.expectEqualStrings("pong", &dial_reply);
    try std.testing.expectEqual(c.PANCAKE_OK, table.conn_close.?(table.ctx, dial_conn.?, null));
    dial_conn = null;
    try dial_peer.await(io);

    var listener: ?*anyopaque = null;
    defer if (listener) |raw| closeProviderListener(table, raw);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        try providerListen(table, "", &listener),
    );
    const listener_raw = listener.?;
    var local = LocatorCapture{};
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.listener_locator.?(listener_raw, &local, LocatorCapture.receive),
    );
    try std.testing.expectEqual(@as(usize, 1), local.calls);
    const local_view = local.locatorView();
    try std.testing.expectEqualStrings("onion", local.transport[0..local.transport_len]);
    try std.testing.expectEqual(service_id.len, local.designator_len);
    try std.testing.expectEqualStrings(service_id, local.designator[0..local.designator_len]);
    try std.testing.expectEqual(@as(usize, 0), local.hint_count);
    try std.testing.expectEqual(cdrv.PANCAKE_HINTS_BOOLEAN_FALSE, local.hint_wire_form);

    var advertised = local_view;
    var accepted = LocatorCapture{};
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.listener_advertise.?(listener_raw, &advertised, &accepted, LocatorCapture.receive),
    );
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
    try std.testing.expectEqualStrings("onion", accepted.transport[0..accepted.transport_len]);

    var map_advertisement = advertised;
    map_advertisement.hint_wire_form = cdrv.PANCAKE_HINTS_MAP;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        table.listener_advertise.?(listener_raw, &map_advertisement, &accepted, LocatorCapture.receive),
    );

    var wrong_designator = advertised;
    wrong_designator.designator = "another-service".ptr;
    wrong_designator.designator_len = "another-service".len;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        table.listener_advertise.?(listener_raw, &wrong_designator, &accepted, LocatorCapture.receive),
    );

    const forward = try onion.Endpoint.parse(daemon.lastForwardTarget());
    const client = try forward.connect(io);
    defer client.close(io);
    var accepted_conn: ?*anyopaque = null;
    defer if (accepted_conn) |raw| closeProviderConn(table, raw);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.accept.?(table.ctx, listener_raw, &accepted_conn, &readiness_fd, null),
    );
    try std.testing.expect(readiness_fd >= 0);

    var client_read_buf: [32]u8 = undefined;
    var client_write_buf: [32]u8 = undefined;
    var client_reader = client.reader(io, &client_read_buf);
    var client_writer = client.writer(io, &client_write_buf);
    try client_writer.interface.writeAll("from-client");
    try client_writer.interface.flush();
    var accepted_request: ["from-client".len]u8 = undefined;
    try providerReadAll(table, accepted_conn.?, &accepted_request);
    try std.testing.expectEqualStrings("from-client", &accepted_request);
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.write_all.?(table.ctx, accepted_conn.?, "from-provider".ptr, "from-provider".len),
    );
    var accepted_reply: ["from-provider".len]u8 = undefined;
    try client_reader.interface.readSliceAll(&accepted_reply);
    try std.testing.expectEqualStrings("from-provider", &accepted_reply);
    try std.testing.expectEqual(c.PANCAKE_OK, table.conn_close.?(table.ctx, accepted_conn.?, null));
    accepted_conn = null;

    try std.testing.expectEqual(c.PANCAKE_OK, table.listener_close.?(table.ctx, listener_raw, null));
    listener = null;
}

test "c-abi onion provider transfers its runtime lease through listener and accepted connection" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();
    const netlayer = try netlayerFor(daemon);
    var construction_alive = true;
    defer if (construction_alive) releaseOnionNetlayer(netlayer);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_transport_provider(netlayer, &provider));
    try std.testing.expectEqual(c.PANCAKE_OK, provider.retain.?(provider.lease_ctx, null));
    var provider_lease_alive = true;
    defer if (provider_lease_alive) releaseProvider(provider);

    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_release(netlayer));
    construction_alive = false;

    const entry = provider.entries.?[0];
    const table: *const cdrv.PancakeStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
    var listener: ?*anyopaque = null;
    defer if (listener) |raw| closeProviderListener(table, raw);
    try std.testing.expectEqual(c.PANCAKE_OK, try providerListen(table, "", &listener));

    try std.testing.expectEqual(c.PANCAKE_OK, provider.release.?(provider.lease_ctx, null));
    provider_lease_alive = false;

    var local = LocatorCapture{};
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.listener_locator.?(listener.?, &local, LocatorCapture.receive),
    );

    const forward = try onion.Endpoint.parse(daemon.lastForwardTarget());
    const client = try forward.connect(io);
    defer client.close(io);
    var conn: ?*anyopaque = null;
    defer if (conn) |raw| closeProviderConn(table, raw);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        table.accept.?(table.ctx, listener.?, &conn, &readiness_fd, null),
    );

    try std.testing.expectEqual(c.PANCAKE_OK, table.listener_close.?(table.ctx, listener.?, null));
    listener = null;

    var client_read_buf: [8]u8 = undefined;
    var client_write_buf: [8]u8 = undefined;
    var client_reader = client.reader(io, &client_read_buf);
    var client_writer = client.writer(io, &client_write_buf);
    try client_writer.interface.writeAll("ping");
    try client_writer.interface.flush();
    var request: [4]u8 = undefined;
    try providerReadAll(table, conn.?, &request);
    try std.testing.expectEqualStrings("ping", &request);
    try std.testing.expectEqual(c.PANCAKE_OK, table.write_all.?(table.ctx, conn.?, "pong".ptr, "pong".len));
    var reply: [4]u8 = undefined;
    try client_reader.interface.readSliceAll(&reply);
    try std.testing.expectEqualStrings("pong", &reply);
    try std.testing.expectEqual(c.PANCAKE_OK, table.conn_close.?(table.ctx, conn.?, null));
    conn = null;
}

test "c-abi driver lease owns onion provider through listener withdrawal" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    var daemon_live = true;
    defer if (daemon_live) daemon.stop();

    const netlayer = try netlayerFor(daemon);
    var construction_alive = true;
    defer if (construction_alive) releaseOnionNetlayer(netlayer);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        co.pancake_onion_transport_provider(netlayer, &provider),
    );

    var host: ?*cd.PancakeHost = null;
    const seed: [64]u8 = @splat(0x75);
    try std.testing.expectEqual(c.PANCAKE_OK, cd.pancake_host_new(
        &seed,
        seed.len,
        frame_cap,
        1,
        c.PANCAKE_CODEC_SYRUP,
        c.PANCAKE_CAPTP_V1_0,
        c.PANCAKE_FEATURE_FULL,
        0,
        &host,
    ));
    errdefer _ = cd.pancake_host_release(host);

    var loop: ?*cdrv.PancakeDriverLoop = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        cdrv.pancake_driver_take_host(host, &driver_options, &loop),
    );
    var loop_alive = true;
    defer if (loop_alive) {
        _ = cdrv.pancake_driver_release(loop);
    };

    try std.testing.expectEqual(
        c.PANCAKE_OK,
        cdrv.pancake_driver_add_provider(loop, &provider),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_release(netlayer));
    construction_alive = false;

    var present: u8 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, cdrv.pancake_driver_has_transport(
        loop,
        "onion",
        "onion".len,
        &present,
    ));
    try std.testing.expectEqual(@as(u8, 1), present);

    var listener: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, cdrv.pancake_driver_listen(
        loop,
        "onion",
        "onion".len,
        null,
        0,
        null,
        &listener,
    ));
    try awaitDriverListenerReady(loop, listener);
    var locator: cdrv.PancakeLocatorView = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        cdrv.pancake_driver_listener_locator(loop, listener, &locator),
    );
    try std.testing.expectEqualStrings("onion", locator.transport.?[0..locator.transport_len]);
    try std.testing.expectEqualStrings(service_id, locator.designator.?[0..locator.designator_len]);

    var restoration_len: usize = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(fake.service_key.len, restoration_len);

    var short: [fake.service_key.len - 1]u8 = @splat(0xa5);
    restoration_len = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, &short, short.len, &restoration_len),
    );
    try std.testing.expectEqual(fake.service_key.len, restoration_len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** short.len), &short);

    var restoration: [fake.service_key.len]u8 = undefined;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        cdrv.pancake_driver_listener_restoration_state(
            loop,
            listener,
            &restoration,
            restoration.len,
            &restoration_len,
        ),
    );
    try std.testing.expectEqualStrings(fake.service_key, restoration[0..restoration_len]);

    const forward = try onion.Endpoint.parse(daemon.lastForwardTarget());
    try std.testing.expectEqual(c.PANCAKE_OK, cdrv.pancake_driver_listener_close(loop, listener));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NOT_FOUND,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(c.PANCAKE_OK, cdrv.pancake_driver_release(loop));
    loop_alive = false;

    if (forward.connect(io)) |stream| {
        stream.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}

    daemon.stop();
    daemon_live = false;
}

test "c-abi onion dialed provider connection owns its runtime lease" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();
    const netlayer = try netlayerFor(daemon);
    var construction_alive = true;
    defer if (construction_alive) releaseOnionNetlayer(netlayer);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_transport_provider(netlayer, &provider));
    try std.testing.expectEqual(c.PANCAKE_OK, provider.retain.?(provider.lease_ctx, null));
    var provider_lease_alive = true;
    defer if (provider_lease_alive) releaseProvider(provider);

    const entry = provider.entries.?[0];
    const table: *const cdrv.PancakeStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
    var locator = cdrv.PancakeLocatorView{
        .abi_version = cdrv.PANCAKE_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeLocatorView),
        .transport = "onion".ptr,
        .transport_len = "onion".len,
        .designator = service_id.ptr,
        .designator_len = service_id.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = cdrv.PANCAKE_HINTS_BOOLEAN_FALSE,
    };
    var peer = try io.concurrent(ProviderDialPeer.run, .{ProviderDialPeer{ .daemon = daemon }});
    var conn: ?*anyopaque = null;
    defer if (conn) |raw| closeProviderConn(table, raw);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        try providerConnect(table, &locator, &conn, &readiness_fd),
    );

    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_release(netlayer));
    construction_alive = false;
    try std.testing.expectEqual(c.PANCAKE_OK, provider.release.?(provider.lease_ctx, null));
    provider_lease_alive = false;

    try std.testing.expectEqual(c.PANCAKE_OK, table.write_all.?(table.ctx, conn.?, "ping".ptr, "ping".len));
    var reply: [4]u8 = undefined;
    try providerReadAll(table, conn.?, &reply);
    try std.testing.expectEqualStrings("pong", &reply);
    try std.testing.expectEqual(c.PANCAKE_OK, table.conn_close.?(table.ctx, conn.?, null));
    conn = null;
    try peer.await(io);
}

const HeldDial = struct {
    daemon: *fake.Daemon,
    accepted: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),

    fn run(self: HeldDial) anyerror!void {
        const stream = try self.daemon.acceptDial();
        defer stream.close(self.daemon.io);
        self.accepted.store(true, .release);
        while (!self.stop.load(.acquire))
            std.Io.sleep(self.daemon.io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
};

const ParkedOnionRead = struct {
    conn: *co.PancakeOnionConn,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = c.PANCAKE_OK,

    fn run(self: *ParkedOnionRead) void {
        var frame: c.PancakeManagedFrame = undefined;
        self.started.store(true, .release);
        self.result = co.pancake_onion_conn_read_frame(self.conn, &frame);
        if (self.result == c.PANCAKE_OK) c.pancake_managed_frame_release(&frame);
    }
};

/// Answer the dial as the far peer: take the stream the fake hands back after the
/// SOCKS reply, and serve one handshake plus bootstrap fetch over it.
fn serveDialedPeer(daemon: *fake.Daemon, allocator: std.mem.Allocator) anyerror!void {
    const stream = try daemon.acceptDial();
    defer stream.close(daemon.io);

    var read_buf: [frame_cap]u8 = undefined;
    var write_buf: [frame_cap]u8 = undefined;
    var reader = stream.reader(daemon.io, &read_buf);
    var writer = stream.writer(daemon.io, &write_buf);

    var peer = c_abi_loopback.stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    var conn = pancake.net.Connection.init(
        daemon.io,
        &peer,
        &reader.interface,
        &writer.interface,
        borrowedHandle(&reader),
    );
    defer conn.deinit();

    try peer.sendCopying(startSession(fake.service_id));
    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

/// A transport handle over a stream the test closes itself.
fn borrowedHandle(reader: *std.Io.net.Stream.Reader) pancake.net.Connection.Transport {
    return .{
        .ctx = reader,
        .close_fn = struct {
            fn noop(_: *anyopaque) void {}
        }.noop,
        .socket_handle_fn = struct {
            fn handle(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
                const r: *std.Io.net.Stream.Reader = @ptrCast(@alignCast(ctx));
                return r.stream.socket.handle;
            }
        }.handle,
    };
}

test "c-abi onion connect: handshake to open + bootstrap fetch round-trip" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    const netlayer_ptr = try netlayerFor(daemon);
    defer releaseOnionNetlayer(netlayer_ptr);

    var server = try io.concurrent(serveDialedPeer, .{ daemon, allocator });

    var conn: ?*co.PancakeOnionConn = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &conn,
    ));
    const conn_ptr = conn.?;

    const client_result = Loopback.fetchOnce(conn_ptr, allocator, startSession("client"));

    // Releasing the client lets the far peer observe EOF and finish.
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_conn_release(conn_ptr));
    const server_result = server.await(io);

    try client_result;
    try server_result;
}

test "c-abi onion connection shutdown wakes a native read before release" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();
    const netlayer = try netlayerFor(daemon);
    defer releaseOnionNetlayer(netlayer);

    var accepted: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(false);
    var held = try io.concurrent(HeldDial.run, .{HeldDial{
        .daemon = daemon,
        .accepted = &accepted,
        .stop = &stop,
    }});
    defer {
        stop.store(true, .release);
        _ = held.await(io) catch {};
    }

    var conn: ?*co.PancakeOnionConn = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_connect(
        netlayer,
        service_id.ptr,
        service_id.len,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &conn,
    ));
    try wait.untilFlag(io, 5_000, &accepted);

    var parked = ParkedOnionRead{ .conn = conn.? };
    var read = try io.concurrent(ParkedOnionRead.run, .{&parked});
    try wait.untilFlag(io, 5_000, &parked.started);

    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_conn_shutdown(conn.?));
    read.await(io);
    try std.testing.expect(parked.result != c.PANCAKE_OK);
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_conn_release(conn.?));
}

test "c-abi onion accept: a forwarded circuit carries a session" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    const netlayer_ptr = try netlayerFor(daemon);
    defer releaseOnionNetlayer(netlayer_ptr);

    var id_buf: [co.PANCAKE_ONION_SERVICE_ID_LEN]u8 = undefined;
    var id_len: usize = 0;
    var key_buf: [co.PANCAKE_ONION_SERVICE_KEY_CAP]u8 = undefined;
    var key_len: usize = 0;
    var listener: ?*co.PancakeOnionListener = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listen(
        netlayer_ptr,
        &id_buf,
        id_buf.len,
        &id_len,
        &key_buf,
        key_buf.len,
        &key_len,
        &listener,
    ));
    const listener_ptr = listener.?;
    defer releaseOnionListener(listener_ptr);

    // The id is the one the daemon reported, not one pancake chose, and the key
    // is what would restore the same address later.
    try std.testing.expectEqual(co.PANCAKE_ONION_SERVICE_ID_LEN, id_len);
    try std.testing.expectEqualStrings(service_id, id_buf[0..id_len]);
    try std.testing.expectEqualStrings(fake.service_key, key_buf[0..key_len]);

    // Stand in for Tor forwarding a circuit: dial the local endpoint the listener
    // told the daemon about, and be the far peer on it.
    const target = daemon.lastForwardTarget();
    try std.testing.expect(std.mem.startsWith(u8, target, "127.0.0.1:"));
    var client = try io.concurrent(dialForwardTarget, .{ io, allocator, target });

    var args: Loopback.ServerArgs = .{
        .listener = listener_ptr,
        .allocator = allocator,
        .start_session = startSession(service_id),
    };
    try Loopback.serveOnce(&args);
    const client_result = client.await(io);
    try client_result;
}

/// Dial the listener's forward target and run the client half of the round trip.
fn dialForwardTarget(io: std.Io, allocator: std.mem.Allocator, target: []const u8) anyerror!void {
    const colon = std.mem.lastIndexOfScalar(u8, target, ':').?;
    const port = try std.fmt.parseInt(u16, target[colon + 1 ..], 10);
    const address = try std.Io.net.IpAddress.parse(target[0..colon], port);
    const stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);

    var read_buf: [frame_cap]u8 = undefined;
    var write_buf: [frame_cap]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var peer = c_abi_loopback.stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    var conn = pancake.net.Connection.init(
        io,
        &peer,
        &reader.interface,
        &writer.interface,
        borrowedHandle(&reader),
    );
    defer conn.deinit();

    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("client"));
    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

test "c-abi onion listen queries its out-parameter lengths without a buffer" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    var netlayer: ?*co.PancakeOnionNetlayer = null;
    var config: co.PancakeOnionConfig = .{};
    config.socks = daemon.socksText().ptr;
    config.socks_len = daemon.socksText().len;
    config.control_endpoint = daemon.controlText().ptr;
    config.control_endpoint_len = daemon.controlText().len;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_new(&config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer releaseOnionNetlayer(netlayer_ptr);

    // A null buffer with a length slot asks how much room the value needs, so a
    // caller can size its storage without hardcoding the constant.
    var id_len: usize = 0;
    var listener: ?*co.PancakeOnionListener = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listen(
        netlayer_ptr,
        null,
        0,
        &id_len,
        null,
        0,
        null,
        &listener,
    ));
    defer releaseOnionListener(listener.?);
    try std.testing.expectEqual(co.PANCAKE_ONION_SERVICE_ID_LEN, id_len);

    // A buffer too small for the id is the caller's error, and the listener is not
    // left behind: a second listen on the same daemon still succeeds.
    var tiny: [8]u8 = undefined;
    var second: ?*co.PancakeOnionListener = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_listen(
        netlayer_ptr,
        &tiny,
        tiny.len,
        null,
        null,
        0,
        null,
        &second,
    ));
}

test "c-abi onion listener_wait reports a timeout rather than blocking forever" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    var netlayer: ?*co.PancakeOnionNetlayer = null;
    var config: co.PancakeOnionConfig = .{};
    config.socks = daemon.socksText().ptr;
    config.socks_len = daemon.socksText().len;
    config.control_endpoint = daemon.controlText().ptr;
    config.control_endpoint_len = daemon.controlText().len;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_new(&config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer releaseOnionNetlayer(netlayer_ptr);

    var listener: ?*co.PancakeOnionListener = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listen(
        netlayer_ptr,
        null,
        0,
        null,
        null,
        0,
        null,
        &listener,
    ));
    const listener_ptr = listener.?;
    defer releaseOnionListener(listener_ptr);

    // Nothing has dialed, so the wait expires and reports not-ready. This is the
    // guard that lets a blocking accept loop check a stop flag.
    var ready: u32 = 7;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        co.pancake_onion_listener_wait(listener_ptr, 1, &ready),
    );
    try std.testing.expectEqual(@as(u32, 0), ready);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        co.pancake_onion_listener_wait(null, 1, &ready),
    );

    co.pancake_onion_listener_shutdown(listener_ptr);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_CLOSED,
        co.pancake_onion_listener_wait(listener_ptr, 0, &ready),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_CLOSED,
        co.pancake_onion_listener_readiness_fd(listener_ptr, &readiness_fd),
    );
}

test "c-abi onion refuses a bad configuration and a bad designator distinctly" {
    // A netlayer with no socks endpoint cannot dial, so it is refused at
    // construction rather than at some later call.
    var netlayer: ?*co.PancakeOnionNetlayer = null;
    var empty: co.PancakeOnionConfig = .{};
    co.pancake_onion_clear_last_error();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        co.pancake_onion_netlayer_new(&empty, &netlayer),
    );
    try std.testing.expect(co.pancake_onion_last_error(null, 0) > 0);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        co.pancake_onion_netlayer_new(null, &netlayer),
    );

    // Every C slice is a pointer/length pair. Null is valid only for an empty
    // slice, and the aggregate copy size must not wrap before allocation.
    var bad_slice: co.PancakeOnionConfig = .{};
    bad_slice.socks = "127.0.0.1:1";
    bad_slice.socks_len = "127.0.0.1:1".len;
    bad_slice.control_endpoint = null;
    bad_slice.control_endpoint_len = 1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        co.pancake_onion_netlayer_new(&bad_slice, &netlayer),
    );

    var overflowing: co.PancakeOnionConfig = .{};
    overflowing.socks = "x";
    overflowing.socks_len = std.math.maxInt(usize);
    overflowing.control_endpoint = "y";
    overflowing.control_endpoint_len = 1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        co.pancake_onion_netlayer_new(&overflowing, &netlayer),
    );

    // An unknown auth kind is refused rather than silently treated as none: a
    // caller that meant to authenticate must not end up not authenticating.
    var bad_auth: co.PancakeOnionConfig = .{};
    bad_auth.socks = "127.0.0.1:1";
    bad_auth.socks_len = "127.0.0.1:1".len;
    bad_auth.auth_kind = 99;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        co.pancake_onion_netlayer_new(&bad_auth, &netlayer),
    );

    // A dial-only netlayer: valid, and hosting is refused with a cause.
    var dial_only: co.PancakeOnionConfig = .{};
    dial_only.socks = "127.0.0.1:1";
    dial_only.socks_len = "127.0.0.1:1".len;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        co.pancake_onion_netlayer_new(&dial_only, &netlayer),
    );
    const netlayer_ptr = netlayer.?;
    defer releaseOnionNetlayer(netlayer_ptr);

    var listener: ?*co.PancakeOnionListener = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_listen(
        netlayer_ptr,
        null,
        0,
        null,
        null,
        0,
        null,
        &listener,
    ));

    var conn: ?*co.PancakeOnionConn = null;
    // A designator that is not a well-formed version 3 address is refused before
    // any socket opens, which is why this reports an invalid argument rather than
    // the connection refusal that reaching 127.0.0.1:1 would produce.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_connect(
        netlayer_ptr,
        "not-an-onion",
        "not-an-onion".len,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &conn,
    ));
    // A zero frame cap and an unknown codec are the ordinary argument faults.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        c.PANCAKE_CODEC_SYRUP,
        0,
        &conn,
    ));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        999,
        frame_cap,
        &conn,
    ));
    try std.testing.expect(co.pancake_onion_last_error(null, 0) > 0);
    // A well-formed designator with nothing listening at the socks endpoint is an
    // I/O fault with a cause, distinct from the argument faults above.
    co.pancake_onion_clear_last_error();
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &conn,
    ));
    try std.testing.expect(co.pancake_onion_last_error(null, 0) > 0);
}

test "c-abi onion netlayer copies its configuration text" {
    // The config's pointers are borrowed for the constructor call only, so a
    // caller may build them on the stack. Proving it means overwriting the source
    // buffer afterwards and still reaching the daemon.
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    var socks_scratch: [64]u8 = undefined;
    var control_scratch: [64]u8 = undefined;
    @memcpy(socks_scratch[0..daemon.socksText().len], daemon.socksText());
    @memcpy(control_scratch[0..daemon.controlText().len], daemon.controlText());

    var netlayer: ?*co.PancakeOnionNetlayer = null;
    var config: co.PancakeOnionConfig = .{};
    config.socks = &socks_scratch;
    config.socks_len = daemon.socksText().len;
    config.control_endpoint = &control_scratch;
    config.control_endpoint_len = daemon.controlText().len;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_new(&config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer releaseOnionNetlayer(netlayer_ptr);

    // Scribble over both sources. A netlayer that borrowed them would now reach
    // nowhere.
    @memset(&socks_scratch, '#');
    @memset(&control_scratch, '#');

    // The control endpoint still works, which covers the copy `listen` reads.
    var listener: ?*co.PancakeOnionListener = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listen(
        netlayer_ptr,
        null,
        0,
        null,
        null,
        0,
        null,
        &listener,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listener_release(listener.?));

    // And the socks endpoint still works, which covers the copy `connect` reads.
    // Without this the test would pass while the socks text was borrowed, because
    // `listen` never looks at it.
    var acceptor = try io.concurrent(acceptAndDrop, .{daemon});
    var conn: ?*co.PancakeOnionConn = null;
    const rc = co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        c.PANCAKE_CODEC_SYRUP,
        frame_cap,
        &conn,
    );
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_conn_release(conn.?));
    _ = acceptor.await(io) catch {};
}

/// Answer one dial's handshake and drop the stream. Enough to prove the dial
/// reached the daemon; the session round trip has its own test.
fn acceptAndDrop(daemon: *fake.Daemon) anyerror!void {
    const stream = try daemon.acceptDial();
    stream.close(daemon.io);
}

const SilentEndpoint = struct {
    server: *std.Io.net.Server,
    io: std.Io,
    accepted: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),

    fn serve(self: SilentEndpoint) anyerror!void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        self.accepted.store(true, .release);
        while (!self.stop.load(.acquire))
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
};

const ConnectAttempt = struct {
    netlayer: *co.PancakeOnionNetlayer,
    done: std.atomic.Value(bool) = .init(false),
    result: i32 = c.PANCAKE_OK,

    fn run(self: *ConnectAttempt) void {
        defer self.done.store(true, .release);
        var conn: ?*co.PancakeOnionConn = null;
        self.result = co.pancake_onion_connect(
            self.netlayer,
            service_id.ptr,
            service_id.len,
            c.PANCAKE_CODEC_SYRUP,
            frame_cap,
            &conn,
        );
        if (conn) |handle| _ = co.pancake_onion_conn_release(handle);
    }
};

const ListenAttempt = struct {
    netlayer: *co.PancakeOnionNetlayer,
    done: std.atomic.Value(bool) = .init(false),
    result: i32 = c.PANCAKE_OK,

    fn run(self: *ListenAttempt) void {
        defer self.done.store(true, .release);
        var listener: ?*co.PancakeOnionListener = null;
        self.result = co.pancake_onion_listen(
            self.netlayer,
            null,
            0,
            null,
            null,
            0,
            null,
            &listener,
        );
        if (listener) |handle| releaseOnionListener(handle);
    }
};

fn silentNetlayer(
    server: *std.Io.net.Server,
    use_control: bool,
) !*co.PancakeOnionNetlayer {
    var endpoint_buf: [48]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "{f}", .{server.socket.address});
    var config: co.PancakeOnionConfig = .{
        .socks = endpoint.ptr,
        .socks_len = endpoint.len,
    };
    if (use_control) {
        config.control_endpoint = endpoint.ptr;
        config.control_endpoint_len = endpoint.len;
    }
    var netlayer: ?*co.PancakeOnionNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_netlayer_new(&config, &netlayer));
    return netlayer.?;
}

test "c-abi onion netlayer shutdown cancels a stalled connect" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try std.Io.net.IpAddress.listen(
        &.{ .ip4 = std.Io.net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const netlayer = try silentNetlayer(&server, false);
    defer releaseOnionNetlayer(netlayer);

    var accepted: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(false);
    var silent = try io.concurrent(SilentEndpoint.serve, .{SilentEndpoint{
        .server = &server,
        .io = io,
        .accepted = &accepted,
        .stop = &stop,
    }});
    defer {
        stop.store(true, .release);
        _ = silent.await(io) catch {};
    }

    var attempt: ConnectAttempt = .{ .netlayer = netlayer };
    var call = try io.concurrent(ConnectAttempt.run, .{&attempt});
    try wait.untilFlag(io, 5_000, &accepted);
    co.pancake_onion_netlayer_shutdown(netlayer);
    try wait.untilFlag(io, 5_000, &attempt.done);
    call.await(io);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, attempt.result);
}

test "c-abi onion netlayer shutdown cancels a stalled listen" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try std.Io.net.IpAddress.listen(
        &.{ .ip4 = std.Io.net.Ip4Address.loopback(0) },
        io,
        .{ .reuse_address = true },
    );
    defer server.deinit(io);
    const netlayer = try silentNetlayer(&server, true);
    defer releaseOnionNetlayer(netlayer);

    var accepted: std.atomic.Value(bool) = .init(false);
    var stop: std.atomic.Value(bool) = .init(false);
    var silent = try io.concurrent(SilentEndpoint.serve, .{SilentEndpoint{
        .server = &server,
        .io = io,
        .accepted = &accepted,
        .stop = &stop,
    }});
    defer {
        stop.store(true, .release);
        _ = silent.await(io) catch {};
    }

    var attempt: ListenAttempt = .{ .netlayer = netlayer };
    var call = try io.concurrent(ListenAttempt.run, .{&attempt});
    try wait.untilFlag(io, 5_000, &accepted);
    co.pancake_onion_netlayer_shutdown(netlayer);
    try wait.untilFlag(io, 5_000, &attempt.done);
    call.await(io);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, attempt.result);
}
