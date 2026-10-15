//! C-ABI frame-boundary loopback over the in-process endpoints, the socket-free
//! counterpart of `driver_loop/loopback_test.zig`. It proves the `glowcap_inproc_*` handles
//! drive a real handshake + bootstrap fetch when the *host* owns the peer and
//! shuttles frames itself, with two peers in one process wired by in-process
//! pipes. The transport itself has no fd. The C listener adapter adds one
//! `WakeChannel` so foreign runtimes can park a reactor without blocking it.
//!
//! The peers are `engine.Peer`s driven through the public Zig boundary
//! (`recvPacket` / `takeOutbound`). The only thing under test
//! is the C inproc-endpoint surface bridging bytes to that boundary on a string
//! designator instead of a host:port.

const std = @import("std");
const glowcap = @import("glowcap");

const c = @import("c_abi");
const ci = @import("c_abi_net_transport_inproc");
const model = glowcap.ocapn.model;
const inproc = glowcap.net.inproc;
const c_abi_loopback = @import("../support/c_abi_loopback.zig");
const handshake = @import("../support/handshake.zig");

const designator = "thermostat-room";

fn releaseListener(listener: *ci.GlowcapInprocListener) void {
    std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_listener_release(listener, null, 0, null)) catch unreachable;
}

const Transport = struct {
    pub const Conn = *ci.GlowcapInprocConn;
    pub const Listener = *ci.GlowcapInprocListener;

    pub fn writeFrame(conn: Conn, cf: *c.GlowcapFrame) i32 {
        return ci.glowcap_inproc_conn_write_frame(conn, cf, null, 0, null);
    }

    pub fn readFrame(conn: Conn, mf: *c.GlowcapManagedFrame) i32 {
        return ci.glowcap_inproc_conn_read_frame(conn, mf, null, 0, null);
    }

    pub fn accept(
        listener: Listener,
        codec: u32,
        max_frame_bytes: usize,
        out_conn: *?Conn,
    ) i32 {
        return ci.glowcap_inproc_accept(listener, codec, max_frame_bytes, out_conn, null, 0, null);
    }

    pub fn releaseConn(conn: Conn) void {
        ci.glowcap_inproc_conn_release(conn);
    }
};

const Loopback = c_abi_loopback.Harness(Transport);
const frame_cap = c_abi_loopback.frame_cap;

const ParkedInprocAccept = struct {
    listener: *ci.GlowcapInprocListener,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = 0,
};

fn parkedInprocAccept(args: *ParkedInprocAccept) void {
    var conn: ?*ci.GlowcapInprocConn = null;
    args.started.store(true, .release);
    args.result = ci.glowcap_inproc_accept(args.listener, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null);
    if (conn) |owned| ci.glowcap_inproc_conn_release(owned);
}

const ParkedInprocRead = struct {
    conn: *ci.GlowcapInprocConn,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = 0,
};

fn parkedInprocRead(args: *ParkedInprocRead) void {
    var managed: c.GlowcapManagedFrame = undefined;
    args.started.store(true, .release);
    args.result = ci.glowcap_inproc_conn_read_frame(args.conn, &managed, null, 0, null);
    if (args.result == c.GLOWCAP_OK) c.glowcap_managed_frame_release(&managed);
}

fn startSession(name: []const u8) model.Message {
    return handshake.startSession(inproc.transport_name, name);
}

test "transport status calls do not expose a stale diagnostic" {
    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    defer ci.glowcap_inproc_netlayer_release(netlayer);

    var conn: ?*ci.GlowcapInprocConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_IO,
        ci.glowcap_inproc_connect(netlayer, "missing".ptr, 7, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expect(ci.glowcap_inproc_last_error(null, 0) != 0);

    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        ci.glowcap_inproc_connect(null, "unused".ptr, 6, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expectEqual(@as(usize, 0), ci.glowcap_inproc_last_error(null, 0));
}

test "transport call can return the worker-thread cause with its status" {
    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    defer ci.glowcap_inproc_netlayer_release(netlayer);

    var conn: ?*ci.GlowcapInprocConn = null;
    var diagnostic: [257]u8 = undefined;
    var diagnostic_len: usize = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_IO,
        ci.glowcap_inproc_connect(
            netlayer,
            "missing".ptr,
            7,
            c.GLOWCAP_CODEC_SYRUP,
            frame_cap,
            &conn,
            &diagnostic,
            diagnostic.len,
            &diagnostic_len,
        ),
    );
    const expected = "connect: no listener bound at that inproc designator";
    try std.testing.expectEqualStrings(expected, diagnostic[0..diagnostic_len]);
    try std.testing.expectEqual(@as(u8, 0), diagnostic[diagnostic_len]);

    diagnostic_len = std.math.maxInt(usize);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        ci.glowcap_inproc_connect(
            null,
            "unused".ptr,
            6,
            c.GLOWCAP_CODEC_SYRUP,
            frame_cap,
            &conn,
            &diagnostic,
            diagnostic.len,
            &diagnostic_len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), diagnostic_len);

    // Refusing a partial optional diagnostic request happens before the effect
    // and clears this thread's archive-local diagnostic.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        ci.glowcap_inproc_connect(
            netlayer,
            "missing".ptr,
            7,
            c.GLOWCAP_CODEC_SYRUP,
            frame_cap,
            &conn,
            &diagnostic,
            diagnostic.len,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), ci.glowcap_inproc_last_error(null, 0));
}

test "c-abi inproc loopback: handshake to open + bootstrap fetch round-trip" {
    const allocator = std.testing.allocator;

    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.glowcap_inproc_netlayer_release(netlayer_ptr);

    var listener: ?*ci.GlowcapInprocListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ci.glowcap_inproc_listen(netlayer_ptr, designator.ptr, designator.len, &listener),
    );
    const listener_ptr = listener.?;
    defer releaseListener(listener_ptr);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args: Loopback.ServerArgs = .{
        .listener = listener_ptr,
        .allocator = allocator,
        .start_session = startSession("server"),
    };
    var server_future = try io.concurrent(Loopback.serveThread, .{&args});

    var conn: ?*ci.GlowcapInprocConn = null;
    const connect_rc = ci.glowcap_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null);
    try std.testing.expectEqual(c.GLOWCAP_OK, connect_rc);
    const conn_ptr = conn.?;

    const client_result = Loopback.fetchOnce(conn_ptr, allocator, startSession("client"));

    // Closing the client lets the server observe EOF and finish.
    ci.glowcap_inproc_conn_release(conn_ptr);
    server_future.await(io);

    try client_result;
    try args.result;
}

test "c-abi inproc connect rejects bad arguments and a missing listener distinctly" {
    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.glowcap_inproc_netlayer_release(netlayer_ptr);

    var conn: ?*ci.GlowcapInprocConn = null;

    // A zero frame cap is an invalid argument, not a codec selector problem.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ci.glowcap_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.GLOWCAP_CODEC_SYRUP, 0, &conn, null, 0, null),
    );
    // An unknown codec selector is an invalid argument.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ci.glowcap_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.GLOWCAP_CODEC_UNKNOWN, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ci.glowcap_inproc_connect(netlayer_ptr, designator.ptr, designator.len, 999, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expect(ci.glowcap_inproc_last_error(null, 0) > 0);
    // A null required pointer is a null-pointer error.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        ci.glowcap_inproc_connect(null, designator.ptr, designator.len, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null),
    );
    // Dialing a designator with no bound listener is an I/O fault, with a cause
    // recorded for glowcap_inproc_last_error, distinct from a malformed request.
    ci.glowcap_inproc_clear_last_error();
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_IO,
        ci.glowcap_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expect(ci.glowcap_inproc_last_error(null, 0) > 0);
}

test "c-abi inproc listen rejects an empty designator" {
    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.glowcap_inproc_netlayer_release(netlayer_ptr);

    const empty = "";
    var listener: ?*ci.GlowcapInprocListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ci.glowcap_inproc_listen(netlayer_ptr, empty.ptr, empty.len, &listener),
    );
}

test "c-abi inproc readiness stays armed for every queued dial" {
    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.glowcap_inproc_netlayer_release(netlayer_ptr);

    var listener: ?*ci.GlowcapInprocListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ci.glowcap_inproc_listen(netlayer_ptr, designator.ptr, designator.len, &listener),
    );
    const listener_ptr = listener.?;
    defer releaseListener(listener_ptr);

    var fd: i32 = -1;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_listener_readiness_fd(listener_ptr, &fd));
    var pollfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfd, 0));

    var dialed = [_]?*ci.GlowcapInprocConn{ null, null };
    for (&dialed) |*slot| {
        try std.testing.expectEqual(
            c.GLOWCAP_OK,
            ci.glowcap_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.GLOWCAP_CODEC_SYRUP, frame_cap, slot, null, 0, null),
        );
    }
    defer for (dialed) |conn| ci.glowcap_inproc_conn_release(conn);

    for (0..2) |_| {
        pollfd[0].revents = 0;
        try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollfd, 1000));
        try std.testing.expect(pollfd[0].revents & std.posix.POLL.IN != 0);
        var accepted: ?*ci.GlowcapInprocConn = null;
        try std.testing.expectEqual(
            c.GLOWCAP_OK,
            ci.glowcap_inproc_accept(listener_ptr, c.GLOWCAP_CODEC_SYRUP, frame_cap, &accepted, null, 0, null),
        );
        ci.glowcap_inproc_conn_release(accepted);
    }
    pollfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfd, 0));
}

test "c-abi inproc release resolves a racing Zig accept" {
    var netlayer: ?*ci.GlowcapInprocNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.glowcap_inproc_netlayer_release(netlayer_ptr);

    var listener: ?*ci.GlowcapInprocListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ci.glowcap_inproc_listen(netlayer_ptr, designator.ptr, designator.len, &listener),
    );
    const listener_ptr = listener.?;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var parked_accept = ParkedInprocAccept{ .listener = listener_ptr };
    var accept_future = try io.concurrent(parkedInprocAccept, .{&parked_accept});
    while (!parked_accept.started.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(c.GLOWCAP_OK, ci.glowcap_inproc_listener_release(listener_ptr, null, 0, null));
    accept_future.await(io);
    // The task may race release before acquiring the listener lease (CLOSED),
    // or release may interrupt an admitted accept (IO). Both are terminal and
    // release has joined the task before returning.
    try std.testing.expect(
        parked_accept.result == c.GLOWCAP_ERR_CLOSED or
            parked_accept.result == c.GLOWCAP_ERR_IO,
    );

    const pair_designator = "shutdown-pair";
    listener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ci.glowcap_inproc_listen(netlayer_ptr, pair_designator.ptr, pair_designator.len, &listener),
    );
    const pair_listener = listener.?;
    defer releaseListener(pair_listener);
    var dialed: ?*ci.GlowcapInprocConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ci.glowcap_inproc_connect(netlayer_ptr, pair_designator.ptr, pair_designator.len, c.GLOWCAP_CODEC_SYRUP, frame_cap, &dialed, null, 0, null),
    );
    defer ci.glowcap_inproc_conn_release(dialed.?);
    var accepted: ?*ci.GlowcapInprocConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ci.glowcap_inproc_accept(pair_listener, c.GLOWCAP_CODEC_SYRUP, frame_cap, &accepted, null, 0, null),
    );
    const accepted_ptr = accepted.?;

    ci.glowcap_inproc_listener_shutdown(pair_listener);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CLOSED,
        ci.glowcap_inproc_listener_readiness_fd(pair_listener, &readiness_fd),
    );

    var parked_read = ParkedInprocRead{ .conn = accepted_ptr };
    var read_future = try io.concurrent(parkedInprocRead, .{&parked_read});
    while (!parked_read.started.load(.acquire)) std.Thread.yield() catch {};
    ci.glowcap_inproc_conn_shutdown(accepted_ptr);
    read_future.await(io);
    try std.testing.expect(parked_read.result != c.GLOWCAP_OK);
    ci.glowcap_inproc_conn_release(accepted_ptr);
}
