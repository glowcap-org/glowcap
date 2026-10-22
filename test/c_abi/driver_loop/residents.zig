//! The refusing and failing residents the driver-loop suite registers:
//! invalid and malformed provider tables and async failure injection. The
//! typed resident that serves real traffic lives in `typed_resident.zig`.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");
const ws_relay = @import("../../support/ws_relay.zig");
const harness = @import("harness.zig");
const providerFailure = harness.providerFailure;
const drained = harness.drained;
const sameStaticProvider = harness.sameStaticProvider;
const retainStaticProvider = harness.retainStaticProvider;
const releaseStaticProvider = harness.releaseStaticProvider;

pub fn noStreamConnectionFailure(_: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) void {
    if (out) |slot| slot.* = std.mem.zeroes(cdrv.GlowcapProviderFailure);
}

pub fn noMultiplexedConnectionFailure(_: ?*anyopaque, _: u64, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) void {
    if (out) |slot| slot.* = std.mem.zeroes(cdrv.GlowcapProviderFailure);
}

pub fn injectedStreamConnectionFailure(_: ?*anyopaque, _: ?*anyopaque, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) void {
    const slot = out orelse return;
    const primary = "InjectedStreamReadFailure";
    const secondary = "InjectedStreamCleanupFailure";
    slot.* = std.mem.zeroes(cdrv.GlowcapProviderFailure);
    slot.result = c.GLOWCAP_ERR_IO;
    slot.primary_name = primary.ptr;
    slot.primary_name_len = primary.len;
    slot.secondary_result = c.GLOWCAP_ERR_INTERNAL;
    slot.secondary_name = secondary.ptr;
    slot.secondary_name_len = secondary.len;
    slot.secondary_count = 2;
}

pub fn injectedMultiplexedConnectionFailure(_: ?*anyopaque, _: u64, out: ?*cdrv.GlowcapProviderFailure) callconv(.c) void {
    const slot = out orelse return;
    const primary = "InjectedMultiplexedReadFailure";
    const secondary = "InjectedMultiplexedCleanupFailure";
    slot.* = std.mem.zeroes(cdrv.GlowcapProviderFailure);
    slot.result = c.GLOWCAP_ERR_IO;
    slot.primary_name = primary.ptr;
    slot.primary_name_len = primary.len;
    slot.secondary_result = c.GLOWCAP_ERR_INTERNAL;
    slot.secondary_name = secondary.ptr;
    slot.secondary_name_len = secondary.len;
    slot.secondary_count = 2;
}

fn teardownFailure(
    out: ?*cdrv.GlowcapProviderFailure,
    primary: []const u8,
    secondary: []const u8,
) i32 {
    const code = providerFailure(out, c.GLOWCAP_ERR_IO, primary);
    const report = out orelse return code;
    report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
    report.secondary_name = secondary.ptr;
    report.secondary_name_len = secondary.len;
    report.secondary_count = 2;
    return code;
}

pub const InvalidMultiplexedResident = struct {
    wake: glowcap.net.wake_channel.WakeChannel,
    invalid_mask: bool = false,
    drain_failure: bool = false,
    drain_success_report: bool = false,
    drain_empty_failure: bool = false,
    connect_with_readable: bool = false,
    listen_without_handle: bool = false,
    listen_output_on_failure: bool = false,
    pending_listen: bool = false,
    pending_listen_route: ?u64 = null,
    pending_listen_with_stream_fields: bool = false,
    connect_io: bool = false,
    finish_connect_success_report: bool = false,
    finish_connect_failure_output: bool = false,
    /// Fail every `finishConnect` with the I/O status and the `DialError`
    /// member name `ConnectionRefused`, the way the tcp provider reports one.
    finish_connect_refused: bool = false,
    /// Fail every `finishConnect` with the I/O status and a secure handshake
    /// whose certificate the trust store refused, the way a TLS carrier does.
    finish_connect_untrusted: bool = false,
    conn_close_failure: bool = false,
    conn_close_calls: usize = 0,
    cancel_connect_failure: bool = false,
    cancel_connect_calls: usize = 0,
    pending_request: ?u64 = null,
    connection_readable: bool = false,
    read_result: ?isize = null,
    write_result: ?isize = null,
    cancel_listen_calls: usize = 0,
    cancel_listen_failure: bool = false,
    stop_listen_calls: usize = 0,
    stop_listen_failure: bool = false,

    pub fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        return self.wake.read;
    }

    pub fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.GlowcapMultiplexedReadyEvent, cap: usize, out_count: ?*usize, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.wake.drain() catch unreachable;
        if (self.drain_success_report) {
            const name = "ContradictoryDrainFailure";
            out_failure.?.* = cshared.transport_provider.emptyProviderFailure();
            out_failure.?.result = c.GLOWCAP_ERR_IO;
            out_failure.?.primary_name = name.ptr;
            out_failure.?.primary_name_len = name.len;
            return drained(out_count, 0);
        }
        if (self.drain_empty_failure) return c.GLOWCAP_ERR_IO;
        if (self.drain_failure) {
            const primary = "InjectedReadinessFailure";
            const secondary = "InjectedDrainCleanupFailure";
            const report = out_failure.?;
            report.* = cshared.transport_provider.emptyProviderFailure();
            report.result = c.GLOWCAP_ERR_IO;
            report.primary_name = primary.ptr;
            report.primary_name_len = primary.len;
            report.secondary_name = secondary.ptr;
            report.secondary_name_len = secondary.len;
            report.secondary_result = c.GLOWCAP_ERR_IO;
            report.secondary_count = 2;
            return c.GLOWCAP_ERR_IO;
        }
        if (self.invalid_mask) {
            if (cap == 0) return drained(out_count, 0);
            out.?[0] = .{ .subject = 0, .events = @as(u32, 1) << 31 };
            return drained(out_count, 1);
        }
        if (self.connect_with_readable) {
            if (cap == 0) return drained(out_count, 0);
            out.?[0] = .{
                .subject = 1,
                .events = cdrv.GLOWCAP_MULTIPLEXED_EV_CONNECT | cdrv.GLOWCAP_MULTIPLEXED_EV_READABLE,
            };
            return drained(out_count, 1);
        }
        if (self.connect_io) {
            if (cap == 0) return drained(out_count, 0);
            if (self.pending_request) |request| {
                out.?[0] = .{
                    .subject = request,
                    .events = cdrv.GLOWCAP_MULTIPLEXED_EV_CONNECT,
                };
                return drained(out_count, 1);
            }
            if (self.connection_readable) {
                self.connection_readable = false;
                out.?[0] = .{
                    .subject = 7,
                    .events = cdrv.GLOWCAP_MULTIPLEXED_EV_READABLE,
                };
                return drained(out_count, 1);
            }
            return drained(out_count, 0);
        }
        if (self.pending_listen) {
            if (cap == 0) return drained(out_count, 0);
            if (self.pending_listen_route) |route| {
                out.?[0] = .{
                    .subject = route,
                    .events = cshared.GLOWCAP_MULTIPLEXED_EV_LISTEN,
                };
                return drained(out_count, 1);
            }
            return drained(out_count, 0);
        }
        if (self.listen_without_handle) {
            return drained(out_count, 0);
        }
        return drained(out_count, cap + 1);
    }

    pub fn startConnect(ctx: ?*anyopaque, request: u64, _: ?*const cdrv.GlowcapLocatorView, _: ?*const cshared.GlowcapTransportOperationOptions, _: ?*const cshared.GlowcapDialOrigin, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (!self.connect_io or self.pending_request != null)
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "InvalidTestDial");
        self.pending_request = request;
        _ = self.wake.nudge() catch unreachable;
        return c.GLOWCAP_OK;
    }

    pub fn finishConnect(ctx: ?*anyopaque, request: u64, out_conn: ?*u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (!self.connect_io or self.pending_request != request)
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "InvalidTestDialClaim");
        self.pending_request = null;
        if (self.finish_connect_refused)
            return providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ConnectionRefused");
        if (self.finish_connect_untrusted) {
            const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "CertificateUntrusted");
            out_failure.?.carrier_phase = cshared.transport_provider.GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE;
            out_failure.?.carrier_verification_flags = 0x08;
            return code;
        }
        if (self.finish_connect_failure_output) {
            out_conn.?.* = 7;
            return providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ContradictoryConnectRefusal");
        }
        self.connection_readable = true;
        _ = self.wake.nudge() catch unreachable;
        out_conn.?.* = 7;
        if (self.finish_connect_success_report) {
            const name = "ContradictoryConnectFailure";
            out_failure.?.* = cshared.transport_provider.emptyProviderFailure();
            out_failure.?.result = c.GLOWCAP_ERR_IO;
            out_failure.?.primary_name = name.ptr;
            out_failure.?.primary_name_len = name.len;
        }
        return c.GLOWCAP_OK;
    }

    pub fn claimExternal(_: ?*anyopaque, _: u64, _: ?*u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const code = providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "InvalidExternalSubject");
        const failure = out_failure orelse return code;
        const cleanup = "ExternalClaimCleanupFailed";
        failure.secondary_result = c.GLOWCAP_ERR_IO;
        failure.secondary_name = cleanup.ptr;
        failure.secondary_name_len = cleanup.len;
        failure.secondary_count = 2;
        return code;
    }

    pub fn subject(ctx: ?*anyopaque, _: u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.conn_close_calls += 1;
        if (self.conn_close_failure)
            return providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ConnectRollbackCloseFailed");
        return c.GLOWCAP_OK;
    }

    pub fn cancelConnect(ctx: ?*anyopaque, _: u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.cancel_connect_calls += 1;
        self.pending_request = null;
        if (self.cancel_connect_failure)
            return teardownFailure(out_failure, "CancelConnectFailed", "CancelConnectCleanupFailed");
        return c.GLOWCAP_OK;
    }

    pub fn listen(
        ctx: ?*anyopaque,
        route: u64,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cshared.GlowcapTransportOperationOptions,
        out_result: ?*cdrv.GlowcapListenResult,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.listen_output_on_failure) {
            (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
                .state = cdrv.GLOWCAP_LISTEN_READY,
                .listener = self,
                .attempt = null,
                .readiness_fd = -1,
            };
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "InvalidListenOutputs");
        }
        if (self.listen_without_handle) {
            (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
                .state = cdrv.GLOWCAP_LISTEN_READY,
                .listener = null,
                .attempt = null,
                .readiness_fd = -1,
            };
            return c.GLOWCAP_OK;
        }
        if (self.pending_listen_with_stream_fields) {
            (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
                .state = cdrv.GLOWCAP_LISTEN_PENDING,
                .listener = self,
                .attempt = null,
                .readiness_fd = -1,
            };
            return c.GLOWCAP_OK;
        }
        if (self.pending_listen) {
            self.pending_listen_route = route;
            (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
                .state = cdrv.GLOWCAP_LISTEN_PENDING,
                .listener = null,
                .attempt = null,
                .readiness_fd = -1,
            };
            _ = self.wake.nudge() catch unreachable;
            return c.GLOWCAP_OK;
        }
        return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "ListenRefused");
    }

    pub fn finishListen(ctx: ?*anyopaque, route: u64, _: ?*?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.pending_listen_route == route) self.pending_listen_route = null;
        const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "FinishListenRefused");
        const failure = out_failure orelse return code;
        const cleanup = "FinishListenCleanupFailed";
        failure.secondary_result = c.GLOWCAP_ERR_INTERNAL;
        failure.secondary_name = cleanup.ptr;
        failure.secondary_name_len = cleanup.len;
        failure.secondary_count = 2;
        return code;
    }

    pub fn listenerLocator(_: ?*anyopaque, _: ?*anyopaque, _: cdrv.GlowcapLocatorSinkFn, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }

    pub fn listenerAdvertise(
        _: ?*anyopaque,
        view: ?*const cdrv.GlowcapLocatorView,
        sink_ctx: ?*anyopaque,
        sink: cdrv.GlowcapLocatorSinkFn,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        return sink(sink_ctx, view);
    }

    pub fn finishAccept(_: ?*anyopaque, _: ?*u64, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_ERR_WOULD_BLOCK;
    }

    pub fn cancelListen(ctx: ?*anyopaque, _: u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.cancel_listen_calls += 1;
        self.pending_listen_route = null;
        if (self.cancel_listen_failure)
            return teardownFailure(out_failure, "CancelListenFailed", "CancelListenCleanupFailed");
        return c.GLOWCAP_OK;
    }

    pub fn stopListen(ctx: ?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        self.stop_listen_calls += 1;
        if (self.stop_listen_failure)
            return teardownFailure(out_failure, "StopListenFailed", "StopListenCleanupFailed");
        return c.GLOWCAP_OK;
    }

    pub fn tryRead(ctx: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        return self.read_result orelse cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }

    pub fn tryWrite(ctx: ?*anyopaque, _: u64, _: ?[*]const u8, len: usize) callconv(.c) isize {
        const self: *InvalidMultiplexedResident = @ptrCast(@alignCast(ctx.?));
        if (self.write_result) |result| return result;
        return if (self.connect_io) @intCast(len) else cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }

    pub fn remoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
        return 0;
    }

    pub fn table(self: *InvalidMultiplexedResident) cdrv.GlowcapMultiplexedTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapMultiplexedTransport),
            .ctx = self,
            .readiness_fd = readinessFd,
            .drain_ready = drainReady,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
            .listen = listen,
            .finish_listen = finishListen,
            .cancel_listen = cancelListen,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .finish_accept = finishAccept,
            .stop_listen = stopListen,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = subject,
            .conn_take_failure = noMultiplexedConnectionFailure,
            .conn_remote_key = remoteKey,
        };
    }
};

/// An immediate-only stream provider that violates READY ownership by also
/// publishing a pending attempt. The driver can close the valid listener but
/// has no fabricated cancellation callback to invoke for the invalid field.
pub const MalformedImmediateStream = struct {
    listener_close_calls: usize = 0,

    pub fn listen(
        ctx: ?*anyopaque,
        _: ?[*]const u8,
        _: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cshared.GlowcapTransportOperationOptions,
        out_result: ?*cdrv.GlowcapListenResult,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
            .state = cdrv.GLOWCAP_LISTEN_READY,
            .listener = ctx,
            .attempt = ctx,
            .readiness_fd = -1,
        };
        return c.GLOWCAP_OK;
    }

    pub fn waitAcceptable(_: ?*anyopaque, _: ?*anyopaque, _: i32, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_ERR_WOULD_BLOCK;
    }

    pub fn readinessFd(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
        return -1;
    }

    pub fn localLocator(_: ?*anyopaque, _: ?*anyopaque, _: cdrv.GlowcapLocatorSinkFn, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    }

    pub fn canonicalizeLocator(
        _: ?*anyopaque,
        view: ?*const cdrv.GlowcapLocatorView,
        sink_ctx: ?*anyopaque,
        sink: cdrv.GlowcapLocatorSinkFn,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        return sink(sink_ctx, view);
    }

    pub fn accept(_: ?*anyopaque, _: ?*anyopaque, _: ?*?*anyopaque, _: ?*i32, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_ERR_WOULD_BLOCK;
    }

    pub fn closeListener(
        ctx: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const self: *MalformedImmediateStream = @ptrCast(@alignCast(ctx.?));
        self.listener_close_calls += 1;
        return c.GLOWCAP_OK;
    }

    pub fn tryRead(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]u8, _: usize) callconv(.c) isize {
        return -1;
    }

    pub fn tryWrite(_: ?*anyopaque, _: ?*anyopaque, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return -1;
    }

    pub fn closeConnection(_: ?*anyopaque, _: ?*anyopaque, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    pub fn table(self: *MalformedImmediateStream) cdrv.GlowcapStreamTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapStreamTransport),
            .ctx = self,
            .start_connect = null,
            .finish_connect = null,
            .cancel_connect = null,
            .listen = listen,
            .finish_listen = null,
            .cancel_listen = null,
            .listener_wait_acceptable = waitAcceptable,
            .listener_readiness_fd = readinessFd,
            .listener_locator = localLocator,
            .listener_advertise = canonicalizeLocator,
            .listener_restoration_state = null,
            .accept = accept,
            .listener_close = closeListener,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = closeConnection,
            .conn_take_failure = noStreamConnectionFailure,
        };
    }
};

/// A dial-only multiplexed resident that admits without allocating, then reports one
/// failed connect through readiness. It isolates post-admission event
/// publication from transport and teardown allocation in the fail-stop test.
pub const AsyncFailureResident = struct {
    wake: glowcap.net.wake_channel.WakeChannel,
    pending: ?u64 = null,

    pub fn self(ctx: ?*anyopaque) *AsyncFailureResident {
        return @ptrCast(@alignCast(ctx.?));
    }

    pub fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        return self(ctx).wake.read;
    }

    pub fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.GlowcapMultiplexedReadyEvent, cap: usize, out_count: ?*usize, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.wake.drain() catch unreachable;
        if (cap == 0) return drained(out_count, 0);
        const request = resident.pending orelse return drained(out_count, 0);
        out.?[0] = .{ .subject = request, .events = cdrv.GLOWCAP_MULTIPLEXED_EV_CONNECT };
        return drained(out_count, 1);
    }

    pub fn startConnect(ctx: ?*anyopaque, request: u64, _: ?*const cdrv.GlowcapLocatorView, _: ?*const cshared.GlowcapTransportOperationOptions, _: ?*const cshared.GlowcapDialOrigin, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending != null)
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "DialAlreadyPending");
        resident.pending = request;
        _ = resident.wake.nudge() catch unreachable;
        return c.GLOWCAP_OK;
    }

    pub fn finishConnect(ctx: ?*anyopaque, request: u64, _: ?*u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending != request)
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "UnknownDialRequest");
        resident.pending = null;
        const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ForcedAsyncDialFailure");
        const report = out_failure orelse return code;
        const secondary = "ForcedDialCleanupFailure";
        report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
        report.secondary_name = secondary.ptr;
        report.secondary_name_len = secondary.len;
        report.secondary_count = 2;
        return code;
    }

    pub fn cancelConnect(ctx: ?*anyopaque, request: u64, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending == request) resident.pending = null;
        return c.GLOWCAP_OK;
    }

    pub fn tryRead(_: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        return cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }

    pub fn tryWrite(_: ?*anyopaque, _: u64, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }

    pub fn connClose(_: ?*anyopaque, _: u64, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    pub fn remoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
        return 0;
    }

    pub fn table(resident: *AsyncFailureResident) cdrv.GlowcapMultiplexedTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapMultiplexedTransport),
            .ctx = resident,
            .readiness_fd = readinessFd,
            .drain_ready = drainReady,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = cancelConnect,
            .listen = null,
            .finish_listen = null,
            .cancel_listen = null,
            .listener_locator = null,
            .listener_advertise = null,
            .finish_accept = null,
            .stop_listen = null,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = connClose,
            .conn_take_failure = noMultiplexedConnectionFailure,
            .conn_remote_key = remoteKey,
        };
    }
};
