//! Generic multiplexed-provider projection of the owned iroh endpoint.
//!
//! This leaf adapts the sidecar's one readiness loop to the driver's provider
//! table. Shared Zig state owns connection identity and listener operations.
//! Endpoint and teardown authority
//! remain in `ownership.zig`.

const std = @import("std");

const model = @import("model");
const iroh = @import("iroh");
const c = @import("c_abi_shared");
const ownership = @import("ownership.zig");

const GlowcapIrohNetlayer = ownership.GlowcapIrohNetlayer;
const NetlayerPayload = ownership.NetlayerPayload;
const MultiplexedAdapter = ownership.MultiplexedAdapter;

const setLastError = c.setLastError;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;

comptime {
    // Connection readiness vocabulary is the sidecar's, value for value.
    std.debug.assert(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE == iroh.loop_ev_readable);
    std.debug.assert(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_WRITABLE == iroh.loop_ev_writable);
    std.debug.assert(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CLOSED == iroh.loop_ev_closed);
    std.debug.assert(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_ACCEPT == iroh.loop_ev_accept);
    std.debug.assert(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT == iroh.loop_ev_connect);
    std.debug.assert(c.transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK == iroh.loop_would_block);
}

/// Fill `out_provider` with this netlayer's complete provider package. Its one
/// multiplexed entry joins generic dial/listen dispatch as `iroh`. Registration
/// retains the netlayer through the package lease.
pub export fn glowcap_iroh_transport_provider(
    netlayer: ?*GlowcapIrohNetlayer,
    out_provider: ?*c.GlowcapTransportProvider,
) i32 {
    c.lastErrorClear();
    const nl = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_provider orelse return GLOWCAP_ERR_NULL_POINTER;
    if (nl.multiplexed_adapter == null) {
        const adapter = nl.allocator.create(MultiplexedAdapter) catch |err|
            return c.failInternal("iroh transport_provider adapter", err);
        adapter.* = .{
            .payload = nl,
            .zig = iroh.MultiplexedAdapter.init(nl.allocator, &nl.resident) catch |err| {
                nl.allocator.destroy(adapter);
                return c.failInternal("iroh transport_provider admission", err);
            },
            .profile = transportProfile(),
            .multiplexed_transport = undefined,
            .entry = undefined,
        };
        adapter.multiplexed_transport = multiplexedTransport(adapter);
        adapter.entry = .{
            .profile = &adapter.profile,
            .execution_model = c.transport_provider.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED,
            .implementation = &adapter.multiplexed_transport,
        };
        nl.multiplexed_adapter = adapter;
    }
    slot.* = .{
        .abi_version = c.transport_provider.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapTransportProvider),
        .entries = @ptrCast(&nl.multiplexed_adapter.?.entry),
        .entry_count = 1,
        .lease_ctx = nl,
        .same_configuration = providerSameConfiguration,
        .retain = providerRetain,
        .release = providerRelease,
    };
    return GLOWCAP_OK;
}

fn providerRetain(ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return GLOWCAP_ERR_NULL_POINTER;
    }));
    if (payload.retain()) return GLOWCAP_OK;
    c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_CLOSED, error.Closed);
    return GLOWCAP_ERR_CLOSED;
}

fn providerRelease(ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse return GLOWCAP_OK));
    if (payload.release()) |failure|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, failure);
    return GLOWCAP_OK;
}

fn providerSameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    const left: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse return 0));
    const right: *NetlayerPayload = @ptrCast(@alignCast(other_ctx orelse return 0));
    if (!std.meta.eql(left.config, right.config)) return 0;
    var left_id: [iroh.node_id_len]u8 = undefined;
    var right_id: [iroh.node_id_len]u8 = undefined;
    return @intFromBool(std.mem.eql(
        u8,
        left.resident.nodeId(&left_id),
        right.resident.nodeId(&right_id),
    ));
}

fn transportProfile() c.GlowcapTransportProfile {
    return c.transport_provider.profileFromMetadata(iroh.transport_profile);
}

fn multiplexedTransport(adapter: *MultiplexedAdapter) c.GlowcapMultiplexedTransport {
    return .{
        .abi_version = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapMultiplexedTransport),
        .ctx = adapter,
        .readiness_fd = multiplexedReadinessFd,
        .drain_ready = multiplexedDrainReady,
        .start_connect = multiplexedStartConnect,
        .finish_connect = multiplexedFinishConnect,
        .cancel_connect = multiplexedCancelConnect,
        .listen = multiplexedListen,
        .finish_listen = null,
        .cancel_listen = null,
        .listener_locator = multiplexedListenerLocator,
        .listener_advertise = multiplexedListenerAdvertise,
        .finish_accept = multiplexedFinishAccept,
        .stop_listen = multiplexedStopListen,
        .try_read = multiplexedTryRead,
        .try_write = multiplexedTryWrite,
        .conn_close = multiplexedConnClose,
        .conn_take_failure = multiplexedConnTakeFailure,
        .conn_remote_key = multiplexedConnRemoteKey,
    };
}

fn multiplexedReadinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
    return MultiplexedAdapter.fromOpaque(ctx).payload.resident.readinessFd();
}

fn multiplexedDrainReady(
    ctx: ?*anyopaque,
    out: ?[*]c.GlowcapMultiplexedReadyEvent,
    cap: usize,
    out_count: ?*usize,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const slot = out_count orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    slot.* = 0;
    if (cap == 0) return GLOWCAP_OK;
    const dest = out orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var ready: [32]@import("net").multiplexed_resident.ReadyEvent = undefined;
    const count = adapter.zig.drainReady(ready[0..@min(cap, ready.len)]) catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
    for (ready[0..count], 0..) |event, i| dest[i] = .{ .subject = @intCast(event.subject), .events = event.events };
    slot.* = count;
    return GLOWCAP_OK;
}

/// Project a dial's classification onto the shared C result and name the
/// concrete cause in this archive's last-error slot: the classification, then
/// the sidecar's own text for the fault when it supplied one (which relay
/// refused, which address stayed silent, the QUIC close reason). The
/// structured `GlowcapProviderFailure` keeps the static error name, because
/// the driver retains those bytes without copying. The slot copies, so the
/// text may live on the caller's stack.
fn dialErrToCode(err: anyerror, detail: []const u8) i32 {
    if (detail.len != 0)
        setLastError("multiplexed_transport dial: {s}: {s}", .{ @errorName(err), detail })
    else
        setLastError("multiplexed_transport dial: {s}", .{@errorName(err)});
    return c.dialFailureCode(err);
}

fn multiplexedStartConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    locator_view: ?*const c.GlowcapLocatorView,
    options: ?*const c.GlowcapTransportOperationOptions,
    _: ?*const c.GlowcapDialOrigin,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const view = locator_view orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        adapter.payload.allocator,
        view,
        &hint_stack,
    ) catch |err| {
        const code = c.locatorAdapterErrorCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    defer borrowed.deinit(adapter.payload.allocator);
    adapter.zig.startConnect(@intCast(request_id), borrowed.value, .inherit) catch |err| {
        return c.transport_provider.failProvider(out_failure, dialErrToCode(err, ""), err);
    };
    return GLOWCAP_OK;
}

fn multiplexedFinishConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    out_conn: ?*u64,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const slot = out_conn orelse {
        _ = multiplexedCancelConnect(ctx, request_id, null);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    };
    var text: iroh.DialText = .{};
    slot.* = @intCast(adapter.zig.finishConnect(@intCast(request_id), &text) catch |err| {
        return c.transport_provider.failProvider(out_failure, dialErrToCode(err, text.slice()), err);
    });
    return GLOWCAP_OK;
}

fn multiplexedCancelConnect(ctx: ?*anyopaque, request_id: u64, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    MultiplexedAdapter.fromOpaque(ctx).zig.cancelConnect(@intCast(request_id));
    return GLOWCAP_OK;
}

fn multiplexedListen(
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    // The node id is iroh's own identity, so the Host key is not read.
    _: ?[*]const u8,
    _: usize,
    options: ?*const c.GlowcapTransportOperationOptions,
    out_result: ?*c.GlowcapListenResult,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const result = out_result orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const selected = (transport orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer))[0..transport_len];
    const requested: []const u8 = if (requested_designator) |ptr| ptr[0..requested_designator_len] else &.{};
    adapter.zig.listen(@intCast(route_id), selected, requested, .inherit) catch |err| {
        const code: i32 = switch (err) {
            error.OutOfMemory => GLOWCAP_ERR_INTERNAL,
            error.SidecarFailed => GLOWCAP_ERR_IO,
            else => GLOWCAP_ERR_INVALID_ARGUMENT,
        };
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    result.* = .{
        .state = c.GLOWCAP_LISTEN_READY,
        .listener = adapter,
        .attempt = null,
        .readiness_fd = -1,
    };
    return GLOWCAP_OK;
}

fn multiplexedListenerLocator(
    ctx: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.GlowcapLocatorSinkFn,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const locator = adapter.zig.borrowListenerLocator() catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, err);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]c.GlowcapLocatorHintView = undefined;
    var projection = c.locator_adapter.Projection.init(
        adapter.payload.allocator,
        locator,
        &hint_stack,
    ) catch |err| return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
    defer projection.deinit(adapter.payload.allocator);
    return sink(sink_ctx, &projection.view);
}

fn multiplexedListenerAdvertise(
    ctx: ?*anyopaque,
    locator_view: ?*const c.GlowcapLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.GlowcapLocatorSinkFn,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const view = locator_view orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        adapter.payload.allocator,
        view,
        &hint_stack,
    ) catch |err| return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
    defer borrowed.deinit(adapter.payload.allocator);
    adapter.zig.validateAdvertisement(borrowed.value) catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, err);
    return sink(sink_ctx, view);
}

fn multiplexedFinishAccept(ctx: ?*anyopaque, out_conn: ?*u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    slot.* = @intCast((adapter.zig.finishAccept() catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err)) orelse return GLOWCAP_ERR_WOULD_BLOCK);
    return GLOWCAP_OK;
}

fn multiplexedStopListen(ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    MultiplexedAdapter.fromOpaque(ctx).zig.stopListen() catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
    return GLOWCAP_OK;
}

fn multiplexedTryRead(ctx: ?*anyopaque, conn: u64, buf: ?[*]u8, cap: usize) callconv(.c) isize {
    return MultiplexedAdapter.fromOpaque(ctx).zig.tryRead(@intCast(conn), (buf orelse return -1)[0..cap]);
}

fn multiplexedTryWrite(ctx: ?*anyopaque, conn: u64, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    return MultiplexedAdapter.fromOpaque(ctx).zig.tryWrite(@intCast(conn), (bytes orelse return -1)[0..len]);
}

fn multiplexedConnClose(ctx: ?*anyopaque, conn: u64, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    MultiplexedAdapter.fromOpaque(ctx).zig.closeConnection(@intCast(conn));
    return GLOWCAP_OK;
}

fn multiplexedConnTakeFailure(ctx: ?*anyopaque, conn: u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) void {
    const slot = out_failure orelse return;
    slot.* = std.mem.zeroes(c.GlowcapProviderFailure);
    if (MultiplexedAdapter.fromOpaque(ctx).zig.takeFailure(@intCast(conn))) |failure|
        c.transport_provider.setProviderFailureChain(slot, GLOWCAP_ERR_IO, failure, c.dialFailureCode);
}

fn multiplexedConnRemoteKey(ctx: ?*anyopaque, conn: u64, out_key: ?[*]u8) callconv(.c) i32 {
    const dst = out_key orelse return 0;
    const key = MultiplexedAdapter.fromOpaque(ctx).zig.remoteKey(@intCast(conn)) orelse return 0;
    @memcpy(dst[0..key.bytes.len], &key.bytes);
    return 1;
}
