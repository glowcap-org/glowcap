//! The chunked byte stream into `feed_bytes`: delimiting across chunks on both
//! codecs, the outbound high-water, the typed over-cap refusal, transport_closed
//! terminating and readmitting, and the open-transition pause that holds a
//! coalesced tail for post-open setup.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const behaviors = @import("behaviors.zig");
const argBase = harness.argBase;
const argInt = harness.argInt;
const argStr = harness.argStr;
const argRef = harness.argRef;
const frame_cap = harness.frame_cap;
const sessionLimitOptions = harness.sessionLimitOptions;
const close_cancel = harness.close_cancel;
const close_finish_unbounded = harness.close_finish_unbounded;
const closeFinish = harness.closeFinish;
const expectOk = harness.expectOk;
const hostSeed = harness.hostSeed;
const openDialed = harness.openDialed;
const openAccepted = harness.openAccepted;
const openAcceptedKeyed = harness.openAcceptedKeyed;
const newHostWithProfile = harness.newHostWithProfile;
const newHostWithFeatures = harness.newHostWithFeatures;
const newHostWith = harness.newHostWith;
const newHost = harness.newHost;
const locatorView = harness.locatorView;
const setAdvertisedLocator = harness.setAdvertisedLocator;
const ensureAdvertisedLocator = harness.ensureAdvertisedLocator;
const tcpLocator = harness.tcpLocator;
const Pair = harness.Pair;
const takeOutbound = harness.takeOutbound;
const ParkedDial = harness.ParkedDial;
const Dials = harness.Dials;
const shuttle = harness.shuttle;
const CapturedSettle = harness.CapturedSettle;
const Watches = harness.Watches;
const drainActions = harness.drainActions;
const pump = harness.pump;
const openPair = harness.openPair;
const Counter = behaviors.Counter;
const widgetBehavior = behaviors.widgetBehavior;
const TypedCapture = behaviors.TypedCapture;
const InlineCapabilityCapture = behaviors.InlineCapabilityCapture;
const inlineCapabilityBehavior = behaviors.inlineCapabilityBehavior;
const typedBehavior = behaviors.typedBehavior;
const IntroducerCtx = behaviors.IntroducerCtx;
const introducerBehavior = behaviors.introducerBehavior;
const CaretakerCtx = behaviors.CaretakerCtx;
const caretakerBehavior = behaviors.caretakerBehavior;
const FactoryCtx = behaviors.FactoryCtx;
const factoryBehavior = behaviors.factoryBehavior;
const kitchen_pair_items = behaviors.kitchen_pair_items;
const kitchen_boxed_items = behaviors.kitchen_boxed_items;
const KitchenCtx = behaviors.KitchenCtx;
const kitchenBehavior = behaviors.kitchenBehavior;

/// One direction's staging buffer for the feed_bytes shuttle: the encoded
/// frames awaiting their chunked presentation. The library owns the
/// unconsumed stream tail, so nothing carries over between rounds.
const BytePipe = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
};

fn appendStreamOutbound(pipe: *BytePipe, prefix: []const u8, bytes: []const u8) !void {
    try std.testing.expect(pipe.len + prefix.len + bytes.len <= pipe.buf.len);
    @memcpy(pipe.buf[pipe.len..][0..prefix.len], prefix);
    pipe.len += prefix.len;
    @memcpy(pipe.buf[pipe.len..][0..bytes.len], bytes);
    pipe.len += bytes.len;
}

/// Drain `from`'s encoded frames into `pipe`, then feed them to `to` through
/// glowcap_host_session_feed_bytes, presenting at most `chunk` bytes per
/// call so frames split at pathological boundaries, including mid-frame. The
/// library owns the tail, so every presented byte is consumed. The leading
/// resume feeds any frames the session held behind its handshake open.
fn shuttleBytes(from: ?*cd.GlowcapHostSession, to: ?*cd.GlowcapHostSession, pipe: *BytePipe, chunk: usize) !bool {
    try expectOk(cd.glowcap_host_session_resume_feed(to));
    var moved = false;
    while (true) {
        var mf: c.GlowcapManagedFrame = undefined;
        var prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
        var prefix_len: usize = undefined;
        const rc = cd.glowcap_host_session_take_outbound(
            from,
            &mf,
            &prefix,
            prefix.len,
            &prefix_len,
        );
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        defer c.glowcap_managed_frame_release(&mf);
        try appendStreamOutbound(pipe, prefix[0..prefix_len], mf.bytes.?[0..mf.len]);
        moved = true;
    }
    var offset: usize = 0;
    while (offset < pipe.len) {
        const n = @min(chunk, pipe.len - offset);
        try expectOk(cd.glowcap_host_session_feed_bytes(to, pipe.buf[offset..].ptr, n));
        offset += n;
        moved = true;
    }
    pipe.len = 0;
    return moved;
}

/// Drain `from` through the generic transport-packet seam and feed each packet
/// to `to`. WebRTC is message-framed, so the Host must return no stream prefix:
/// one drained frame is one transport packet.
fn shuttleMessagePackets(from: ?*cd.GlowcapHostSession, to: ?*cd.GlowcapHostSession) !bool {
    var moved = false;
    while (true) {
        var mf: c.GlowcapManagedFrame = undefined;
        var prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
        var prefix_len: usize = undefined;
        const rc = cd.glowcap_host_session_take_packet(
            from,
            &mf,
            &prefix,
            prefix.len,
            &prefix_len,
        );
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        defer c.glowcap_managed_frame_release(&mf);
        try std.testing.expectEqual(@as(usize, 0), prefix_len);
        try expectOk(cd.glowcap_host_session_feed_packet(to, mf.bytes, mf.len));
        moved = true;
    }
    return moved;
}

fn pumpMessagePackets(hosts: []const ?*cd.GlowcapHost, pair: Pair, dials: *Dials, watches: *Watches) !void {
    var rounds: usize = 0;
    var quiet: usize = 0;
    while (rounds < 128) : (rounds += 1) {
        var progressed = false;
        if (try shuttleMessagePackets(pair.a, pair.b)) progressed = true;
        if (try shuttleMessagePackets(pair.b, pair.a)) progressed = true;
        if (try drainActions(hosts, dials, watches)) progressed = true;
        if (progressed) {
            quiet = 0;
        } else {
            quiet += 1;
            if (quiet == 2) return;
        }
    }
    return error.PumpDidNotQuiesce;
}

/// `pump`, but every frame crosses as a chunked byte stream. Quiesces after
/// two consecutive no-progress rounds: the leading resume feeds can dispatch
/// session-held frames whose effects surface only on the following round.
fn pumpBytes(hosts: []const ?*cd.GlowcapHost, pair: Pair, pipes: *[2]BytePipe, chunk: usize, dials: *Dials, watches: *Watches) !void {
    var rounds: usize = 0;
    var quiet: usize = 0;
    while (rounds < 128) : (rounds += 1) {
        var progressed = false;
        if (try shuttleBytes(pair.a, pair.b, &pipes[0], chunk)) progressed = true;
        if (try shuttleBytes(pair.b, pair.a, &pipes[1], chunk)) progressed = true;
        if (try drainActions(hosts, dials, watches)) progressed = true;
        if (progressed) {
            quiet = 0;
        } else {
            quiet += 1;
            if (quiet == 2) return;
        }
    }
    return error.PumpDidNotQuiesce;
}

test "libglowcap_host: feed_bytes delimits a chunked byte stream end to end, both codecs" {
    const codecs = [_]u32{ c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CODEC_CAPNP };
    for (codecs, 0..) |codec, i| {
        const client = try newHostWith(@intCast(0x81 + 2 * i), codec);
        defer _ = cd.glowcap_host_release(client);
        const server = try newHostWith(@intCast(0x82 + 2 * i), codec);
        defer _ = cd.glowcap_host_release(server);
        var dials = Dials{};
        var watches = Watches{};
        const hosts = [_]?*cd.GlowcapHost{ client, server };

        // Seven never divides a frame or a capnp word, so the keyed hellos
        // and every later frame arrive split mid-frame (and, for the
        // word-shaped codec, mid-word and unaligned).
        const chunk: usize = 7;
        var pipes = [_]BytePipe{ .{}, .{} };
        const designator = "127.0.0.1:7004";
        try ensureAdvertisedLocator(client, "tcp");
        try setAdvertisedLocator(server, tcpLocator(designator));
        var accepted: ?*cd.GlowcapHostSession = null;
        try expectOk(openAccepted(server, "tcp", 3, &accepted));
        var dialed: ?*cd.GlowcapHostSession = null;
        try expectOk(openDialed(client, "tcp", 3, designator.ptr, designator.len, &dialed));
        const pair = Pair{ .a = dialed, .b = accepted };
        try pumpBytes(&hosts, pair, &pipes, chunk, &dials, &watches);
        try std.testing.expect(cd.glowcap_host_session_is_open(dialed) != 0);
        try std.testing.expect(cd.glowcap_host_session_is_open(accepted) != 0);

        var counter = Counter{};
        var widget_local_ref: c.GlowcapReference = .{ .id = 0 };
        try expectOk(cd.glowcap_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));
        var fetched = CapturedSettle{};
        var fetched_vow: u64 = 0;
        try expectOk(cd.glowcap_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
        watches.add(client, fetched_vow, &fetched);
        try pumpBytes(&hosts, pair, &pipes, chunk, &dials, &watches);
        const widget_ref = try fetched.requireRef();

        var vow: u64 = 0;
        try expectOk(cd.glowcap_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &vow));
        var settled = CapturedSettle{};
        watches.add(client, vow, &settled);
        try pumpBytes(&hosts, pair, &pipes, chunk, &dials, &watches);
        try std.testing.expect(settled.fired);
        try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
        try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
        try std.testing.expectEqual(@as(u32, 1), counter.pokes);
        // Nothing lingers in either inbox: the stream delimited exactly.
        try std.testing.expectEqual(@as(usize, 0), pipes[0].len);
        try std.testing.expectEqual(@as(usize, 0), pipes[1].len);
    }
}

test "libglowcap_host: transport packets carry bare frames for message-framed transports" {
    const client = try newHost(0x91);
    defer _ = cd.glowcap_host_release(client);
    const server = try newHost(0x92);
    defer _ = cd.glowcap_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.GlowcapHost{ client, server };

    const server_seed = hostSeed(0x92);
    const server_designator = crypto.SecretKey.fromSeed(server_seed[0..32].*).publicKey().toDesignator();
    try ensureAdvertisedLocator(client, "webrtc");
    var accepted: ?*cd.GlowcapHostSession = null;
    try expectOk(openAcceptedKeyed(server, "webrtc", server_designator[0..], "", &accepted));
    var dialed: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(client, "webrtc", 6, server_designator[0..].ptr, server_designator.len, &dialed));
    const pair = Pair{ .a = dialed, .b = accepted };
    try pumpMessagePackets(&hosts, pair, &dials, &watches);
    try std.testing.expect(cd.glowcap_host_session_is_open(dialed) != 0);
    try std.testing.expect(cd.glowcap_host_session_is_open(accepted) != 0);
    try expectOk(cd.glowcap_host_session_resume_feed(accepted));
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CODEC,
        cd.glowcap_host_session_feed_packet(accepted, null, 0),
    );
}

test "libglowcap_host: producers honor their minted outbound high-water until frames drain" {
    const client = try newHost(0x72);
    defer _ = cd.glowcap_host_release(client);
    const server = try newHost(0x73);
    defer _ = cd.glowcap_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.GlowcapHost{ client, server };

    // This limit belongs to the session minted below, not to the Host options
    // after that point. It is large enough for an ordinary fetch producer but
    // small enough for a short burst to reach deterministically.
    var tight = sessionLimitOptions(0, 0, 1024, 0);
    try expectOk(cd.glowcap_host_set_session_limits(client, &tight));

    const designator = "127.0.0.1:7072";
    try ensureAdvertisedLocator(client, "tcp");
    try setAdvertisedLocator(server, tcpLocator(designator));
    var accepted: ?*cd.GlowcapHostSession = null;
    try expectOk(openAccepted(server, "tcp", 3, &accepted));
    defer _ = cd.glowcap_host_session_release(accepted);
    var dialed: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(client, "tcp", 3, designator.ptr, designator.len, &dialed));
    defer _ = cd.glowcap_host_session_release(dialed);
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(&hosts, &.{pair}, &dials, &watches);

    var first_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(dialed, "first", 5, &first_vow));
    try std.testing.expect(first_vow != 0);
    // Raising the Host default now must not rewrite this live session.
    var roomy = sessionLimitOptions(0, 0, 1024 * 1024, 0);
    try expectOk(cd.glowcap_host_set_session_limits(client, &roomy));
    var admitted: usize = 1;
    var refused = false;
    for (0..128) |_| {
        var vow: u64 = 0;
        const rc = cd.glowcap_host_session_fetch(dialed, "next", 4, &vow);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) {
            try std.testing.expectEqual(@as(u64, 0), vow);
            refused = true;
            break;
        }
        try expectOk(rc);
        try std.testing.expect(vow != 0);
        admitted += 1;
    }
    try std.testing.expect(admitted > 1);
    try std.testing.expect(refused);
    // Inbound production is parked by the same session-owned mark.
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, cd.glowcap_host_session_feed_bytes(dialed, null, 0));
    while (true) {
        var mf: c.GlowcapManagedFrame = undefined;
        const rc = takeOutbound(dialed, &mf);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        c.glowcap_managed_frame_release(&mf);
    }
    var retry_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(dialed, "next", 4, &retry_vow));
    try std.testing.expect(retry_vow != 0);
}

test "libglowcap_host: feed_bytes refuses an over-cap frame with the typed FRAME_TOO_LARGE and queues the abort" {
    // The receiver's cap is smaller than any keyed hello, so the partner's
    // first frame trips the cap-during-scan verdict.
    var tiny: ?*cd.GlowcapHost = null;
    const tiny_seed = hostSeed(0x91);
    try expectOk(cd.glowcap_host_new(&tiny_seed, tiny_seed.len, 64, 1, c.GLOWCAP_CODEC_SYRUP, c.GLOWCAP_CAPTP_V1_0, c.GLOWCAP_FEATURE_FULL, 0, 1, &tiny));
    defer _ = cd.glowcap_host_release(tiny);
    const dialer = try newHost(0x92);
    defer _ = cd.glowcap_host_release(dialer);

    const designator = "127.0.0.1:7005";
    try ensureAdvertisedLocator(dialer, "tcp");
    try setAdvertisedLocator(tiny, tcpLocator(designator));
    var accepted: ?*cd.GlowcapHostSession = null;
    try expectOk(openAccepted(tiny, "tcp", 3, &accepted));
    var dialed: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(dialer, "tcp", 3, designator.ptr, designator.len, &dialed));

    var hello: c.GlowcapManagedFrame = undefined;
    try expectOk(takeOutbound(dialed, &hello));
    defer c.glowcap_managed_frame_release(&hello);
    try std.testing.expect(hello.len > 64);

    var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = stream_framing.renderPrefix(&prefix_buf, hello.len);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_FRAME_TOO_LARGE,
        cd.glowcap_host_session_feed_bytes(accepted, prefix.ptr, prefix.len),
    );

    // The typed cause is retained locally and the loud abort is queued for
    // the partner, exactly the whole-frame feed's failure choreography:
    // deliver the refusing side's queued outbound (its own hello, then the
    // abort) and the partner retains the typed kind.
    var abort_info: c.GlowcapLastAbort = undefined;
    try expectOk(cd.glowcap_host_session_last_abort(accepted, &abort_info));
    try std.testing.expect(abort_info.has_kind != 0);
    while (true) {
        var out: c.GlowcapManagedFrame = undefined;
        const rc = takeOutbound(accepted, &out);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        // The dialed side's own hello/handshake output is unrelated to this
        // terminal-delivery assertion, but it still counts against that
        // session's waterline. Drain it before feeding the next partner frame.
        while (true) {
            var local: c.GlowcapManagedFrame = undefined;
            const local_rc = takeOutbound(dialed, &local);
            if (local_rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
            try expectOk(local_rc);
            c.glowcap_managed_frame_release(&local);
        }
        const borrowed: c.GlowcapFrame = .{ .bytes = out.bytes, .len = out.len, .shape = out.shape };
        try expectOk(cd.glowcap_host_session_feed(dialed, &borrowed));
        c.glowcap_managed_frame_release(&out);
    }
    // An over-cap frame projects the resource-exhaustion abort kind.
    var kind_name: ?[*]const u8 = null;
    var kind_name_len: usize = 0;
    try expectOk(cd.glowcap_host_session_partner_abort(dialed, &kind_name, &kind_name_len, null, 0, null));
    try std.testing.expectEqualStrings("ResourceExhausted", kind_name.?[0..kind_name_len]);
}

test "libglowcap_host: transport_closed terminates finish and fires a parked fetch closed" {
    const client = try newHost(0x51);
    defer _ = cd.glowcap_host_release(client);
    const server = try newHost(0x52);
    defer _ = cd.glowcap_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    // Gives whose exporter is this connection would name the override; null
    // clears it back to the session record.
    const override_loc = try glowcap.ocapn.model.uri.parsePeer(std.testing.allocator, "ocapn://192.0.2.1%3A7009.tcp");
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, override_loc);
    var no_hints: [0]cd.GlowcapLocatorHintView = .{};
    var override = locatorView(override_loc, &no_hints);
    try expectOk(cd.glowcap_host_session_set_exporter_location(pair.b, &override));
    var malformed = override;
    malformed.abi_version = 0;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_session_set_exporter_location(pair.b, &malformed));
    try expectOk(cd.glowcap_host_session_set_exporter_location(pair.b, null));

    // A fetch whose resolve never arrives: the transport dies, the break
    // queues the vow's FAIL completion inside the call, and the drain routes
    // it with the reason.
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try std.testing.expect(!fetched.fired);

    // Local finish intent cannot hide a later physical transport loss. The
    // core remains the lifecycle authority and turns the unbounded wait into
    // terminal close when the adapter reports EOF.
    try expectOk(cd.glowcap_host_session_close(pair.a, &close_finish_unbounded, 100));
    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_session_lifecycle_state(pair.a, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_FINISHING, state);
    try expectOk(cd.glowcap_host_session_transport_closed(pair.a, "transport gone", 14));
    _ = try drainActions(&hosts, &dials, &watches);
    try expectOk(cd.glowcap_host_session_lifecycle_state(pair.a, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try std.testing.expect(fetched.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_BREAK, fetched.kind);
    try std.testing.expectEqualStrings("transport gone", fetched.msg[0..fetched.msg_len]);
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CLOSED,
        cd.glowcap_host_session_fetch(pair.a, "too-late", 8, &refused_vow),
    );
}

test "libglowcap_host: transport_closed admits reconnect before dead handle release" {
    const host = try newHost(0x53);
    defer _ = cd.glowcap_host_release(host);
    const designator = "127.0.0.1:7013";
    var first: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, designator, designator.len, &first));
    try expectOk(cd.glowcap_host_session_transport_closed(first, "transport gone", 14));

    var again: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, designator, designator.len, &again));
    try expectOk(cd.glowcap_host_session_release(again));
    try expectOk(cd.glowcap_host_session_release(first));
}

const NestedEchoCtx = struct { self_ref: c.GlowcapReference = .{ .id = 0 } };

/// The inner behavior of the composed-forward regression: before reading its
/// own args it fires a nested enqueueing verb whose marshalling shares the
/// instance's arg scratch, then echoes args[0]. If the nested marshal reset
/// that scratch, the echoed bytes would be the nested verb's payload, not the
/// forwarder's.
fn nestedEchoBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    const ec: *NestedEchoCtx = @ptrCast(@alignCast(ctx.?));
    const v = verb[0..verb_len];
    if (std.mem.eql(u8, v, "noop")) {
        out_reply.* = argBase();
        return c.GLOWCAP_OK;
    }
    if (!std.mem.eql(u8, v, "echo")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    // The nested verb's payload has the exact shape and byte length of the
    // forwarded payload, so a scratch reset would land these bytes exactly
    // where the live args' bytes sit.
    const clobber = [_]c.GlowcapArgument{argStr("XXXXXXXXXXXXXXXXXXXX")};
    const self_ref = ec.self_ref;
    if (cd.glowcap_host_turn_tell(turn, &self_ref, "noop", 4, &clobber, clobber.len) != c.GLOWCAP_OK)
        return c.GLOWCAP_ERR_INTERNAL;
    if (args_len != 1 or args.?[0].kind != c.GLOWCAP_ARG_STRING) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    out_reply.* = args.?[0];
    return c.GLOWCAP_OK;
}

const ForwarderCtx = struct { target_ref: c.GlowcapReference };

/// The outer behavior: forwards a fresh payload to the echo object through
/// turn_forward, marshalling that payload through the shared arg scratch.
fn forwarderBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    _ = .{ args, args_len };
    const fc: *ForwarderCtx = @ptrCast(@alignCast(ctx.?));
    if (!std.mem.eql(u8, verb[0..verb_len], "relay")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const target = fc.target_ref;
    const payload = [_]c.GlowcapArgument{argStr("the payload survives")};
    return cd.glowcap_host_turn_forward(turn, &target, "echo", 4, &payload, payload.len, out_reply);
}

test "libglowcap_host: a composed forward's inner behavior keeps its args across a nested verb" {
    const client = try newHost(0xa1);
    defer _ = cd.glowcap_host_release(client);
    const server = try newHost(0xa2);
    defer _ = cd.glowcap_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var echo_ctx = NestedEchoCtx{};
    var echo_local_ref: c.GlowcapReference = .{ .id = 0 };
    try expectOk(cd.glowcap_host_session_spawn(pair.b, nestedEchoBehavior, &echo_ctx, null, &echo_local_ref));
    echo_ctx.self_ref = echo_local_ref;
    var fwd_ctx = ForwarderCtx{ .target_ref = echo_local_ref };
    var fwd_local_ref: c.GlowcapReference = .{ .id = 0 };
    try expectOk(cd.glowcap_host_session_publish(pair.b, "relay", 5, forwarderBehavior, &fwd_ctx, null, &fwd_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(pair.a, "relay", 5, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const relay_ref = try fetched.requireRef();

    // The forwarded answer must carry the forwarder's own payload, proving
    // the inner behavior's live args survived its nested tell.
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_send(pair.a, &relay_ref, "relay", 5, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("the payload survives", settled.text[0..settled.text_len]);

    // A local eventual send forwards through the same queue authority. The
    // queued args must survive the inner behavior's nested tell. The Host
    // drives both turns inside this call; completion waits on the action queue
    // for the watch registered right after.
    const fwd_ref = fwd_local_ref;
    var near_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_send(pair.b, &fwd_ref, "relay", 5, null, 0, &near_vow));
    var near_settled = CapturedSettle{};
    watches.add(server, near_vow, &near_settled);
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(near_settled.fired);
    try std.testing.expectEqual(c.GLOWCAP_RESOLUTION_FULFILL, near_settled.kind);
    try std.testing.expectEqualStrings("the payload survives", near_settled.text[0..near_settled.text_len]);
}

test "libglowcap_host: feed_bytes stops at the session-open transition so a coalesced tail waits for post-open setup" {
    const client = try newHost(0xb1);
    defer _ = cd.glowcap_host_release(client);
    const server = try newHost(0xb2);
    defer _ = cd.glowcap_host_release(server);

    const designator = "127.0.0.1:7007";
    try ensureAdvertisedLocator(client, "tcp");
    try setAdvertisedLocator(server, tcpLocator(designator));
    var accepted: ?*cd.GlowcapHostSession = null;
    try expectOk(openAccepted(server, "tcp", 3, &accepted));
    var dialed: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(client, "tcp", 3, designator.ptr, designator.len, &dialed));

    // Open the client side first: feed it the server's hello whole.
    var server_hello: c.GlowcapManagedFrame = undefined;
    try expectOk(takeOutbound(accepted, &server_hello));
    const borrowed_hello: c.GlowcapFrame = .{ .bytes = server_hello.bytes, .len = server_hello.len, .shape = server_hello.shape };
    try expectOk(cd.glowcap_host_session_feed(dialed, &borrowed_hello));
    c.glowcap_managed_frame_release(&server_hello);
    try std.testing.expect(cd.glowcap_host_session_is_open(dialed) != 0);

    // The client fetches before the server has seen a single byte: its
    // outbound is now [hello][fetch deliver, ...], the coalesced buffer a
    // batching transport hands the server in one read.
    var fetch_vow: u64 = 0;
    try expectOk(cd.glowcap_host_session_fetch(dialed, "widget", 6, &fetch_vow));
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var frames: usize = 0;
    while (true) {
        var mf: c.GlowcapManagedFrame = undefined;
        const rc = takeOutbound(dialed, &mf);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        defer c.glowcap_managed_frame_release(&mf);
        var prefix_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
        const prefix = stream_framing.renderPrefix(&prefix_buf, mf.len);
        @memcpy(buf[len..][0..prefix.len], prefix);
        len += prefix.len;
        @memcpy(buf[len..][0..mf.len], mf.bytes.?[0..mf.len]);
        len += mf.len;
        frames += 1;
    }
    try std.testing.expect(frames >= 2);

    // One feed of the whole buffer dispatches exactly the hello: the session
    // just opened, and the frames coalesced behind it wait in the session's
    // own tail, the fetch has not answered, because its target is not
    // published yet. status-allow: pending state or quoted runtime label
    try expectOk(cd.glowcap_host_session_feed_bytes(accepted, &buf, len));
    try std.testing.expect(cd.glowcap_host_session_is_open(accepted) != 0);

    // The embedder acts on the fresh session, publish, then asks the Host
    // to resume retained input, and the fetch that rode behind the hello
    // answers correctly.
    var counter = Counter{};
    var widget_local_ref: c.GlowcapReference = .{ .id = 0 };
    try expectOk(cd.glowcap_host_session_publish(accepted, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));
    try expectOk(cd.glowcap_host_session_resume_feed(accepted));

    var dials = Dials{};
    var watches = Watches{};
    var fetched = CapturedSettle{};
    watches.add(client, fetch_vow, &fetched);
    const hosts = [_]?*cd.GlowcapHost{ client, server };
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(&hosts, &.{pair}, &dials, &watches);
    _ = try fetched.requireRef();
}
