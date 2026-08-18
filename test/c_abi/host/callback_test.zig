//! What a behavior may do from inside a callback: top-level verbs refuse,
//! enqueueing verbs land at the unwind, a refused pump preserves its exact
//! action for retry, and a deferred resolver settle re-enters top-level
//! (ADR-0102).

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

/// The reentry probe's shared state: the behavior below runs inside a served
/// turn and records whether every top-level verb refused and every
/// enqueueing verb succeeded.
const ReentryCtx = struct {
    host: ?*cd.PancakeHost = null,
    session: ?*cd.PancakeHostSession = null,
    widget_local_ref: c.PancakeReference = .{ .id = 0 },
    watches: *Watches = undefined,
    ran: bool = false,
    all_refused: bool = false,
    enqueued_ok: bool = false,
    nested: CapturedSettle = .{},
};

/// From inside the callback window, every host-driving verb must refuse
/// (INVALID_ARGUMENT, or last-error for the void releases) and every
/// enqueueing verb must succeed, its effects landing at the unwind.
fn reentryBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ turn, verb, verb_len, args, args_len };
    const rc: *ReentryCtx = @ptrCast(@alignCast(ctx.?));
    rc.ran = true;
    const inv = c.PANCAKE_ERR_INVALID_ARGUMENT;
    var ok = true;

    const garbage = "x";
    const borrowed: c.PancakeFrame = .{ .bytes = @constCast(garbage.ptr), .len = garbage.len, .shape = c.PANCAKE_FRAME_SHAPE_BYTE };
    ok = ok and cd.pancake_host_session_feed(rc.session, &borrowed) == inv;
    ok = ok and cd.pancake_host_session_feed_bytes(rc.session, garbage.ptr, garbage.len) == inv;
    var mf: c.PancakeManagedFrame = undefined;
    ok = ok and takeOutbound(rc.session, &mf) == inv;
    var action: cd.PancakeHostAction = undefined;
    ok = ok and cd.pancake_host_next_action(rc.host, &action) == inv;
    ok = ok and cd.pancake_host_dialed(rc.host, 0, rc.session) == inv;
    ok = ok and cd.pancake_host_dial_failed(rc.host, 0, "x", 1) == inv;
    ok = ok and cd.pancake_host_provide_gift_id(rc.host, 0, "x", 1) == inv;
    var new_session: ?*cd.PancakeHostSession = null;
    ok = ok and openDialed(rc.host, "tcp", 3, "d", 1, &new_session) == inv;
    ok = ok and openAccepted(rc.host, "tcp", 3, &new_session) == inv;
    var refused_ref: c.PancakeReference = .{ .id = 0 };
    ok = ok and cd.pancake_host_session_publish(rc.session, "n", 1, widgetBehavior, null, null, &refused_ref) == inv;
    ok = ok and cd.pancake_host_session_spawn(rc.session, widgetBehavior, null, null, &refused_ref) == inv;
    ok = ok and cd.pancake_host_publish(rc.host, "n", 1, widgetBehavior, null, null) == inv;
    var refused_vow: u64 = 0;
    ok = ok and cd.pancake_host_session_fetch(rc.session, "n", 1, &refused_vow) == inv;
    ok = ok and cd.pancake_host_session_enliven(rc.session, "n", 1, &refused_vow) == inv;
    ok = ok and cd.pancake_host_session_break_far_vows(rc.session, "x", 1) == inv;
    ok = ok and cd.pancake_host_session_transport_closed(rc.session, "x", 1) == inv;
    // The void releases refuse through the last-error slot and keep the
    // handles alive.
    cd.pancake_host_clear_last_error();
    _ = cd.pancake_host_session_release(rc.session);
    ok = ok and cd.pancake_host_last_error(null, 0) > 0;
    cd.pancake_host_clear_last_error();
    _ = cd.pancake_host_release(rc.host);
    ok = ok and cd.pancake_host_last_error(null, 0) > 0;
    rc.all_refused = ok;

    // The enqueueing verbs: a nested near send whose local vow is still live
    // inside this window, so a projection refuses NotPipelineable (a local
    // vow has no wire answer); the turn settles them at the unwind, and the
    // watch registered here routes the vow's queued completion.
    const near = rc.widget_local_ref;
    var vow: u64 = 0;
    var eok = cd.pancake_host_session_send(rc.session, &near, "poke", 4, null, 0, &vow) == c.PANCAKE_OK;
    if (eok) rc.watches.add(rc.host, vow, &rc.nested);
    var projected: u64 = 0;
    eok = eok and cd.pancake_host_vow_index(rc.host, vow, 0, &projected) == inv;
    eok = eok and cd.pancake_host_session_tell(rc.session, &near, "poke", 4, null, 0) == c.PANCAKE_OK;
    eok = eok and cd.pancake_host_session_set_exporter_location(rc.session, null) == c.PANCAKE_OK;
    rc.enqueued_ok = eok;

    out_reply.* = argStr("probed");
    return c.PANCAKE_OK;
}

test "libpancake_host: inside a callback every top-level verb refuses and every enqueueing verb lands at the unwind" {
    const client = try newHost(0x71);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x72);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7001", &dials, &watches);

    var counter = Counter{};
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, &counter, null, &widget_local_ref));
    var rctx = ReentryCtx{ .host = server, .session = pair.b, .widget_local_ref = widget_local_ref, .watches = &watches };
    var probe_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "probe", 5, reentryBehavior, &rctx, null, &probe_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "probe", 5, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const probe_ref = try fetched.requireRef();

    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &probe_ref, "go", 2, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);

    try std.testing.expect(rctx.ran);
    try std.testing.expect(rctx.all_refused);
    try std.testing.expect(rctx.enqueued_ok);
    // The probe's own reply reached the caller, so the refusals broke nothing.
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("probed", settled.text[0..settled.text_len]);
    // The nested send and tell both landed at the unwind, and the nested
    // vow's settle fired.
    try std.testing.expect(rctx.nested.fired);
    try std.testing.expectEqualStrings("poked over the C surface", rctx.nested.text[0..rctx.nested.text_len]);
    try std.testing.expectEqual(@as(u32, 2), counter.pokes);
}

/// One direction's staging buffer for the feed_bytes shuttle: the encoded
/// frames awaiting their chunked presentation. The library owns the
/// unconsumed stream tail, so nothing carries over between rounds.
const PumpRetryCtx = struct {
    calls: usize = 0,
    tickets: [2]u64 = undefined,
};

fn refuseFirstPumpArm(
    raw: ?*anyopaque,
    _: ?*cd.PancakeHost,
    action: *const cd.PancakeHostAction,
    out_progressed: ?*u32,
) callconv(.c) i32 {
    const ctx: *PumpRetryCtx = @ptrCast(@alignCast(raw.?));
    ctx.tickets[ctx.calls] = action.ticket;
    ctx.calls += 1;
    if (ctx.calls == 1) return c.PANCAKE_ERR_IO;
    if (out_progressed) |progressed| progressed.* = 1;
    return c.PANCAKE_OK;
}

test "libpancake_host: pump callback refusal preserves the exact action for retry" {
    const client = try newHostWithProfile(0x35, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_NEXT);
    defer _ = cd.pancake_host_release(client);

    const sturdyref = "ocapn://127.0.0.1%3A7025.tcp/s/widget";
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(client, sturdyref, sturdyref.len, &vow));

    var ctx = PumpRetryCtx{};
    const hooks = cd.PancakeHostPumpHooks{
        .ctx = &ctx,
        .flush = null,
        .close = null,
        .need_gift_id = null,
        .complete = null,
        .dial = refuseFirstPumpArm,
    };
    var acted: u32 = 0;
    var yielded: u32 = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_IO,
        cd.pancake_host_pump_drain(client, &hooks, &acted, &yielded),
    );
    try expectOk(cd.pancake_host_pump_drain(client, &hooks, &acted, &yielded));
    try std.testing.expectEqual(@as(usize, 2), ctx.calls);
    try std.testing.expectEqual(ctx.tickets[0], ctx.tickets[1]);
    try std.testing.expectEqual(@as(u32, 1), acted);
}

/// A behavior that defers its answer onto a resolver vow (ADR-0102): it
/// atomically defers the turn, proves the in-turn settle refuses, and
/// parks the resolver id for the test body — the stand-in for a worker that
/// completes off-turn.
const DeferCtx = struct {
    host: ?*cd.PancakeHost = null,
    resolver_id: u64 = 0,
};

fn deferringBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.PancakeArgument,
    args_len: usize,
    out_reply: *c.PancakeArgument,
) callconv(.c) i32 {
    _ = .{ args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "work")) return c.PANCAKE_ERR_INVALID_ARGUMENT;
    const state: *DeferCtx = @ptrCast(@alignCast(ctx.?));
    var resolver_id: u64 = 0;
    const deferred = cd.pancake_host_turn_defer(turn, &resolver_id);
    if (deferred != c.PANCAKE_OK) return deferred;
    // A settle from inside the turn must refuse: the worker's completion
    // re-enters top-level only.
    var premature = argStr("early");
    if (cd.pancake_host_resolver_fulfill(state.host, resolver_id, &premature) == c.PANCAKE_OK)
        return c.PANCAKE_ERR_INTERNAL;
    state.resolver_id = resolver_id;
    out_reply.* = argBase();
    return c.PANCAKE_OK;
}

test "libpancake_host: a behavior defers onto a resolver vow, and the settle re-enters top-level (ADR-0102)" {
    const client = try newHost(0x71);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x72);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7031", &dials, &watches);

    var state = DeferCtx{ .host = server };
    var worker_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(pair.b, "worker", 6, deferringBehavior, &state, null, &worker_local_ref));

    var fetched = CapturedSettle{};
    var fetched_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "worker", 6, &fetched_vow));
    watches.add(client, fetched_vow, &fetched);
    try pump(&hosts, &.{pair}, &dials, &watches);
    const worker_ref = try fetched.requireRef();

    // The behavior returns and every wire quiesces, yet the answer is still
    // open: the deferral holds it for the resolver.
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &worker_ref, "work", 4, null, 0, &vow));
    var settled = CapturedSettle{};
    watches.add(client, vow, &settled);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(!settled.fired);
    try std.testing.expect(state.resolver_id != 0);

    // Plain data only: a settle whose value names a capability refuses whole.
    var cap_value = argRef(worker_ref);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_resolver_fulfill(server, state.resolver_id, &cap_value),
    );

    // The worker completes: the settle re-enters top-level, the deferred wire
    // answer resolves, and the partner hears it.
    var value = argStr("computed off-turn");
    try expectOk(cd.pancake_host_resolver_fulfill(server, state.resolver_id, &value));
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(settled.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, settled.kind);
    try std.testing.expectEqualStrings("computed off-turn", settled.text[0..settled.text_len]);

    // One attempt: the resolver is consumed.
    var late = argStr("late");
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_resolver_fulfill(server, state.resolver_id, &late),
    );

    // A second deferral settles broken, and the partner hears the worker's
    // own words.
    var second_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(pair.a, &worker_ref, "work", 4, null, 0, &second_vow));
    var broke = CapturedSettle{};
    watches.add(client, second_vow, &broke);
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(!broke.fired);
    try expectOk(cd.pancake_host_resolver_break(server, state.resolver_id, "worker gave up", 14));
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(broke.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, broke.kind);
    try std.testing.expectEqualStrings("worker gave up", broke.msg[0..broke.msg_len]);
}
