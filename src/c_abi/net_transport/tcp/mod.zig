//! The TCP transport's public C ABI — `libpancake_net_transport_tcp`.
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
//! transport) and reuses the shared types by layout, exactly as a C program
//! including `pancake_ocapn.h` and `pancake_net_transport_tcp.h` does. The transport
//! carries its own per-thread last-error slot, read through
//! `pancake_tcp_last_error`.

const std = @import("std");

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

    /// `Threaded.io()` captures `&self.threaded`, so the payload must be
    /// heap-pinned for the borrowed `Io` to stay valid. `create` gives it that
    /// stable address.
    fn io(self: *TcpNetlayerPayload) std.Io {
        return self.threaded.io();
    }
};

/// Create a netlayer handle allocating through the library-owned allocator.
/// Release it with `pancake_tcp_netlayer_release` after closing every endpoint
/// made from it.
pub export fn pancake_tcp_netlayer_new(out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, slot);
}

/// Create a netlayer handle whose backend, endpoints, and per-connection buffers
/// all allocate through `context`. Released with `pancake_tcp_netlayer_release`.
pub export fn pancake_tcp_netlayer_new_in(context: ?*PancakeContext, out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), slot);
}

fn netlayerNewIn(alloc: std.mem.Allocator, slot: *?*PancakeTcpNetlayer) i32 {
    const payload = alloc.create(TcpNetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{ .threaded = std.Io.Threaded.init(alloc, .{}), .allocator = alloc };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_tcp_netlayer_release(netlayer: ?*PancakeTcpNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    const alloc = payload.allocator;
    payload.threaded.deinit();
    alloc.destroy(payload);
}

const TcpConnPayload = struct {
    stream: net.FrameStream,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const TcpListenerPayload = struct {
    listener: net.tcp.Listener,
    allocator: std.mem.Allocator,
};

// The shared buffer/payload lifecycle (`c_abi_shared.ConnLifecycle`): allocate
// with `begin`, release a never-installed payload with `abort`, an established
// one with `destroy`. Buffer caps are the shared leaf's
// `endpoint_read_buf_bytes` / `endpoint_write_buf_bytes`. Frame read/write
// choreography is `ConnFrameOps` below — this archive keeps the `export fn`s.
const conn_lifecycle = c.ConnLifecycle(TcpConnPayload);
const beginConn = conn_lifecycle.begin;
const abortConn = conn_lifecycle.abort;
const destroyConn = conn_lifecycle.destroy;
const conn_frame_ops = c.ConnFrameOps(TcpConnPayload);

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
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = net.tcp.connectFrameStream(nl.io(), nl.allocator, address, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf, .{}) catch |err| {
        abortConn(payload);
        setLastError("connect: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
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
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("listen: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = nl.allocator.create(TcpListenerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .listener = net.tcp.Listener.bind(nl.io(), address) catch |err| {
            nl.allocator.destroy(payload);
            setLastError("listen: {s}", .{@errorName(err)});
            return PANCAKE_ERR_IO;
        },
        .allocator = nl.allocator,
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// The OS-resolved local port of a listener (useful after binding to port 0).
pub export fn pancake_tcp_listener_port(listener: ?*PancakeTcpListener, out_port: ?*u16) i32 {
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_port orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.listener.localAddress().getPort();
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
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
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

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame` (the caller releases it after feeding its bytes to a Host
/// session). Returns `_CLOSED` on graceful EOF, `_IO` on a
/// socket fault (see `pancake_tcp_last_error`), `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
pub export fn pancake_tcp_conn_read_frame(conn: ?*PancakeTcpConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.readFrame(payload, slot, onReadConnectionLost);
}

/// Write one frame's *borrowed* bytes and flush. Returns `_IO` on a socket fault.
pub export fn pancake_tcp_conn_write_frame(conn: ?*PancakeTcpConn, frame_in: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    return conn_frame_ops.writeFrame(payload, borrowed, onWriteErr);
}

pub export fn pancake_tcp_conn_release(conn: ?*PancakeTcpConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

pub export fn pancake_tcp_listener_release(listener: ?*PancakeTcpListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
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
