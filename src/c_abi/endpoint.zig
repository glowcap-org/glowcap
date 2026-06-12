//! Blocking TCP endpoint handles.
//!
//! This is the host-driven netlayer boundary for C. The C host owns the peer. It
//! reads a whole frame, feeds that owned frame to the peer, steps the peer, takes
//! outbound frames, and writes them back to the connection. The C side cannot
//! name a Zig `Io`, so the backend is an explicit owned handle:
//! `PancakeTcpNetlayer` owns one `std.Io.Threaded`. Endpoints created from it
//! borrow that backend and must be closed before it is released. This transport is
//! blocking, cleartext TCP; there is no TLS. Production transports — TCP and
//! the iroh sidecar — layer above the same `net_adapter` types.

const std = @import("std");

const model = @import("model");
const net_adapter = @import("net_adapter");

const c = @import("mod.zig");
const ctx = @import("context.zig");
const frame = @import("frame.zig");

const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;
const PancakeTcpNetlayer = c.PancakeTcpNetlayer;
const PancakeTcpConn = c.PancakeTcpConn;
const PancakeTcpListener = c.PancakeTcpListener;

const setLastError = c.setLastError;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_MALFORMED = c.PANCAKE_ERR_MALFORMED;
const PANCAKE_ERR_FRAME_TOO_LARGE = c.PANCAKE_ERR_FRAME_TOO_LARGE;

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
    return netlayerNewIn(ctx.library_allocator, slot);
}

/// Create a netlayer handle whose backend, endpoints, and per-connection buffers
/// all allocate through `context`. Released with `pancake_tcp_netlayer_release`.
pub export fn pancake_tcp_netlayer_new_in(context: ?*PancakeContext, out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator, slot);
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
    stream: net_adapter.FrameStream,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const TcpListenerPayload = struct {
    listener: net_adapter.tcp.Listener,
    allocator: std.mem.Allocator,
};

const codecFromC = c.codecFromC;

fn destroyConn(payload: *TcpConnPayload) void {
    const alloc = payload.allocator;
    payload.stream.deinit();
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

/// Modest caps on the per-connection buffers. Neither buffer needs to hold a
/// whole frame: `writeAll` streams a large outbound frame straight through the
/// write buffer, and an inbound frame larger than the read buffer accumulates
/// in the connection's bounded spill (`net_adapter.Spill`) while it is in
/// flight. Steady per-connection memory is therefore these two buffers, not
/// `max_frame_bytes`.
const endpoint_read_buf_bytes: usize = 16 * 1024;
const endpoint_write_buf_bytes: usize = 64 * 1024;

/// Allocate a connection payload and its buffers, leaving `.stream` for the
/// caller to install once the socket is established. On any failure before
/// install, release it with `abortConn`. Both endpoint constructors share this
/// so the buffer/payload lifecycle lives in one place.
fn beginConn(alloc: std.mem.Allocator, max_frame_bytes: usize) ?*TcpConnPayload {
    const read_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_read_buf_bytes)) catch return null;
    const write_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_write_buf_bytes)) catch {
        alloc.free(read_buf);
        return null;
    };
    const payload = alloc.create(TcpConnPayload) catch {
        alloc.free(read_buf);
        alloc.free(write_buf);
        return null;
    };
    payload.read_buf = read_buf;
    payload.write_buf = write_buf;
    payload.allocator = alloc;
    return payload;
}

fn abortConn(payload: *TcpConnPayload) void {
    const alloc = payload.allocator;
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

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

    const address = net_adapter.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = net_adapter.tcp.connectFrameStream(nl.io(), nl.allocator, address, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
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

    const address = net_adapter.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("listen: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = nl.allocator.create(TcpListenerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .listener = net_adapter.tcp.Listener.bind(nl.io(), address) catch |err| {
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
    payload.stream = lpayload.listener.acceptFrameStream(lpayload.allocator, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        setLastError("accept: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame` (the caller `release`s it, or hands it to
/// `pancake_peer_feed_owned`). Returns `_CLOSED` on graceful EOF, `_IO` on a
/// socket fault (see `pancake_last_error`), `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
pub export fn pancake_tcp_conn_read_frame(conn: ?*PancakeTcpConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;

    const f = payload.stream.readFrame() catch |err| return frameReadErrorToCode(payload, err);

    slot.* = frame.tryManagedFrame(payload.allocator, f) catch {
        var owned = f;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Write one frame's *borrowed* bytes and flush. Returns `_IO` on a socket fault.
pub export fn pancake_tcp_conn_write_frame(conn: ?*PancakeTcpConn, frame_in: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;

    payload.stream.writeFrame(bytes_ptr[0..borrowed.len]) catch |err| {
        if (payload.stream.lastWriteError()) |cause| {
            setLastError("write_frame: {s}", .{@errorName(cause)});
        } else {
            setLastError("write_frame: {s}", .{@errorName(err)});
        }
        return PANCAKE_ERR_IO;
    };
    return PANCAKE_OK;
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

fn frameReadErrorToCode(payload: *TcpConnPayload, err: net_adapter.FrameError) i32 {
    return switch (err) {
        error.Closed => PANCAKE_ERR_CLOSED,
        error.MalformedFrame => PANCAKE_ERR_MALFORMED,
        error.FrameTooLarge => PANCAKE_ERR_FRAME_TOO_LARGE,
        error.TruncatedFrame => blk: {
            setLastError("read_frame: stream closed mid-frame", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.ConnectionLost => blk: {
            if (payload.stream.lastReadError()) |cause| {
                setLastError("read_frame: {s}", .{@errorName(cause)});
            } else {
                setLastError("read_frame: connection lost", .{});
            }
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
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
