//! Taking a byte-fed Host into the driver: only a quiescent Host transfers,
//! borrowed actions and byte-fed session state refuse, and a failed adoption
//! rolls runtime ownership back.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");
const ws_relay = @import("../../support/ws_relay.zig");

const harness = @import("harness.zig");
const residents = @import("residents.zig");
const StreamAdoptionResident = @import("stream_adoption_resident.zig").StreamAdoptionResident;
const typed_resident = @import("typed_resident.zig");
const frame_cap = harness.frame_cap;
const sessionLimitOptions = harness.sessionLimitOptions;
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

test "a contextless Host keeps its queued dial when driver adoption is refused" {
    var host = try @import("../host/harness.zig").newHost(0x33);
    var sentinel: u8 = 0;
    const original: *cdrv.GlowcapDriverLoop = @ptrCast(&sentinel);
    var loop: ?*cdrv.GlowcapDriverLoop = original;
    var adopted = false;
    errdefer {
        const result = c.ReleaseResult.fromRaw(if (adopted) harness.releaseLoop(loop) else cd.glowcap_host_release(host));
        if (result.ownership == .retained) @panic("contextless Host retained at teardown");
    }

    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_enliven(host, sturdyref, sturdyref.len, &vow));
    const rc = cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop);
    adopted = rc == c.GLOWCAP_OK;
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, rc);
    try std.testing.expectEqual(original, loop.?);
    var message: [128]u8 = undefined;
    const len = cdrv.glowcap_driver_last_error(&message, message.len);
    try std.testing.expect(len < message.len);
    try std.testing.expect(std.mem.find(u8, message[0..len], "glowcap_host_new_in") != null);
    var action: cd.GlowcapHostAction = undefined;
    try expectOk(cd.glowcap_host_next_action(host, &action));
    try std.testing.expectEqual(cd.GLOWCAP_HOST_ACTION_DIAL, action.kind);
    const released = cd.glowcap_host_release(host);
    if (c.ReleaseResult.fromRaw(released).ownership == .consumed) host = null;
    try expectOk(released);
}

test "a quiescent byte-fed Host transfers exclusively to the driver" {
    var owned = try newByteFedHost(0x31, null);
    defer owned.deinit();
    const host = owned.host;
    try expectOk(cd.glowcap_host_publish(host, "widget", 6, widgetBehavior, null, null));

    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw));
    const loop = owned.raw;
    try installTcp(loop);

    // One runtime owns transport execution and terminal release. Neither a
    // second loop nor the old Host release path can acquire that authority.
    var second: ?*cdrv.GlowcapDriverLoop = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &second),
    );
    try std.testing.expect(second == null);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, cd.glowcap_host_release(host));
    var limits = sessionLimitOptions(0, 17, 0, 0);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cd.glowcap_host_set_session_limits(host, &limits),
    );

    // Application state created before transfer remains on the same Host, and
    // transport lifecycle is immediately usable through the generic driver.
    const listener = try listenReady(loop, "tcp", "127.0.0.1:0");
    const locator = try readListenerLocator(loop, listener);
    defer glowcap.ocapn.model.freePeerLocator(std.testing.allocator, locator);
    try std.testing.expectEqualStrings("tcp", locator.transport);
}

test "an unborrowed Host dial transfers with the Host" {
    var owned = try newByteFedHost(0x35, null);
    defer owned.deinit();
    const host = owned.host;
    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_enliven(host, sturdyref, sturdyref.len, &vow));
    try std.testing.expect(vow != 0);

    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw));

    // The driver owns the original queued action. The former byte-fed drain
    // cannot race it after the transaction commits.
    var action: cd.GlowcapHostAction = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cd.glowcap_host_next_action(host, &action),
    );
}

test "the creating Context drains its Host report after driver release" {
    var owned = try newEmptyLoop(0x37);
    defer owned.deinit();
    var host_id: u64 = 0;
    try expectOk(cd.glowcap_host_diagnostic_id(owned.host, &host_id));
    try std.testing.expect(host_id != 0);
    const operation = "observer.notify";
    const cause = "ObserverFailed";
    var report = std.mem.zeroes(c.GlowcapFailureReport);
    report.abi_version = c.GLOWCAP_FAILURE_EVENT_ABI_VERSION;
    report.struct_size = @sizeOf(c.GlowcapFailureReport);
    report.layer = c.GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER;
    report.scope_kind = c.GLOWCAP_FAILURE_SCOPE_HOST;
    report.scope_id = host_id;
    report.primary_result = c.GLOWCAP_ERR_INTERNAL;
    report.operation = operation.ptr;
    report.operation_len = operation.len;
    report.primary_name = cause.ptr;
    report.primary_name_len = cause.len;
    try expectOk(c.glowcap_context_report_failure(owned.context, &report));

    var failure = cdrv.GlowcapDriverFailure.init();
    try expectOk(owned.release(&failure));
    var event: c.GlowcapFailureEvent = undefined;
    var payload: [128]u8 = undefined;
    var required: usize = 0;
    try expectOk(c.glowcap_context_next_failure(owned.context, &event, &payload, payload.len, &required));
    try std.testing.expectEqual(c.GLOWCAP_FAILURE_SCOPE_HOST, event.scope_kind);
    try std.testing.expectEqual(host_id, event.scope_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_INTERNAL, event.primary_result);
    try std.testing.expectEqualStrings(cause, event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        c.glowcap_context_next_failure(owned.context, &event, &payload, payload.len, &required),
    );
}

test "borrowing a Host action prevents runtime transfer" {
    var owned = try newByteFedHost(0x36, null);
    defer owned.deinit();
    const host = owned.host;
    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_enliven(host, sturdyref, sturdyref.len, &vow));

    var action: cd.GlowcapHostAction = undefined;
    try expectOk(cd.glowcap_host_next_action(host, &action));
    try std.testing.expectEqual(cd.GLOWCAP_HOST_ACTION_DIAL, action.kind);

    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw),
    );
    try std.testing.expect(owned.raw == null);
}

test "failed Host adoption rolls runtime ownership back" {
    const CountingHost = @import("../../support/c_abi_counting_alloc.zig").CountingHost;
    var counting = CountingHost{};
    {
        const spec = counting.spec();
        var owned = try newByteFedHost(0x32, &spec);
        defer owned.deinit();
        const host = owned.host;
        errdefer {
            counting.fail_allocations = false;
            counting.allocations_before_failure = null;
        }
        counting.fail_allocations = true;
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_INTERNAL,
            cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw),
        );
        try std.testing.expect(owned.raw == null);
        counting.fail_allocations = false;

        // Let the loop allocation succeed, then fail its runtime scaffolding. The
        // rollback destructor must not cancel the borrowed core before returning
        // the C drive token.
        counting.allocations_before_failure = 1;
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_INTERNAL,
            cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw),
        );
        try std.testing.expect(owned.raw == null);
        counting.allocations_before_failure = null;

        var state: u32 = undefined;
        try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
        try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);
        try expectOk(cd.glowcap_host_publish(host, "after-rollback", 14, widgetBehavior, null, null));
        try expectOk(owned.release(null));
    }
    try std.testing.expect(counting.balanced());
}

test "a closing byte-fed Host cannot transfer to a new driver" {
    var owned = try newByteFedHost(0x3b, null);
    defer owned.deinit();
    const host = owned.host;
    try expectOk(cd.glowcap_host_close(host, &close_cancel, 0));

    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CLOSED,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw),
    );
    try std.testing.expect(owned.raw == null);

    // Failed Zig adoption returns the C drive token to the byte-fed owner.
    try expectOk(owned.release(null));
}

test "a Host with byte-fed session state cannot transfer runtimes" {
    var owned = try newByteFedHost(0x30, null);
    defer owned.deinit();
    const host = owned.host;
    try expectOk(cd.glowcap_host_ensure_advertised_locator(host, "tcp", 3));
    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openAccepted(host, "tcp", 3, &session));
    defer _ = cd.glowcap_host_session_release(session);

    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &owned.raw),
    );
    try std.testing.expect(owned.raw == null);
}
