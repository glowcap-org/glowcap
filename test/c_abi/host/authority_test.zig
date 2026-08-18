//! What a reference is allowed to mean: opaque references cannot cross Host
//! authority, capability ids are process-unique, a hosted actor outlives its
//! Port, rejected projections release every occurrence, and each session signs
//! under its own key with its own reported identity.

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

test "libpancake_host: opaque references cannot cross Host authority" {
    const a = try newHost(0x53);
    defer _ = cd.pancake_host_release(a);
    const b = try newHost(0x54);
    defer _ = cd.pancake_host_release(b);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ a, b };
    const pair = try openPair(&hosts, a, b, "127.0.0.1:7000", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    var a_ref: c.PancakeReference = .{ .id = 0 };
    var b_ref: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(pair.a, widgetBehavior, null, null, &a_ref));
    try expectOk(cd.pancake_host_session_spawn(pair.b, widgetBehavior, null, null, &b_ref));
    try std.testing.expect(a_ref.id != b_ref.id);

    var vow: u64 = 0;
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_session_send(pair.b, &a_ref, "poke", 4, null, 0, &vow));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_session_tell(pair.b, &a_ref, "poke", 4, null, 0));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_ref_release(b, &a_ref, 1));

    var exporter: ?*cd.PancakeHostSession = undefined;
    try expectOk(cd.pancake_host_reference_exporter(b, &a_ref, &exporter));
    try std.testing.expect(exporter == null);
    try expectOk(cd.pancake_host_reference_exporter(b, &b_ref, &exporter));
    // A local actor belongs to the Host Vat, not to the Port that first
    // projected it, so it has no unique exporter session.
    try std.testing.expect(exporter == null);
    try expectOk(cd.pancake_host_ref_release(b, &b_ref, 1));
    try std.testing.expectEqual(c.PANCAKE_ERR_NOT_FOUND, cd.pancake_host_ref_release(b, &b_ref, 1));
}

test "libpancake_host: raw capability ids are opaque and process-unique across equal-seed Hosts" {
    const a = try newHost(0x55);
    defer _ = cd.pancake_host_release(a);
    const b = try newHost(0x55);
    defer _ = cd.pancake_host_release(b);
    try setAdvertisedLocator(a, tcpLocator("a"));
    try setAdvertisedLocator(b, tcpLocator("b"));
    var a_session: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(a, "tcp", 3, &a_session));
    defer _ = cd.pancake_host_session_release(a_session);
    var b_session: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(b, "tcp", 3, &b_session));
    defer _ = cd.pancake_host_session_release(b_session);

    var a_first: c.PancakeReference = .{ .id = 0 };
    var a_second: c.PancakeReference = .{ .id = 0 };
    var b_first: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_spawn(a_session, widgetBehavior, null, null, &a_first));
    try expectOk(cd.pancake_host_session_spawn(a_session, widgetBehavior, null, null, &a_second));
    try expectOk(cd.pancake_host_session_spawn(b_session, widgetBehavior, null, null, &b_first));

    try std.testing.expect(a_first.id != 0 and a_second.id != 0 and b_first.id != 0);
    try std.testing.expect(a_first.id != b_first.id);
    try std.testing.expect(a_second.id != a_first.id +% 1);
    try std.testing.expect(a_first.id != (@as(u64, 1) << 62));
}

test "libpancake_host: a hosted actor survives its originating Port" {
    const first_client = try newHost(0x57);
    defer _ = cd.pancake_host_release(first_client);
    const second_client = try newHost(0x58);
    defer _ = cd.pancake_host_release(second_client);
    const server = try newHost(0x59);
    defer _ = cd.pancake_host_release(server);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ first_client, second_client, server };
    const first = try openPair(&hosts, first_client, server, "127.0.0.1:7057", &dials, &watches);
    const second = try openPair(&hosts, second_client, server, "127.0.0.1:7058", &dials, &watches);
    defer _ = cd.pancake_host_session_release(second.a);
    defer _ = cd.pancake_host_session_release(second.b);

    var counter = Counter{};
    var hosted: c.PancakeReference = .{ .id = 0 };
    try expectOk(cd.pancake_host_session_publish(first.b, "widget", 6, widgetBehavior, &counter, null, &hosted));

    // The actor belongs to the server Host Vat, not to the Port that selected
    // its first projection. Retire both ends of that connection, then call the
    // same opaque Host identity through a sibling server Port.
    try expectOk(cd.pancake_host_session_release(first.a));
    try expectOk(cd.pancake_host_session_release(first.b));
    try expectOk(cd.pancake_host_session_tell(second.b, &hosted, "poke", 4, null, 0));
    try std.testing.expectEqual(@as(u32, 1), counter.pokes);
}

test "libpancake_host: rejected recursive projection releases every reference occurrence" {
    const client = try newHost(0x55);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x56);
    defer _ = cd.pancake_host_release(server);
    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7003", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    // Two wire occurrences of the same import surround a handoff-receive arm.
    // A receive is an exporter bootstrap request, never an application value,
    // so the whole projection fails and neither reference occurrence may
    // survive as invisible Host or import authority. Error is intentionally
    // not this sentinel: it is a first-class fulfilled value.
    try cd.testing.importObject(pair.a, 7);
    try cd.testing.importObject(pair.a, 7);
    var handoff = model.Handoff{ .receive = .{
        .receiving_session = "session",
        .receiving_side = "side",
        .handoff_count = 0,
        .signed_give = .{
            .recipient_key = "recipient",
            .exporter = .{ .transport = "memory", .designator = "exporter" },
            .gifter_exporter_session = "gifter-session",
            .gifter_side = "gifter-side",
            .gift_id = &([_]u8{0x77} ** model.HANDOFF_GIFT_ID_BYTES),
            .signature = "give-signature",
        },
        .signature = "receive-signature",
    } };
    const args = [_]model.Argument{
        .{ .reference = .{ .far = model.FarRef.object(7) } },
        .{ .handoff = &handoff },
        .{ .reference = .{ .far = model.FarRef.object(7) } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedValue, cd.testing.projectArgs(client, pair.a, arena.allocator(), &args));
    try std.testing.expectEqual(@as(usize, 0), try cd.testing.liveCapabilityCount(client));
    try std.testing.expectEqual(@as(u64, 0), try cd.testing.importRefcount(pair.a, 7));
}

// ── C argument/reference construction (shared across the c_abi suite) ────────

test "host action FAIL carries the core-owned broken or closed result" {
    const client = try newHost(0x3a);
    defer _ = cd.pancake_host_release(client);
    const server = try newHost(0x3b);
    defer _ = cd.pancake_host_release(server);
    const hosts = [_]?*cd.PancakeHost{ client, server };
    var dials = Dials{};
    var watches = Watches{};
    const pair = try openPair(&hosts, client, server, "127.0.0.1:7009", &dials, &watches);
    defer _ = cd.pancake_host_session_release(pair.a);
    defer _ = cd.pancake_host_session_release(pair.b);

    var broken_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "pending", 7, &broken_vow));
    try expectOk(cd.pancake_host_session_break_far_vows(pair.a, "partner broke", 13));
    var saw_broken = false;
    while (true) {
        var action: cd.PancakeHostAction = undefined;
        const rc = cd.pancake_host_next_action(client, &action);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        if (action.kind == cd.PANCAKE_HOST_ACTION_FAIL and action.ticket == broken_vow) {
            try std.testing.expectEqual(c.PANCAKE_ERR_BROKEN, action.result);
            saw_broken = true;
        }
    }
    try std.testing.expect(saw_broken);

    var closed_vow: u64 = 0;
    try expectOk(cd.pancake_host_session_fetch(pair.a, "pending", 7, &closed_vow));
    try expectOk(cd.pancake_host_session_transport_closed(pair.a, "transport gone", 14));
    var saw_closed = false;
    while (true) {
        var action: cd.PancakeHostAction = undefined;
        const rc = cd.pancake_host_next_action(client, &action);
        if (rc == c.PANCAKE_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        if (action.kind == cd.PANCAKE_HOST_ACTION_FAIL and action.ticket == closed_vow) {
            try std.testing.expectEqual(c.PANCAKE_ERR_CLOSED, action.result);
            saw_closed = true;
        }
    }
    try std.testing.expect(saw_closed);
}

// ── Behaviors and captures ───────────────────────────────────────────────────

// ── Tests ────────────────────────────────────────────────────────────────────

test "libpancake_host: Context assigns distinct stable Host diagnostic identities" {
    var context: ?*c.PancakeContext = null;
    try expectOk(c.pancake_context_new(&context));
    defer c.pancake_context_release(context);

    var first: ?*cd.PancakeHost = null;
    const first_seed = hostSeed(0x08);
    try expectOk(cd.pancake_host_new_in(context, &first_seed, first_seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &first));
    defer _ = cd.pancake_host_release(first);
    var second: ?*cd.PancakeHost = null;
    const second_seed = hostSeed(0x09);
    try expectOk(cd.pancake_host_new_in(context, &second_seed, second_seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &second));
    defer _ = cd.pancake_host_release(second);

    var first_id: u64 = 0;
    var second_id: u64 = 0;
    try expectOk(cd.pancake_host_diagnostic_id(first, &first_id));
    try expectOk(cd.pancake_host_diagnostic_id(second, &second_id));
    try std.testing.expectEqual(@as(u64, 1), first_id);
    try std.testing.expectEqual(@as(u64, 2), second_id);
}

test "libpancake_host: keyed-tcp accept signs the published locator, or its own candidate when none is selected" {
    const crypto = pancake.foundation.crypto;

    // No locator published: the accept-derived candidate (this host's key
    // designator plus the accept-reported address hint) is installed,
    // selected, and signed.
    const seed_a = hostSeed(0x5c);
    const designator_a = crypto.SecretKey.fromSeed(seed_a[0..32].*).publicKey().toDesignator();
    var host_a: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new(&seed_a, seed_a.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &host_a));
    defer _ = cd.pancake_host_release(host_a);
    var accepted_a: ?*cd.PancakeHostSession = null;
    try expectOk(openAcceptedKeyed(host_a, "keyed-tcp", &designator_a, "127.0.0.1:9000", &accepted_a));
    defer _ = cd.pancake_host_session_release(accepted_a);
    var mf_a: c.PancakeManagedFrame = undefined;
    try expectOk(takeOutbound(accepted_a, &mf_a));
    defer c.pancake_managed_frame_release(&mf_a);
    const bytes_a = mf_a.bytes.?[0..mf_a.len];
    try std.testing.expect(std.mem.indexOf(u8, bytes_a, "direct-addresses") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes_a, "127.0.0.1:9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes_a, designator_a[0..]) != null);

    // A published locator is deployment policy: the accept retains its own
    // candidate but the signed hello still carries the published hint.
    const seed_b = hostSeed(0x5d);
    const designator_b = crypto.SecretKey.fromSeed(seed_b[0..32].*).publicKey().toDesignator();
    const published_hint = "127.0.0.1:9010";
    var host_b: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new(&seed_b, seed_b.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &host_b));
    defer _ = cd.pancake_host_release(host_b);
    var hint_entries: [1]model.HintEntry = undefined;
    try setAdvertisedLocator(host_b, .{
        .transport = "keyed-tcp",
        .designator = &designator_b,
        .hints = model.Hints.forDirectAddresses(published_hint, &hint_entries),
    });
    var accepted_b: ?*cd.PancakeHostSession = null;
    try expectOk(openAcceptedKeyed(host_b, "keyed-tcp", &designator_b, "10.9.9.9:1", &accepted_b));
    defer _ = cd.pancake_host_session_release(accepted_b);
    var mf_b: c.PancakeManagedFrame = undefined;
    try expectOk(takeOutbound(accepted_b, &mf_b));
    defer c.pancake_managed_frame_release(&mf_b);
    const bytes_b = mf_b.bytes.?[0..mf_b.len];
    try std.testing.expect(std.mem.indexOf(u8, bytes_b, published_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes_b, "10.9.9.9:1") == null);
}

test "libpancake_host: a 64-byte seed gives every session its own signing key" {
    // ADR-0097 at the byte-fed tier. The core draws no entropy, so the
    // embedder supplies a session-key root after the durable identity in the
    // one seed buffer, and each session then signs with its own key. A
    // durable-only 32-byte seed is refused — CapTP session keys must not
    // silently reuse the identity seed.
    const crypto = pancake.foundation.crypto;

    const durable = [_]u8{0x71} ** 32;
    var seed_with_root: [64]u8 = undefined;
    @memcpy(seed_with_root[0..32], &durable);
    @memcpy(seed_with_root[32..], &[_]u8{0x72} ** 32);

    var refused: ?*cd.PancakeHost = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cd.pancake_host_new(&durable, durable.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &refused),
    );
    try std.testing.expect(refused == null);

    var host: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new(&seed_with_root, seed_with_root.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &host));
    defer _ = cd.pancake_host_release(host);
    try setAdvertisedLocator(host, tcpLocator("127.0.0.1:7401"));

    // Two sessions, two hellos. Each carries the key that session signed with.
    var first: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(host, "tcp", 3, &first));
    defer _ = cd.pancake_host_session_release(first);
    var second: ?*cd.PancakeHostSession = null;
    try expectOk(openAccepted(host, "tcp", 3, &second));
    defer _ = cd.pancake_host_session_release(second);

    var first_key: [32]u8 = undefined;
    var second_key: [32]u8 = undefined;
    inline for (.{ .{ first, &first_key }, .{ second, &second_key } }) |pair| {
        var mf: c.PancakeManagedFrame = undefined;
        try expectOk(takeOutbound(pair[0], &mf));
        defer c.pancake_managed_frame_release(&mf);
        const view = try pancake.ocapn.codec.syrup.decodeBody(.{ .bytes = mf.bytes.?[0..mf.len], .shape = .byte });
        @memcpy(pair[1], view.start_session.session_pubkey[0..32]);
    }

    try std.testing.expect(!std.mem.eql(u8, &first_key, &second_key));
    // And neither is the durable identity, which stays the host's own name.
    const durable_key = crypto.SecretKey.fromSeed(durable).publicKey();
    try std.testing.expect(!std.mem.eql(u8, &first_key, durable_key.asBytes()));
    try std.testing.expect(!std.mem.eql(u8, &second_key, durable_key.asBytes()));
}

test "libpancake_host: one PartnerIdentity reports session key, durable name, and provenance apart" {
    // ADR-0097 evidence item 11 at the C tier: the three facts are one struct
    // and are not conflated. keyed-tcp supplies no channel proof, so its
    // key-shaped designator remains unauthenticated.
    const crypto = pancake.foundation.crypto;

    const server_seed = hostSeed(0x6d);
    const designator = crypto.SecretKey.fromSeed(server_seed[0..32].*).publicKey().toDesignator();
    const hint = "127.0.0.1:9100";

    var client: ?*cd.PancakeHost = null;
    const client_seed = hostSeed(0x6c);
    try expectOk(cd.pancake_host_new(&client_seed, client_seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &client));
    defer _ = cd.pancake_host_release(client);
    var server: ?*cd.PancakeHost = null;
    try expectOk(cd.pancake_host_new(&server_seed, server_seed.len, frame_cap, 1, c.PANCAKE_CODEC_SYRUP, c.PANCAKE_CAPTP_V1_0, c.PANCAKE_FEATURE_FULL, 0, &server));
    defer _ = cd.pancake_host_release(server);

    try ensureAdvertisedLocator(client, "keyed-tcp");
    var hint_entries: [1]model.HintEntry = undefined;
    try setAdvertisedLocator(server, .{
        .transport = "keyed-tcp",
        .designator = &designator,
        .hints = model.Hints.forDirectAddresses(hint, &hint_entries),
    });

    var accepted: ?*cd.PancakeHostSession = null;
    try expectOk(openAcceptedKeyed(server, "keyed-tcp", &designator, hint, &accepted));
    defer _ = cd.pancake_host_session_release(accepted);
    var dialed: ?*cd.PancakeHostSession = null;
    try expectOk(openDialed(
        client,
        "keyed-tcp",
        9,
        &designator,
        designator.len,
        &dialed,
    ));
    defer _ = cd.pancake_host_session_release(dialed);

    var dials = Dials{};
    var watches = Watches{};
    const hosts = [_]?*cd.PancakeHost{ client, server };
    const pair = Pair{ .a = dialed, .b = accepted };
    try pump(&hosts, &.{pair}, &dials, &watches);
    try std.testing.expect(cd.pancake_host_session_is_open(dialed) != 0);

    var identity: cd.PancakePartnerIdentity = undefined;
    try expectOk(cd.pancake_host_session_partner_identity(dialed, &identity));

    // Session identity: 32 raw key bytes.
    try std.testing.expectEqual(@as(usize, 32), identity.session_key_len);
    // Durable identity: the 64-hex designator, a different length and a
    // different spelling from the key above.
    try std.testing.expectEqualStrings(&designator, identity.designator.?[0..identity.designator_len]);
    try std.testing.expectEqual(identity.session_key_len * 2, identity.designator_len);
    // Provenance: what authenticated that durable name.
    try std.testing.expectEqual(
        cd.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED,
        identity.provenance,
    );
}

// ── Dial planner (pancake_host_plan_dial) ────────────────────────────────────
//
// The C wrapper over driver_core.planDial: the transport dispatch,
// designator validation, host:port resolution, and reachability decision the
// bindings share instead of re-expressing. The pure logic is exhaustively
// tested in test/driver/dial_plan_test.zig; these lock the C marshalling — the
// posture-policy mapping, the borrowed views, and the typed error code.
