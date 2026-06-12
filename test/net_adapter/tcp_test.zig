//! TCP loopback integration proof — the headline of the netlayer design.
//!
//! Two real `engine.Peer`s talk over a 127.0.0.1 socket pair driven by a
//! `std.Io.Threaded` backend: the server runs concurrently (`io.concurrent`),
//! the client on the test fiber. We prove (1) the handshake drives both peers to
//! `open` over the wire, and (2) a bootstrap fetch — an `op:deliver` answered by
//! an auto-`op:resolve` — round-trips end to end, the same scenario the
//! in-process conformance harness runs, now framed by `recvStreamPrefix` over a
//! byte stream.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const tcp = pancake.net_adapter.tcp;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const net = std.Io.net;

const frame_cap = 4096;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

/// This loopback proof exercises transport + framing, and its `startSession`
/// carries the stub zero signature — so the peers run with partner-signature
/// verification off (a verifying peer would refuse the unsigned handshake). The
/// keyed, verified handshake is proven in `pairing_test`.
fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

const ServerError = anyerror;

/// Accept one connection, complete the handshake, and serve the bootstrap fetch
/// by pumping until the client closes (graceful EOF). The responder half is
/// automatic in the runtime; the server only drives bytes.
fn serveOnce(listener: *tcp.Listener, allocator: std.mem.Allocator) ServerError!void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, read_buf, write_buf);
    defer conn.deinit();

    try peer.sendCopying(startSession("server"));

    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            // The client closing after it has its answer is the normal end.
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

/// Connect, handshake to open, fetch `thermostat`, and assert the fetch settles
/// fulfilled. Closes the connection on return (its `defer`), which lets the
/// concurrent server observe EOF and finish.
fn fetchOnce(io: std.Io, address: net.IpAddress, allocator: std.mem.Allocator) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    // Dial via the locator path (the `acceptable-location` reconnect entry),
    // exercising designator parsing end to end rather than the raw-address shim.
    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{address.getPort()});
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf);
    defer conn.deinit();

    // 1. Handshake.
    try fetch_pump.handshakeToOpen(&peer, &conn, startSession("client"));

    // 2. Fetch the published cap and pump until it settles fulfilled.
    const reference = try fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat");
    model.freeReference(allocator, reference);
}

test "tcp loopback: handshake to open + bootstrap fetch round-trip" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    // Server runs concurrently; the client drives this fiber.
    var server_future = try io.concurrent(serveOnce, .{ &listener, allocator });

    const client_result = fetchOnce(io, address, allocator);

    // Closing the client (fetchOnce's defer ran) lets the server see EOF.
    const server_result = server_future.await(io);

    try client_result;
    try server_result;
}
