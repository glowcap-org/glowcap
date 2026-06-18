//! The in-process transport's public C ABI — `libpancake_net_transport_inproc`.
//!
//! The socket-free sibling of the TCP transport (`src/c_abi/net_transport/tcp/`): the same
//! host-driven netlayer boundary, but the two peers run in one process with no
//! kernel transport and no file descriptors. A `PancakeInprocNetlayer` is a
//! switchboard (`net.inproc.Network`) plus the one `std.Io` backend its pipes
//! block on; a listener binds to a *string designator* (not host:port) and a
//! dialer names that designator. This is what a binding's smoke test dials so a
//! full OCapN conversation runs in-process without touching a socket — the path
//! that dodges socket-sandbox limits entirely.
//!
//! Frame movement is identical to TCP's: read a whole owned frame, feed it to the
//! host's peer, step, take outbound, write it back. Only the addressing and the
//! transport behind the `FrameStream` differ, so the C host's loop is unchanged.
//!
//! This is a *separate archive* from `libpancake_ocapn` (ADR-0059): it imports
//! only the shared vocabulary leaf (`@import("c_abi_shared")`), so it exports
//! just the `pancake_inproc_*` family and shares no core symbol with the ocapn
//! archive. The transport carries its own per-thread last-error slot, read
//! through `pancake_inproc_last_error`.

const std = @import("std");

const net = @import("net");

// The shared C-ABI vocabulary leaf — *not* the ocapn root. Importing the leaf
// gives this transport ABI the same frame and context types
// `pancake_ocapn.h` declares, with its own compiled copy of the helpers and
// last-error slot, and pulls *none* of the ocapn archive's exported surface
// (ADR-0059 companion split).
const c = @import("c_abi_shared");

/// The netlayer handle owns the in-process switchboard and the one `std.Io`
/// backend its pipes block on. Created and released explicitly by the host; it
/// must outlive every connection and listener made from it.
pub const PancakeInprocNetlayer = opaque {};
/// One in-process connection carrying one OCapN session. Owned by the caller;
/// released with `pancake_inproc_conn_release`.
pub const PancakeInprocConn = opaque {};
/// A bound in-process listener. Owned by the caller; released with
/// `pancake_inproc_listener_release`.
pub const PancakeInprocListener = opaque {};

const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;

const setLastError = c.setLastError;
const codecFromC = c.codecFromC;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_MALFORMED = c.PANCAKE_ERR_MALFORMED;
const PANCAKE_ERR_FRAME_TOO_LARGE = c.PANCAKE_ERR_FRAME_TOO_LARGE;

/// Copy the calling thread's last inproc-transport error message into `out_buf`,
/// the inproc sibling of `pancake_last_error`. `libpancake_net_transport_inproc`
/// carries its own per-thread slot (a separate compiled copy of the shared
/// leaf's slot), so a `pancake_inproc_*` call that returns a cause-bearing code
/// records it here, readable independently of the ocapn archive's. Copies at
/// most `cap - 1` bytes and always NUL-terminates when `cap > 0`;
/// `out_buf == NULL` or `cap == 0` queries the length. Returns the full message
/// length, or 0 when none is set.
pub export fn pancake_inproc_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's inproc-transport last error slot.
pub export fn pancake_inproc_clear_last_error() void {
    c.lastErrorClear();
}

/// The netlayer handle owns the in-process switchboard and the one `std.Io`
/// backend its pipes block on. Created and released explicitly by the host; it
/// must outlive every connection and listener made from it. `Network` captures
/// `&self.threaded` via `io()`, so the payload is heap-pinned for that borrow to
/// stay valid (`create` gives it a stable address).
const InprocNetlayerPayload = struct {
    threaded: std.Io.Threaded,
    network: net.inproc.Network,
    allocator: std.mem.Allocator,
};

/// Per-connection state: the in-process frame stream plus the caller-owned read
/// and write buffers it borrows. The buffers free with the connection.
const InprocConnPayload = struct {
    stream: net.inproc.InprocFrameStream,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const InprocListenerPayload = struct {
    listener: *net.inproc.InprocListener,
    allocator: std.mem.Allocator,
};

// Same per-connection buffer caps as the TCP endpoints: neither holds a whole
// frame (a large inbound frame spills, bounded by `max_frame_bytes`), so steady
// per-connection memory is these two buffers.
const endpoint_read_buf_bytes: usize = 16 * 1024;
const endpoint_write_buf_bytes: usize = 64 * 1024;

/// Create a netlayer handle allocating through the library-owned allocator.
/// Release it with `pancake_inproc_netlayer_release` after closing every
/// endpoint made from it.
pub export fn pancake_inproc_netlayer_new(out_netlayer: ?*?*PancakeInprocNetlayer) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, slot);
}

/// Create a netlayer handle whose switchboard, backend, and per-connection
/// buffers all allocate through `context`. Released with
/// `pancake_inproc_netlayer_release`.
pub export fn pancake_inproc_netlayer_new_in(context: ?*PancakeContext, out_netlayer: ?*?*PancakeInprocNetlayer) i32 {
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator, slot);
}

fn netlayerNewIn(alloc: std.mem.Allocator, slot: *?*PancakeInprocNetlayer) i32 {
    const payload = alloc.create(InprocNetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.threaded = std.Io.Threaded.init(alloc, .{});
    payload.allocator = alloc;
    // `Network.init` captures `payload.threaded.io()`, which borrows
    // `&payload.threaded` — valid now that the payload has its stable address.
    payload.network = net.inproc.Network.init(alloc, payload.threaded.io());
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_inproc_netlayer_release(netlayer: ?*PancakeInprocNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    const alloc = payload.allocator;
    payload.network.deinit();
    payload.threaded.deinit();
    alloc.destroy(payload);
}

fn beginConn(alloc: std.mem.Allocator, max_frame_bytes: usize) ?*InprocConnPayload {
    const read_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_read_buf_bytes)) catch return null;
    const write_buf = alloc.alloc(u8, @min(max_frame_bytes, endpoint_write_buf_bytes)) catch {
        alloc.free(read_buf);
        return null;
    };
    const payload = alloc.create(InprocConnPayload) catch {
        alloc.free(read_buf);
        alloc.free(write_buf);
        return null;
    };
    payload.read_buf = read_buf;
    payload.write_buf = write_buf;
    payload.allocator = alloc;
    return payload;
}

fn abortConn(payload: *InprocConnPayload) void {
    const alloc = payload.allocator;
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

fn destroyConn(payload: *InprocConnPayload) void {
    const alloc = payload.allocator;
    payload.stream.deinit();
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

/// Dial the in-process listener bound at `designator` and return an owned
/// connection handle framing on `codec`. Non-blocking on the dial itself.
pub export fn pancake_inproc_connect(
    netlayer: ?*PancakeInprocNetlayer,
    designator: ?[*]const u8,
    designator_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeInprocConn,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const designator_ptr = designator orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = nl.network.connectFrameStream(designator_ptr[0..designator_len], codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        return dialErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Bind an in-process listener on `designator`. Returns an owned listener handle.
pub export fn pancake_inproc_listen(
    netlayer: ?*PancakeInprocNetlayer,
    designator: ?[*]const u8,
    designator_len: usize,
    out_listener: ?*?*PancakeInprocListener,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_listener orelse return PANCAKE_ERR_NULL_POINTER;
    const designator_ptr = designator orelse return PANCAKE_ERR_NULL_POINTER;

    const payload = nl.allocator.create(InprocListenerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .listener = nl.network.bindFrame(nl.allocator, designator_ptr[0..designator_len]) catch |err| {
            nl.allocator.destroy(payload);
            return listenErrorToCode(err);
        },
        .allocator = nl.allocator,
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Block until a dialer connects, returning an owned connection handle framing
/// on `codec`.
pub export fn pancake_inproc_accept(
    listener: ?*PancakeInprocListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeInprocConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = lpayload.listener.acceptFrameStream(lpayload.allocator, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        return acceptErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame`. `_CLOSED` on graceful EOF, `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
pub export fn pancake_inproc_conn_read_frame(conn: ?*PancakeInprocConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;

    const f = payload.stream.readFrame() catch |err| return frameReadErrorToCode(err);

    slot.* = c.tryManagedFrame(payload.allocator, f) catch {
        var owned = f;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Write one frame's *borrowed* bytes into the partner's pipe.
pub export fn pancake_inproc_conn_write_frame(conn: ?*PancakeInprocConn, frame_in: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;

    payload.stream.writeFrame(bytes_ptr[0..borrowed.len]) catch |err| {
        setLastError("write_frame: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    return PANCAKE_OK;
}

pub export fn pancake_inproc_conn_release(conn: ?*PancakeInprocConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

pub export fn pancake_inproc_listener_release(listener: ?*PancakeInprocListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    const alloc = payload.allocator;
    payload.listener.close();
    alloc.destroy(payload);
}

fn dialErrorToCode(err: net.netlayer.DialError) i32 {
    return switch (err) {
        error.InvalidAddress => blk: {
            setLastError("connect: empty inproc designator", .{});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
        error.ConnectionLost => blk: {
            setLastError("connect: no listener bound at that inproc designator", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn listenErrorToCode(err: net.netlayer.ListenError) i32 {
    return switch (err) {
        error.InvalidAddress => blk: {
            setLastError("listen: empty inproc designator", .{});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
        error.BindFailed => blk: {
            setLastError("listen: inproc designator already bound", .{});
            break :blk PANCAKE_ERR_INVALID_ARGUMENT;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn acceptErrorToCode(err: net.netlayer.AcceptError) i32 {
    return switch (err) {
        error.ConnectionLost => blk: {
            setLastError("accept: listener closed", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn frameReadErrorToCode(err: net.FrameError) i32 {
    return switch (err) {
        error.Closed => PANCAKE_ERR_CLOSED,
        error.MalformedFrame => PANCAKE_ERR_MALFORMED,
        error.FrameTooLarge => PANCAKE_ERR_FRAME_TOO_LARGE,
        error.TruncatedFrame => blk: {
            setLastError("read_frame: stream closed mid-frame", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.ConnectionLost => blk: {
            setLastError("read_frame: in-process pipe failed", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn netlayerFromOpaque(netlayer: ?*PancakeInprocNetlayer) ?*InprocNetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*PancakeInprocConn) ?*InprocConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn listenerFromOpaque(listener: ?*PancakeInprocListener) ?*InprocListenerPayload {
    const ptr = listener orelse return null;
    return @ptrCast(@alignCast(ptr));
}
