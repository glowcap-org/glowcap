//! Session handles across driver close and retirement: delivered handles
//! survive until explicit release, retirement preserves claimed sessions and
//! owns the final release transition, and a session close reaches its
//! transport barrier without closing the loop.

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

test "driver close preserves delivered session handles until explicit release" {
    const owned_server = try newLoop(0x45);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x46);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.glowcap_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cd.glowcap_host_session_break_far_vows(client_seen.dialed_session, "stale embedder", 14),
    );

    try expectOk(cdrv.glowcap_driver_close(client, &close_cancel));
    try expectOk(cdrv.glowcap_driver_close(server, &close_cancel));
    try expectStep(cdrv.glowcap_driver_step(client, 0));
    try expectStep(cdrv.glowcap_driver_step(server, 0));
    try drainEvents(client, &client_seen);
    try drainEvents(server, &server_seen);

    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(client, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.glowcap_driver_lifecycle_state(server, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);

    try expectOk(cdrv.glowcap_driver_session_release(client, client_seen.dialed_session));
    try expectOk(cdrv.glowcap_driver_session_release(server, server_seen.accepted_session));
}

test "driver retirement preserves claimed sessions and owns the final release transition" {
    const owned_server = try newLoop(0x65);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x66);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.glowcap_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    try std.testing.expect(client_seen.dialed_session != null);
    try std.testing.expect(server_seen.accepted_session != null);

    try expectOk(cdrv.glowcap_driver_retire(server));
    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_lifecycle_state(server, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);

    var refused_listener: u64 = 0;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CLOSED,
        cdrv.glowcap_driver_listen(server, "tcp", 3, "127.0.0.1:0", 11, null, &refused_listener),
    );

    try expectOk(cdrv.glowcap_driver_session_release(server, server_seen.accepted_session));
    rounds = 0;
    while (rounds < 2_000) : (rounds += 1) {
        try drainEvents(server, &server_seen);
        try expectOk(cdrv.glowcap_driver_lifecycle_state(server, &state));
        if (state == cd.GLOWCAP_LIFECYCLE_CLOSED) break;
        try expectStep(cdrv.glowcap_driver_step(server, 0));
    }
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try expectOk(cdrv.glowcap_driver_session_release(client, client_seen.dialed_session));
}

test "driver session close reaches its transport barrier without closing the loop" {
    const owned_server = try newLoop(0x47);
    defer owned_server.deinit();
    const server = owned_server.raw;
    const listener = try listenReady(server, "tcp", "127.0.0.1:0");
    try expectOk(cdrv.glowcap_driver_listener_select(server, listener));
    const locator = try readListenerLocator(server, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);

    const owned_client = try newLoop(0x48);
    defer owned_client.deinit();
    const client = owned_client.raw;
    var ticket: u64 = 0;
    try expectOk(try dialParts(client, "tcp", locator.designator, "", &ticket));

    var client_seen = Drained{};
    var server_seen = Drained{};
    var rounds: usize = 0;
    while ((client_seen.dialed_session == null or server_seen.accepted_session == null) and rounds < 2_000) : (rounds += 1) {
        try expectStep(cdrv.glowcap_driver_step(client, 5));
        try drainEvents(client, &client_seen);
        try expectStep(cdrv.glowcap_driver_step(server, 5));
        try drainEvents(server, &server_seen);
    }
    const client_session = client_seen.dialed_session orelse return error.DialNeverOpened;
    const server_session = server_seen.accepted_session orelse return error.AcceptNeverOpened;

    try expectOk(cdrv.glowcap_driver_session_close(client, client_session, &close_cancel));
    var state: u32 = undefined;
    try expectOk(cdrv.glowcap_driver_session_lifecycle_state(client, client_session, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_TERMINATING, state);
    try expectStep(cdrv.glowcap_driver_step(client, 0));
    try expectOk(cdrv.glowcap_driver_session_lifecycle_state(client, client_session, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_CLOSED, state);
    try drainEvents(client, &client_seen);

    try expectOk(cdrv.glowcap_driver_lifecycle_state(client, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);
    try expectOk(cdrv.glowcap_driver_session_release(client, client_session));
    try expectOk(cdrv.glowcap_driver_session_release(server, server_session));
}
