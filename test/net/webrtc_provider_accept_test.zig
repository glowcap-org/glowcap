//! The managed WebRTC accept through the C provider table (ADR-0035),
//! against the scripted sidecar in `webrtc_sidecar_stub.zig`. A failure here
//! points at `src/c_abi/net_transport/webrtc/accept.zig`: which verbs a
//! netlayer offers, what `listen` records, how an inbound offer becomes an
//! answer under a minted exchange id, how the channel opening becomes the
//! listener's accept, and how `stop_listen` ends what is still in flight.

const std = @import("std");
const c = @import("c_abi_shared");
const foundation = @import("foundation");
const webrtc = @import("webrtc");
const webrtc_archive = @import("c_abi_net_transport_webrtc");
const stub = @import("webrtc_sidecar_stub.zig");
const fixture = @import("webrtc_provider_fixture.zig");

const Fixture = fixture.Fixture;
const stub_peer_id = fixture.stub_peer_id;
const expectLastErrorContains = fixture.expectLastErrorContains;
const EV_ACCEPT = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_ACCEPT;

const route_id: u64 = 5;
const offer = "v=0 offer";
const accept_id_bit: u64 = 1 << 63;

/// Signaling that answers and never dials.
const answering_signaling: webrtc_archive.GlowcapWebrtcSignaling = .{
    .ctx = null,
    .send_offer = null,
    .send_answer = fixture.sendAnswer,
    .send_candidate = fixture.sendCandidate,
    .done = fixture.done,
};

/// The Host identity the driver would pass to `listen`.
fn identity() [fixture.designator_len]u8 {
    return foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x5e))).publicKey().toDesignator();
}

fn listen(fx: *Fixture, requested: ?[]const u8, out_result: *c.GlowcapListenResult) i32 {
    const t = fx.table();
    const host = identity();
    const requested_ptr: ?[*]const u8 = if (requested) |value| value.ptr else null;
    const requested_len: usize = if (requested) |value| value.len else 0;
    return t.listen.?(
        t.ctx,
        route_id,
        webrtc.transport_name.ptr,
        webrtc.transport_name.len,
        requested_ptr,
        requested_len,
        &host,
        host.len,
        null,
        out_result,
        &fx.failure,
    );
}

fn listenReady(fx: *Fixture) !*anyopaque {
    var result: c.GlowcapListenResult = undefined;
    try std.testing.expectEqual(c.GLOWCAP_OK, listen(fx, null, &result));
    try std.testing.expectEqual(c.GLOWCAP_LISTEN_READY, result.state);
    return result.listener.?;
}

fn provideOffer(fx: *Fixture, out_exchange: *u64) i32 {
    return webrtc_archive.glowcap_webrtc_netlayer_provide_offer(fx.netlayer, &fx.designator, fx.designator.len, offer.ptr, offer.len, out_exchange);
}

/// What `listener_locator` projected, written by `sinkLocator`.
var sunk_transport: [16]u8 = undefined;
var sunk_transport_len: usize = 0;
var sunk_designator: [fixture.designator_len]u8 = undefined;
var sunk_count: usize = 0;

fn sinkLocator(_: ?*anyopaque, view: ?*const c.GlowcapLocatorView) callconv(.c) i32 {
    const v = view.?;
    sunk_transport_len = v.transport_len;
    @memcpy(sunk_transport[0..v.transport_len], v.transport.?[0..v.transport_len]);
    @memcpy(&sunk_designator, v.designator.?[0..v.designator_len]);
    sunk_count += 1;
    return c.GLOWCAP_OK;
}

test "a netlayer listens only when its signaling can answer" {
    var silent = try Fixture.init(std.mem.zeroes(webrtc_archive.GlowcapWebrtcSignaling));
    defer silent.deinit();
    const silent_table = silent.table();
    try std.testing.expect(silent_table.listen == null);
    try std.testing.expect(silent_table.finish_accept == null);
    try std.testing.expect(silent_table.stop_listen == null);

    var answering = try Fixture.init(answering_signaling);
    defer answering.deinit();
    const answering_table = answering.table();
    try std.testing.expect(answering_table.listen != null);
    try std.testing.expect(answering_table.listener_locator != null);
    try std.testing.expect(answering_table.listener_advertise != null);
    try std.testing.expect(answering_table.finish_accept != null);
    try std.testing.expect(answering_table.stop_listen != null);
    // The listener's setup completes at once, so the pending verbs stay out.
    try std.testing.expect(answering_table.finish_listen == null);
    try std.testing.expect(answering_table.cancel_listen == null);
    try std.testing.expect(answering_table.start_connect == null);

    var both = try Fixture.init(fixture.full_signaling);
    defer both.deinit();
    try std.testing.expect(both.table().listen != null);
    try std.testing.expect(both.table().start_connect != null);

    // An answer callback without the candidate callback is half a signaling.
    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    config.signaling.send_answer = fixture.sendAnswer;
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = @ptrFromInt(1);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    try std.testing.expectEqual(@as(?*webrtc_archive.GlowcapWebrtcNetlayer, null), netlayer);
}

test "an inbound offer is answered under a minted id and becomes the listener's accepted connection" {
    var fx = try Fixture.init(answering_signaling);
    defer fx.deinit();
    const t = fx.table();
    const listener = try listenReady(&fx);

    // The listener is reachable as the Host's identity when nothing else was asked.
    sunk_count = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, t.listener_locator.?(listener, null, sinkLocator, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), sunk_count);
    try std.testing.expectEqualStrings(webrtc.transport_name, sunk_transport[0..sunk_transport_len]);
    try std.testing.expectEqualSlices(u8, &identity(), &sunk_designator);

    var exchange: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &exchange));
    try std.testing.expect(exchange & accept_id_bit != 0);
    try std.testing.expectEqual(@as(?u64, exchange), fixture.signals.answer_exchange);
    try std.testing.expectEqualSlices(u8, &fx.designator, &fixture.signals.answer_designator);
    try std.testing.expectEqual(@as(usize, 64), fixture.signals.answer_sdp_len);
    try std.testing.expectEqual(@as(usize, 1), stub.set_remote_calls);

    // The offerer's candidates reach the answerer under the minted id, and
    // the answerer's own go out under it. Neither is a record for the driver.
    const ice = "{\"candidate\":\"host\"}";
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_provide_candidate(fx.netlayer, exchange, ice.ptr, ice.len));
    try std.testing.expectEqual(@as(usize, 1), stub.add_remote_candidate_calls);
    var records: [4]c.GlowcapMultiplexedReadyEvent = undefined;
    stub.candidate_bytes_to_emit = 100;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_candidate);
    try std.testing.expectEqual(@as(usize, 0), (try fx.drain(&records)).len);
    try std.testing.expectEqual(@as(?u64, exchange), fixture.signals.candidate_exchange);
    try std.testing.expectEqual(@as(usize, 100), fixture.signals.candidate_len);
    // The netlayer produced the answer itself, so none can be provided.
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_answer(fx.netlayer, exchange, offer.ptr, offer.len));
    try expectLastErrorContains("is an accept");

    // The channel opening is the listener's accept record, on the listener's route.
    stub.open_result = 0;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_open);
    const accepted = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), accepted.len);
    try std.testing.expectEqual(route_id, accepted[0].subject);
    try std.testing.expectEqual(EV_ACCEPT, accepted[0].events);

    // A hello that arrives before the claim still reaches the driver under the peer id.
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_readable);
    const readable = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), readable.len);
    try std.testing.expectEqual(stub_peer_id, readable[0].subject);

    var conn: u64 = 0;
    try std.testing.expectEqual(@as(usize, 0), fixture.signals.done_calls);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.finish_accept.?(listener, &conn, &fx.failure));
    try std.testing.expectEqual(stub_peer_id, conn);
    try std.testing.expectEqual(@as(usize, 1), fixture.signals.done_calls);
    try std.testing.expectEqual(@as(?u64, exchange), fixture.signals.done_exchange);
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, t.finish_accept.?(listener, &conn, &fx.failure));
    // The exchange is over: a late candidate finds nothing.
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_candidate(fx.netlayer, exchange, ice.ptr, ice.len));
    try expectLastErrorContains("no exchange");

    // The connection's authenticated remote is the offerer's key.
    var remote: [foundation.crypto.peer_key_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 1), t.conn_remote_key.?(t.ctx, conn, &remote));
    try std.testing.expectEqualSlices(u8, foundation.crypto.PeerKey.fromDesignator(&fx.designator).?.asBytes(), &remote);

    // The connection is the peer's one reference.
    try std.testing.expectEqual(@as(usize, 0), stub.freed_peers);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.conn_close.?(t.ctx, conn, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);

    // Stopping and listening again is an ordinary restart.
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(listener, &fx.failure));
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(listener, &fx.failure));
    const again = try listenReady(&fx);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(again, &fx.failure));
}

test "an offer the netlayer cannot answer commits nothing" {
    var fx = try Fixture.init(answering_signaling);
    defer fx.deinit();
    const t = fx.table();
    var exchange: u64 = 0;

    // No listener yet.
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, provideOffer(&fx, &exchange));
    try expectLastErrorContains("no listener is active");
    try std.testing.expectEqual(@as(usize, 0), stub.set_remote_calls);

    const listener = try listenReady(&fx);

    // A second listener on one netlayer.
    var result: c.GlowcapListenResult = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, listen(&fx, null, &result));

    // A designator that names no key.
    const bad = "not-a-key";
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_offer(fx.netlayer, bad.ptr, bad.len, offer.ptr, offer.len, &exchange));
    try expectLastErrorContains("names no key");
    try std.testing.expectEqual(@as(usize, 0), stub.freed_peers);

    // The sidecar refuses the offer.
    stub.set_remote_result = -1;
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, provideOffer(&fx, &exchange));
    try expectLastErrorContains("refused the offer");
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(?u64, null), fixture.signals.answer_exchange);
    stub.set_remote_result = 0;

    // The application cannot carry the answer.
    fixture.signals.refuse_answer = true;
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, provideOffer(&fx, &exchange));
    try expectLastErrorContains("refused the answer");
    try std.testing.expectEqual(@as(usize, 2), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 0), fixture.signals.done_calls);
    fixture.signals.refuse_answer = false;

    // Nothing above left an exchange behind: stopping the listener ends only
    // the one offer that was answered.
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &exchange));
    try std.testing.expect(exchange & accept_id_bit != 0);
    try std.testing.expectEqual(@as(usize, 2), stub.freed_peers);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(listener, &fx.failure));
    try std.testing.expectEqual(@as(usize, 3), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 1), fixture.signals.done_calls);
    try std.testing.expectEqual(@as(?u64, exchange), fixture.signals.done_exchange);
}

test "a dial and an offer with one peer each run under their own id" {
    var fx = try Fixture.init(fixture.full_signaling);
    defer fx.deinit();
    const t = fx.table();
    const listener = try listenReady(&fx);
    const view = fx.locator();

    // Both peers dial each other at once: this side's dial and the far
    // side's offer are two exchanges, and CapTP keeps one of their sessions.
    try std.testing.expectEqual(c.GLOWCAP_OK, t.start_connect.?(t.ctx, 1, &view, null, null, &fx.failure));
    var first: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &first));
    var second: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &second));
    try std.testing.expect(first != 1 and second != 1 and first != second);

    // Each ends on its own.
    try std.testing.expectEqual(c.GLOWCAP_OK, t.cancel_connect.?(t.ctx, 1, &fx.failure));
    try std.testing.expectEqual(@as(?u64, 1), fixture.signals.done_exchange);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(listener, &fx.failure));
    try std.testing.expectEqual(@as(usize, 3), fixture.signals.done_calls);
}

test "an accept that ends before opening is quiet, and stop_listen closes the rest" {
    var fx = try Fixture.init(answering_signaling);
    defer fx.deinit();
    const t = fx.table();
    const listener = try listenReady(&fx);
    var records: [4]c.GlowcapMultiplexedReadyEvent = undefined;
    var exchange: u64 = 0;

    // The offerer went away: the closed record ends the exchange with done
    // and nothing for the driver.
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &exchange));
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_closed);
    try std.testing.expectEqual(@as(usize, 0), (try fx.drain(&records)).len);
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(?u64, exchange), fixture.signals.done_exchange);

    // The application gave up: the peer closes and its closed record ends it.
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &exchange));
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_fail_exchange(fx.netlayer, exchange));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_candidate(fx.netlayer, exchange, offer.ptr, offer.len));
    try expectLastErrorContains("is past signaling");
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_closed);
    try std.testing.expectEqual(@as(usize, 0), (try fx.drain(&records)).len);
    try std.testing.expectEqual(@as(usize, 2), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 2), fixture.signals.done_calls);

    // An accept the driver never claimed, and one still signaling, both end with stop_listen.
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &exchange));
    stub.open_result = 0;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_open);
    try std.testing.expectEqual(@as(usize, 1), (try fx.drain(&records)).len);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(listener, &fx.failure));
    try std.testing.expectEqual(@as(usize, 3), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 3), fixture.signals.done_calls);
    var conn: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, t.finish_accept.?(listener, &conn, &fx.failure));

    const again = try listenReady(&fx);
    try std.testing.expectEqual(c.GLOWCAP_OK, provideOffer(&fx, &exchange));
    try std.testing.expectEqual(c.GLOWCAP_OK, t.stop_listen.?(again, &fx.failure));
    try std.testing.expectEqual(@as(usize, 4), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 4), fixture.signals.done_calls);
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, provideOffer(&fx, &exchange));
}

test "a listener is named by its key and advertises only that locator" {
    var fx = try Fixture.init(answering_signaling);
    defer fx.deinit();
    const t = fx.table();
    var result: c.GlowcapListenResult = undefined;

    // A requested designator that is a different key from the Host's is refused,
    // and so is one that names no key.
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, listen(&fx, &fx.designator, &result));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, listen(&fx, "nope", &result));

    // The Host's own designator may be requested.
    const host = identity();
    try std.testing.expectEqual(c.GLOWCAP_OK, listen(&fx, &host, &result));
    const listener = result.listener.?;
    defer _ = t.stop_listen.?(listener, &fx.failure);

    sunk_count = 0;
    const own = Fixture.locatorFor(&host);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.listener_advertise.?(listener, &own, null, sinkLocator, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), sunk_count);
    try std.testing.expectEqualSlices(u8, &host, &sunk_designator);
    const other = Fixture.locatorFor(&fx.designator);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, t.listener_advertise.?(listener, &other, null, sinkLocator, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), sunk_count);
}
