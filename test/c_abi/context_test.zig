//! Allocation-context contract independent of any CapTP application handle.
//! A caller-supplied allocator owns the context, TCP netlayer, listener,
//! connections, their buffers, and an owned frame; teardown returns every byte
//! through the same callbacks.

const std = @import("std");

const c = @import("c_abi");
const ct = @import("c_abi_net_transport_tcp");

const frame = "<8'op:abort3\"bye>";
const frame_cap = 4096;

const CountingHost = @import("../support/c_abi_counting_alloc.zig").CountingHost;

test "context constructors reject null arguments" {
    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new(null));
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new_with_allocator(null, &ctx));

    var host = CountingHost{};
    var partial = host.spec();
    partial.free = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_context_new_with_allocator(&partial, &ctx));

    c.pancake_context_release(null);
    try std.testing.expect(host.balanced());
}

const AcceptArgs = struct {
    listener: *ct.PancakeTcpListener,
    result: anyerror!void = {},
};

const ParkedTcpAccept = struct {
    listener: *ct.PancakeTcpListener,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = 0,
};

fn parkedTcpAccept(args: *ParkedTcpAccept) void {
    var conn: ?*ct.PancakeTcpConn = null;
    args.started.store(true, .release);
    args.result = ct.pancake_tcp_accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn);
    if (conn) |owned| ct.pancake_tcp_conn_release(owned);
}

const ParkedTcpRead = struct {
    conn: *ct.PancakeTcpConn,
    started: std.atomic.Value(bool) = .init(false),
    result: i32 = 0,
};

fn parkedTcpRead(args: *ParkedTcpRead) void {
    var managed: c.PancakeManagedFrame = undefined;
    args.started.store(true, .release);
    args.result = ct.pancake_tcp_conn_read_frame(args.conn, &managed);
    if (args.result == c.PANCAKE_OK) c.pancake_managed_frame_release(&managed);
}

fn acceptThread(args: *AcceptArgs) void {
    args.result = acceptOnce(args);
}

fn acceptOnce(args: *AcceptArgs) !void {
    var conn: ?*ct.PancakeTcpConn = null;
    if (ct.pancake_tcp_accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn) != c.PANCAKE_OK)
        return error.AcceptFailed;
    const conn_ptr = conn orelse return error.AcceptNull;
    defer ct.pancake_tcp_conn_release(conn_ptr);

    var managed: c.PancakeManagedFrame = undefined;
    if (ct.pancake_tcp_conn_read_frame(conn_ptr, &managed) != c.PANCAKE_OK) return error.ReadFailed;
    defer c.pancake_managed_frame_release(&managed);

    const bytes = (managed.bytes orelse return error.NullFrame)[0..managed.len];
    try std.testing.expectEqualStrings(frame, bytes);
}

test "host allocator balances a TCP handle family and owned frame" {
    var host = CountingHost{};
    const spec = host.spec();

    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new_with_allocator(&spec, &ctx));
    const ctx_ptr = ctx.?;

    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new_in(ctx_ptr, &netlayer));
    const netlayer_ptr = netlayer.?;

    const host_addr = "127.0.0.1";
    var listener: ?*ct.PancakeTcpListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;

    var port: u16 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_listener_port(listener_ptr, &port));
    try std.testing.expect(port != 0);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args: AcceptArgs = .{ .listener = listener_ptr };
    var accept_future = try io.concurrent(acceptThread, .{&args});

    var conn: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn),
    );
    const conn_ptr = conn.?;

    var outbound: c.PancakeFrame = .{
        .bytes = frame.ptr,
        .len = frame.len,
        .shape = c.PANCAKE_FRAME_SHAPE_BYTE,
    };
    const write_rc = ct.pancake_tcp_conn_write_frame(conn_ptr, &outbound);

    accept_future.await(io);
    ct.pancake_tcp_conn_release(conn_ptr);
    ct.pancake_tcp_listener_release(listener_ptr);
    ct.pancake_tcp_netlayer_release(netlayer_ptr);
    c.pancake_context_release(ctx_ptr);

    try std.testing.expectEqual(c.PANCAKE_OK, write_rc);
    try args.result;
    try std.testing.expect(host.alloc_calls > 0);
    try std.testing.expect(host.balanced());
}

test "tcp connect and accept reject the unknown codec selector" {
    var ctx: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&ctx));
    const ctx_ptr = ctx.?;
    defer c.pancake_context_release(ctx_ptr);

    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new_in(ctx_ptr, &netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.PancakeTcpListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;
    defer ct.pancake_tcp_listener_release(listener_ptr);

    var conn: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, 1, c.PANCAKE_CODEC_UNKNOWN, frame_cap, &conn),
    );
    try std.testing.expect(conn == null);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_accept(listener_ptr, c.PANCAKE_CODEC_UNKNOWN, frame_cap, &conn),
    );
    try std.testing.expect(conn == null);
}

test "tcp listener readiness fd is level-readable until accept" {
    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.PancakeTcpListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;
    defer ct.pancake_tcp_listener_release(listener_ptr);

    var fd: i32 = -1;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_listener_readiness_fd(listener_ptr, &fd));
    try std.testing.expect(fd >= 0);
    var pollfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfd, 0));

    var port: u16 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_listener_port(listener_ptr, &port));
    var dialed: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &dialed),
    );
    defer ct.pancake_tcp_conn_release(dialed.?);
    pollfd[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollfd, 1000));
    try std.testing.expect(pollfd[0].revents & std.posix.POLL.IN != 0);

    var accepted: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_accept(listener_ptr, c.PANCAKE_CODEC_SYRUP, frame_cap, &accepted),
    );
    defer ct.pancake_tcp_conn_release(accepted.?);
}

test "tcp release resolves a racing native accept" {
    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host_addr = "127.0.0.1";
    var listener: ?*ct.PancakeTcpListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const listener_ptr = listener.?;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var parked_accept = ParkedTcpAccept{ .listener = listener_ptr };
    var accept_future = try io.concurrent(parkedTcpAccept, .{&parked_accept});
    while (!parked_accept.started.load(.acquire)) std.Thread.yield() catch {};
    ct.pancake_tcp_listener_release(listener_ptr);
    accept_future.await(io);
    // The task may race release before acquiring the listener lease (CLOSED),
    // or release may interrupt an admitted accept (IO). Both are terminal and
    // release has joined the task before returning.
    try std.testing.expect(
        parked_accept.result == c.PANCAKE_ERR_CLOSED or
            parked_accept.result == c.PANCAKE_ERR_IO,
    );

    // Use a fresh listener to establish a pair, then park one endpoint in a
    // native frame read. Connection shutdown must wake it before storage frees.
    listener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host_addr.ptr, host_addr.len, 0, &listener),
    );
    const pair_listener = listener.?;
    defer ct.pancake_tcp_listener_release(pair_listener);
    var port: u16 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_listener_port(pair_listener, &port));
    var dialed: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_connect(netlayer_ptr, host_addr.ptr, host_addr.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &dialed),
    );
    defer ct.pancake_tcp_conn_release(dialed.?);
    var accepted: ?*ct.PancakeTcpConn = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_accept(pair_listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &accepted),
    );
    const accepted_ptr = accepted.?;

    ct.pancake_tcp_listener_shutdown(pair_listener);
    var readiness_fd: i32 = -1;
    try std.testing.expectEqual(c.PANCAKE_ERR_CLOSED, ct.pancake_tcp_listener_port(pair_listener, &port));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_CLOSED,
        ct.pancake_tcp_listener_readiness_fd(pair_listener, &readiness_fd),
    );

    var parked_read = ParkedTcpRead{ .conn = accepted_ptr };
    var read_future = try io.concurrent(parkedTcpRead, .{&parked_read});
    while (!parked_read.started.load(.acquire)) std.Thread.yield() catch {};
    ct.pancake_tcp_conn_shutdown(accepted_ptr);
    read_future.await(io);
    try std.testing.expect(parked_read.result != c.PANCAKE_OK);
    ct.pancake_tcp_conn_release(accepted_ptr);
}
