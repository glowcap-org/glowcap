//! Keyed handshake over the C ABI — proves a binding can drive the keyed
//! `op:start-session` exchange that a peer requiring the handshake (a real
//! Goblins vat) expects, using only the C functions: a negotiating peer, a
//! signed start-session built from a 32-byte seed, and the session-open accessor.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

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

test "C ABI session-is-open is a pure predicate: a NULL peer reports 0, never an error code" {
    try std.testing.expectEqual(@as(i32, 0), c.pancake_peer_session_is_open(null));
}

test "C ABI default peer constructor starts in negotiating state" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&peer));
    defer c.pancake_peer_release(peer);

    try std.testing.expectEqual(@as(i32, 0), c.pancake_peer_session_is_open(peer));
}

test "C ABI raw-open constructor is explicit fixture surface" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(peer));
}

test "C ABI context raw-open constructor is explicit fixture surface" {
    var context: ?*c.PancakeContext = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open_in(context, &peer));
    defer c.pancake_peer_release(peer);

    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(peer));
}

test "C ABI keyed start-session drives two negotiating peers to an open session" {
    var dialer: ?*c.PancakePeer = null;
    var listener: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&dialer));
    defer c.pancake_peer_release(dialer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&listener));
    defer c.pancake_peer_release(listener);

    // Each side signs its own keyed start-session over a `tcp`/`#f`-hints locator
    // — the same shape a live Goblins partner verifies — from a 32-byte seed.
    const transport = "tcp";
    const dialer_loc = "127.0.0.1:1";
    const listener_loc = "127.0.0.1:2";
    const dialer_seed = [_]u8{0x11} ** 32;
    const listener_seed = [_]u8{0x22} ** 32;

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(
        dialer,
        transport,
        transport.len,
        dialer_loc,
        dialer_loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &dialer_seed,
        dialer_seed.len,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(
        listener,
        transport,
        transport.len,
        listener_loc,
        listener_loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &listener_seed,
        listener_seed.len,
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

test "C ABI negotiated constructor drives PreSpec keyed peers to an open session" {
    var dialer: ?*c.PancakePeer = null;
    var listener: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiated(c.PANCAKE_CAPTP_VERSION_PRE_SPEC, c.PANCAKE_CODEC_SYRUP, &dialer));
    defer c.pancake_peer_release(dialer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiated(c.PANCAKE_CAPTP_VERSION_PRE_SPEC, c.PANCAKE_CODEC_SYRUP, &listener));
    defer c.pancake_peer_release(listener);

    const transport = "tcp";
    const dialer_loc = "127.0.0.1:11";
    const listener_loc = "127.0.0.1:12";
    const dialer_seed = [_]u8{0x44} ** 32;
    const listener_seed = [_]u8{0x55} ** 32;

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(
        dialer,
        transport,
        transport.len,
        dialer_loc,
        dialer_loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &dialer_seed,
        dialer_seed.len,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(
        listener,
        transport,
        transport.len,
        listener_loc,
        listener_loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &listener_seed,
        listener_seed.len,
    ));

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

test "C ABI negotiated constructor drives Cap'n Proto keyed peers to an open session" {
    var dialer: ?*c.PancakePeer = null;
    var listener: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiated(c.PANCAKE_CAPTP_VERSION_V1_0, c.PANCAKE_CODEC_CAPNP, &dialer));
    defer c.pancake_peer_release(dialer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_negotiated(c.PANCAKE_CAPTP_VERSION_V1_0, c.PANCAKE_CODEC_CAPNP, &listener));
    defer c.pancake_peer_release(listener);

    const transport = "tcp";
    const dialer_loc = "127.0.0.1:21";
    const listener_loc = "127.0.0.1:22";
    const dialer_seed = [_]u8{0x66} ** 32;
    const listener_seed = [_]u8{0x99} ** 32;

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(
        dialer,
        transport,
        transport.len,
        dialer_loc,
        dialer_loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &dialer_seed,
        dialer_seed.len,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(
        listener,
        transport,
        transport.len,
        listener_loc,
        listener_loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &listener_seed,
        listener_seed.len,
    ));

    // The handshake frames themselves ride the negotiated codec, so reaching
    // open proves the codec knob landed in the session, not just in a field.
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

    var codec: u32 = std.math.maxInt(u32);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_codec(dialer, &codec));
    try std.testing.expectEqual(c.PANCAKE_CODEC_CAPNP, codec);
}

test "C ABI negotiated constructor refuses a codec outside the PANCAKE_CODEC family" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_peer_new_negotiated(c.PANCAKE_CAPTP_VERSION_V1_0, 2, &peer));
    try std.testing.expectEqual(@as(?*c.PancakePeer, null), peer);
}

test "C ABI keyed start-session refuses a seed_len other than 32" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&peer));
    defer c.pancake_peer_release(peer);

    const transport = "tcp";
    const loc = "127.0.0.1:1";
    const seed = [_]u8{0x77} ** 32;
    // A 16-byte seed_len is refused before any of the seed bytes are read.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_peer_start_session(
        peer,
        transport,
        transport.len,
        loc,
        loc.len,
        c.PANCAKE_HINTS_EMPTY_FALSE,
        &seed,
        16,
    ));
}

test "C ABI keyed start-session refuses an unknown hints discriminant" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&peer));
    defer c.pancake_peer_release(peer);

    const transport = "tcp";
    const loc = "127.0.0.1:1";
    const seed = [_]u8{0x88} ** 32;
    // 2 is neither PANCAKE_HINTS_EMPTY_MAP (0) nor PANCAKE_HINTS_EMPTY_FALSE (1).
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_peer_start_session(
        peer,
        transport,
        transport.len,
        loc,
        loc.len,
        2,
        &seed,
        seed.len,
    ));
}
