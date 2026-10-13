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

test "a quiescent byte-fed Host transfers exclusively to the driver" {
    const host = try newByteFedHost(0x31);
    try expectOk(cd.glowcap_host_publish(host, "widget", 6, widgetBehavior, null, null));

    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop));
    try installTcp(loop);
    defer _ = harness.releaseLoop(loop);

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
    const host = try newByteFedHost(0x35);
    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_enliven(host, sturdyref, sturdyref.len, &vow));
    try std.testing.expect(vow != 0);

    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try expectOk(cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop));
    defer _ = harness.releaseLoop(loop);

    // The driver owns the original queued action. The former byte-fed drain
    // cannot race it after the transaction commits.
    var action: cd.GlowcapHostAction = undefined;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cd.glowcap_host_next_action(host, &action),
    );
}

test "borrowing a Host action prevents runtime transfer" {
    const host = try newByteFedHost(0x36);
    defer _ = cd.glowcap_host_release(host);
    const sturdyref = "ocapn://127.0.0.1%3A7999.tcp/s/d2lkZ2V0";
    var vow: u64 = 0;
    try expectOk(cd.glowcap_host_enliven(host, sturdyref, sturdyref.len, &vow));

    var action: cd.GlowcapHostAction = undefined;
    try expectOk(cd.glowcap_host_next_action(host, &action));
    try std.testing.expectEqual(cd.GLOWCAP_HOST_ACTION_DIAL, action.kind);

    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
}

test "failed Host adoption rolls runtime ownership back" {
    const CountingHost = @import("../../support/c_abi_counting_alloc.zig").CountingHost;
    var counting = CountingHost{};
    const spec = counting.spec();
    var ctx: ?*c.GlowcapContext = null;
    try expectOk(c.glowcap_context_new_with_allocator(&spec, &ctx));

    const seed = hostSeed(0x32);
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

    counting.fail_allocations = true;
    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INTERNAL,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
    counting.fail_allocations = false;

    // Let the loop allocation succeed, then fail its runtime scaffolding. The
    // rollback destructor must not cancel the borrowed core before returning
    // the C drive token.
    counting.allocations_before_failure = 1;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INTERNAL,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
    counting.allocations_before_failure = null;

    var state: u32 = undefined;
    try expectOk(cd.glowcap_host_lifecycle_state(host, &state));
    try std.testing.expectEqual(cd.GLOWCAP_LIFECYCLE_ACTIVE, state);
    try expectOk(cd.glowcap_host_publish(host, "after-rollback", 14, widgetBehavior, null, null));
    try expectOk(cd.glowcap_host_release(host));
    c.glowcap_context_release(ctx);
    try std.testing.expect(counting.balanced());
}

test "a closing byte-fed Host cannot transfer to a new driver" {
    const host = try newByteFedHost(0x3b);
    try expectOk(cd.glowcap_host_close(host, &close_cancel, 0));

    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_CLOSED,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);

    // Failed native adoption returns the C drive token to the byte-fed owner.
    try expectOk(cd.glowcap_host_release(host));
}

test "a Host with byte-fed session state cannot transfer runtimes" {
    const host = try newByteFedHost(0x30);
    defer _ = cd.glowcap_host_release(host);
    try expectOk(cd.glowcap_host_ensure_advertised_locator(host, "tcp", 3));
    var session: ?*cd.GlowcapHostSession = null;
    try expectOk(openAccepted(host, "tcp", 3, &session));
    defer _ = cd.glowcap_host_session_release(session);

    var loop: ?*cdrv.GlowcapDriverLoop = null;
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_INVALID_ARGUMENT,
        cdrv.glowcap_driver_take_host(host, &driver_options_1s, &loop),
    );
    try std.testing.expect(loop == null);
}
