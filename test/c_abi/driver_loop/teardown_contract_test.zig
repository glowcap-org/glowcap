//! Exact C projection of multiplexed cancellation and listener teardown.
//! These are operation-owned outcomes: no callback-local TLS slot or runtime
//! journal is needed to recover the provider's primary and consequences.

const std = @import("std");

const c = @import("c_abi");
const cdrv = @import("c_abi_driver");
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
        try std.testing.expectEqual(@as(usize, 2), resident.stop_listen_calls);
    }
}
