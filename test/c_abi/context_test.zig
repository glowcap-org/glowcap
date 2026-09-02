//! Allocation-context contract independent of any CapTP application handle.
//! A caller-supplied allocator owns the context, TCP netlayer, listener,
//! connections, their buffers, and an owned frame; teardown returns every byte
//! through the same callbacks.

const std = @import("std");

const c = @import("c_abi");
const ct = @import("c_abi_net_transport_tcp");

const frame = "<8'op:abort3\"bye>";
const frame_cap = 4096;
const tcp_config: ct.GlowcapTcpConfig = .{ .stream = .{
    .keepalive_idle_sec = 0,
    .keepalive_interval_sec = 0,
    .keepalive_count = 0,
} };

const CountingHost = @import("../support/c_abi_counting_alloc.zig").CountingHost;

test "context constructors reject null arguments" {
    var ctx: ?*c.GlowcapContext = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_context_new(null));
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_context_new_with_allocator(null, &ctx));

    var host = CountingHost{};
    var partial = host.spec();
    partial.free = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, c.glowcap_context_new_with_allocator(&partial, &ctx));

    c.glowcap_context_release(null);
    try std.testing.expect(host.balanced());
}

test "TCP configuration rejects absent and partial keepalive defaults" {
    var netlayer: ?*ct.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, ct.glowcap_tcp_netlayer_new(null, &netlayer));
    try std.testing.expect(netlayer == null);

    const partial: ct.GlowcapTcpConfig = .{ .stream = .{
        .keepalive_idle_sec = 30,
        .keepalive_interval_sec = 0,
        .keepalive_count = 3,
    } };
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, ct.glowcap_tcp_netlayer_new(&partial, &netlayer));
    try std.testing.expect(netlayer == null);
}

test "TCP blocking calls have one optional diagnostic contract" {
    var netlayer: ?*ct.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_netlayer_new(&tcp_config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.glowcap_tcp_netlayer_release(netlayer_ptr);

    var conn: ?*ct.GlowcapTcpConn = null;
    var diagnostic: [128]u8 = undefined;
    var diagnostic_len: usize = 0;
    const invalid_host = "not-an-ip-address";
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ct.glowcap_tcp_connect(
            netlayer_ptr,
            invalid_host.ptr,
            invalid_host.len,
            1,
            null,
            c.GLOWCAP_CODEC_SYRUP,
            frame_cap,
            &conn,
            &diagnostic,
            diagnostic.len,
            &diagnostic_len,
        ),
    );
    try std.testing.expect(conn == null);
    try std.testing.expectEqualStrings(
        "connect: invalid address: InvalidAddress",
        diagnostic[0..diagnostic_len],
    );

    // A partial diagnostic request is rejected before the operation starts.
    // It cannot silently run the dial and then replace its outcome.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        ct.glowcap_tcp_connect(
            netlayer_ptr,
            invalid_host.ptr,
            invalid_host.len,
            1,
            null,
            c.GLOWCAP_CODEC_SYRUP,
            frame_cap,
            &conn,
            &diagnostic,
            diagnostic.len,
            null,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), ct.glowcap_tcp_last_error(null, 0));
}

const AcceptArgs = struct {
    listener: *ct.GlowcapTcpListener,
    result: anyerror!void = {},
};

const ParkedTcpAccept = struct {
    listener: *ct.GlowcapTcpListener,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = 0,
};

fn parkedTcpAccept(args: *ParkedTcpAccept) void {
    var conn: ?*ct.GlowcapTcpConn = null;
    args.started.store(true, .release);
    args.result = ct.glowcap_tcp_accept(args.listener, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null);
    if (conn) |owned| _ = ct.glowcap_tcp_conn_release(owned, null, 0, null);
}

const ParkedTcpRead = struct {
    conn: *ct.GlowcapTcpConn,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = 0,
};

fn parkedTcpRead(args: *ParkedTcpRead) void {
    var managed: c.GlowcapManagedFrame = undefined;
    args.started.store(true, .release);
    args.result = ct.glowcap_tcp_conn_read_frame(args.conn, &managed, null, 0, null);
    if (args.result == c.GLOWCAP_OK) c.glowcap_managed_frame_release(&managed);
}

fn acceptThread(args: *AcceptArgs) void {
    args.result = acceptOnce(args);
}

fn acceptOnce(args: *AcceptArgs) !void {
    var conn: ?*ct.GlowcapTcpConn = null;
    if (ct.glowcap_tcp_accept(args.listener, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null) != c.GLOWCAP_OK)
        return error.AcceptFailed;
    const conn_ptr = conn orelse return error.AcceptNull;
    defer _ = ct.glowcap_tcp_conn_release(conn_ptr, null, 0, null);

    var managed: c.GlowcapManagedFrame = undefined;
    if (ct.glowcap_tcp_conn_read_frame(conn_ptr, &managed, null, 0, null) != c.GLOWCAP_OK) return error.ReadFailed;
    defer c.glowcap_managed_frame_release(&managed);

    const bytes = (managed.bytes orelse return error.NullFrame)[0..managed.len];
    try std.testing.expectEqualStrings(frame, bytes);
}

test "host allocator balances a TCP handle family and owned frame" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.GlowcapContext = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var netlayer: ?*ct.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_netlayer_new_in(ctx_ptr, &tcp_config, &netlayer));
    const netlayer_ptr = netlayer.?;

    const host_addr = "127.0.0.1";
    var listener: ?*ct.GlowcapTcpListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;

    var port: u16 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_listener_port(listener_ptr, &port));
    try std.testing.expect(port != 0);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args: AcceptArgs = .{ .listener = listener_ptr };
    var accept_future = try io.concurrent(acceptThread, .{&args});

    var conn: ?*ct.GlowcapTcpConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &conn, null, 0, null),
    );
    const conn_ptr = conn.?;

    var outbound: c.GlowcapFrame = .{
        .bytes = frame.ptr,
        .len = frame.len,
        .shape = c.GLOWCAP_FRAME_SHAPE_BYTE,
    };
    const write_rc = ct.glowcap_tcp_conn_write_frame(conn_ptr, &outbound, null, 0, null);

    accept_future.await(io);

    // Malformed optional diagnostic plumbing is refused before consuming the
    // connection. The subsequent diagnosed release proves ownership remained
    // with the caller and that success clears the worker-local slot.
    var release_diagnostic: [64]u8 = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        ct.glowcap_tcp_conn_release(conn_ptr, &release_diagnostic, release_diagnostic.len, null),
    );
    var release_diagnostic_len: usize = std.math.maxInt(usize);
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_conn_release(
            conn_ptr,
            &release_diagnostic,
            release_diagnostic.len,
            &release_diagnostic_len,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), release_diagnostic_len);
    ct.glowcap_tcp_listener_release(listener_ptr);
    ct.glowcap_tcp_netlayer_release(netlayer_ptr);
    c.glowcap_context_release(ctx_ptr);

    try std.testing.expectEqual(c.GLOWCAP_OK, write_rc);
    try args.result;
    try std.testing.expect(host.alloc_calls > 0);
    try std.testing.expect(host.balanced());
}

test "tcp connect and accept reject the unknown codec selector" {
    var ctx: ?*c.GlowcapContext = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, c.glowcap_context_new(&ctx));
    const ctx_ptr = ctx.?;
    defer c.glowcap_context_release(ctx_ptr);

    var netlayer: ?*ct.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_netlayer_new_in(ctx_ptr, &tcp_config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.glowcap_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.GlowcapTcpListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;
    defer ct.glowcap_tcp_listener_release(listener_ptr);

    var conn: ?*ct.GlowcapTcpConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ct.glowcap_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, 1, null, c.GLOWCAP_CODEC_UNKNOWN, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expect(conn == null);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        ct.glowcap_tcp_accept(listener_ptr, null, c.GLOWCAP_CODEC_UNKNOWN, frame_cap, &conn, null, 0, null),
    );
    try std.testing.expect(conn == null);
}

test "tcp listener readiness fd is level-readable until accept" {
    var netlayer: ?*ct.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_netlayer_new(&tcp_config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.glowcap_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.GlowcapTcpListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;
    defer ct.glowcap_tcp_listener_release(listener_ptr);

    var fd: i32 = -1;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_listener_readiness_fd(listener_ptr, &fd));
    try std.testing.expect(fd >= 0);
    var pollfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfd, 0));

    var port: u16 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_listener_port(listener_ptr, &port));
    var dialed: ?*ct.GlowcapTcpConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &dialed, null, 0, null),
    );
    defer _ = ct.glowcap_tcp_conn_release(dialed.?, null, 0, null);
    pollfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollfd, 1000));
    try std.testing.expect(pollfd[0].revents & std.posix.POLL.IN != 0);

    var accepted: ?*ct.GlowcapTcpConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_accept(listener_ptr, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &accepted, null, 0, null),
    );
    defer _ = ct.glowcap_tcp_conn_release(accepted.?, null, 0, null);
}

test "tcp release resolves a racing native accept" {
    var netlayer: ?*ct.GlowcapTcpNetlayer = null;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_netlayer_new(&tcp_config, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.glowcap_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.GlowcapTcpListener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var parked_accept = ParkedTcpAccept{ .listener = listener_ptr };
    var accept_future = try io.concurrent(parkedTcpAccept, .{&parked_accept});
    while (!parked_accept.started.load(.acquire)) std.Thread.yield() catch {};
    ct.glowcap_tcp_listener_release(listener_ptr);
    accept_future.await(io);
    // The task may race release before acquiring the listener lease (CLOSED),
    // or release may interrupt an admitted accept (IO). Both are terminal and
    // release has joined the task before returning.
    try std.testing.expect(
        parked_accept.result == c.GLOWCAP_ERR_CLOSED or
            parked_accept.result == c.GLOWCAP_ERR_IO,
    );

    // Use a fresh listener to establish a pair, then park one endpoint in a
    // native frame read. Connection shutdown must wake it before storage frees.
    listener = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const pair_listener = listener.?;
    defer ct.glowcap_tcp_listener_release(pair_listener);
    var port: u16 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_listener_port(pair_listener, &port));
    var dialed: ?*ct.GlowcapTcpConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &dialed, null, 0, null),
    );
    defer _ = ct.glowcap_tcp_conn_release(dialed.?, null, 0, null);
    var accepted: ?*ct.GlowcapTcpConn = null;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        ct.glowcap_tcp_accept(pair_listener, null, c.GLOWCAP_CODEC_SYRUP, frame_cap, &accepted, null, 0, null),
    );
    const accepted_ptr = accepted.?;

    ct.glowcap_tcp_listener_shutdown(pair_listener);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, ct.glowcap_tcp_listener_port(pair_listener, &port));
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CLOSED,
        ct.glowcap_tcp_listener_readiness_fd(pair_listener, &readiness_fd),
    );

    var parked_read = ParkedTcpRead{ .conn = accepted_ptr };
    var read_future = try io.concurrent(parkedTcpRead, .{&parked_read});
    while (!parked_read.started.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_conn_shutdown(accepted_ptr));
    read_future.await(io);
    try std.testing.expect(parked_read.result != c.GLOWCAP_OK);
    try std.testing.expectEqual(c.GLOWCAP_OK, ct.glowcap_tcp_conn_release(accepted_ptr, null, 0, null));
}
