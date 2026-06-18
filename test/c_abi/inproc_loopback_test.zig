//! C-ABI frame-boundary loopback over the in-process endpoints — the socket-free
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
const engine = pancake.ocapn.engine;
const inproc = pancake.net.inproc;
const handshake = @import("../support/handshake.zig");

const frame_cap = 4096;
const designator = "thermostat-room";

fn startSession(name: []const u8) model.Message {
    return handshake.startSession(inproc.transport_name, name);
}

fn isOpen(peer: *engine.Peer) bool {
    return peer.session_state.state == .open;
}

/// Same unsigned-handshake boundary proof as the TCP loopback: partner-signature
/// verification is off (the keyed, verified handshake is proven in `pairing_test`).
fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

const Step = enum { received, closed };

fn pumpStep(peer: *engine.Peer, conn: *ci.PancakeInprocConn) !Step {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const bytes = frame.bytes();
        var cf: c.PancakeFrame = .{ .bytes = bytes.ptr, .len = bytes.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
        if (ci.pancake_inproc_conn_write_frame(conn, &cf) != c.PANCAKE_OK) return error.WriteFailed;
    }

    var mf: c.PancakeManagedFrame = undefined;
    const rc = ci.pancake_inproc_conn_read_frame(conn, &mf);
    if (rc == c.PANCAKE_ERR_CLOSED) return .closed;
    if (rc != c.PANCAKE_OK) return error.ReadFailed;
    defer c.pancake_managed_frame_release(&mf);

    const bytes = (mf.bytes orelse return error.NullFrame)[0..mf.len];
    switch (try peer.recvStreamPrefix(bytes)) {
        .consumed => return .received,
        .incomplete => return error.PartialFrameFromEndpoint,
    }
}

const ServerArgs = struct {
    listener: *ci.PancakeInprocListener,
    allocator: std.mem.Allocator,
    result: anyerror!void = {},
};

fn serveThread(args: *ServerArgs) void {
    args.result = serveOnce(args);
}

fn serveOnce(args: *ServerArgs) !void {
    var peer = stubNegotiatingPeer(args.allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    var conn: ?*ci.PancakeInprocConn = null;
    if (ci.pancake_inproc_accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn) != c.PANCAKE_OK)
        return error.AcceptFailed;
    const conn_ptr = conn orelse return error.AcceptNull;
    defer ci.pancake_inproc_conn_release(conn_ptr);

    try peer.sendCopying(startSession("server"));
    while ((try pumpStep(&peer, conn_ptr)) != .closed) {}
}

fn fetchOnce(conn: *ci.PancakeInprocConn, allocator: std.mem.Allocator) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    try peer.sendCopying(startSession("client"));
    while (!isOpen(&peer)) {
        if ((try pumpStep(&peer, conn)) == .closed) return error.ClosedDuringHandshake;
    }
    drainEvents(&peer);

    const prepared = try engine.fetch.prepareFetchSwissnum(allocator, &peer.session_state, "thermostat");
    try peer.send(prepared.message);

    var settled = false;
    while (!settled) {
        const step = try pumpStep(&peer, conn);
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const owned = try event.decodeOwned(allocator);
            const match = try engine.fetch.tryMatchFetchOutcome(
                allocator,
                prepared.resolver_export,
                prepared.answer_position,
                owned,
            );
            switch (match) {
                .settled => |outcome| switch (outcome) {
                    .fulfilled => |reference| {
                        model.freeReference(allocator, reference);
                        settled = true;
                    },
                    .broken => |reason| {
                        allocator.free(reason);
                        return error.FetchBroke;
                    },
                    .malformed => return error.FetchMalformed,
                },
                .unrelated => |msg| model.freeMessage(allocator, msg),
            }
        }
        if (step == .closed) break;
    }

    try std.testing.expect(settled);
}

fn drainEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |event| {
        var e = event;
        e.deinit();
    }
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

    var args: ServerArgs = .{ .listener = listener_ptr, .allocator = allocator };
    const server_thread = try std.Thread.spawn(.{}, serveThread, .{&args});

    var conn: ?*ci.PancakeInprocConn = null;
    const connect_rc = ci.pancake_inproc_connect(netlayer_ptr, designator.ptr, designator.len, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn);
    try std.testing.expectEqual(c.PANCAKE_OK, connect_rc);
    const conn_ptr = conn.?;

    const client_result = fetchOnce(conn_ptr, allocator);

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
    // recorded for pancake_inproc_last_error — distinct from a malformed request.
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
