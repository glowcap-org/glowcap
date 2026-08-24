//! The `noise-tcp` netlayer end to end over real 127.0.0.1 sockets
//! (ADR-0107): a keyed listener on the owning face accepts
//! a sealed session, a client dials the listener's key designator, the
//! Noise_XK handshake completes inside the ordinary handshake pump, and both
//! legs report `authenticated_transport` with no embedder testimony anywhere
//! — the channel itself is the realizer. A fetch and a call round-trip
//! through the sealed records prove CapTP is untouched above the channel.
//!
//! The negative half is the tier boundary: the borrowing `BlockingSession`
//! tier stands on no core Host, so nothing there would seal the wire, and
//! both of its constructors refuse the symbol outright.

const std = @import("std");
const pancake = @import("pancake");
const netlayer_test = @import("../support/netlayer.zig");
const support_actors = @import("../support/actors.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const driver = pancake.driver;
const net = pancake.net;

const frame_cap = 4096;

const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const Greeter = support_actors.StaticReplyValueActor("greet", "hello through the sealed channel");

/// Accept one partner, assert the sealed channel proved the client's durable
/// key, publish the greeter, and serve until the client leaves.
fn hostOnce(server: *driver.Server) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    const identity = try session.runtime.core.partnerIdentity(session.hs);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, identity.provenance);
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

test "noise-tcp: a sealed session opens over loopback and both legs hold the channel proof" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server_secret = try driver.drawSessionSecret(io);
    var resident = net.tcp.noise.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .{ .keyed = server_secret },
        dial_opts,
    );
    defer server.deinit();

    // The dial locator, copied off the advertised one before the accept task
    // starts: the key designator says who, the hint says where.
    const advertised = try server.advertisedLocator();
    var designator_buf: [crypto.PeerKey.designator_len]u8 = undefined;
    @memcpy(designator_buf[0..advertised.designator.len], advertised.designator);
    const designator = designator_buf[0..advertised.designator.len];
    var hint_buf: [64]u8 = undefined;
    const advertised_hint = net.netlayer.directAddrHint(advertised.hints) orelse return error.MissingBoundAddress;
    @memcpy(hint_buf[0..advertised_hint.len], advertised_hint);
    const hint = hint_buf[0..advertised_hint.len];
    try std.testing.expectEqualStrings(&server_secret.publicKey().toDesignator(), designator);

    var host_future = try io.concurrent(hostOnce, .{server});
    const client_result = clientAsserts(allocator, io, designator, hint);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

fn clientAsserts(allocator: std.mem.Allocator, io: std.Io, designator: []const u8, hint: []const u8) !void {
    var resident = net.tcp.noise.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};
    var entries: [1]model.HintEntry = undefined;
    const locator: model.PeerLocator = .{
        .transport = model.transport.noise_tcp,
        .designator = designator,
        .hints = model.Hints.forDirectAddresses(hint, &entries),
    };
    const client = try driver.connect(allocator, &netlayers, locator, .ephemeral, dial_opts);
    defer client.deinit();

    // The dialing leg's proof comes from its own completed handshake.
    const identity = try client.runtime.core.partnerIdentity(client.hs);
    try std.testing.expectEqual(driver.core.DurableProvenance.authenticated_transport, identity.provenance);
    try std.testing.expect(identity.durableIdentityAuthenticated());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const greeter = try client.fetch("greeter");
    const settled = try client.call(greeter, "greet", &.{}, arena.allocator());
    try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
    try std.testing.expectEqualStrings("hello through the sealed channel", settled.fulfilled.string);
}

test "noise-tcp: the borrowing blocking tier refuses the sealed symbol on both halves" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x70)));
    var resident = net.tcp.noise.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    const designator = secret.publicKey().toDesignator();
    var entries: [1]model.HintEntry = undefined;
    try std.testing.expectError(driver.Error.SealedChannelRequiresHost, driver.connectVia(
        allocator,
        &netlayers,
        &peer,
        .{
            .transport = model.transport.noise_tcp,
            .designator = designator[0..],
            .hints = model.Hints.forDirectAddresses("127.0.0.1:1", &entries),
        },
        .ephemeral,
        &read_buf,
        &write_buf,
        .{ .handshake = .{ .ms = 1_000 }, .settle = .{ .ms = 1_000 } },
    ));

    const listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = secret.publicKey(),
    });
    defer netlayer_test.close(listener);
    try std.testing.expectError(driver.Error.SealedChannelRequiresHost, driver.acceptVia(
        allocator,
        listener,
        &peer,
        .{ .keyed = secret },
        &read_buf,
        &write_buf,
        .{ .handshake = .{ .ms = 1_000 }, .settle = .{ .ms = 1_000 } },
    ));
}
