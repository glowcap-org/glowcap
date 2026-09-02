//! Host and session close: the monotonic barrier, grace deadlines and sticky
//! timeouts, allocator pressure at initiation, queue-cap overrides before mint,
//! the stream-ready outbound vector, and terminal release handover.

const std = @import("std");
const c = @import("c_abi");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
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

test "byte-fed host close exposes one monotonic barrier" {
    const host = try newHost(0x70);
    defer _ = cd.glowcap_host_release(host);

    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);

    try expectOk(cd.glowcap_host_close(host, &close_finish_unbounded, 100));
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_FINISHING, state);
    try expectOk(cd.glowcap_host_close_progress(host, 100, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);

    // Repeated finish and later cancel observe the same completed barrier.
    try expectOk(cd.glowcap_host_close(host, &close_finish_unbounded, 200));
    try expectOk(cd.glowcap_host_close(host, &close_cancel, 200));
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
}

test "byte-fed host close wait budget reports the nearest grace deadline" {
    const host = try newHost(0x72);
    defer _ = cd.glowcap_host_release(host);

    var wait_ms: i64 = undefined;
    // No close pending: only activity can advance anything, so the budget is -1.
    try expectOk(cd.glowcap_host_close_wait_ms(host, 0, &wait_ms));
    try std.testing.expectEqual(@as(i64, -1), wait_ms);

    // A negotiating session holds a finite finish open; its grace deadline is
    // the wait budget, counted in the embedder's own clock.
    try ensureAdvertisedLocator(host, "tcp");
    const transport = "tcp";
    const designator = "pending-peer";
    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, transport, transport.len, designator, designator.len, &session));

    const finish_50 = closeFinish(50);
    try expectOk(cd.glowcap_host_close(host, &finish_50, 100));
    try expectOk(cd.glowcap_host_close_wait_ms(host, 100, &wait_ms));
    try std.testing.expectEqual(@as(i64, 50), wait_ms);
    try expectOk(cd.glowcap_host_close_wait_ms(host, 140, &wait_ms));
    try std.testing.expectEqual(@as(i64, 10), wait_ms);
    // At or past the deadline the budget clamps to zero: progress now.
    try expectOk(cd.glowcap_host_close_wait_ms(host, 200, &wait_ms));
    try std.testing.expectEqual(@as(i64, 0), wait_ms);

    // Applying the expired clock escalates FINISH through the cancel path
    // (the sticky ERR_TIMEOUT outcome is pinned by the close tests); what
    // this test holds is that the consumed deadline leaves no budget: the
    // driver parks on activity alone while teardown actions drain.
    var state: u32 = undefined;
    _ = cd.glowcap_host_close_progress(host, 200, &state);
    try expectOk(cd.glowcap_host_close_wait_ms(host, 201, &wait_ms));
    try std.testing.expectEqual(@as(i64, -1), wait_ms);
}

test "byte-fed host close initiation succeeds under allocator pressure" {
    const CountingHost = @import("../../support/c_abi_counting_alloc.zig").CountingHost;
    var counting = CountingHost{};
    const spec = counting.spec();
    var context: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new_with_allocator(&spec, &context));

    const seed = hostSeed(0x79);
    var host: ?*cd.GlowcapHost = null;
    try expectOk(cd.glowcap_host_new_in(
        context,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.GLOWCAP_CODEC_SYRUP,
        c.GLOWCAP_CAPTP_V1_0,
        c.GLOWCAP_FEATURE_FULL,
        0,
        &host,
    ));

    counting.fail_allocations = true;
    try expectOk(cd.glowcap_host_close(host, &close_cancel, 0));
    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);
    counting.fail_allocations = false;

    try expectOk(cd.glowcap_host_close_progress(host, 1, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try expectOk(cd.glowcap_host_release(host));
    c.glowcap_context_release(context);
    try std.testing.expect(counting.balanced());
}

test "byte-fed host close validates policy and reports terminal progress" {
    const host = try newHost(0x71);
    defer _ = cd.glowcap_host_release(host);
    try ensureAdvertisedLocator(host, "tcp");

    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, "127.0.0.1:1", 11, &session));

    var invalid = close_cancel;
    invalid.pending = 99;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_close(host, &invalid, 0));
    invalid = close_cancel;
    invalid.grace_ms = 1;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_close(host, &invalid, 0));
    invalid = close_cancel;
    invalid.grace_mode = cd.GLOWCAP_CLOSE_GRACE_FINITE;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_close(host, &invalid, 0));
    invalid = close_finish_unbounded;
    invalid.grace_mode = cd.GLOWCAP_CLOSE_GRACE_UNSPECIFIED;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_close(host, &invalid, 0));
    invalid = close_finish_unbounded;
    invalid.grace_ms = 1;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_close(host, &invalid, 0));
    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);

    try expectOk(cd.glowcap_host_close(host, &close_cancel, 0));
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);

    var saw_close = false;
    while (true) {
        var action: cd.GlowcapHostAction = undefined;
        const rc = cd.glowcap_host_next_action(host, &action);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        if (action.kind == cd.GLOWCAP_HOST_ACTION_CLOSE) {
            try std.testing.expectEqual(session, action.session);
            try std.testing.expectEqual(c.GLOWCAP_OK, action.result);
            saw_close = true;
        }
    }
    try std.testing.expect(saw_close);
    try expectOk(cd.glowcap_host_session_release(session));

    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
}

test "byte-fed host close owns grace deadline and sticky timeout outcome" {
    const host = try newHost(0x73);
    defer _ = cd.glowcap_host_release(host);
    try ensureAdvertisedLocator(host, "tcp");

    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, "127.0.0.1:1", 11, &session));
    defer _ = cd.glowcap_host_session_release(session);

    const first = closeFinish(10);
    try expectOk(cd.glowcap_host_close(host, &first, 100));

    // A later FINISH neither shortens nor restarts the first deadline.
    const later = closeFinish(1);
    try expectOk(cd.glowcap_host_close(host, &later, 105));
    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_close_progress(host, 109, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_FINISHING, state);

    try expectOk(cd.glowcap_host_close_progress(host, 110, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);

    while (true) {
        var action: cd.GlowcapHostAction = undefined;
        const rc = cd.glowcap_host_next_action(host, &action);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        if (action.kind == cd.GLOWCAP_HOST_ACTION_CLOSE) {
            try std.testing.expectEqual(c.GLOWCAP_OK, action.result);
        }
    }

    try std.testing.expectEqual(c.GLOWCAP_ERR_TIMEOUT, cd.glowcap_host_close_progress(host, 111, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try std.testing.expectEqual(c.GLOWCAP_ERR_TIMEOUT, cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
}

test "byte-fed session close is monotonic and separate from release" {
    const host = try newHost(0x72);
    defer _ = cd.glowcap_host_release(host);
    try ensureAdvertisedLocator(host, "tcp");

    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, "127.0.0.1:1", 11, &session));
    defer _ = cd.glowcap_host_session_release(session);

    var state: u32 = undefined;
    var invalid = close_cancel;
    invalid.pending = 99;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_session_close(session, &invalid, 0));
    try expectOk(cd.glowcap_host_session_lifecycle_state(session, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);

    try expectOk(cd.glowcap_host_session_close(session, &close_finish_unbounded, 100));
    try expectOk(cd.glowcap_host_session_lifecycle_state(session, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_FINISHING, state);

    try expectOk(cd.glowcap_host_session_close(session, &close_cancel, 200));
    try expectOk(cd.glowcap_host_session_lifecycle_state(session, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);
}

test "byte-fed session close owns grace deadline and escalation" {
    const host = try newHost(0x74);
    defer _ = cd.glowcap_host_release(host);
    try ensureAdvertisedLocator(host, "tcp");

    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, "127.0.0.1:1", 11, &session));
    defer _ = cd.glowcap_host_session_release(session);

    const first = closeFinish(10);
    try expectOk(cd.glowcap_host_session_close(session, &first, 100));
    const later = closeFinish(1);
    try expectOk(cd.glowcap_host_session_close(session, &later, 105));

    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_session_close_progress(session, 109, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_FINISHING, state);
    // Expiry starts cancellation, but timeout is not observable until the
    // retryable CLOSE action crosses the embedder-delivery boundary.
    try expectOk(cd.glowcap_host_session_close_progress(session, 110, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);
    try expectOk(cd.glowcap_host_session_lifecycle_state(session, &state));

    var saw_close = false;
    while (true) {
        var action: cd.GlowcapHostAction = undefined;
        const rc = cd.glowcap_host_next_action(host, &action);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
        try expectOk(rc);
        if (action.kind == cd.GLOWCAP_HOST_ACTION_CLOSE) {
            try std.testing.expectEqual(c.GLOWCAP_ERR_TIMEOUT, action.result);
            saw_close = true;
        }
    }
    try std.testing.expect(saw_close);
    try std.testing.expectEqual(c.GLOWCAP_ERR_TIMEOUT, cd.glowcap_host_session_lifecycle_state(session, &state));
}

test "glowcap_host_set_session_limits validates one versioned patch and updates durable limits" {
    const host = try newHost(0x51);
    defer _ = cd.glowcap_host_release(host);
    try std.testing.expectEqual(c.GLOWCAP_ERR_NULL_POINTER, cd.glowcap_host_set_session_limits(host, null));
    var unsupported = sessionLimitOptions(0, 19, 0, 0);
    unsupported.abi_version = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cd.glowcap_host_set_session_limits(host, &unsupported),
    );
    unsupported = sessionLimitOptions(0, 19, 0, 0);
    unsupported.struct_size -= 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cd.glowcap_host_set_session_limits(host, &unsupported),
    );
    if (comptime @sizeOf(usize) > @sizeOf(u32)) {
        unsupported = sessionLimitOptions(0, 0, 0, @as(usize, std.math.maxInt(u32)) + 1);
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_INVALID_ARGUMENT,
            cd.glowcap_host_set_session_limits(host, &unsupported),
        );
    }
    var limits = sessionLimitOptions(0, 19, 0, 8 * 1024 * 1024);
    try expectOk(cd.glowcap_host_set_session_limits(host, &limits));
    const configured = try cd.testing.configuredSessionLimits(host);
    try std.testing.expectEqual(@as(usize, 19), configured.queue_cap);
    try std.testing.expectEqual(@as(u32, 8 * 1024 * 1024), configured.max_retained_sent_answer_bytes);
    // Mint a dialed session; limits land via Host.negotiatingOptions.
    try ensureAdvertisedLocator(host, "tcp");
    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(
        host,
        "tcp",
        3,
        "127.0.0.1:1",
        11,
        &session,
    ));
    defer _ = cd.glowcap_host_session_release(session);
    try std.testing.expect(session != null);
}

test "take_outbound returns one stream-ready vector without transport inference" {
    const clear = try newHost(0x49);
    defer _ = cd.glowcap_host_release(clear);
    try ensureAdvertisedLocator(clear, "tcp");

    var clear_session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(clear, "tcp", 3, "127.0.0.1:1", 11, &clear_session));
    defer _ = cd.glowcap_host_session_release(clear_session);

    // Refusing an undersized prefix destination must not transfer the queued
    // payload. A correctly sized retry sees the original first frame.
    var mf: c.GlowcapManagedFrame = undefined;
    var short_prefix: [1]u8 = undefined;
    var required: usize = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_BUFFER_TOO_SMALL,
        cd.glowcap_host_session_take_outbound(
            clear_session,
            &mf,
            &short_prefix,
            short_prefix.len,
            &required,
        ),
    );
    try std.testing.expectEqual(cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP, required);

    var clear_prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
    var clear_prefix_len: usize = undefined;
    try expectOk(cd.glowcap_host_session_take_outbound(
        clear_session,
        &mf,
        &clear_prefix,
        clear_prefix.len,
        &clear_prefix_len,
    ));
    defer c.glowcap_managed_frame_release(&mf);
    var expected_buf: [stream_framing.prefix_buffer_bytes]u8 = undefined;
    const expected = stream_framing.renderPrefix(&expected_buf, mf.len);
    try std.testing.expectEqualSlices(u8, expected, clear_prefix[0..clear_prefix_len]);

    // A sealed session starts with Noise handshake bytes. They are already
    // stream-ready, so the same generic drain returns no outer prefix.
    const noise_host = try newHost(0x4a);
    defer _ = cd.glowcap_host_release(noise_host);
    const crypto = glowcap.foundation.crypto;
    const local_seed = hostSeed(0x4a);
    const local_designator = crypto.SecretKey.fromSeed(local_seed[0..32].*).publicKey().toDesignator();
    const remote_seed = hostSeed(0x4b);
    const remote_designator = crypto.SecretKey.fromSeed(remote_seed[0..32].*).publicKey().toDesignator();
    try setAdvertisedLocator(noise_host, .{
        .transport = model.transport.noise_tcp,
        .designator = &local_designator,
        .hints = model.Hints.emptyFalse(),
    });
    var noise_session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(
        noise_host,
        model.transport.noise_tcp.ptr,
        model.transport.noise_tcp.len,
        &remote_designator,
        remote_designator.len,
        &noise_session,
    ));
    defer _ = cd.glowcap_host_session_release(noise_session);

    var noise_frame: c.GlowcapManagedFrame = undefined;
    var noise_prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
    var noise_prefix_len: usize = undefined;
    try expectOk(cd.glowcap_host_session_take_outbound(
        noise_session,
        &noise_frame,
        &noise_prefix,
        noise_prefix.len,
        &noise_prefix_len,
    ));
    defer c.glowcap_managed_frame_release(&noise_frame);
    try std.testing.expectEqual(@as(usize, 0), noise_prefix_len);
    try std.testing.expect(noise_frame.len > 0);
}

test "take_outbound wraps an already queued frame without allocating" {
    const CountingHost = @import("../../support/c_abi_counting_alloc.zig").CountingHost;
    var counting = CountingHost{};
    const spec = counting.spec();
    var context: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new_with_allocator(&spec, &context));

    const seed = hostSeed(0x4c);
    var host: ?*cd.GlowcapHost = null;
    try expectOk(cd.glowcap_host_new_in(
        context,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.GLOWCAP_CODEC_SYRUP,
        c.GLOWCAP_CAPTP_V1_0,
        c.GLOWCAP_FEATURE_FULL,
        0,
        &host,
    ));
    try ensureAdvertisedLocator(host, "tcp");
    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openDialed(host, "tcp", 3, "127.0.0.1:1", 11, &session));

    var frame: c.GlowcapManagedFrame = undefined;
    var prefix: [cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP]u8 = undefined;
    var prefix_len: usize = undefined;
    counting.fail_allocations = true;
    try expectOk(cd.glowcap_host_session_take_outbound(
        session,
        &frame,
        &prefix,
        prefix.len,
        &prefix_len,
    ));
    c.glowcap_managed_frame_release(&frame);
    counting.fail_allocations = false;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, cd.glowcap_host_session_take_outbound(
        session,
        &frame,
        &prefix,
        prefix.len,
        &prefix_len,
    ));

    try expectOk(cd.glowcap_host_session_release(session));
    try expectOk(cd.glowcap_host_release(host));
    c.glowcap_context_release(context);
    try std.testing.expect(counting.balanced());
}

test "glowcap_host_release accepts an exclusive terminal thread transfer" {
    const host = try newHost(0x52);
    // Claim the Host on this thread through an ordinary live verb first. Only
    // terminal ownership moves; every nonterminal call remains thread-affine.
    var limits = sessionLimitOptions(0, 19, 0, 0);
    try expectOk(cd.glowcap_host_set_session_limits(host, &limits));

    var release_rc: i32 = c.GLOWCAP_ERR_INTERNAL;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(owned: ?*cd.GlowcapHost, rc: *i32) void {
            rc.* = cd.glowcap_host_release(owned);
        }
    }.run, .{ host, &release_rc });
    thread.join();
    try expectOk(release_rc);
}
