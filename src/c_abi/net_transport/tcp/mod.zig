//! The TCP transport's public C ABI — `libpancake_net_transport_tcp`.
//!
//! Blocking, cleartext TCP endpoint handles: the host-driven netlayer boundary
//! for C. The C host owns the peer. It reads a whole frame, feeds that owned
//! frame to the peer, steps the peer, takes outbound frames, and writes them
//! back to the connection. The C side cannot name a Zig `Io`, so the backend is
//! an explicit owned handle: `PancakeTcpNetlayer` owns one `std.Io.Threaded`.
//! Endpoints created from it borrow that backend and must be closed before it is
//! released. There is no TLS.
//!
//! This is a *separate archive* from `libpancake_ocapn` (ADR-0059): it imports
//! only the shared vocabulary leaf (`@import("c_abi_shared")` — frame/context
//! types, codes, allocation, the last-error slot), so it exports just the
//! `pancake_tcp_*` family and shares no core symbol with the ocapn archive. A
//! consumer links both libraries (ocapn for the peer surface, this for the
//! transport) and reuses the shared types by layout, exactly as a C program
//! including `pancake_ocapn.h` and `pancake_net_transport_tcp.h` does. The transport
//! carries its own per-thread last-error slot, read through
//! `pancake_tcp_last_error`.

const std = @import("std");

const net = @import("net");
// The owning `pancake_tcp_session_*` surface is the C spelling of
// `driver.Session`: it dials, runs the keyed handshake, and drives turns for
// a blocking `fetch`/`call`. An owning session is intrinsically a driver-level
// concept, so this archive embeds the actor runtime through `driver` (ADR-0062);
// the host-driven frame surface above stays driver-free.
const driver = @import("driver");

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
/// An owning OCapN session over one blocking TCP connection — the C spelling of
/// `driver.Session` (ADR-0062). `pancake_tcp_session_connect` dials and runs
/// the keyed handshake; `..._fetch`/`..._call` are blocking request/reply.
/// Owned by the caller; released with `pancake_tcp_session_release`.
pub const PancakeTcpSession = opaque {};
/// An outstanding eventual-send's answer — the C handle for the `driver.Vow` a
/// `pancake_tcp_session_send` (or `..._send_pipelined`) returned. It is the
/// questioner half of promise pipelining (ADR-0007): pipeline a dependent call
/// against it with `..._send_pipelined` before it resolves, await it with
/// `..._session_settle`, and free it with `pancake_tcp_promise_release`. Owned
/// by the caller, always released exactly once whether or not it was settled.
pub const PancakeTcpPromise = opaque {};

const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;
const PancakeReference = c.PancakeReference;
const PancakeArgument = c.PancakeArgument;

/// The settled outcome of a blocking `pancake_tcp_session_call` or `_fetch`,
/// projected to C. `resolution_kind` selects `fulfill` (a value) or the
/// `break_message` bytes; both alias the `owner` arena and stay valid until
/// `pancake_tcp_settled_release` frees it. The owning session is the only thing
/// that mints one, so the type lives in this transport archive rather than the
/// shared leaf: it composes the shared `PancakeArgument` by layout but is not
/// itself shared vocabulary until a second transport's session produces it
/// (ADR-0062). Distinct from `PancakeResolve` (a polled
/// `op:resolve` event keyed on an answer): a settled result carries no answer,
/// it is the awaited outcome of one owning call.
pub const PancakeSettled = extern struct {
    resolution_kind: u32,
    fulfill: PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
    owner: ?*anyopaque,
};

const setLastError = c.setLastError;
const codecFromC = c.codecFromC;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_SESSION = c.PANCAKE_ERR_SESSION;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;
const PANCAKE_ERR_UNSUPPORTED_VALUE = c.PANCAKE_ERR_UNSUPPORTED_VALUE;
const PANCAKE_ERR_BROKEN = c.PANCAKE_ERR_BROKEN;

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
/// into `out_frame` (the caller `release`s it, or hands it to
/// `pancake_peer_feed_owned`). Returns `_CLOSED` on graceful EOF, `_IO` on a
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

// ── Owning session (ADR-0062) ────────────────────────────────────────────────
//
// The host-driven frame surface above hands the caller whole frames to shuttle
// through a `PancakePeer` by hand. This surface is the higher-level twin: it
// owns a `driver.Session` (peer, both buffers, the bound vat) and offers the
// same blocking `fetch`/`call` the native-Zig `Session` does, marshalling the
// shared `PancakeReference`/`PancakeArgument` vocabulary into the `PancakeSettled`
// outcome this archive declares (the only producer, so it is not shared). It is
// this transport archive's own entry, not a driver default; inproc/iroh can grow
// the same shape later.

/// Owns the `driver.Session` and the resident the dial ran over. Heap-pinned:
/// `driver.connect` borrows the resident's netlayer for the dial, and the
/// connection borrows the resident's `Io`-derived stream for its life, so the
/// resident lives here alongside the connection it backs.
const TcpSessionPayload = struct {
    resident: net.tcp.Resident,
    conn: *driver.Session,
    allocator: std.mem.Allocator,
};

/// Boxes the `driver.Vow` an eventual-send returned so the C side holds it
/// as an opaque `PancakeTcpPromise*`. A `driver.Vow` is a small value (a
/// tagged answer position), but the C handle must be a stable pointer the
/// caller releases, so it lives on the session's allocator until
/// `pancake_tcp_promise_release`.
const TcpPromiseBox = struct {
    promise: driver.Vow,
    allocator: std.mem.Allocator,
};

/// Dial `host:port`, run the ephemeral keyed handshake, and return an owning
/// session framing on `codec` and refusing inbound frames over
/// `max_frame_bytes`. Blocking; `host` is borrowed. The C twin of
/// `driver.connect(&.{tcp}, …, .ephemeral, …)`. Release with
/// `pancake_tcp_session_release`.
pub export fn pancake_tcp_session_connect(
    netlayer: ?*PancakeTcpNetlayer,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    codec: u32,
    max_frame_bytes: usize,
    out_session: ?*?*PancakeTcpSession,
) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return PANCAKE_ERR_NULL_POINTER;
    const host_ptr = host orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const address = net.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("session_connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = nl.allocator.create(TcpSessionPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.resident = .{ .io = nl.io() };
    payload.allocator = nl.allocator;

    var loc_buf: [64]u8 = undefined;
    const locator = net.tcp.locator(&loc_buf, address);
    const netlayers = [_]net.netlayer.Netlayer{payload.resident.netlayer()};
    payload.conn = driver.connect(nl.allocator, &netlayers, locator, .ephemeral, .{
        .frame_cap = max_frame_bytes,
        .codec = codec_id,
    }) catch |err| {
        setLastError("session_connect: {s}", .{@errorName(err)});
        nl.allocator.destroy(payload);
        return sessionConnectErrToCode(err);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Fetch the partner's published capability `name`, writing the resolved
/// capability into `out_reference` (a `_FAR` object reference). Blocking. A name
/// the partner answers with a break returns `PANCAKE_ERR_BROKEN`
/// (`pancake_tcp_last_error` names it); a fetch that fulfils with a non-capability
/// returns `PANCAKE_ERR_UNSUPPORTED_VALUE`; a partner that left returns
/// `PANCAKE_ERR_CLOSED`. `name` is borrowed.
pub export fn pancake_tcp_session_fetch(
    session: ?*PancakeTcpSession,
    name: ?[*]const u8,
    name_len: usize,
    out_reference: ?*PancakeReference,
) i32 {
    const payload = sessionFromOpaque(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const ref_slot = out_reference orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = c.sliceFromC(name, name_len) catch |err| return c.marshalErrorToCode(err);

    const reference = payload.conn.fetchReference(name_bytes) catch |err| {
        setLastError("session_fetch: {s}", .{@errorName(err)});
        return sessionFetchErrToCode(err);
    };
    ref_slot.* = c.referenceToC(reference);
    return PANCAKE_OK;
}

/// Send `verb`/`args` to `target` and block until the reply settles, projecting
/// the outcome into `out_settled` (release it with `pancake_tcp_settled_release`).
/// `target` is a reference a prior `..._fetch` (or a received argument) produced;
/// only a near/far object reference is callable (`PANCAKE_ERR_INVALID_ARGUMENT`
/// otherwise). `target`, `verb`, and `args` are borrowed for the call. A partner
/// that left before the reply settles returns `PANCAKE_ERR_CLOSED`.
pub export fn pancake_tcp_session_call(
    session: ?*PancakeTcpSession,
    target: ?*const PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    out_settled: ?*PancakeSettled,
) i32 {
    const payload = sessionFromOpaque(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const tref = target orelse return PANCAKE_ERR_NULL_POINTER;
    const out = out_settled orelse return PANCAKE_ERR_NULL_POINTER;

    // The owning session calls object capabilities only: a far object from a
    // prior fetch, or a near object a received argument handed back. Gate the
    // target here so every uncallable kind — a promise/sturdy/broken reference,
    // or a promise-kind near/far — returns one consistent code, rather than
    // splitting between INVALID_ARGUMENT (promise) and UNSUPPORTED_VALUE
    // (sturdy/broken via referenceFromC) or silently coercing a promise ref to
    // an object turn. Matches this function's documented contract.
    const callable = (tref.kind == c.PANCAKE_REF_NEAR or tref.kind == c.PANCAKE_REF_FAR) and
        tref.sub_kind == c.PANCAKE_REF_SUB_OBJECT;
    if (!callable) {
        setLastError("session_call: target is not a callable object reference", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }

    const verb_bytes = c.sliceFromC(verb, verb_len) catch |err| return c.marshalErrorToCode(err);
    const model_target = c.referenceFromC(tref.*) catch |err| return c.marshalErrorToCode(err);

    // One projection arena owns the settled outcome (the fulfilled argument's
    // deep clone or the broken reason's dupe) and the inbound `PancakeArgument`
    // tree; `pancake_tcp_settled_release` frees it. Held until the projection
    // succeeds, so a refused value never leaks an arena.
    const arena = c.newProjectionArena(payload.allocator) orelse return PANCAKE_ERR_INTERNAL;
    var settled_ok = false;
    defer if (!settled_ok) c.freeProjectionArena(arena);
    const a = arena.allocator();

    const model_args = c.argsFromC(a, args, args_len, 0) catch |err| return c.marshalErrorToCode(err);
    const settled = payload.conn.callReference(model_target, verb_bytes, model_args, a) catch |err| {
        setLastError("session_call: {s}", .{@errorName(err)});
        return sessionCallErrToCode(err);
    };
    const code = fillSettled(arena, settled, out);
    if (code != PANCAKE_OK) return code;
    settled_ok = true;
    return PANCAKE_OK;
}

/// Project a `driver.Settled` — its values already materialized into `arena` by
/// `callReference`/`settleVow` — into `out`, handing `arena` to the result
/// as its `owner`. A fulfilled argument deep-clones into the same arena; a break
/// aliases the reason bytes there. `pancake_tcp_settled_release` frees the arena
/// and everything it owns. Returns `PANCAKE_OK`, or a marshal error code (the
/// caller leaves `settled_ok` false so its `defer` frees the arena).
const give_needs_redeem = "answer is a three-party introduction; redeem it through the node surface";

fn fillSettled(arena: *std.heap.ArenaAllocator, settled: driver.Settled, out: *PancakeSettled) i32 {
    const a = arena.allocator();
    out.* = switch (settled) {
        .fulfilled => |arg| .{
            .resolution_kind = c.PANCAKE_RESOLUTION_FULFILL,
            .fulfill = c.argumentToC(a, arg) catch |err| return c.marshalErrorToCode(err),
            .break_message = null,
            .break_message_len = 0,
            .owner = @ptrCast(arena),
        },
        .broken => |reason| .{
            .resolution_kind = c.PANCAKE_RESOLUTION_BREAK,
            .fulfill = c.zero_argument,
            .break_message = if (reason.len == 0) null else reason.ptr,
            .break_message_len = reason.len,
            .owner = @ptrCast(arena),
        },
        // The owning session is a single-connection client with no redeemer
        // for a three-party introduction; the outcome is a typed break. A
        // consumer that redeems drives the node surface instead.
        .give => .{
            .resolution_kind = c.PANCAKE_RESOLUTION_BREAK,
            .fulfill = c.zero_argument,
            .break_message = give_needs_redeem.ptr,
            .break_message_len = give_needs_redeem.len,
            .owner = @ptrCast(arena),
        },
    };
    return PANCAKE_OK;
}

/// Eventual-send `verb`/`args` to `target` without blocking, returning the
/// answer in `out_promise` (release it with `pancake_tcp_promise_release`). The
/// non-blocking, pipelinable twin of `pancake_tcp_session_call`: the call is
/// queued, not flushed, so a chain of `..._send` / `..._send_pipelined` leaves
/// together on the next settle. `target` must be a near/far object reference (a
/// prior `..._fetch` or received argument); a promise, sturdy, or broken
/// reference is `PANCAKE_ERR_INVALID_ARGUMENT`. `target`, `verb`, and `args` are
/// borrowed (the send deep-copies what it queues).
pub export fn pancake_tcp_session_send(
    session: ?*PancakeTcpSession,
    target: ?*const PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    out_promise: ?*?*PancakeTcpPromise,
) i32 {
    const payload = sessionFromOpaque(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const tref = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_promise orelse return PANCAKE_ERR_NULL_POINTER;

    // The same callable gate `pancake_tcp_session_call` applies: an eventual-send
    // targets a near/far object reference only, so every uncallable kind returns
    // one consistent INVALID_ARGUMENT rather than splitting across marshalling
    // and `sendReference`.
    const callable = (tref.kind == c.PANCAKE_REF_NEAR or tref.kind == c.PANCAKE_REF_FAR) and
        tref.sub_kind == c.PANCAKE_REF_SUB_OBJECT;
    if (!callable) {
        setLastError("session_send: target is not a callable object reference", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }

    const verb_bytes = c.sliceFromC(verb, verb_len) catch |err| return c.marshalErrorToCode(err);
    const model_target = c.referenceFromC(tref.*) catch |err| return c.marshalErrorToCode(err);

    // The queued send deep-copies its args synchronously, so a scratch arena
    // freed on return owns the marshalled tree for exactly the send call.
    var scratch = std.heap.ArenaAllocator.init(payload.allocator);
    defer scratch.deinit();
    const model_args = c.argsFromC(scratch.allocator(), args, args_len, 0) catch |err| return c.marshalErrorToCode(err);

    const promise = payload.conn.sendReference(model_target, verb_bytes, model_args) catch |err| {
        setLastError("session_send: {s}", .{@errorName(err)});
        return sessionCallErrToCode(err);
    };
    return boxPromise(payload, promise, slot);
}

/// Pipeline `verb`/`args` against the answer `promise` — an eventual-send to the
/// object that answer will resolve to, sent now without waiting for it (ADR-0007
/// questioner-side pipelining). Returns the dependent call's own answer in
/// `out_promise`. Queued, not flushed, like `..._session_send`. `promise` stays
/// valid and must still be released; `verb`/`args` are borrowed.
pub export fn pancake_tcp_session_send_pipelined(
    session: ?*PancakeTcpSession,
    promise: ?*PancakeTcpPromise,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    out_promise: ?*?*PancakeTcpPromise,
) i32 {
    const payload = sessionFromOpaque(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const box = promiseFromOpaque(promise) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_promise orelse return PANCAKE_ERR_NULL_POINTER;

    const verb_bytes = c.sliceFromC(verb, verb_len) catch |err| return c.marshalErrorToCode(err);
    var scratch = std.heap.ArenaAllocator.init(payload.allocator);
    defer scratch.deinit();
    const model_args = c.argsFromC(scratch.allocator(), args, args_len, 0) catch |err| return c.marshalErrorToCode(err);

    const answer = payload.conn.sendToAnswer(box.promise, .{ .verb = verb_bytes, .args = model_args }) catch |err| {
        setLastError("session_send_pipelined: {s}", .{@errorName(err)});
        return sessionCallErrToCode(err);
    };
    return boxPromise(payload, answer, slot);
}

/// Drive the session until `promise` settles, projecting the outcome into
/// `out_settled` (release it with `pancake_tcp_settled_release`). The first
/// settle flushes every queued `..._send` / `..._send_pipelined`, so a pipelined
/// batch travels as one round trip. Settle a given promise once; the handle
/// itself is still owned and must be released with `pancake_tcp_promise_release`.
pub export fn pancake_tcp_session_settle(
    session: ?*PancakeTcpSession,
    promise: ?*PancakeTcpPromise,
    out_settled: ?*PancakeSettled,
) i32 {
    const payload = sessionFromOpaque(session) orelse return PANCAKE_ERR_NULL_POINTER;
    const box = promiseFromOpaque(promise) orelse return PANCAKE_ERR_NULL_POINTER;
    const out = out_settled orelse return PANCAKE_ERR_NULL_POINTER;

    const arena = c.newProjectionArena(payload.allocator) orelse return PANCAKE_ERR_INTERNAL;
    var settled_ok = false;
    defer if (!settled_ok) c.freeProjectionArena(arena);

    const settled = payload.conn.settleVow(box.promise, arena.allocator()) catch |err| {
        setLastError("session_settle: {s}", .{@errorName(err)});
        return sessionCallErrToCode(err);
    };
    const code = fillSettled(arena, settled, out);
    if (code != PANCAKE_OK) return code;
    settled_ok = true;
    return PANCAKE_OK;
}

/// Release an answer handle from `pancake_tcp_session_send` /
/// `..._send_pipelined`. The boxed promise dies; a settled projection it
/// produced (a `PancakeSettled`) is independent and freed separately.
pub export fn pancake_tcp_promise_release(promise: ?*PancakeTcpPromise) void {
    const box = promiseFromOpaque(promise) orelse return;
    box.allocator.destroy(box);
}

/// Box `promise` on the session's allocator and hand the opaque handle to
/// `slot`, the shared tail of `..._send` and `..._send_pipelined`.
fn boxPromise(payload: *TcpSessionPayload, promise: driver.Vow, slot: *?*PancakeTcpPromise) i32 {
    const box = payload.allocator.create(TcpPromiseBox) catch return PANCAKE_ERR_INTERNAL;
    box.* = .{ .promise = promise, .allocator = payload.allocator };
    slot.* = @ptrCast(box);
    return PANCAKE_OK;
}

/// Release a settled projection from `pancake_tcp_session_call`; the `fulfill`
/// value and `break_message` views aliasing its arena die with it. Idempotent:
/// the struct is cleared, so releasing again (or a zero-initialized struct) is a
/// no-op.
pub export fn pancake_tcp_settled_release(settled: ?*PancakeSettled) void {
    const s = settled orelse return;
    c.freeProjectionArena(s.owner);
    s.* = .{ .resolution_kind = 0, .fulfill = c.zero_argument, .break_message = null, .break_message_len = 0, .owner = null };
}

/// Tear down the session: close the connection (freeing the owned peer and
/// buffers) and free the handle. Do not use `session` afterward.
pub export fn pancake_tcp_session_release(session: ?*PancakeTcpSession) void {
    const payload = sessionFromOpaque(session) orelse return;
    const alloc = payload.allocator;
    payload.conn.deinit();
    alloc.destroy(payload);
}

fn sessionConnectErrToCode(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.UnknownTransport, error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.ConnectionLost, error.ConnectionClosed => PANCAKE_ERR_IO,
        else => PANCAKE_ERR_SESSION,
    };
}

fn sessionFetchErrToCode(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.FetchBroken => PANCAKE_ERR_BROKEN,
        error.FetchNotACapability => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.ConnectionClosed => PANCAKE_ERR_CLOSED,
        error.ConnectionLost, error.TruncatedFrame => PANCAKE_ERR_IO,
        else => PANCAKE_ERR_SESSION,
    };
}

fn sessionCallErrToCode(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.UncallableTarget => PANCAKE_ERR_INVALID_ARGUMENT,
        error.ConnectionClosed => PANCAKE_ERR_CLOSED,
        error.ConnectionLost, error.TruncatedFrame => PANCAKE_ERR_IO,
        else => PANCAKE_ERR_SESSION,
    };
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

fn sessionFromOpaque(session: ?*PancakeTcpSession) ?*TcpSessionPayload {
    const ptr = session orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn promiseFromOpaque(promise: ?*PancakeTcpPromise) ?*TcpPromiseBox {
    const ptr = promise orelse return null;
    return @ptrCast(@alignCast(ptr));
}
