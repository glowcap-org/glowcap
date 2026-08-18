//! The application verbs over the byte shuttle: keyed session open, the
//! bounded trace, malformed-frame classification, publish, fetch, send and
//! tell, projected release, and the codec and budget options. Typed values
//! live in `values_test.zig`; the turn verbs and pipelining in
//! `turn_test.zig`.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const pancake = @import("pancake");
const model = pancake.ocapn.model;
const keyed_relay = pancake.net.relay;
const stream_framing = pancake.foundation.stream_framing;

const harness = @import("harness.zig");
const behaviors = @import("behaviors.zig");
const argBase = harness.argBase;
const argInt = harness.argInt;
const argStr = harness.argStr;
const argRef = harness.argRef;
const frame_cap = harness.frame_cap;
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

test "libpancake_host: two byte-fed hosts open a keyed session through the C surface (ADR-0072)" {
    var context: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    // The dialer allocates through a context, the acceptor through the
    // library allocator, so both constructors are exercised.
    var dialer: ?*cd.PancakeHost = null;
    const dialer_seed = hostSeed(0x0a);
    try expectOk(cd.pancake_host_new_in(context, &dialer_seed, dialer_seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &dialer));
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x0b);
    defer _ = cd.pancake_host_release(acceptor);
    var dialer_diagnostic_id: u64 = 0;
    var acceptor_diagnostic_id: u64 = 99;
    try expectOk(cd.pancake_host_diagnostic_id(dialer, &dialer_diagnostic_id));
    try expectOk(cd.pancake_host_diagnostic_id(acceptor, &acceptor_diagnostic_id));
    try std.testing.expectEqual(@as(u64, 1), dialer_diagnostic_id);
    try std.testing.expectEqual(@as(u64, 0), acceptor_diagnostic_id);

    // The dialer also listens, so its complete reachable locator is the route
    // its hellos advertise.
    try setAdvertisedLocator(dialer, tcpLocator("127.0.0.1:9999"));

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7001", &dials, &watches);
    try std.testing.expectEqual(@as(usize, 0), dials.len);

    // Quiescent: nothing queued on either side, on either channel.
    var mf: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, takeOutbound(pair.a, &mf));
    var action: cd.PancakeHostAction = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_next_action(dialer, &action));

    // Connections release before their hosts.
    _ = cd.pancake_host_session_release(pair.a);
    _ = cd.pancake_host_session_release(pair.b);
}

test "libpancake_host: the drained trace reports the same facts the callback does, bounded" {
    // The seam for an embedder that cannot hand the library a function
    // pointer: a browser, whose wasm module declares exactly one import. The
    // facts are the core's either way, so the queue has to carry what the
    // callback carries — the open with its wire name, both message
    // directions, the close — and it has to stay bounded, which the callback
    // never had to be.
    //
    // What this cannot see: clearing the queue while no callback is installed
    // must also drop the core's sink, and it does, but leaving the sink in
    // place would only cost a pointless call per fact and captures nothing, so
    // no assertion here can tell the two apart.
    const dialer = try newHost(0x31);
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x32);
    defer _ = cd.pancake_host_release(acceptor);

    // One record and a small payload window: far under one session's traffic,
    // so the drop path and the clip path are the ordinary case here rather
    // than contrivances.
    try expectOk(cd.pancake_host_set_trace_queue(dialer, 1, 96));
    // A zero payload window is refused rather than silently storing nothing.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_set_trace_queue(acceptor, 2, 0),
    );
    try expectOk(cd.pancake_host_set_trace_queue(acceptor, 16, 4096));

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7003", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    // A failed replacement is transactional: overflow is refused and the
    // already-captured open remains in the original one-slot queue.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_set_trace_queue(dialer, std.math.maxInt(usize), 2),
    );

    try expectOk(cd.pancake_host_publish(acceptor, "widget", 6, widgetBehavior, null, null));
    var fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetch_vow));
    try pump(&hosts, &.{pair}, &dials, &watches);

    // The acceptor's roomy queue: the open carries the OCapN Session ID and
    // both halves of the partner's locator, and the fetch's deliver is a
    // message row whose whole frame fit the window.
    var ev: cd.PancakeTraceEvent = undefined;
    var acceptor_session_id_len: usize = 0;
    var acceptor_transport_len: usize = 0;
    var messages: usize = 0;
    while (cd.pancake_host_next_trace(acceptor, &ev) == c.PANCAKE_OK) {
        try std.testing.expectEqual(@as(u64, 0), ev.dropped);
        if (ev.kind == cd.PANCAKE_TRACE_SESSION_OPEN) {
            acceptor_session_id_len = ev.session_id_len;
            acceptor_transport_len = ev.transport_len;
            try std.testing.expect(ev.designator_len > 0);
        } else if (ev.kind == cd.PANCAKE_TRACE_MESSAGE) {
            messages += 1;
            try std.testing.expectEqual(ev.frame_total_len, ev.frame_len);
            try std.testing.expect(ev.frame_len > 0);
        }
    }
    try std.testing.expectEqual(@as(usize, 64), acceptor_session_id_len);
    // The transport is carried through the ring beside the designator, so a
    // consumer can rebuild the locator rather than half of one.
    try std.testing.expect(acceptor_transport_len > 0);
    try std.testing.expect(messages > 0);
    // Drained empty reports WOULD_BLOCK, so a drain loop terminates.
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_next_trace(acceptor, &ev));

    // The dialer's one-slot queue kept the OLDEST fact and dropped the rest.
    // The open is what a consumer keys everything else by, so a full ring
    // drops the newest record rather than the causal prefix.
    try expectOk(cd.pancake_host_next_trace(dialer, &ev));
    try std.testing.expectEqual(cd.PANCAKE_TRACE_SESSION_OPEN, ev.kind);
    try std.testing.expectEqual(@as(usize, 64), ev.session_id_len);
    try std.testing.expectEqual(@as(u64, 0), ev.dropped);
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_next_trace(dialer, &ev));

    // What the ring could not hold is reported as a gap on the next record it
    // does capture, so a consumer reads the break instead of inventing
    // continuity. That record is a message, and a 96-byte window cannot hold a
    // whole frame beside the verb, so it also reports its true length rather
    // than understating it.
    var fetch_again: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetch_again));
    try pump(&hosts, &.{pair}, &dials, &watches);
    try expectOk(cd.pancake_host_next_trace(dialer, &ev));
    try std.testing.expectEqual(cd.PANCAKE_TRACE_MESSAGE, ev.kind);
    try std.testing.expect(ev.dropped > 0);
    try std.testing.expect(ev.frame_total_len > ev.frame_len);

    // Clearing frees the ring; nothing is captured afterwards.
    try expectOk(cd.pancake_host_set_trace_queue(dialer, 0, 0));
    var fetch_third: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetch_third));
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_next_trace(dialer, &ev));
}

test "libpancake_host: a malformed frame classifies CODEC, session_last_abort names it, and the partner retains the abort" {
    const dialer = try newHost(0x11);
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x12);
    defer _ = cd.pancake_host_release(acceptor);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7001", &dials, &watches);

    // No abort yet, on either accessor.
    var abort_info: c.PancakeLastAbort = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_last_abort(pair.b, &abort_info));
    var kind_name: ?[*]const u8 = null;
    var kind_name_len: usize = 0;
    var partner_msg: [160]u8 = undefined;
    var partner_len: usize = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, cd.pancake_host_session_partner_abort(pair.a, &kind_name, &kind_name_len, &partner_msg, partner_msg.len, &partner_len));

    // Attacker-shaped input: not a Syrup frame at all. The classified code
    // must be CODEC (the shared taxonomy), never a flattened SESSION.
    const garbage = "not a syrup frame";
    const borrowed: c.PancakeFrame = .{ .bytes = @constCast(garbage.ptr), .len = garbage.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    try std.testing.expectEqual(c.PANCAKE_ERR_CODEC, cd.pancake_host_session_feed(pair.b, &borrowed));

    // The cause is readable through the family's own error channel. A later
    // undetailed refusal clears it rather than borrowing that cause.
    var err_buf: [128]u8 = undefined;
    try std.testing.expect(cd.pancake_host_last_error(&err_buf, err_buf.len) > 0);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cd.pancake_host_diagnostic_id(null, null),
    );
    try std.testing.expectEqual(@as(usize, 0), cd.pancake_host_last_error(&err_buf, err_buf.len));

    // The typed cause is retained on the failing side.
    try expectOk(cd.pancake_host_session_last_abort(pair.b, &abort_info));
    try std.testing.expectEqual(c.PANCAKE_ABORT_DOMAIN_CODEC, abort_info.domain);
    try std.testing.expect(abort_info.has_kind != 0);

    // The failure is loud on the wire: a typed op:abort is queued for the
    // partner, and once fed the partner retains kind and diagnostic.
    var mf: c.PancakeManagedFrame = undefined;
    try expectOk(takeOutbound(pair.b, &mf));
    const abort_frame: c.PancakeFrame = .{ .bytes = mf.bytes, .len = mf.len, .shape = mf.shape };
    _ = cd.pancake_host_session_feed(pair.a, &abort_frame);
    c.pancake_managed_frame_release(&mf);
    try expectOk(cd.pancake_host_session_partner_abort(pair.a, &kind_name, &kind_name_len, &partner_msg, partner_msg.len, &partner_len));
    try std.testing.expect(kind_name_len > 0);
    try std.testing.expectEqualStrings("MalformedFrame", kind_name.?[0..kind_name_len]);
}

test "libpancake_host: publish, fetch, send, tell, and the enliven cache hit's pre-queued completion" {
    const client = try newHost(0x21);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x22);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));

    // Fetch arrives already enrolled as a node-unique token.
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const widget_ref = try fetched.requireRef();

    // A send through the token settles with the served reply, drained as the
    // vow's SETTLE action.
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // Fire-and-forget still runs the served turn.
    try expectOk(cd.pancake_host_session_tell(pair.a, &widget_ref, "poke", 4, null, 0));
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expectEqual(@as(u32, 2), counter.pokes);

    // The empty verb is a real message — Goblins invokes a capability
    // positionally with verb "" — and the family's `ptr + len` contract admits
    // `(null, 0)` as the empty view, which is exactly what a wasm caller
    // stages for an empty buffer. The call must be accepted at the ABI seam
    // and travel to the behavior, which refuses the verb *there* (a broken
    // reply), not as a NullPointer at the boundary.
    var empty_verb_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, null, 0, null, 0, &empty_verb_vow));
    var empty_verb_settled = CapturedSettle{};
    watches.add(client, empty_verb_vow, &empty_verb_settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(empty_verb_settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, empty_verb_settled.kind);

    // A fresh enliven rides the wire; the second one hits the dedup cache and
    // its completion is queued before the registering call returns — no wire
    // traffic, just the next drain.
    const sturdyref = "ocapn://127.0.0.1%3A7001.tcp/s/d2lkZ2V0";
    const wrong_peer = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_session_enliven(pair.a, wrong_peer, wrong_peer.len, &refused_vow),
    );
    var no_fetch: c.PancakeManagedFrame = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_WOULD_BLOCK, takeOutbound(pair.a, &no_fetch));
    var enlivened = CapturedSettle{};
    var enlivened_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_enliven(pair.a, sturdyref, sturdyref.len, &enlivened_vow));
    watches.add(client, enlivened_vow, &enlivened);
    try std.testing.expect(!enlivened.fired);
    try pump(&hosts, &.{pair}, &dials, &watches);
    _ = try enlivened.requireRef();
    var cache_hit = CapturedSettle{};
    var cache_hit_vow: u64 = 0;
    const same_peer_new_hints = "ocapn://127.0.0.1%3A7001.tcp/s/d2lkZ2V0?route=changed";
    try expectOk(cd.pancake_host_session_enliven(pair.a, same_peer_new_hints, same_peer_new_hints.len, &cache_hit_vow));
    watches.add(client, cache_hit_vow, &cache_hit);
    try std.testing.expect(!cache_hit.fired);
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(cache_hit.fired);
    _ = try cache_hit.requireRef();

    // Listen on a capability this session holds (`op:listen` through the C
    // seam): CapTP answers a listen on an already-settled capability at once,
    // so the vow settles naming the same object — proof the round trip ran.
    // The vow is plain, and it rides the same SETTLE drain as every other.
    var listened = CapturedSettle{};
    var listen_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_listen(pair.a, &widget_ref, &listen_vow));
    watches.add(client, listen_vow, &listened);
    try std.testing.expect(!listened.fired);
    try pump(&hosts, &.{pair}, &dials, &watches);
    _ = try listened.requireRef();

    // The seam's own refusals: a null target or vow slot never reaches the
    // core (the InvalidReference semantics for a bad target are pinned at the
    // core tier, `test/driver/core_host_test.zig`).
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cd.pancake_host_session_listen(pair.a, null, &listen_vow),
    );
    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cd.pancake_host_session_listen(pair.a, &widget_ref, null),
    );
}

test "libpancake_host: a projected reference releases after its home session closes" {
    const client = try newHost(0x23);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x24);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7002", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.b);

    var counter = Counter{};
    var local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &local_ref));

    var fetched = CapturedSettle{};
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &vow));
    watches.add(client, vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const remote_ref = try fetched.requireRef();

    // Closing the home invalidates use immediately, but teardown already
    // reclaimed the wire import. The application unit therefore retains one
    // release-only recipient instead of turning a later finalizer into a
    // permanent NOT_FOUND retry.
    try expectOk(cd.pancake_host_session_release(pair.a));
    try expectOk(cd.pancake_host_ref_release(client, &remote_ref, 1));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_ref_release(client, &remote_ref, 1));
}

test "libpancake_host: a nonzero local_turn_budget constructs a host (ADR-0076)" {
    var host: ?*cd.PancakeHost = null;
    const seed = hostSeed(0x41);
    try expectOk(cd.pancake_host_new(&seed, seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 64, &host));
    defer _ = cd.pancake_host_release(host);
    // 0 remains the unbounded default; a second host with 0 still constructs.
    const unbounded = try newHost(0x42);
    defer _ = cd.pancake_host_release(unbounded);
}

test "libpancake_host: a zero frame cap is refused before allocation" {
    var host: ?*cd.PancakeHost = null;
    const seed = hostSeed(0x43);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_new(&seed, seed.len, 0, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &host),
    );
    try std.testing.expect(host == null);
}

test "libpancake_host: the host codec option carries a Cap'n Proto session end to end" {
    // Selectors outside their C ABI families are refused before allocation.
    var refused: ?*cd.PancakeHost = null;
    const seed = hostSeed(0x31);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_new(&seed, seed.len, frame_cap, 1, c.PANCAKE_CODEC_UNKNOWN, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &refused));
    try std.testing.expect(refused == null);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_new(&seed, seed.len, frame_cap, 1, 99, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &refused));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_new(&seed, seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, 99, c.PANCAKE_FEATURE_FULL, 0, &refused));
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cd.pancake_host_new(&seed, seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL + 1, 0, &refused));

    const client = try newHostWith(0x31, c.PANCAKE_CODEC_CAPNP);
    defer _ = cd.pancake_host_release(client);
    const server = try newHostWith(0x32, c.PANCAKE_CODEC_CAPNP);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };

    // Open the halves by hand so the dialer's first outbound frame can be
    // inspected. The hello is Syrup even on a Cap'n Proto session, so it opens
    // with Syrup's record byte rather than a capnp segment table: a handshake
    // cannot be encoded in the codec the handshake settles, the same rule
    // `codec.signed` states for signed bytes. What the codec option carries is
    // the session, which this test goes on to prove by messaging over it.
    const designator = "127.0.0.1:7002";
    try ensureAdvertisedLocator(client, "tcp");
    try setAdvertisedLocator(server, tcpLocator(designator));
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(server, "tcp", 3, &accepted));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(openDialed(client, "tcp", 3, designator.ptr, designator.len, &dialed));
    var hello: c.PancakeManagedFrame = undefined;
    try expectOk(takeOutbound(dialed, &hello));
    try std.testing.expect(hello.len >= 8);
    try std.testing.expectEqual(@as(u8, '<'), hello.bytes.?[0]);
    const borrowed: c.PancakeFrame = .{ .bytes = hello.bytes, .len = hello.len, .shape = hello.shape };
    try expectOk(cd.pancake_host_session_feed(accepted, &borrowed));
    c.pancake_managed_frame_release(&hello);
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);
    try std.testing.expect(cd.pancake_host_session_is_open(accepted) != 0);

    // A publish/fetch/send round-trip carries through the capnp session.
    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &widget_local_ref));
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "widget", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const widget_ref = try fetched.requireRef();
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);
}
