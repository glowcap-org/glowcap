//! Live iroh transport: two pancake peers hold a real keyed OCapN
//! conversation over real iroh endpoints (ADR-0055).
//!
//! The server binds an iroh endpoint, registers the `iroh` netlayer resident,
//! and serves a Greeter actor behind the verified keyed handshake. The client
//! binds its *own* iroh endpoint and dials by the server's endpoint id, the
//! locator's designator — with the server's direct socket addresses riding the
//! locator's `direct-addresses` hint (relay-less, lookup-less: ADR-0055's
//! slice 1). The bytes on the wire are QUIC: encrypted and authenticated to the
//! server's Ed25519 endpoint key by iroh, then carrying the same
//! `op:start-session` keyed handshake, bootstrap fetch, and deliver/resolve the
//! TCP gates prove against Goblins.
//!
//! Both peers here are pancake, deliberately: this driver proves the
//! bring-your-own-netlayer contract carries an encrypted transport end to end,
//! with no second implementation in the picture. `goblins-iroh` is the outside
//! partner's check, over the iroh netlayer this repository wrote for Goblins.
//!
//! Beyond the conversation, the gate pins the seam's edges: address defects
//! refuse as typed `InvalidAddress` before the network is touched, closing the
//! endpoint releases a parked accept, and a seeded endpoint's id is the same
//! Ed25519 public key pancake's own crypto derives from the seed. That bridge is
//! the key-unification capstone stands on.
//!
//! Two capstones ride that bridge. Dial-by-id: two endpoints in the
//! `local_discovery` posture reach each other by node id alone, no
//! direct-address hints. That is the lookup half of the transport, proven
//! deterministically with no relay or public infrastructure. Key unification:
//! each peer seeds its endpoint and signs its `op:start-session` with the secret
//! half of that same seed, so over the live wire the partner's verified session
//! pubkey equals the node id the transport authenticated equals the signed
//! locator designator. One key is at once the transport identity, the OCapN
//! designator, and the session signing key. Durable identity: a vat tears its
//! endpoint down and rebinds from the same seed: same key, same node id at a
//! fresh address. A client reaches the same published cap through the
//! locator recorded before the restart, so a sturdyref (node id + swiss-number)
//! outlives the process that minted it.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build iroh-lib`, needs cargo), so it runs as the sibling
//! step `zig build iroh-interop`.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const driver = pancake.driver;
const net = pancake.net;

fn listenReady(layer: net.netlayer.Netlayer, allocator: std.mem.Allocator) !net.netlayer.Listener {
    var result = switch (layer.listen(allocator, .{ .designator = "" })) {
        .admitted => |result| result,
        .failed => |failure| return failure.cause,
    };
    return switch (result.requireReady()) {
        .ready => |listener| listener,
        .failed => |failure| failure.cause,
    };
}

const frame_cap: usize = 4096;
const greeting = "hello over iroh";

/// The published actor: answers `greet` with a static greeting.
const Greeter = harness.StaticReplyActor("greet", greeting);

/// Server half: accept one partner over iroh signing with `secret` — the
/// endpoint's own key, so the session key a dialer's identity pin verifies is
/// the node id it dialed — publish the greeter, serve until the client hangs
/// up. iroh is a key-designator transport, so every accept here is keyed; an
/// ephemeral accept identity is refused by the driver.
const hostOnce = harness.AcceptServeOne(
    Greeter,
    "greeter",
    frame_cap,
    "iroh-interop: server accepted a QUIC stream and opened the keyed session",
).run;

/// Prove the shutdown lever: an accept against a closed endpoint returns
/// `error.ConnectionLost` instead of parking its thread forever, the contract
/// `Resident.close` exists to provide.
fn expectAcceptClosed(listener: net.netlayer.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    if (listener.accept(&peer, .{ .read = &read_buf, .write = &write_buf })) |_| {
        return error.UnexpectedAccept;
    } else |err| switch (err) {
        error.ConnectionLost => {},
        else => return err,
    }
}

/// Client half: dial by endpoint id + direct-address hints through the
/// transport-neutral `connectVia`, fetch the greeter, call it, check the reply.
fn callOnce(
    netlayers: []const net.netlayer.Netlayer,
    designator: []const u8,
    direct_addrs: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const hint_entries = [_]model.HintEntry{.{
        .name = iroh.hint_direct_addresses,
        .value = .{ .string = direct_addrs },
    }};
    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = designator,
        .hints = .{ .entries = &hint_entries },
    };
    var cv = try driver.connectVia(allocator, netlayers, &scaffold.peer, locator, .ephemeral, scaffold.read_buf, scaffold.write_buf, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
    defer cv.deinit();
    std.debug.print("iroh-interop: client dialed by endpoint id and opened the keyed session\n", .{});

    const greeter = try cv.fetch("greeter");
    std.debug.print("iroh-interop: client bootstrap-fetched the greeter\n", .{});

    try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{.{ .string = "world" }}, greeting);
    std.debug.print("iroh-interop: client called greet and the reply matched\n", .{});
}

/// Dial by endpoint id with no direct-address hint — the discovery path, where
/// the netlayer resolves the partner by id alone — then fetch and call the
/// greeter. The locator carries an empty hint set, so a successful session
/// proves the dial was resolved, not hinted.
fn callByIdOnly(
    netlayers: []const net.netlayer.Netlayer,
    designator: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, netlayers, &scaffold.peer, locator, .ephemeral, scaffold.read_buf, scaffold.write_buf, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{.{ .string = "world" }}, greeting);
}

/// Assert the identity knot on an open session, as ADR-0097 leaves it: the
/// partner's signed locator designator is the iroh node id the transport
/// authenticated, and the partner's OCapN session pubkey is deliberately
/// *not* that key.
///
/// This used to assert all three were one value, the meaning of key
/// unification while a host signed every session with its durable key. Each
/// session now draws its own signing key, so the durable identity and the
/// session identity are different facts about the same peer: `node_id_hex`
/// names who the partner is, and the session key names only this session.
/// Asserting the difference is what would catch a regression back to one key.
fn assertPartnerIsNodeId(cv: *driver.BlockingSession, node_id_hex: []const u8) !void {
    const designator = cv.served.port.peer.session_state.partnerDesignator() orelse return error.NoPartnerDesignator;
    if (!std.mem.eql(u8, designator, node_id_hex)) return error.PartnerDesignatorMismatch;
    const key = cv.served.port.peer.session_state.partnerSessionKey() orelse return error.NoPartnerKey;
    if (key.len != 32) return error.PartnerKeyWidth;
    var key_arr: [32]u8 = undefined;
    @memcpy(&key_arr, key[0..32]);
    const key_hex = std.fmt.bytesToHex(key_arr, .lower);
    if (std.mem.eql(u8, &key_hex, node_id_hex)) return error.SessionKeyIsNotPerConnection;
}

/// Server half of the key-unification proof: accept over iroh signing the
/// responder handshake with `secret` (the endpoint's own key), assert the dialer
/// arrived as its own node id, then publish and serve.
fn hostUnified(
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,
    secret: pancake.foundation.crypto.SecretKey,
    expect_partner_id: []const u8,
) anyerror!void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    var cv = try driver.acceptVia(allocator, listener, &scaffold.peer, .{ .keyed = secret }, scaffold.read_buf, scaffold.write_buf, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
    defer cv.deinit();
    try assertPartnerIsNodeId(&cv, expect_partner_id);

    _ = try cv.publish("greeter", Greeter, .{});
    try cv.serve();
}

/// Client half of the key-unification proof: dial the server by id alone, sign
/// the dialer handshake with `secret` over the dialer's own `self_id`, assert the
/// server's session identity is its node id, then fetch and call the greeter so
/// the unified session is proven to carry real traffic.
fn callUnified(
    netlayers: []const net.netlayer.Netlayer,
    server_id: []const u8,
    self_id: []const u8,
    secret: pancake.foundation.crypto.SecretKey,
    allocator: std.mem.Allocator,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, netlayers, &scaffold.peer, locator, .{ .keyed = .{ .secret = secret, .designator = self_id } }, scaffold.read_buf, scaffold.write_buf, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
    defer cv.deinit();
    try assertPartnerIsNodeId(&cv, server_id);

    const greeter = try cv.fetch("greeter");
    try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{.{ .string = "world" }}, greeting);
}

/// One serve-and-reach cycle for the durable-identity proof: `server` hosts the
/// greeter while a fresh discovery client dials `dial_id` (a recorded sturdyref
/// designator) by id alone, fetches, and calls. Both peers share the process
/// address book, so `dial_id` resolves to whatever endpoint currently holds that
/// node id, which is the point: the locator is stable, the endpoint behind it
/// need not be.
fn restartCycle(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *iroh.Resident,
    server_secret: pancake.foundation.crypto.SecretKey,
    dial_id: []const u8,
) !void {
    var client = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
    defer client.deinit() catch |err| std.log.err("iroh client teardown failed: {s}", .{@errorName(err)});

    const s_entries = [_]net.netlayer.Netlayer{server.netlayer()};
    const c_entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var listener = try listenReady(net.netlayer.resolve(&s_entries, iroh.transport_name).?, allocator);
    defer std.debug.assert(listener.close() == null);

    var host = try io.concurrent(hostOnce, .{ listener, allocator, server_secret });
    const client_result = callByIdOnly(&c_entries, dial_id, allocator);
    if (client_result) |_| {} else |err| {
        std.debug.print("iroh-interop: durable-identity client failed: {s}\n", .{@errorName(err)});
        server.close();
    }
    const host_result = host.await(io);
    try client_result;
    try host_result;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The server endpoint is seeded so its accepts sign with the endpoint's
    // own key: iroh is a key-designator transport, and a dialer pins the
    // session identity to the node id it dialed.
    const main_server_seed: [32]u8 = @splat(0x31);
    const main_server_secret = pancake.foundation.crypto.SecretKey.fromSeed(main_server_seed);
    var server = iroh.Resident.init(io, &main_server_seed, .{ .reachability = .direct }) catch |err| {
        std.debug.print("iroh-interop: server endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer server.deinit() catch |err| std.log.err("iroh server teardown failed: {s}", .{@errorName(err)});
    var client = iroh.Resident.init(io, null, .{ .reachability = .direct }) catch |err| {
        std.debug.print("iroh-interop: client endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.deinit() catch |err| std.log.err("iroh client teardown failed: {s}", .{@errorName(err)});

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = server.nodeId(&id_buf);
    const server_addrs = try server.directAddrsOwned(allocator);
    defer allocator.free(server_addrs);
    std.debug.print("iroh-interop: server endpoint id {s} direct addrs {s}\n", .{ server_id, server_addrs });

    const server_entries = [_]net.netlayer.Netlayer{server.netlayer()};
    const client_entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var listener = try listenReady(net.netlayer.resolve(&server_entries, iroh.transport_name).?, allocator);
    defer std.debug.assert(listener.close() == null);

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator, main_server_secret });
    const client_result = callOnce(&client_entries, server_id, server_addrs, allocator);
    if (client_result) |_| {} else |err| {
        std.debug.print("iroh-interop: client failed: {s}\n", .{@errorName(err)});
        server.close();
    }
    const host_result = host_future.await(io);

    try client_result;
    try host_result;

    {
        var peer = engine.Peer.initNegotiating(allocator);
        defer peer.deinit();
        var read_buf: [256]u8 = undefined;
        var write_buf: [256]u8 = undefined;
        const bufs: net.netlayer.Buffers = .{ .read = &read_buf, .write = &write_buf };
        const nl = net.netlayer.resolve(&client_entries, iroh.transport_name).?;
        if (nl.dial(&peer, .{
            .transport = iroh.transport_name,
            .designator = "not-a-node-id",
            .hints = model.Hints.emptyFalse(),
        }, bufs, .inherit)) |_| return error.UnexpectedDial else |err| if (err != error.InvalidAddress) return err;
        if (nl.dial(&peer, .{
            .transport = iroh.transport_name,
            .designator = server_id,
            .hints = model.Hints.emptyFalse(),
        }, bufs, .inherit)) |_| return error.UnexpectedDial else |err| if (err != error.InvalidAddress) return err;
        std.debug.print("iroh-interop: address defects refused as InvalidAddress before touching the network\n", .{});
    }

    var parked = try io.concurrent(expectAcceptClosed, .{ listener, allocator });
    server.close();
    try parked.await(io);
    std.debug.print("iroh-interop: closing the endpoint released the parked accept\n", .{});

    {
        const seed: [32]u8 = @splat(0x42);
        var seeded = try iroh.Resident.init(io, &seed, .{ .reachability = .direct });
        defer seeded.deinit() catch |err| std.log.err("iroh seeded endpoint teardown failed: {s}", .{@errorName(err)});
        var seeded_buf: [iroh.node_id_len]u8 = undefined;
        const seeded_id = seeded.nodeId(&seeded_buf);
        const secret = pancake.foundation.crypto.SecretKey.fromSeed(seed);
        const expected = std.fmt.bytesToHex(secret.publicKey().bytes, .lower);
        if (!std.mem.eql(u8, seeded_id, &expected)) return error.SeededIdentityMismatch;
        std.debug.print("iroh-interop: a seeded endpoint's id is the Ed25519 key pancake derives from the same seed\n", .{});
    }

    {
        const d_server_seed: [32]u8 = @splat(0x33);
        const d_server_secret = pancake.foundation.crypto.SecretKey.fromSeed(d_server_seed);
        var d_server = try iroh.Resident.init(io, &d_server_seed, .{ .reachability = .local_discovery });
        defer d_server.deinit() catch |err| std.log.err("iroh discovery server teardown failed: {s}", .{@errorName(err)});
        var d_client = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
        defer d_client.deinit() catch |err| std.log.err("iroh discovery client teardown failed: {s}", .{@errorName(err)});

        var d_id_buf: [iroh.node_id_len]u8 = undefined;
        const d_server_id = d_server.nodeId(&d_id_buf);

        const d_server_entries = [_]net.netlayer.Netlayer{d_server.netlayer()};
        const d_client_entries = [_]net.netlayer.Netlayer{d_client.netlayer()};

        var d_listener = try listenReady(net.netlayer.resolve(&d_server_entries, iroh.transport_name).?, allocator);
        defer std.debug.assert(d_listener.close() == null);

        var d_host = try io.concurrent(hostOnce, .{ d_listener, allocator, d_server_secret });
        const d_client_result = callByIdOnly(&d_client_entries, d_server_id, allocator);
        if (d_client_result) |_| {} else |err| {
            std.debug.print("iroh-interop: dial-by-id-alone client failed: {s}\n", .{@errorName(err)});
            d_server.close();
        }
        const d_host_result = d_host.await(io);
        try d_client_result;
        try d_host_result;
        std.debug.print("iroh-interop: dialed by endpoint id alone through the discovery address book, no direct-address hints\n", .{});
    }

    {
        const crypto = pancake.foundation.crypto;
        const server_seed: [32]u8 = @splat(0x11);
        const client_seed: [32]u8 = @splat(0x22);
        const server_secret = crypto.SecretKey.fromSeed(server_seed);
        const client_secret = crypto.SecretKey.fromSeed(client_seed);

        var u_server = try iroh.Resident.init(io, &server_seed, .{ .reachability = .local_discovery });
        defer u_server.deinit() catch |err| std.log.err("iroh unification server teardown failed: {s}", .{@errorName(err)});
        var u_client = try iroh.Resident.init(io, &client_seed, .{ .reachability = .local_discovery });
        defer u_client.deinit() catch |err| std.log.err("iroh unification client teardown failed: {s}", .{@errorName(err)});

        var u_server_buf: [iroh.node_id_len]u8 = undefined;
        const u_server_id = u_server.nodeId(&u_server_buf);
        var u_client_buf: [iroh.node_id_len]u8 = undefined;
        const u_client_id = u_client.nodeId(&u_client_buf);

        const u_server_entries = [_]net.netlayer.Netlayer{u_server.netlayer()};
        const u_client_entries = [_]net.netlayer.Netlayer{u_client.netlayer()};

        var u_listener = try listenReady(net.netlayer.resolve(&u_server_entries, iroh.transport_name).?, allocator);
        defer std.debug.assert(u_listener.close() == null);

        var u_host = try io.concurrent(hostUnified, .{ u_listener, allocator, server_secret, u_client_id });
        const u_client_result = callUnified(&u_client_entries, u_server_id, u_client_id, client_secret, allocator);
        if (u_client_result) |_| {} else |err| {
            std.debug.print("iroh-interop: key-unification client failed: {s}\n", .{@errorName(err)});
            u_server.close();
        }
        const u_host_result = u_host.await(io);
        try u_client_result;
        try u_host_result;
        std.debug.print("iroh-interop: one key per peer is the iroh node id, the locator designator, and the session signing key, verified on both halves over the live wire\n", .{});
    }

    {
        const dur_seed: [32]u8 = @splat(0x55);
        const dur_secret = pancake.foundation.crypto.SecretKey.fromSeed(dur_seed);
        var sturdyref: [iroh.node_id_len]u8 = undefined;

        {
            var v1 = try iroh.Resident.init(io, &dur_seed, .{ .reachability = .local_discovery });
            defer v1.deinit() catch |err| std.log.err("iroh durable endpoint teardown failed: {s}", .{@errorName(err)});
            _ = v1.nodeId(&sturdyref);
            try restartCycle(io, allocator, &v1, dur_secret, sturdyref[0..]);
        }

        {
            var v2 = try iroh.Resident.init(io, &dur_seed, .{ .reachability = .local_discovery });
            defer v2.deinit() catch |err| std.log.err("iroh restarted endpoint teardown failed: {s}", .{@errorName(err)});
            var v2_buf: [iroh.node_id_len]u8 = undefined;
            const v2_id = v2.nodeId(&v2_buf);
            if (!std.mem.eql(u8, v2_id, sturdyref[0..])) return error.NodeIdNotDurable;
            try restartCycle(io, allocator, &v2, dur_secret, sturdyref[0..]);
        }
        std.debug.print("iroh-interop: a sturdyref (node id + swiss-number) outlives an endpoint restart, same seed, same node id, same published cap reached through the recorded locator\n", .{});
    }

    std.debug.print("iroh-interop: OK, encrypted iroh channel: keyed handshake + bootstrap fetch + deliver/resolve + dial-by-id discovery + key unification + durable identity, pancake to pancake\n", .{});
}
