//! C ABI surface for `libpancake` — the boring, C-shaped boundary.
//!
//! Ownership is explicit in the vocabulary, not in comments a caller has to
//! find: a `PancakeFrame` is *borrowed* for the duration of one call (the C
//! caller keeps owning its bytes); a `PancakeManagedFrame` is *owned* and
//! self-releasing (the C caller must call its `release` exactly once). Return
//! codes are fixed-width `i32` — `PANCAKE_OK` or a negative `PANCAKE_ERR_*`;
//! handles are opaque (`PancakePeer`); events carry the originating frame in the
//! negotiated codec with no re-encode.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const runtime = @import("../runtime/mod.zig");
const net_adapter = @import("../net_adapter/mod.zig");

pub const PANCAKE_OK: i32 = 0;
pub const PANCAKE_ERR_NULL_POINTER: i32 = -1;
pub const PANCAKE_ERR_INVALID_HANDLE: i32 = -2;
/// A non-pointer argument was out of range or unparseable (e.g. a zero frame
/// cap, or a host string that is not an address). Distinct from `_NULL_POINTER`
/// (a required pointer was null) and `_IO` (the network itself failed).
pub const PANCAKE_ERR_INVALID_ARGUMENT: i32 = -3;
pub const PANCAKE_ERR_SESSION: i32 = -4;
pub const PANCAKE_ERR_CODEC: i32 = -5;
pub const PANCAKE_ERR_INTERNAL: i32 = -6;
pub const PANCAKE_ERR_WOULD_BLOCK: i32 = -7;
/// The peer closed the stream gracefully on a frame boundary (clean EOF).
pub const PANCAKE_ERR_CLOSED: i32 = -8;
/// An underlying socket read/write failed; `pancake_last_error` carries the
/// concrete cause.
pub const PANCAKE_ERR_IO: i32 = -9;
/// Inbound bytes were not a structurally valid frame.
pub const PANCAKE_ERR_MALFORMED: i32 = -10;
/// An inbound frame exceeded the endpoint's `max_frame_bytes`.
pub const PANCAKE_ERR_FRAME_TOO_LARGE: i32 = -11;

/// Codec selector for endpoint framing (the grammar that delimits frames).
pub const PANCAKE_CODEC_SYRUP: u32 = 0;
pub const PANCAKE_CODEC_CAPNP: u32 = 1;

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;
pub const PANCAKE_EVENT_DELIVER: u32 = 1;
pub const PANCAKE_EVENT_RESOLVE: u32 = 2;
pub const PANCAKE_EVENT_GC_EXPORT: u32 = 3;
pub const PANCAKE_EVENT_GC_ANSWER: u32 = 4;
pub const PANCAKE_EVENT_HANDOFF: u32 = 5;
pub const PANCAKE_EVENT_START_SESSION: u32 = 6;
pub const PANCAKE_EVENT_ABORT: u32 = 7;
pub const PANCAKE_EVENT_LISTEN: u32 = 8;
pub const PANCAKE_EVENT_GET: u32 = 9;
pub const PANCAKE_EVENT_INDEX: u32 = 10;

/// A frame whose bytes are *borrowed* from the C caller for the duration of one
/// call. The runtime reads them during the call and retains nothing; the caller
/// keeps ownership and frees them on its own schedule. Used for inbound feeds.
pub const PancakeFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

/// Release hook a `PancakeManagedFrame` carries; the caller invokes it once to
/// free the frame.
pub const ReleaseFn = *const fn (*PancakeManagedFrame) callconv(.c) void;

/// A frame the runtime *owns* and hands to the C caller (outbound frames, event
/// frames). It is self-describing and self-releasing: the caller must invoke
/// `release` exactly once to free it — never a host `free`.
pub const PancakeManagedFrame = extern struct {
    bytes: ?[*]u8,
    len: usize,
    shape: u32,
    release: ?ReleaseFn,
    private_data: ?*anyopaque,
};

pub const PancakeEvent = extern struct {
    kind: u32,
    frame: PancakeManagedFrame,
};

pub const PancakePeer = opaque {};

const allocator = std.heap.page_allocator;

const ManagedFramePayload = struct {
    frame: foundation.Frame,
};

const AdoptedManagedFramePayload = struct {
    managed: PancakeManagedFrame,
};

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy ([`runtime.abort_projection.classify`]) so the C codes
/// cannot drift from the abort projection: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
fn feedErrorToCode(err: anyerror) i32 {
    return switch (runtime.abort_projection.classify(err).domain) {
        .codec => PANCAKE_ERR_CODEC,
        .session => PANCAKE_ERR_SESSION,
        .foreign => PANCAKE_ERR_INTERNAL,
    };
}

pub export fn pancake_managed_frame_release(frame: ?*PancakeManagedFrame) void {
    const managed = frame orelse return;
    const release = managed.release orelse return;

    managed.release = null;
    // The callback owns payload cleanup and any remaining descriptor
    // normalization. Do not touch `managed` after this call; a producer may
    // allocate descriptors whose release reclaims the whole object.
    release(managed);
}

pub export fn pancake_frame_release(frame: ?*PancakeManagedFrame) void {
    pancake_managed_frame_release(frame);
}

pub export fn pancake_event_release(event: ?*PancakeEvent) void {
    const managed = event orelse return;
    pancake_managed_frame_release(&managed.frame);
    managed.kind = 0;
}

pub export fn pancake_peer_new(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    const peer = allocator.create(runtime.Peer) catch return PANCAKE_ERR_INTERNAL;
    peer.* = runtime.Peer.init(allocator);
    slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

pub export fn pancake_peer_release(peer: ?*PancakePeer) void {
    const ptr = peerFromOpaque(peer) orelse return;
    ptr.deinit();
    allocator.destroy(ptr);
}

/// Dispatch one inbound frame whose bytes are *borrowed* for this call only. The
/// peer reads and retains nothing; the caller keeps ownership of `frame`'s bytes.
pub export fn pancake_peer_feed_borrowed(peer: ?*PancakePeer, frame: ?*const PancakeFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frameShapeFromC(borrowed.shape) orelse return PANCAKE_ERR_CODEC;

    ptr.recvBorrowed(.{
        .bytes = bytes_ptr[0..borrowed.len],
        .shape = shape,
    }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Adopt an inbound managed frame, transferring ownership to the peer for queued
/// dispatch. On success the caller's `frame` struct is nulled out (bytes/len/
/// release cleared) so it is not released twice; the peer releases it later.
pub export fn pancake_peer_feed_owned(peer: ?*PancakePeer, frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const managed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = managed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frameShapeFromC(managed.shape) orelse return PANCAKE_ERR_CODEC;

    const payload = allocator.create(AdoptedManagedFramePayload) catch return PANCAKE_ERR_INTERNAL;
    errdefer allocator.destroy(payload);
    payload.* = .{ .managed = managed.* };

    const owned = foundation.Frame.initExternal(
        bytes_ptr[0..managed.len],
        shape,
        payload,
        releaseAdoptedManagedFrame,
    ) catch return PANCAKE_ERR_CODEC;

    ptr.feedInbound(owned) catch return PANCAKE_ERR_INTERNAL;
    managed.bytes = null;
    managed.len = 0;
    managed.release = null;
    managed.private_data = null;
    return PANCAKE_OK;
}

/// Advance the peer: validate-and-apply queued inbound frames and encode pending
/// outbound work. No I/O — the caller drains `take_outbound` and `poll_event`
/// afterward.
pub export fn pancake_peer_step(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    _ = ptr.step() catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Take the next outbound frame, writing an *owned* managed frame into
/// `out_frame` that the caller must `release`. Returns `PANCAKE_ERR_WOULD_BLOCK`
/// when the outbound queue is empty.
pub export fn pancake_peer_take_outbound(peer: ?*PancakePeer, out_frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const frame = ptr.takeOutbound() orelse return PANCAKE_ERR_WOULD_BLOCK;

    const payload = allocator.create(ManagedFramePayload) catch {
        var owned = frame;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    payload.* = .{ .frame = frame };
    slot.* = .{
        .bytes = @constCast(payload.frame.bytes().ptr),
        .len = payload.frame.bytes().len,
        .shape = frameShapeToC(payload.frame.view().shape),
        .release = releaseOwnedFrame,
        .private_data = payload,
    };
    return PANCAKE_OK;
}

/// Take the next application event, writing it into `out_event`. The event's
/// frame is the originating wire bytes in the negotiated codec (no re-encode),
/// handed over as an *owned* managed frame the caller must `release`. Returns
/// `PANCAKE_ERR_WOULD_BLOCK` when no event is pending.
pub export fn pancake_peer_poll_event(peer: ?*PancakePeer, out_event: ?*PancakeEvent) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_event orelse return PANCAKE_ERR_NULL_POINTER;
    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;

    // Hand back the originating frame bytes in the session's negotiated codec.
    // The frame moves into the managed payload; no decode and no re-encode.
    slot.* = .{
        .kind = eventKindToC(event.kind()),
        .frame = tryManagedFrame(event.frame) catch {
            event.deinit();
            return PANCAKE_ERR_INTERNAL;
        },
    };
    return PANCAKE_OK;
}

fn tryManagedFrame(frame: foundation.Frame) !PancakeManagedFrame {
    const payload = try allocator.create(ManagedFramePayload);
    payload.* = .{ .frame = frame };
    return .{
        .bytes = @constCast(payload.frame.bytes().ptr),
        .len = payload.frame.bytes().len,
        .shape = frameShapeToC(payload.frame.view().shape),
        .release = releaseOwnedFrame,
        .private_data = payload,
    };
}

fn eventKindToC(kind: runtime.EventKind) u32 {
    return switch (kind) {
        .deliver => PANCAKE_EVENT_DELIVER,
        .resolve => PANCAKE_EVENT_RESOLVE,
        .gc_export => PANCAKE_EVENT_GC_EXPORT,
        .gc_answer => PANCAKE_EVENT_GC_ANSWER,
        .handoff => PANCAKE_EVENT_HANDOFF,
        .start_session => PANCAKE_EVENT_START_SESSION,
        .abort => PANCAKE_EVENT_ABORT,
        .listen => PANCAKE_EVENT_LISTEN,
        .get => PANCAKE_EVENT_GET,
        .index => PANCAKE_EVENT_INDEX,
    };
}

fn releaseOwnedFrame(frame: *PancakeManagedFrame) callconv(.c) void {
    const payload_ptr = frame.private_data orelse return;
    const payload: *ManagedFramePayload = @ptrCast(@alignCast(payload_ptr));
    payload.frame.deinit();
    allocator.destroy(payload);
    frame.bytes = null;
    frame.len = 0;
    frame.release = null;
    frame.private_data = null;
}

fn releaseAdoptedManagedFrame(context: *anyopaque) void {
    const payload: *AdoptedManagedFramePayload = @ptrCast(@alignCast(context));
    pancake_managed_frame_release(&payload.managed);
    allocator.destroy(payload);
}

fn peerFromOpaque(peer: ?*PancakePeer) ?*runtime.Peer {
    const ptr = peer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn frameShapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        PANCAKE_FRAME_SHAPE_BYTE => .byte,
        PANCAKE_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

fn frameShapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => PANCAKE_FRAME_SHAPE_BYTE,
        .word => PANCAKE_FRAME_SHAPE_WORD,
    };
}

// ── Per-thread last error ────────────────────────────────────────────────────
//
// The Zig side would otherwise hide the concrete `ReadFailed` / `WriteFailed`
// behind a flat `PANCAKE_ERR_IO`. This per-thread slot re-exposes it: a function
// that returns `_IO` first records a human-readable cause here.

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch blk: {
        // Message longer than the slot: keep the truncated prefix.
        break :blk last_error_buf[0..];
    };
    last_error_len = written.len;
}

/// Copy the calling thread's last error message into `out_buf` (NUL-terminated
/// if it fits), returning the full message length (which may exceed `cap`, in
/// which case the copy was truncated). errno-style: meaningful only right after
/// a call that returned a cause-bearing code (`_IO`, or the address-parse
/// `_INVALID_ARGUMENT`); a later success does not clear it. Returns 0 when none
/// is set.
pub export fn pancake_last_error(out_buf: ?[*]u8, cap: usize) usize {
    const dest = out_buf orelse return last_error_len;
    if (cap == 0) return last_error_len;
    const n = @min(last_error_len, cap - 1);
    @memcpy(dest[0..n], last_error_buf[0..n]);
    dest[n] = 0;
    return last_error_len;
}

/// Clear the calling thread's last error slot.
pub export fn pancake_clear_last_error() void {
    last_error_len = 0;
}

// ── Bootstrap registration ───────────────────────────────────────────────────

/// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
/// (ADR-0006 responder half). Writes the allocated export id into
/// `out_export_id`. The swissnum bytes are borrowed for the call.
pub export fn pancake_peer_register_bootstrap_cap(
    peer: ?*PancakePeer,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    out_export_id: ?*u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_id orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss_ptr = swissnum orelse return PANCAKE_ERR_NULL_POINTER;
    const export_id = ptr.registerBootstrapCap(swiss_ptr[0..swissnum_len]) catch |err|
        return feedErrorToCode(err);
    slot.* = export_id;
    return PANCAKE_OK;
}

// ── Blocking TCP endpoint handles (`tcp-testing-only`) ────────────────────────
//
// The host-driven netlayer seam: the C host owns the peer and shuttles frames
// (`read_frame -> feed_owned -> step -> take_outbound -> write_frame`). The C
// side cannot name an `Io`, so the backend is an explicit owned handle
// (`PancakeTcpNetlayer` owns one `std.Io.Threaded`); endpoints created from it
// borrow that backend and must be closed before it is freed. Cleartext,
// loopback-grade; production transports layer above the same `net_adapter` types.

pub const PancakeTcpNetlayer = opaque {};
pub const PancakeTcpConn = opaque {};
pub const PancakeTcpListener = opaque {};

/// The netlayer handle owns the one I/O backend the endpoints run on. It is
/// created and freed explicitly by the host — `std.Io` cannot cross the C ABI,
/// so this is the boring-handle translation of "pass `Io` in" rather than a
/// hidden process-global runtime. Endpoints created from it borrow its `Io`, so
/// the handle must outlive every connection and listener made from it.
const TcpNetlayerPayload = struct {
    threaded: std.Io.Threaded,

    /// `Threaded.io()` captures `&self.threaded`, so the payload must be heap-
    /// pinned (it is — `allocator.create`) for the borrowed `Io` to stay valid.
    fn io(self: *TcpNetlayerPayload) std.Io {
        return self.threaded.io();
    }
};

/// Create a netlayer handle (owns a `std.Io.Threaded` backend). Free it with
/// `pancake_tcp_netlayer_free` after closing every endpoint made from it.
pub export fn pancake_tcp_netlayer_new(out_netlayer: ?*?*PancakeTcpNetlayer) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const payload = allocator.create(TcpNetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{ .threaded = std.Io.Threaded.init(allocator, .{}) };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

pub export fn pancake_tcp_netlayer_free(netlayer: ?*PancakeTcpNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    payload.threaded.deinit();
    allocator.destroy(payload);
}

const TcpConnPayload = struct {
    stream: net_adapter.FrameStream,
    read_buf: []u8,
    write_buf: []u8,
};

const TcpListenerPayload = struct {
    listener: net_adapter.tcp.Listener,
};

fn codecFromC(codec: u32) ?model.CodecId {
    return switch (codec) {
        PANCAKE_CODEC_SYRUP => .syrup,
        PANCAKE_CODEC_CAPNP => .capnp,
        else => null,
    };
}

fn destroyConn(payload: *TcpConnPayload) void {
    payload.stream.deinit();
    allocator.free(payload.read_buf);
    allocator.free(payload.write_buf);
    allocator.destroy(payload);
}

/// Modest cap on the write buffer: `writeAll` streams a frame larger than its
/// buffer straight through, so the writer never needs to hold a whole frame
/// (unlike the read buffer, which slice-1 sizes to `max_frame_bytes` so an
/// admissible frame frames whole). Caps per-connection memory at
/// `max_frame_bytes + this` instead of `2 * max_frame_bytes`.
const endpoint_write_buf_bytes: usize = 64 * 1024;

/// Allocate a connection payload and its buffers, leaving `.stream` for the
/// caller to install once the socket is established. On any failure before
/// install, release it with [`abortConn`]. Both endpoint constructors share this
/// so the buffer/payload lifecycle lives in one place.
fn beginConn(max_frame_bytes: usize) ?*TcpConnPayload {
    const read_buf = allocator.alloc(u8, max_frame_bytes) catch return null;
    const write_buf = allocator.alloc(u8, @min(max_frame_bytes, endpoint_write_buf_bytes)) catch {
        allocator.free(read_buf);
        return null;
    };
    const payload = allocator.create(TcpConnPayload) catch {
        allocator.free(read_buf);
        allocator.free(write_buf);
        return null;
    };
    payload.read_buf = read_buf;
    payload.write_buf = write_buf;
    return payload;
}

fn abortConn(payload: *TcpConnPayload) void {
    allocator.free(payload.read_buf);
    allocator.free(payload.write_buf);
    allocator.destroy(payload);
}

/// Connect to `host:port` and return an owned connection handle framing on
/// `codec`. Blocking. Runs on `netlayer`'s I/O backend.
pub export fn pancake_endpoint_tcp_testing_connect(
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
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_CODEC;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const address = net_adapter.tcp.parseHostPort(host_ptr[0..host_len], port) catch |err| {
        setLastError("connect: invalid address: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const payload = beginConn(max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = net_adapter.tcp.connectFrameStream(nl.io(), address, codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        setLastError("connect: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Bind + listen on `host:port` (port 0 = OS-chosen). Returns an owned listener
/// handle. Runs on `netlayer`'s I/O backend.
pub export fn pancake_endpoint_tcp_testing_listen(
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

    const payload = allocator.create(TcpListenerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .listener = net_adapter.tcp.Listener.bind(nl.io(), address) catch |err| {
            allocator.destroy(payload);
            setLastError("listen: {s}", .{@errorName(err)});
            return PANCAKE_ERR_IO;
        },
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// The OS-resolved local port of a listener (useful after binding to port 0).
pub export fn pancake_endpoint_tcp_listener_port(listener: ?*PancakeTcpListener, out_port: ?*u16) i32 {
    const payload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_port orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = payload.listener.localAddress().getPort();
    return PANCAKE_OK;
}

/// Block until a client connects, returning an owned connection handle framing
/// on `codec`.
pub export fn pancake_endpoint_tcp_testing_accept(
    listener: ?*PancakeTcpListener,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeTcpConn,
) i32 {
    const lpayload = listenerFromOpaque(listener) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_CODEC;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = lpayload.listener.acceptFrameStream(codec_id, max_frame_bytes, payload.read_buf, payload.write_buf) catch |err| {
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
pub export fn pancake_endpoint_tcp_read_frame(conn: ?*PancakeTcpConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;

    const frame = payload.stream.readFrame(allocator) catch |err| return frameReadErrorToCode(payload, err);

    slot.* = tryManagedFrame(frame) catch {
        var owned = frame;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Write one frame's *borrowed* bytes and flush. Returns `_IO` on a socket fault.
pub export fn pancake_endpoint_tcp_write_frame(conn: ?*PancakeTcpConn, frame: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame orelse return PANCAKE_ERR_NULL_POINTER;
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

pub export fn pancake_endpoint_tcp_conn_close(conn: ?*PancakeTcpConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

pub export fn pancake_endpoint_tcp_listener_close(listener: ?*PancakeTcpListener) void {
    const payload = listenerFromOpaque(listener) orelse return;
    payload.listener.deinit();
    allocator.destroy(payload);
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
