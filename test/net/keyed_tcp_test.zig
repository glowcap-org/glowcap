//! Keyed TCP designator grammar: the `keyed-tcp` locator's two halves.
//!
//! A `keyed-tcp` locator names *who* in the designator (an Ed25519 key in
//! canonical lowercase hex) and *where* in the `direct-addresses` hint (a
//! `host:port`). These units pin the grammar's edges without a socket: the one
//! canonical key spelling (`foundation.crypto.PeerKey`'s
//! `toDesignator`/`fromDesignator`), and the dial refusals that fire before
//! any I/O: a non-key designator, and a hint-less dial (TCP has no
//! discovery). The full restart-stable loopback test lives in
//! `test/driver/keyed_tcp_restart_test.zig`.

const std = @import("std");
const pancake = @import("pancake");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const net = pancake.net;

test "toDesignator/fromDesignator round-trip byte-for-byte" {
    const secret = crypto.SecretKey.fromSeed([_]u8{0x5a} ** crypto.SEED_BYTES);
    const key = secret.publicKey();
    const designator = key.toDesignator();
    try std.testing.expectEqual(crypto.PeerKey.designator_len, designator.len);
    const parsed = crypto.PeerKey.fromDesignator(designator[0..]) orelse return error.RoundTripRefused;
    try std.testing.expect(parsed.eql(key));
}

test "fromDesignator is strict: length, case, and non-hex are all refused" {
    const key = crypto.SecretKey.fromSeed([_]u8{0x5b} ** crypto.SEED_BYTES).publicKey();
    var designator = key.toDesignator();

    // Wrong length: one short, one long, empty.
    try std.testing.expect(crypto.PeerKey.fromDesignator(designator[0 .. designator.len - 1]) == null);
    var long: [crypto.PeerKey.designator_len + 1]u8 = undefined;
    @memcpy(long[0..designator.len], designator[0..]);
    long[designator.len] = '0';
    try std.testing.expect(crypto.PeerKey.fromDesignator(long[0..]) == null);
    try std.testing.expect(crypto.PeerKey.fromDesignator("") == null);

    // Uppercase hex is a second spelling of the same key, refused so a key
    // has exactly one designator.
    var upper = designator;
    for (&upper) |*c| c.* = std.ascii.toUpper(c.*);
    try std.testing.expect(!std.mem.eql(u8, upper[0..], designator[0..]));
    try std.testing.expect(crypto.PeerKey.fromDesignator(upper[0..]) == null);

    // A non-hex character anywhere refuses.
    designator[17] = 'g';
    try std.testing.expect(crypto.PeerKey.fromDesignator(designator[0..]) == null);
}

test "keyed-tcp dial refuses a non-key designator and a hint-less key designator before any I/O" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed([_]u8{0x5c} ** crypto.SEED_BYTES);
    var resident = net.tcp.keyed.Resident{ .io = io };
    const nl = resident.netlayer();
    try std.testing.expectEqual(net.netlayer.DesignatorScheme.key, nl.designatorScheme());

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    const bufs: net.netlayer.Buffers = .{ .read = &read_buf, .write = &write_buf };

    // A host:port in the designator is the *plain tcp* grammar, not this one.
    try std.testing.expectError(error.InvalidAddress, nl.dial(&peer, .{
        .transport = net.tcp.keyed.transport_name,
        .designator = "127.0.0.1:9999",
        .hints = model.Hints.emptyFalse(),
    }, bufs));

    // A canonical key with no direct-addresses hint has nowhere to dial:
    // refused loud instead of timing out (TCP has no discovery).
    const designator = secret.publicKey().toDesignator();
    try std.testing.expectError(error.InvalidAddress, nl.dial(&peer, .{
        .transport = net.tcp.keyed.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    }, bufs));

    // A malformed hint value (the address grammar is tcp's) also refuses.
    const bad_hint = [_]model.HintEntry{.{
        .name = net.netlayer.hint_direct_addresses,
        .value = .{ .string = "not-an-address" },
    }};
    try std.testing.expectError(error.InvalidAddress, nl.dial(&peer, .{
        .transport = net.tcp.keyed.transport_name,
        .designator = designator[0..],
        .hints = .{ .entries = &bad_hint },
    }, bufs));
}

test "plain tcp designator grammar is untouched by the keyed sibling" {
    // The two postures dispatch by transport symbol, so the plain resident
    // still parses host:port designators and knows nothing of keys.
    const address = try net.tcp.parseDesignator("127.0.0.1:9000");
    try std.testing.expectEqual(@as(u16, 9000), address.getPort());
    try std.testing.expect(!std.mem.eql(u8, net.tcp.plain.transport_name, net.tcp.keyed.transport_name));
}

fn waitUntilKeyedListenerClose(listener: net.netlayer.Listener) anyerror!void {
    try std.testing.expectError(error.ConnectionLost, listener.waitAcceptable(-1));
}

test "keyed-tcp listener close wakes and joins a blocked readiness wait" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const secret = crypto.SecretKey.fromSeed([_]u8{0x5d} ** crypto.SEED_BYTES);
    var resident = net.tcp.keyed.Resident{ .io = io };
    const listener = try resident.netlayer().listen(allocator, .{
        .designator = "127.0.0.1:0",
        .identity = secret.publicKey(),
    });
    var waiter = try io.concurrent(waitUntilKeyedListenerClose, .{listener});
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    listener.close();
    try waiter.await(io);
}
