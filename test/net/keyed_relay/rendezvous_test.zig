//! The keyed-relay headline loopback: register, get pinged in the park,
//! cold dial the key designator through the relay's rendezvous leg, and
//! fetch round-trip over the bridged WebSocket pair. A cold dial routed
//! through the target's other relay, and malformed, typed, duplicate, and
//! oversized relay hints refused. The live sibling against the Deno
//! reference relay is `zig build zig-keyed-relay-rendezvous`.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../../support/netlayer.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;
const keyed_relay = net.relay;
const ws_relay = @import("../../support/ws_relay.zig");
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const wait = @import("../../support/wait.zig");

const Io = std.Io;
const ip = std.Io.net;

const admission = @import("../../support/keyed_relay_admission.zig");
const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;

const frame_cap = admission.frame_cap;

const relay_support = @import("harness.zig");
const stubNegotiatingPeer = relay_support.stubNegotiatingPeer;
const startSession = relay_support.startSession;
const serveRegistered = relay_support.serveRegistered;

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
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://localhost:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://LOCALHOST:{d}/register", .{port});

    const identity = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x6e)));

    var registered = try keyed_relay.Resident.initRegistered(
        allocator,
        io,
        relay_url,
        register_url,
        identity.publicKey(),
    );
    defer _ = registered.deinit();
    var dialer = try keyed_relay.Resident.init(allocator, io, relay_url);
    defer _ = dialer.deinit();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &server, allocator });
    defer _ = relay_future.cancel(io) catch {};

    // `listen` schedules registration without performing network I/O itself.
    // The relay fixture accepts that leg first and pings it before accepting
    // the rendezvous leg, proving the parked task is live before data arrives.
    const registered_nl = registered.netlayer();
    const listener = try netlayer_test.listenBlocking(registered_nl, allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    defer netlayer_test.close(listener);

    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });
    defer _ = serve_future.cancel(io) catch {};

    // `listenBlocking` consumes the pending construction result only after
    // registration, so the cold dial cannot race the relay's registration
    // accept. The operation's readiness edge supplies the ordering, not a
    // sleep in this test.

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
        var conn = nl.dial(&peer, locator, .{ .read = read_buf, .write = write_buf }, .inherit) catch |err| break :blk err;
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

test "keyed-relay routes a cold dial through the target's other relay" {
    const allocator = std.testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Keep the configured relay distinct and unavailable. A successful dial
    // therefore proves the locator hint selected the target's relay rather
    // than merely using the resident default.
    const unused_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var unused_server = try ip.IpAddress.listen(&unused_addr, io, .{ .reuse_address = true });
    const unused_port = unused_server.socket.address.getPort();
    unused_server.deinit(io);

    const target_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var target_server = try ip.IpAddress.listen(&target_addr, io, .{ .reuse_address = true });
    defer target_server.deinit(io);
    const target_port = target_server.socket.address.getPort();

    var configured_url_buf: [64]u8 = undefined;
    const configured_url = try std.fmt.bufPrint(
        &configured_url_buf,
        "ws://127.0.0.1:{d}/relay",
        .{unused_port},
    );
    var target_relay_url_buf: [64]u8 = undefined;
    const target_relay_url = try std.fmt.bufPrint(
        &target_relay_url_buf,
        "ws://127.0.0.1:{d}/relay",
        .{target_port},
    );
    var target_register_url_buf: [64]u8 = undefined;
    const target_register_url = try std.fmt.bufPrint(
        &target_register_url_buf,
        "ws://127.0.0.1:{d}/register",
        .{target_port},
    );

    const identity = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x7a)));
    var registered = try keyed_relay.Resident.initRegistered(
        allocator,
        io,
        target_relay_url,
        target_register_url,
        identity.publicKey(),
    );
    defer _ = registered.deinit();
    var dialer = try keyed_relay.Resident.init(allocator, io, configured_url);
    defer _ = dialer.deinit();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &target_server, allocator });
    defer _ = relay_future.cancel(io) catch {};

    const listener = try netlayer_test.listenBlocking(registered.netlayer(), allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    defer netlayer_test.close(listener);
    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });
    defer _ = serve_future.cancel(io) catch {};

    const advertised = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, advertised);
    try std.testing.expectEqualStrings(
        keyed_relay.rendezvous_relay_hint,
        advertised.hints.entries[0].name,
    );
    try std.testing.expectEqualStrings(
        target_relay_url,
        advertised.hints.entries[0].value.string,
    );

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const locator = advertised;
    const client_result = blk: {
        var conn = dialer.netlayer().dial(&peer, locator, .{ .read = read_buf, .write = write_buf }, .inherit) catch |err|
            break :blk err;
        defer conn.deinit();
        fetch_pump.handshakeToOpen(&peer, &conn, startSession("client")) catch |err|
            break :blk err;
        break :blk {};
    };

    const serve_result = serve_future.await(io);
    const relay_result = relay_future.await(io);
    try client_result;
    try serve_result;
    try relay_result;
}

test "keyed-relay refuses malformed, typed, duplicate, and oversized relay hints" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var resident = try keyed_relay.Resident.init(allocator, threaded.io(), "ws://127.0.0.1:1/relay");
    defer _ = resident.deinit();

    const identity = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x7b)));
    const designator = identity.publicKey().toDesignator();

    // A listener cannot truthfully advertise the dial URL when registration
    // is on a different relay authority.
    try std.testing.expectError(
        error.InvalidRelayUrl,
        keyed_relay.Resident.initRegistered(
            allocator,
            threaded.io(),
            "ws://127.0.0.1:1/relay",
            "ws://127.0.0.1:2/register",
            identity.publicKey(),
        ),
    );

    const invalid_values = [_]model.HintValue{
        .{ .string = "http://127.0.0.1:1/relay" },
        .{ .string = "ws://127.0.0.1:1/relay#fragment" },
        .{ .bytes = "ws://127.0.0.1:1/relay" },
    };
    for (invalid_values) |value| {
        const locator: model.PeerLocator = .{
            .transport = keyed_relay.transport_name,
            .designator = designator[0..],
            .hints = .{ .entries = &.{.{
                .name = keyed_relay.rendezvous_relay_hint,
                .value = value,
            }} },
        };
        try std.testing.expectError(error.InvalidAddress, resident.dialRaw(locator));
        try std.testing.expectError(error.InvalidAddress, keyed_relay.DialResolver.resolve(locator));
    }

    var oversized: [keyed_relay.max_rendezvous_relay_hint_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    const oversized_locator: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = .{ .entries = &.{.{
            .name = keyed_relay.rendezvous_relay_hint,
            .value = .{ .string = &oversized },
        }} },
    };
    try std.testing.expectError(error.InvalidAddress, resident.dialRaw(oversized_locator));
    try std.testing.expectError(error.InvalidAddress, keyed_relay.DialResolver.resolve(oversized_locator));

    const duplicate_locator: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = .{ .entries = &.{
            .{ .name = keyed_relay.rendezvous_relay_hint, .value = .{ .string = "ws://127.0.0.1:1/relay" } },
            .{ .name = keyed_relay.rendezvous_relay_hint, .value = .{ .string = "ws://127.0.0.1:1/relay" } },
        } },
    };
    try std.testing.expectError(error.InvalidAddress, resident.dialRaw(duplicate_locator));
    try std.testing.expectError(error.InvalidAddress, keyed_relay.DialResolver.resolve(duplicate_locator));
}
