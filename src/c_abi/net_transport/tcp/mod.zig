//! The framed TCP stream's public C ABI — `libpancake_net_transport_tcp`.
//!
//! Blocking, cleartext TCP endpoint handles for a byte-fed Host. The C side
//! cannot name a Zig `Io`, so the backend is
//! an explicit owned handle: `PancakeTcpNetlayer` owns one `std.Io.Threaded`.
//! Endpoints created from it borrow that backend and must be closed before it is
//! released. There is no TLS.
//!
//! This is a *separate archive* from `libpancake_ocapn` (ADR-0059): it imports
//! only the shared vocabulary leaf (`@import("c_abi_shared")` — frame/context
//! types, codes, allocation, the last-error slot), so it exports just the
//! `pancake_tcp_*` family and shares no core symbol with the ocapn archive. A
//! consumer links both libraries (ocapn for shared vocabulary, this for the
//! stream adapter) and reuses the shared types by layout, exactly as a C program
//! including `pancake_ocapn.h` and `pancake_net_transport_tcp.h` does. The transport
//! carries its own per-thread last-error slot, read through
//! `pancake_tcp_last_error`.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const net = @import("net");

// The shared C-ABI vocabulary leaf — types, codes, allocation policy,
// managed-frame machinery, and the per-thread last-error slot — *not* the ocapn
// root. Importing the leaf gives this transport ABI the same frame and context
// types `pancake_ocapn.h` declares, with its own compiled copy of the helpers
// and last-error slot, and pulls *none* of the ocapn archive's exported surface
// (ADR-0059 companion split, generalized from the iroh companion).
const c = @import("c_abi_shared");

/// The netlayer handle owns the one I/O backend the endpoints run on. Created
/// and released explicitly by the host; it must outlive every connection and
/// listener made from it.
pub const PancakeTcpNetlayer = opaque {};
/// One blocking TCP connection carrying one OCapN session, framed on the
/// netlayer's codec. Owned by the caller; released with `pancake_tcp_conn_release`.
pub const PancakeTcpConn = opaque {};
/// A bound TCP listener. Owned by the caller; released with
/// `pancake_tcp_listener_release`.
pub const PancakeTcpListener = opaque {};
const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;

const setLastError = c.setLastError;
const clearLastError = c.lastErrorClear;
const codecFromC = c.codecFromC;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_SESSION = c.PANCAKE_ERR_SESSION;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// Copy the calling thread's last TCP-transport error message into `out_buf`,
/// the tcp sibling of `pancake_last_error`. `libpancake_net_transport_tcp`
/// carries its own per-thread slot (a separate compiled copy of the shared
/// leaf's slot), so a `pancake_tcp_*` call that returns `PANCAKE_ERR_IO` records
/// its cause here, readable independently of the ocapn archive's. Copies at most
/// `cap - 1` bytes and always NUL-terminates when `cap > 0`; `out_buf == NULL`
/// or `cap == 0` queries the length. Returns the full message length, or 0 when
/// none is set.
pub export fn pancake_tcp_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's tcp-transport last error slot.
pub export fn pancake_tcp_clear_last_error() void {
    c.lastErrorClear();
}

/// The netlayer handle owns the one I/O backend the endpoints run on. It is
/// created and released explicitly by the host. `std.Io` cannot cross the C ABI,
/// so this is the plain handle translation of "pass `Io` in" rather than a
/// hidden process-global runtime. Endpoints created from it borrow its `Io`, so
/// the handle must outlive every connection and listener made from it.
const TcpNetlayerPayload = struct {
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
    provider_profiles: [3]ProviderProfile,
    provider_profile_abi: [3]c.PancakeTransportProfile,
    provider_tables: [3]c.PancakeStreamTransport,
    provider_entries: [3]c.PancakeTransportProviderEntry,
    provider: c.PancakeTransportProvider,

    /// `Threaded.io()` captures `&self.threaded`, so the payload must be
    /// heap-pinned for the borrowed `Io` to stay valid. `create` gives it that
    /// stable address.
    fn io(self: *TcpNetlayerPayload) std.Io {
        return self.threaded.io();
    }

    fn initProvider(self: *TcpNetlayerPayload) void {
        for (net.tcp.profiles, 0..) |transport, i| {
            self.provider_profiles[i] = .{ .owner = self, .transport = transport };
            self.provider_profile_abi[i] = c.transport_provider.profileFromMetadata(transport.metadata());
            self.provider_tables[i] = streamTransport(&self.provider_profiles[i]);
            self.provider_entries[i] = .{
                .profile = &self.provider_profile_abi[i],
                .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM,
                .implementation = &self.provider_tables[i],
            };
        }
        self.provider = .{
            .abi_version = c.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
            .struct_size = @sizeOf(c.PancakeTransportProvider),
            .entries = &self.provider_entries,
            .entry_count = self.provider_entries.len,
            .lease_ctx = self,
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

    fn release(self: *TcpNetlayerPayload) void {
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

fn providerRetain(ctx: ?*anyopaque) callconv(.c) i32 {
    const payload: *TcpNetlayerPayload = @ptrCast(@alignCast(ctx orelse return PANCAKE_ERR_NULL_POINTER));
    return if (payload.retain()) PANCAKE_OK else PANCAKE_ERR_CLOSED;
}

fn providerRelease(ctx: ?*anyopaque) callconv(.c) void {
    const payload: *TcpNetlayerPayload = @ptrCast(@alignCast(ctx orelse return));
    payload.release();
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
};

const RawListener = struct {
    listener: net.tcp.ProfileListener,
    locator: model.PeerLocator,
    owner: *TcpNetlayerPayload,
};

const ProviderConnectAttempt = struct {
    owner: *TcpNetlayerPayload,
    address: std.Io.net.IpAddress,
    completion: net.AsyncConnectCompletion,
    result: Result = .pending,

    const Result = union(enum) {
        pending,
        connection: net.tcp.RawConnection,
        failure: i32,
    };

    fn run(self: *ProviderConnectAttempt) std.Io.Cancelable!void {
        self.result = if (net.tcp.connectRaw(self.owner.io(), self.address, &.{}, &.{}, .{})) |connection|
            .{ .connection = connection }
        else |_|
            .{ .failure = PANCAKE_ERR_IO };
        if (!self.completion.publish()) self.destroy();
    }

    fn destroy(self: *ProviderConnectAttempt) void {
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

fn streamTransport(profile: *ProviderProfile) c.PancakeStreamTransport {
    return .{
        .abi_version = c.transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeStreamTransport),
        .ctx = profile,
        .start_connect = providerStartConnect,
        .finish_connect = providerFinishConnect,
        .cancel_connect = providerCancelConnect,
        .listen = providerListen,
        .listener_wait_ready = providerListenerWaitReady,
        .listener_wait_acceptable = providerListenerWaitAcceptable,
        .listener_readiness_fd = providerListenerReadinessFd,
        .listener_locator = providerListenerLocator,
        .listener_advertise = providerListenerAdvertise,
        .accept = providerAccept,
        .listener_close = providerListenerClose,
        .read = providerRead,
        .write_all = providerWriteAll,
        .conn_close = providerConnClose,
    };
}

fn providerStartConnect(
    ctx: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    out_attempt: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
) callconv(.c) i32 {
    const profile = profileFrom(ctx);
    const slot = out_attempt orelse return PANCAKE_ERR_NULL_POINTER;
    const fd_slot = out_readiness_fd orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    fd_slot.* = -1;
    const view = locator_view orelse return PANCAKE_ERR_NULL_POINTER;
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        profile.owner.allocator,
        view,
        &hint_stack,
    ) catch |err| return c.locatorAdapterErrorCode(err);
    defer borrowed.deinit(profile.owner.allocator);
    const locator = borrowed.value;
    if (!std.mem.eql(u8, locator.transport, profile.metadata().symbol)) return PANCAKE_ERR_INVALID_ARGUMENT;
    const address = net.tcp.resolveProfile(
        profile.metadata(),
        locator.designator,
        net.netlayer.directAddrHint(locator.hints) orelse "",
    ) catch
        return PANCAKE_ERR_INVALID_ARGUMENT;
    const attempt = profile.owner.allocator.create(ProviderConnectAttempt) catch return PANCAKE_ERR_INTERNAL;
    attempt.* = .{
        .owner = profile.owner,
        .address = address,
        .completion = net.AsyncConnectCompletion.init() catch {
            profile.owner.allocator.destroy(attempt);
            return PANCAKE_ERR_INTERNAL;
        },
    };
    profile.owner.tasks.start(ProviderConnectAttempt.run, .{attempt}) catch {
        attempt.destroy();
        return PANCAKE_ERR_IO;
    };
    slot.* = attempt;
    fd_slot.* = attempt.completion.readinessFd();
    return PANCAKE_OK;
}

fn providerFinishConnect(
    attempt_raw: ?*anyopaque,
    out_conn: ?*?*anyopaque,
    out_readiness_fd: ?*i32,
) callconv(.c) i32 {
    const attempt: *ProviderConnectAttempt = @ptrCast(@alignCast(attempt_raw orelse return PANCAKE_ERR_NULL_POINTER));
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const fd_slot = out_readiness_fd orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    fd_slot.* = -1;
    if (!attempt.completion.claim()) return PANCAKE_ERR_CLOSED;
    attempt.completion.wake.drain();
    const result = attempt.result;
    attempt.result = .pending;
    switch (result) {
        .failure => |code| {
            attempt.destroy();
            return code;
        },
        .pending => unreachable,
        .connection => |connection| {
            const conn = attempt.owner.allocator.create(RawConn) catch {
                var owned = connection;
                owned.close();
                attempt.destroy();
                return PANCAKE_ERR_INTERNAL;
            };
            conn.* = .{ .connection = connection, .owner = attempt.owner };
            slot.* = conn;
            fd_slot.* = connection.readinessFd();
            attempt.destroy();
            return PANCAKE_OK;
        },
    }
}

fn providerCancelConnect(attempt_raw: ?*anyopaque) callconv(.c) void {
    const attempt: *ProviderConnectAttempt = @ptrCast(@alignCast(attempt_raw orelse return));
    if (attempt.completion.cancel()) attempt.destroy();
}

fn providerListen(
    ctx: ?*anyopaque,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    out_listener: ?*?*anyopaque,
) callconv(.c) i32 {
    const profile = profileFrom(ctx);
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const requested = c.sliceFromC(requested_designator, requested_designator_len) catch return PANCAKE_ERR_NULL_POINTER;
    const address = net.tcp.parseDesignator(requested) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const identity = c.sliceFromC(identity_designator, identity_designator_len) catch {
        return PANCAKE_ERR_NULL_POINTER;
    };
    const peer_key = if (profile.metadata().designator_scheme == .key)
        crypto.PeerKey.fromDesignator(identity) orelse return PANCAKE_ERR_INVALID_ARGUMENT
    else
        null;
    var listener = switch (profile.transport) {
        .tcp => net.tcp.ProfileListener.bind(.tcp, profile.owner.io(), address, peer_key),
        .keyed_tcp => net.tcp.ProfileListener.bind(.keyed_tcp, profile.owner.io(), address, peer_key),
        .noise_tcp => net.tcp.ProfileListener.bind(.noise_tcp, profile.owner.io(), address, peer_key),
        else => unreachable,
    } catch return PANCAKE_ERR_IO;
    errdefer listener.deinit();
    const locator = listener.localLocator(profile.owner.allocator) catch return PANCAKE_ERR_INTERNAL;
    errdefer model.freePeerLocator(profile.owner.allocator, locator);
    const raw = profile.owner.allocator.create(RawListener) catch return PANCAKE_ERR_INTERNAL;
    raw.* = .{ .listener = listener, .locator = locator, .owner = profile.owner };
    slot.* = raw;
    return PANCAKE_OK;
}

fn rawListener(raw: ?*anyopaque) *RawListener {
    return @ptrCast(@alignCast(raw.?));
}

fn providerListenerWaitReady(_: ?*anyopaque, _: ?*anyopaque, _: i32) callconv(.c) i32 {
    return PANCAKE_OK;
}

fn providerListenerWaitAcceptable(_: ?*anyopaque, listener: ?*anyopaque, timeout_ms: i32) callconv(.c) i32 {
    return if (rawListener(listener).listener.waitAcceptable(timeout_ms) catch return PANCAKE_ERR_IO)
        PANCAKE_OK
    else
        c.PANCAKE_ERR_WOULD_BLOCK;
}

fn providerListenerReadinessFd(_: ?*anyopaque, listener: ?*anyopaque) callconv(.c) i32 {
    return rawListener(listener).listener.readinessFd();
}

fn providerListenerLocator(
    listener_raw: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]c.PancakeLocatorHintView = undefined;
    var projection = c.locator_adapter.Projection.init(
        listener.owner.allocator,
        listener.locator,
        &hint_stack,
    ) catch |err| return c.locatorAdapterErrorCode(err);
    defer projection.deinit(listener.owner.allocator);
    return sink(sink_ctx, &projection.view);
}

fn providerListenerAdvertise(
    listener_raw: ?*anyopaque,
    locator_view: ?*const c.PancakeLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.PancakeLocatorSinkFn,
) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const view = locator_view orelse return PANCAKE_ERR_NULL_POINTER;
    var hint_stack: [c.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = c.locator_adapter.BorrowedLocator.init(
        listener.owner.allocator,
        view,
        &hint_stack,
    ) catch |err| return c.locatorAdapterErrorCode(err);
    defer borrowed.deinit(listener.owner.allocator);
    listener.listener.validateLocator(borrowed.value) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    return sink(sink_ctx, view);
}

fn providerAccept(_: ?*anyopaque, listener_raw: ?*anyopaque, out_conn: ?*?*anyopaque, out_readiness_fd: ?*i32) callconv(.c) i32 {
    const listener = rawListener(listener_raw);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const fd_slot = out_readiness_fd orelse return PANCAKE_ERR_NULL_POINTER;
    const connection = listener.listener.acceptRaw(&.{}, &.{}, .{}) catch return PANCAKE_ERR_IO;
    const owner = listener.owner;
    const conn = owner.allocator.create(RawConn) catch {
        var owned = connection;
        owned.close();
        return PANCAKE_ERR_INTERNAL;
    };
    conn.* = .{ .connection = connection, .owner = owner };
    slot.* = conn;
    fd_slot.* = connection.readinessFd();
    return PANCAKE_OK;
}

fn providerListenerClose(_: ?*anyopaque, listener_raw: ?*anyopaque) callconv(.c) void {
    const listener = rawListener(listener_raw);
    const owner = listener.owner;
    listener.listener.deinit();
    model.freePeerLocator(owner.allocator, listener.locator);
    owner.allocator.destroy(listener);
}

fn rawConn(raw: ?*anyopaque) *RawConn {
    return @ptrCast(@alignCast(raw.?));
}

fn providerRead(_: ?*anyopaque, conn_raw: ?*anyopaque, out: ?[*]u8, cap: usize) callconv(.c) isize {
    const conn = rawConn(conn_raw);
    const dest = (out orelse return -1)[0..cap];
    const got = conn.connection.read(dest) catch |err| return if (err == error.EndOfStream) 0 else -1;
    return @intCast(got);
}

fn providerWriteAll(_: ?*anyopaque, conn_raw: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) i32 {
    const conn = rawConn(conn_raw);
    conn.connection.writeAll((bytes orelse return PANCAKE_ERR_NULL_POINTER)[0..len]) catch return PANCAKE_ERR_IO;
    return PANCAKE_OK;
}

fn providerConnClose(_: ?*anyopaque, conn_raw: ?*anyopaque) callconv(.c) void {
    const conn = rawConn(conn_raw);
    const owner = conn.owner;
    conn.connection.close();
    owner.allocator.destroy(conn);
}

/// Create a netlayer handle allocating through the library-owned allocator.
/// Release it with `pancake_tcp_netlayer_release` after closing every endpoint
/// made from it.
pub export fn pancake_tcp_netlayer_new(out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    clearLastError();
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, slot);
}

/// Create a netlayer handle whose backend, endpoints, and per-connection buffers
/// all allocate through `context`. Released with `pancake_tcp_netlayer_release`.
pub export fn pancake_tcp_netlayer_new_in(context: ?*PancakeContext, out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    clearLastError();
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), slot);
}

fn netlayerNewIn(alloc: std.mem.Allocator, slot: *?*PancakeTcpNetlayer) i32 {
    const payload = alloc.create(TcpNetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.threaded = std.Io.Threaded.init(alloc, .{});
    payload.allocator = alloc;
    payload.references = .init(1);
    payload.calls = .{};
    payload.tasks.init(payload.io()) catch {
        payload.threaded.deinit();
        alloc.destroy(payload);
        return PANCAKE_ERR_INTERNAL;
    };
    payload.initProvider();
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Borrow this TCP runtime's complete provider package: plain TCP, keyed TCP,
/// and Noise-sealed TCP. The returned table is copied; its callback contexts
/// borrow `netlayer`, which must outlive the driver registration.
pub export fn pancake_tcp_transport_provider(
    netlayer: ?*PancakeTcpNetlayer,
    out_provider: ?*c.PancakeTransportProvider,
) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_provider orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.provider;
    return PANCAKE_OK;
}

/// Seal connect admission and request cancellation of a connect already in
/// progress. Idempotent; release joins the operation before freeing the backend.
pub export fn pancake_tcp_netlayer_shutdown(netlayer: ?*PancakeTcpNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    _ = payload.calls.beginShutdown(payload.io());
    payload.tasks.shutdown();
}

pub export fn pancake_tcp_netlayer_release(netlayer: ?*PancakeTcpNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    payload.release();
}

const TcpConnPayload = struct {
    stream: net.FrameStream,
    operations: c.ForeignCallBarrier,
    directions: c.ConnDirectionGates,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const TcpListenerPayload = struct {
    listener: net.tcp.plain.Listener,
    operations: c.ForeignCallBarrier,
    io: std.Io,
    allocator: std.mem.Allocator,
};

// The shared buffer/payload lifecycle (`c_abi_shared.ConnLifecycle`): allocate
// with `begin`, release a never-installed payload with `abort`, an established
// one with `destroy`. Buffer caps are the shared leaf's
// `connection_read_buf_bytes` / `connection_write_buf_bytes`. Frame read/write
// choreography is `ConnFrameOps` below — this archive keeps the `export fn`s.
const conn_lifecycle = c.ConnLifecycle(TcpConnPayload);
const beginConn = conn_lifecycle.begin;
const abortConn = conn_lifecycle.abort;
const destroyConn = conn_lifecycle.destroy;
const conn_frame_ops = c.ConnFrameOps(TcpConnPayload);

const ConnectJob = struct {
    netlayer: *TcpNetlayerPayload,
    payload: *TcpConnPayload,
    address: std.Io.net.IpAddress,
    codec: u32,
    max_frame_bytes: usize,
    err: ?std.Io.net.IpAddress.ConnectError = null,
    done: net.OperationLatch = .{},

    fn run(job: *ConnectJob) std.Io.Cancelable!void {
        defer job.done.signal(job.netlayer.io());
        job.payload.stream = net.tcp.plain.connectFrameStream(
            job.netlayer.io(),
            job.netlayer.allocator,
            job.address,
            codecFromC(job.codec).?,
            job.max_frame_bytes,
            job.payload.read_buf,
            job.payload.write_buf,
            .{},
        ) catch |err| {
            job.err = err;
            return;
        };
    }
};

/// Connect to `host:port` and return an owned connection handle framing on
/// `codec`. Blocking. Runs on `netlayer`'s I/O backend.
pub export fn pancake_tcp_connect(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    clearLastError();
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.io())) return PANCAKE_ERR_CLOSED;
    defer nl.calls.release(nl.io());
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;
    _ = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    var job: ConnectJob = .{
        .netlayer = nl,
        .payload = payload,
        .address = address,
        .codec = codec,
        .max_frame_bytes = max_frame_bytes,
    };
    nl.tasks.start(ConnectJob.run, .{&job}) catch {
        abortConn(payload);
        setLastError("connect: TCP netlayer is closing or cannot schedule I/O", .{});
        return PANCAKE_ERR_IO;
    };
    job.done.wait(nl.io());
    if (job.err) |err| {
        abortConn(payload);
        setLastError("connect: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    }
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_tcp_connect_with_diagnostic(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    const len = out_error_len orelse {
        clearLastError();
        return PANCAKE_ERR_NULL_POINTER;
    };
    return c.captureCallError(
        pancake_tcp_connect(netlayer, host, host_len, port, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        len,
    );
}

/// Bind + listen on `host:port` (port 0 = OS-chosen). Returns an owned listener
/// handle. Runs on `netlayer`'s I/O backend.
pub export fn pancake_tcp_listen(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    out_listener: ?*?*PancakeTcpListener,
) i32 {
    clearLastError();
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.io())) return PANCAKE_ERR_CLOSED;
    defer nl.calls.release(nl.io());
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("listen: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = nl.allocator.create(TcpListenerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .listener = net.tcp.plain.Listener.bind(nl.io(), address) catch |err| {
            nl.allocator.destroy(payload);
            setLastError("listen: {s}", .{@errorName(err)});
            return PANCAKE_ERR_IO;
        },
        .operations = .{},
        .io = nl.io(),
        .allocator = nl.allocator,
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// The OS-resolved local port of a listener (useful after binding to port 0).
pub export fn pancake_tcp_listener_port(listener: ?*PancakeTcpListener, out_port: ?*u16) i32 {
    clearLastError();
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!payload.operations.acquire(payload.io)) return PANCAKE_ERR_CLOSED;
    defer payload.operations.release(payload.io);
    const slot = out_port orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.listener.localAddress().getPort();
    return PANCAKE_OK;
}

/// Return the listener's borrowed readiness descriptor. An embedder parks its
/// reactor on this fd and calls `pancake_tcp_accept` after it is readable.
/// Readiness is advisory: another accept consumer or a close can spend it first,
/// so serialize consumers when the reactor must not park. The listener owns the
/// fd; do not close it or use it after `pancake_tcp_listener_release`.
pub export fn pancake_tcp_listener_readiness_fd(listener: ?*PancakeTcpListener, out_fd: ?*i32) i32 {
    clearLastError();
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!payload.operations.acquire(payload.io)) return PANCAKE_ERR_CLOSED;
    defer payload.operations.release(payload.io);
    const slot = out_fd orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = @intCast(payload.listener.readinessFd());
    return PANCAKE_OK;
}

/// Block until a client connects, returning an owned connection handle framing
/// on `codec`.
pub export fn pancake_tcp_accept(
    listener: ?*PancakeTcpListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    clearLastError();
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return PANCAKE_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = lpayload.listener.acceptFrameStream(lpayload.allocator, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf, .{}) catch |err| {
        abortConn(payload);
        setLastError("accept: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_tcp_accept_with_diagnostic(
    listener: ?*PancakeTcpListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    const len = out_error_len orelse {
        clearLastError();
        return PANCAKE_ERR_NULL_POINTER;
    };
    return c.captureCallError(
        pancake_tcp_accept(listener, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        len,
    );
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame` (the caller releases it after feeding its bytes to a Host
/// session). Returns `_CLOSED` on graceful EOF, `_IO` on a
/// socket fault (see `pancake_tcp_last_error`), `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
pub export fn pancake_tcp_conn_read_frame(conn: ?*PancakeTcpConn, out_frame: ?*PancakeManagedFrame) i32 {
    clearLastError();
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.readFrame(payload, slot, onReadConnectionLost);
}

pub export fn pancake_tcp_conn_read_frame_with_diagnostic(
    conn: ?*PancakeTcpConn,
    out_frame: ?*PancakeManagedFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    const len = out_error_len orelse {
        clearLastError();
        return PANCAKE_ERR_NULL_POINTER;
    };
    return c.captureCallError(
        pancake_tcp_conn_read_frame(conn, out_frame),
        out_error,
        error_cap,
        len,
    );
}

/// Write one frame's *borrowed* bytes and flush. Returns `_IO` on a socket fault.
pub export fn pancake_tcp_conn_write_frame(conn: ?*PancakeTcpConn, frame_in: ?*const PancakeFrame) i32 {
    clearLastError();
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.writeFrame(payload, borrowed, onWriteErr);
}

pub export fn pancake_tcp_conn_write_frame_with_diagnostic(
    conn: ?*PancakeTcpConn,
    frame_in: ?*const PancakeFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    const len = out_error_len orelse {
        clearLastError();
        return PANCAKE_ERR_NULL_POINTER;
    };
    return c.captureCallError(
        pancake_tcp_conn_write_frame(conn, frame_in),
        out_error,
        error_cap,
        len,
    );
}

/// Interrupt blocked reads and writes and seal new operation admission without
/// freeing the connection. Release joins every admitted operation.
pub export fn pancake_tcp_conn_shutdown(conn: ?*PancakeTcpConn) void {
    const payload = connFromOpaque(conn) orelse return;
    conn_lifecycle.shutdown(payload);
}

pub export fn pancake_tcp_conn_release(conn: ?*PancakeTcpConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

/// Interrupt a blocked accept without freeing the listener. Release joins any
/// accept that was already admitted.
pub export fn pancake_tcp_listener_shutdown(listener: ?*PancakeTcpListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    if (payload.operations.beginShutdown(payload.io)) payload.listener.shutdown();
}

pub export fn pancake_tcp_listener_release(listener: ?*PancakeTcpListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    pancake_tcp_listener_shutdown(listener);
    payload.operations.wait(payload.io);
    const alloc = payload.allocator;
    payload.listener.deinit();
    alloc.destroy(payload);
}

fn onReadConnectionLost(payload: *TcpConnPayload) void {
    if (payload.stream.lastReadError()) |cause| {
        setLastError("read_frame: {s}", .{@errorName(cause)});
    } else {
        setLastError("read_frame: connection lost", .{});
    }
}

fn onWriteErr(payload: *TcpConnPayload, err: anyerror) void {
    if (payload.stream.lastWriteError()) |cause| {
        setLastError("write_frame: {s}", .{@errorName(cause)});
    } else {
        setLastError("write_frame: {s}", .{@errorName(err)});
    }
}

fn netlayerFromOpaque(netlayer: ?*PancakeTcpNetlayer) ?*TcpNetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*PancakeTcpConn) ?*TcpConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn listenerFromOpaque(listener: ?*PancakeTcpListener) ?*TcpListenerPayload {
    const ptr = listener orelse return null;
    return @ptrCast(@alignCast(ptr));
}
