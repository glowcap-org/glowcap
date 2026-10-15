//! A whole conversation over the onion C-ABI endpoints, against fake Tor
//! daemons: dial through the SOCKS fake to handshake, bootstrap fetch, and a
//! shutdown that wakes a parked Zig read. Accept of a forwarded circuit,
//! and the listen out-parameter length query.

const std = @import("std");
const glowcap = @import("glowcap");

const c = @import("c_abi");
const co = @import("c_abi_net_transport_onion");
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
    conn: *co.GlowcapOnionConn,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = c.GLOWCAP_OK,

    fn run(self: *ParkedOnionRead) void {
        var frame: c.GlowcapManagedFrame = undefined;
        self.started.store(true, .release);
        self.result = co.glowcap_onion_conn_read_frame(self.conn, &frame, null, 0, null);
        if (self.result == c.GLOWCAP_OK) c.glowcap_managed_frame_release(&frame);
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

    var conn = glowcap.net.Connection.init(
        daemon.io,
        &peer,
        &reader.interface,
        &writer.interface,
        borrowedHandle(&reader),
    );
    defer conn.deinit();

    try peer.sendBorrowed(startSession(fake.service_id));
    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

/// A transport handle over a stream the test closes itself.
fn borrowedHandle(reader: *std.Io.net.Stream.Reader) glowcap.net.Connection.Transport {
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

    var conn: ?*co.GlowcapOnionConn = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_connect(
        netlayer_ptr,
        service_id.ptr,
        service_id.len,
        c.GLOWCAP_CODEC_SYRUP,
        frame_cap,
        &conn,
        null,
        0,
        null,
    ));
    const conn_ptr = conn.?;

    const client_result = Loopback.fetchOnce(conn_ptr, allocator, startSession("client"));

    // Releasing the client lets the far peer observe EOF and finish. Refusing
    // malformed optional diagnostic plumbing first proves that validation does
    // not consume the connection; the valid call returns this worker's empty
    // success diagnostic explicitly.
    var release_diagnostic: [64]u8 = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        co.glowcap_onion_conn_release(conn_ptr, &release_diagnostic, release_diagnostic.len, null),
    );
    var release_diagnostic_len: usize = std.math.maxInt(usize);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        co.glowcap_onion_conn_release(
            conn_ptr,
            &release_diagnostic,
            release_diagnostic.len,
            &release_diagnostic_len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), release_diagnostic_len);
    const server_result = server.await(io);

    try client_result;
    try server_result;
}

test "c-abi onion connection shutdown wakes a Zig read before release" {
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

    var conn: ?*co.GlowcapOnionConn = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_connect(
        netlayer,
        service_id.ptr,
        service_id.len,
        c.GLOWCAP_CODEC_SYRUP,
        frame_cap,
        &conn,
        null,
        0,
        null,
    ));
    try wait.untilFlag(io, 5_000, &accepted);

    var parked = ParkedOnionRead{ .conn = conn.? };
    var read = try io.concurrent(ParkedOnionRead.run, .{&parked});
    try wait.untilFlag(io, 5_000, &parked.started);

    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_conn_shutdown(conn.?));
    read.await(io);
    try std.testing.expect(parked.result != c.GLOWCAP_OK);
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_conn_release(conn.?, null, 0, null));
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

    var id_buf: [co.GLOWCAP_ONION_SERVICE_ID_LEN]u8 = undefined;
    var id_len: usize = 0;
    var key_buf: [co.GLOWCAP_ONION_SERVICE_KEY_CAP]u8 = undefined;
    var key_len: usize = 0;
    var listener: ?*co.GlowcapOnionListener = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_listen(
        netlayer_ptr,
        &id_buf,
        id_buf.len,
        &id_len,
        &key_buf,
        key_buf.len,
        &key_len,
        &listener,
        null,
        0,
        null,
    ));
    const listener_ptr = listener.?;
    defer releaseOnionListener(listener_ptr);

    // The id is the one the daemon reported, not one glowcap chose, and the key
    // is what would restore the same address later.
    try std.testing.expectEqual(co.GLOWCAP_ONION_SERVICE_ID_LEN, id_len);
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

    var conn = glowcap.net.Connection.init(
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

    var netlayer: ?*co.GlowcapOnionNetlayer = null;
    var config: co.GlowcapOnionConfig = .{};
    config.socks = daemon.socksText().ptr;
    config.socks_len = daemon.socksText().len;
    config.control_endpoint = daemon.controlText().ptr;
    config.control_endpoint_len = daemon.controlText().len;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_netlayer_new(&config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer releaseOnionNetlayer(netlayer_ptr);

    // A null buffer with a length slot asks how much room the value needs, so a
    // caller can size its storage without hardcoding the constant.
    var id_len: usize = 0;
    var listener: ?*co.GlowcapOnionListener = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, co.glowcap_onion_listen(
        netlayer_ptr,
        null,
        0,
        &id_len,
        null,
        0,
        null,
        &listener,
        null,
        0,
        null,
    ));
    defer releaseOnionListener(listener.?);
    try std.testing.expectEqual(co.GLOWCAP_ONION_SERVICE_ID_LEN, id_len);

    // A buffer too small for the id is the caller's error, and the listener is not
    // left behind: a second listen on the same daemon still succeeds.
    var tiny: [8]u8 = undefined;
    var second: ?*co.GlowcapOnionListener = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, co.glowcap_onion_listen(
        netlayer_ptr,
        &tiny,
        tiny.len,
        null,
        null,
        0,
        null,
        &second,
        null,
        0,
        null,
    ));
}
