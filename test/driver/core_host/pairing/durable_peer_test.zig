//! A proved durable peer keeps one session: an authenticated channel
//! collapses a crossed pair to one shared survivor over frame and byte-stream
//! delivery, and a reconnect supersedes the session the peer's ended run left
//! open.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const ParkedDial = harness.ParkedDial;
const pumpToQuiescence = harness.pumpToQuiescence;
const retireClosedSession = harness.retireClosedSession;

const CrossedPairProof = enum { none, authenticated_channel };
const Delivery = enum { frame, stream };
const CrossedPairOptions = struct {
    a_seed_byte: u8 = 0x01,
    a_dialed_first: bool = false,
    b_dialed_first: bool = false,
};

fn deliver(delivery: Delivery, host: *Host, session: *HostSession, frame: glowcap.foundation.FrameView) !void {
    switch (delivery) {
        .frame => try host.feed(session, frame),
        .stream => try feedStream(host, session, frame),
    }
}

/// Exercise the same fresh-key crossed pair with and without realizer proof.
/// Four distinct session keys make the durable-peer directory the only possible
/// cross-connection match. A bare key designator cannot populate it, while a
/// channel-authenticated durable key can.
fn expectFreshKeyCrossedPair(transport: []const u8, proof: CrossedPairProof, delivery: Delivery, options: CrossedPairOptions) !void {
    const allocator = std.testing.allocator;
    const a_seed = @as([32]u8, @splat(options.a_seed_byte));
    const b_seed = @as([32]u8, @splat(0xff));
    const a_opts = Host.Options.withFrameCap(frame_cap);
    const b_opts = Host.Options.withFrameCap(frame_cap);
    var a = test_host.init(allocator, a_seed, a_opts);
    defer a.deinit();
    var b = test_host.init(allocator, b_seed, b_opts);
    defer b.deinit();

    const a_designator = crypto.SecretKey.fromSeed(a_seed).publicKey().toDesignator();
    const b_designator = crypto.SecretKey.fromSeed(b_seed).publicKey().toDesignator();

    const a_direct: []const u8 = if (std.mem.eql(u8, transport, "keyed-tcp")) "127.0.0.1:9200" else &.{};
    const b_direct: []const u8 = if (std.mem.eql(u8, transport, "keyed-tcp")) "127.0.0.1:9201" else &.{};
    const a_accept = try publishAndOpenAccepted(&a, transport, a_designator[0..], a_direct);
    const b_accept = try publishAndOpenAccepted(&b, transport, b_designator[0..], b_direct);
    const a_dialed = try a.openDialedLocator(.{
        .transport = transport,
        .designator = b_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    const b_dialed = try b.openDialedLocator(.{
        .transport = transport,
        .designator = a_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });

    if (proof == .authenticated_channel) {
        try a.bindVerifiedChannelKey(a_accept, &b_designator);
        try a.bindVerifiedChannelKey(a_dialed, &b_designator);
        try b.bindVerifiedChannelKey(b_accept, &a_designator);
        try b.bindVerifiedChannelKey(b_dialed, &a_designator);
    }

    const ids = [_][32]u8{
        crypto.derivePublicIdentifier(a_accept.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(a_dialed.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(b_accept.sessionSecret().publicKey()).bytes,
        crypto.derivePublicIdentifier(b_dialed.sessionSecret().publicKey()).bytes,
    };
    for (ids, 0..) |left, i| {
        for (ids[i + 1 ..]) |right| try std.testing.expect(!std.mem.eql(u8, &left, &right));
    }

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    const Hello = struct { session: *HostSession, frame: glowcap.foundation.FrameView };
    const a_hellos = [_]Hello{
        .{ .session = a_accept, .frame = b_hello.view() },
        .{ .session = a_dialed, .frame = b_accept_hello.view() },
    };
    const b_hellos = [_]Hello{
        .{ .session = b_accept, .frame = a_hello.view() },
        .{ .session = b_dialed, .frame = a_accept_hello.view() },
    };
    for (0..2) |index| {
        const a_next = a_hellos[if (options.a_dialed_first) 1 - index else index];
        const b_next = b_hellos[if (options.b_dialed_first) 1 - index else index];
        try deliver(delivery, &a, a_next.session, a_next.frame);
        try deliver(delivery, &b, b_next.session, b_next.frame);
    }

    switch (proof) {
        .none => {
            try std.testing.expect(!a_accept.isTerminating() and !a_dialed.isTerminating());
            try std.testing.expect(!b_accept.isTerminating() and !b_dialed.isTerminating());
        },
        .authenticated_channel => {
            try std.testing.expect(a_accept.isTerminating() != a_dialed.isTerminating());
            try std.testing.expect(b_accept.isTerminating() != b_dialed.isTerminating());
            try std.testing.expectEqual(a_accept.isTerminating(), b_dialed.isTerminating());
            try std.testing.expectEqual(a_dialed.isTerminating(), b_accept.isTerminating());
            // The spec keeps the connection with the higher initiator's
            // session identifier, regardless of either hello's arrival order.
            const a_is_higher = std.mem.order(u8, &ids[1], &ids[3]) != .lt;
            try std.testing.expectEqual(a_is_higher, a_accept.isTerminating());
        },
    }

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
}

test "session identity: raw keyed transport cannot collapse crossed locator claims" {
    try expectFreshKeyCrossedPair("keyed-tcp", .none, .frame, .{});
}

test "session identity: authenticated channel collapses a crossed pair to one shared survivor" {
    try expectFreshKeyCrossedPair("iroh", .authenticated_channel, .frame, .{});
}

test "session identity: a crossed pair collapses over byte-stream delivery without an ingress error" {
    // The loser is condemned while its own hello dispatches, through the
    // byte-stream verb a socket or relay transport feeds.
    try expectFreshKeyCrossedPair("iroh", .authenticated_channel, .stream, .{});
}

/// Feed one frame the way a byte-stream transport delivers it, through the
/// envelope `feedBytes` unwraps (ADR-0012).
fn feedStream(host: *Host, session: *HostSession, frame: glowcap.foundation.FrameView) !void {
    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, frame.bytes.len);
    var stream: [frame_cap + stream_framing.prefix_buffer_bytes]u8 = undefined;
    @memcpy(stream[0..prefix.len], prefix);
    @memcpy(stream[prefix.len..][0..frame.bytes.len], frame.bytes);
    try host.feedBytes(session, stream[0 .. prefix.len + frame.bytes.len]);
}

test "session identity: a proved peer's reconnect supersedes the session its old incarnation left open" {
    // A peer that restarts under the same durable key dials again while the
    // session its ended run opened still looks live here. The peer opened
    // both, and a peer reuses a live session rather than dialing another, so
    // the directory retires the session the ended run left. Refusing the
    // newcomer would strand the reconnect until that session's transport
    // happened to close.
    const allocator = std.testing.allocator;
    const host_seed = @as([32]u8, @splat(0x21));
    const peer_seed = @as([32]u8, @splat(0x22));
    var host = test_host.init(allocator, host_seed, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const host_designator = crypto.SecretKey.fromSeed(host_seed).publicKey().toDesignator();
    const peer_designator = crypto.SecretKey.fromSeed(peer_seed).publicKey().toDesignator();
    const host_locator: model.PeerLocator = .{
        .transport = "iroh",
        .designator = host_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    const peer_locator: model.PeerLocator = .{
        .transport = "iroh",
        .designator = peer_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    var old_peer = test_host.init(allocator, peer_seed, Host.Options.withFrameCap(frame_cap));
    defer old_peer.deinit();
    try old_peer.setAdvertisedLocator(peer_locator);
    const old_accepted = try publishAndOpenAccepted(&host, "iroh", host_designator[0..], &.{});
    const old_dialed = try old_peer.openDialedLocator(host_locator);
    try host.bindVerifiedChannelKey(old_accepted, &peer_designator);
    try old_peer.bindVerifiedChannelKey(old_dialed, &host_designator);
    try pumpToQuiescence(allocator, &.{ &old_peer, &host }, &.{.{ .ah = &old_peer, .a = old_dialed, .bh = &host, .b = old_accepted }}, &dials);
    try std.testing.expect(old_accepted.sessionOpen());

    // The restart: the same durable identity, a fresh session key, and the
    // old session still open here.
    var new_peer = test_host.init(allocator, peer_seed, Host.Options.withFrameCap(frame_cap));
    defer new_peer.deinit();
    try new_peer.setAdvertisedLocator(peer_locator);
    const new_dialed = try new_peer.openDialedLocator(host_locator);
    const new_accepted = try host.openAcceptedAdvertised("iroh");
    try host.bindVerifiedChannelKey(new_accepted, &peer_designator);
    try new_peer.bindVerifiedChannelKey(new_dialed, &host_designator);

    var hello = (try new_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try feedStream(&host, new_accepted, hello.view());
    try std.testing.expect(old_accepted.isTerminating());
    try std.testing.expect(!new_accepted.isTerminating());
    try retireClosedSession(&host, old_accepted);

    // The reconnect completes, and the directory reaches the peer through it.
    try pumpToQuiescence(allocator, &.{ &new_peer, &host }, &.{.{ .ah = &new_peer, .a = new_dialed, .bh = &host, .b = new_accepted }}, &dials);
    try std.testing.expect(new_dialed.sessionOpen() and new_accepted.sessionOpen());
    try std.testing.expectEqual(new_accepted, (try host.liveSessionForDial("iroh", &peer_designator)).?);

    try old_peer.releaseSession(old_dialed);
    try new_peer.releaseSession(new_dialed);
    try host.releaseSession(new_accepted);
}

test "session identity: authenticated crossed pairs converge across fresh keys" {
    for ([_]Delivery{ .frame, .stream }) |delivery|
        for ([_]bool{ false, true }) |a_dialed_first|
            for ([_]bool{ false, true }) |b_dialed_first|
                for (2..18) |seed| {
                    try expectFreshKeyCrossedPair("iroh", .authenticated_channel, delivery, .{
                        .a_seed_byte = @intCast(seed),
                        .a_dialed_first = a_dialed_first,
                        .b_dialed_first = b_dialed_first,
                    });
                };
}
