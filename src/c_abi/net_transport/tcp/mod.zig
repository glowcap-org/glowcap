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

const net = @import("net");
const runtime = @import("runtime.zig");

// The shared C-ABI vocabulary leaf — types, codes, allocation policy,
// managed-frame machinery, and the per-thread last-error slot — *not* the ocapn
// root. Importing the leaf gives this transport ABI the same frame and context
// types `pancake_ocapn.h` declares, with its own compiled copy of the helpers
// and last-error slot, and pulls *none* of the ocapn archive's exported surface
// (ADR-0059 companion split, generalized from the iroh companion).
const c = @import("c_abi_shared");

/// Exact callable-surface identity checked before a separately loaded TCP
/// archive receives any arguments. Derived from this archive and the shared
/// provider ABI; never hand-bumped.
pub const PANCAKE_TCP_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprintParts(
    &.{ @embedFile("mod.zig"), @embedFile("runtime.zig") },
    @embedFile("symbols.zig"),
);

pub export fn pancake_tcp_archive_fingerprint() u64 {
    return PANCAKE_TCP_ARCHIVE_FINGERPRINT;
}

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
/// Per-stream TCP policy. All-zero disables keepalive; otherwise all three
/// fields must be positive. A null operation pointer inherits the provider
/// default, while an explicit all-zero value overrides it off.
pub const PancakeTcpStreamOptions = runtime.PancakeTcpStreamOptions;
/// Defaults inherited by every connection this netlayer dials or accepts.
pub const PancakeTcpConfig = extern struct {
    stream: PancakeTcpStreamOptions,
};
/// Provider-owned payload for one generic driver dial or listener operation.
/// Omit the common envelope to inherit `PancakeTcpConfig`; supplying this value
/// overrides the stream settings, including an explicit all-zero disable.
pub const PancakeTcpOperationOptions = runtime.PancakeTcpOperationOptions;
const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;

const setLastError = c.setLastError;
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
const TcpNetlayerPayload = runtime.TcpNetlayerPayload;
const streamOptionsFromC = runtime.streamOptionsFromC;
const operationStreamOptions = runtime.operationStreamOptions;

/// Create a netlayer handle allocating through the library-owned allocator.
/// Release it with `pancake_tcp_netlayer_release` after closing every endpoint
/// made from it.
pub export fn pancake_tcp_netlayer_new(
    config: ?*const PancakeTcpConfig,
    out_netlayer: ?*?*PancakeTcpNetlayer,
) i32 {
    c.lastErrorClear();
    const stream_options = streamOptionsFromC((config orelse return PANCAKE_ERR_NULL_POINTER).stream, "tcp netlayer_new") catch
        return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, stream_options, slot);
}

/// Create a netlayer handle whose backend, endpoints, and per-connection buffers
/// all allocate through `context`. Released with `pancake_tcp_netlayer_release`.
pub export fn pancake_tcp_netlayer_new_in(
    context: ?*PancakeContext,
    config: ?*const PancakeTcpConfig,
    out_netlayer: ?*?*PancakeTcpNetlayer,
) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const stream_options = streamOptionsFromC((config orelse return PANCAKE_ERR_NULL_POINTER).stream, "tcp netlayer_new_in") catch
        return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), stream_options, slot);
}

fn netlayerNewIn(
    alloc: std.mem.Allocator,
    stream_options: net.tcp.StreamOptions,
    slot: *?*PancakeTcpNetlayer,
) i32 {
    const payload = alloc.create(TcpNetlayerPayload) catch |err|
        return c.failInternal("tcp netlayer_new", err);
    payload.threaded = std.Io.Threaded.init(alloc, .{});
    payload.allocator = alloc;
    payload.references = .init(1);
    payload.calls = .{};
    payload.stream_options = stream_options;
    payload.tasks.init(payload.io()) catch |err| {
        payload.threaded.deinit();
        alloc.destroy(payload);
        return c.failInternal("tcp netlayer_new scheduler", err);
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
    c.lastErrorClear();
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
    stream_options: net.tcp.StreamOptions,
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
    stream_options: net.tcp.StreamOptions,
    codec: u32,
    max_frame_bytes: usize,
    err: ?(std.Io.net.IpAddress.ConnectError || net.socket.ConfigurationError) = null,
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
            job.stream_options,
        ) catch |err| {
            job.err = err;
            return;
        };
    }
};

/// Connect to `host:port` and return an owned connection handle framing on
/// `codec`. Blocking. Runs on `netlayer`'s I/O backend.
fn tcpConnect(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    options: ?*const PancakeTcpStreamOptions,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.io())) return PANCAKE_ERR_CLOSED;
    defer nl.calls.release(nl.io());
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;
    const stream_options = operationStreamOptions(nl.stream_options, options) catch |err| {
        setLastError("tcp connect: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    _ = c.framingOptionsFromC(codec, max_frame_bytes, "tcp connect") catch
        return PANCAKE_ERR_INVALID_ARGUMENT;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse
        return c.failInternal("tcp connect", error.OutOfMemory);
    var job: ConnectJob = .{
        .netlayer = nl,
        .payload = payload,
        .address = address,
        .stream_options = stream_options,
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

/// Connect and optionally copy this call's diagnostic into caller-owned
/// storage before an off-thread runtime regains control.
pub export fn pancake_tcp_connect(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    options: ?*const PancakeTcpStreamOptions,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        tcpConnect(netlayer, host, host_len, port, options, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
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
    c.lastErrorClear();
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.io())) return PANCAKE_ERR_CLOSED;
    defer nl.calls.release(nl.io());
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("listen: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = nl.allocator.create(TcpListenerPayload) catch |err|
        return c.failInternal("tcp listen", err);
    payload.* = .{
        .listener = net.tcp.plain.Listener.bind(nl.io(), address) catch |err| {
            nl.allocator.destroy(payload);
            setLastError("listen: {s}", .{@errorName(err)});
            return PANCAKE_ERR_IO;
        },
        .operations = .{},
        .io = nl.io(),
        .stream_options = nl.stream_options,
        .allocator = nl.allocator,
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// The OS-resolved local port of a listener (useful after binding to port 0).
pub export fn pancake_tcp_listener_port(listener: ?*PancakeTcpListener, out_port: ?*u16) i32 {
    c.lastErrorClear();
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
    c.lastErrorClear();
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!payload.operations.acquire(payload.io)) return PANCAKE_ERR_CLOSED;
    defer payload.operations.release(payload.io);
    const slot = out_fd orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = @intCast(payload.listener.readinessFd());
    return PANCAKE_OK;
}

/// Block until a client connects, returning an owned connection handle framing
/// on `codec`.
fn tcpAccept(
    listener: ?*PancakeTcpListener,
    options: ?*const PancakeTcpStreamOptions,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return PANCAKE_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const stream_options = operationStreamOptions(lpayload.stream_options, options) catch |err| {
        setLastError("tcp accept: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const codec_id = c.framingOptionsFromC(codec, max_frame_bytes, "tcp accept") catch
        return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse
        return c.failInternal("tcp accept", error.OutOfMemory);
    payload.stream = lpayload.listener.acceptFrameStream(lpayload.allocator, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf, stream_options) catch |err| {
        abortConn(payload);
        setLastError("accept: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Accept and optionally copy this call's diagnostic into caller-owned
/// storage before an off-thread runtime regains control.
pub export fn pancake_tcp_accept(
    listener: ?*PancakeTcpListener,
    options: ?*const PancakeTcpStreamOptions,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        tcpAccept(listener, options, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame` (the caller releases it after feeding its bytes to a Host
/// session). Returns `_CLOSED` on graceful EOF, `_IO` on a
/// socket fault (see `pancake_tcp_last_error`), `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
fn tcpConnReadFrame(conn: ?*PancakeTcpConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.readFrame(payload, slot, onReadConnectionLost);
}

/// Read and optionally copy this call's diagnostic into caller-owned storage.
pub export fn pancake_tcp_conn_read_frame(
    conn: ?*PancakeTcpConn,
    out_frame: ?*PancakeManagedFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        tcpConnReadFrame(conn, out_frame),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Write one frame's *borrowed* bytes and flush. Returns `_IO` on a socket fault.
fn tcpConnWriteFrame(conn: ?*PancakeTcpConn, frame_in: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.writeFrame(payload, borrowed, onWriteErr);
}

/// Write and optionally copy this call's diagnostic into caller-owned storage.
pub export fn pancake_tcp_conn_write_frame(
    conn: ?*PancakeTcpConn,
    frame_in: ?*const PancakeFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        tcpConnWriteFrame(conn, frame_in),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Interrupt blocked reads and writes and seal new operation admission without
/// freeing the connection. Release joins every admitted operation.
pub export fn pancake_tcp_conn_shutdown(conn: ?*PancakeTcpConn) i32 {
    c.lastErrorClear();
    const payload = connFromOpaque(conn) orelse return PANCAKE_OK;
    conn_lifecycle.shutdown(payload) catch |err| return c.failIo("tcp connection shutdown", err);
    return PANCAKE_OK;
}

fn tcpConnRelease(conn: ?*PancakeTcpConn) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_OK;
    destroyConn(payload) catch |err| return c.failIo("tcp connection release", err);
    return PANCAKE_OK;
}

pub export fn pancake_tcp_conn_release(
    conn: ?*PancakeTcpConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return PANCAKE_ERR_NULL_POINTER;
    }
    return c.captureCallError(tcpConnRelease(conn), out_error, error_cap, out_error_len);
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
