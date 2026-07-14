//! C-ABI frame-boundary loopback, proves the blocking TCP endpoint handles drive a
//! real handshake + bootstrap fetch when the *host* owns the peer and shuttles
//! frames itself (`read_frame -> recvStreamPrefix` / `takeOutbound ->
//! write_frame`). This is the host-driven netlayer boundary the C ABI exposes: the
//! transport is the exported endpoint surface, the framing is still the one
//! parser, and no `Io` is ever named on the boundary.
//!
//! The peers here are `engine.Peer`s driven through the public Zig boundary
//! (`recvStreamPrefix` / `takeOutbound`); the only thing under test that is new
//! is the C endpoint surface bridging bytes to that boundary.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const ct = @import("c_abi_net_transport_tcp");
const model = pancake.ocapn.model;
const tcp = pancake.net.tcp;
const c_abi_loopback = @import("../support/c_abi_loopback.zig");
const handshake = @import("../support/handshake.zig");

const Transport = struct {
    pub const Conn = *ct.PancakeTcpConn;
    pub const Listener = *ct.PancakeTcpListener;

    pub fn writeFrame(conn: Conn, cf: *c.PancakeFrame) i32 {
        return ct.pancake_tcp_conn_write_frame(conn, cf);
    }

    pub fn readFrame(conn: Conn, mf: *c.PancakeManagedFrame) i32 {
        return ct.pancake_tcp_conn_read_frame(conn, mf);
    }

    pub fn accept(
        listener: Listener,
        codec: u32,
        max_frame_bytes: usize,
        out_conn: *?Conn,
    ) i32 {
        return ct.pancake_tcp_accept(listener, codec, max_frame_bytes, out_conn);
    }

    pub fn releaseConn(conn: Conn) void {
        ct.pancake_tcp_conn_release(conn);
    }
};

const Loopback = c_abi_loopback.Harness(Transport);
const frame_cap = c_abi_loopback.frame_cap;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

test "c-abi endpoint loopback: handshake to open + bootstrap fetch round-trip" {
    const allocator = std.testing.allocator;

    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    var listener: ?*ct.PancakeTcpListener = null;
    const host = "127.0.0.1";
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listen(netlayer_ptr, host.ptr, host.len, 0, &listener),
    );
    const listener_ptr = listener.?;
    defer ct.pancake_tcp_listener_release(listener_ptr);

    var port: u16 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ct.pancake_tcp_listener_port(listener_ptr, &port),
    );
    try std.testing.expect(port != 0);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args: Loopback.ServerArgs = .{
        .listener = listener_ptr,
        .allocator = allocator,
        .start_session = startSession("server"),
    };
    var server_future = try io.concurrent(Loopback.serveThread, .{&args});

    var conn: ?*ct.PancakeTcpConn = null;
    const connect_rc = ct.pancake_tcp_connect(netlayer_ptr, host.ptr, host.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn);
    try std.testing.expectEqual(c.PANCAKE_OK, connect_rc);
    const conn_ptr = conn.?;

    const client_result = Loopback.fetchOnce(conn_ptr, allocator, startSession("client"));

    // Closing the client lets the server observe EOF and finish.
    ct.pancake_tcp_conn_release(conn_ptr);
    server_future.await(io);

    try client_result;
    try args.result;
}

test "c-abi last_error records a cause on connect failure" {
    ct.pancake_tcp_clear_last_error();
    try std.testing.expectEqual(@as(usize, 0), ct.pancake_tcp_last_error(null, 0));

    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    var conn: ?*ct.PancakeTcpConn = null;
    const host = "not a valid ip";
    const rc = ct.pancake_tcp_connect(netlayer_ptr, host.ptr, host.len, 9, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn);
    // A bad host string is an invalid argument, not a network fault.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, rc);

    var buf: [128]u8 = undefined;
    const len = ct.pancake_tcp_last_error(&buf, buf.len);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@min(len, buf.len - 1)], "connect") != null);
}

test "c-abi endpoint rejects bad arguments distinctly from network faults" {
    var netlayer: ?*ct.PancakeTcpNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ct.pancake_tcp_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ct.pancake_tcp_netlayer_release(netlayer_ptr);

    const host = "127.0.0.1";
    var conn: ?*ct.PancakeTcpConn = null;

    // A zero frame cap is an invalid argument, not a codec selector problem.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_connect(netlayer_ptr, host.ptr, host.len, 9, c.PANCAKE_CODEC_SYRUP, 0, &conn),
    );
    // An unknown codec selector is an invalid argument, like every other
    // out-of-range discriminant.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ct.pancake_tcp_connect(netlayer_ptr, host.ptr, host.len, 9, 999, frame_cap, &conn),
    );
    // A null required pointer is a null-pointer error.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        ct.pancake_tcp_connect(null, host.ptr, host.len, 9, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn),
    );
}

test "c-abi bootstrap registration allocates an export id" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&peer));
    const peer_ptr = peer.?;
    defer c.pancake_peer_release(peer_ptr);

    const swiss_a = "thermostat";
    const swiss_b = "hygrometer";
    var id_a: u64 = 0;
    var id_b: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_register_bootstrap_cap(peer_ptr, swiss_a.ptr, swiss_a.len, &id_a),
    );
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        c.pancake_peer_register_bootstrap_cap(peer_ptr, swiss_b.ptr, swiss_b.len, &id_b),
    );
    // Distinct swissnums get distinct export positions (the allocator advanced).
    try std.testing.expect(id_a != id_b);
}
