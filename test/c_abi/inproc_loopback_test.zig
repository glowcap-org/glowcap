//! C-ABI frame-boundary loopback over the in-process endpoints, the socket-free
//! sibling of `endpoint_loopback_test`. It proves the `pancake_inproc_*` handles
//! drive a real handshake + bootstrap fetch when the *host* owns the peer and
//! shuttles frames itself, with two peers in one process wired by in-process
//! pipes: no sockets, no file descriptors, so it runs anywhere the threaded
//! `std.Io` backend can park a thread.
//!
//! The peers are `engine.Peer`s driven through the public Zig boundary
//! (`recvStreamPrefix` / `takeOutbound`); the only thing under test that is new
//! is the C inproc-endpoint surface bridging bytes to that boundary on a string
//! designator instead of a host:port.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");
const ci = @import("c_abi_net_transport_inproc");
const model = pancake.ocapn.model;
const inproc = pancake.net.inproc;
const c_abi_loopback = @import("../support/c_abi_loopback.zig");
const handshake = @import("../support/handshake.zig");

const designator = "thermostat-room";

const Transport = struct {
    pub const Conn = *ci.PancakeInprocConn;
    pub const Listener = *ci.PancakeInprocListener;

    pub fn writeFrame(conn: Conn, cf: *c.PancakeFrame) i32 {
        return ci.pancake_inproc_conn_write_frame(conn, cf);
    }

    pub fn readFrame(conn: Conn, mf: *c.PancakeManagedFrame) i32 {
        return ci.pancake_inproc_conn_read_frame(conn, mf);
    }

    pub fn accept(
        listener: Listener,
        codec: u32,
        max_frame_bytes: usize,
        out_conn: *?Conn,
    ) i32 {
        return ci.pancake_inproc_accept(listener, codec, max_frame_bytes, out_conn);
    }

    pub fn releaseConn(conn: Conn) void {
        ci.pancake_inproc_conn_release(conn);
    }
};

const Loopback = c_abi_loopback.Harness(Transport);
const frame_cap = c_abi_loopback.frame_cap;

fn startSession(name: []const u8) model.Message {
    return handshake.startSession(inproc.transport_name, name);
}

test "c-abi inproc loopback: handshake to open + bootstrap fetch round-trip" {
    const allocator = std.testing.allocator;

    var netlayer: ?*ci.PancakeInprocNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ci.pancake_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.pancake_inproc_netlayer_release(netlayer_ptr);

    var listener: ?*ci.PancakeInprocListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_OK,
        ci.pancake_inproc_listen(netlayer_ptr, designator.ptr, designator.len, &listener),
    );
    const listener_ptr = listener.?;
    defer ci.pancake_inproc_listener_release(listener_ptr);

    var args: Loopback.ServerArgs = .{
        .listener = listener_ptr,
        .allocator = allocator,
        .start_session = startSession("server"),
    };
    const server_thread = try std.Thread.spawn(.{}, Loopback.serveThread, .{&args});

    var conn: ?*ci.PancakeInprocConn = null;
    const connect_rc = ci.pancake_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn);
    try std.testing.expectEqual(c.PANCAKE_OK, connect_rc);
    const conn_ptr = conn.?;

    const client_result = Loopback.fetchOnce(conn_ptr, allocator, startSession("client"));

    // Closing the client lets the server observe EOF and finish.
    ci.pancake_inproc_conn_release(conn_ptr);
    server_thread.join();

    try client_result;
    try args.result;
}

test "c-abi inproc connect rejects bad arguments and a missing listener distinctly" {
    var netlayer: ?*ci.PancakeInprocNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ci.pancake_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.pancake_inproc_netlayer_release(netlayer_ptr);

    var conn: ?*ci.PancakeInprocConn = null;

    // A zero frame cap is an invalid argument, not a codec selector problem.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ci.pancake_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.PANCAKE_CODEC_SYRUP, 0, &conn),
    );
    // An unknown codec selector is an invalid argument.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ci.pancake_inproc_connect(netlayer_ptr, designator.ptr, designator.len, 999, frame_cap, &conn),
    );
    // A null required pointer is a null-pointer error.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        ci.pancake_inproc_connect(null, designator.ptr, designator.len, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn),
    );
    // Dialing a designator with no bound listener is an I/O fault, with a cause
    // recorded for pancake_inproc_last_error, distinct from a malformed request.
    ci.pancake_inproc_clear_last_error();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_IO,
        ci.pancake_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn),
    );
    try std.testing.expect(ci.pancake_inproc_last_error(null, 0) > 0);
}

test "c-abi inproc listen rejects an empty designator" {
    var netlayer: ?*ci.PancakeInprocNetlayer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, ci.pancake_inproc_netlayer_new(&netlayer));
    const netlayer_ptr = netlayer.?;
    defer ci.pancake_inproc_netlayer_release(netlayer_ptr);

    const empty = "";
    var listener: ?*ci.PancakeInprocListener = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        ci.pancake_inproc_listen(netlayer_ptr, empty.ptr, empty.len, &listener),
    );
}
