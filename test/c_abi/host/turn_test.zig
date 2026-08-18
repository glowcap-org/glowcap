//! The caretaker's turn verbs and promise pipelining over the byte
//! shuttle: turn_forward, turn_send, and turn_tell behind a caretaker,
//! turn_spawn minting a capability mid-turn, turn_break carrying the
//! refusal's own words, and vow_send/index/untag/get against answers that
//! do not exist yet — with the baseline peer's outbound-untag refusal.

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

test "libpancake_host: a spawned object behind a caretaker — turn_forward, turn_send, turn_tell" {
    const client = try newHost(0x31);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x32);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    // The wrapped object has no fetchable name; only the caretaker is
    // published, and it reaches the widget through the turn verbs.
    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var caretaker_ctx = CaretakerCtx{ .target_ref = widget_local_ref };
    var caretaker_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "caretaker", 9, caretakerBehavior, &caretaker_ctx, null, &caretaker_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "caretaker", 9, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const caretaker_ref = try fetched.requireRef();

    // Forwarded call: the caretaker's own answer settles on the widget's reply.
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &caretaker_ref, "poke", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("poked over the C surface", settled.text[0..settled.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // The turn's own send and tell each land one more poke.
    var kick_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &caretaker_ref, "kick", 4, null, 0, &kick_vow));
    var kicked = CapturedSettle{};
    watches.add(client, kick_vow, &kicked);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(kicked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, kicked.kind);
    try std.testing.expectEqual(@as(u32, 3), counter.pokes);
}

test "libpancake_host: turn_spawn mints a capability mid-turn, and turn_break carries the refusal's own words" {
    const client = try newHost(0x61);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x62);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var factory_ctx = FactoryCtx{ .counter = &counter, .expected_session = pair.b };
    var factory_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "factory", 7, factoryBehavior, &factory_ctx, null, &factory_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "factory", 7, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const factory_ref = try fetched.requireRef();

    // The served "make" spawns a widget inside its own turn and replies with
    // it; the reply's capability is live, so a follow-up poke lands.
    var make_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &factory_ref, "make", 4, null, 0, &make_vow));
    var made = CapturedSettle{};
    watches.add(client, make_vow, &made);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(made.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, made.kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, made.value.kind);
    try std.testing.expect(factory_ctx.saw_expected_session);
    const widget_ref = made.value.reference;

    var poke_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &widget_ref, "poke", 4, null, 0, &poke_vow));
    var poked = CapturedSettle{};
    watches.add(client, poke_vow, &poked);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(poked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, poked.kind);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);

    // A refusal through turn_break reaches the caller with the behavior's own
    // diagnostic, not a generic reason.
    var deny_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &factory_ref, "deny", 4, null, 0, &deny_vow));
    var denied = CapturedSettle{};
    watches.add(client, deny_vow, &denied);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(denied.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, denied.kind);
    try std.testing.expectEqualStrings("Attenuated", denied.msg[0..denied.msg_len]);
}

test "libpancake_host: promise pipelining — vow_send, vow_index, vow_untag, vow_get before the answers exist" {
    // `op:untag` is an OCapN 1.0 operation. Both Pancake peers advertise the
    // full feature set, so it remains legal on the baseline wire version; a
    // silent Goblins peer instead negotiates the baseline set without untag.
    const client = try newHostWithProfile(0x41, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0);
    defer _ = cd.pancake_host_release(client);
    const server = try newHostWithProfile(0x42, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var kitchen_ctx = KitchenCtx{ .widget_local_ref = widget_local_ref };
    var kitchen_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "kitchen", 7, kitchenBehavior, &kitchen_ctx, null, &kitchen_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "kitchen", 7, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const kitchen_ref = try fetched.requireRef();

    // All three chains register before a single frame moves: the sends ride
    // the answers, not the settled values.
    var make_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "make", 4, null, 0, &make_vow));
    var poked_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_send(client, make_vow, "poke", 4, null, 0, &poked_vow));
    var poked = CapturedSettle{};
    watches.add(client, poked_vow, &poked);

    var pair_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "pair", 4, null, 0, &pair_vow));
    var second_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_index(client, pair_vow, 1, &second_vow));
    var second = CapturedSettle{};
    watches.add(client, second_vow, &second);

    var boxed_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "boxed", 5, null, 0, &boxed_vow));
    var unboxed_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_untag(client, boxed_vow, "box", 3, &unboxed_vow));
    var unboxed = CapturedSettle{};
    watches.add(client, unboxed_vow, &unboxed);

    // vow_get mints against the still-pending list answer: C ABI cannot build
    // a Struct reply, so the projected vow breaks when the source settles.
    var get_vow: u64 = 0;
    try expectOk(cd.pancake_host_vow_get(client, pair_vow, "name", 4, &get_vow));
    var gotten = CapturedSettle{};
    watches.add(client, get_vow, &gotten);

    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(poked.fired);
    try std.testing.expectEqualStrings("poked over the C surface", poked.text[0..poked.text_len]);
    try std.testing.expect(second.fired);
    try std.testing.expectEqual(c.PANCAKE_ARG_INTEGER, second.value.kind);
    try std.testing.expectEqual(@as(i64, 22), second.value.integer);
    try std.testing.expect(unboxed.fired);
    try std.testing.expectEqual(c.PANCAKE_ARG_INTEGER, unboxed.value.kind);
    try std.testing.expectEqual(@as(i64, 7), unboxed.value.integer);
    try std.testing.expect(gotten.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, gotten.kind);

    // A NEAR send runs its turn inside the call, so its local vow settles
    // and retires before the caller can touch it: the projection reports the
    // row gone, the same NOT_FOUND a settled wire vow reports.
    const near_widget = widget_local_ref;
    var local_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.b, &near_widget, "poke", 4, null, 0, &local_vow));
    var refused_vow: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_vow_index(server, local_vow, 0, &refused_vow));
}

test "libpancake_host: a baseline peer refuses outbound untag before minting its projected vow" {
    const client = try newHostWithFeatures(
        0x43,
        c.PANCAKE_CODEC_SYRUP,
        c.PANCAKE_CAPTP_V1_0,
        c.PANCAKE_FEATURE_BASELINE,
    );
    defer _ = cd.pancake_host_release(client);
    const server = try newHostWithProfile(0x44, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7003", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var kitchen_ctx = KitchenCtx{ .widget_local_ref = widget_local_ref };
    var kitchen_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "kitchen", 7, kitchenBehavior, &kitchen_ctx, null, &kitchen_local_ref));
    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "kitchen", 7, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const kitchen_ref = try fetched.requireRef();

    var boxed_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &kitchen_ref, "boxed", 5, null, 0, &boxed_vow));
    var refused_vow: u64 = std.math.maxInt(u64);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_SESSION,
        cd.pancake_host_vow_untag(client, boxed_vow, "box", 3, &refused_vow),
    );
    try std.testing.expectEqual(std.math.maxInt(u64), refused_vow);
    var err_buf: [128]u8 = undefined;
    const err_len = cd.pancake_host_last_error(&err_buf, err_buf.len);
    try std.testing.expect(std.mem.indexOf(u8, err_buf[0..err_len], "FeatureNotNegotiated") != null);
}
