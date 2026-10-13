//! TCP runtime and generic driver-provider projection.
//!
//! This module owns the pinned `std.Io.Threaded` backend, its cancellable
//! operation lifetime, and the raw stream/listener callbacks installed into a
//! generic driver. The archive facade in `mod.zig` owns the blocking framed C
//! handles. Both borrow this one runtime authority. Neither mirrors its state.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const net = @import("net");
const c = @import("c_abi_shared");

pub const GlowcapTcpStreamOptions = extern struct {
    keepalive_idle_sec: u32,
    keepalive_interval_sec: u32,
    keepalive_count: u32,
};

pub const GlowcapTcpOperationOptions = extern struct {
    stream: GlowcapTcpStreamOptions,
};

const setLastError = c.setLastError;

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

pub const TcpNetlayerPayload = struct {
    threaded: std.Io.Threaded,
    /// The allocator the netlayer and every endpoint made from it use. Endpoints
    /// copy it onto their own payload so a conn/listener frees through the same
    /// policy as the netlayer that minted it.
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize),
    /// Covers each complete foreign constructor call, including result
    /// publication after its cancellable I/O task returns.
    calls: c.ForeignCallBarrier = .{},
    tasks: net.OperationOwner,
    stream_options: net.tcp.StreamOptions,
    provider_profiles: [net.tcp.profiles.len]ProviderProfile,
    provider_profile_abi: [net.tcp.profiles.len]c.GlowcapTransportProfile,
    provider_tables: [net.tcp.profiles.len]c.GlowcapStreamTransport,
    provider_entries: [net.tcp.profiles.len]c.GlowcapTransportProviderEntry,
    provider: c.GlowcapTransportProvider,

    /// `Threaded.io()` captures `&self.threaded`, so the payload must be
    /// heap-pinned for the borrowed `Io` to stay valid. The archive constructor
    /// allocates it at that stable address before this runtime is initialized.
    pub fn io(self: *TcpNetlayerPayload) std.Io {
        return self.threaded.io();
    }

    pub fn initProvider(self: *TcpNetlayerPayload) void {
        for (net.tcp.profiles, 0..) |transport, i| {
            self.provider_profiles[i] = .{ .owner = self, .transport = transport };
            self.provider_profile_abi[i] = c.transport_provider.profileFromMetadata(transport.metadata());
            self.provider_tables[i] = streamTransport(&self.provider_profiles[i]);
            self.provider_entries[i] = .{
                .profile = &self.provider_profile_abi[i],
                .execution_model = c.transport_provider.GLOWCAP_TRANSPORT_EXEC_STREAM,
                .implementation = &self.provider_tables[i],
            };
        }
        self.provider = .{
            .abi_version = c.transport_provider.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION,
            .struct_size = @sizeOf(c.GlowcapTransportProvider),
            .entries = &self.provider_entries,
            .entry_count = self.provider_entries.len,
            .lease_ctx = self,
            .same_configuration = providerSameConfiguration,
            .retain = providerRetain,
            .release = providerRelease,
        };
    }

    fn retain(self: *TcpNetlayerPayload) bool {
        var current = self.references.load(.acquire);
        while (current != 0) {
            if (self.references.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
                current = observed;
            } else return true;
        }
        return false;
    }

    pub fn release(self: *TcpNetlayerPayload) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        _ = self.calls.beginShutdown(self.io());
        self.tasks.shutdown();
        self.tasks.join();
        self.calls.wait(self.io());
        const alloc = self.allocator;
        self.threaded.deinit();
        alloc.destroy(self);
    }
};

fn providerSameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    const lhs: *TcpNetlayerPayload = @ptrCast(@alignCast(ctx orelse return 0));
    const rhs: *TcpNetlayerPayload = @ptrCast(@alignCast(other_ctx orelse return 0));
    return @intFromBool(std.meta.eql(lhs.stream_options, rhs.stream_options));
}

fn decodeStreamOptions(value: GlowcapTcpStreamOptions) error{InvalidStreamOptions}!net.tcp.StreamOptions {
    const idle = value.keepalive_idle_sec;
    const interval = value.keepalive_interval_sec;
    const count = value.keepalive_count;
    if (idle == 0 and interval == 0 and count == 0) return .{};
    if (idle == 0 or interval == 0 or count == 0 or
        idle > std.math.maxInt(c_int) or interval > std.math.maxInt(c_int) or count > std.math.maxInt(c_int))
        return error.InvalidStreamOptions;
    return .{ .keepalive = .{ .idle_sec = idle, .interval_sec = interval, .count = count } };
}

pub fn streamOptionsFromC(value: GlowcapTcpStreamOptions, operation: []const u8) error{InvalidStreamOptions}!net.tcp.StreamOptions {
    return decodeStreamOptions(value) catch |err| {
        setLastError("{s}: {s}", .{ operation, @errorName(err) });
        return err;
    };
}

pub fn operationStreamOptions(
    inherited: net.tcp.StreamOptions,
    options: ?*const GlowcapTcpStreamOptions,
) error{InvalidStreamOptions}!net.tcp.StreamOptions {
    return if (options) |value| decodeStreamOptions(value.*) else inherited;
}

fn providerOperationStreamOptions(
    inherited: net.tcp.StreamOptions,
    raw: ?*const c.GlowcapTransportOperationOptions,
) error{InvalidStreamOptions}!net.tcp.StreamOptions {
    const envelope = raw orelse return inherited;
    const typed = (net.OperationOptions{
        .data = envelope.data,
        .size = envelope.size,
    }).decode(GlowcapTcpOperationOptions) catch return error.InvalidStreamOptions;
    return decodeStreamOptions((typed orelse return inherited).stream);
}

fn providerRetain(ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *TcpNetlayerPayload = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return GLOWCAP_ERR_NULL_POINTER;
    }));
    if (payload.retain()) return GLOWCAP_OK;
    c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_CLOSED, error.Closed);
    return GLOWCAP_ERR_CLOSED;
}

fn providerRelease(ctx: ?*anyopaque, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *TcpNetlayerPayload = @ptrCast(@alignCast(ctx orelse return GLOWCAP_OK));
    payload.release();
    return GLOWCAP_OK;
}

const ProviderProfile = struct {
    owner: *TcpNetlayerPayload,
    transport: model.transport.Known,

    fn metadata(self: ProviderProfile) model.transport.Metadata {
        return self.transport.metadata();
    }
};

const RawConn = struct {
    connection: net.tcp.RawConnection,
    owner: *TcpNetlayerPayload,
    failure: c.GlowcapProviderFailure = std.mem.zeroes(c.GlowcapProviderFailure),
};

const RawListener = struct {
    listener: net.tcp.ProfileListener,
    locator: model.PeerLocator,
    owner: *TcpNetlayerPayload,
    stream_options: net.tcp.StreamOptions,
};

const ProviderDialAttempt = struct {
    owner: *TcpNetlayerPayload,
    address: std.Io.net.IpAddress,
    stream_options: net.tcp.StreamOptions,
    completion: net.TransportOperationCompletion,
    operation: net.CancelableOperation = undefined,
    result: Result = .pending,

    const Result = union(enum) {
        pending,
        connection: net.tcp.RawConnection,
        failure: net.tcp.ConnectRawError,
    };

    fn run(self: *ProviderDialAttempt) std.Io.Cancelable!void {
        self.result = if (net.tcp.connectRaw(self.owner.io(), self.address, &.{}, &.{}, self.stream_options)) |connection|
            .{ .connection = connection }
        else |err|
            .{ .failure = err };
        _ = self.completion.publish();
    }

    fn retire(raw: *anyopaque) void {
        const self: *ProviderDialAttempt = @ptrCast(@alignCast(raw));
        self.destroy();
    }

    fn destroy(self: *ProviderDialAttempt) void {
        switch (self.result) {
            .connection => |*connection| connection.close(),
            .pending, .failure => {},
        }
        self.completion.deinit();
        const allocator = self.owner.allocator;
        allocator.destroy(self);
    }
};

fn profileFrom(ctx: ?*anyopaque) *ProviderProfile {
    return @ptrCast(@alignCast(ctx.?));
}

fn streamTransport(profile: *ProviderProfile) c.GlowcapStreamTransport {
    return .{
        .abi_version = c.transport_provider.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.GlowcapStreamTransport),
        .ctx = profile,
        .start_connect = providerStartConnect,
        .finish_connect = providerFinishConnect,
        .cancel_connect = providerCancelConnect,
        .listen = providerListen,
        .listener_wait_acceptable = providerListenerWaitAcceptable,
        .listener_readiness_fd = providerListenerReadinessFd,
        .listener_locator = providerListenerLocator,
        .listener_advertise = providerListenerAdvertise,
        .accept = providerAccept,
        .listener_close = providerListenerClose,
        .try_read = providerTryRead,
        .try_write = providerTryWrite,
        .conn_close = providerConnClose,
        .conn_take_failure = providerConnTakeFailure,
    };
}

fn providerStartConnect(
    ctx: ?*anyopaque,
    locator_view: ?*const c.GlowcapLocatorView,
    options: ?*const c.GlowcapTransportOperationOptions,
    out_attempt: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const profile = profileFrom(ctx);
    const slot = out_attempt orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const fd_slot = out_readiness_fd orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const view = locator_view orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        profile.owner.allocator,
        view,
        &hint_stack,
    ) catch |err| {
        const code = c.locatorAdapterErrorCode(err);
        return c.transport_provider.failProvider(out_failure, code, err);
    };
    defer borrowed.deinit(profile.owner.allocator);
    const locator = borrowed.value;
    if (!std.mem.eql(u8, locator.transport, profile.metadata().symbol))
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const address = net.tcp.resolveProfile(
        profile.metadata(),
        locator.designator,
        net.netlayer.directAddrHint(locator.hints) orelse "",
    ) catch |err| return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, err);
    const stream_options = providerOperationStreamOptions(profile.owner.stream_options, options) catch
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const attempt = profile.owner.allocator.create(ProviderDialAttempt) catch |err| {
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_INTERNAL, err);
        return c.failInternal("tcp provider connect admission", err);
    };
    attempt.* = .{
        .owner = profile.owner,
        .address = address,
        .stream_options = stream_options,
        .completion = net.TransportOperationCompletion.init() catch |err| {
            profile.owner.allocator.destroy(attempt);
            c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_INTERNAL, err);
            return c.failInternal("tcp provider connect completion", err);
        },
    };
    profile.owner.tasks.startCancelable(
        &attempt.operation,
        ProviderDialAttempt.run,
        .{attempt},
        attempt,
        ProviderDialAttempt.retire,
    ) catch |err| {
        attempt.destroy();
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
    };
    slot.* = attempt;
    fd_slot.* = attempt.completion.readinessFd();
    return GLOWCAP_OK;
}

fn providerFinishConnect(
    attempt_raw: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const attempt: *ProviderDialAttempt = @ptrCast(@alignCast(attempt_raw orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer)));
    const slot = out_conn orelse {
        _ = providerCancelConnect(attempt, null);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    };
    const fd_slot = out_readiness_fd orelse {
        _ = providerCancelConnect(attempt, null);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    };
    const claimed = attempt.completion.claim() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
    };
    if (!claimed) return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_CLOSED, error.Closed);
    attempt.completion.wake.drain() catch |err| {
        _ = attempt.owner.tasks.reap(&attempt.operation);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
    };
    const result = attempt.result;
    attempt.result = .pending;
    switch (result) {
        .failure => |err| {
            _ = attempt.owner.tasks.reap(&attempt.operation);
            // std names the connect timeout `Timeout`; the shared table keys on
            // the netlayer's `TimedOut`, so classify first. The report names
            // the classification, which the driver reads back onto the retry
            // axis, and the std cause rides in the last-error text.
            const classified = net.tcp.classifyConnect(err);
            setLastError("connect: {s}: {s}", .{ @errorName(classified), @errorName(err) });
            return c.transport_provider.failProvider(out_failure, c.dialFailureCode(classified), classified);
        },
        .pending => unreachable,
        .connection => |connection| {
            const conn = attempt.owner.allocator.create(RawConn) catch |err| {
                var owned = connection;
                owned.close();
                _ = attempt.owner.tasks.reap(&attempt.operation);
                return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err);
            };
            conn.* = .{ .connection = connection, .owner = attempt.owner };
            if (!net.socket.setNoSigpipe(connection.readinessFd())) {
                conn.connection.close();
                attempt.owner.allocator.destroy(conn);
                _ = attempt.owner.tasks.reap(&attempt.operation);
                return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, error.SocketConfigurationFailed);
            }
            slot.* = conn;
            fd_slot.* = connection.readinessFd();
            _ = attempt.owner.tasks.reap(&attempt.operation);
            return GLOWCAP_OK;
        },
    }
}

fn providerCancelConnect(attempt_raw: ?*anyopaque, _: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const attempt: *ProviderDialAttempt = @ptrCast(@alignCast(attempt_raw orelse return GLOWCAP_OK));
    if (attempt.completion.cancel())
        _ = attempt.owner.tasks.reap(&attempt.operation)
    else
        _ = attempt.owner.tasks.cancel(&attempt.operation);
    return GLOWCAP_OK;
}

fn providerListen(
    ctx: ?*anyopaque,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    options: ?*const c.GlowcapTransportOperationOptions,
    out_result: ?*c.GlowcapListenResult,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const profile = profileFrom(ctx);
    const slot = out_result orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const requested = c.sliceFromC(requested_designator, requested_designator_len) catch
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const address = net.tcp.parseDesignator(requested) catch
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    const identity = c.sliceFromC(identity_designator, identity_designator_len) catch {
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    };
    const peer_key = if (profile.metadata().designator_scheme == .key)
        crypto.PeerKey.fromDesignator(identity) orelse
            return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress)
    else
        null;
    const stream_options = providerOperationStreamOptions(profile.owner.stream_options, options) catch
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    var listener = switch (profile.transport) {
        .tcp => net.tcp.ProfileListener.bind(.tcp, profile.owner.io(), address, peer_key),
        .keyed_tcp => net.tcp.ProfileListener.bind(.keyed_tcp, profile.owner.io(), address, peer_key),
        .noise_tcp => net.tcp.ProfileListener.bind(.noise_tcp, profile.owner.io(), address, peer_key),
        else => unreachable,
    } catch |err| {
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_IO, err);
        return c.failIo("tcp provider listen", err);
    };
    // A C-calling-convention function returns a code, not an error union, so
    // an `errdefer` here would never run: each refusal below releases what it
    // owns by hand before it returns.
    const locator = listener.localLocator(profile.owner.allocator) catch |err| {
        listener.deinit();
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_INTERNAL, err);
        return c.failInternal("tcp provider listener locator", err);
    };
    const raw = profile.owner.allocator.create(RawListener) catch |err| {
        model.freePeerLocator(profile.owner.allocator, locator);
        listener.deinit();
        c.transport_provider.setProviderFailure(out_failure, GLOWCAP_ERR_INTERNAL, err);
        return c.failInternal("tcp provider listener", err);
    };
    raw.* = .{
        .listener = listener,
        .locator = locator,
        .owner = profile.owner,
        .stream_options = stream_options,
    };
    slot.* = .{
        .state = c.GLOWCAP_LISTEN_READY,
        .listener = raw,
        .attempt = null,
        .readiness_fd = -1,
    };
    return GLOWCAP_OK;
}

fn rawListener(raw: ?*anyopaque) *RawListener {
    return @ptrCast(@alignCast(raw.?));
}

fn providerListenerWaitAcceptable(_: ?*anyopaque, listener: ?*anyopaque, timeout_ms: i32, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    return if (rawListener(listener).listener.waitAcceptable(timeout_ms) catch |err|
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err))
        GLOWCAP_OK
    else
        c.GLOWCAP_ERR_WOULD_BLOCK;
}

fn providerListenerReadinessFd(_: ?*anyopaque, listener: ?*anyopaque) callconv(.c) i32 {
    return rawListener(listener).listener.readinessFd();
}

fn providerListenerLocator(
    listener_raw: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.GlowcapLocatorSinkFn,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]c.GlowcapLocatorHintView = undefined;
    var projection = c.locator_adapter.Projection.init(
        listener.owner.allocator,
        listener.locator,
        &hint_stack,
    ) catch |err| return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
    defer projection.deinit(listener.owner.allocator);
    return sink(sink_ctx, &projection.view);
}

fn providerListenerAdvertise(
    listener_raw: ?*anyopaque,
    locator_view: ?*const c.GlowcapLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.GlowcapLocatorSinkFn,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const view = locator_view orelse
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        listener.owner.allocator,
        view,
        &hint_stack,
    ) catch |err| return c.transport_provider.failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
    defer borrowed.deinit(listener.owner.allocator);
    listener.listener.validateLocator(borrowed.value) catch |err| {
        c.setLastError("tcp listener advertise: {s}", .{@errorName(err)});
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, err);
    };
    return sink(sink_ctx, view);
}

fn providerAccept(_: ?*anyopaque, listener_raw: ?*anyopaque, out_conn: ?*?*anyopaque, out_readiness_fd: ?*i32, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const fd_slot = out_readiness_fd orelse return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const connection = listener.listener.acceptRaw(&.{}, &.{}, listener.stream_options) catch |err| {
        setLastError("accept: {s}", .{@errorName(err)});
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, err);
    };
    const owner = listener.owner;
    const conn = owner.allocator.create(RawConn) catch |err| {
        var owned = connection;
        owned.close();
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err);
    };
    conn.* = .{ .connection = connection, .owner = owner };
    if (!net.socket.setNoSigpipe(connection.readinessFd())) {
        conn.connection.close();
        owner.allocator.destroy(conn);
        return c.transport_provider.failProvider(out_failure, GLOWCAP_ERR_IO, error.SocketConfigurationFailed);
    }
    slot.* = conn;
    fd_slot.* = connection.readinessFd();
    return GLOWCAP_OK;
}

fn providerListenerClose(
    _: ?*anyopaque,
    listener_raw: ?*anyopaque,
    _: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const owner = listener.owner;
    listener.listener.deinit();
    model.freePeerLocator(owner.allocator, listener.locator);
    owner.allocator.destroy(listener);
    return GLOWCAP_OK;
}

fn rawConn(raw: ?*anyopaque) *RawConn {
    return @ptrCast(@alignCast(raw.?));
}

fn providerTryRead(_: ?*anyopaque, conn_raw: ?*anyopaque, out: ?[*]u8, cap: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    const dest = (out orelse {
        c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return -1;
    })[0..cap];
    const got = net.socket.receiveNonblocking(conn.connection.readinessFd(), dest) catch |err| {
        if (err == error.WouldBlock) return c.transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_IO, err);
        return -1;
    };
    return @intCast(got);
}

fn providerTryWrite(_: ?*anyopaque, conn_raw: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    const source = bytes orelse {
        c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
        return -1;
    };
    const wrote = net.socket.sendNonblocking(conn.connection.readinessFd(), source[0..len]) catch |err| {
        if (err == error.WouldBlock) return c.transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(conn.failure))
            c.transport_provider.setProviderFailure(&conn.failure, GLOWCAP_ERR_IO, err);
        return -1;
    };
    return @intCast(wrote);
}

fn providerConnTakeFailure(_: ?*anyopaque, conn_raw: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) void {
    c.transport_provider.takeProviderFailure(&rawConn(conn_raw).failure, out_failure);
}

fn providerConnClose(
    _: ?*anyopaque,
    conn_raw: ?*anyopaque,
    _: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const conn = rawConn(conn_raw);
    const owner = conn.owner;
    conn.connection.close();
    owner.allocator.destroy(conn);
    return GLOWCAP_OK;
}
