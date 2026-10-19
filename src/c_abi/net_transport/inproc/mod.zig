//! The in-process transport's public C ABI, `libglowcap_net_transport_inproc`.
//!
//! The socket-free sibling of the TCP transport (`src/c_abi/net_transport/tcp/`): the same
//! host-driven netlayer boundary, but the two peers run in one process with no
//! kernel transport. A `GlowcapInprocNetlayer` is a switchboard
//! (`net.inproc.Network`) plus the one `std.Io` backend its pipes block on. A
//! listener binds to a *string designator* (not host:port) and a dialer names
//! that designator. The C listener adds a socketpair wake descriptor for foreign
//! reactors, but no application bytes flow through it. This is what a binding's
//! smoke test dials so a full OCapN conversation runs in-process without a
//! network socket.
//!
//! Frame movement is identical to TCP's: read a whole owned frame, feed it to the
//! host's peer, step, take outbound, write it back. Only the addressing and the
//! transport behind the `FrameStream` differ, so the C host's loop is unchanged.
//!
//! This is a *separate archive* from `libglowcap_ocapn` (ADR-0022): it imports
//! only the shared vocabulary leaf (`@import("c_abi_shared")`), so it exports
//! just the `glowcap_inproc_*` family and shares no core symbol with the ocapn
//! archive. The transport carries its own per-thread last-error slot, read
//! through `glowcap_inproc_last_error`.

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");

const net = @import("net");

// The shared C-ABI vocabulary leaf, *not* the ocapn root. Importing the leaf
// gives this transport ABI the same frame and context types
// `glowcap_ocapn.h` declares, with its own compiled copy of the helpers and
// last-error slot, and pulls *none* of the ocapn archive's exported surface
// (ADR-0022 companion split).
const c = @import("c_abi_shared");

pub const contract_layouts = [_]c.archive_contract.Layout{};

pub const GLOWCAP_INPROC_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "inproc",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);

pub export fn glowcap_inproc_archive_fingerprint() u64 {
    return GLOWCAP_INPROC_ARCHIVE_FINGERPRINT;
}

/// The netlayer handle owns the in-process switchboard and the one `std.Io`
/// backend its pipes block on. Created and released explicitly by the host. It
/// must outlive every connection and listener made from it.
pub const GlowcapInprocNetlayer = opaque {};
/// One in-process connection carrying one OCapN session. Owned by the caller.
/// Released with `glowcap_inproc_conn_release`.
pub const GlowcapInprocConn = opaque {};
/// A bound in-process listener. Owned by the caller. Released with
/// `glowcap_inproc_listener_release`.
pub const GlowcapInprocListener = opaque {};

const GlowcapContext = c.GlowcapContext;
const GlowcapFrame = c.GlowcapFrame;
const GlowcapManagedFrame = c.GlowcapManagedFrame;

const setLastError = c.setLastError;

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from. See `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// Copy the calling thread's last inproc-transport error message into `out_buf`,
/// the inproc sibling of `glowcap_last_error`. `libglowcap_net_transport_inproc`
/// carries its own per-thread slot (a separate compiled copy of the shared
/// leaf's slot), so a `glowcap_inproc_*` call that returns a cause-bearing code
/// records it here, readable independently of the ocapn archive's. Copies at
/// most `cap - 1` bytes and always NUL-terminates when `cap > 0`.
/// `out_buf == NULL` or `cap == 0` queries the length. Returns the full message
/// length, or 0 when none is set.
pub export fn glowcap_inproc_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's inproc-transport last error slot.
pub export fn glowcap_inproc_clear_last_error() void {
    c.lastErrorClear();
}

/// The netlayer handle owns the in-process switchboard and the one `std.Io`
/// backend its pipes block on. Created and released explicitly by the host. It
/// must outlive every connection and listener made from it. `Network` captures
/// `&self.threaded` via `io()`, so the payload is heap-pinned for that borrow to
/// stay valid (`create` gives it a stable address).
const InprocNetlayerPayload = struct {
    threaded: std.Io.Threaded,
    network: net.inproc.Network,
    calls: c.ForeignCallBarrier,
    allocator: std.mem.Allocator,

    fn io(self: *InprocNetlayerPayload) std.Io {
        return self.threaded.io();
    }
};

/// Per-connection state: the in-process frame stream plus the caller-owned read
/// and write buffers it borrows. The buffers free with the connection.
const InprocConnPayload = struct {
    stream: net.inproc.InprocFrameStream,
    operations: c.ForeignCallBarrier,
    directions: c.ConnDirectionGates,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

const InprocListenerPayload = struct {
    listener: *net.inproc.InprocListener,
    operations: c.ForeignCallBarrier,
    io: std.Io,
    allocator: std.mem.Allocator,
};

// The shared buffer/payload lifecycle (`c_abi_shared.ConnLifecycle`): allocate
// with `begin`, release a never-installed payload with `abort`, an established
// one with `destroy`. Buffer caps are the shared leaf's
// `connection_read_buf_bytes` / `connection_write_buf_bytes`, the same as the
// TCP connections. Frame read/write choreography is `ConnFrameOps` below. This
// archive keeps the `export fn`s.
const conn_lifecycle = c.ConnLifecycle(InprocConnPayload);
const beginConn = conn_lifecycle.begin;
const abortConn = conn_lifecycle.abort;
const destroyConn = conn_lifecycle.destroy;
const conn_frame_ops = c.ConnFrameOps(InprocConnPayload);

/// Create a netlayer handle allocating through the library-owned allocator.
/// Release it with `glowcap_inproc_netlayer_release` after closing every
/// endpoint made from it.
pub export fn glowcap_inproc_netlayer_new(out_netlayer: ?*?*GlowcapInprocNetlayer) i32 {
    c.lastErrorClear();
    const slot = out_netlayer orelse return GLOWCAP_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, slot);
}

/// Create a netlayer handle whose switchboard, backend, and per-connection
/// buffers all allocate through `context`. Released with
/// `glowcap_inproc_netlayer_release`.
pub export fn glowcap_inproc_netlayer_new_in(context: ?*GlowcapContext, out_netlayer: ?*?*GlowcapInprocNetlayer) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return GLOWCAP_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), slot);
}

fn netlayerNewIn(alloc: std.mem.Allocator, slot: *?*GlowcapInprocNetlayer) i32 {
    const payload = alloc.create(InprocNetlayerPayload) catch |err|
        return c.failInternal("inproc netlayer_new", err);
    payload.threaded = std.Io.Threaded.init(alloc, .{});
    payload.calls = .{};
    payload.allocator = alloc;
    // `Network.init` captures `payload.threaded.io()`, which borrows
    // `&payload.threaded`, valid now that the payload has its stable address.
    payload.network = net.inproc.Network.init(alloc, payload.threaded.io());
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

pub export fn glowcap_inproc_netlayer_release(netlayer: ?*GlowcapInprocNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    _ = payload.calls.beginShutdown(payload.io());
    payload.calls.wait(payload.io());
    const alloc = payload.allocator;
    payload.network.deinit();
    payload.threaded.deinit();
    alloc.destroy(payload);
}

/// Dial the in-process listener bound at `designator` and return an owned
/// connection handle framing on `codec`. Non-blocking on the dial itself.
fn inprocConnect(
    netlayer: ?*GlowcapInprocNetlayer,
    designator: ?[*]const u8,
    designator_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapInprocConn,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.io())) return GLOWCAP_ERR_CLOSED;
    defer nl.calls.release(nl.io());
    const slot = out_conn orelse return GLOWCAP_ERR_NULL_POINTER;
    const designator_ptr = designator orelse return GLOWCAP_ERR_NULL_POINTER;
    const codec_id = c.framingOptionsFromC(codec, max_frame_bytes, "inproc connect") catch
        return GLOWCAP_ERR_INVALID_ARGUMENT;

    const payload = beginConn(nl.allocator, max_frame_bytes) orelse
        return c.failInternal("inproc connect", error.OutOfMemory);
    payload.stream = nl.network.connectFrameStream(designator_ptr[0..designator_len], codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        return dialErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

pub export fn glowcap_inproc_connect(
    netlayer: ?*GlowcapInprocNetlayer,
    designator: ?[*]const u8,
    designator_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapInprocConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        inprocConnect(netlayer, designator, designator_len, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Bind an in-process listener on `designator`. Returns an owned listener handle.
/// An empty designator is `GLOWCAP_ERR_INVALID_ARGUMENT`; one already bound is
/// `GLOWCAP_ERR_IO`, the shared code for a bind another listener holds.
pub export fn glowcap_inproc_listen(
    netlayer: ?*GlowcapInprocNetlayer,
    designator: ?[*]const u8,
    designator_len: usize,
    out_listener: ?*?*GlowcapInprocListener,
) i32 {
    c.lastErrorClear();
    const nl = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!nl.calls.acquire(nl.io())) return GLOWCAP_ERR_CLOSED;
    defer nl.calls.release(nl.io());
    const slot = out_listener orelse return GLOWCAP_ERR_NULL_POINTER;
    const designator_ptr = designator orelse return GLOWCAP_ERR_NULL_POINTER;

    const payload = nl.allocator.create(InprocListenerPayload) catch |err|
        return c.failInternal("inproc listen", err);
    payload.* = .{
        .listener = nl.network.bindFrame(nl.allocator, designator_ptr[0..designator_len]) catch |err| {
            nl.allocator.destroy(payload);
            return listenErrorToCode(err);
        },
        .operations = .{},
        .io = nl.io(),
        .allocator = nl.allocator,
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

/// Return the listener's borrowed readiness descriptor. Inproc has no transport
/// fd, so this is its wake channel, nudged when a dial is queued.
/// Park on it before calling `glowcap_inproc_accept`. The listener owns it.
pub export fn glowcap_inproc_listener_readiness_fd(listener: ?*GlowcapInprocListener, out_fd: ?*i32) i32 {
    c.lastErrorClear();
    const payload = listenerFromOpaque(listener) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!payload.operations.acquire(payload.io)) return GLOWCAP_ERR_CLOSED;
    defer payload.operations.release(payload.io);
    const slot = out_fd orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = payload.listener.readinessFd();
    return GLOWCAP_OK;
}

/// Block until a dialer connects, returning an owned connection handle framing
/// on `codec`.
fn inprocAccept(
    listener: ?*GlowcapInprocListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapInprocConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!lpayload.operations.acquire(lpayload.io)) return GLOWCAP_ERR_CLOSED;
    defer lpayload.operations.release(lpayload.io);
    const slot = out_conn orelse return GLOWCAP_ERR_NULL_POINTER;
    const codec_id = c.framingOptionsFromC(codec, max_frame_bytes, "inproc accept") catch
        return GLOWCAP_ERR_INVALID_ARGUMENT;

    const payload = beginConn(lpayload.allocator, max_frame_bytes) orelse
        return c.failInternal("inproc accept", error.OutOfMemory);
    payload.stream = lpayload.listener.acceptFrameStream(lpayload.allocator, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        return acceptErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

pub export fn glowcap_inproc_accept(
    listener: ?*GlowcapInprocListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*GlowcapInprocConn,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        inprocAccept(listener, codec, max_frame_bytes, out_conn),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Block until one whole frame arrives, writing it as an *owned* managed frame
/// into `out_frame`. `_CLOSED` on graceful EOF, `_MALFORMED` / `_FRAME_TOO_LARGE`
/// for a bad frame.
fn inprocConnReadFrame(conn: ?*GlowcapInprocConn, out_frame: ?*GlowcapManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_frame orelse return GLOWCAP_ERR_NULL_POINTER;
    return conn_frame_ops.readFrame(payload, slot, onReadConnectionLost);
}

pub export fn glowcap_inproc_conn_read_frame(
    conn: ?*GlowcapInprocConn,
    out_frame: ?*GlowcapManagedFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        inprocConnReadFrame(conn, out_frame),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Write one frame's *borrowed* bytes into the partner's pipe.
fn inprocConnWriteFrame(conn: ?*GlowcapInprocConn, frame_in: ?*const GlowcapFrame) i32 {
    const payload = connFromOpaque(conn) orelse return GLOWCAP_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return GLOWCAP_ERR_NULL_POINTER;
    return conn_frame_ops.writeFrame(payload, borrowed, onWriteErr);
}

pub export fn glowcap_inproc_conn_write_frame(
    conn: ?*GlowcapInprocConn,
    frame_in: ?*const GlowcapFrame,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        inprocConnWriteFrame(conn, frame_in),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// Interrupt blocked reads and writes and seal new operation admission without
/// freeing the connection. Release joins every admitted operation.
pub export fn glowcap_inproc_conn_shutdown(conn: ?*GlowcapInprocConn) void {
    const payload = connFromOpaque(conn) orelse return;
    conn_lifecycle.shutdown(payload);
}

pub export fn glowcap_inproc_conn_release(conn: ?*GlowcapInprocConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

/// Stop admission and wake a blocked accept without freeing the listener.
/// Release joins every accept already admitted.
pub export fn glowcap_inproc_listener_shutdown(listener: ?*GlowcapInprocListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    if (payload.operations.beginShutdown(payload.io)) payload.listener.shutdown();
}

fn inprocListenerRelease(listener: ?*GlowcapInprocListener) i32 {
    const payload = listenerFromOpaque(listener) orelse return GLOWCAP_OK;
    glowcap_inproc_listener_shutdown(listener);
    payload.operations.wait(payload.io);
    const alloc = payload.allocator;
    const failure = payload.listener.close();
    alloc.destroy(payload);
    if (failure) |chain| {
        setLastError("listener release: {s}", .{@errorName(chain.cause)});
        return GLOWCAP_ERR_IO;
    }
    return GLOWCAP_OK;
}

pub export fn glowcap_inproc_listener_release(
    listener: ?*GlowcapInprocListener,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        inprocListenerRelease(listener),
        out_error,
        error_cap,
        out_error_len,
    );
}

fn dialErrorToCode(err: net.netlayer.DialError) i32 {
    switch (err) {
        error.InvalidAddress => setLastError("connect: empty inproc designator", .{}),
        error.ConnectionRefused => setLastError("connect: no listener bound at that inproc designator", .{}),
        // ConnectionLost is reachable: a listener acquired for the dial can be
        // torn down before `enqueue`. NetworkUnreachable and TimedOut have no
        // in-memory meaning and never arise for inproc; the shared DialError set
        // only spells them because network transports need them. Surface the
        // exact classification by name rather than collapsing it, so a consumer
        // reading `glowcap_inproc_last_error` sees which one it hit.
        else => setLastError("connect: inproc dial failed: {s}", .{@errorName(err)}),
    }
    return c.netlayerFailureCode(err);
}

fn listenErrorToCode(err: net.netlayer.ListenError) i32 {
    switch (err) {
        error.InvalidAddress => setLastError("listen: empty inproc designator", .{}),
        error.BindFailed => setLastError("listen: inproc designator already bound", .{}),
        else => setLastError("listen: inproc listen failed: {s}", .{@errorName(err)}),
    }
    return c.netlayerFailureCode(err);
}

fn acceptErrorToCode(err: net.netlayer.AcceptError) i32 {
    switch (err) {
        error.ConnectionLost => setLastError("accept: listener closed", .{}),
        error.SocketConfigurationFailed => setLastError("accept: transport socket configuration failed", .{}),
        error.WakeNudgeFailed => setLastError("accept: in-process listener wake failed", .{}),
        error.WakeDrainFailed => setLastError("accept: in-process listener wake drain failed", .{}),
        else => setLastError("accept: inproc accept failed: {s}", .{@errorName(err)}),
    }
    return c.netlayerFailureCode(err);
}

fn onReadConnectionLost(_: *InprocConnPayload) void {
    setLastError("read_frame: in-process pipe failed", .{});
}

fn onWriteErr(_: *InprocConnPayload, err: anyerror) void {
    setLastError("write_frame: {s}", .{@errorName(err)});
}

fn netlayerFromOpaque(netlayer: ?*GlowcapInprocNetlayer) ?*InprocNetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*GlowcapInprocConn) ?*InprocConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn listenerFromOpaque(listener: ?*GlowcapInprocListener) ?*InprocListenerPayload {
    const ptr = listener orelse return null;
    return @ptrCast(@alignCast(ptr));
}
