//! Exact C projection of multiplexed cancellation and listener teardown.
//! These are operation-owned outcomes: no callback-local TLS slot or runtime
//! journal is needed to recover the provider's primary and consequences.

const std = @import("std");

const c = @import("c_abi");
const cdrv = @import("c_abi_driver");
const cd = @import("c_abi_host");
const glowcap = @import("glowcap");

const harness = @import("harness.zig");
const residents = @import("residents.zig");
const typed = @import("typed_resident.zig");

const expectOk = harness.expectOk;
const expectStep = harness.expectStep;

test "multiplexed dial cancellation retains provider cleanup on its OPEN_FAILED owner" {
    const owned = try harness.newEmptyLoop(0x7d);
    defer owned.deinit();
    var resident = residents.InvalidMultiplexedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .connect_io = true,
        .cancel_connect_failure = true,
    };
    defer resident.wake.deinit();
    var table = resident.table();
    try expectOk(harness.addMultiplexedProvider(owned.raw, &table, "cancel-chain"));

    var locator: ?*c.GlowcapLocator = null;
    try expectOk(c.glowcap_locator_new(
        "cancel-chain",
        "cancel-chain".len,
        "endpoint",
        "endpoint".len,
        c.GLOWCAP_HINTS_MAP,
        &locator,
    ));
    defer c.glowcap_locator_release(locator);
    var view: ?*const c.GlowcapLocatorView = null;
    try expectOk(c.glowcap_locator_borrow_view(locator, &view));
    var operation_id: u64 = 0;
    try expectOk(cdrv.glowcap_driver_dial(owned.raw, view, null, &operation_id));
    try expectOk(cdrv.glowcap_driver_close(owned.raw, &harness.close_cancel));

    var event: cdrv.GlowcapDriverEvent = undefined;
    while (cdrv.glowcap_driver_next_event(owned.raw, &event) == c.GLOWCAP_ERR_WOULD_BLOCK)
        try expectStep(cdrv.glowcap_driver_step(owned.raw, 0));
    try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_OPEN_FAILED, event.kind);
    try std.testing.expectEqual(operation_id, event.operation_id);
    try std.testing.expectEqual(c.GLOWCAP_ERR_CLOSED, event.primary_result);
    try std.testing.expectEqualStrings("Canceled", event.primary_name.?[0..event.primary_name_len]);
    try std.testing.expectEqual(c.GLOWCAP_ERR_IO, event.secondary_result);
    try std.testing.expectEqualStrings(
        "CancelConnectFailed",
        event.secondary_name.?[0..event.secondary_name_len],
    );
    try std.testing.expectEqual(@as(u32, 3), event.secondary_count);
    try std.testing.expectEqual(@as(usize, 1), resident.cancel_connect_calls);
    try std.testing.expectEqual(
        c.GLOWCAP_ERR_WOULD_BLOCK,
        cdrv.glowcap_driver_next_event(owned.raw, &event),
    );
}

test "pending and active listener teardown return exact provider chains" {
    {
        const owned = try harness.newEmptyLoop(0x7e);
        defer owned.deinit();
        var resident = residents.InvalidMultiplexedResident{
            .wake = try glowcap.net.wake_channel.WakeChannel.open(),
            .pending_listen = true,
            .cancel_listen_failure = true,
        };
        defer resident.wake.deinit();
        var table = resident.table();
        try expectOk(harness.addMultiplexedProvider(owned.raw, &table, "cancel-listen-chain"));
        var listener: u64 = 0;
        try expectOk(cdrv.glowcap_driver_listen(
            owned.raw,
            "cancel-listen-chain",
            "cancel-listen-chain".len,
            "endpoint",
            "endpoint".len,
            null,
            &listener,
        ));
        var failure = cdrv.GlowcapDriverFailure.init();
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_IO,
            cdrv.glowcap_driver_listener_close(owned.raw, listener, &failure),
        );
        try std.testing.expectEqualStrings(
            "CancelListenFailed",
            failure.primary_name.?[0..failure.primary_name_len],
        );
        try std.testing.expectEqualStrings(
            "CancelListenCleanupFailed",
            failure.secondary_name.?[0..failure.secondary_name_len],
        );
        try std.testing.expectEqual(@as(u32, 2), failure.secondary_count);
        try std.testing.expectEqual(@as(usize, 1), resident.cancel_listen_calls);
    }

    {
        const owned = try harness.newEmptyLoop(0x7f);
        defer owned.deinit();
        var resident = typed.TypedResident{
            .wake = try glowcap.net.wake_channel.WakeChannel.open(),
            .opaque_hint = &.{},
            .stop_listen_failure = true,
        };
        defer resident.wake.deinit();
        var table = resident.table();
        const profile = harness.providerProfile("typed-test");
        var provider = typed.typedProvider(&resident, &table, &profile);
        try expectOk(harness.addProvider(owned.raw, &provider));
        const listener = try harness.listenReady(owned.raw, "typed-test", "listener-peer");
        var failure = cdrv.GlowcapDriverFailure.init();
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_IO,
            cdrv.glowcap_driver_listener_close(owned.raw, listener, &failure),
        );
        try std.testing.expectEqualStrings(
            "StopListenFailed",
            failure.primary_name.?[0..failure.primary_name_len],
        );
        try std.testing.expectEqualStrings(
            "StopListenCleanupFailed",
            failure.secondary_name.?[0..failure.secondary_name_len],
        );
        try std.testing.expectEqual(@as(u32, 2), failure.secondary_count);
        try std.testing.expectEqual(cdrv.GLOWCAP_CARRIER_PHASE_SHUTDOWN, failure.carrier_phase);
        try std.testing.expectEqual(@as(usize, 1), resident.stop_listen_calls);
    }

    {
        const owned = try harness.newEmptyLoop(0x80);
        defer owned.deinit();
        var resident = typed.TypedResident{
            .wake = try glowcap.net.wake_channel.WakeChannel.open(),
            .opaque_hint = &.{},
            .stop_listen_pending = true,
            .stop_listen_failure = true,
        };
        defer resident.wake.deinit();
        var table = resident.table();
        const profile = harness.providerProfile("typed-test");
        var provider = typed.typedProvider(&resident, &table, &profile);
        try expectOk(harness.addProvider(owned.raw, &provider));
        const listener = try harness.listenReady(owned.raw, "typed-test", "listener-peer");
        var failure = cdrv.GlowcapDriverFailure.init();
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_WOULD_BLOCK,
            cdrv.glowcap_driver_listener_close(owned.raw, listener, &failure),
        );

        var event: cdrv.GlowcapDriverEvent = undefined;
        try std.testing.expectEqual(
            c.GLOWCAP_ERR_WOULD_BLOCK,
            cdrv.glowcap_driver_next_event(owned.raw, &event),
        );
        try expectStep(cdrv.glowcap_driver_step(owned.raw, 1_000));
        try expectOk(cdrv.glowcap_driver_next_event(owned.raw, &event));
        try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, event.kind);
        try std.testing.expectEqual(listener, event.listener_id);
        try std.testing.expectEqualStrings(
            "StopListenFailed",
            event.primary_name.?[0..event.primary_name_len],
        );
        try std.testing.expectEqualStrings(
            "StopListenCleanupFailed",
            event.secondary_name.?[0..event.secondary_name_len],
        );
        try std.testing.expectEqual(@as(u32, 2), event.secondary_count);
        try std.testing.expectEqual(cdrv.GLOWCAP_CARRIER_PHASE_SHUTDOWN, event.carrier_phase);
        try std.testing.expectEqual(@as(usize, 2), resident.stop_listen_calls);
    }
}

/// A teardown callback that tries to re-enter the loop while
/// `glowcap_driver_release` owns it: both guard families (ordinary and
/// callback-safe) and the otherwise-unguarded `has_transport`,
/// `listener_locator` and `wake` queries. It counts only while armed.
/// The null-argument probe runs first: a verb that passes the release guard
/// refuses its null argument without touching state teardown may have freed,
/// and only a guard refusal lets the callback issue the rest.
const ReleaseProbe = struct {
    loop: ?*cdrv.GlowcapDriverLoop,
    listener: u64,
    /// Shared across probes: each records its position among the callbacks.
    order: *usize,
    /// The provider package release count, captured inside each callback.
    releases: *const usize,
    releases_seen: usize = 0,
    armed: bool = false,
    calls: usize = 0,
    position: usize = 0,
    guard: i32 = c.GLOWCAP_ERR_INTERNAL,
    has_transport: i32 = c.GLOWCAP_ERR_INTERNAL,
    listener_locator: i32 = c.GLOWCAP_ERR_INTERNAL,
    wake: i32 = c.GLOWCAP_ERR_INTERNAL,
    nested_release: i32 = c.GLOWCAP_ERR_INTERNAL,
    /// Which null-argument verb proves the guard: the ordinary guard from the
    /// provider release, the callback-safe guard from the hosted free.
    callback_safe_guard: bool,

    fn run(self: *ReleaseProbe) void {
        if (!self.armed) return;
        self.calls += 1;
        self.releases_seen = self.releases.*;
        self.position = self.order.*;
        self.order.* += 1;
        self.guard = if (self.callback_safe_guard)
            cdrv.glowcap_driver_claim_exporter_session(self.loop, null)
        else
            cdrv.glowcap_driver_readiness_fd(self.loop, null);
        if (self.guard != c.GLOWCAP_ERR_INVALID_ARGUMENT) return;
        var present: u8 = 0;
        self.has_transport = cdrv.glowcap_driver_has_transport(self.loop, "typed-test", 10, &present);
        var view: c.GlowcapLocatorView = undefined;
        self.listener_locator = cdrv.glowcap_driver_listener_locator(self.loop, self.listener, &view);
        self.wake = cdrv.glowcap_driver_wake(self.loop);
        var failure = cdrv.GlowcapDriverFailure.init();
        self.nested_release = cdrv.glowcap_driver_release(self.loop, &failure);
    }

    fn providerRelease(ctx: ?*anyopaque) void {
        const self: *ReleaseProbe = @ptrCast(@alignCast(ctx.?));
        self.run();
    }

    fn hostedFree(ctx: ?*anyopaque) callconv(.c) void {
        const self: *ReleaseProbe = @ptrCast(@alignCast(ctx.?));
        self.run();
    }

    fn expectRefused(self: *const ReleaseProbe) !void {
        try std.testing.expectEqual(@as(usize, 1), self.calls);
        try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, self.guard);
        try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, self.has_transport);
        try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, self.listener_locator);
        try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, self.wake);
        const nested = c.ReleaseResult.fromRaw(self.nested_release);
        try std.testing.expectEqual(.retained, nested.ownership);
        try std.testing.expectEqual(c.GLOWCAP_ERR_INVALID_ARGUMENT, nested.code());
    }
};

test "driver release refuses reentry into the loop from both teardown phases" {
    const owned = try harness.newEmptyLoop(0x81);
    var resident = typed.TypedResident{
        .wake = try glowcap.net.wake_channel.WakeChannel.open(),
        .opaque_hint = &.{},
    };
    defer resident.wake.deinit();
    var table = resident.table();
    const profile = harness.providerProfile("typed-test");
    var provider = typed.typedProvider(&resident, &table, &profile);
    try expectOk(harness.addProvider(owned.raw, &provider));
    const listener = try harness.listenReady(owned.raw, "typed-test", "listener-peer");

    var order: usize = 0;
    var provider_probe = ReleaseProbe{
        .loop = owned.raw,
        .listener = listener,
        .order = &order,
        .releases = &resident.releases,
        .callback_safe_guard = false,
    };
    var hosted_probe = ReleaseProbe{
        .loop = owned.raw,
        .listener = listener,
        .order = &order,
        .releases = &resident.releases,
        .callback_safe_guard = true,
    };
    resident.release_hook = ReleaseProbe.providerRelease;
    resident.release_hook_ctx = &provider_probe;
    try expectOk(cd.glowcap_host_publish(
        owned.host,
        "widget",
        6,
        typed.widgetBehavior,
        &hosted_probe,
        ReleaseProbe.hostedFree,
    ));

    // Live neighbors: the same verbs work before release begins.
    var present: u8 = 0;
    try expectOk(cdrv.glowcap_driver_has_transport(owned.raw, "typed-test", 10, &present));
    try std.testing.expectEqual(@as(u8, 1), present);
    var view: c.GlowcapLocatorView = undefined;
    try expectOk(cdrv.glowcap_driver_listener_locator(owned.raw, listener, &view));
    try expectOk(cdrv.glowcap_driver_wake(owned.raw));

    provider_probe.armed = true;
    hosted_probe.armed = true;
    const released = c.ReleaseResult.fromRaw(harness.releaseLoop(owned.raw));

    try std.testing.expectEqual(.consumed, released.ownership);
    try std.testing.expectEqual(c.GLOWCAP_OK, released.code());
    try provider_probe.expectRefused();
    try hosted_probe.expectRefused();
    // Provider release runs in runtime teardown; the hosted free runs after.
    try std.testing.expectEqual(@as(usize, 0), provider_probe.position);
    try std.testing.expectEqual(@as(usize, 1), hosted_probe.position);
    try std.testing.expectEqual(@as(usize, 1), provider_probe.releases_seen);
    try std.testing.expectEqual(@as(usize, 1), hosted_probe.releases_seen);
    try std.testing.expectEqual(@as(usize, 1), resident.releases);
}
