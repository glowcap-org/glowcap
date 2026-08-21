//! Generic stream-provider projection for the onion runtime.
//
// This layer translates the fixed C provider table into the native onion
// resident. Tor control, SOCKS, and service policy remain in the native layer.

const std = @import("std");
const model = @import("model");
const net = @import("net");
const c = @import("c_abi_shared");
const attempts = @import("attempt.zig");
const connection = @import("connection.zig");
const failure_projection = @import("../failure.zig");
const runtime = @import("../runtime/state.zig");

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;

const RawListener = struct {
    listener: *net.onion.Listener,
    locator: model.PeerLocator,
    owner: *runtime.Netlayer,
    operations: c.ForeignCallBarrier = .{},
};

pub fn init(owner: *runtime.Netlayer) void {
    owner.provider_profile = .{ .owner = owner };
    owner.provider_profile_abi = c.transport_provider.profileFromMetadata(
        model.transport.Known.onion.metadata(),
    );
    owner.provider_table = streamTransport(&owner.provider_profile);
    owner.provider_entry = .{
        .profile = &owner.provider_profile_abi,
        .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM,
        .implementation = &owner.provider_table,
    };
    owner.provider = .{
        .abi_version = c.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeTransportProvider),
        .entries = @ptrCast(&owner.provider_entry),
        .entry_count = 1,
        .lease_ctx = owner,
        .same_configuration = providerSameConfiguration,
        .retain = providerRetain,
        .release = providerRelease,
    };
}

pub fn package(owner: *const runtime.Netlayer) c.PancakeTransportProvider {
    return owner.provider;
}

fn authEqual(a: net.onion.control.Auth, b: net.onion.control.Auth) bool {
    return switch (a) {
        .none => b == .none,
        .cookie => |left| switch (b) {
            .cookie => |right| std.mem.eql(u8, left, right),
            else => false,
        },
        .password => |left| switch (b) {
            .password => |right| std.mem.eql(u8, left, right),
            else => false,
        },
    };
}

fn providerSameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    const left: *runtime.Netlayer = @ptrCast(@alignCast(ctx orelse return 0));
    const right: *runtime.Netlayer = @ptrCast(@alignCast(other_ctx orelse return 0));
    const a = left.resident.config;
    const b = right.resident.config;
    return @intFromBool(
        std.mem.eql(u8, a.socks, b.socks) and
            std.mem.eql(u8, a.control_endpoint, b.control_endpoint) and
            authEqual(a.auth, b.auth) and
            std.mem.eql(u8, a.service_key, b.service_key) and
            std.mem.eql(u8, a.forward, b.forward),
    );
}

fn providerRetain(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *runtime.Netlayer = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return PANCAKE_ERR_NULL_POINTER;
    }));
    if (payload.retain()) return PANCAKE_OK;
    c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    return PANCAKE_ERR_CLOSED;
}

fn providerRelease(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *runtime.Netlayer = @ptrCast(@alignCast(ctx orelse return PANCAKE_OK));
    if (payload.release()) |failure| {
        c.setLastErrorChain("onion provider release", failure);
        const code = failure_projection.providerListen(failure.cause);
        return c.transport_provider.failProviderChain(out_failure, code, failure, failure_projection.providerListen);
    }
    return PANCAKE_OK;
}

fn profileFrom(ctx: ?*anyopaque) *runtime.Profile {
    return @ptrCast(@alignCast(ctx.?));
}

fn streamTransport(profile: *runtime.Profile) c.PancakeStreamTransport {
    return .{
        .abi_version = c.transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeStreamTransport),
        .ctx = profile,
        .start_connect = providerStartConnect,
        .finish_connect = providerFinishConnect,
        .cancel_connect = providerCancelConnect,
        .listen = providerListen,
        .finish_listen = providerFinishListen,
        .cancel_listen = providerCancelListen,
        .listener_wait_acceptable = providerListenerWaitAcceptable,
        .listener_readiness_fd = providerListenerReadinessFd,
        .listener_locator = providerListenerLocator,
        .listener_advertise = providerListenerAdvertise,
        .listener_restoration_state = providerListenerRestorationState,
        .accept = providerAccept,
        .listener_close = providerListenerClose,
        .read = connection.providerRead,
        .write_all = connection.providerWriteAll,
        .conn_close = connection.providerConnClose,
        .conn_take_failure = connection.providerConnTakeFailure,
    };
}

fn providerListenerRestorationState(
    listener_raw: ?*anyopaque,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const len_slot = out_len orelse
        return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    len_slot.* = 0;
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io()))
        return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    const state = listener.listener.serviceKey();
    len_slot.* = state.len;
    if (cap < state.len) return c.PANCAKE_ERR_BUFFER_TOO_SMALL;
    if (state.len != 0) {
        const dest = out orelse
            return c.transport_provider.failProvider(out_failure, c.PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        @memcpy(dest[0..state.len], state);
    }
    return c.PANCAKE_OK;
}

fn rawListener(raw: ?*anyopaque) *RawListener {
    return @ptrCast(@alignCast(raw.?));
}

fn onionLocatorFromView(view: *const c.PancakeLocatorView) ?model.PeerLocator {
    if (view.abi_version != c.PANCAKE_LOCATOR_VIEW_ABI_VERSION or
        view.struct_size < @sizeOf(c.PancakeLocatorView) or
        view.hint_count != 0 or
        view.hint_wire_form != c.PANCAKE_HINTS_BOOLEAN_FALSE)
        return null;
    return c.locator_adapter.fromView(view, &.{}) catch null;
}

fn providerStartConnect(
    ctx: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    options: ?*const c.PancakeTransportOperationOptions,
    out_attempt: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const profile = profileFrom(ctx);
    const slot = out_attempt orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const fd_slot = out_readiness_fd orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const view = locator_view orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const locator = onionLocatorFromView(view) orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    if (!std.mem.eql(u8, locator.transport, model.transport.Known.onion.metadata().symbol))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const attempt = profile.owner.allocator.create(attempts.Dial) catch |err| {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider connect admission", err);
    };
    const designator = profile.owner.allocator.dupe(u8, locator.designator) catch |err| {
        profile.owner.allocator.destroy(attempt);
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider connect designator", err);
    };
    attempt.* = .{
        .owner = profile.owner,
        .designator = designator,
        .completion = net.TransportOperationCompletion.init() catch |err| {
            profile.owner.allocator.free(designator);
            profile.owner.allocator.destroy(attempt);
            c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
            return c.failInternal("onion provider connect completion", err);
        },
    };
    profile.owner.tasks.startCancelable(
        &attempt.operation,
        attempts.Dial.run,
        .{attempt},
        attempt,
        attempts.Dial.retire,
    ) catch |err| {
        attempt.destroy();
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    slot.* = attempt;
    fd_slot.* = attempt.completion.readinessFd();
    return PANCAKE_OK;
}

fn providerFinishConnect(
    attempt_raw: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const attempt: *attempts.Dial = @ptrCast(@alignCast(attempt_raw orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer)));
    const slot = out_conn orelse {
        _ = providerCancelConnect(attempt, null);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const fd_slot = out_readiness_fd orelse {
        _ = providerCancelConnect(attempt, null);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const claimed = attempt.completion.claim() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    if (!claimed) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    attempt.completion.wake.drain() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    const result = attempt.result;
    attempt.result = .pending;
    switch (result) {
        .failure => |err| {
            _ = attempt.owner.tasks.reap(&attempt.operation);
            const code = failure_projection.providerDial(err);
            return c.transport_provider.failProvider(out_failure, code, err);
        },
        .pending => unreachable,
        .stream => |stream| {
            if (!attempt.owner.retain()) {
                stream.close(attempt.owner.io());
                _ = attempt.owner.tasks.reap(&attempt.operation);
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
            }
            const adopted = connection.adoptStream(attempt.owner, stream) catch |err| {
                _ = attempt.owner.tasks.reap(&attempt.operation);
                return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INTERNAL, err);
            };
            slot.* = adopted.handle;
            fd_slot.* = adopted.readiness_fd;
            _ = attempt.owner.tasks.reap(&attempt.operation);
            return PANCAKE_OK;
        },
    }
}

fn providerCancelConnect(attempt_raw: ?*anyopaque, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const attempt: *attempts.Dial = @ptrCast(@alignCast(attempt_raw orelse return PANCAKE_OK));
    if (attempt.completion.cancel())
        _ = attempt.owner.tasks.reap(&attempt.operation)
    else
        _ = attempt.owner.tasks.cancel(&attempt.operation);
    return PANCAKE_OK;
}

fn providerListen(
    ctx: ?*anyopaque,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    options: ?*const c.PancakeTransportOperationOptions,
    out_result: ?*c.PancakeListenResult,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const profile = profileFrom(ctx);
    const slot = out_result orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const requested = c.sliceFromC(requested_designator, requested_designator_len) catch
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    _ = c.sliceFromC(identity_designator, identity_designator_len) catch
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const attempt = profile.owner.allocator.create(attempts.Listen) catch |err| {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider listen admission", err);
    };
    const requested_copy = profile.owner.allocator.dupe(u8, requested) catch |err| {
        profile.owner.allocator.destroy(attempt);
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
        return c.failInternal("onion provider listen designator", err);
    };
    attempt.* = .{
        .owner = profile.owner,
        .requested_designator = requested_copy,
        .completion = net.TransportOperationCompletion.init() catch |err| {
            profile.owner.allocator.free(requested_copy);
            profile.owner.allocator.destroy(attempt);
            c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_INTERNAL, err);
            return c.failInternal("onion provider listen completion", err);
        },
    };
    profile.owner.tasks.startCancelable(
        &attempt.operation,
        attempts.Listen.run,
        .{attempt},
        attempt,
        attempts.Listen.retire,
    ) catch |err| {
        attempt.destroy();
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    slot.* = .{
        .state = c.PANCAKE_LISTEN_PENDING,
        .listener = null,
        .attempt = attempt,
        .readiness_fd = attempt.completion.readinessFd(),
    };
    return PANCAKE_OK;
}

fn providerFinishListen(
    attempt_raw: ?*anyopaque,
    out_listener: ?*?*anyopaque,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const attempt: *attempts.Listen = @ptrCast(@alignCast(attempt_raw orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer)));
    const slot = out_listener orelse {
        _ = providerCancelListen(attempt, null);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    };
    const claimed = attempt.completion.claim() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    if (!claimed) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    attempt.completion.wake.drain() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    };
    const result = attempt.result;
    attempt.result = .pending;
    defer _ = attempt.owner.tasks.reap(&attempt.operation);
    switch (result) {
        .failure => |failure| {
            c.setLastErrorChain("onion provider listen", failure);
            const code = failure_projection.providerListen(failure.cause);
            c.transport_provider.setProviderFailureChain(out_failure, code, failure, failure_projection.providerListen);
            return code;
        },
        .pending => unreachable,
        .listener => |listener| {
            if (!attempt.owner.retain()) {
                var failure = net.netlayer.ListenFailure.init(error.Closed);
                if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                c.setLastErrorChain("onion provider listen", failure);
                c.transport_provider.setProviderFailureChain(out_failure, PANCAKE_ERR_CLOSED, failure, failure_projection.providerListen);
                return PANCAKE_ERR_CLOSED;
            }
            var owns_owner_ref = true;
            defer if (owns_owner_ref) attempt.owner.releaseProviderChild();
            const locator = model.clonePeerLocator(attempt.owner.allocator, .{
                .transport = model.transport.Known.onion.metadata().symbol,
                .designator = listener.designator(),
                .hints = .emptyFalse(),
            }) catch |err| {
                var failure = net.netlayer.ListenFailure.init(err);
                if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                c.setLastErrorChain("onion provider listener locator", failure);
                c.transport_provider.setProviderFailureChain(out_failure, PANCAKE_ERR_INTERNAL, failure, failure_projection.providerListen);
                return PANCAKE_ERR_INTERNAL;
            };
            const raw = attempt.owner.allocator.create(RawListener) catch |err| {
                model.freePeerLocator(attempt.owner.allocator, locator);
                var failure = net.netlayer.ListenFailure.init(err);
                if (listener.deinit()) |cleanup| failure.noteChain(cleanup);
                c.setLastErrorChain("onion provider listener", failure);
                c.transport_provider.setProviderFailureChain(out_failure, PANCAKE_ERR_INTERNAL, failure, failure_projection.providerListen);
                return PANCAKE_ERR_INTERNAL;
            };
            raw.* = .{ .listener = listener, .locator = locator, .owner = attempt.owner, .operations = .{} };
            slot.* = raw;
            owns_owner_ref = false;
            return PANCAKE_OK;
        },
    }
}

fn providerCancelListen(attempt_raw: ?*anyopaque, _: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const attempt: *attempts.Listen = @ptrCast(@alignCast(attempt_raw orelse return PANCAKE_OK));
    if (attempt.completion.cancel())
        _ = attempt.owner.tasks.reap(&attempt.operation)
    else
        _ = attempt.owner.tasks.cancel(&attempt.operation);
    return PANCAKE_OK;
}

fn providerListenerWaitAcceptable(_: ?*anyopaque, listener: ?*anyopaque, timeout_ms: i32, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const raw = rawListener(listener);
    if (!raw.operations.acquire(raw.owner.io())) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer raw.operations.release(raw.owner.io());
    return if (raw.listener.waitAcceptable(timeout_ms) catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err))
        PANCAKE_OK
    else
        PANCAKE_ERR_WOULD_BLOCK;
}

fn providerListenerReadinessFd(_: ?*anyopaque, listener: ?*anyopaque) callconv(.c) i32 {
    const raw = rawListener(listener);
    if (!raw.operations.acquire(raw.owner.io())) return -1;
    defer raw.operations.release(raw.owner.io());
    return @intCast(raw.listener.readinessFd());
}

fn providerListenerLocator(
    listener_raw: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io()))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    var hint_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    const view = c.locator_adapter.project(
        listener.locator,
        hint_stack[0..listener.locator.hints.entries.len],
    ) catch |err| {
        c.setLastError("onion listener locator projection: {s}", .{@errorName(err)});
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, err);
    };
    return sink(sink_ctx, &view);
}

fn providerListenerAdvertise(
    listener_raw: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io()))
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    const view = locator_view orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const locator = onionLocatorFromView(view) orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const canonical = net.netlayer.canonicalizeFixedLocator(
        listener.owner.allocator,
        locator,
        listener.locator.transport,
        listener.locator.designator,
    ) catch |err| return c.transport_provider.failProvider(
        out_failure,
        if (err == error.OutOfMemory) PANCAKE_ERR_INTERNAL else PANCAKE_ERR_INVALID_ARGUMENT,
        err,
    );
    defer model.freePeerLocator(listener.owner.allocator, canonical);
    var c_hint_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    const canonical_view = c.locator_adapter.project(
        canonical,
        c_hint_stack[0..canonical.hints.entries.len],
    ) catch |err|
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, err);
    return sink(sink_ctx, &canonical_view);
}

fn providerAccept(_: ?*anyopaque, listener_raw: ?*anyopaque, out_conn: ?*?*anyopaque, out_readiness_fd: ?*i32, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    if (!listener.operations.acquire(listener.owner.io())) return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    defer listener.operations.release(listener.owner.io());
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const fd_slot = out_readiness_fd orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const stream = listener.listener.acceptRawStream() catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
    if (!listener.owner.retain()) {
        stream.close(listener.owner.io());
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, error.Closed);
    }
    const adopted = connection.adoptStream(listener.owner, stream) catch |err| {
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INTERNAL, err);
    };
    slot.* = adopted.handle;
    fd_slot.* = adopted.readiness_fd;
    return PANCAKE_OK;
}

fn providerListenerClose(
    _: ?*anyopaque,
    listener_raw: ?*anyopaque,
    out_failure: ?*c.PancakeProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const owner = listener.owner;
    if (listener.operations.beginShutdown(owner.io())) listener.listener.shutdown();
    listener.operations.wait(owner.io());
    var failure = listener.listener.deinit();
    model.freePeerLocator(owner.allocator, listener.locator);
    owner.allocator.destroy(listener);
    if (owner.release()) |runtime_failure| {
        if (failure) |*primary|
            primary.noteChain(runtime_failure)
        else
            failure = runtime_failure;
    }
    if (failure) |chain| {
        c.setLastErrorChain("onion provider listener close", chain);
        const code = failure_projection.providerListen(chain.cause);
        return c.transport_provider.failProviderChain(out_failure, code, chain, failure_projection.providerListen);
    }
    return PANCAKE_OK;
}
