//! TCP loopback integration test: the headline of the netlayer design.
//!
//! Two real `engine.Peer`s talk over a 127.0.0.1 socket pair driven by a
//! `std.Io.Threaded` backend: the server runs concurrently (`io.concurrent`),
//! the client on the test fiber. We prove (1) the handshake drives both peers to
//! `open` over the wire, and (2) a bootstrap fetch. That fetch is an
//! `op:deliver` answered by an auto-`op:resolve` that round-trips end to end,
//! the same oracle scenario carried in envelopes over a byte stream.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const tcp = glowcap.net.tcp;
const fetch_pump = @import("../support/fetch_pump.zig");
const wait = @import("../support/wait.zig");
const handshake = @import("../support/handshake.zig");
const descriptor_quota = @import("../support/descriptor_quota.zig");

const ip = std.Io.net;

const frame_cap = 4096;

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(tcp.transport_name, designator);
}

const ServerError = anyerror;

/// Accept one connection, complete the handshake, and serve the bootstrap fetch
/// by pumping until the client closes (graceful EOF). The responder half is
/// automatic in the runtime. The server only drives bytes.
fn serveOnce(listener: *tcp.Listener, allocator: std.mem.Allocator) ServerError!void {
    var peer = handshake.stubPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var conn = try listener.accept(&peer, read_buf, write_buf, .{});
    defer conn.deinit();

    try peer.sendBorrowed(startSession("server"));

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
    var peer = handshake.stubPeer(allocator);
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
    var peer = handshake.stubPeer(allocator);
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
    // tolerant: a reset in place of EOF still means the far side closed, which is all this wait needs.
    _ = reader.interface.readSliceShort(&sink) catch {};
}

test "tcp listener close wakes and joins a blocked accept" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    var accept = try io.concurrent(acceptUntilListenerClose, .{ &listener, allocator });
    try wait.untilLeaseHeld(io, &listener.profile.socket.gate);
    listener.deinit();
    try accept.await(io);
}

test "a nonblocking accept keeps an aborted arrival or an empty queue pending" {
    const pending = @import("glowcap").net.socket_tcp.testing.pendingOnAccept;
    try std.testing.expect(pending(.CONNABORTED));
    try std.testing.expect(pending(.AGAIN));
    try std.testing.expect(!pending(.MFILE));
}

test "a full descriptor table refuses the accept and leaves the listener open" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();
    const first = try ip.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer first.close(io);
    const second = try ip.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer second.close(io);

    const raw = &listener.profile.socket;
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    {
        const quota = try descriptor_quota.Lowered.begin(0);
        defer quota.end();
        // The blocking accept, then the event-driven one: each names the
        // quota, and neither reports the listener as shut down.
        try std.testing.expectError(error.AcceptRefused, listener.acceptStream());
        switch (raw.acceptOutcome(&read_buf, &write_buf, .{}, .ready)) {
            .listener_failed => |err| try std.testing.expectEqual(error.ProcessFdQuotaExceeded, err),
            else => return error.TestUnexpectedResult,
        }
    }
    // Linux keeps a refused arrival queued, and macOS closes it, so dial
    // fresh ones: the same listener takes them on either kernel.
    const third = try ip.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer third.close(io);
    const fourth = try ip.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer fourth.close(io);
    const served = try listener.acceptStream();
    served.close(io);
    try std.testing.expect(try listener.waitAcceptable(5_000));
    switch (raw.acceptOutcome(&read_buf, &write_buf, .{}, .ready)) {
        .connection => |accepted| {
            var conn = accepted;
            conn.close();
        },
        else => return error.TestUnexpectedResult,
    }
}

test "a refused readiness poll keeps its cause and names the listener refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const poll = glowcap.net.poll;
    var script: poll.testing.Script = .{ .errnos = &.{ .NOMEM, .NOMEM } };
    const guard = poll.testing.inject(&script);
    defer guard.deinit();
    try std.testing.expectError(error.SystemResources, listener.waitAcceptable(0));
    try std.testing.expectError(error.AcceptRefused, listener.asNetlayer().waitAcceptable(0));
    try std.testing.expectEqual(@as(usize, 2), script.calls);
}
