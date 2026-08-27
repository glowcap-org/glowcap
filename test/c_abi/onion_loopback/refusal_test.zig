//! Refusals and cancellation on the onion C-ABI endpoints: a listener wait
//! that times out instead of parking, distinct refusals for a bad
//! configuration and a bad designator, configuration text copied rather than
//! borrowed, and shutdown cancelling a stalled connect or listen.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const co = @import("c_abi_net_transport_onion");
const model = pancake.ocapn.model;
const onion = pancake.net.onion;
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
        null,
        0,
        null,
    ));
    const listener_ptr = listener.?;
    defer releaseOnionListener(listener_ptr);

    // Nothing has dialed, so the wait expires and reports not-ready. This is the
    // guard that lets a blocking accept loop check a stop flag.
    var ready: u32 = 7;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        co.pancake_onion_listener_wait(listener_ptr, 1, &ready, null, 0, null),
    );
    try std.testing.expectEqual(@as(u32, 0), ready);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        co.pancake_onion_listener_wait(null, 1, &ready, null, 0, null),
    );

    co.pancake_onion_listener_shutdown(listener_ptr);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_CLOSED,
        co.pancake_onion_listener_wait(listener_ptr, 0, &ready, null, 0, null),
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
        null,
        0,
        null,
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
        null,
        0,
        null,
    ));
    // A zero frame cap and an unknown codec are the ordinary argument faults.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        c.PANCAKE_CODEC_SYRUP,
        0,
        &conn,
        null,
        0,
        null,
    ));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, co.pancake_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        999,
        frame_cap,
        &conn,
        null,
        0,
        null,
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
        null,
        0,
        null,
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
        null,
        0,
        null,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_listener_release(listener.?, null, 0, null));

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
        null,
        0,
        null,
    );
    try std.testing.expectEqual(c.PANCAKE_OK, rc);
    try std.testing.expectEqual(c.PANCAKE_OK, co.pancake_onion_conn_release(conn.?, null, 0, null));
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
            null,
            0,
            null,
        );
        if (conn) |handle| _ = co.pancake_onion_conn_release(handle, null, 0, null);
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
            null,
            0,
            null,
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
