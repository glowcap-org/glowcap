//! The keyed-relay netlayer: the RFC 6455 client codec's refusals, the relay
//! URL grammar, and the headline loopback — a native peer registers at an
//! in-process relay (`test/support/ws_relay.zig`), another native peer cold
//! dials its key designator through the relay's rendezvous leg, and a
//! bootstrap fetch round-trips over the bridged WebSocket pair. The relay
//! pings the parked registration before the dial and the listener answers in
//! place, so the wait loop's control-frame handling is on the proven path.
//! The live sibling against the Deno reference relay is
//! `zig build zig-keyed-relay-rendezvous`.

const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;
const keyed_relay = net.keyed_relay;
const ws_relay = @import("../support/ws_relay.zig");
const fetch_pump = @import("../support/fetch_pump.zig");
const handshake = @import("../support/handshake.zig");

const Io = std.Io;
const ip = std.Io.net;

const frame_cap = 4096;

// --- Codec units -----------------------------------------------------------

test "acceptKey reproduces the RFC 6455 worked example" {
    var out: [28]u8 = undefined;
    keyed_relay.acceptKey(&out, "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", out[0..]);
}

fn headerOf(bytes: []const u8) keyed_relay.FrameError!keyed_relay.FrameHeader {
    var r = Io.Reader.fixed(bytes);
    return keyed_relay.readFrameHeader(&r);
}

test "readFrameHeader accepts the plain server shapes" {
    // FIN binary, 5-byte payload.
    const small = try headerOf(&.{ 0x82, 0x05 });
    try std.testing.expectEqual(keyed_relay.Opcode.binary, small.opcode);
    try std.testing.expectEqual(@as(u64, 5), small.len);
    try std.testing.expect(small.fin);

    // 16-bit extended length.
    const mid = try headerOf(&.{ 0x82, 126, 0x01, 0x2c });
    try std.testing.expectEqual(@as(u64, 300), mid.len);

    // 64-bit extended length.
    const big = try headerOf(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70 });
    try std.testing.expectEqual(@as(u64, 70000), big.len);

    // Non-final binary then a continuation: fragmentation streams through.
    const frag = try headerOf(&.{ 0x02, 0x05 });
    try std.testing.expect(!frag.fin);
    const cont = try headerOf(&.{ 0x80, 0x03 });
    try std.testing.expectEqual(keyed_relay.Opcode.continuation, cont.opcode);
}

test "readFrameHeader fails closed on every hostile shape" {
    // A reserved bit set (no extension negotiated).
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0xc2, 0x05 }));
    // A masked server frame (RFC 6455 forbids it).
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x82, 0x85, 1, 2, 3, 4 }));
    // A text frame on a binary protocol.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x81, 0x05 }));
    // An unknown opcode.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x83, 0x05 }));
    // A control frame past the 125-byte cap.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x89, 126, 0x00, 0x80 }));
    // A fragmented ping.
    try std.testing.expectError(error.ProtocolViolation, headerOf(&.{ 0x09, 0x05 }));
    // A 64-bit length with the sign bit set.
    try std.testing.expectError(
        error.ProtocolViolation,
        headerOf(&.{ 0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 1 }),
    );
    // Truncation mid-header.
    try std.testing.expectError(error.Truncated, headerOf(&.{0x82}));
    try std.testing.expectError(error.Truncated, headerOf(&.{ 0x82, 126, 0x01 }));
}

test "writeFrameHeader emits the masked client shapes readFrameHeader's mirror expects" {
    const mask = [4]u8{ 0xa1, 0xb2, 0xc3, 0xd4 };
    var buf: [keyed_relay.max_header_len]u8 = undefined;

    const small = keyed_relay.writeFrameHeader(&buf, .binary, 5, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x85, 0xa1, 0xb2, 0xc3, 0xd4 }, small);

    const mid = keyed_relay.writeFrameHeader(&buf, .binary, 300, mask);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0xfe, 0x01, 0x2c, 0xa1, 0xb2, 0xc3, 0xd4 }, mid);

    const big = keyed_relay.writeFrameHeader(&buf, .binary, 70000, mask);
    try std.testing.expectEqual(@as(usize, keyed_relay.max_header_len), big.len);
    try std.testing.expectEqual(@as(u8, 0x82), big[0]);
    try std.testing.expectEqual(@as(u8, 0xff), big[1]);
}

test "RelayUrl.parse admits ws IP-literal endpoints and refuses the rest" {
    const good = try keyed_relay.RelayUrl.parse("ws://127.0.0.1:8000/relay");
    try std.testing.expectEqualStrings("127.0.0.1", good.host);
    try std.testing.expectEqual(@as(u16, 8000), good.port);
    try std.testing.expectEqualStrings("/relay", good.path);

    const bare = try keyed_relay.RelayUrl.parse("ws://[::1]:9000");
    try std.testing.expectEqualStrings("", bare.path);

    // The scheme is `ws` only (cleartext channel, keyed handshake carries the
    // authentication); anything else refuses.
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("wss://127.0.0.1:1/x"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("http://127.0.0.1:1/x"));
    // The native tier resolves no names, and the port is explicit.
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://relay.example:80/x"));
    try std.testing.expectError(error.InvalidRelayUrl, keyed_relay.RelayUrl.parse("ws://127.0.0.1/x"));
}

// --- The loopback scenario -------------------------------------------------

fn stubNegotiatingPeer(allocator: std.mem.Allocator) engine.Peer {
    return engine.Peer.initNegotiatingWith(allocator, .{ .verify_partner_handshake = false });
}

fn startSession(designator: []const u8) model.Message {
    return handshake.startSession(keyed_relay.transport_name, designator);
}

/// The registered peer: wait through the relay's ping on an already-live
/// registration, accept the bridged session, and serve the bootstrap fetch.
/// The `listen` (which registers) runs on the test fiber before this spawns,
/// so the dialer cannot reach the relay ahead of the registration.
fn serveRegistered(
    listener: net.netlayer.Listener,
    identity: crypto.PeerKey,
    allocator: std.mem.Allocator,
) !void {
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    _ = try peer.registerBootstrapCap("thermostat");

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    while (!(try listener.waitAcceptable(500))) {}
    var conn = try listener.accept(&peer, .{ .read = read_buf, .write = write_buf });
    defer conn.deinit();

    const hex = identity.toDesignator();
    try peer.sendCopying(startSession(hex[0..]));

    while (true) {
        const progress = conn.pump() catch |err| switch (err) {
            error.ConnectionLost, error.TruncatedFrame => break,
            else => return err,
        };
        if (progress == .closed) break;
    }
}

test "keyed-relay loopback: register, ping in the park, cold dial, fetch round-trip" {
    const allocator = std.testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    const identity = crypto.SecretKey.fromSeed([_]u8{0x6e} ** crypto.SEED_BYTES);

    var registered = keyed_relay.Resident{
        .io = io,
        .relay_url = try keyed_relay.RelayUrl.parse(relay_url),
        .register_url = try keyed_relay.RelayUrl.parse(register_url),
        .public_key = identity.publicKey(),
    };
    var dialer = try keyed_relay.Resident.init(io, relay_url);

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &server, allocator });

    // Register on this fiber before anything dials: `listen` returns only once
    // the relay has upgraded the registration, so the rendezvous leg below can
    // never reach the relay first.
    const registered_nl = registered.netlayer();
    const listener = try registered_nl.listen(allocator, .{ .designator = "" });
    defer listener.close();

    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });

    // The dialing peer: cold dial the registered key through the relay.
    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const designator = identity.publicKey().toDesignator();
    const locator: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyMap(),
    };
    const client_result = blk: {
        const nl = dialer.netlayer();
        var conn = nl.dial(&peer, locator, .{ .read = read_buf, .write = write_buf }) catch |err| break :blk err;
        defer conn.deinit();
        fetch_pump.handshakeToOpen(&peer, &conn, startSession("client")) catch |err| break :blk err;
        const reference = fetch_pump.settleFetch(allocator, &peer, &conn, "thermostat") catch |err| break :blk err;
        model.freeReference(allocator, reference);
        break :blk {};
    };

    const serve_result = serve_future.await(io);
    const relay_result = relay_future.await(io);
    try client_result;
    try serve_result;
    try relay_result;
}

test "keyed-relay dial refuses a non-key designator and a listen without registration config" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try keyed_relay.Resident.init(io, "ws://127.0.0.1:1/relay");
    const nl = resident.netlayer();

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    // A non-key designator refuses before any I/O.
    const bad: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = "not-a-key",
        .hints = model.Hints.emptyMap(),
    };
    try std.testing.expectError(
        error.InvalidAddress,
        nl.dial(&peer, bad, .{ .read = &read_buf, .write = &write_buf }),
    );

    // A dial-only resident (no register URL, no identity) refuses listen.
    try std.testing.expectError(
        error.InvalidAddress,
        nl.listen(allocator, .{ .designator = "" }),
    );
}
