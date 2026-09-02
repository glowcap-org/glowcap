//! The `glowcap_onion_*` provider surface against fake Tor daemons: one
//! profile with fixed hintless locators, runtime-lease transfer through
//! listener and accepted connection, driver-lease ownership through listener
//! withdrawal, and the dialed connection's own lease.

const std = @import("std");
const glowcap = @import("glowcap");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const co = @import("c_abi_net_transport_onion");
const cdrv = @import("c_abi_driver");
const model = glowcap.ocapn.model;
const onion = glowcap.net.onion;
const c_abi_loopback = @import("../../support/c_abi_loopback.zig");
const handshake = @import("../../support/handshake.zig");
const fake = @import("../../support/onion_fake_daemon.zig");
const fetch_pump = @import("../../support/fetch_pump.zig");
const wait = @import("../../support/wait.zig");

const frame_cap = c_abi_loopback.frame_cap;

const harness = @import("harness.zig");
const releaseOnionListener = harness.releaseOnionListener;
const releaseOnionNetlayer = harness.releaseOnionNetlayer;
const Transport = harness.Transport;
const Loopback = harness.Loopback;
const startSession = harness.startSession;
const netlayerFor = harness.netlayerFor;
const service_id = harness.service_id;

const driver_options: cdrv.GlowcapDriverOptions = .{
    .abi_version = cdrv.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION,
    .struct_size = @sizeOf(cdrv.GlowcapDriverOptions),
    .wire_buffer_bytes = 16 << 10,
    .max_pending_opens = 256,
    .handshake_ms = 1_000,
    .listener_setup_ms = 1_000,
    .settle_ms = 1_000,
};

fn closeProviderListener(table: *const cdrv.GlowcapStreamTransport, listener: *anyopaque) void {
    std.testing.expectEqual(c.GLOWCAP_OK, table.listener_close.?(table.ctx, listener, null)) catch unreachable;
}

fn releaseProvider(provider: cdrv.GlowcapTransportProvider) void {
    std.testing.expectEqual(c.GLOWCAP_OK, provider.release.?(provider.lease_ctx, null)) catch unreachable;
}

fn closeProviderConn(table: *const cdrv.GlowcapStreamTransport, raw: *anyopaque) void {
    std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, raw, null)) catch unreachable;
}

fn awaitDriverListenerReady(loop: ?*cdrv.GlowcapDriverLoop, listener: u64) !void {
    for (0..2_000) |_| {
        var event: cdrv.GlowcapDriverEvent = undefined;
        const next = cdrv.glowcap_driver_next_event(loop, &event);
        if (next == c.GLOWCAP_OK) {
            switch (event.kind) {
                cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_READY => {
                    try std.testing.expectEqual(listener, event.listener_id);
                    return;
                },
                cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED => return error.ListenerSetupFailed,
                else => return error.UnexpectedDriverEvent,
            }
        }
        try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, next);
        const stepped = cdrv.glowcap_driver_step(loop, 5);
        try std.testing.expect(stepped == c.GLOWCAP_OK or stepped == c.GLOWCAP_ERR_WOULD_BLOCK);
    }
    return error.ListenerSetupTimedOut;
}

const LocatorCapture = struct {
    calls: usize = 0,
    transport: [16]u8 = undefined,
    transport_len: usize = 0,
    designator: [co.GLOWCAP_ONION_SERVICE_ID_LEN]u8 = undefined,
    designator_len: usize = 0,
    hint_count: usize = 0,
    hint_wire_form: u32 = 0,

    fn receive(ctx: ?*anyopaque, view: ?*const cdrv.GlowcapLocatorView) callconv(.c) i32 {
        const self: *LocatorCapture = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const borrowed = view orelse return c.GLOWCAP_ERR_NULL_POINTER;
        if (borrowed.transport_len > self.transport.len or
            borrowed.designator_len > self.designator.len or
            borrowed.hint_count != 0)
            return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        @memcpy(self.transport[0..borrowed.transport_len], borrowed.transport.?[0..borrowed.transport_len]);
        @memcpy(self.designator[0..borrowed.designator_len], borrowed.designator.?[0..borrowed.designator_len]);
        self.transport_len = borrowed.transport_len;
        self.designator_len = borrowed.designator_len;
        self.hint_count = borrowed.hint_count;
        self.hint_wire_form = borrowed.hint_wire_form;
        return c.GLOWCAP_OK;
    }

    fn locatorView(self: *const LocatorCapture) cdrv.GlowcapLocatorView {
        return .{
            .abi_version = cdrv.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapLocatorView),
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
    table: *const cdrv.GlowcapStreamTransport,
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
    table: *const cdrv.GlowcapStreamTransport,
    locator: *const cdrv.GlowcapLocatorView,
    out_conn: *?*anyopaque,
    out_readiness_fd: *i32,
) !i32 {
    var attempt: ?*anyopaque = null;
    var attempt_fd: i32 = -1;
    const start = table.start_connect.?(table.ctx, locator, null, &attempt, &attempt_fd, null);
    if (start != c.GLOWCAP_OK) return start;
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
    table: *const cdrv.GlowcapStreamTransport,
    requested_designator: []const u8,
    out_listener: *?*anyopaque,
) !i32 {
    var result: cdrv.GlowcapListenResult = undefined;
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
    if (start != c.GLOWCAP_OK) return start;
    if (result.state == cdrv.GLOWCAP_LISTEN_READY) {
        out_listener.* = result.listener;
        return c.GLOWCAP_OK;
    }
    try std.testing.expectEqual(cdrv.GLOWCAP_LISTEN_PENDING, result.state);
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

test "c-abi onion provider owns one profile and fixed, hintless locators" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var daemon = try fake.Daemon.start(allocator, io);
    defer daemon.stop();

    const netlayer = try netlayerFor(daemon);
    defer releaseOnionNetlayer(netlayer);
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        co.glowcap_onion_transport_provider(netlayer, &provider),
    );
    try std.testing.expectEqual(@as(usize, 1), provider.entry_count);

    const entry = provider.entries.?[0];
    const profile = entry.profile.?.*;
    try std.testing.expectEqualStrings("onion", profile.transport_name.?[0..profile.transport_name_len]);
    try std.testing.expectEqual(cdrv.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS, profile.designator_scheme);
    try std.testing.expectEqual(cdrv.GLOWCAP_SEALED_CHANNEL_NONE, profile.sealed_channel);
    try std.testing.expectEqual(cdrv.GLOWCAP_TRANSPORT_EXEC_STREAM, entry.execution_model);

    const table: *const cdrv.GlowcapStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
    var wrong_transport = cdrv.GlowcapLocatorView{
        .abi_version = cdrv.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapLocatorView),
        .transport = "tcp".ptr,
        .transport_len = "tcp".len,
        .designator = service_id.ptr,
        .designator_len = service_id.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = cdrv.GLOWCAP_HINTS_BOOLEAN_FALSE,
    };
    var attempt: ?*anyopaque = null;
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &wrong_transport, null, &attempt, &readiness_fd, null),
    );
    var short_view = wrong_transport;
    short_view.struct_size = @offsetOf(cdrv.GlowcapLocatorView, "hints");
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &short_view, null, &attempt, &readiness_fd, null),
    );
    var hinted = wrong_transport;
    hinted.transport = "onion".ptr;
    hinted.transport_len = "onion".len;
    var hints = [_]cdrv.GlowcapLocatorHintView{.{
        .name = "route".ptr,
        .name_len = "route".len,
        .kind = cdrv.GLOWCAP_HINT_STRING,
        .bytes = "ignored".ptr,
        .bytes_len = "ignored".len,
        .boolean_value = 0,
        .integer_value = 0,
    }};
    hinted.hints = hints[0..].ptr;
    hinted.hint_count = 1;
    hinted.hint_wire_form = cdrv.GLOWCAP_HINTS_MAP;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &hinted, null, &attempt, &readiness_fd, null),
    );

    hinted.hints = null;
    hinted.hint_count = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.start_connect.?(table.ctx, &hinted, null, &attempt, &readiness_fd, null),
    );

    var dial_locator = hinted;
    dial_locator.hint_wire_form = cdrv.GLOWCAP_HINTS_BOOLEAN_FALSE;
    var dial_peer = try io.concurrent(ProviderDialPeer.run, .{ProviderDialPeer{ .daemon = daemon }});
    var dial_conn: ?*anyopaque = null;
    defer if (dial_conn) |raw| closeProviderConn(table, raw);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        try providerConnect(table, &dial_locator, &dial_conn, &readiness_fd),
    );
    try std.testing.expect(readiness_fd >= 0);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.write_all.?(table.ctx, dial_conn.?, "ping".ptr, "ping".len),
    );
    var dial_reply: [4]u8 = undefined;
    try providerReadAll(table, dial_conn.?, &dial_reply);
    try std.testing.expectEqualStrings("pong", &dial_reply);
    try std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, dial_conn.?, null));
    dial_conn = null;
    try dial_peer.await(io);

    var listener: ?*anyopaque = null;
    defer if (listener) |raw| closeProviderListener(table, raw);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        try providerListen(table, "", &listener),
    );
    const listener_raw = listener.?;
    var local = LocatorCapture{};
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.listener_locator.?(listener_raw, &local, LocatorCapture.receive, null),
    );
    try std.testing.expectEqual(@as(usize, 1), local.calls);
    const local_view = local.locatorView();
    try std.testing.expectEqualStrings("onion", local.transport[0..local.transport_len]);
    try std.testing.expectEqual(service_id.len, local.designator_len);
    try std.testing.expectEqualStrings(service_id, local.designator[0..local.designator_len]);
    try std.testing.expectEqual(@as(usize, 0), local.hint_count);
    try std.testing.expectEqual(cdrv.GLOWCAP_HINTS_BOOLEAN_FALSE, local.hint_wire_form);

    var advertised = local_view;
    var accepted = LocatorCapture{};
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.listener_advertise.?(listener_raw, &advertised, &accepted, LocatorCapture.receive, null),
    );
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
    try std.testing.expectEqualStrings("onion", accepted.transport[0..accepted.transport_len]);

    var map_advertisement = advertised;
    map_advertisement.hint_wire_form = cdrv.GLOWCAP_HINTS_MAP;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.listener_advertise.?(listener_raw, &map_advertisement, &accepted, LocatorCapture.receive, null),
    );

    var wrong_designator = advertised;
    wrong_designator.designator = "another-service".ptr;
    wrong_designator.designator_len = "another-service".len;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        table.listener_advertise.?(listener_raw, &wrong_designator, &accepted, LocatorCapture.receive, null),
    );

    const forward = try onion.Endpoint.parse(daemon.lastForwardTarget());
    const client = try forward.connect(io);
    defer client.close(io);
    var accepted_conn: ?*anyopaque = null;
    defer if (accepted_conn) |raw| closeProviderConn(table, raw);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
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
        c.GLOWCAP_OK,
        table.write_all.?(table.ctx, accepted_conn.?, "from-provider".ptr, "from-provider".len),
    );
    var accepted_reply: ["from-provider".len]u8 = undefined;
    try client_reader.interface.readSliceAll(&accepted_reply);
    try std.testing.expectEqualStrings("from-provider", &accepted_reply);
    try std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, accepted_conn.?, null));
    accepted_conn = null;

    try std.testing.expectEqual(c.GLOWCAP_OK, table.listener_close.?(table.ctx, listener_raw, null));
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
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_transport_provider(netlayer, &provider));
    try std.testing.expectEqual(c.GLOWCAP_OK, provider.retain.?(provider.lease_ctx, null));
    var provider_lease_alive = true;
    defer if (provider_lease_alive) releaseProvider(provider);

    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_netlayer_release(netlayer, null, 0, null));
    construction_alive = false;

    const entry = provider.entries.?[0];
    const table: *const cdrv.GlowcapStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
    var listener: ?*anyopaque = null;
    defer if (listener) |raw| closeProviderListener(table, raw);
    try std.testing.expectEqual(c.GLOWCAP_OK, try providerListen(table, "", &listener));

    try std.testing.expectEqual(c.GLOWCAP_OK, provider.release.?(provider.lease_ctx, null));
    provider_lease_alive = false;

    var local = LocatorCapture{};
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.listener_locator.?(listener.?, &local, LocatorCapture.receive, null),
    );

    const forward = try onion.Endpoint.parse(daemon.lastForwardTarget());
    const client = try forward.connect(io);
    defer client.close(io);
    var conn: ?*anyopaque = null;
    defer if (conn) |raw| closeProviderConn(table, raw);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        table.accept.?(table.ctx, listener.?, &conn, &readiness_fd, null),
    );

    try std.testing.expectEqual(c.GLOWCAP_OK, table.listener_close.?(table.ctx, listener.?, null));
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
    try std.testing.expectEqual(c.GLOWCAP_OK, table.write_all.?(table.ctx, conn.?, "pong".ptr, "pong".len));
    var reply: [4]u8 = undefined;
    try client_reader.interface.readSliceAll(&reply);
    try std.testing.expectEqualStrings("pong", &reply);
    try std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, conn.?, null));
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
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        co.glowcap_onion_transport_provider(netlayer, &provider),
    );

    var host: ?*cd.GlowcapHost = null;
    const seed: [64]u8 = @splat(0x75);
    try std.testing.expectEqual(c.GLOWCAP_OK, cd.glowcap_host_new(
        &seed,
        seed.len,
        frame_cap,
        1,
        c.GLOWCAP_CODEC_SYRUP,
        c.GLOWCAP_CAPTP_V1_0,
        c.GLOWCAP_FEATURE_FULL,
        0,
        &host,
    ));
    errdefer _ = cd.glowcap_host_release(host);

    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        cdrv.glowcap_driver_take_host(host, &driver_options, &loop),
    );
    var loop_alive = true;
    defer if (loop_alive) {
        var failure = cdrv.GlowcapDriverFailure.init();
        _ = cdrv.glowcap_driver_release(loop, &failure);
    };

    var install_failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        cdrv.glowcap_driver_add_provider(loop, &provider, &install_failure),
    );
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_netlayer_release(netlayer, null, 0, null));
    construction_alive = false;

    var present: u8 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, cdrv.glowcap_driver_has_transport(
        loop,
        "onion",
        "onion".len,
        &present,
    ));
    try std.testing.expectEqual(@as(u8, 1), present);

    var listener: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, cdrv.glowcap_driver_listen(
        loop,
        "onion",
        "onion".len,
        null,
        0,
        null,
        &listener,
    ));
    try awaitDriverListenerReady(loop, listener);
    var locator: cdrv.GlowcapLocatorView = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        cdrv.glowcap_driver_listener_locator(loop, listener, &locator),
    );
    try std.testing.expectEqualStrings("onion", locator.transport.?[0..locator.transport_len]);
    try std.testing.expectEqualStrings(service_id, locator.designator.?[0..locator.designator_len]);

    var restoration_len: usize = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_BUFFER_TOO_SMALL,
        cdrv.glowcap_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(fake.service_key.len, restoration_len);

    var short: [fake.service_key.len - 1]u8 = @splat(0xa5);
    restoration_len = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_BUFFER_TOO_SMALL,
        cdrv.glowcap_driver_listener_restoration_state(loop, listener, &short, short.len, &restoration_len),
    );
    try std.testing.expectEqual(fake.service_key.len, restoration_len);
    const expected_short: [short.len]u8 = @splat(0xa5);
    try std.testing.expectEqualSlices(u8, &expected_short, &short);

    var restoration: [fake.service_key.len]u8 = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        cdrv.glowcap_driver_listener_restoration_state(
            loop,
            listener,
            &restoration,
            restoration.len,
            &restoration_len,
        ),
    );
    try std.testing.expectEqualStrings(fake.service_key, restoration[0..restoration_len]);

    const forward = try onion.Endpoint.parse(daemon.lastForwardTarget());
    var listener_close_failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        cdrv.glowcap_driver_listener_close(loop, listener, &listener_close_failure),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    var release_failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(c.GLOWCAP_OK, cdrv.glowcap_driver_release(loop, &release_failure));
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
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_transport_provider(netlayer, &provider));
    try std.testing.expectEqual(c.GLOWCAP_OK, provider.retain.?(provider.lease_ctx, null));
    var provider_lease_alive = true;
    defer if (provider_lease_alive) releaseProvider(provider);

    const entry = provider.entries.?[0];
    const table: *const cdrv.GlowcapStreamTransport = @ptrCast(@alignCast(entry.implementation.?));
    var locator = cdrv.GlowcapLocatorView{
        .abi_version = cdrv.GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapLocatorView),
        .transport = "onion".ptr,
        .transport_len = "onion".len,
        .designator = service_id.ptr,
        .designator_len = service_id.len,
        .hints = null,
        .hint_count = 0,
        .hint_wire_form = cdrv.GLOWCAP_HINTS_BOOLEAN_FALSE,
    };
    var peer = try io.concurrent(ProviderDialPeer.run, .{ProviderDialPeer{ .daemon = daemon }});
    var conn: ?*anyopaque = null;
    defer if (conn) |raw| closeProviderConn(table, raw);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        try providerConnect(table, &locator, &conn, &readiness_fd),
    );

    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_netlayer_release(netlayer, null, 0, null));
    construction_alive = false;
    try std.testing.expectEqual(c.GLOWCAP_OK, provider.release.?(provider.lease_ctx, null));
    provider_lease_alive = false;

    try std.testing.expectEqual(c.GLOWCAP_OK, table.write_all.?(table.ctx, conn.?, "ping".ptr, "ping".len));
    var reply: [4]u8 = undefined;
    try providerReadAll(table, conn.?, &reply);
    try std.testing.expectEqualStrings("pong", &reply);
    try std.testing.expectEqual(c.GLOWCAP_OK, table.conn_close.?(table.ctx, conn.?, null));
    conn = null;
    try peer.await(io);
}
