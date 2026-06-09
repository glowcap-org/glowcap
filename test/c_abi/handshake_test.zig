//! Keyed handshake over the C ABI — proves a binding can drive the keyed
//! `op:start-session` exchange that a peer requiring the handshake (a real
//! Goblins vat) expects, using only the C functions: a negotiating peer, a
//! signed start-session built from a 32-byte seed, and the session-open accessor.

const std = @import("std");
const pancake = @import("pancake");

const c = pancake.c_abi;

fn drainInto(from: ?*c.PancakePeer, to: ?*c.PancakePeer) !void {
    while (true) {
        var frame: c.PancakeManagedFrame = undefined;
        const rc = c.pancake_peer_take_outbound(from, &frame);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try std.testing.expectEqual(c.PANCAKE_OK, rc);
        const borrowed = c.PancakeFrame{ .bytes = frame.bytes, .len = frame.len, .shape = frame.shape };
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_feed_borrowed(to, &borrowed));
        c.pancake_managed_frame_release(&frame);
    }
}

test "C ABI keyed start-session drives two negotiating peers to an open session" {
    var dialer: ?*c.PancakePeer = null;
    var listener: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiating(&dialer));
    defer c.pancake_peer_release(dialer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiating(&listener));
    defer c.pancake_peer_release(listener);

    // Each side signs its own keyed start-session over a `tcp`/`#f`-hints locator
    // — the same shape a live Goblins partner verifies — from a 32-byte seed.
    const transport = "tcp";
    const dialer_loc = "127.0.0.1:1";
    const listener_loc = "127.0.0.1:2";
    const dialer_seed = [_]u8{0x11} ** 32;
    const listener_seed = [_]u8{0x22} ** 32;

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session_keyed(
        dialer,
        0, // v1.0
        transport,
        transport.len,
        dialer_loc,
        dialer_loc.len,
        1, // hints encode as `#f`
        &dialer_seed,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session_keyed(
        listener,
        0,
        transport,
        transport.len,
        listener_loc,
        listener_loc.len,
        1,
        &listener_seed,
    ));

    try std.testing.expectEqual(@as(i32, 0), c.pancake_peer_session_is_open(dialer));

    // Shuttle the handshake frames between the two C-ABI peers until both open.
    var i: usize = 0;
    while (i < 8 and !(c.pancake_peer_session_is_open(dialer) == 1 and
        c.pancake_peer_session_is_open(listener) == 1)) : (i += 1)
    {
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(dialer));
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(listener));
        try drainInto(dialer, listener);
        try drainInto(listener, dialer);
    }

    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(dialer));
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(listener));
}

test "C ABI keyed start-session rejects an unknown captp version" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiating(&peer));
    defer c.pancake_peer_release(peer);

    const transport = "tcp";
    const loc = "127.0.0.1:1";
    const seed = [_]u8{0x33} ** 32;
    // Version 2 is neither v1.0 (0) nor pre-spec (1).
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_peer_start_session_keyed(
        peer,
        2,
        transport,
        transport.len,
        loc,
        loc.len,
        1,
        &seed,
    ));
}
