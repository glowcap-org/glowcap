//! Keyed handshake over the C ABI, proves a binding can drive the keyed
//! `op:start-session` exchange that a peer requiring the handshake (a real
//! Goblins vat) expects, using only the C functions: a negotiating peer, a
//! signed start-session built from a 32-byte seed, and the session-open accessor.

const std = @import("std");
const pancake = @import("pancake");

const c = @import("c_abi");

fn argBytes(bytes: []const u8) c.PancakeArgument {
    var a = std.mem.zeroes(c.PancakeArgument);
    a.kind = c.PANCAKE_ARG_BYTES;
    a.bytes = bytes.ptr;
    a.bytes_len = bytes.len;
    return a;
}

fn farRef(import_position: u64) c.PancakeReference {
    return .{ .kind = c.PANCAKE_REF_FAR, .sub_kind = c.PANCAKE_REF_SUB_OBJECT, .id = import_position };
}

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

test "C ABI send_withdraw_gift queues a signed withdraw-gift to the exporter bootstrap" {
    const crypto = pancake.foundation.crypto;
    const engine = pancake.ocapn.engine;

    var recipient_peer: ?*c.PancakePeer = null;
    var exporter: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&recipient_peer));
    defer c.pancake_peer_release(recipient_peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&exporter));
    defer c.pancake_peer_release(exporter);

    const transport = "tcp";
    const recipient_loc = "127.0.0.1:1";
    const exporter_loc = "127.0.0.1:2";
    // The recipient signs both its session to the exporter AND its handoff-receive
    // with this one seed, the continuity a gift deposited under its key needs.
    const recipient_seed = [_]u8{0x11} ** 32;
    const exporter_seed = [_]u8{0x22} ** 32;

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(recipient_peer, transport, transport.len, recipient_loc, recipient_loc.len, c.PANCAKE_HINTS_EMPTY_FALSE, &recipient_seed, recipient_seed.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(exporter, transport, transport.len, exporter_loc, exporter_loc.len, c.PANCAKE_HINTS_EMPTY_FALSE, &exporter_seed, exporter_seed.len));

    var i: usize = 0;
    while (i < 8 and !(c.pancake_peer_session_is_open(recipient_peer) == 1 and
        c.pancake_peer_session_is_open(exporter) == 1)) : (i += 1)
    {
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_peer));
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(exporter));
        try drainInto(recipient_peer, exporter);
        try drainInto(exporter, recipient_peer);
    }
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(recipient_peer));

    // Drain any residual handshake frames so the take_outbound below returns the
    // withdraw and nothing earlier.
    while (true) {
        var resid: c.PancakeManagedFrame = undefined;
        const rc = c.pancake_peer_take_outbound(recipient_peer, &resid);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try std.testing.expectEqual(c.PANCAKE_OK, rc);
        c.pancake_managed_frame_release(&resid);
    }

    // Mint a genuine signed give, exactly what a gifter would have handed back:
    // it names the recipient's session key and points at the exporter's locator.
    const gifter_secret = crypto.SecretKey.fromSeed([_]u8{0x33} ** 32);
    const recipient_pub = crypto.SecretKey.fromSeed(recipient_seed).publicKey();
    const give = try engine.handoff_gifter.buildSignedGive(
        std.testing.allocator,
        gifter_secret,
        recipient_pub.asBytes(),
        exporter_loc,
        &([_]u8{0xcc} ** 32),
        &([_]u8{0x11} ** 32),
        &([_]u8{0x01} ** 32),
    );
    defer std.testing.allocator.free(give);

    // The recipient signs a handoff-receive and queues the withdraw to far obj 0.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_withdraw_gift(
        recipient_peer,
        give.ptr,
        give.len,
        &recipient_seed,
        recipient_seed.len,
        7777,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_peer));

    var out: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_take_outbound(recipient_peer, &out));
    defer c.pancake_managed_frame_release(&out);
    const wire = out.bytes.?[0..out.len];
    try std.testing.expect(std.mem.indexOf(u8, wire, "op:deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "withdraw-gift") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "desc:handoff-receive") != null);
    // The receive embeds the gifter's verbatim give certificate.
    try std.testing.expect(std.mem.indexOf(u8, wire, "desc:handoff-give") != null);
}

/// Drive two negotiating C-ABI peers through the keyed start-session exchange
/// from `seed_a`/`seed_b` over `tcp` locators until both report open.
fn openKeyedPair(
    a: ?*c.PancakePeer,
    a_loc: []const u8,
    seed_a: *const [32]u8,
    b: ?*c.PancakePeer,
    b_loc: []const u8,
    seed_b: *const [32]u8,
) !void {
    const transport = "tcp";
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(a, transport, transport.len, a_loc.ptr, a_loc.len, c.PANCAKE_HINTS_EMPTY_FALSE, seed_a, seed_a.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_start_session(b, transport, transport.len, b_loc.ptr, b_loc.len, c.PANCAKE_HINTS_EMPTY_FALSE, seed_b, seed_b.len));
    var i: usize = 0;
    while (i < 8 and !(c.pancake_peer_session_is_open(a) == 1 and c.pancake_peer_session_is_open(b) == 1)) : (i += 1) {
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(a));
        try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(b));
        try drainInto(a, b);
        try drainInto(b, a);
    }
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(a));
    try std.testing.expectEqual(@as(i32, 1), c.pancake_peer_session_is_open(b));
}

/// The partner's verbatim location-record bytes (valid Syrup), captured from its
/// keyed start-session, what a gifter embeds as a give's exporter location.
fn partnerLocatorRaw(peer: ?*c.PancakePeer) ![]const u8 {
    var ptr: ?[*]const u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_partner_locator_raw(peer, &ptr, &len));
    try std.testing.expect(ptr != null);
    try std.testing.expect(len > 0);
    return ptr.?[0..len];
}

/// Drain queued events off `peer` until the next event is `want` (or none
/// remains), discarding the handshake `START_SESSION` and any other interim
/// events so a typed poll sees the resolution the test is after.
fn drainEventsUntil(peer: ?*c.PancakePeer, want: i32) void {
    while (true) {
        const kind = c.pancake_peer_peek_event(peer);
        if (kind == want or kind == c.PANCAKE_ERR_WOULD_BLOCK) return;
        var event: c.PancakeEvent = undefined;
        if (c.pancake_peer_poll_event(peer, &event) != c.PANCAKE_OK) return;
        c.pancake_event_release(&event);
    }
}

/// Drain every queued outbound frame off `peer` (handshake residue) so a later
/// take_outbound returns only the frame the test just produced.
fn drainOutbound(peer: ?*c.PancakePeer) !void {
    while (true) {
        var resid: c.PancakeManagedFrame = undefined;
        const rc = c.pancake_peer_take_outbound(peer, &resid);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try std.testing.expectEqual(c.PANCAKE_OK, rc);
        c.pancake_managed_frame_release(&resid);
    }
}

test "C ABI gifter deposit + shared-registry withdraw round-trips across two exporter peers" {
    // The Phase 1 gap-fix proof: an exporter NODE serves a deposit on one
    // connection (to the gifter) and the matching withdraw on another (the
    // recipient's fresh dial). Both exporter peers share one gift registry, so
    // the withdraw finds what the deposit recorded, a per-peer registry would
    // park the withdraw forever. This exercises every new gifter primitive:
    // pancake_build_handoff_give, pancake_peer_send_deposit_gift, and the
    // registry new/set/free surface (the recipient leg reuses the shipped
    // pancake_peer_send_withdraw_gift).
    const crypto = pancake.foundation.crypto;

    // The exporter node's two peers share one identity (one seed) and one
    // registry, the shape the Deno binding will build per node in Phase 2.
    const exporter_seed = [_]u8{0x22} ** 32;
    const gifter_seed = [_]u8{0x33} ** 32;
    const recipient_seed = [_]u8{0x11} ** 32;

    var registry: ?*c.PancakeGiftRegistry = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_gift_registry_new(&registry));
    defer c.pancake_gift_registry_free(registry);

    // Exporter↔gifter session (deposit lands here) and exporter↔recipient session
    // (withdraw lands here), both bound to the shared registry before any traffic.
    var exporter_to_gifter: ?*c.PancakePeer = null;
    var exporter_to_recipient: ?*c.PancakePeer = null;
    var gifter: ?*c.PancakePeer = null;
    var recipient_peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&exporter_to_gifter));
    defer c.pancake_peer_release(exporter_to_gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&exporter_to_recipient));
    defer c.pancake_peer_release(exporter_to_recipient);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&gifter));
    defer c.pancake_peer_release(gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&recipient_peer));
    defer c.pancake_peer_release(recipient_peer);

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_set_gift_registry(exporter_to_gifter, registry));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_set_gift_registry(exporter_to_recipient, registry));

    // The exporter node hosts the gifted object as a bootstrap cap published
    // under one swissnum on *both* connections. The two sessions allocate it at
    // independent export positions — a burned export on the recipient session
    // forces them to differ — so a verbatim deposit-session near would be wrong
    // on the withdraw session. The engine re-resolves the swiss against the
    // withdrawing session instead (the node-shared object identity Phase 2c
    // proves end to end). The gift names the object only by what the gifter
    // imported; the exporter recovers its swiss at deposit and re-mints it here.
    var dm_pos_gifter: u64 = 0;
    var dm_pos_recipient: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_bootstrap_cap(exporter_to_gifter, "dm", 2, &dm_pos_gifter));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_export(exporter_to_recipient, 99));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_bootstrap_cap(exporter_to_recipient, "dm", 2, &dm_pos_recipient));
    try std.testing.expect(dm_pos_gifter != dm_pos_recipient);

    try openKeyedPair(exporter_to_gifter, "127.0.0.1:2", &exporter_seed, gifter, "127.0.0.1:3", &gifter_seed);
    try openKeyedPair(exporter_to_recipient, "127.0.0.1:2", &exporter_seed, recipient_peer, "127.0.0.1:4", &recipient_seed);
    try drainOutbound(exporter_to_gifter);
    try drainOutbound(exporter_to_recipient);
    try drainOutbound(gifter);
    try drainOutbound(recipient_peer);

    // The gifter mints the give: it names the recipient's session key and the
    // exporter's locator + session key, all reachable from the gifter's two
    // sessions in the real flow. Here the test supplies them directly.
    const recipient_pub = crypto.SecretKey.fromSeed(recipient_seed).publicKey();
    const recipient_key = recipient_pub.asBytes();
    const exporter_pub = crypto.SecretKey.fromSeed(exporter_seed).publicKey();
    const exporter_key = exporter_pub.asBytes();
    // The exporter's verbatim location, learned from the gifter's session to it,
    // valid Syrup the give embeds byte-for-byte (a bare string would not decode).
    const exporter_loc = try partnerLocatorRaw(gifter);
    const gift_id = [_]u8{0x5a} ** 32;

    var give_ptr: ?[*]u8 = null;
    var give_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_build_handoff_give(
        &gifter_seed,
        gifter_seed.len,
        recipient_key.ptr,
        recipient_key.len,
        exporter_loc.ptr,
        exporter_loc.len,
        exporter_key.ptr,
        exporter_key.len,
        &gift_id,
        gift_id.len,
        &give_ptr,
        &give_len,
    ));
    defer c.pancake_handoff_give_bytes_release(give_ptr, give_len);
    try std.testing.expect(give_ptr != null);
    const give = give_ptr.?[0..give_len];
    try std.testing.expect(std.mem.indexOf(u8, give, "desc:sig-envelope") != null);
    try std.testing.expect(std.mem.indexOf(u8, give, "desc:handoff-give") != null);

    // The gifter deposits a reference whose home is the exporter, an import it
    // received earlier (here registered directly at the exporter's gifter-session
    // export position for "dm"), encoded back to the exporter as that export on
    // the wire, where the exporter recognizes it as its bootstrap cap.
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(gifter, dm_pos_gifter));
    const gifted = farRef(dm_pos_gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_deposit_gift(gifter, &gift_id, gift_id.len, &gifted));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(gifter));
    try drainInto(gifter, exporter_to_gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(exporter_to_gifter));

    // The recipient withdraws on the SEPARATE exporter↔recipient session. The
    // gift was deposited on the other peer; only the shared registry makes it
    // visible here.
    const withdraw_answer: u64 = 7777;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_withdraw_gift(
        recipient_peer,
        give.ptr,
        give.len,
        &recipient_seed,
        recipient_seed.len,
        withdraw_answer,
    ));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_peer));
    try drainInto(recipient_peer, exporter_to_recipient);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(exporter_to_recipient));
    // The exporter answers the withdraw with the gifted reference; route it back.
    try drainInto(exporter_to_recipient, recipient_peer);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_peer));

    drainEventsUntil(recipient_peer, c.PANCAKE_EVENT_RESOLVE);
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_RESOLVE)), c.pancake_peer_peek_event(recipient_peer));
    var resolve: c.PancakeResolve = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event_resolve(recipient_peer, &resolve));
    defer c.pancake_resolve_release(&resolve);
    try std.testing.expectEqual(withdraw_answer, resolve.answer);
    // FULFILL with a reference, not a BREAK (which a missing/unshared gift, or a
    // failed signature, would produce), proving the shared registry resolved it.
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, resolve.resolution_kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, resolve.fulfill.kind);
}

test "C ABI send_resolve_handoff_give emits a give the recipient projects as a handoff" {
    // The gifter's resolve leg: answering a recipient's question not with a value
    // but with a signed desc:handoff-give, so the binding redeems it transparently.
    const crypto = pancake.foundation.crypto;

    // A recipient asks the gifter a question (an answered deliver), so the gifter
    // holds an inbound answer it can resolve with a give.
    var gifter: ?*c.PancakePeer = null;
    var recipient_peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&gifter));
    defer c.pancake_peer_release(gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new(&recipient_peer));
    defer c.pancake_peer_release(recipient_peer);

    const gifter_seed = [_]u8{0x33} ** 32;
    const recipient_seed = [_]u8{0x11} ** 32;
    try openKeyedPair(gifter, "127.0.0.1:3", &gifter_seed, recipient_peer, "127.0.0.1:4", &recipient_seed);
    try drainOutbound(gifter);
    try drainOutbound(recipient_peer);

    // The gifter exposes an object; the recipient calls it with an answer.
    var export_pos: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_export(gifter, &export_pos));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_register_import(recipient_peer, export_pos));
    var answer: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_next_answer(recipient_peer, &answer));
    const target = farRef(export_pos);
    const args = [_]c.PancakeArgument{argBytes("introduce")};
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_deliver(recipient_peer, &target, &args, args.len, 1, answer));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(recipient_peer));
    try drainInto(recipient_peer, gifter);
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(gifter));

    // The gifter builds a give and resolves the question with it. The inbound
    // question is recorded in the gifter's session by the feed above; draining
    // its deliver event is unnecessary for the resolve.
    const recipient_pub = crypto.SecretKey.fromSeed(recipient_seed).publicKey();
    const recipient_key = recipient_pub.asBytes();
    const exporter_key = [_]u8{0x22} ** 32;
    // Any valid Syrup location decodes; reuse the recipient's, learned from the
    // gifter's session, as a stand-in exporter location for this projection test.
    const exporter_loc = try partnerLocatorRaw(gifter);
    const gift_id = [_]u8{0x5a} ** 32;
    var give_ptr: ?[*]u8 = null;
    var give_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_build_handoff_give(
        &gifter_seed,
        gifter_seed.len,
        recipient_key.ptr,
        recipient_key.len,
        exporter_loc.ptr,
        exporter_loc.len,
        &exporter_key,
        exporter_key.len,
        &gift_id,
        gift_id.len,
        &give_ptr,
        &give_len,
    ));
    defer c.pancake_handoff_give_bytes_release(give_ptr, give_len);
    const give = give_ptr.?[0..give_len];

    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_send_resolve_handoff_give(gifter, answer, give.ptr, give.len));
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_step(gifter));
    try drainInto(gifter, recipient_peer);

    // The recipient projects the resolution as a handoff give carrying the
    // verbatim signed envelope, ready for transparent redeem.
    drainEventsUntil(recipient_peer, c.PANCAKE_EVENT_RESOLVE);
    try std.testing.expectEqual(@as(i32, @intCast(c.PANCAKE_EVENT_RESOLVE)), c.pancake_peer_peek_event(recipient_peer));
    var resolve: c.PancakeResolve = undefined;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_poll_event_resolve(recipient_peer, &resolve));
    defer c.pancake_resolve_release(&resolve);
    try std.testing.expectEqual(answer, resolve.answer);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_HANDOFF, resolve.resolution_kind);
    try std.testing.expect(resolve.handoff.give != null);
    const projected = resolve.handoff.give.?[0..resolve.handoff.give_len];
    try std.testing.expect(std.mem.indexOf(u8, projected, "desc:handoff-give") != null);
}

test "C ABI send_withdraw_gift fails closed without an open keyed session" {
    var peer: ?*c.PancakePeer = null;
    try std.testing.expectEqual(c.PANCAKE_OK, c.pancake_peer_new_raw_open(&peer));
    defer c.pancake_peer_release(peer);

    const give = [_]u8{0x07} ** 8;
    const seed = [_]u8{0x11} ** 32;
    // A raw-open peer has no completed handshake, so no exporter session key.
    try std.testing.expectEqual(c.PANCAKE_ERR_SESSION, c.pancake_peer_send_withdraw_gift(peer, &give, give.len, &seed, seed.len, 1));
    // A 16-byte seed is refused before any session check.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, c.pancake_peer_send_withdraw_gift(peer, &give, give.len, &seed, 16, 1));
    // A NULL give is refused.
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, c.pancake_peer_send_withdraw_gift(peer, null, 0, &seed, seed.len, 1));
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
