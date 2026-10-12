//! TCP loopback integration test: the headline of the netlayer design.
//!
//! Two real `engine.Peer`s talk over a 127.0.0.1 socket pair driven by a
//! `std.Io.Threaded` backend: the server runs concurrently (`io.concurrent`),
//! the client on the test fiber. We prove (1) the handshake drives both peers to
//! `open` over the wire, and (2) a bootstrap fetch. That fetch is an
//! `op:deliver` answered by an auto-`op:resolve` that round-trips end to end,
//! the same oracle scenario framed by `recvStreamPrefix` over a byte stream.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const ip = std.Io.net;

const frame_cap = 4096;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

/// This loopback proof exercises transport + framing, and its `startSession`
/// carries the stub zero signature, so the peers run with partner-signature
/// verification off (a verifying peer would refuse the unsigned handshake). The
/// keyed, verified handshake is proven in `pairing_test`.
fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

const ServerError = anyerror;

/// Accept one connection, complete the handshake, and serve the bootstrap fetch
/// by pumping until the client closes (graceful EOF). The responder half is
/// automatic in the runtime. The server only drives bytes.
fn serveOnce(listener: *tcp.Listener, allocator: std.mem.Allocator) ServerError!void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, read_buf, write_buf, .{});
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
fn fetchOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    // Dial via the locator path (the `acceptable-location` reconnect entry),
    // exercising designator parsing end to end rather than the raw-address shim.
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", address.getPort());
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    const locator: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyMap(),
    };
    var conn = try tcp.connect(io, &peer, locator, read_buf, write_buf, .{});
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

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
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

test "tcp listener owns its address exclusively" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();

    if (tcp.Listener.bind(io, listener.localAddress())) |second_value| {
        var second = second_value;
        second.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(error.AddressInUse, err);
}

test "tcp.locator formats a host:port designator into fixed-width caller storage" {
    // `locator` takes a `*[designator_buf_len]u8`, so a short buffer cannot be
    // passed and the internal format is infallible. The widest designator (a
    // bracketed IPv6 literal with a five-digit port) still fits with room to
    // spare, so both families round-trip.
    var buf: [tcp.designator_buf_len]u8 = undefined;

    const v4 = try tcp.parseHostPort("127.0.0.1", 9000);
    const loc4 = tcp.locatorFromAddress(&buf, v4);
    try std.testing.expectEqualStrings(tcp.transport_name, loc4.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9000", loc4.designator);
    const back4 = try tcp.parseDesignator(loc4.designator);
    try std.testing.expect(back4.eql(&v4));

    const v6 = try tcp.parseHostPort("::1", 65535);
    const loc6 = tcp.locatorFromAddress(&buf, v6);
    try std.testing.expectEqualStrings("[::1]:65535", loc6.designator);
    try std.testing.expect(loc6.designator.len <= tcp.designator_buf_len);
    const back6 = try tcp.parseDesignator(loc6.designator);
    try std.testing.expect(back6.eql(&v6));
}

fn acceptUntilListenerClose(listener: *tcp.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    try std.testing.expectError(
        error.ConnectionLost,
        listener.accept(&peer, &read_buf, &write_buf, .{}),
    );
}

test "tcp listener restarted onto its port reclaims it from TIME_WAIT" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var first = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    const address = first.localAddress();

    // One raw connection whose server side closes first: the shutdown order
    // that leaves the port's TIME_WAIT sockets with the listener. The kernel
    // lets a rebind reclaim past them only when both listener generations set
    // SO_REUSEADDR (`socket.openListenerReuseAddr` documents the contract),
    // so before that landed this rebind lost the port for the TIME_WAIT
    // minute, exactly how a stateful server restarted onto its pinned port
    // failed under load.
    var client = try io.concurrent(readUntilEof, .{ io, address });
    const served = try first.acceptStream();
    served.close(io);
    try client.await(io);
    first.deinit();

    var second = try tcp.Listener.bind(io, address);
    second.deinit();
}

/// Dial `address`, wait for the far side's close, then close. Keeping the
/// client open across the server's close is what puts the TIME_WAIT on the
/// server side.
fn readUntilEof(io: std.Io, address: ip.IpAddress) !void {
    const stream = try ip.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);
    var byte: [1]u8 = undefined;
    var reader = stream.reader(io, &byte);
    var sink: [1]u8 = undefined;
    _ = reader.interface.readSliceShort(&sink) catch {};
}

test "tcp listener close wakes and joins a blocked accept" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    var accept = try io.concurrent(acceptUntilListenerClose, .{ &listener, allocator });
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    listener.deinit();
    try accept.await(io);
}
