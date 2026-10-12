//! The listener's life under the provider seam: activation, advertisement,
//! and restoration preserve the provider failure chain. A pending listener
//! closes without publishing. Accepts cancel, park, and survive close in the
//! order the events committed.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
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

test "listener close remains available after terminal provider failure" {
    const owned_loop = try newLoop(0x5e);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        loop,
        glowcap.ocapn.model.transport.tcp.ptr,
        glowcap.ocapn.model.transport.tcp.len,
        "127.0.0.1:0",
        "127.0.0.1:0".len,
        null,
        &listener,
    ));
    try awaitListenerReady(loop, listener);
    var readiness_fd: i32 = -1;
    try expectOk(cdrv.glowcap_driver_readiness_fd(loop, &readiness_fd));

    var resident = InvalidMultiplexedResident{ .wake = try glowcap.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "terminal-failure"));
    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_step(loop, 0));
    try expectOk(harness.closeListener(loop, listener));

    // Provider work stays fail-stop, but that failure cannot strand the
    // owner's explicit terminal barrier.
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_step(loop, 0));
    try expectOk(cdrv.glowcap_driver_close(loop, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    while (state != cd.GLOWCAP_LIFECYCLE_CLOSED) {
        try expectStep(cdrv.glowcap_driver_step(loop, 0));
        try expectOk(cdrv.glowcap_driver_lifecycle_state(loop, &state));
    }

    // Close initiation posts one wake. Terminal stepping must consume it
    // explicitly rather than relying on that stale level to busy-spin the
    // lifecycle forward.
    var fds = [_]std.posix.pollfd{.{ .fd = readiness_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_step(loop, 0));
}

test "an active listener failure retires its stable id through a reserved event" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .stop_listen_pending = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x6a);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("typed-test");
    var provider = typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &provider));

    const listener_id = try listenReady(owned_loop.raw, "typed-test", "listener-peer");
    resident.failed_accept_route = resident.listeners[0].route;
    _ = try resident.wake.nudge();
    try expectOk(cdrv.glowcap_driver_step(owned_loop.raw, 1_000));

    var event: cdrv.GlowcapDriverEvent = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        cdrv.glowcap_driver_next_event(owned_loop.raw, &event),
    );
    try expectOk(cdrv.glowcap_driver_step(owned_loop.raw, 1_000));
    try expectOk(cdrv.glowcap_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, event.kind);
    try std.testing.expectEqual(listener_id, event.listener_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, event.primary_result);
    try std.testing.expectEqualStrings("ForcedAcceptFailure", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, event.secondary_result);
    try std.testing.expectEqualStrings("ForcedAcceptCleanupFailure", event.secondary_name.?[0..event.secondary_name_len]);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    var locator: cdrv.GlowcapLocatorView = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_locator(owned_loop.raw, listener_id, &locator),
    );
    try std.testing.expect(!resident.listeners[0].active);
    try std.testing.expectEqual(@as(usize, 2), resident.stop_listen_calls);
}

test "listener activation preserves the provider locator failure chain" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .locator_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x77);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("typed-test");
    var provider = typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &provider));

    var listener_id: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        owned_loop.raw,
        "typed-test",
        "typed-test".len,
        "listener-peer",
        "listener-peer".len,
        null,
        &listener_id,
    ));

    var event: cdrv.GlowcapDriverEvent = undefined;
    try expectOk(cdrv.glowcap_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, event.kind);
    try std.testing.expectEqual(listener_id, event.listener_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, event.primary_result);
    try std.testing.expectEqualStrings("ForcedLocatorFailure", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, event.secondary_result);
    try std.testing.expectEqualStrings(
        "ForcedLocatorCleanupFailure",
        event.secondary_name.?[0..event.secondary_name_len],
    );
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), resident.stop_listen_calls);
    try std.testing.expect(!resident.listeners[0].active);
    var locator: cdrv.GlowcapLocatorView = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_locator(owned_loop.raw, listener_id, &locator),
    );
}

test "listener advertisement preserves the provider failure chain without retiring the listener" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x78);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("typed-test");
    var provider = typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &provider));

    const listener_id = try listenReady(owned_loop.raw, "typed-test", "listener-peer");
    var locator: cdrv.GlowcapLocatorView = undefined;
    try expectOk(cdrv.glowcap_driver_listener_locator(owned_loop.raw, listener_id, &locator));
    resident.advertise_failure = true;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_IO,
        cdrv.glowcap_driver_listener_advertise(owned_loop.raw, listener_id, &locator),
    );
    var message: [256]u8 = undefined;
    const message_len = @min(cdrv.glowcap_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ForcedAdvertiseFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ForcedAdvertiseCleanupFailure") != null);
    try std.testing.expect(resident.listeners[0].active);
    try std.testing.expectEqual(@as(usize, 0), resident.stop_listen_calls);
    try expectOk(cdrv.glowcap_driver_listener_locator(owned_loop.raw, listener_id, &locator));
}

test "listener restoration state preserves the provider failure chain" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .restoration_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x79);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("typed-test");
    var provider = typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &provider));

    const listener_id = try listenReady(owned_loop.raw, "typed-test", "listener-peer");
    var needed: usize = 99;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_IO,
        cdrv.glowcap_driver_listener_restoration_state(owned_loop.raw, listener_id, null, 0, &needed),
    );
    try std.testing.expectEqual(@as(usize, 0), needed);
    var message: [256]u8 = undefined;
    const message_len = @min(cdrv.glowcap_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ForcedRestorationFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ForcedRestorationCleanupFailure") != null);
    try std.testing.expect(resident.listeners[0].active);
    try std.testing.expectEqual(@as(usize, 0), resident.stop_listen_calls);
}

test "pending listener close retains its retry identity and refuses every non-close verb" {
    var resident: TypedResident = .{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .stop_listen_pending = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x7a);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("typed-test");
    var provider = typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &provider));

    const listener_id = try listenReady(owned_loop.raw, "typed-test", "listener-peer");
    try expectOk(cdrv.glowcap_driver_listener_select(owned_loop.raw, listener_id));

    var failure = cdrv.GlowcapDriverFailure.init();
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        cdrv.glowcap_driver_listener_close(owned_loop.raw, listener_id, &failure),
    );
    try std.testing.expectEqual(@as(usize, 1), resident.stop_listen_calls);

    var locator: cdrv.GlowcapLocatorView = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_locator(owned_loop.raw, listener_id, &locator),
    );
    var needed: usize = 99;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_restoration_state(owned_loop.raw, listener_id, null, 0, &needed),
    );
    try std.testing.expectEqual(@as(usize, 0), needed);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        advertiseParts(owned_loop.raw, listener_id, "typed-test", "listener-peer", "127.0.0.1:1"),
    );
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NOT_FOUND,
        cdrv.glowcap_driver_listener_select(owned_loop.raw, listener_id),
    );

    try expectStep(cdrv.glowcap_driver_step(owned_loop.raw, 1_000));
    try expectOk(harness.closeListener(owned_loop.raw, listener_id));
    try std.testing.expectEqual(c.GLOWCAP_ERR_NOT_FOUND, harness.closeListener(owned_loop.raw, listener_id));
    try std.testing.expectEqual(@as(usize, 2), resident.stop_listen_calls);
}

test "a successful multiplexed listen must return its listener handle" {
    var resident = InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .listen_without_handle = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x4c);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "missing-listener"));
    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(loop, "missing-listener", "missing-listener".len, "", 0, null, &listener));
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_step(loop, 0),
    );
    var event: cdrv.GlowcapDriverEvent = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        cdrv.glowcap_driver_next_event(loop, &event),
    );
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);
    try std.testing.expectEqual(@as(usize, 0), resident.stop_listen_calls);
}

test "an immediate-only stream listener rejects pending ownership without a fake cancel callback" {
    var stream: MalformedImmediateStream = .{};
    const owned_loop = try newEmptyLoop(0x5d);
    defer owned_loop.deinit();
    var table = stream.table();
    try expectOk(addStreamProvider(owned_loop.raw, &table, "malformed-immediate-stream"));

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        owned_loop.raw,
        "malformed-immediate-stream",
        "malformed-immediate-stream".len,
        "endpoint",
        "endpoint".len,
        null,
        &listener,
    ));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_step(owned_loop.raw, 0));
    try std.testing.expectEqual(@as(usize, 1), stream.listener_close_calls);
}

test "closing a pending listener abandons setup without publishing a failure" {
    var resident = InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .pending_listen = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x60);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "pending-listener-close"));

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        owned_loop.raw,
        "pending-listener-close",
        "pending-listener-close".len,
        "endpoint",
        "endpoint".len,
        null,
        &listener,
    ));
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_NULL_POINTER,
        cdrv.glowcap_driver_listener_close(owned_loop.raw, listener, null),
    );
    var malformed = cdrv.GlowcapDriverFailure.init();
    malformed.abi_version += 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_listener_close(owned_loop.raw, listener, &malformed),
    );
    try std.testing.expectEqual(@as(usize, 0), resident.cancel_listen_calls);
    try expectOk(harness.closeListener(owned_loop.raw, listener));
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);

    var event: cdrv.GlowcapDriverEvent = undefined;
    try std.testing.expectEqual(c.GLOWCAP_ERR_WOULD_BLOCK, cdrv.glowcap_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(c.GLOWCAP_ERR_NOT_FOUND, harness.closeListener(owned_loop.raw, listener));
}

test "multiplexed listener start preserves the provider failure identity" {
    var resident = InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x70);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "listen-start-failure"));

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        owned_loop.raw,
        "listen-start-failure",
        "listen-start-failure".len,
        "endpoint",
        "endpoint".len,
        null,
        &listener,
    ));
    try expectOk(cdrv.glowcap_driver_step(owned_loop.raw, 0));

    var event: cdrv.GlowcapDriverEvent = undefined;
    try expectOk(cdrv.glowcap_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, event.kind);
    try std.testing.expectEqual(listener, event.listener_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, event.primary_result);
    try std.testing.expectEqualStrings("ListenRefused", event.primary_name.?[0..event.primary_name_len]);
}

test "multiplexed listener finish preserves provider cleanup consequences" {
    var resident = InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .pending_listen = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x71);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "listen-finish-failure"));

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(
        owned_loop.raw,
        "listen-finish-failure",
        "listen-finish-failure".len,
        "endpoint",
        "endpoint".len,
        null,
        &listener,
    ));
    try expectOk(cdrv.glowcap_driver_step(owned_loop.raw, 0));

    var event: cdrv.GlowcapDriverEvent = undefined;
    try expectOk(cdrv.glowcap_driver_next_event(owned_loop.raw, &event));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, event.kind);
    try std.testing.expectEqual(listener, event.listener_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, event.primary_result);
    try std.testing.expectEqualStrings("FinishListenRefused", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, event.secondary_result);
    try std.testing.expectEqualStrings("FinishListenCleanupFailed", event.secondary_name.?[0..event.secondary_name_len]);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqual(@as(?u64, null), resident.pending_listen_route);
    try std.testing.expectEqual(@as(usize, 0), resident.cancel_listen_calls);
}

test "a failed provider callback cannot publish listener ownership" {
    var resident = InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .listen_output_on_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x58);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "failed-output"));

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(loop, "failed-output", "failed-output".len, "", 0, null, &listener));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_step(loop, 0));
}

test "a malformed pending multiplexed listener retires every published owner" {
    var resident = InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .pending_listen_with_stream_fields = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x59);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "malformed-pending"));

    var listener: u64 = 0;
    try expectOk(cdrv.glowcap_driver_listen(loop, "malformed-pending", "malformed-pending".len, "", 0, null, &listener));
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cdrv.glowcap_driver_step(loop, 0));
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);
    try std.testing.expectEqual(@as(usize, 1), resident.stop_listen_calls);
}

test "listener close cancels a connection still in the accepted handshake" {
    const owned_server = try newLoop(0x3a);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try glowcap.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    // Accept the socket and stage its CapTP handshake, but send no hello.
    try expectLoopReadable(server);
    try expectStep(cdrv.glowcap_driver_step(server, 0));
    try expectOk(harness.closeListener(server, listener));

    var seen = Drained{};
    try drainEvents(server, &seen);
    try std.testing.expect(!seen.accepted);
    // Later steps cannot resurrect the canceled accept under the retired id.
    try expectStep(cdrv.glowcap_driver_step(server, 0));
    try drainEvents(server, &seen);
    try std.testing.expect(!seen.accepted);
}

test "driver release retires pending accepts before listener storage" {
    const owned_server = try newLoop(0x61);
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try glowcap.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    try expectLoopReadable(server);
    try expectStep(cdrv.glowcap_driver_step(server, 0));
    try expectOk(harness.releaseLoop(server));
}

test "an unselected listener refuses accept visibly until routing policy is selected" {
    const owned_server = try newLoop(0x3d);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try glowcap.net.tcp.parseDesignator(locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    try expectLoopReadable(server);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_step(server, 0),
    );
    var message: [128]u8 = undefined;
    const message_len = cdrv.glowcap_driver_last_error(&message, message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "MissingAdvertisedLocator") != null);

    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    try expectStep(cdrv.glowcap_driver_step(server, 0));
    try expectOk(harness.closeListener(server, listener));
}

test "listener close preserves an ACCEPTED event committed by an earlier step" {
    const owned_server = try newLoop(0x3b);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x3c);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var rounds: usize = 0;
    while (client_seen.dialed_session == null and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        // Do not drain the server: ACCEPTED must remain native-
        // owned across listener close once the handshake commits it.
        try expectStep(cdrv.glowcap_driver_step(server, 5));
    }
    try std.testing.expect(client_seen.dialed_session != null);

    try expectOk(harness.closeListener(server, listener));
    var server_seen = Drained{};
    try drainEvents(server, &server_seen);
    try std.testing.expect(server_seen.accepted_session != null);
    try std.testing.expectEqual(listener, server_seen.accepted_listener);

    try expectOk(cdrv.glowcap_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.glowcap_driver_session_release(server, server_seen.accepted_session));
}
