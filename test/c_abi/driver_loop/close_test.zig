//! Driver close and thread lifetime: the monotonic barrier, wait budgets,
//! allocator pressure at initiation, committed C event delivery through
//! teardown, detach_thread handoffs at quiescent boundaries, foreign-thread
//! refusals, counted allocation parity, and bounded pending-open admission.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const ctcp = @import("c_abi_net_transport_tcp");
const glowcap = @import("glowcap");
const ws_relay = @import("../../support/ws_relay.zig");

const harness = @import("harness.zig");
const residents = @import("residents.zig");
const typed_resident = @import("typed_resident.zig");
const frame_cap = harness.frame_cap;
const default_tcp_config = harness.default_tcp_config;
const driver_options_1s = harness.driver_options_1s;
const driver_options_10s = harness.driver_options_10s;
const driver_options_cap1 = harness.driver_options_cap1;
const close_cancel = harness.close_cancel;
const providerFailure = harness.providerFailure;
const drained = harness.drained;
const expectOk = harness.expectOk;
const expectStep = harness.expectStep;
const retainStaticProvider = harness.retainStaticProvider;
const releaseStaticProvider = harness.releaseStaticProvider;
const sameStaticProvider = harness.sameStaticProvider;
const providerProfile = harness.providerProfile;
const addMultiplexedProviderWithProfile = harness.addMultiplexedProviderWithProfile;
const addMultiplexedProvider = harness.addMultiplexedProvider;
const addStreamProvider = harness.addStreamProvider;
const openAccepted = harness.openAccepted;
const readListenerLocator = harness.readListenerLocator;
const expectLoopReadable = harness.expectLoopReadable;
const directAddresses = harness.directAddresses;
const callWithLocator = harness.callWithLocator;
const dialParts = harness.dialParts;
const dialLocator = harness.dialLocator;
const advertiseParts = harness.advertiseParts;
const hostSeed = harness.hostSeed;
const TestLoop = harness.TestLoop;
const installTcp = harness.installTcp;
const installRelay = harness.installRelay;
const newEmptyLoop = harness.newEmptyLoop;
const newLoop = harness.newLoop;
const newByteFedHost = harness.newByteFedHost;
const Drained = harness.Drained;
const serveBoth = harness.serveBoth;
const drainEvents = harness.drainEvents;
const awaitListenerReady = harness.awaitListenerReady;
const listenReady = harness.listenReady;
const noStreamConnectionFailure = residents.noStreamConnectionFailure;
const noMultiplexedConnectionFailure = residents.noMultiplexedConnectionFailure;
const injectedStreamConnectionFailure = residents.injectedStreamConnectionFailure;
const injectedMultiplexedConnectionFailure = residents.injectedMultiplexedConnectionFailure;
const InvalidMultiplexedResident = residents.InvalidMultiplexedResident;
const MalformedImmediateStream = residents.MalformedImmediateStream;
const AsyncFailureResident = residents.AsyncFailureResident;
const TypedResident = typed_resident.TypedResident;
const typedProvider = typed_resident.typedProvider;
const widgetBehavior = typed_resident.widgetBehavior;
const ReentrantSessionRelease = typed_resident.ReentrantSessionRelease;
const CallbackRetirement = typed_resident.CallbackRetirement;
const callbackRetirementBehavior = typed_resident.callbackRetirementBehavior;
const reentrantSessionReleaseBehavior = typed_resident.reentrantSessionReleaseBehavior;

test "driver C events preserve the first consequence and total count" {
    var failure = glowcap.driver.OperationFailure.fromError(error.ConnectionLost);
    failure.note(error.CloseTimedOut);
    failure.note(error.OutOfMemory);
    var event = std.mem.zeroes(cdrv.GlowcapDriverEvent);
    cdrv.FailureProjection.init(failure).project(&event);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, event.primary_result);
    try std.testing.expectEqual(c.GLOWCAP_ERR_TIMEOUT, event.secondary_result);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqualStrings("ConnectionLost", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqualStrings("CloseTimedOut", event.secondary_name.?[0..event.secondary_name_len]);
}

test "loop refusals speak through the driver family's own error slot" {
    var loop_slot: ?*cdrv.GlowcapDriverLoop = null;
    // A null Host is a null-pointer refusal.
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        cdrv.glowcap_driver_take_host(null, &driver_options_1s, &loop_slot),
    );
    // Malformed limits are refused with a message in this family's own slot.
    const host = try newByteFedHost(0x33);
    defer _ = cd.glowcap_host_release(host);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        cdrv.glowcap_driver_take_host(host, null, &loop_slot),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, null),
    );
    var invalid_options = driver_options_1s;
    invalid_options.abi_version += 1;
    cdrv.glowcap_driver_clear_last_error();
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &invalid_options, &loop_slot),
    );
    invalid_options = driver_options_1s;
    invalid_options.struct_size = @offsetOf(cdrv.GlowcapDriverOptions, "settle_ms");
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &invalid_options, &loop_slot),
    );
    invalid_options = driver_options_1s;
    invalid_options.wire_buffer_bytes = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &invalid_options, &loop_slot),
    );
    invalid_options = driver_options_1s;
    invalid_options.handshake_ms = cdrv.GLOWCAP_DRIVER_MAX_WAIT_MS + 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &invalid_options, &loop_slot),
    );
    var message: [256]u8 = undefined;
    try std.testing.expect(cdrv.glowcap_driver_last_error(&message, message.len) > 0);

    // Zero is the explicit unbounded sentinel for each wait budget. It is not
    // accepted for retained memory or admission limits. Both successful calls
    // clear the prior refusal instead of leaving a stale cause for the next
    // undetailed status.
    const unbounded_host = try newByteFedHost(0x35);
    var unbounded_options = driver_options_1s;
    unbounded_options.handshake_ms = 0;
    unbounded_options.listener_setup_ms = 0;
    unbounded_options.settle_ms = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_OK,
        cdrv.glowcap_driver_take_host(unbounded_host, &unbounded_options, &loop_slot),
    );
    try std.testing.expect(loop_slot != null);
    try std.testing.expectEqual(c.GLOWCAP_OK, harness.releaseLoop(loop_slot));
    loop_slot = null;
    try std.testing.expectEqual(@as(usize, 0), cdrv.glowcap_driver_last_error(&message, message.len));

    const owned_loop = try newLoop(0x34);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    const malformed_operation_options: cshared.GlowcapTransportOperationOptions = .{
        .data = null,
        .size = 1,
    };
    var refused_listener: u64 = 73;
    cdrv.glowcap_driver_clear_last_error();
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_listen(
            loop,
            "tcp",
            3,
            "127.0.0.1:0",
            11,
            &malformed_operation_options,
            &refused_listener,
        ),
    );
    try std.testing.expectEqual(@as(u64, 73), refused_listener);
    var operation_message: [256]u8 = undefined;
    const operation_message_len = @min(
        cdrv.glowcap_driver_last_error(&operation_message, operation_message.len),
        operation_message.len,
    );
    try std.testing.expect(std.mem.indexOf(u8, operation_message[0..operation_message_len], "transport operation options") != null);
    // A resident table with unset function pointers is refused before any
    // registration happens.
    var table = std.mem.zeroes(cdrv.GlowcapMultiplexedTransport);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
    table.abi_version = cdrv.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION;
    table.struct_size = @offsetOf(cdrv.GlowcapMultiplexedTransport, "ctx");
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
    var profile = providerProfile("invalid-count");
    profile.abi_version = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        addMultiplexedProviderWithProfile(loop, &table, &profile),
    );
    // Wake is callable before the readiness set is armed (a no-op then), and
    // the thread handover verb round-trips: after a detach, the next verb on
    // this same thread re-claims.
    try expectOk(cdrv.glowcap_driver_wake(loop));
    try expectOk(cdrv.glowcap_driver_detach_thread(loop));
    try expectStep(cdrv.glowcap_driver_step(loop, 0));
}

test "driver close is one nonblocking monotonic barrier" {
    const owned = try newEmptyLoop(0x37);
    defer owned.deinit();
    const loop = owned.raw;

    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);

    var invalid = close_cancel;
    invalid.pending = 99;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_close(loop, &invalid));
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);

    try expectOk(cdrv.glowcap_driver_close(loop, &close_cancel));
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);
    try expectStep(cdrv.glowcap_driver_step(loop, 0));
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);

    // Finish cannot weaken a completed cancel barrier, and new runtime work
    // is refused while status/event drains and release remain available.
    const finish_unbounded: cdrv.GlowcapCloseOptions = .{
        .abi_version = cdrv.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapCloseOptions),
        .pending = cd.GLOWCAP_PENDING_FINISH,
        .grace_mode = cdrv.GLOWCAP_CLOSE_GRACE_UNBOUNDED,
        .grace_ms = 0,
    };
    try expectOk(cdrv.glowcap_driver_close(loop, &finish_unbounded));

    var tcp: ?*ctcp.GlowcapTcpNetlayer = null;
    try expectOk(ctcp.glowcap_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.glowcap_tcp_netlayer_release(tcp);
    var provider: cdrv.GlowcapTransportProvider = undefined;
    try expectOk(ctcp.glowcap_tcp_transport_provider(tcp, &provider));
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, harness.addProvider(loop, &provider));
}

test "driver step wait budget reports the nearest pending-work deadline" {
    const owned = try newEmptyLoop(0x38);
    defer owned.deinit();
    const loop = owned.raw;

    var wait_ms: i32 = undefined;
    // An idle loop pends no deadline: readiness alone advances it.
    try expectOk(cdrv.glowcap_driver_step_wait_ms(loop, &wait_ms));
    try std.testing.expectEqual(@as(i32, -1), wait_ms);

    // A committed finite grace bounds the wait until the next step applies
    // it. The exact remainder depends on the loop's own clock, so the pin is
    // the range, not a value.
    const finish_5s: cdrv.GlowcapCloseOptions = .{
        .abi_version = cdrv.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapCloseOptions),
        .pending = cd.GLOWCAP_PENDING_FINISH,
        .grace_mode = cdrv.GLOWCAP_CLOSE_GRACE_FINITE,
        .grace_ms = 5000,
    };
    try expectOk(cdrv.glowcap_driver_close(loop, &finish_5s));
    try expectOk(cdrv.glowcap_driver_step_wait_ms(loop, &wait_ms));
    try std.testing.expect(wait_ms >= 0 and wait_ms <= 5000);

    // An idle finish reaches CLOSED at its next step; terminal state pends
    // no deadline and the close driver parks on activity alone.
    try expectStep(cdrv.glowcap_driver_step(loop, 0));
    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.glowcap_driver_step_wait_ms(loop, &wait_ms));
    try std.testing.expectEqual(@as(i32, -1), wait_ms);
}

test "driver close initiation succeeds under allocator pressure" {
    var counting = @import("../../support/c_abi_counting_alloc.zig").CountingHost{};
    const spec = counting.spec();
    var context: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new_with_allocator(&spec, &context));

    const seed = hostSeed(0x5f);
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
        1,
        &host,
    ));
    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop));

    counting.fail_allocations = true;
    try expectOk(cdrv.glowcap_driver_close(loop, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);
    counting.fail_allocations = false;

    try expectStep(cdrv.glowcap_driver_step(loop, 0));
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try expectOk(harness.releaseLoop(loop));
    c.glowcap_context_release(context);
    try std.testing.expect(counting.balanced());
}

test "driver close waits for committed C event delivery after Zig teardown" {
    const owned = try newLoop(0x3a);
    defer owned.deinit();
    const loop = owned.raw;

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        loop,
        "tcp",
        3,
        "127.0.0.1:0",
        11,
        null,
        &listener,
    ));
    var locator: cdrv.GlowcapLocatorView = undefined;
    for (0..2_000) |_| {
        const code = cdrv.glowcap_driver_listener_locator(loop, listener, &locator);
        if (code == c.GLOWCAP_OK) break;
        try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, code);
        try expectStep(cdrv.glowcap_driver_step(loop, 5));
    } else return error.ListenerSetupTimedOut;

    try expectOk(cdrv.glowcap_driver_close(loop, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);

    var event: cdrv.GlowcapDriverEvent = undefined;
    try expectOk(cdrv.glowcap_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_READY, event.kind);
    try std.testing.expectEqual(listener, event.listener_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, cdrv.glowcap_driver_next_event(loop, &event));

    try expectStep(cdrv.glowcap_driver_step(loop, 0));
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
}

test "driver finish timeout closes transport work before reporting timeout" {
    const server_owned = try newLoop(0x38);
    defer server_owned.deinit();
    const server = server_owned.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const client_owned = try newLoop(0x39);
    defer client_owned.deinit();
    const client = client_owned.raw;
    var operation_id: u64 = 0;
    try expectOk(try dialLocator(client, locator, &operation_id));

    const finish: cdrv.GlowcapCloseOptions = .{
        .abi_version = cdrv.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapCloseOptions),
        .pending = cd.GLOWCAP_PENDING_FINISH,
        .grace_mode = cdrv.GLOWCAP_CLOSE_GRACE_FINITE,
        .grace_ms = 25,
    };
    try expectOk(cdrv.glowcap_driver_close(client, &finish));

    var state: u32 = cd.GLOWCAP_LIFECYCLE_FINISHING;
    var timed_out = false;
    var rounds: usize = 0;
    while (state != cd.GLOWCAP_LIFECYCLE_CLOSED and rounds < 20) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, -1));
        while (true) {
            var event: cdrv.GlowcapDriverEvent = undefined;
            const event_rc = cdrv.glowcap_driver_next_event(client, &event);
            if (event_rc == c.GLOWCAP_ERR_WOULD_BLOCK) break;
            try expectOk(event_rc);
        }
        const state_rc = cdrv.glowcap_driver_lifecycle_state(client, &state);
        timed_out = state_rc == c.GLOWCAP_ERR_TIMEOUT;
        try std.testing.expect(state_rc == c.GLOWCAP_OK or timed_out);
    }
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try std.testing.expect(timed_out);
}

fn stepAFewTimes(loop: ?*cdrv.GlowcapDriverLoop, failed: *std.atomic.Value(bool)) void {
    for (0..3) |_| {
        const rc = cdrv.glowcap_driver_step(loop, 0);
        if (rc != c.GLOWCAP_OK and rc != c.GLOWCAP_ERR_WOULD_BLOCK) {
            failed.store(true, .release);
            return;
        }
    }
    // Hand the claim back, so the test thread's release may take it.
    if (cdrv.glowcap_driver_detach_thread(loop) != c.GLOWCAP_OK) failed.store(true, .release);
}

test "detach_thread hands a set-up loop between threads at quiescent boundaries (ADR-0024)" {
    const owned_loop = try newLoop(0x33);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    // `publish` claims the host for this thread; the detach below is the
    // quiescent handover that lets the worker's first step re-claim it (in a
    // safe build, stepping without it aborts on the affinity assert).
    try expectOk(cd.glowcap_host_publish(owned_loop.host, "widget", 6, widgetBehavior, null, null));
    try expectOk(cdrv.glowcap_driver_detach_thread(loop));

    var failed = std.atomic.Value(bool).init(false);
    const worker = try std.Thread.spawn(.{}, stepAFewTimes, .{ loop, &failed });
    worker.join();
    try std.testing.expect(!failed.load(.acquire));
}

fn releaseFromForeignThread(loop: ?*cdrv.GlowcapDriverLoop, result: *std.atomic.Value(i32)) void {
    result.store(harness.releaseLoop(loop), .release);
}

test "a foreign-thread driver release is a nonfatal refusal" {
    const owned_loop = try newLoop(0x34);
    var loop_live = true;
    defer if (loop_live) owned_loop.deinit();

    // Claim the Host on this thread. A foreign finalizer or consumer cannot
    // silently transfer a live loop; it receives a retryable refusal and the
    // owning thread retains the deterministic release barrier.
    try expectOk(cd.glowcap_host_publish(owned_loop.host, "widget", 6, widgetBehavior, null, null));
    var result = std.atomic.Value(i32).init(c.GLOWCAP_OK);
    const worker = try std.Thread.spawn(.{}, releaseFromForeignThread, .{ owned_loop.raw, &result });
    worker.join();

    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, result.load(.acquire));
    try expectOk(harness.releaseLoop(owned_loop.raw));
    loop_live = false;
}

test "a loop built over a counting context releases every byte it took" {
    var counting = @import("../../support/c_abi_counting_alloc.zig").CountingHost{};
    const spec = counting.spec();
    var ctx: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new_with_allocator(&spec, &ctx));

    const seed = hostSeed(0x35);
    var host: ?*cd.GlowcapHost = null;
    try expectOk(cd.glowcap_host_new_in(
        ctx,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.GLOWCAP_CODEC_SYRUP,
        c.GLOWCAP_CAPTP_V1_0,
        c.GLOWCAP_FEATURE_FULL,
        0,
        1,
        &host,
    ));
    var host_owned = true;
    errdefer if (host_owned) {
        _ = cd.glowcap_host_release(host);
    };
    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop));
    host_owned = false;
    try installTcp(loop);
    // An in-flight dial and a live listener both belong to loop release.
    var ticket: u64 = 0;
    try expectOk(try dialParts(loop, "tcp", "127.0.0.1:1", "127.0.0.1:1", &ticket));
    var listener_id: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(loop, "tcp", 3, "127.0.0.1:0", 11, null, &listener_id));
    try expectOk(harness.releaseLoop(loop));

    c.glowcap_context_release(ctx);
    try std.testing.expect(counting.balanced());
}

test "pending-open admission is bounded and failure publishes from reserved capacity" {
    var counting = @import("../../support/c_abi_counting_alloc.zig").CountingHost{};
    const spec = counting.spec();
    var ctx: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new_with_allocator(&spec, &ctx));

    const seed = hostSeed(0x38);
    var host: ?*cd.GlowcapHost = null;
    try expectOk(cd.glowcap_host_new_in(
        ctx,
        &seed,
        seed.len,
        frame_cap,
        1,
        c.GLOWCAP_CODEC_SYRUP,
        c.GLOWCAP_CAPTP_V1_0,
        c.GLOWCAP_FEATURE_FULL,
        0,
        1,
        &host,
    ));
    errdefer _ = cd.glowcap_host_release(host);
    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_cap1, &loop));

    var resident = AsyncFailureResident{ .wake = try glowcap.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "async-fail"));
    try expectStep(cdrv.glowcap_driver_step(loop, 0)); // Warm poll scratch.
    var ticket: u64 = 0;
    try expectOk(try dialParts(loop, "async-fail", "target", "", &ticket));
    var refused_operation_id: u64 = 99;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        try dialParts(loop, "async-fail", "other", "", &refused_operation_id),
    );
    try std.testing.expectEqual(@as(u64, 99), refused_operation_id);
    counting.fail_allocations = true;
    const step_rc = cdrv.glowcap_driver_step(loop, 10);
    counting.fail_allocations = false;
    try expectOk(step_rc);

    var event: cdrv.GlowcapDriverEvent = undefined;
    try expectOk(cdrv.glowcap_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_OPEN_FAILED, event.kind);
    try std.testing.expectEqual(ticket, event.operation_id);
    try std.testing.expectEqualStrings("ForcedAsyncDialFailure", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, event.secondary_result);
    try std.testing.expectEqualStrings("ForcedDialCleanupFailure", event.secondary_name.?[0..event.secondary_name_len]);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        cdrv.glowcap_driver_next_event(loop, &event),
    );
    var retry_operation_id: u64 = 0;
    try expectOk(try dialParts(loop, "async-fail", "retry", "", &retry_operation_id));
    try expectOk(harness.releaseLoop(loop));
    c.glowcap_context_release(ctx);
    try std.testing.expect(counting.balanced());
}
