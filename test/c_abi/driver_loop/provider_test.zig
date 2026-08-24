//! What the provider ABI admits and refuses: complete-or-absent operation
//! groups, profile and configuration equivalence, bounded I/O results,
//! contradiction handling on connect and readiness, package leases, and
//! failure chains that survive rollback.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const crelay = @import("c_abi_net_transport_relay");
const ctcp = @import("c_abi_net_transport_tcp");
const pancake = @import("pancake");
const c_args = @import("../../support/c_abi_args.zig");
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

test "a resident cannot return a count beyond the borrowed C buffer" {
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x36);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "tcp"),
    );

    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
    // The violation poisons the adapter: stepping it again cannot silently
    // resume calls through a table that already broke memory ownership.
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "provider registration requires complete profile and configuration equivalence" {
    var first = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer first.wake.deinit();
    var other = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer other.wake.deinit();
    const owned_loop = try newLoop(0x54);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;

    var first_table = first.table();
    var profile = providerProfile("equivalence-test");
    try expectOk(addMultiplexedProviderWithProfile(loop, &first_table, &profile));
    try expectOk(addMultiplexedProviderWithProfile(loop, &first_table, &profile));

    var other_table = other.table();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProviderWithProfile(loop, &other_table, &profile),
    );

    profile.designator_scheme = cdrv.PANCAKE_DESIGNATOR_SCHEME_KEY;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProviderWithProfile(loop, &first_table, &profile),
    );
}

test "a dial-only resident registers without fake listener callbacks" {
    const owned_loop = try newLoop(0x47);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.listen = null;
    table.finish_listen = null;
    table.cancel_listen = null;
    table.listener_locator = null;
    table.listener_advertise = null;
    table.finish_accept = null;
    table.stop_listen = null;
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));

    var listener: u64 = 0;
    const name = "invalid-count";
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listen(loop, name.ptr, name.len, "endpoint".ptr, "endpoint".len, null, &listener),
    );
}

test "resident operation groups must be complete or absent" {
    const owned_loop = try newLoop(0x48);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.finish_accept = null;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        addMultiplexedProvider(loop, &table, "invalid-count"),
    );
}

test "an immediate multiplexed listener registers without completion callbacks" {
    const owned_loop = try newLoop(0x5b);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .listen_without_handle = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    table.finish_listen = null;
    table.cancel_listen = null;
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "immediate-listener"));
}

test "an immediate-only multiplexed provider cannot publish pending setup" {
    const owned_loop = try newLoop(0x5c);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .pending_listen = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    table.finish_listen = null;
    table.cancel_listen = null;
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "invalid-pending"));

    var listener: u64 = 0;
    try expectOk(cdrv.pancake_driver_listen(
        owned_loop.raw,
        "invalid-pending",
        "invalid-pending".len,
        "",
        0,
        null,
        &listener,
    ));
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_step(owned_loop.raw, 0),
    );
}

test "each stream profile requires its own implementation table" {
    const owned_loop = try newEmptyLoop(0x5d);
    defer owned_loop.deinit();
    var tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.pancake_tcp_netlayer_release(tcp);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp, &provider));
    var entries = [2]cdrv.PancakeTransportProviderEntry{
        provider.entries.?[0],
        provider.entries.?[1],
    };
    entries[1].implementation = entries[0].implementation;
    provider.entries = &entries;
    provider.entry_count = entries.len;

    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        harness.addProvider(owned_loop.raw, &provider),
    );
}

test "driver failure records refuse before provider or loop ownership commits" {
    const owned_loop = try newEmptyLoop(0x66);
    var loop_live = true;
    defer if (loop_live) owned_loop.deinit();
    var tcp: ?*ctcp.PancakeTcpNetlayer = null;
    try expectOk(ctcp.pancake_tcp_netlayer_new(&default_tcp_config, &tcp));
    defer ctcp.pancake_tcp_netlayer_release(tcp);
    var provider: cdrv.PancakeTransportProvider = undefined;
    try expectOk(ctcp.pancake_tcp_transport_provider(tcp, &provider));

    try std.testing.expectEqual(
        c.PANCAKE_ERR_NULL_POINTER,
        cdrv.pancake_driver_add_provider(owned_loop.raw, &provider, null),
    );
    var invalid = cdrv.PancakeDriverFailure.init();
    invalid.struct_size = @offsetOf(cdrv.PancakeDriverFailure, "secondary_name_len");
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(owned_loop.raw, &provider, &invalid),
    );
    var present: u8 = 1;
    try expectOk(cdrv.pancake_driver_has_transport(owned_loop.raw, "tcp", 3, &present));
    try std.testing.expectEqual(@as(u8, 0), present);

    try expectOk(harness.addProvider(owned_loop.raw, &provider));
    try std.testing.expectEqual(c.PANCAKE_ERR_NULL_POINTER, cdrv.pancake_driver_release(owned_loop.raw, null));
    invalid = cdrv.PancakeDriverFailure.init();
    invalid.abi_version += 1;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_release(owned_loop.raw, &invalid),
    );
    try expectOk(cdrv.pancake_driver_has_transport(owned_loop.raw, "tcp", 3, &present));
    try std.testing.expectEqual(@as(u8, 1), present);
    try expectOk(harness.releaseLoop(owned_loop.raw));
    loop_live = false;
}

test "an external-claim-only resident routes adoption through the generic driver" {
    const owned_loop = try newLoop(0x49);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{ .wake = try pancake.net.wake_channel.WakeChannel.open() };
    defer resident.wake.deinit();
    var table = resident.table();
    table.start_connect = null;
    table.finish_connect = null;
    table.cancel_connect = null;
    table.listen = null;
    table.finish_listen = null;
    table.cancel_listen = null;
    table.listener_locator = null;
    table.listener_advertise = null;
    table.finish_accept = null;
    table.stop_listen = null;
    table.claim_external = InvalidMultiplexedResident.claimExternal;

    const loop = owned_loop.raw;
    try expectOk(addMultiplexedProvider(loop, &table, "external-only"));
    var present: u8 = 0;
    try expectOk(cdrv.pancake_driver_has_transport(loop, "external-only", 13, &present));
    try std.testing.expectEqual(@as(u32, 1), present);

    var ticket: u64 = 0;
    try expectOk(cdrv.pancake_driver_adopt_external(
        loop,
        "external-only",
        13,
        7,
        cdrv.PANCAKE_DRIVER_ADOPT_DIALED,
        &ticket,
    ));
    try std.testing.expect(ticket != 0);
    var event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED, event.kind);
    try std.testing.expectEqual(ticket, event.operation_id);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, event.primary_result);
    try std.testing.expectEqualStrings("InvalidExternalSubject", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, event.secondary_result);
    try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
    try std.testing.expectEqualStrings("ExternalClaimCleanupFailed", event.secondary_name.?[0..event.secondary_name_len]);
}

test "the provider ABI preserves typed locators and holds one package lease" {
    const opaque_bytes = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(opaque_bytes);
    for (opaque_bytes, 0..) |*byte, i| byte.* = @truncate(i);

    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = opaque_bytes,
    };
    defer resident.wake.deinit();

    const host = try newByteFedHost(0x4a);
    errdefer _ = cd.pancake_host_release(host);
    var loop: ?*cdrv.PancakeDriverLoop = null;
    try expectOk(cdrv.pancake_driver_take_host(host, &driver_options_1s, &loop));
    var loop_live = true;
    defer if (loop_live) {
        _ = harness.releaseLoop(loop);
    };

    var table = resident.table();
    const profiles = [_]cdrv.PancakeTransportProfile{
        providerProfile("typed-test"),
        providerProfile("typed-test-alt"),
    };
    const entries = [_]cdrv.PancakeTransportProviderEntry{
        .{
            .profile = &profiles[0],
            .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &table,
        },
        .{
            .profile = &profiles[1],
            .execution_model = cdrv.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &table,
        },
    };
    const provider: cdrv.PancakeTransportProvider = .{
        .abi_version = cdrv.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.PancakeTransportProvider),
        .entries = &entries,
        .entry_count = entries.len,
        .lease_ctx = &resident,
        .same_configuration = sameStaticProvider,
        .retain = TypedResident.retain,
        .release = TypedResident.release,
    };
    try expectOk(harness.addProvider(loop, &provider));
    try std.testing.expectEqual(@as(usize, 1), resident.retains);
    try std.testing.expectEqual(@as(usize, 0), resident.releases);

    var present: u8 = 0;
    try expectOk(cdrv.pancake_driver_has_transport(loop, "typed-test", "typed-test".len, &present));
    try std.testing.expectEqual(@as(u8, 1), present);
    try expectOk(cdrv.pancake_driver_has_transport(loop, "typed-test-alt", "typed-test-alt".len, &present));
    try std.testing.expectEqual(@as(u8, 1), present);
    try expectOk(cdrv.pancake_driver_has_transport(loop, "absent", "absent".len, &present));
    try std.testing.expectEqual(@as(u8, 0), present);

    const listener = try listenReady(loop, "typed-test", "listener-peer");
    const published = try readListenerLocator(loop, listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, published);
    try std.testing.expectEqualStrings("typed-test", published.transport);
    try std.testing.expectEqualStrings("listener-peer", published.designator);
    try std.testing.expectEqual(@as(usize, 5), published.hints.entries.len);
    try std.testing.expectEqualStrings("primary", published.hints.entries[0].value.string);
    try std.testing.expectEqualSlices(u8, opaque_bytes, published.hints.entries[1].value.bytes);
    try std.testing.expect(published.hints.entries[2].value.boolean);
    try std.testing.expectEqual(@as(i64, 73), published.hints.entries[3].value.integer);
    try std.testing.expectEqualStrings(pancake.ocapn.model.transport.hint_features, published.hints.entries[4].name);
    try std.testing.expectEqualStrings(
        "pipelining,handoff,wire_delta,sturdyref,untag",
        published.hints.entries[4].value.string,
    );

    var restoration_len: usize = 0;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(resident.restoration_state.len, restoration_len);
    var short: [4]u8 = @splat(0xa5);
    try std.testing.expectEqual(
        c.PANCAKE_ERR_BUFFER_TOO_SMALL,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, &short, short.len, &restoration_len),
    );
    const expected_short: [short.len]u8 = @splat(0xa5);
    try std.testing.expectEqualSlices(u8, &expected_short, &short);
    var restoration: ["typed-restoration-state".len]u8 = undefined;
    try expectOk(cdrv.pancake_driver_listener_restoration_state(
        loop,
        listener,
        &restoration,
        restoration.len,
        &restoration_len,
    ));
    try std.testing.expectEqualStrings(resident.restoration_state, restoration[0..restoration_len]);

    const second_listener = try listenReady(loop, "typed-test-alt", "listener-peer");
    const second_published = try readListenerLocator(loop, second_listener);
    defer pancake.ocapn.model.freePeerLocator(std.testing.allocator, second_published);
    try std.testing.expectEqualStrings("typed-test-alt", second_published.transport);

    var dial_locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new("typed-test", 10, "dial-peer", 9, c.PANCAKE_HINTS_MAP, &dial_locator));
    defer c.pancake_locator_release(dial_locator);
    try expectOk(c.pancake_locator_add_string(dial_locator, "route", 5, "alternate", 9));
    try expectOk(c.pancake_locator_add_bytes(dial_locator, "token", 5, &.{ 0, 0xff, 7 }, 3));
    try expectOk(c.pancake_locator_add_boolean(dial_locator, "enabled", 7, 1));
    try expectOk(c.pancake_locator_add_integer(dial_locator, "limit", 5, -42));
    var dial_view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(dial_locator, &dial_view));
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(loop, dial_view, null, &operation_id));
    try std.testing.expect(operation_id != 0);
    try std.testing.expect(resident.dial_verified);
    var dial_event: cdrv.PancakeDriverEvent = undefined;
    try expectOk(cdrv.pancake_driver_next_event(loop, &dial_event));
    try std.testing.expectEqual(cdrv.PANCAKE_DRIVER_EVENT_OPEN_FAILED, dial_event.kind);
    try std.testing.expectEqual(operation_id, dial_event.operation_id);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, dial_event.primary_result);
    try std.testing.expectEqual(cdrv.PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE, dial_event.carrier_phase);
    try std.testing.expectEqual(
        cdrv.PANCAKE_CARRIER_DETAIL_PEER_ALERT | cdrv.PANCAKE_CARRIER_DETAIL_ENGINE_CODE,
        dial_event.carrier_detail_flags,
    );
    try std.testing.expectEqual(@as(u32, 0x21), dial_event.carrier_verification_flags);
    try std.testing.expectEqual(@as(u32, 42), dial_event.carrier_peer_alert);
    try std.testing.expectEqual(@as(i32, -0x2700), dial_event.carrier_engine_code);
    try std.testing.expectEqualStrings("TypedDialRefused", dial_event.primary_name.?[0..dial_event.primary_name_len]);

    resident.invalid_restoration_result = true;
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_listener_restoration_state(loop, listener, null, 0, &restoration_len),
    );
    try std.testing.expectEqual(@as(usize, 0), restoration_len);

    // The earlier contract failure remains the exact teardown cause, but the
    // consuming release cannot return INVALID_ARGUMENT: that code exclusively
    // means admission refused and the handle is still live.
    var release_failure = cdrv.PancakeDriverFailure.init();
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, cdrv.pancake_driver_release(loop, &release_failure));
    try std.testing.expectEqual(c.PANCAKE_ERR_INTERNAL, release_failure.primary_result);
    try std.testing.expectEqualStrings(
        "ProviderContract",
        release_failure.primary_name.?[0..release_failure.primary_name_len],
    );
    loop_live = false;
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
}

test "provider registration keeps rollback release failure secondary" {
    var first: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer first.wake.deinit();
    var conflicting: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .release_code = c.PANCAKE_ERR_IO,
    };
    defer conflicting.wake.deinit();

    const owned_loop = try newEmptyLoop(0x63);
    var loop_live = true;
    defer if (loop_live) {
        _ = harness.releaseLoop(owned_loop.raw);
    };
    var first_table = first.table();
    var conflicting_table = conflicting.table();
    const profile = providerProfile("release-conflict");
    const first_provider = typedProvider(&first, &first_table, &profile);
    const conflicting_provider = typedProvider(&conflicting, &conflicting_table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &first_provider));

    var registration_failure = cdrv.PancakeDriverFailure.init();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        cdrv.pancake_driver_add_provider(owned_loop.raw, &conflicting_provider, &registration_failure),
    );
    try std.testing.expectEqual(@as(usize, 1), conflicting.retains);
    try std.testing.expectEqual(@as(usize, 1), conflicting.releases);
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, registration_failure.primary_result);
    try std.testing.expectEqualStrings(
        "ProviderConfigurationConflict",
        registration_failure.primary_name.?[0..registration_failure.primary_name_len],
    );
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, registration_failure.secondary_result);
    try std.testing.expectEqual(@as(u32, 1), registration_failure.secondary_count);
    try std.testing.expectEqualStrings(
        "TestPackageReleaseFailed",
        registration_failure.secondary_name.?[0..registration_failure.secondary_name_len],
    );

    try expectOk(harness.releaseLoop(owned_loop.raw));
    loop_live = false;
}

test "contradictory retain diagnostics retire the committed package lease" {
    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .retain_reports_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x65);
    defer owned_loop.deinit();
    var table = resident.table();
    const profile = providerProfile("bad-retain-report");
    const provider = typedProvider(&resident, &table, &profile);

    try std.testing.expectEqual(
        c.PANCAKE_ERR_INVALID_ARGUMENT,
        harness.addProvider(owned_loop.raw, &provider),
    );
    try std.testing.expectEqual(@as(usize, 1), resident.retains);
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
}

test "driver release returns final provider package failure" {
    var resident: TypedResident = .{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
        .release_code = c.PANCAKE_ERR_IO,
    };
    defer resident.wake.deinit();
    const owned_loop = try newEmptyLoop(0x64);
    var table = resident.table();
    const profile = providerProfile("release-failure");
    const provider = typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned_loop.raw, &provider));

    var release_failure = cdrv.PancakeDriverFailure.init();
    try std.testing.expectEqual(
        c.PANCAKE_ERR_IO,
        cdrv.pancake_driver_release(owned_loop.raw, &release_failure),
    );
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
    try std.testing.expectEqual(c.PANCAKE_ERR_IO, release_failure.primary_result);
    try std.testing.expectEqualStrings(
        "TestPackageReleaseFailed",
        release_failure.primary_name.?[0..release_failure.primary_name_len],
    );
    try std.testing.expectEqual(@as(u32, 0), release_failure.secondary_count);
}
