//! The managed WebRTC dial through the C provider table (ADR-0226), against
//! the scripted sidecar in `webrtc_sidecar_stub.zig`. A failure here points
//! at `src/c_abi/net_transport/webrtc/dial.zig`: which verbs a netlayer
//! offers, what the signaling callbacks receive, how an answer and a
//! candidate find their exchange, and how an exchange ends as a connection,
//! a failure, or a cancel.

const std = @import("std");
const c = @import("c_abi_shared");
const foundation = @import("foundation");
const webrtc = @import("webrtc");
const webrtc_archive = @import("c_abi_net_transport_webrtc");
const stub = @import("webrtc_sidecar_stub.zig");

const fixture = @import("webrtc_provider_fixture.zig");

const Fixture = fixture.Fixture;
const full_signaling = fixture.full_signaling;
const stub_peer_id = fixture.stub_peer_id;
const expectLastErrorContains = fixture.expectLastErrorContains;

/// Start a dial the way the driver starts one, with no origin.
fn start(fx: *Fixture, request: u64) i32 {
    const t = fx.table();
    const view = fx.locator();
    return t.start_connect.?(t.ctx, request, &view, null, null, &fx.failure);
}

/// Start a dial the way the driver starts a handoff dial: with the
/// introducing session's designator in the origin.
fn startIntroduced(fx: *Fixture, request: u64, introducer: []const u8) i32 {
    const t = fx.table();
    const view = fx.locator();
    const origin: c.GlowcapDialOrigin = .{ .introducer = introducer.ptr, .introducer_len = introducer.len };
    return t.start_connect.?(t.ctx, request, &view, null, &origin, &fx.failure);
}

test "a netlayer dials only when its configuration carries signaling" {
    var silent = try Fixture.init(std.mem.zeroes(webrtc_archive.GlowcapWebrtcSignaling));
    defer silent.deinit();
    const silent_table = silent.table();
    try std.testing.expect(silent_table.start_connect == null);
    try std.testing.expect(silent_table.finish_connect == null);
    try std.testing.expect(silent_table.cancel_connect == null);
    try std.testing.expect(silent_table.claim_external != null);

    var dialing = try Fixture.init(full_signaling);
    defer dialing.deinit();
    const dialing_table = dialing.table();
    try std.testing.expect(dialing_table.start_connect != null);
    try std.testing.expect(dialing_table.finish_connect != null);
    try std.testing.expect(dialing_table.cancel_connect != null);
}

test "signaling with one send callback and not the other is refused" {
    var config: webrtc_archive.GlowcapWebrtcConfig = std.mem.zeroes(webrtc_archive.GlowcapWebrtcConfig);
    config.signaling.send_offer = fixture.sendOffer;
    var netlayer: ?*webrtc_archive.GlowcapWebrtcNetlayer = @ptrFromInt(1);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_new(&config, &netlayer));
    try std.testing.expectEqual(@as(?*webrtc_archive.GlowcapWebrtcNetlayer, null), netlayer);
}

test "a handoff dial hands the offer the introducing session's designator" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const t = fx.table();
    const introducer = foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0x1e))).publicKey().toDesignator();

    try std.testing.expectEqual(c.GLOWCAP_OK, startIntroduced(&fx, 11, &introducer));
    try std.testing.expectEqual(@as(?u64, 11), fixture.signals.offer_exchange);
    try std.testing.expectEqualSlices(u8, &fx.designator, &fixture.signals.offer_designator);
    try std.testing.expectEqual(@as(?usize, introducer.len), fixture.signals.offer_introducer_len);
    try std.testing.expectEqualSlices(u8, &introducer, fixture.signals.offer_introducer[0..introducer.len]);

    // The origin is borrowed for the start call alone: cancelling needs
    // nothing from it.
    var failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_OK, t.cancel_connect.?(t.ctx, 11, &failure));
    try std.testing.expectEqual(@as(?u64, 11), fixture.signals.done_exchange);
}

test "a dial sends the offer, takes the answer, pumps candidates, and becomes the driver's connection" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const t = fx.table();

    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 7));
    try std.testing.expectEqual(@as(?u64, 7), fixture.signals.offer_exchange);
    try std.testing.expectEqualSlices(u8, &fx.designator, &fixture.signals.offer_designator);
    // A dial the application started names no introducer.
    try std.testing.expectEqual(@as(?usize, 0), fixture.signals.offer_introducer_len);
    try std.testing.expectEqual(@as(usize, 64), fixture.signals.offer_sdp_len);

    // The same request id cannot dial twice while the first is in flight.
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, start(&fx, 7));

    const answer = "v=0 answer";
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_provide_answer(fx.netlayer, 7, answer.ptr, answer.len));
    try std.testing.expectEqual(@as(usize, 1), stub.set_remote_calls);
    const ice = "{\"candidate\":\"host\"}";
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_provide_candidate(fx.netlayer, 7, ice.ptr, ice.len));
    try std.testing.expectEqual(@as(usize, 1), stub.add_remote_candidate_calls);

    // A local candidate goes out under the exchange id and is no record for
    // the driver. The channel opening is the connect record.
    var records: [4]c.GlowcapMultiplexedReadyEvent = undefined;
    stub.candidate_bytes_to_emit = 100;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_candidate);
    try std.testing.expectEqual(@as(usize, 0), (try fx.drain(&records)).len);
    try std.testing.expectEqual(@as(?u64, 7), fixture.signals.candidate_exchange);
    try std.testing.expectEqual(@as(usize, 100), fixture.signals.candidate_len);

    stub.open_result = 0;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_open);
    const connect = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), connect.len);
    try std.testing.expectEqual(@as(u64, 7), connect[0].subject);
    try std.testing.expectEqual(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT, connect[0].events);

    // A hello that arrives before the claim still reaches the driver, under
    // the peer id the connection will carry.
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_readable);
    const readable = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), readable.len);
    try std.testing.expectEqual(stub_peer_id, readable[0].subject);
    try std.testing.expectEqual(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE, readable[0].events);

    var conn: u64 = 0;
    try std.testing.expectEqual(c.GLOWCAP_OK, t.finish_connect.?(t.ctx, 7, &conn, &fx.failure));
    try std.testing.expectEqual(stub_peer_id, conn);
    try std.testing.expectEqual(@as(usize, 1), fixture.signals.done_calls);
    try std.testing.expectEqual(@as(?u64, 7), fixture.signals.done_exchange);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_answer(fx.netlayer, 7, answer.ptr, answer.len));

    // The connection is the peer's one reference.
    try std.testing.expectEqual(@as(usize, 0), stub.freed_peers);
    try std.testing.expectEqual(c.GLOWCAP_OK, t.conn_close.?(t.ctx, conn, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
}

test "an answer for no dial in progress is refused without effect" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const answer = "v=0";
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_answer(fx.netlayer, 99, answer.ptr, answer.len));
    try expectLastErrorContains("no exchange 99");
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_candidate(fx.netlayer, 99, answer.ptr, answer.len));
    try std.testing.expectEqual(@as(usize, 0), stub.set_remote_calls);
    try std.testing.expectEqual(@as(usize, 0), stub.add_remote_candidate_calls);
}

test "a refused offer fails the dial at once and leaves no peer behind" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    fixture.signals.refuse_offer = true;
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, start(&fx, 7));
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, fx.failure.result);
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 0), fixture.signals.done_calls);
    try expectLastErrorContains("refused the offer");
}

test "a cancel releases the dialing peer and announces the end of the exchange" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const t = fx.table();
    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 8));
    try std.testing.expectEqual(c.GLOWCAP_OK, t.cancel_connect.?(t.ctx, 8, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(?u64, 8), fixture.signals.done_exchange);
    // Cancelling again, or an unknown request, is already done.
    try std.testing.expectEqual(c.GLOWCAP_OK, t.cancel_connect.?(t.ctx, 8, &fx.failure));
    try std.testing.expectEqual(@as(usize, 1), fixture.signals.done_calls);
}

test "a channel that fails or closes before opening fails the dial with its own cause" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const t = fx.table();
    var records: [4]c.GlowcapMultiplexedReadyEvent = undefined;
    var conn: u64 = 0;

    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 9));
    stub.open_result = -1;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_open);
    const failed = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), failed.len);
    try std.testing.expectEqual(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT, failed[0].events);
    // Nothing more is reported for a failed exchange.
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_closed);
    try std.testing.expectEqual(@as(usize, 0), (try fx.drain(&records)).len);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, t.finish_connect.?(t.ctx, 9, &conn, &fx.failure));
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, fx.failure.result);
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(?u64, 9), fixture.signals.done_exchange);

    fx.failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 10));
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_closed);
    try std.testing.expectEqual(@as(usize, 1), (try fx.drain(&records)).len);
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, t.finish_connect.?(t.ctx, 10, &conn, &fx.failure));
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, fx.failure.result);
    try std.testing.expectEqual(@as(usize, 2), stub.freed_peers);

    // Finishing a dial whose connect record never came is a would-block,
    // and it ends the exchange too.
    fx.failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 11));
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, t.finish_connect.?(t.ctx, 11, &conn, &fx.failure));
    try std.testing.expectEqual(@as(usize, 3), stub.freed_peers);
    try std.testing.expectEqual(@as(usize, 3), fixture.signals.done_calls);
}

test "a candidate the application cannot carry fails the dial with the refusal cause" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const t = fx.table();
    var records: [4]c.GlowcapMultiplexedReadyEvent = undefined;
    var conn: u64 = 0;

    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 14));
    fixture.signals.refuse_candidate = true;
    stub.candidate_bytes_to_emit = 100;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_candidate);
    // The refusal fails the exchange in the same drain, as its connect record.
    const failed = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), failed.len);
    try std.testing.expectEqual(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT, failed[0].events);
    try std.testing.expectEqual(@as(u64, 14), failed[0].subject);
    try std.testing.expectEqual(@as(?u64, 14), fixture.signals.candidate_exchange);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_answer(fx.netlayer, 14, "v=0", 3));
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, t.finish_connect.?(t.ctx, 14, &conn, &fx.failure));
    try std.testing.expectEqualStrings("SignalingRefused", fx.failure.primary_name.?[0..fx.failure.primary_name_len]);
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(?u64, 14), fixture.signals.done_exchange);
}

test "giving up on an exchange fails the dial at the next drain with the signaling cause" {
    var fx = try Fixture.init(full_signaling);
    defer fx.deinit();
    const t = fx.table();
    var records: [4]c.GlowcapMultiplexedReadyEvent = undefined;
    var conn: u64 = 0;

    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 12));
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_fail_exchange(fx.netlayer, 12));
    // Closing the peer queued its closed record, which becomes the connect record.
    const failed = try fx.drain(&records);
    try std.testing.expectEqual(@as(usize, 1), failed.len);
    try std.testing.expectEqual(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT, failed[0].events);
    try std.testing.expectEqual(@as(u64, 12), failed[0].subject);
    // Giving up again is already done, a late answer has no effect, and an
    // unknown dial is refused.
    try std.testing.expectEqual(c.GLOWCAP_OK, webrtc_archive.glowcap_webrtc_netlayer_fail_exchange(fx.netlayer, 12));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_provide_answer(fx.netlayer, 12, "v=0", 3));
    try expectLastErrorContains("is past signaling");
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_fail_exchange(fx.netlayer, 99));
    try expectLastErrorContains("no exchange 99");
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, t.finish_connect.?(t.ctx, 12, &conn, &fx.failure));
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, fx.failure.result);
    try std.testing.expectEqualStrings("SignalingFailed", fx.failure.primary_name.?[0..fx.failure.primary_name_len]);
    try std.testing.expectEqual(@as(usize, 1), stub.freed_peers);
    try std.testing.expectEqual(@as(?u64, 12), fixture.signals.done_exchange);

    // A channel that has already opened is past giving up.
    fx.failure = c.transport_provider.emptyProviderFailure();
    try std.testing.expectEqual(c.GLOWCAP_OK, start(&fx, 13));
    stub.open_result = 0;
    stub.pushDriverEvent(stub.lastPeer(), webrtc.ev_open);
    try std.testing.expectEqual(@as(usize, 1), (try fx.drain(&records)).len);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, webrtc_archive.glowcap_webrtc_netlayer_fail_exchange(fx.netlayer, 13));
    try expectLastErrorContains("already opened");
    try std.testing.expectEqual(c.GLOWCAP_OK, t.cancel_connect.?(t.ctx, 13, &fx.failure));
    try std.testing.expectEqual(@as(usize, 2), stub.freed_peers);
}
