//! Noise TCP designator grammar: the `noise-tcp` locator's two halves.
//!
//! A `noise-tcp` locator names *who* in the designator (an Ed25519 key in
//! canonical lowercase hex) and *where* in the `direct-addresses` hint (a
//! `host:port`), the `keyed-tcp` grammar exactly, under the symbol that
//! seals the wire (ADR-0107). These units pin the grammar's edges without a
//! socket: the dial refusals that fire before any I/O (a non-key designator,
//! a hint-less dial, a malformed hint), and the listener whose designator is
//! the identity key. The sealed channel itself is the core Host's and is
//! proved in `test/driver/sealed_channel_test.zig`. The live loopback
//! session is `test/driver/noise_tcp_live_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../support/netlayer.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;

test "noise-tcp shares the keyed grammar and the sealed predicate covers both symbols" {
    try std.testing.expectEqual(model.transport.DesignatorScheme.key, model.transport.Known.noise_tcp.metadata().designator_scheme);
    try std.testing.expect(model.transport.Known.noise_tcp.metadata().sealed_channel);
    try std.testing.expect(model.transport.Known.noise_relay.metadata().sealed_channel);
    try std.testing.expect(!model.transport.Known.keyed_tcp.metadata().sealed_channel);
    try std.testing.expect(!std.mem.eql(u8, net.tcp.noise.transport_name, net.tcp.keyed.transport_name));
}

test "noise-tcp dial refuses a non-key designator and a hint-less key designator before any I/O" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x6e)));
    var resident = net.tcp.noise.Resident{ .io = io };
    const nl = resident.netlayer();
    try std.testing.expectEqual(net.netlayer.DesignatorScheme.key, nl.designatorScheme());

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    const bufs: net.netlayer.Buffers = .{ .read = &read_buf, .write = &write_buf };

    // A host:port in the designator is the *plain tcp* grammar, not this one.
    try std.testing.expectError(error.InvalidAddress, nl.dial(&peer, .{
        .transport = net.tcp.noise.transport_name,
        .designator = "127.0.0.1:9999",
        .hints = model.Hints.emptyFalse(),
    }, bufs, .inherit));

    // A canonical key with no direct-addresses hint has nowhere to dial:
    // refused loud instead of timing out (TCP has no discovery).
    const designator = secret.publicKey().toDesignator();
    try std.testing.expectError(error.InvalidAddress, nl.dial(&peer, .{
        .transport = net.tcp.noise.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    }, bufs, .inherit));

    // A malformed hint value (the address grammar is tcp's) also refuses.
    const bad_hint = [_]model.HintEntry{.{
        .name = net.netlayer.hint_direct_addresses,
        .value = .{ .string = "not-an-address" },
    }};
    try std.testing.expectError(error.InvalidAddress, nl.dial(&peer, .{
        .transport = net.tcp.noise.transport_name,
        .designator = designator[0..],
        .hints = .{ .entries = &bad_hint },
    }, bufs, .inherit));
}

fn waitUntilNoiseListenerClose(listener: net.netlayer.Listener) anyerror!void {
    try std.testing.expectError(error.ConnectionLost, listener.waitAcceptable(-1));
}

test "noise-tcp listener designator is the identity key, and close wakes a blocked wait" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x6f)));
    var resident = net.tcp.noise.Resident{ .io = io };
    const listener = try netlayer_test.listenBlocking(resident.netlayer(), allocator, .{
        .designator = "127.0.0.1:0",
        .identity = secret.publicKey(),
    });

    // The complete locator keeps the identity designator and socket hint
    // together under the transport that owns their meaning.
    const locator = try listener.localLocator(allocator);
    defer model.freePeerLocator(allocator, locator);
    try std.testing.expectEqualStrings(net.tcp.noise.transport_name, locator.transport);
    try std.testing.expectEqualStrings(&secret.publicKey().toDesignator(), locator.designator);
    const addr = net.netlayer.directAddrHint(locator.hints) orelse return error.MissingDirectAddresses;
    try std.testing.expect(std.mem.indexOfScalar(u8, addr, ':') != null);

    var waiter = try io.concurrent(waitUntilNoiseListenerClose, .{listener});
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    netlayer_test.close(listener);
    try waiter.await(io);
}
