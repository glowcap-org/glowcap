//! The typed resident the driver-loop suite serves real traffic through:
//! its provider table and widget behavior, and the callback-retirement and
//! re-entrant session-release behaviors registered beside it.

const std = @import("std");

const c = @import("c_abi");
const cshared = @import("c_abi_shared");
const cd = @import("c_abi_host");
const cdrv = @import("c_abi_driver");
const glowcap = @import("glowcap");

const residents = @import("residents.zig");
const noMultiplexedConnectionFailure = residents.noMultiplexedConnectionFailure;
const c_args = @import("../../support/c_abi_args.zig");
const ws_relay = @import("../../support/ws_relay.zig");
const harness = @import("harness.zig");
const providerFailure = harness.providerFailure;
const drained = harness.drained;
const sameStaticProvider = harness.sameStaticProvider;
const retainStaticProvider = harness.retainStaticProvider;
const releaseStaticProvider = harness.releaseStaticProvider;

pub const TypedResident = struct {
    wake: glowcap.net.wake_channel.WakeChannel,
    opaque_hint: []const u8,
    restoration_state: []const u8 = "typed-restoration-state",
    invalid_restoration_result: bool = false,
    restoration_failure: bool = false,
    listeners: [2]Listener = undefined,
    listener_count: usize = 0,
    dial_verified: bool = false,
    retains: usize = 0,
    releases: usize = 0,
    retain_reports_failure: bool = false,
    release_code: i32 = c.GLOWCAP_OK,
    failed_accept_route: ?u64 = null,
    locator_failure: bool = false,
    advertise_failure: bool = false,
    stop_listen_failure: bool = false,
    stop_listen_pending: bool = false,
    pending_stop_route: ?u64 = null,
    stop_listen_calls: usize = 0,
    provider_entry: cdrv.GlowcapTransportProviderEntry = undefined,

    const Listener = struct {
        resident: *TypedResident,
        transport: []const u8,
        route: u64,
        active: bool = true,
        stop_started: bool = false,
    };

    pub fn self(ctx: ?*anyopaque) *TypedResident {
        return @ptrCast(@alignCast(ctx.?));
    }

    pub fn listener(ctx: ?*anyopaque) *Listener {
        return @ptrCast(@alignCast(ctx.?));
    }

    pub fn retain(ctx: ?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.retains += 1;
        if (resident.retain_reports_failure) {
            const name = "ContradictoryRetainFailure";
            const report = out_failure.?;
            report.* = cshared.transport_provider.emptyProviderFailure();
            report.result = c.GLOWCAP_ERR_IO;
            report.primary_name = name.ptr;
            report.primary_name_len = name.len;
        }
        return c.GLOWCAP_OK;
    }

    pub fn release(ctx: ?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        resident.releases += 1;
        if (resident.release_code != c.GLOWCAP_OK) {
            const name = "TestPackageReleaseFailed";
            const report = out_failure orelse return resident.release_code;
            report.* = cshared.transport_provider.emptyProviderFailure();
            report.result = resident.release_code;
            report.primary_name = name.ptr;
            report.primary_name_len = name.len;
        }
        return resident.release_code;
    }

    pub fn readinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
        return self(ctx).wake.read;
    }

    pub fn drainReady(ctx: ?*anyopaque, out: ?[*]cdrv.GlowcapMultiplexedReadyEvent, cap: usize, out_count: ?*usize, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        if (resident.pending_stop_route) |route| {
            if (cap == 0) return drained(out_count, 0);
            resident.pending_stop_route = null;
            out.?[0] = .{ .subject = route, .events = cshared.GLOWCAP_MULTIPLEXED_EV_LISTEN };
            return drained(out_count, 1);
        }
        const route = resident.failed_accept_route orelse return drained(out_count, 0);
        if (cap == 0) return drained(out_count, 0);
        resident.failed_accept_route = null;
        out.?[0] = .{ .subject = route, .events = cdrv.GLOWCAP_MULTIPLEXED_EV_ACCEPT };
        return drained(out_count, 1);
    }

    pub fn startConnect(ctx: ?*anyopaque, _: u64, view: ?*const cdrv.GlowcapLocatorView, _: ?*const cshared.GlowcapTransportOperationOptions, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const resident = self(ctx);
        const locator_view = view orelse return c.GLOWCAP_ERR_NULL_POINTER;
        var hint_storage: [4]glowcap.ocapn.model.HintEntry = undefined;
        const locator = cshared.locator_adapter.fromView(locator_view, &hint_storage) catch
            return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        if (!std.mem.eql(u8, locator.transport, "typed-test") or
            !std.mem.eql(u8, locator.designator, "dial-peer") or
            locator.hints.entries.len != 4)
            return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        const expected_names = [_][]const u8{ "route", "token", "enabled", "limit" };
        for (locator.hints.entries, expected_names) |entry, name| {
            if (!std.mem.eql(u8, entry.name, name)) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        }
        if (!std.mem.eql(u8, locator.hints.entries[0].value.string, "alternate")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        if (!std.mem.eql(u8, locator.hints.entries[1].value.bytes, &.{ 0, 0xff, 7 })) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        if (!locator.hints.entries[2].value.boolean) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        if (locator.hints.entries[3].value.integer != -42) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        resident.dial_verified = true;
        const code = providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "TypedDialRefused");
        if (out_failure) |failure| {
            failure.carrier_phase = cshared.transport_provider.GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE;
            failure.carrier_detail_flags = cshared.transport_provider.GLOWCAP_CARRIER_DETAIL_PEER_ALERT |
                cshared.transport_provider.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
            failure.carrier_verification_flags = 0x21;
            failure.carrier_peer_alert = 42;
            failure.carrier_engine_code = -0x2700;
        }
        return code;
    }

    pub fn finishConnect(_: ?*anyopaque, _: u64, _: ?*u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "TypedDialClaimRefused");
    }

    pub fn subject(_: ?*anyopaque, _: u64, _: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return c.GLOWCAP_OK;
    }

    pub fn listen(
        ctx: ?*anyopaque,
        route: u64,
        transport: ?[*]const u8,
        transport_len: usize,
        designator: ?[*]const u8,
        len: usize,
        _: ?[*]const u8,
        _: usize,
        _: ?*const cshared.GlowcapTransportOperationOptions,
        out_result: ?*cdrv.GlowcapListenResult,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const selected = (transport orelse return providerFailure(out_failure, c.GLOWCAP_ERR_NULL_POINTER, "NullTransport"))[0..transport_len];
        const canonical = if (std.mem.eql(u8, selected, "typed-test"))
            "typed-test"
        else if (std.mem.eql(u8, selected, "typed-test-alt"))
            "typed-test-alt"
        else
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "UnknownTransport");
        const requested = if (len == 0) "" else (designator orelse return providerFailure(out_failure, c.GLOWCAP_ERR_NULL_POINTER, "NullDesignator"))[0..len];
        if (!std.mem.eql(u8, requested, "listener-peer"))
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "WrongListenerPeer");
        const resident = self(ctx);
        if (resident.listener_count == resident.listeners.len)
            return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "ListenerCapacity");
        const slot = &resident.listeners[resident.listener_count];
        resident.listener_count += 1;
        slot.* = .{ .resident = resident, .transport = canonical, .route = route };
        (out_result orelse return c.GLOWCAP_ERR_NULL_POINTER).* = .{
            .state = cdrv.GLOWCAP_LISTEN_READY,
            .listener = slot,
            .attempt = null,
            .readiness_fd = -1,
        };
        return c.GLOWCAP_OK;
    }

    pub fn finishListen(_: ?*anyopaque, _: u64, _: ?*?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        return providerFailure(out_failure, c.GLOWCAP_ERR_INVALID_ARGUMENT, "TypedFinishListenRefused");
    }

    pub fn listenerLocator(
        ctx: ?*anyopaque,
        sink_ctx: ?*anyopaque,
        sink: cdrv.GlowcapLocatorSinkFn,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const active = listener(ctx);
        if (!active.active) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        const resident = active.resident;
        if (resident.locator_failure) {
            const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ForcedLocatorFailure");
            const report = out_failure orelse return code;
            report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
            report.secondary_name = "ForcedLocatorCleanupFailure".ptr;
            report.secondary_name_len = "ForcedLocatorCleanupFailure".len;
            report.secondary_count = 2;
            return code;
        }
        const hints = [_]glowcap.ocapn.model.HintEntry{
            .{ .name = "route", .value = .{ .string = "primary" } },
            .{ .name = "token", .value = .{ .bytes = resident.opaque_hint } },
            .{ .name = "enabled", .value = .{ .boolean = true } },
            .{ .name = "limit", .value = .{ .integer = 73 } },
        };
        const locator: glowcap.ocapn.model.PeerLocator = .{
            .transport = active.transport,
            .designator = "listener-peer",
            .hints = .{ .entries = &hints, .wire_form = .map },
        };
        var c_hints: [hints.len]cdrv.GlowcapLocatorHintView = undefined;
        const view = cshared.locator_adapter.project(locator, &c_hints) catch
            return c.GLOWCAP_ERR_INVALID_ARGUMENT;
        return sink(sink_ctx, &view);
    }

    pub fn listenerAdvertise(
        ctx: ?*anyopaque,
        view: ?*const cdrv.GlowcapLocatorView,
        sink_ctx: ?*anyopaque,
        sink: cdrv.GlowcapLocatorSinkFn,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        if (listener(ctx).resident.advertise_failure) {
            const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ForcedAdvertiseFailure");
            const report = out_failure orelse return code;
            report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
            report.secondary_name = "ForcedAdvertiseCleanupFailure".ptr;
            report.secondary_name_len = "ForcedAdvertiseCleanupFailure".len;
            report.secondary_count = 2;
            return code;
        }
        return sink(sink_ctx, view);
    }

    pub fn listenerRestorationState(
        ctx: ?*anyopaque,
        out: ?[*]u8,
        cap: usize,
        out_len: ?*usize,
        out_failure: ?*cdrv.GlowcapProviderFailure,
    ) callconv(.c) i32 {
        const resident = listener(ctx).resident;
        const len_slot = out_len orelse return c.GLOWCAP_ERR_NULL_POINTER;
        len_slot.* = 0;
        if (resident.restoration_failure) {
            const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "ForcedRestorationFailure");
            const report = out_failure orelse return code;
            report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
            report.secondary_name = "ForcedRestorationCleanupFailure".ptr;
            report.secondary_name_len = "ForcedRestorationCleanupFailure".len;
            report.secondary_count = 2;
            return code;
        }
        if (resident.invalid_restoration_result) {
            len_slot.* = cap + 1;
            return c.GLOWCAP_OK;
        }
        len_slot.* = resident.restoration_state.len;
        if (cap < resident.restoration_state.len) return c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
        if (resident.restoration_state.len != 0)
            @memcpy((out orelse return c.GLOWCAP_ERR_NULL_POINTER)[0..resident.restoration_state.len], resident.restoration_state);
        return c.GLOWCAP_OK;
    }

    pub fn finishAccept(ctx: ?*anyopaque, _: ?*u64, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const active = listener(ctx);
        if (active.active) {
            const slot = out_failure orelse return c.GLOWCAP_ERR_NULL_POINTER;
            slot.* = .{
                .result = c.GLOWCAP_ERR_IO,
                .carrier_phase = cshared.transport_provider.GLOWCAP_CARRIER_PHASE_REGISTRATION,
                .carrier_detail_flags = 0,
                .carrier_verification_flags = 0,
                .carrier_peer_alert = 0,
                .carrier_engine_code = 0,
                .primary_name = "ForcedAcceptFailure".ptr,
                .primary_name_len = "ForcedAcceptFailure".len,
                .secondary_result = c.GLOWCAP_ERR_INTERNAL,
                .secondary_name = "ForcedAcceptCleanupFailure".ptr,
                .secondary_name_len = "ForcedAcceptCleanupFailure".len,
                .secondary_count = 2,
            };
            return c.GLOWCAP_ERR_IO;
        }
        cshared.transport_provider.setProviderFailure(out_failure, c.GLOWCAP_ERR_CLOSED, error.Closed);
        return c.GLOWCAP_ERR_CLOSED;
    }

    pub fn stopListen(ctx: ?*anyopaque, out_failure: ?*cdrv.GlowcapProviderFailure) callconv(.c) i32 {
        const active = listener(ctx);
        active.resident.stop_listen_calls += 1;
        active.active = false;
        if (active.resident.stop_listen_pending and !active.stop_started) {
            active.stop_started = true;
            active.resident.pending_stop_route = active.route;
            _ = active.resident.wake.nudge() catch unreachable;
            return c.GLOWCAP_ERR_WOULD_BLOCK;
        }
        if (active.resident.stop_listen_failure) {
            const code = providerFailure(out_failure, c.GLOWCAP_ERR_IO, "StopListenFailed");
            const report = out_failure orelse return code;
            report.secondary_result = c.GLOWCAP_ERR_INTERNAL;
            report.secondary_name = "StopListenCleanupFailed".ptr;
            report.secondary_name_len = "StopListenCleanupFailed".len;
            report.secondary_count = 2;
            return code;
        }
        return c.GLOWCAP_OK;
    }

    pub fn tryRead(_: ?*anyopaque, _: u64, _: ?[*]u8, _: usize) callconv(.c) isize {
        return cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }

    pub fn tryWrite(_: ?*anyopaque, _: u64, _: ?[*]const u8, _: usize) callconv(.c) isize {
        return cdrv.GLOWCAP_TRANSPORT_WOULD_BLOCK;
    }

    pub fn remoteKey(_: ?*anyopaque, _: u64, _: ?[*]u8) callconv(.c) i32 {
        return 0;
    }

    pub fn table(resident: *TypedResident) cdrv.GlowcapMultiplexedTransport {
        return .{
            .abi_version = cdrv.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION,
            .struct_size = @sizeOf(cdrv.GlowcapMultiplexedTransport),
            .ctx = resident,
            .readiness_fd = readinessFd,
            .drain_ready = drainReady,
            .start_connect = startConnect,
            .finish_connect = finishConnect,
            .cancel_connect = subject,
            .listen = listen,
            .finish_listen = finishListen,
            .cancel_listen = subject,
            .listener_locator = listenerLocator,
            .listener_advertise = listenerAdvertise,
            .listener_restoration_state = listenerRestorationState,
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

pub fn typedProvider(
    resident: *TypedResident,
    table: *const cdrv.GlowcapMultiplexedTransport,
    profile: *const cdrv.GlowcapTransportProfile,
) cdrv.GlowcapTransportProvider {
    resident.provider_entry = .{
        .profile = profile,
        .execution_model = cdrv.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = table,
    };
    return .{
        .abi_version = cdrv.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(cdrv.GlowcapTransportProvider),
        .entries = @ptrCast(&resident.provider_entry),
        .entry_count = 1,
        .lease_ctx = resident,
        .same_configuration = sameStaticProvider,
        .retain = TypedResident.retain,
        .release = TypedResident.release,
    };
}

pub fn widgetBehavior(
    ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    _ = .{ ctx, turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "poke")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    out_reply.* = c_args.argStr("poked through the driver archive");
    return c.GLOWCAP_OK;
}

pub const ReentrantSessionRelease = struct {
    loop: ?*cdrv.GlowcapDriverLoop,
    listener: u64,
    session: ?*cd.GlowcapHostSession = null,
    result: i32 = c.GLOWCAP_OK,
    readiness_result: i32 = c.GLOWCAP_OK,
    restoration_result: i32 = c.GLOWCAP_OK,
    exporter_result: i32 = c.GLOWCAP_ERR_INTERNAL,
    claim_result: i32 = c.GLOWCAP_ERR_INTERNAL,
    repeated_claim_result: i32 = c.GLOWCAP_ERR_INTERNAL,
    exporter: ?*cd.GlowcapHostSession = null,
    ran: bool = false,
};

pub const CallbackRetirement = struct {
    loop: ?*cdrv.GlowcapDriverLoop,
    result: i32 = c.GLOWCAP_ERR_INTERNAL,
    ran: bool = false,
};

pub fn callbackRetirementBehavior(
    raw_ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    _ = .{ turn, args, args_len };
    if (!std.mem.eql(u8, verb[0..verb_len], "retire")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const ctx: *CallbackRetirement = @ptrCast(@alignCast(raw_ctx.?));
    ctx.ran = true;
    ctx.result = cdrv.glowcap_driver_retire(ctx.loop);
    out_reply.* = c_args.argStr("retired");
    return c.GLOWCAP_OK;
}

pub fn reentrantSessionReleaseBehavior(
    raw_ctx: ?*anyopaque,
    turn: ?*cd.GlowcapHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const c.GlowcapArgument,
    args_len: usize,
    out_reply: *c.GlowcapArgument,
) callconv(.c) i32 {
    _ = turn;
    if (!std.mem.eql(u8, verb[0..verb_len], "probe")) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    if (args_len != 1 or args.?[0].kind != c.GLOWCAP_ARG_REFERENCE) return c.GLOWCAP_ERR_INVALID_ARGUMENT;
    const ctx: *ReentrantSessionRelease = @ptrCast(@alignCast(raw_ctx.?));
    ctx.ran = true;
    ctx.exporter_result = cdrv.glowcap_driver_claim_reference_exporter(ctx.loop, &args.?[0].reference, &ctx.exporter);
    ctx.claim_result = cdrv.glowcap_driver_claim_exporter_session(ctx.loop, ctx.exporter);
    ctx.repeated_claim_result = cdrv.glowcap_driver_claim_exporter_session(ctx.loop, ctx.exporter);
    var readiness_fd: i32 = -1;
    ctx.readiness_result = cdrv.glowcap_driver_readiness_fd(ctx.loop, &readiness_fd);
    var restoration_len: usize = 0;
    ctx.restoration_result = cdrv.glowcap_driver_listener_restoration_state(
        ctx.loop,
        ctx.listener,
        null,
        0,
        &restoration_len,
    );
    ctx.result = cdrv.glowcap_driver_session_release(ctx.loop, ctx.session);
    out_reply.* = c_args.argStr("still open");
    return c.GLOWCAP_OK;
}
