//! Blocking framed-endpoint projection for the onion C archive.
//
// These handles adapt Zig onion streams to the shared managed-frame ABI.
// Tor configuration and the generic provider package have separate owners.

const std = @import("std");
const net = @import("net");
const c = @import("c_abi_shared");
const contract = @import("../contract.zig");
const failure_projection = @import("../failure.zig");
const runtime = @import("../runtime/state.zig");

const GlowcapOnionNetlayer = contract.GlowcapOnionNetlayer;
const GlowcapOnionConn = contract.GlowcapOnionConn;
const GlowcapOnionListener = contract.GlowcapOnionListener;
const GlowcapFrame = c.GlowcapFrame;
const GlowcapManagedFrame = c.GlowcapManagedFrame;

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

const Conn = struct {
    stream: net.FrameStream,
    operations: c.ForeignCallBarrier,
    directions: c.ConnDirectionGates,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const Listener = struct {
    listener: *net.onion.Listener,
    operations: c.ForeignCallBarrier,
    io: std.Io,
    allocator: std.mem.Allocator,
};

const conn_lifecycle = c.ConnLifecycle(Conn);
const beginConn = conn_lifecycle.begin;
const abortConn = conn_lifecycle.abort;
const destroyConn = conn_lifecycle.destroy;
const conn_frame_ops = c.ConnFrameOps(Conn);

const ConnectJob = struct {
    netlayer: *runtime.Netlayer,
    payload: *Conn,
    service_id: []const u8,
    codec: u32,
    max_frame_bytes: usize,
    err: ?net.netlayer.DialError = null,
    done: net.OperationLatch = .{},

    fn run(job: *ConnectJob) std.Io.Cancelable!void {
        defer job.done.signal(job.netlayer.resident.io);
        job.payload.stream = net.onion.resident.dialFrameStream(
            job.netlayer.resident.io,
            job.netlayer.allocator,
            job.netlayer.resident.config.socks,
            job.service_id,
            c.codecFromC(job.codec).?,
            job.max_frame_bytes,
            job.payload.read_buf,
            job.payload.write_buf,
        ) catch |err| {
            job.err = err;
            return;
        };
    }
};

const ListenJob = struct {
    netlayer: *runtime.Netlayer,
    payload: *Listener,
    failure: ?net.netlayer.ListenFailure = null,
    done: net.OperationLatch = .{},

    fn run(job: *ListenJob) std.Io.Cancelable!void {
        defer job.done.signal(job.netlayer.resident.io);
        switch (net.onion.Listener.create(
            job.netlayer.allocator,
            job.netlayer.resident.io,
            job.netlayer.resident.config,
        )) {
            .ready => |listener| job.payload.listener = listener,
            .failed => |failure| job.failure = failure,
        }
    }
};

/// Dial the onion service `service_id` through the configured Tor and return an
/// owned connection handle framing on `codec`.
///
/// `service_id` is the bare version 3 designator, 56 base32 characters with no
/// `.onion` suffix. A designator that is not a well-formed v3 address is refused
/// before any socket opens. Blocking: a Tor circuit takes seconds.
fn onionConnect(
    netlayer: ?*GlowcapOnionNetlayer,
    service_id: ?[*]const u8,
    service_id_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapOnionConn,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.resident.io)) return GLOWCAP_ERR_CLOSED;
    defer nl.calls.release(nl.resident.io);
    const slot = out_conn orelse return GLOWCAP_ERR_NULL_POINTER;
    const id_ptr = service_id orelse return GLOWCAP_ERR_NULL_POINTER;
    _ = c.framingOptionsFromC(codec, max_frame_bytes, "onion connect") catch
        return GLOWCAP_ERR_INVALID_ARGUMENT;

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse
        return c.failInternal("onion connect", error.OutOfMemory);
    var job: ConnectJob = .{
        .netlayer = nl,
        .payload = payload,
        .service_id = id_ptr[0..service_id_len],
        .codec = codec,
        .max_frame_bytes = max_frame_bytes,
    };
    nl.tasks.start(ConnectJob.run, .{&job}) catch {
        abortConn(payload);
        c.setLastError("connect: onion netlayer is closing or cannot schedule Tor I/O", .{});
        return GLOWCAP_ERR_IO;
    };
    job.done.wait(nl.resident.io);
    if (job.err) |err| {
        abortConn(payload);
        return failure_projection.dial(err);
    }
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

pub fn connect(
    netlayer: ?*GlowcapOnionNetlayer,
    service_id: ?[*]const u8,
    service_id_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionConnect(netlayer, service_id, service_id_len, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Ask Tor for an onion service and bind its local end.
///
/// On success `out_service_id` receives the 56-character designator (no NUL) and
/// `out_service_id_len` its length, which is always
/// `GLOWCAP_ONION_SERVICE_ID_LEN`. `out_service_key` receives the key that
/// restores this exact service, or nothing when the service was restored rather
/// than minted. A caller that wants a durable onion address stores those bytes and
/// passes them back as `GlowcapOnionConfig.service_key`.
///
/// Every out-parameter is optional. Requires a configured control endpoint.
/// Blocking: the control conversation is several round trips to the daemon.
fn onionListen(
    netlayer: ?*GlowcapOnionNetlayer,
    out_service_id: ?[*]u8,
    out_service_id_cap: usize,
    out_service_id_len: ?*usize,
    out_service_key: ?[*]u8,
    out_service_key_cap: usize,
    out_service_key_len: ?*usize,
    out_listener: ?*?*GlowcapOnionListener,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.resident.io)) return GLOWCAP_ERR_CLOSED;
    defer nl.calls.release(nl.resident.io);
    const slot = out_listener orelse return GLOWCAP_ERR_NULL_POINTER;

    const payload = nl.allocator.create(Listener) catch |err|
        return c.failInternal("onion listen", err);
    payload.allocator = nl.allocator;
    payload.operations = .{};
    payload.io = nl.resident.io;
    var job: ListenJob = .{
        .netlayer = nl,
        .payload = payload,
    };
    nl.tasks.start(ListenJob.run, .{&job}) catch {
        nl.allocator.destroy(payload);
        c.setLastError("listen: onion netlayer is closing or cannot schedule Tor I/O", .{});
        return GLOWCAP_ERR_IO;
    };
    job.done.wait(nl.resident.io);
    if (job.failure) |failure| {
        nl.allocator.destroy(payload);
        c.setLastErrorChain("onion listen", failure);
        return failure_projection.listen(failure.cause);
    }

    const id = payload.listener.designator();
    if (!copyOut(id, out_service_id, out_service_id_cap, out_service_id_len)) {
        const cleanup = payload.listener.deinit();
        nl.allocator.destroy(payload);
        if (cleanup) |failure| {
            c.setLastError("listen: service id buffer needs {d} bytes; cleanup: {s} ({d} secondary failures)", .{
                id.len,
                @errorName(failure.cause),
                @as(u32, failure.secondary_count) + 1,
            });
        } else c.setLastError("listen: service id buffer needs {d} bytes", .{id.len});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const key = payload.listener.serviceKey();
    if (!copyOut(key, out_service_key, out_service_key_cap, out_service_key_len)) {
        const cleanup = payload.listener.deinit();
        nl.allocator.destroy(payload);
        if (cleanup) |failure| {
            c.setLastError("listen: service key buffer needs {d} bytes; cleanup: {s} ({d} secondary failures)", .{
                key.len,
                @errorName(failure.cause),
                @as(u32, failure.secondary_count) + 1,
            });
        } else c.setLastError("listen: service key buffer needs {d} bytes", .{key.len});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }

    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

pub fn listen(
    netlayer: ?*GlowcapOnionNetlayer,
    out_service_id: ?[*]u8,
    service_id_cap: usize,
    out_service_id_len: ?*usize,
    out_service_key: ?[*]u8,
    service_key_cap: usize,
    out_service_key_len: ?*usize,
    out_listener: ?*?*GlowcapOnionListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionListen(
            netlayer,
            out_service_id,
            service_id_cap,
            out_service_id_len,
            out_service_key,
            service_key_cap,
            out_service_key_len,
            out_listener,
        ),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Write `bytes` into an optional out-parameter pair. False when the buffer was
/// supplied but is too small, which is a caller error rather than a fault.
fn copyOut(bytes: []const u8, out: ?[*]u8, cap: usize, out_len: ?*usize) bool {
    if (out) |dest| {
        if (cap < bytes.len) return false;
        @memcpy(dest[0..bytes.len], bytes);
    }
    if (out_len) |slot| slot.* = bytes.len;
    return true;
}

/// Block until Tor forwards a circuit to this service, returning an owned
/// connection handle framing on `codec`.
///
/// The partner's claimed location is unverified on this side: Tor tells a hidden
/// service nothing about who dialed it. ADR-0042 records that, and the pinned
/// Goblins has the identical gap.
fn onionAccept(
    listener: ?*GlowcapOnionListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapOnionConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return GLOWCAP_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_conn orelse return GLOWCAP_ERR_NULL_POINTER;
    const codec_id = c.framingOptionsFromC(codec, max_frame_bytes, "onion accept") catch
        return GLOWCAP_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse
        return c.failInternal("onion accept", error.OutOfMemory);
    payload.stream = lpayload.listener.acceptFrameStream(
        lpayload.allocator,
        codec_id,
        max_frame_bytes,
        payload.read_buf,
        payload.write_buf,
    ) catch |err| {
        abortConn(payload);
        return failure_projection.accept(err);
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

pub fn accept(
    listener: ?*GlowcapOnionListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionAccept(listener, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Wait until `glowcap_onion_accept` would make progress, up to `timeout_ms`.
/// Writes 1 into `out_ready` when the next accept should proceed and 0 on
/// timeout. The one poll guard that lets a blocking host exit its accept loop
/// without closing the listener from another thread.
///
/// The flag is a `u32` rather than a C `bool` because every other integer in this
/// family is fixed-width, and `_Bool` is the one type whose width a caller has to
/// look up.
fn onionListenerWait(
    listener: ?*GlowcapOnionListener,
    timeout_ms: i32,
    out_ready: ?*u32,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return GLOWCAP_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_ready orelse return GLOWCAP_ERR_NULL_POINTER;
    const ready = lpayload.listener.waitAcceptable(timeout_ms) catch |err| {
        c.setLastError("listener_wait: {s}", .{@errorName(err)});
        return GLOWCAP_ERR_IO;
    };
    slot.* = @intFromBool(ready);
    return GLOWCAP_OK;
}

pub fn listenerWait(
    listener: ?*GlowcapOnionListener,
    timeout_ms: i32,
    out_ready: ?*u32,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionListenerWait(listener, timeout_ms, out_ready),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Hand back the descriptor this listener's circuits arrive on, so an embedder can
/// poll instead of blocking.
///
/// This is the readiness half of the surface, the same posture the iroh and WebRTC
/// archives take. Park on this descriptor with whatever your loop uses and call
/// `glowcap_onion_accept` once it is readable. Readiness means an accept can make
/// progress. It is not a nonblocking guarantee, because another accept consumer or
/// a close can consume that state first. Serialize accept consumers when a loop
/// must not park. An onion service's forward target is an ordinary local socket,
/// which is why this can be a real descriptor rather than a synthesized readiness
/// fd.
///
/// The descriptor is owned by the listener. Do not close it, and do not use it
/// after `glowcap_onion_listener_release`.
pub fn listenerReadinessFd(
    listener: ?*GlowcapOnionListener,
    out_fd: ?*i32,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return GLOWCAP_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_fd orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = @intCast(lpayload.listener.readinessFd());
    return GLOWCAP_OK;
}

/// Hand back the descriptor this connection's bytes flow over, so an embedder can
/// poll instead of blocking.
///
/// Same contract as `glowcap_onion_listener_readiness_fd`: poll it, and call
/// `glowcap_onion_conn_read_frame` only when it is readable. A whole frame may
/// still need more than one readable turn, in which case the read parks for the
/// remainder: the descriptor makes the common case free, not every case.
///
/// The descriptor is owned by the connection. Do not close it, and do not use it
/// after `glowcap_onion_conn_release`.
pub fn connReadinessFd(conn: ?*GlowcapOnionConn, out_fd: ?*i32) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_fd orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!payload.operations.acquire(payload.stream.io)) return GLOWCAP_ERR_CLOSED;
    defer payload.operations.release(payload.stream.io);
    slot.* = @intCast(payload.stream.reader.stream.socket.handle);
    return GLOWCAP_OK;
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame`. `_CLOSED` on graceful EOF, `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
///
/// Prefer polling `glowcap_onion_conn_readiness_fd` first. This blocks when nothing
/// has arrived.
fn onionConnReadFrame(conn: ?*GlowcapOnionConn, out_frame: ?*GlowcapManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_frame orelse return GLOWCAP_ERR_NULL_POINTER;
    return conn_frame_ops.readFrame(payload, slot, onReadConnectionLost);
}

pub fn connReadFrame(
    conn: ?*GlowcapOnionConn,
    out_frame: ?*GlowcapManagedFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionConnReadFrame(conn, out_frame),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Write one frame's *borrowed* bytes to the partner.
fn onionConnWriteFrame(conn: ?*GlowcapOnionConn, frame_in: ?*const GlowcapFrame) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return GLOWCAP_ERR_NULL_POINTER;
    return conn_frame_ops.writeFrame(payload, borrowed, onWriteErr);
}

pub fn connWriteFrame(
    conn: ?*GlowcapOnionConn,
    frame_in: ?*const GlowcapFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionConnWriteFrame(conn, frame_in),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Interrupt a blocked connection read or write without freeing `conn`.
///
/// This is the cancellation half for runtimes that dispatch a blocking C call
/// to another OS thread. Stop new calls, use shutdown to wake admitted work,
/// join the runtime's operation leases, and only then release the handle.
pub fn connShutdown(conn: ?*GlowcapOnionConn) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_OK;
    conn_lifecycle.shutdown(payload) catch |err| return c.failIo("onion connection shutdown", err);
    return GLOWCAP_OK;
}

fn onionConnRelease(conn: ?*GlowcapOnionConn) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_OK;
    destroyConn(payload) catch |err| return c.failIo("onion connection release", err);
    return GLOWCAP_OK;
}

pub fn connRelease(
    conn: ?*GlowcapOnionConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(onionConnRelease(conn), out_error, error_cap, out_error_len);
}

/// Interrupt a blocked accept without freeing `listener` or withdrawing its
/// service. Release joins every accept already admitted. Idempotent: its wake
/// channel is pre-opened with the listener and cannot fail at shutdown time.
pub fn listenerShutdown(listener: ?*GlowcapOnionListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    if (payload.operations.beginShutdown(payload.io)) payload.listener.shutdown();
}

/// Withdraw the service and release the listener. This is the only release in the
/// family with an effect on shared state: the service stops being published, so a
/// partner dialing that address afterwards finds nothing.
fn onionListenerRelease(listener: ?*GlowcapOnionListener) i32 {
    const payload = listenerFromOpaque(listener) orelse return GLOWCAP_OK;
    listenerShutdown(listener);
    payload.operations.wait(payload.io);
    const alloc = payload.allocator;
    const failure = payload.listener.deinit();
    alloc.destroy(payload);
    if (failure) |chain| {
        c.setLastErrorChain("onion listener release", chain);
        return failure_projection.listen(chain.cause);
    }
    return GLOWCAP_OK;
}

pub fn listenerRelease(
    listener: ?*GlowcapOnionListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        onionListenerRelease(listener),
        out_error,
        error_cap,
        out_error_len,
    );
}

fn onReadConnectionLost(_: *Conn) void {
    c.setLastError("read_frame: onion stream failed", .{});
}

fn onWriteErr(_: *Conn, err: anyerror) void {
    c.setLastError("write_frame: {s}", .{@errorName(err)});
}

fn netlayerFromOpaque(netlayer: ?*GlowcapOnionNetlayer) ?*runtime.Netlayer {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*GlowcapOnionConn) ?*Conn {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn listenerFromOpaque(listener: ?*GlowcapOnionListener) ?*Listener {
    const ptr = listener orelse return null;
    return @ptrCast(@alignCast(ptr));
}
