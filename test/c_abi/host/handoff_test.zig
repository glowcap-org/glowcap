//! Reaching a third party from C: the full three-party handoff with its one
//! DIAL action and routable token, the dial planner's per-transport shapes and
//! typed refusals, and select-or-dial enlivens riding, parking, and breaking.

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

/// Counts `PancakeHostCtxFree` runs, pinning the exactly-once contract.
const FreeFlag = struct {
    var runs: u32 = 0;
    fn cb(ctx: ?*anyopaque) callconv(.c) void {
        _ = ctx;
        runs += 1;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "libpancake_host: the full three-party handoff through the C surface — one dial action, a routable token" {
    const exporter = try newHost(0x0e);
    const gifter = try newHost(0x06);
    defer _ = cd.pancake_host_release(gifter);
    const recipient = try newHost(0x0c);
    defer _ = cd.pancake_host_release(recipient);
    const hosts = [_]?*cd.PancakeHost{ exporter, gifter, recipient };
    var dials = Dials{};
    var watches = Watches{};

    // The widget is published Host-wide before any connection exists. Fetch
    // lazily projects it on the gifter-facing Port; deposit captures that exact
    // actor in the Vat owned by the Host, and withdrawal later projects it on the
    // recipient-facing Port without consulting the alias again.
    var counter = Counter{};
    FreeFlag.runs = 0;
    try expectOk(cd.pancake_host_publish(exporter, "widget", 6, widgetBehavior, &counter, FreeFlag.cb));

    // Gifter dials the exporter and fetches the widget: the node records the
    // capability's foreign home, which is what the give will name.
    const g_to_e = try openPair(&hosts, gifter, exporter, "127.0.0.1:7001", &dials, &watches);
    var widget = CapturedSettle{};
    var widget_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(g_to_e.a, "widget", 6, &widget_vow));
    watches.add(gifter, widget_vow, &widget);
    try pump(&hosts, &.{g_to_e}, &dials, &watches);
    const widget_token = try widget.requireRef();

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(&hosts, recipient, gifter, "127.0.0.1:7002", &dials, &watches);
    var introducer_ctx = IntroducerCtx{ .widget = widget_token };
    var introducer_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(r_to_g.b, "introducer", 10, introducerBehavior, &introducer_ctx, null, &introducer_local_ref));
    var introducer = CapturedSettle{};
    var introducer_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(r_to_g.a, "introducer", 10, &introducer_vow));
    watches.add(recipient, introducer_vow, &introducer);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);
    const introducer_ref = try introducer.requireRef();

    // The introduction: the gifter's reply fulfills with a foreign-homed
    // capability, the gifter host originates the give (gift-id entropy
    // answered through its action queue), and the recipient host claims the
    // give and surfaces exactly one DIAL action naming the exporter.
    var introduce_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(r_to_g.a, &introducer_ref, "introduce", 9, null, 0, &introduce_vow));
    var redeemed = CapturedSettle{};
    watches.add(recipient, introduce_vow, &redeemed);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);

    try std.testing.expectEqual(@as(usize, 1), dials.len);
    const parked = dials.items[0];
    try std.testing.expect(parked.host == recipient);

    // Pending-row dial parts (ticket-only DIAL): this tcp give has only the
    // signed feature offer, never a fabricated transport route hint.
    try std.testing.expectEqualStrings("tcp", parked.transport[0..parked.transport_len]);
    try std.testing.expectEqualStrings("127.0.0.1:7001", parked.designator[0..parked.designator_len]);
    try std.testing.expectEqual(@as(usize, 1), parked.hint_count);

    // The test is the dial executor: open the recipient's own connection to
    // the exporter, drive it open, and report it back. The withdraw, its
    // settle, and the vow's fulfillment all pump inside the report. The
    // exporter publishes nothing on this session by hand — withdrawal projects
    // the exact deposited target onto this Port.
    var e_accepts_r: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(exporter, "tcp", 3, &e_accepts_r));
    var r_to_e: ?*cd.PancakeHostSession = null;
    try expectOk(openDialed(
        recipient,
        parked.transport[0..parked.transport_len].ptr,
        parked.transport_len,
        parked.designator[0..parked.designator_len].ptr,
        parked.designator_len,
        &r_to_e,
    ));
    const redeem_pair = Pair{ .a = r_to_e, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pump(&hosts, &all_pairs, &dials, &watches);
    try std.testing.expect(cd.pancake_host_session_is_open(r_to_e) != 0);
    try expectOk(cd.pancake_host_dialed(recipient, parked.ticket, r_to_e));
    try pump(&hosts, &all_pairs, &dials, &watches);

    try std.testing.expect(redeemed.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, redeemed.kind);
    try std.testing.expectEqual(c.PANCAKE_ARG_REFERENCE, redeemed.value.kind);
    const token = redeemed.value.reference;

    // An ordinary fetch over the exporter session that fulfilled the
    // withdrawal must converge with the handoff result immediately. The C
    // projection exposes that Host identity as an opaque scalar, so id
    // equality is the C Target-equality operation. Each occurrence still owns
    // one retain; releasing the direct occurrence leaves the token live.
    var direct = CapturedSettle{};
    var direct_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(r_to_e, "widget", 6, &direct_vow));
    watches.add(recipient, direct_vow, &direct);
    try pump(&hosts, &all_pairs, &dials, &watches);
    const direct_ref = try direct.requireRef();
    try std.testing.expectEqual(token.id, direct_ref.id);
    try expectOk(cd.pancake_host_ref_release(recipient, &direct_ref, 1));

    // The token routes: a send through it reaches the exporter's widget
    // directly, over the recipient's own connection. Its local capability
    // argument must therefore project on that routed connection, not on the
    // recipient-gifter session the application happened to call through.
    var local_argument: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(r_to_g.a, widgetBehavior, null, null, &local_argument));
    var routed_args = [_]c.PancakeArgument{argRef(local_argument)};
    var poke_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(r_to_g.a, &token, "poke", 4, &routed_args, routed_args.len, &poke_vow));
    var poked = CapturedSettle{};
    watches.add(recipient, poke_vow, &poked);
    try pump(&hosts, &all_pairs, &dials, &watches);
    try std.testing.expect(poked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_FULFILL, poked.kind);
    try std.testing.expectEqualStrings("poked over the C surface", poked.text[0..poked.text_len]);
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);
    try expectOk(cd.pancake_host_ref_release(recipient, &local_argument, 1));

    // The same foreign capability can now appear recursively in an ordinary C
    // value. Two occurrences become two one-shot gifts, but the gifter lifts
    // both local promises onto one eventual Host identity before invoking the
    // behavior. The C layer only decodes/encodes the common owning Value.
    var typed_capture = InlineCapabilityCapture{};
    var typed_local: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(
        r_to_g.b,
        "typed",
        5,
        inlineCapabilityBehavior,
        &typed_capture,
        null,
        &typed_local,
    ));
    var typed_target_capture = CapturedSettle{};
    var typed_fetch_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(r_to_g.a, "typed", 5, &typed_fetch_vow));
    watches.add(recipient, typed_fetch_vow, &typed_target_capture);
    try pump(&hosts, &all_pairs, &dials, &watches);
    const typed_target = try typed_target_capture.requireRef();

    const tagged_items = [_]c.PancakeArgument{argRef(token)};
    var tagged = argBase();
    tagged.kind = c.PANCAKE_ARG_TAGGED;
    tagged.bytes = "delegated";
    tagged.bytes_len = 9;
    tagged.items = tagged_items[0..].ptr;
    tagged.items_len = tagged_items.len;
    const struct_items = [_]c.PancakeArgument{
        argStr("target"),
        argRef(token),
    };
    var structured = argBase();
    structured.kind = c.PANCAKE_ARG_STRUCT;
    structured.items = struct_items[0..].ptr;
    structured.items_len = struct_items.len;
    const typed_args = [_]c.PancakeArgument{ tagged, structured };
    var foreign_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(
        r_to_g.a,
        &typed_target,
        "accept",
        6,
        &typed_args,
        typed_args.len,
        &foreign_vow,
    ));
    // C's accepted operation owns both delayed occurrences. The application
    // can drop its only copy before entropy is supplied; the Host keeps the
    // exporter authority until both gift transactions publish and releases it
    // through the ordinary retryable GC barrier afterward.
    try expectOk(cd.pancake_host_ref_release(recipient, &token, 1));
    var foreign_settled = CapturedSettle{};
    watches.add(recipient, foreign_vow, &foreign_settled);
    try pump(&hosts, &all_pairs, &dials, &watches);
    try std.testing.expect(typed_capture.seen);
    try std.testing.expect(typed_capture.refs[0].id != 0);
    try std.testing.expect(typed_capture.refs[1].id != 0);
    try std.testing.expectEqualStrings(
        "inline capabilities arrived",
        foreign_settled.text[0..foreign_settled.text_len],
    );
    try expectOk(cd.pancake_host_ref_release(gifter, &typed_capture.refs[0], 1));
    try expectOk(cd.pancake_host_ref_release(gifter, &typed_capture.refs[1], 1));
    try expectOk(cd.pancake_host_ref_release(recipient, &typed_target, 1));

    // The giftable row owns the shared ctx: its free runs exactly once, at
    // host release, no matter how many Ports projected the actor.
    try std.testing.expectEqual(@as(u32, 0), FreeFlag.runs);
    _ = cd.pancake_host_release(exporter);
    try std.testing.expectEqual(@as(u32, 1), FreeFlag.runs);
}

test "libpancake_host: a failed dial breaks the redeeming vow with the reason" {
    const exporter = try newHost(0x1e);
    defer _ = cd.pancake_host_release(exporter);
    const gifter = try newHost(0x16);
    defer _ = cd.pancake_host_release(gifter);
    const recipient = try newHost(0x1c);
    defer _ = cd.pancake_host_release(recipient);
    const hosts = [_]?*cd.PancakeHost{ exporter, gifter, recipient };
    var dials = Dials{};
    var watches = Watches{};

    const g_to_e = try openPair(&hosts, gifter, exporter, "127.0.0.1:7001", &dials, &watches);
    var widget_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(g_to_e.b, "widget", 6, widgetBehavior, null, null, &widget_local_ref));
    var widget = CapturedSettle{};
    var widget_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(g_to_e.a, "widget", 6, &widget_vow));
    watches.add(gifter, widget_vow, &widget);
    try pump(&hosts, &.{g_to_e}, &dials, &watches);
    const widget_token = try widget.requireRef();

    const r_to_g = try openPair(&hosts, recipient, gifter, "127.0.0.1:7002", &dials, &watches);
    var introducer_ctx = IntroducerCtx{ .widget = widget_token };
    var introducer_local_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(r_to_g.b, "introducer", 10, introducerBehavior, &introducer_ctx, null, &introducer_local_ref));
    var introducer = CapturedSettle{};
    var introducer_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(r_to_g.a, "introducer", 10, &introducer_vow));
    watches.add(recipient, introducer_vow, &introducer);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);
    const introducer_ref = try introducer.requireRef();

    var introduce_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_send(r_to_g.a, &introducer_ref, "introduce", 9, null, 0, &introduce_vow));
    var redeemed = CapturedSettle{};
    watches.add(recipient, introduce_vow, &redeemed);
    try pump(&hosts, &.{ g_to_e, r_to_g }, &dials, &watches);
    try std.testing.expectEqual(@as(usize, 1), dials.len);

    // The exporter is unreachable: the dial's failure breaks the vow, its
    // FAIL completion queued inside the report and drained right after.
    try expectOk(cd.pancake_host_dial_failed(recipient, dials.items[0].ticket, "exporter unreachable", 20));
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(redeemed.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, redeemed.kind);
    try std.testing.expect(std.mem.indexOf(u8, redeemed.msg[0..redeemed.msg_len], "exporter unreachable") != null);
}

/// The reentry probe's shared state: the behavior below runs inside a served
/// turn and records whether every top-level verb refused and every
/// enqueueing verb succeeded.

// ── Dial planner (pancake_host_plan_dial) ────────────────────────────────────
//
// The C wrapper over driver_core.planDial: the transport dispatch,
// designator validation, host:port resolution, and reachability decision the
// bindings share instead of re-expressing. The pure logic is exhaustively
// tested in test/driver/dial_plan_test.zig; these lock the C marshalling — the
// posture-policy mapping, the borrowed views, and the typed error code.

const key64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn planDialC(
    transport: []const u8,
    designator: []const u8,
    hint: []const u8,
    policy: u32,
    posture_value: u32,
    out: *cd.PancakeDialPlan,
) i32 {
    return cd.pancake_host_plan_dial(
        transport.ptr,
        transport.len,
        designator.ptr,
        designator.len,
        if (hint.len == 0) null else hint.ptr,
        hint.len,
        policy,
        posture_value,
        out,
    );
}

test "plan_dial C: tcp resolves the designator to host:port" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("tcp", "127.0.0.1:9000", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_HOST_PORT, plan.shape);
    try std.testing.expectEqualStrings("127.0.0.1", plan.host.?[0..plan.host_len]);
    try std.testing.expectEqual(@as(u16, 9000), plan.port);
}

test "plan_dial C: keyed-tcp resolves host:port off the hint, no hint is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("keyed-tcp", key64, "10.0.0.5:8000", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_HOST_PORT, plan.shape);
    try std.testing.expectEqualStrings("10.0.0.5", plan.host.?[0..plan.host_len]);
    try std.testing.expectEqual(@as(u16, 8000), plan.port);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("keyed-tcp", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "plan_dial C: iroh redeem picks direct with a hint, configured without" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("iroh", key64, "1.2.3.4:5", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_PEER_ID, plan.shape);
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_DIRECT, plan.reach_kind);
    try std.testing.expectEqualStrings("1.2.3.4:5", plan.addresses.?[0..plan.addresses_len]);
    try expectOk(planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_CONFIGURED, plan.reach_kind);
}

test "plan_dial C: keyed-relay resolves to the rendezvous shape" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("keyed-relay", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_RENDEZVOUS, plan.shape);
}

test "plan_dial C: iroh connect carries the explicit posture, none is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_EXPLICIT, 2, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_REACH_EXPLICIT, plan.reach_kind);
    try std.testing.expectEqual(@as(u32, 2), plan.reach_value);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("iroh", key64, "", cd.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE, 0, &plan));
}

test "plan_dial C: an unknown transport is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("x-nope", "whatever", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "plan_dial C: webrtc produces a signaling shape with any posture" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("webrtc", key64, "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_SIGNALING, plan.shape);
}

test "plan_dial C: webrtc ignores a direct-addresses hint" {
    var plan: cd.PancakeDialPlan = undefined;
    try expectOk(planDialC("webrtc", key64, "1.2.3.4:5", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
    try std.testing.expectEqual(cd.PANCAKE_DIAL_SHAPE_SIGNALING, plan.shape);
}

test "plan_dial C: webrtc non-key designator is a typed refusal" {
    var plan: cd.PancakeDialPlan = undefined;
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, planDialC("webrtc", "not-a-key", "", cd.PANCAKE_DIAL_POSTURE_REDEEM, 0, &plan));
}

test "libpancake_host: host_dialed refuses a session belonging to another host" {
    const dialer = try newHost(0x21);
    defer _ = cd.pancake_host_release(dialer);
    const acceptor = try newHost(0x22);
    defer _ = cd.pancake_host_release(acceptor);
    const stranger = try newHost(0x23);
    defer _ = cd.pancake_host_release(stranger);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ dialer, acceptor };
    const pair = try openPair(&hosts, dialer, acceptor, "127.0.0.1:7011", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    // A ticket is a plain integer and a session is an opaque pointer, so
    // nothing about the pair says they come from the same host. Answering one
    // host's dial with another host's session would seat that connection in a
    // node that never dialed it.
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_dialed(stranger, 1, pair.a),
    );

    // The refusal is about the host, not the ticket: the same unknown ticket on
    // the session's own host is the documented no-op success.
    try expectOk(cd.pancake_host_dialed(dialer, 1, pair.a));
}

test "libpancake_host: select-or-dial enliven rides a live session, then parks on a staged dial" {
    // ADR-0098 step 4 at the C seam: the embedder brings a complete sturdyref
    // and no session. A peer it already dialed is selected; an unreached peer
    // becomes an ordinary DIAL action, answered with the same two verbs a
    // handoff redeem uses.
    const client = try newHost(0x31);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x32);
    defer _ = cd.pancake_host_release(server);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7021", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);
    var counter = Counter{};
    var published: c.PancakeReference = undefined;
    try expectOk(cd.pancake_host_session_publish(pair.b, "widget", 6, widgetBehavior, &counter, null, &published));

    // SELECT: the sturdyref names the peer this host dialed, so no dial is
    // staged and the vow settles over the live session.
    const sturdyref = "ocapn://127.0.0.1%3A7021.tcp/s/d2lkZ2V0";
    var selected_vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(client, sturdyref, sturdyref.len, &selected_vow));
    try std.testing.expectEqual(@as(usize, 0), dials.len);
    var selected = CapturedSettle{};
    watches.add(client, selected_vow, &selected);
    try pump(&hosts, &.{pair}, &dials, &watches);
    _ = try selected.requireRef();
    try std.testing.expectEqual(@as(usize, 0), dials.len);

    // DIAL: an unreached peer parks the enliven and asks the embedder to dial.
    const elsewhere = "ocapn://127.0.0.1%3A7022.tcp/s/d2lkZ2V0";
    var parked_vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(client, elsewhere, elsewhere.len, &parked_vow));
    var parked = CapturedSettle{};
    watches.add(client, parked_vow, &parked);
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expectEqual(@as(usize, 1), dials.len);
    try std.testing.expectEqualStrings(
        "127.0.0.1:7022",
        dials.items[0].designator[0..dials.items[0].designator_len],
    );

    // The embedder opens what it was told to and reports it; the parked
    // enliven then runs over that session and settles the pre-minted vow.
    const second = try newHost(0x33);
    defer _ = cd.pancake_host_release(second);
    try setAdvertisedLocator(second, tcpLocator("127.0.0.1:7022"));
    var second_counter = Counter{};
    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(second, "tcp", 3, &accepted));
    defer _ = cd.pancake_host_session_release(accepted);
    var second_published: c.PancakeReference = undefined;
    try expectOk(cd.pancake_host_session_publish(accepted, "widget", 6, widgetBehavior, &second_counter, null, &second_published));
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(openDialed(client, "tcp", 3, "127.0.0.1:7022", 14, &dialed));
    defer _ = cd.pancake_host_session_release(dialed);
    const second_pair = Pair{ .a = dialed, .b = accepted };
    const both = [_]?*cd.PancakeHost{ client, second };
    try pump(&both, &.{second_pair}, &dials, &watches);
    const ticket = dials.items[0].ticket;
    dials.len = 0;
    try expectOk(cd.pancake_host_dialed(client, ticket, dialed));
    try pump(&both, &.{ pair, second_pair }, &dials, &watches);
    _ = try parked.requireRef();
}

test "libpancake_host: a select-or-dial enliven breaks when the embedder cannot dial" {
    const client = try newHost(0x34);
    defer _ = cd.pancake_host_release(client);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{client};

    const relay_route = "ws://127.0.0.1:9999/relay";
    const elsewhere = "ocapn://" ++ key64 ++
        ".keyed-relay/s/d2lkZ2V0?rendezvous-relay=ws%3A%2F%2F127.0.0.1%3A9999%2Frelay";
    var parked_vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(client, elsewhere, elsewhere.len, &parked_vow));
    var parked = CapturedSettle{};
    watches.add(client, parked_vow, &parked);
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expectEqual(@as(usize, 1), dials.len);
    try std.testing.expectEqualStrings(
        "keyed-relay",
        dials.items[0].transport[0..dials.items[0].transport_len],
    );
    try std.testing.expectEqualStrings(
        key64,
        dials.items[0].designator[0..dials.items[0].designator_len],
    );
    try std.testing.expectEqual(@as(usize, 1), dials.items[0].hint_count);
    try std.testing.expectEqualStrings(
        relay_route,
        dials.items[0].relay_route[0..dials.items[0].relay_route_len],
    );

    // Reporting the failure breaks the parked vow rather than stranding it.
    const reason = "connection refused";
    try expectOk(cd.pancake_host_dial_failed(client, dials.items[0].ticket, reason, reason.len));
    _ = try drainActions(&hosts, &dials, &watches);
    try std.testing.expect(parked.fired);
    try std.testing.expectEqual(c.PANCAKE_RESOLUTION_BREAK, parked.kind);
}

test "libpancake_host: next select-or-dial enliven parses raw swiss URI bytes" {
    const client = try newHostWithProfile(0x34, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_NEXT);
    defer _ = cd.pancake_host_release(client);

    const sturdyref = "ocapn://127.0.0.1%3A7024.tcp/s/widget%2Fpart";
    var vow: u64 = 0;
    try expectOk(cd.pancake_host_enliven(client, sturdyref, sturdyref.len, &vow));

    var action: cd.PancakeHostAction = undefined;
    try expectOk(cd.pancake_host_next_action(client, &action));
    try std.testing.expectEqual(cd.PANCAKE_HOST_ACTION_DIAL, action.kind);
}
