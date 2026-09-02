//! Restart-stable TCP listening identity: the `keyed-tcp` loopback test
//! (ADR-0075).
//!
//! Three scenes over real 127.0.0.1 sockets. First, the happy path: a listener
//! bound from a fixed seed accepts under its key designator, and a client
//! dialing that designator (bound address riding the `direct-addresses` hint)
//! sees the partner's signed designator equal the key and a call round-trip.
//! Second, the load-bearing negative: a listener holding a *different* key at
//! the same kind of address, dialed under the original designator, is refused
//! at the handshake. A keyed listener signs the designator its own key
//! spells, so a squatter advertises its own identity rather than the dialed
//! one and the target check refuses it before the session opens
//! (`PartnerDesignatorMismatch`). This is not authentication: a malicious
//! cleartext peer can repeat the dialed designator. Third, the restart: the
//! same seed rebound on a fresh port is
//! reached through the recorded designator with only the hint updated, and the
//! recorded and fresh locators are equal under `model.peerLocatorsEqual`. The
//! designator is the identity, not the address, and the port change is what
//! proves it.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../support/netlayer.zig");
const support_actors = @import("../support/actors.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;

const frame_cap = 4096;

/// The published actor: answers `greet` with a static greeting.
const Greeter = support_actors.StaticReplyActor("greet", "hello from the keyed listener");

/// Accept one partner on the keyed listener, signing with `secret` (the key
/// whose hex is the listener's designator), publish the greeter, serve until
/// the client leaves — cleanly or by dropping the socket after its refused
/// handshake, which arrives here as an ordinary connection loss.
fn hostOnce(
    listener: net.netlayer.Listener,
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = driver.acceptVia(allocator, listener, &peer, .{ .keyed = secret }, read_buf, write_buf, .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } }) catch |err| switch (err) {
        // A pinned dialer that refuses our key drops the socket mid-handshake;
        // that is this vat's whole (expected) conversation in the negative arm.
        error.ConnectionLost, error.TruncatedFrame, driver.Error.ConnectionClosed => return,
        else => return err,
    };
    defer cv.deinit();
    _ = try cv.publish("greeter", Greeter, .{});
    try cv.serve();
}

/// Dial `locator` through the keyed-tcp netlayer, fetch the greeter, call it,
/// and assert the partner's signed designator is exactly `expect_designator`.
fn callKeyed(
    io: std.Io,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
    expect_designator: []const u8,
) !void {
    var resident = net.tcp.keyed.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectVia(allocator, &netlayers, &peer, locator, .ephemeral, read_buf, write_buf, .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer cv.deinit();

    // The knot: the partner's signed designator is the key that was dialed,
    // and the handshake pin already verified the session key equals it.
    const partner = peer.session_state.partnerDesignator() orelse return error.NoPartnerDesignator;
    try std.testing.expectEqualStrings(expect_designator, partner);

    const greeter = try cv.fetch("greeter");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "glowcap" }} }, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("hello from the keyed listener", arg.string);
        },
        .broken, .give => return error.CallBroke,
    }
}

/// Bind a keyed listener on port 0 from `resident`, run one hosted accept, and
/// dial it with the given designator, returning the client's result.
fn serveAndDial(
    io: std.Io,
    allocator: std.mem.Allocator,
    resident: *net.tcp.keyed.Resident,
    secret: crypto.SecretKey,
    dial_designator: []const u8,
) !void {
    var listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = secret.publicKey(),
    });
    defer netlayer_test.close(listener);

    const local_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, local_locator);
    try std.testing.expect(net.netlayer.directAddrHint(local_locator.hints) != null);
    const locator: model.PeerLocator = .{
        .transport = net.tcp.keyed.transport_name,
        .designator = dial_designator,
        .hints = local_locator.hints,
    };

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator, secret });
    const client_result = callKeyed(io, allocator, locator, dial_designator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "keyed-tcp loopback: the dialed key designator is the partner's signed identity and the call round-trips" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x71)));
    const designator = secret.publicKey().toDesignator();
    var resident = net.tcp.keyed.Resident{ .io = io };

    try serveAndDial(io, allocator, &resident, secret, designator[0..]);

    // The contract listener also reports the key as its designator (what a
    // `driver.Server.localDesignator` hands an application to publish).
    var listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = secret.publicKey(),
    });
    defer netlayer_test.close(listener);
    const local_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, local_locator);
    try std.testing.expectEqualStrings(designator[0..], local_locator.designator);
}

test "keyed-tcp negative: a listener claiming a different key than the dialed designator is refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const honest = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x72)));
    const squatter = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x73)));
    const dialed_designator = honest.publicKey().toDesignator();

    // The squatter answers the socket the hint names, holding a different key.
    var resident = net.tcp.keyed.Resident{ .io = io };
    var listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = squatter.publicKey(),
    });
    defer netlayer_test.close(listener);
    const local_locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, local_locator);
    const locator: model.PeerLocator = .{
        .transport = net.tcp.keyed.transport_name,
        .designator = dialed_designator[0..],
        .hints = local_locator.hints,
    };

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator, squatter });

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var dial_resident = net.tcp.keyed.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{dial_resident.netlayer()};
    // The squatter's hello advertises the identity its own key spells, not
    // the one this dial named, so the claim check refuses it. The connection
    // pump folds every protocol refusal into its `ProtocolAbort` family and
    // keeps the typed member readable on the peer (`AbortInfo`).
    try std.testing.expectError(
        error.ProtocolAbort,
        driver.connectVia(allocator, &netlayers, &peer, locator, .ephemeral, read_buf, write_buf, .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } }),
    );
    const abort = peer.lastAbort() orelse return error.NoAbortRecorded;
    try std.testing.expectEqualStrings("PartnerDesignatorMismatch", abort.error_name);
    try std.testing.expectEqual(model.AbortKind.invalid_start_session_signature, abort.kind.?);
    try std.testing.expect(!peer.sessionIsOpen());

    const host_result = host_future.await(io);
    try host_result;
}

test "keyed-tcp restart: the same seed on a fresh port is reachable through the recorded designator with only the hint updated" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const seed: [crypto.SEED_BYTES]u8 = @splat(0x74);
    const secret = crypto.SecretKey.fromSeed(seed);
    const recorded_designator = secret.publicKey().toDesignator();
    const recorded_locator: model.PeerLocator = .{
        .transport = net.tcp.keyed.transport_name,
        .designator = recorded_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };

    var resident = net.tcp.keyed.Resident{ .io = io };

    // First life: bind on port 0, serve one client through the key designator,
    // and record only the designator (the hint is per-life connection advice).
    var first_listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = secret.publicKey(),
    });
    const first_local = try first_listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, first_local);
    const first_hint = net.netlayer.directAddrHint(first_local.hints) orelse return error.MissingDirectAddresses;
    {
        const locator: model.PeerLocator = .{
            .transport = net.tcp.keyed.transport_name,
            .designator = recorded_designator[0..],
            .hints = first_local.hints,
        };
        var host_future = try io.concurrent(hostOnce, .{ first_listener, allocator, secret });
        const client_result = callKeyed(io, allocator, locator, recorded_designator[0..]);
        const host_result = host_future.await(io);
        try client_result;
        try host_result;
    }

    // Restart: the same seed rebuilds the same key on a fresh kernel-chosen
    // port. The first listener stays bound while the second binds, so the
    // kernel cannot hand back the same port — the port change is the proof
    // that the designator is the identity, not the address.
    const rebuilt = crypto.SecretKey.fromSeed(seed);
    var second_life = net.tcp.keyed.Resident{ .io = io };
    var second_listener = try netlayer_test.listenBlocking(second_life.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = rebuilt.publicKey(),
    });
    const second_local = try second_listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, second_local);
    const second_hint = net.netlayer.directAddrHint(second_local.hints) orelse return error.MissingDirectAddresses;
    try std.testing.expect(!std.mem.eql(u8, first_hint, second_hint));
    netlayer_test.close(first_listener);
    {
        // Re-dial the locator recorded before the restart: same designator,
        // only the hint updated.
        const locator: model.PeerLocator = .{
            .transport = net.tcp.keyed.transport_name,
            .designator = recorded_designator[0..],
            .hints = second_local.hints,
        };
        var host_future = try io.concurrent(hostOnce, .{ second_listener, allocator, rebuilt });
        const client_result = callKeyed(io, allocator, locator, recorded_designator[0..]);
        const host_result = host_future.await(io);
        try client_result;
        try host_result;
    }
    netlayer_test.close(second_listener);

    // The locator a partner recorded before the restart names the same peer
    // as the one it dialed after it: hints are connection advice, never
    // identity (`model.peerLocatorsEqual` compares transport + designator).
    const fresh_designator = rebuilt.publicKey().toDesignator();
    const fresh_locator: model.PeerLocator = .{
        .transport = net.tcp.keyed.transport_name,
        .designator = fresh_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try std.testing.expect(model.peerLocatorsEqual(recorded_locator, fresh_locator));
}
