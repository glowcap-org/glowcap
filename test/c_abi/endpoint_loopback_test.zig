//! C-ABI frame-boundary loopback — proves the blocking TCP endpoint handles drive a
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
const engine = pancake.ocapn.engine;
const tcp = pancake.net.tcp;
const handshake = @import("../support/handshake.zig");

const frame_cap = 4096;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

fn isOpen(peer: *engine.Peer) bool {
    return peer.session_state.state == .open;
}

/// This boundary proof exercises the C endpoint + framing, and its `startSession`
/// carries the stub zero signature — so the peers run with partner-signature
/// verification off (a verifying peer would refuse the unsigned handshake). The
/// keyed, verified handshake is proven in `pairing_test`.
fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

const Step = enum { received, closed };

/// One pump over a C endpoint: encode + write all queued outbound, then block
/// for one inbound frame and apply it through the peer boundary.
fn pumpStep(peer: *engine.Peer, conn: *ct.PancakeTcpConn) !Step {
    while ((try peer.step()) != .idle) {}
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const bytes = frame.bytes();
        var cf: c.PancakeFrame = .{ .bytes = bytes.ptr, .len = bytes.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
        if (ct.pancake_tcp_conn_write_frame(conn, &cf) != c.PANCAKE_OK) return error.WriteFailed;
    }

    var mf: c.PancakeManagedFrame = undefined;
    const rc = ct.pancake_tcp_conn_read_frame(conn, &mf);
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
    listener: *ct.PancakeTcpListener,
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

    var conn: ?*ct.PancakeTcpConn = null;
    if (ct.pancake_tcp_accept(args.listener, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn) != c.PANCAKE_OK)
        return error.AcceptFailed;
    const conn_ptr = conn orelse return error.AcceptNull;
    defer ct.pancake_tcp_conn_release(conn_ptr);

    try peer.sendCopying(startSession("server"));
    while ((try pumpStep(&peer, conn_ptr)) != .closed) {}
}

fn fetchOnce(conn: *ct.PancakeTcpConn, allocator: std.mem.Allocator) !void {
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

    var args: ServerArgs = .{ .listener = listener_ptr, .allocator = allocator };
    const server_thread = try std.Thread.spawn(.{}, serveThread, .{&args});

    var conn: ?*ct.PancakeTcpConn = null;
    const connect_rc = ct.pancake_tcp_connect(netlayer_ptr, host.ptr, host.len, port, c.PANCAKE_CODEC_SYRUP, frame_cap, &conn);
    try std.testing.expectEqual(c.PANCAKE_OK, connect_rc);
    const conn_ptr = conn.?;

    const client_result = fetchOnce(conn_ptr, allocator);

    // Closing the client lets the server observe EOF and finish.
    ct.pancake_tcp_conn_release(conn_ptr);
    server_thread.join();

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
    // Distinct swissnums get distinct export ids (the allocator advanced).
    try std.testing.expect(id_a != id_b);
}
