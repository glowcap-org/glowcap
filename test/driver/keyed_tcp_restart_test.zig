//! Restart-stable TCP listening identity — the `keyed-tcp` loopback proof
//! (ADR-0075).
//!
//! Three scenes over real 127.0.0.1 sockets. First, the happy path: a listener
//! bound from a fixed seed accepts under its key designator, and a client
//! dialing that designator (bound address riding the `direct-addresses` hint)
//! sees the partner's signed designator equal the key and a call round-trip.
//! Second, the load-bearing negative: a listener holding a *different* key at
//! the same kind of address, dialed under the original designator, is refused
//! at the handshake with `PartnerKeyMismatch` — the pin is what makes the
//! designator trustworthy, so without this arm the whole feature is
//! decorative. Third, the restart: the same seed rebound on a fresh port is
//! reached through the recorded designator with only the hint updated, and the
//! recorded and fresh locators are equal under `model.peerLocatorsEqual` — the
//! designator is the identity, not the address, and the port change is what
//! proves it.

const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const frame_cap = 4096;

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = "hello from the keyed listener" };
    }
};

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

    var cv = driver.acceptVia(allocator, listener, &peer, .{ .keyed = secret }, read_buf, write_buf, 0) catch |err| switch (err) {
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
    var resident = net.tcp_keyed.Resident{
        .io = io,
        // The dialer does not listen; its resident key is unused on the dial
        // path, so any value works. Use the expected partner key for shape.
        .public_key = crypto.PeerKey.fromDesignator(expect_designator).?,
    };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectVia(allocator, &netlayers, &peer, locator, .ephemeral, read_buf, write_buf, 0);
    defer cv.deinit();

    // The knot: the partner's signed designator is the key that was dialed,
    // and the handshake pin already verified the session key equals it.
    const partner = peer.session_state.partnerDesignator() orelse return error.NoPartnerDesignator;
    try std.testing.expectEqualStrings(expect_designator, partner);

    const greeter = try cv.fetch("greeter");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "pancake" }} }, arena_state.allocator());
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
    resident: *net.tcp_keyed.Resident,
    secret: crypto.SecretKey,
    dial_designator: []const u8,
    hint_out: []u8,
) !void {
    var listener = try resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer listener.close();

    // The bound host:port is the dial hint; the designator stays the key.
    const hint = listener.localHint(hint_out);
    try std.testing.expect(hint.len != 0);

    const hint_entries = [_]model.HintEntry{.{
        .name = net.netlayer.hint_direct_addresses,
        .value = .{ .string = hint },
    }};
    const locator: model.PeerLocator = .{
        .transport = net.tcp_keyed.transport_name,
        .designator = dial_designator,
        .hints = .{ .entries = &hint_entries },
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

    const secret = crypto.SecretKey.fromSeed([_]u8{0x71} ** crypto.SEED_BYTES);
    const designator = secret.publicKey().toDesignator();
    var resident = net.tcp_keyed.Resident{ .io = io, .public_key = secret.publicKey() };

    var hint_buf: [net.tcp.designator_buf_len]u8 = undefined;
    try serveAndDial(io, allocator, &resident, secret, designator[0..], &hint_buf);

    // The contract listener also reports the key as its designator (what a
    // `driver.Server.localDesignator` hands an application to publish).
    var listener = try resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer listener.close();
    var designator_buf: [crypto.PeerKey.designator_len]u8 = undefined;
    try std.testing.expectEqualStrings(designator[0..], listener.localDesignator(&designator_buf));
}

test "keyed-tcp negative: a listener holding a different key under the dialed designator is refused with PartnerKeyMismatch" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const honest = crypto.SecretKey.fromSeed([_]u8{0x72} ** crypto.SEED_BYTES);
    const squatter = crypto.SecretKey.fromSeed([_]u8{0x73} ** crypto.SEED_BYTES);
    const dialed_designator = honest.publicKey().toDesignator();

    // The squatter answers the socket the hint names, holding a different key.
    var resident = net.tcp_keyed.Resident{ .io = io, .public_key = squatter.publicKey() };
    var listener = try resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    defer listener.close();
    var hint_buf: [net.tcp.designator_buf_len]u8 = undefined;
    const hint = listener.localHint(&hint_buf);

    const hint_entries = [_]model.HintEntry{.{
        .name = net.netlayer.hint_direct_addresses,
        .value = .{ .string = hint },
    }};
    const locator: model.PeerLocator = .{
        .transport = net.tcp_keyed.transport_name,
        .designator = dialed_designator[0..],
        .hints = .{ .entries = &hint_entries },
    };

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator, squatter });

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var dial_resident = net.tcp_keyed.Resident{ .io = io, .public_key = honest.publicKey() };
    const netlayers = [_]net.netlayer.Netlayer{dial_resident.netlayer()};
    // The engine refuses with `PartnerKeyMismatch`; the connection pump folds
    // every protocol refusal into its `ProtocolAbort` family and keeps the
    // typed member readable on the peer (`AbortInfo`).
    try std.testing.expectError(
        error.ProtocolAbort,
        driver.connectVia(allocator, &netlayers, &peer, locator, .ephemeral, read_buf, write_buf, 0),
    );
    const abort = peer.lastAbort() orelse return error.NoAbortRecorded;
    try std.testing.expectEqualStrings("PartnerKeyMismatch", abort.error_name);
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
        .transport = net.tcp_keyed.transport_name,
        .designator = recorded_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };

    var resident = net.tcp_keyed.Resident{ .io = io, .public_key = secret.publicKey() };

    // First life: bind on port 0, serve one client through the key designator,
    // and record only the designator (the hint is per-life connection advice).
    var first_listener = try resident.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    var first_hint_buf: [net.tcp.designator_buf_len]u8 = undefined;
    const first_hint = first_listener.localHint(&first_hint_buf);
    {
        const hint_entries = [_]model.HintEntry{.{
            .name = net.netlayer.hint_direct_addresses,
            .value = .{ .string = first_hint },
        }};
        const locator: model.PeerLocator = .{
            .transport = net.tcp_keyed.transport_name,
            .designator = recorded_designator[0..],
            .hints = .{ .entries = &hint_entries },
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
    var second_life = net.tcp_keyed.Resident{ .io = io, .public_key = rebuilt.publicKey() };
    var second_listener = try second_life.netlayer().listen(allocator, .{ .designator = "127.0.0.1:0" });
    var second_hint_buf: [net.tcp.designator_buf_len]u8 = undefined;
    const second_hint = second_listener.localHint(&second_hint_buf);
    try std.testing.expect(!std.mem.eql(u8, first_hint, second_hint));
    first_listener.close();
    {
        const hint_entries = [_]model.HintEntry{.{
            .name = net.netlayer.hint_direct_addresses,
            .value = .{ .string = second_hint },
        }};
        // Re-dial the locator recorded before the restart: same designator,
        // only the hint updated.
        const locator: model.PeerLocator = .{
            .transport = net.tcp_keyed.transport_name,
            .designator = recorded_designator[0..],
            .hints = .{ .entries = &hint_entries },
        };
        var host_future = try io.concurrent(hostOnce, .{ second_listener, allocator, rebuilt });
        const client_result = callKeyed(io, allocator, locator, recorded_designator[0..]);
        const host_result = host_future.await(io);
        try client_result;
        try host_result;
    }
    second_listener.close();

    // The locator a partner recorded before the restart names the same peer
    // as the one it dialed after it: hints are connection advice, never
    // identity (`model.peerLocatorsEqual` compares transport + designator).
    const fresh_designator = rebuilt.publicKey().toDesignator();
    const fresh_locator: model.PeerLocator = .{
        .transport = net.tcp_keyed.transport_name,
        .designator = fresh_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try std.testing.expect(model.peerLocatorsEqual(recorded_locator, fresh_locator));
}
