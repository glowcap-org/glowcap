//! Restart-stable TCP listening identity: the `keyed-tcp` loopback test
//! (ADR-0075).
//!
//! Three scenes over real 127.0.0.1 sockets. First, the happy path: a server
//! keyed from a fixed seed accepts under its key designator, and a client
//! dialing that designator (bound address riding the `direct-addresses` hint)
//! sees the partner's signed designator equal the key and a call round-trip.
//! Second, the load-bearing negative: a server holding a *different* key at
//! the same kind of address, dialed under the original designator, is refused
//! at the handshake. A keyed server signs the designator its own key
//! spells, so a squatter advertises its own identity rather than the dialed
//! one and the target check refuses it before the session opens (the typed
//! member, `PartnerDesignatorMismatch`, is pinned at the core in
//! `test/driver/core_host/admission_test.zig`). This is not authentication:
//! an untrusted cleartext peer can repeat the dialed designator. Third, the
//! restart: the same seed rebound on a fresh port is reached through the
//! recorded designator with only the hint updated, and the recorded and
//! fresh locators are equal under `model.peerLocatorsEqual`. The designator
//! is the identity, not the address, and the port change is what proves it.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../support/actors.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;

const frame_cap = 4096;

/// Finite budgets: a partner that goes quiet fails the suite instead of
/// parking it.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

/// The published actor: answers `greet` with a static greeting.
const Greeter = support_actors.StaticReplyValueActor("greet", "hello from the keyed listener");

/// Bind a keyed server on an ephemeral loopback port, signing with `secret`,
/// whose public key's hex is the server's designator.
fn listenKeyed(allocator: std.mem.Allocator, io: std.Io, secret: crypto.SecretKey) !*driver.Server {
    return driver.listen(allocator, io, .{ .symbols = &.{.keyed_tcp} }, model.transport.keyed_tcp, .{ .designator = "127.0.0.1:0" }, .{ .keyed = secret }, dial_opts);
}

/// The server's advertised locator, with its designator and direct-address
/// hint copied into caller-owned buffers so they outlive the accept.
const Advertised = struct {
    designator_buf: [crypto.PeerKey.designator_len]u8 = undefined,
    designator_len: usize = 0,
    hint_buf: [64]u8 = undefined,
    hint_len: usize = 0,

    fn of(server: *driver.Server) !Advertised {
        const advertised = try server.advertisedLocator();
        var self = Advertised{};
        @memcpy(self.designator_buf[0..advertised.designator.len], advertised.designator);
        self.designator_len = advertised.designator.len;
        const direct = net.netlayer.directAddrHint(advertised.hints) orelse return error.MissingDirectAddresses;
        @memcpy(self.hint_buf[0..direct.len], direct);
        self.hint_len = direct.len;
        return self;
    }

    fn designator(self: *const Advertised) []const u8 {
        return self.designator_buf[0..self.designator_len];
    }

    fn hint(self: *const Advertised) []const u8 {
        return self.hint_buf[0..self.hint_len];
    }
};

/// Accept one partner on the keyed server, publish the greeter, serve until
/// the client leaves, cleanly or by dropping the socket after its refused
/// handshake, which arrives here as an ordinary connection loss.
fn hostOnce(server: *driver.Server) anyerror!void {
    var session = server.accept() catch |err| switch (err) {
        // A pinned dialer that refuses our key drops the socket mid-handshake;
        // that is this vat's whole (expected) conversation in the negative arm.
        error.ConnectionLost, error.TruncatedFrame, driver.Error.ConnectionClosed => return,
        else => return err,
    };
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

/// Dial `designator` through the keyed-tcp symbol with `hint` as the direct
/// address, fetch the greeter, call it, and assert the partner's signed
/// designator is exactly `expect_designator`.
fn callKeyed(
    io: std.Io,
    allocator: std.mem.Allocator,
    designator: []const u8,
    hint: []const u8,
    expect_designator: []const u8,
) !void {
    var entries: [1]model.HintEntry = undefined;
    const locator: model.PeerLocator = .{
        .transport = model.transport.keyed_tcp,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses(hint, &entries),
    };
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.keyed_tcp} }, locator, .ephemeral, dial_opts);
    defer session.deinit();

    // The knot: the partner's signed designator is the key that was dialed,
    // and the handshake pin already verified the session key equals it.
    const partner = try session.partnerIdentity();
    try std.testing.expectEqualStrings(expect_designator, partner.designator);

    const greeter = try session.fetch("greeter");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try session.call(greeter, "greet", &.{.{ .string = "glowcap" }}, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("hello from the keyed listener", arg.string);
        },
        .broken => return error.CallBroke,
    }
}

/// Run one hosted accept on `server` and dial it under `dial_designator`
/// with the server's own direct-address hint, returning the client's result.
fn serveAndDial(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *driver.Server,
    dial_designator: []const u8,
) !void {
    const advertised = try Advertised.of(server);

    var host_future = try io.concurrent(hostOnce, .{server});
    const client_result = callKeyed(io, allocator, dial_designator, advertised.hint(), dial_designator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "keyed-tcp loopback: the dialed key designator is the partner's signed identity and the call round-trips" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x71)));
    const designator = secret.publicKey().toDesignator();

    var server = try listenKeyed(allocator, io, secret);
    defer server.deinit();

    // The server reports the key as its designator: what
    // `driver.Server.localDesignator` hands an application to publish.
    var local_buf: [crypto.PeerKey.designator_len]u8 = undefined;
    try std.testing.expectEqualStrings(designator[0..], try server.localDesignator(&local_buf));

    try serveAndDial(io, allocator, server, designator[0..]);
}

test "keyed-tcp negative: a listener claiming a different key than the dialed designator is refused" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const honest = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x72)));
    const squatter = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x73)));
    const dialed_designator = honest.publicKey().toDesignator();

    // The squatter answers the socket the hint names, holding a different key.
    var server = try listenKeyed(allocator, io, squatter);
    defer server.deinit();
    const advertised = try Advertised.of(server);
    var entries: [1]model.HintEntry = undefined;
    const locator: model.PeerLocator = .{
        .transport = model.transport.keyed_tcp,
        .designator = dialed_designator[0..],
        .hints = model.Hints.forDirectAddresses(advertised.hint(), &entries),
    };

    var host_future = try io.concurrent(hostOnce, .{server});

    // The squatter's hello advertises the identity its own key spells, not
    // the one this dial named, so the claim check refuses it before the
    // session opens. The handshake pump folds every protocol refusal into
    // its `ProtocolAbort` family, and `driver.connect` releases the refused
    // session with its wire, so nothing opens for the caller to read.
    try std.testing.expectError(
        error.ProtocolAbort,
        driver.connect(allocator, io, .{ .symbols = &.{.keyed_tcp} }, locator, .ephemeral, dial_opts),
    );

    const host_result = host_future.await(io);
    try host_result;
}

test "keyed-tcp restart: the same seed on a fresh port is reachable through the recorded designator with only the hint updated" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const seed: [crypto.seed_bytes]u8 = @splat(0x74);
    const secret = crypto.SecretKey.fromSeed(seed);
    const recorded_designator = secret.publicKey().toDesignator();
    const recorded_locator: model.PeerLocator = .{
        .transport = model.transport.keyed_tcp,
        .designator = recorded_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };

    // First life: bind on port 0, serve one client through the key designator,
    // and record only the designator (the hint is per-life connection advice).
    var first = try listenKeyed(allocator, io, secret);
    var first_live = true;
    defer if (first_live) first.deinit();
    const first_advertised = try Advertised.of(first);
    try serveAndDial(io, allocator, first, recorded_designator[0..]);

    // Restart: the same seed rebuilds the same key on a fresh kernel-chosen
    // port. The first server stays bound while the second binds, so the
    // kernel cannot hand back the same port, the port change is the proof
    // that the designator is the identity, not the address.
    const rebuilt = crypto.SecretKey.fromSeed(seed);
    var second = try listenKeyed(allocator, io, rebuilt);
    defer second.deinit();
    const second_advertised = try Advertised.of(second);
    try std.testing.expect(!std.mem.eql(u8, first_advertised.hint(), second_advertised.hint()));
    first.deinit();
    first_live = false;

    // Re-dial the locator recorded before the restart: same designator,
    // only the hint updated.
    try serveAndDial(io, allocator, second, recorded_designator[0..]);

    // The locator a partner recorded before the restart names the same peer
    // as the one it dialed after it: hints are connection advice, never
    // identity (`model.peerLocatorsEqual` compares transport + designator).
    const fresh_designator = rebuilt.publicKey().toDesignator();
    const fresh_locator: model.PeerLocator = .{
        .transport = model.transport.keyed_tcp,
        .designator = fresh_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try std.testing.expect(model.peerLocatorsEqual(recorded_locator, fresh_locator));
}
