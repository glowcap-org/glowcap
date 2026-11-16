//! A stream provider's listen failure reaches the `LISTENER_FAILED` event
//! under the provider's own cause name, whether the start or the finish
//! refuses.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");

const harness = @import("harness.zig");
const residents = @import("residents.zig");
const Stubs = residents.MalformedImmediateStream;
const expectOk = harness.expectOk;
const providerFailure = harness.providerFailure;

/// A stream table whose listen refuses with a named I/O cause, either at the
/// start or, when `pending` is set, at the finish.
const BusyStream = struct {
    wake: glowcap.net.wake_channel.WakeChannel,
    pending: bool = false,
    listens: usize = 0,
    cancels: usize = 0,
    closes: usize = 0,

    fn of(ctx: ?*anyopaque) *BusyStream {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn startConnect(
        _: ?*anyopaque,
        _: ?*const cdrv.GlowcapLocatorView,
        _: ?*const cdrv.GlowcapTransportOperationOptions,
        _: ?*?*anyopaque,
        _: ?*i32,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "DialUnsupported");
    }

    fn finishConnect(_: ?*anyopaque, _: ?*?*anyopaque, _: ?*i32, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "DialUnsupported");
    }

    fn cancelConnect(_: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    fn listen(
        ctx: ?*anyopaque,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cdrv.GlowcapTransportOperationOptions,
        out_result: ?*cdrv.GlowcapListenResult,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const self = of(ctx);
        self.listens += 1;
        if (!self.pending) return providerFailure(out_failure, c.GLOWCAP_ERR_IO, "AddressInUse");
        _ = self.wake.nudge() catch return c.GLOWCAP_ERR_INTERNAL;
        (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
            .state = cdrv.GLOWCAP_LISTEN_PENDING,
            .listener = null,
            .attempt = self,
            .readiness_fd = self.wake.read,
        };
        return c.GLOWCAP_OK;
    }

    fn finishListen(_: ?*anyopaque, _: ?*?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return providerFailure(out_failure, c.GLOWCAP_ERR_IO, "AddressInUse");
    }

    fn cancelListen(attempt: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        of(attempt).cancels += 1;
        return c.GLOWCAP_OK;
    }

    fn listenerClose(ctx: ?*anyopaque, _: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        of(ctx).closes += 1;
        return c.GLOWCAP_OK;
    }

    fn tryIo(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) isize {
        return -1;
    }

    fn tryWrite(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return -1;
    }

    fn connClose(_: ?*anyopaque, _: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    fn takeFailure(_: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) void {
        if (out) |report| report.* = cshared.transport_provider.emptyProviderFailure();
    }

    fn table(self: *BusyStream) cdrv.GlowcapStreamTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapStreamTransport),
            .ctx = self,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
            .listen = listen,
            .finish_listen = if (self.pending) finishListen else null,
            .cancel_listen = if (self.pending) cancelListen else null,
            .listener_wait_acceptable = Stubs.waitAcceptable,
            .listener_readiness_fd = Stubs.readinessFd,
            .listener_locator = Stubs.localLocator,
            .listener_advertise = Stubs.canonicalizeLocator,
            .listener_restoration_state = null,
            .accept = Stubs.accept,
            .listener_close = listenerClose,
            .try_read = tryIo,
            .try_write = tryWrite,
            .conn_close = connClose,
            .conn_take_failure = takeFailure,
        };
    }
};

/// Step the loop until it has an event, within five seconds.
fn nextEvent(loop: ?*cdrv.GlowcapDriverLoop) !cdrv.GlowcapDriverEvent {
    var event: cdrv.GlowcapDriverEvent = undefined;
    for (0..500) |_| {
        try expectOk(cdrv.glowcap_driver_step(loop, 10));
        const rc = cdrv.glowcap_driver_next_event(loop, &event);
        if (rc == c.GLOWCAP_ERR_WOULD_BLOCK) continue;
        try expectOk(rc);
        return event;
    }
    return error.NoDriverEvent;
}

fn expectListenFailsAsAddressInUse(pending: bool, seed: u8, name: []const u8) !void {
    var resident = BusyStream{ .wake = try glowcap.net.wake_channel.WakeChannel.open(), .pending = pending };
    defer resident.wake.deinit();
    const owned_loop = try harness.newEmptyLoop(seed);
    defer owned_loop.deinit();
    var table = resident.table();
    try expectOk(harness.addStreamProvider(owned_loop.raw, &table, name));

    // The second listen reaches the provider again, so the first failure
    // left the provider's listener seat free.
    for (1..3) |attempt| {
        var listener: u64 = 0;
        try expectOk(cdrv.glowcap_driver_listen(owned_loop.raw, name.ptr, name.len, "endpoint", "endpoint".len, null, &listener));
        const event = try nextEvent(owned_loop.raw);
        try std.testing.expectEqual(cdrv.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, event.kind);
        try std.testing.expectEqual(listener, event.listener_id);
        try std.testing.expectEqual(c.GLOWCAP_ERR_IO, event.primary_result);
        try std.testing.expectEqualStrings("AddressInUse", event.primary_name.?[0..event.primary_name_len]);
        try std.testing.expectEqual(attempt, resident.listens);
    }
    // A refused start or finish consumed its attempt, so nothing is left to
    // cancel or close.
    try std.testing.expectEqual(@as(usize, 0), resident.cancels);
    try std.testing.expectEqual(@as(usize, 0), resident.closes);
}

test "stream listener start preserves the provider failure identity" {
    try expectListenFailsAsAddressInUse(false, 0x72, "stream-listen-start-failure");
}

test "stream listener finish preserves the provider failure identity" {
    try expectListenFailsAsAddressInUse(true, 0x73, "stream-listen-finish-failure");
}
