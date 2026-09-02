//! Generic multiplexed-provider projection of the owned iroh endpoint.
//!
//! This leaf adapts the sidecar's one readiness loop to the driver's provider
//! table. It owns the id-to-handle mapping and listener projection operations
//! stored in `ownership.MultiplexedAdapter`; endpoint and teardown authority
//! remain in `ownership.zig`.

const std = @import("std");

const model = @import("model");
const net = @import("net");
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
    std.debug.assert(c.multiplexed_transport.GLOWCAP_MULTIPLEXED_WOULD_BLOCK == iroh.loop_would_block);
}

/// Fill `out_provider` with this netlayer's complete provider package. Its one
/// multiplexed entry joins generic dial/listen dispatch as `iroh`; registration
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
    const count_slot = out_count orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const out_ptr = out orelse if (cap == 0) null else return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var scratch: [32]iroh.ReadyEvent = undefined;
    var total: usize = 0;
    while (total < cap) {
        const want = @min(cap - total, scratch.len);
        const got = adapter.payload.resident.drainReady(scratch[0..want]);
        if (got < 0) return c.transport_provider.failProvider(out_failure, c.GLOWCAP_ERR_IO, error.ReadinessFailed);
        if (got == 0) break;
        const count: usize = @intCast(got);
        for (scratch[0..count]) |record| {
            if (record.events & iroh.loop_ev_accept != 0) {
                if (!adapter.listening) {
                    while (adapter.payload.resident.loopTryAccept()) |conn| {
                        adapter.payload.resident.loopConnClose(conn);
                    }
                    continue;
                }
                out_ptr.?[total] = .{
                    .subject = adapter.listener_route orelse continue,
                    .events = record.events,
                };
                total += 1;
                if (total == cap) break;
                continue;
            }
            out_ptr.?[total] = .{ .subject = @intCast(record.subject), .events = record.events };
            total += 1;
            if (total == cap) break;
        }
        if (count < want) break;
    }
    count_slot.* = total;
    return GLOWCAP_OK;
}

fn dialErrToCode(err: anyerror) i32 {
    setLastError("multiplexed_transport dial: {s}", .{@errorName(err)});
    return switch (err) {
        error.InvalidAddress => GLOWCAP_ERR_INVALID_ARGUMENT,
        error.TimedOut => c.GLOWCAP_ERR_TIMEOUT,
        error.WouldBlock => GLOWCAP_ERR_WOULD_BLOCK,
        error.OutOfMemory => GLOWCAP_ERR_INTERNAL,
        else => c.GLOWCAP_ERR_IO,
    };
}

fn multiplexedStartConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    locator_view: ?*const c.GlowcapLocatorView,
    options: ?*const c.GlowcapTransportOperationOptions,
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
    const locator = borrowed.value;
    if (!std.mem.eql(u8, locator.transport, iroh.transport_name))
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    adapter.payload.resident.loopStartConnectResolved(
        @intCast(request_id),
        locator.designator,
        net.netlayer.directAddrHint(locator.hints) orelse "",
    ) catch |err| {
        const code = dialErrToCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
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
    const handle = adapter.payload.resident.loopFinishConnect(@intCast(request_id)) catch |err| {
        const code = dialErrToCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    const conn_id: u64 = @intCast(adapter.payload.resident.loopConnId(handle));
    adapter.conns.put(adapter.payload.allocator, conn_id, handle) catch |err| {
        adapter.payload.resident.loopConnClose(handle);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err);
    };
    slot.* = conn_id;
    return GLOWCAP_OK;
}

fn multiplexedCancelConnect(ctx: ?*anyopaque, request_id: u64, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    MultiplexedAdapter.fromOpaque(ctx).payload.resident.loopCancelConnect(@intCast(request_id));
    return GLOWCAP_OK;
}

fn multiplexedListen(
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    options: ?*const c.GlowcapTransportOperationOptions,
    out_result: ?*c.GlowcapListenResult,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const result = out_result orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    if (adapter.listening)
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.AlreadyListening);
    const selected = (transport orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer))[0..transport_len];
    if (!std.mem.eql(u8, selected, model.transport.iroh))
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const requested: []const u8 = if (requested_designator) |ptr| ptr[0..requested_designator_len] else &.{};
    var designator: [iroh.node_id_len]u8 = undefined;
    const actual = adapter.payload.resident.nodeId(&designator);
    if (actual.len == 0 or (requested.len != 0 and !std.mem.eql(u8, requested, actual))) {
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    }
    const direct_addresses = adapter.payload.resident.directAddrsOwned(adapter.payload.allocator) catch |err| switch (err) {
        error.OutOfMemory => return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, error.OutOfMemory),
        error.AddressListTooLarge => return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.MetadataTooLarge),
        error.SidecarFailed => return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, error.SidecarFailed),
    };
    defer adapter.payload.allocator.free(direct_addresses);
    var hint_storage: [1]model.HintEntry = undefined;
    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = actual,
        .hints = model.Hints.forDirectAddresses(direct_addresses, &hint_storage),
    };
    adapter.listener_locator = model.clonePeerLocator(adapter.payload.allocator, locator) catch {
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, error.OutOfMemory);
    };
    adapter.listening = true;
    adapter.listener_route = route_id;
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
    if (!adapter.listening)
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.NotListening);
    const locator = adapter.listener_locator orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.MissingListenerLocator);
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
    if (!adapter.listening)
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.NotListening);
    const view = locator_view orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        adapter.payload.allocator,
        view,
        &hint_stack,
    ) catch |err| return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
    defer borrowed.deinit(adapter.payload.allocator);
    const active = adapter.listener_locator orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.MissingListenerLocator);
    iroh.validateListenerLocator(active.designator, borrowed.value) catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, err);
    return sink(sink_ctx, view);
}

fn multiplexedFinishAccept(ctx: ?*anyopaque, out_conn: ?*u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    if (!adapter.listening) return GLOWCAP_ERR_WOULD_BLOCK;
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const handle = adapter.payload.resident.loopTryAccept() orelse return GLOWCAP_ERR_WOULD_BLOCK;
    const conn_id: u64 = @intCast(adapter.payload.resident.loopConnId(handle));
    adapter.conns.put(adapter.payload.allocator, conn_id, handle) catch |err| {
        adapter.payload.resident.loopConnClose(handle);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err);
    };
    slot.* = conn_id;
    return GLOWCAP_OK;
}

fn multiplexedStopListen(ctx: ?*anyopaque, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    adapter.listening = false;
    adapter.listener_route = null;
    if (adapter.listener_locator) |locator| model.freePeerLocator(adapter.payload.allocator, locator);
    adapter.listener_locator = null;
    while (adapter.payload.resident.loopTryAccept()) |conn| {
        adapter.payload.resident.loopConnClose(conn);
    }
    return GLOWCAP_OK;
}

fn multiplexedTryRead(ctx: ?*anyopaque, conn: u64, buf: ?[*]u8, cap: usize) callconv(.c) isize {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const handle = adapter.conns.get(conn) orelse return -1;
    const dst = buf orelse return -1;
    return adapter.payload.resident.loopTryRead(handle, dst[0..cap]);
}

fn multiplexedTryWrite(ctx: ?*anyopaque, conn: u64, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const handle = adapter.conns.get(conn) orelse return -1;
    const src = bytes orelse return -1;
    return adapter.payload.resident.loopTryWrite(handle, src[0..len]);
}

fn multiplexedConnClose(ctx: ?*anyopaque, conn: u64, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    // Tolerant: a stale id drains to nothing, per the resident namespace rule.
    if (adapter.conns.fetchRemove(conn)) |row| {
        adapter.payload.resident.loopConnClose(row.value);
    }
    return GLOWCAP_OK;
}

fn multiplexedConnTakeFailure(_: ?*anyopaque, _: u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) void {
    if (out_failure) |slot| slot.* = std.mem.zeroes(c.GlowcapProviderFailure);
}

fn multiplexedConnRemoteKey(ctx: ?*anyopaque, conn: u64, out_key: ?[*]u8) callconv(.c) i32 {
    const adapter = MultiplexedAdapter.fromOpaque(ctx);
    const handle = adapter.conns.get(conn) orelse return 0;
    const dst = out_key orelse return 0;
    const key = adapter.payload.resident.loopConnRemoteKey(handle) orelse return 0;
    @memcpy(dst[0..key.bytes.len], &key.bytes);
    return 1;
}
