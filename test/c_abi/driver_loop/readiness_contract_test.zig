//! The multiplexed I/O and readiness contract: a provider cannot return
//! undocumented or oversized I/O results, contradictory connect outcomes are
//! retained or refused rather than leaked, and the readiness drain rejects
//! smuggled event kinds, broken failure chains, and contradictory reports.

const std = @import("std");

const c = @import("c_abi");
const cdrv = @import("c_abi_driver");
const pancake = @import("pancake");
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

fn expectMultiplexedIoContractFailure(
    seed: u8,
    read_result: ?isize,
    write_result: ?isize,
) !void {
    const owned_loop = try newLoop(seed);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_io = true,
        .read_result = read_result,
        .write_result = write_result,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "invalid-io"));

    var locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new("invalid-io", "invalid-io".len, "endpoint", "endpoint".len, c.PANCAKE_HINTS_MAP, &locator));
    defer c.pancake_locator_release(locator);
    var locator_view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(locator, &locator_view));
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(owned_loop.raw, locator_view, null, &operation_id));
    try std.testing.expectEqual(@as(u64, 1), operation_id);
    var failed = false;
    for (0..2) |_| {
        const code = cdrv.pancake_driver_step(owned_loop.raw, 0);
        if (code == c.PANCAKE_ERR_INVALID_ARGUMENT) {
            failed = true;
            break;
        }
        try expectStep(code);
    }
    try std.testing.expect(failed);
}

test "multiplexed providers cannot return undocumented or oversized I/O results" {
    try expectMultiplexedIoContractFailure(0x50, -3, null);
    try expectMultiplexedIoContractFailure(0x51, std.math.maxInt(isize), null);
    try expectMultiplexedIoContractFailure(0x52, null, -3);
    try expectMultiplexedIoContractFailure(0x53, null, std.math.maxInt(isize));
}

test "contradictory multiplexed connect success retains rollback close failure" {
    const owned_loop = try newLoop(0x6f);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_io = true,
        .finish_connect_success_report = true,
        .conn_close_failure = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "contradictory-connect"));

    var locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new(
        "contradictory-connect",
        "contradictory-connect".len,
        "endpoint",
        "endpoint".len,
        c.PANCAKE_HINTS_MAP,
        &locator,
    ));
    defer c.pancake_locator_release(locator);
    var view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(locator, &view));
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(owned_loop.raw, view, null, &operation_id));

    var failed = false;
    for (0..2) |_| {
        const code = cdrv.pancake_driver_step(owned_loop.raw, 0);
        if (code == c.PANCAKE_ERR_INVALID_ARGUMENT) {
            failed = true;
            break;
        }
        try expectStep(code);
    }
    try std.testing.expect(failed);
    try std.testing.expectEqual(@as(usize, 1), resident.conn_close_calls);
    var message: [512]u8 = undefined;
    const message_len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ProviderContract") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ContradictoryConnectFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "2 secondary failures") != null);
}

test "multiplexed connect failure cannot leak a contradictory connection output" {
    const owned_loop = try newLoop(0x70);
    defer owned_loop.deinit();
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_io = true,
        .finish_connect_failure_output = true,
        .conn_close_failure = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "failed-connect-output"));

    var locator: ?*c.PancakeLocator = null;
    try expectOk(c.pancake_locator_new(
        "failed-connect-output",
        "failed-connect-output".len,
        "endpoint",
        "endpoint".len,
        c.PANCAKE_HINTS_MAP,
        &locator,
    ));
    defer c.pancake_locator_release(locator);
    var view: ?*const c.PancakeLocatorView = null;
    try expectOk(c.pancake_locator_borrow_view(locator, &view));
    var operation_id: u64 = 0;
    try expectOk(cdrv.pancake_driver_dial(owned_loop.raw, view, null, &operation_id));

    var failed = false;
    for (0..2) |_| {
        const code = cdrv.pancake_driver_step(owned_loop.raw, 0);
        if (code == c.PANCAKE_ERR_INVALID_ARGUMENT) {
            failed = true;
            break;
        }
        try expectStep(code);
    }
    try std.testing.expect(failed);
    try std.testing.expectEqual(@as(usize, 1), resident.conn_close_calls);
    var message: [512]u8 = undefined;
    const message_len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ProviderContract") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "ContradictoryConnectRefusal") != null);
    // The Runtime barrier retains the contract verdict, the first exact
    // consequence, and the truthful total. The operation-local chain owns the
    // later cleanup name; the bounded barrier does not pretend to retain every
    // consequence string.
    try std.testing.expect(std.mem.indexOf(u8, message[0..message_len], "2 secondary failures") != null);
}

test "a dial resident cannot smuggle unsupported readiness events" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .invalid_mask = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x37);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "invalid-count"));
    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}

test "multiplexed readiness failure preserves its exact chain" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .drain_failure = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x69);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(addMultiplexedProvider(owned_loop.raw, &table, "failed-drain"));
    _ = try resident.wake.nudge();

    try std.testing.expectEqual(c.PANCAKE_ERR_IO, cdrv.pancake_driver_step(owned_loop.raw, 0));
    var message: [256]u8 = undefined;
    const len = @min(cdrv.pancake_driver_last_error(&message, message.len), message.len);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "InjectedReadinessFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "InjectedDrainCleanupFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, message[0..len], "2 secondary failures") != null);
}

test "multiplexed readiness drain rejects contradictory failure reports" {
    inline for (.{ "success-with-failure", "failure-without-report" }, 0..) |name, index| {
        var resident = InvalidMultiplexedResident{
            .wake = try pancake.net.wake_channel.WakeChannel.open(),
            .drain_success_report = index == 0,
            .drain_empty_failure = index == 1,
        };
        defer resident.wake.deinit();
        const owned_loop = try newLoop(0x6a + index);
        defer owned_loop.deinit();
        var table = resident.table();
        try expectOk(addMultiplexedProvider(owned_loop.raw, &table, name));
        _ = try resident.wake.nudge();
        try std.testing.expectEqual(
            c.PANCAKE_ERR_INVALID_ARGUMENT,
            cdrv.pancake_driver_step(owned_loop.raw, 0),
        );
    }
}

test "a resident cannot combine connect readiness with connection events" {
    var resident = InvalidMultiplexedResident{
        .wake = try pancake.net.wake_channel.WakeChannel.open(),
        .connect_with_readable = true,
    };
    defer resident.wake.deinit();
    const owned_loop = try newLoop(0x4b);
    defer owned_loop.deinit();
    const loop = owned_loop.raw;
    var table = resident.table();
    try expectOk(addMultiplexedProvider(loop, &table, "combined-connect"));
    _ = try resident.wake.nudge();
    try std.testing.expectEqual(c.PANCAKE_ERR_INVALID_ARGUMENT, cdrv.pancake_driver_step(loop, 0));
}
