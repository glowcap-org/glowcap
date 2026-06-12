//! The iroh transport's public C ABI — a host-driven netlayer boundary for C,
//! the encrypted-QUIC sibling of the blocking TCP endpoints.
//!
//! This is a *separate artifact* from `libpancake` (ADR-0055): it links the
//! Rust iroh sidecar, so folding it into the pure-Zig core would drag cargo
//! into every consumer of the protocol library. The artifact
//! (`libpancake_iroh`) is a superset — it force-references the base `c_abi`
//! root so a binding loads one library and gets the whole peer-driving surface
//! plus this transport. The default `libpancake` never imports this file and
//! stays cargo-free.
//!
//! The shape mirrors `endpoint.zig` exactly so a binding's frame pump is reused
//! unchanged: the host owns the peer, reads a whole frame
//! (`pancake_iroh_conn_read_frame`), feeds it, steps, takes outbound frames,
//! and writes them back (`pancake_iroh_conn_write_frame`). The one departure is
//! addressing: there is no `host:port`. A peer is dialed by its endpoint id
//! (the canonical lowercase-hex designator `pancake_iroh_netlayer_node_id`
//! prints). Whether a dial also needs a comma-separated direct-address hint
//! (`pancake_iroh_netlayer_direct_addrs`) depends on the netlayer's chosen
//! reachability: a `direct` endpoint dials by id plus hints, a discovery
//! endpoint resolves the partner by id alone.
//!
//! Symbol names deliberately avoid the sidecar's own `pancake_iroh_sidecar_*`
//! exports (`pancake_iroh_sidecar_connect`, `pancake_iroh_sidecar_conn_close`,
//! …): this public surface is `pancake_iroh_netlayer_*` and
//! `pancake_iroh_conn_{read,write}_frame` / `_release`, so the private
//! byte-level seam and the public frame-level ABI share no prefix and the two
//! C ABIs link into one library without colliding.
//!
//! Threading: a `PancakeIrohConn` is single-owner like a peer — serialize every
//! call on one onto one thread. Distinct connections are independent. Every
//! sidecar call blocks the calling thread (the endpoint runs its own runtime),
//! so a host that wants concurrency runs accept and per-connection pumps on its
//! own threads (or a binding's non-blocking FFI).

const std = @import("std");

const model = @import("model");
const net_adapter = @import("net_adapter");
const iroh = @import("iroh");

const c = @import("c_abi");

/// The netlayer handle owns the one iroh endpoint (and, through it, the
/// sidecar's runtime) plus the `std.Io.Threaded` the resident captures. Every
/// connection made from it borrows the endpoint, so the netlayer must outlive
/// every connection.
pub const PancakeIrohNetlayer = opaque {};
/// One QUIC connection carrying one OCapN session, framed on the netlayer's
/// codec. Owned by the caller; released with `pancake_iroh_conn_release`.
pub const PancakeIrohConn = opaque {};

const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;
const PancakeContext = c.PancakeContext;
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

// The base `c_abi` exports (peer, frame, context, tcp) compile into this
// artifact too, so a binding loads one library for the whole surface. A plain
// reference is enough to pull a module's `export fn`s into the link.
comptime {
    _ = c;
}

const NetlayerPayload = struct {
    threaded: std.Io.Threaded,
    resident: iroh.Resident,
    /// The allocator the netlayer and every connection made from it use, so a
    /// connection frees through the same policy as the netlayer that minted it.
    allocator: std.mem.Allocator,
};

const ConnPayload = struct {
    stream: *iroh.IrohStream,
    /// Bounded overflow for a frame larger than the read buffer; inactive (and
    /// allocation-free) while frames fit the buffer.
    spill: net_adapter.Spill,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
};

/// Modest per-connection buffer caps, matching the TCP endpoints: neither
/// buffer must hold a whole frame (a large outbound frame streams through the
/// write buffer; a large inbound frame accumulates in the bounded spill), so
/// steady per-connection memory is these two buffers, not `max_frame_bytes`.
const conn_read_buf_bytes: usize = 16 * 1024;
const conn_write_buf_bytes: usize = 64 * 1024;

// ── Netlayer lifecycle ───────────────────────────────────────────────────────

/// Create an iroh netlayer (one bound endpoint) allocating through the
/// library-owned allocator. `secret_seed`/`secret_seed_len` is either a 32-byte
/// Ed25519 secret key (borrowed) or empty (`secret_seed_len == 0`) for a fresh
/// random key; any other length is `PANCAKE_ERR_INVALID_ARGUMENT`.
/// `reachability` is one of `PANCAKE_IROH_REACH_*` and is mandatory — it decides
/// whether the endpoint uses relays or a discovery service, with no default; an
/// unknown value is `PANCAKE_ERR_INVALID_ARGUMENT`. Release with
/// `pancake_iroh_netlayer_release` after releasing every connection made from
/// it.
pub export fn pancake_iroh_netlayer_new(
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    reachability: u32,
    out_netlayer: ?*?*PancakeIrohNetlayer,
) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const seed = decodeSeed(secret_seed, secret_seed_len) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const reach = reachabilityFromC(reachability) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    return netlayerNewIn(c.library_allocator, seed, reach, slot);
}

/// As `pancake_iroh_netlayer_new`, allocating the netlayer, endpoint, and every
/// per-connection buffer through `context`.
pub export fn pancake_iroh_netlayer_new_in(
    context: ?*PancakeContext,
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    reachability: u32,
    out_netlayer: ?*?*PancakeIrohNetlayer,
) i32 {
    const cc = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const seed = decodeSeed(secret_seed, secret_seed_len) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const reach = reachabilityFromC(reachability) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    return netlayerNewIn(cc.allocator, seed, reach, slot);
}

fn decodeSeed(seed: ?[*]const u8, seed_len: usize) error{InvalidSeed}!?*const [32]u8 {
    if (seed_len == 0) return null;
    if (seed_len != 32) return error.InvalidSeed;
    const p = seed orelse return error.InvalidSeed;
    return @ptrCast(p);
}

/// Map a raw `PANCAKE_IROH_REACH_*` value to the resident's `Reachability`, or
/// null for an unrecognized posture so the caller is refused rather than handed
/// a silent default.
fn reachabilityFromC(reachability: u32) ?iroh.Reachability {
    inline for (@typeInfo(iroh.Reachability).@"enum".fields) |field| {
        if (reachability == field.value) return @enumFromInt(field.value);
    }
    return null;
}

fn netlayerNewIn(alloc: std.mem.Allocator, seed: ?*const [32]u8, reachability: iroh.Reachability, slot: *?*PancakeIrohNetlayer) i32 {
    const payload = alloc.create(NetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .threaded = std.Io.Threaded.init(alloc, .{}),
        .resident = undefined,
        .allocator = alloc,
    };
    // `Threaded.io()` borrows `&payload.threaded`, valid because `payload` is
    // heap-pinned; the resident captures it for the connections it mints.
    payload.resident = iroh.Resident.init(payload.threaded.io(), seed, reachability) catch {
        payload.threaded.deinit();
        alloc.destroy(payload);
        setLastError("iroh netlayer_new: endpoint bind failed", .{});
        return PANCAKE_ERR_IO;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Close the endpoint without releasing the handle: a blocked
/// `pancake_iroh_netlayer_accept` returns `PANCAKE_ERR_IO` and subsequent dials
/// fail. Idempotent. The shutdown lever for a host whose accept loop parks on
/// another thread.
pub export fn pancake_iroh_netlayer_close(netlayer: ?*PancakeIrohNetlayer) void {
    const nl = nlFromOpaque(netlayer) orelse return;
    nl.resident.close();
}

/// Release the netlayer, its endpoint, and the runtime. Every connection made
/// from it must already be released.
pub export fn pancake_iroh_netlayer_release(netlayer: ?*PancakeIrohNetlayer) void {
    const nl = nlFromOpaque(netlayer) orelse return;
    const alloc = nl.allocator;
    nl.resident.deinit();
    nl.threaded.deinit();
    alloc.destroy(nl);
}

// ── Addressing ───────────────────────────────────────────────────────────────

/// Write this endpoint's id — its Ed25519 public key, the dialable designator —
/// into `out` as lowercase hex, and the byte count into `out_len`. `cap` must
/// be at least the id length (64) or the call is `PANCAKE_ERR_INVALID_ARGUMENT`.
/// No terminator is written.
pub export fn pancake_iroh_netlayer_node_id(
    netlayer: ?*PancakeIrohNetlayer,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse return PANCAKE_ERR_NULL_POINTER;
    const len_slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;

    var buf: [iroh.node_id_len]u8 = undefined;
    const id = nl.resident.nodeId(&buf);
    if (id.len == 0) {
        setLastError("node_id: sidecar reported no endpoint id", .{});
        return PANCAKE_ERR_IO;
    }
    if (cap < id.len) return PANCAKE_ERR_INVALID_ARGUMENT;
    @memcpy(dest[0..id.len], id);
    len_slot.* = id.len;
    return PANCAKE_OK;
}

/// Write this endpoint's comma-separated direct socket addresses into `out`
/// (the hint string a partner passes to `pancake_iroh_netlayer_connect`) and
/// the byte count into `out_len`. A buffer too small for the list is
/// `PANCAKE_ERR_INVALID_ARGUMENT`; an endpoint with no direct addresses writes
/// zero bytes and returns `PANCAKE_OK`. No terminator is written.
pub export fn pancake_iroh_netlayer_direct_addrs(
    netlayer: ?*PancakeIrohNetlayer,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse return PANCAKE_ERR_NULL_POINTER;
    const len_slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;

    const addrs = nl.resident.directAddrs(dest[0..cap]) catch {
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    len_slot.* = addrs.len;
    return PANCAKE_OK;
}

// ── Connections ──────────────────────────────────────────────────────────────

/// Dial a partner by endpoint id and return an owned connection framing on
/// `codec`, refusing inbound frames over `max_frame_bytes`. `node_id` is the
/// partner's canonical id (borrowed for the call); `addr_hints` is its
/// comma-separated direct-address list (borrowed; empty cannot dial, since the
/// sidecar runs no lookup service). Blocking. `PANCAKE_ERR_INVALID_ARGUMENT`
/// for a bad codec, a zero frame cap, or a malformed id/hint;
/// `PANCAKE_ERR_IO` (see `pancake_last_error`) when the dial fails. Release with
/// `pancake_iroh_conn_release`.
pub export fn pancake_iroh_netlayer_connect(
    netlayer: ?*PancakeIrohNetlayer,
    node_id: ?[*]const u8,
    node_id_len: usize,
    addr_hints: ?[*]const u8,
    addr_hints_len: usize,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeIrohConn,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const id_ptr = node_id orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    const hints: []const u8 = if (addr_hints) |h| h[0..addr_hints_len] else &.{};

    const payload = beginConn(nl.allocator, codec_id, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = nl.resident.dialStream(nl.allocator, id_ptr[0..node_id_len], hints, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        return dialErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Block until a partner dials this endpoint, returning an owned connection
/// framing on `codec`. Same argument and release contract as
/// `pancake_iroh_netlayer_connect`. `PANCAKE_ERR_IO` when the endpoint is
/// closed (the shutdown lever) or the accept faults.
pub export fn pancake_iroh_netlayer_accept(
    netlayer: ?*PancakeIrohNetlayer,
    codec: u32,
    max_frame_bytes: usize,
    out_conn: ?*?*PancakeIrohConn,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    const codec_id = codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    if (max_frame_bytes == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    const payload = beginConn(nl.allocator, codec_id, max_frame_bytes) orelse return PANCAKE_ERR_INTERNAL;
    payload.stream = nl.resident.acceptStream(nl.allocator, payload.read_buf, payload.write_buf) catch |err| {
        abortConn(payload);
        return acceptErrorToCode(err);
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Block for one whole frame as an owned managed frame (the caller `release`s
/// it, or hands it to `pancake_peer_feed_owned`). `PANCAKE_ERR_CLOSED` on
/// graceful end of stream, `PANCAKE_ERR_IO` on a QUIC fault, `_MALFORMED` /
/// `_FRAME_TOO_LARGE` for a bad frame.
pub export fn pancake_iroh_conn_read_frame(conn: ?*PancakeIrohConn, out_frame: ?*PancakeManagedFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;

    const f = net_adapter.readFrameFrom(
        payload.stream.readerInterface(),
        payload.allocator,
        payload.codec_id,
        payload.max_frame_bytes,
        &payload.spill,
    ) catch |err| return frameReadErrorToCode(err);

    slot.* = c.tryManagedFrame(payload.allocator, f) catch {
        var owned = f;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Write one frame's borrowed bytes and flush. `PANCAKE_ERR_IO` on a QUIC fault.
pub export fn pancake_iroh_conn_write_frame(conn: ?*PancakeIrohConn, frame_in: ?*const PancakeFrame) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;

    net_adapter.writeFrameTo(payload.stream.writerInterface(), bytes_ptr[0..borrowed.len]) catch |err| {
        setLastError("write_frame: {s}", .{@errorName(err)});
        return PANCAKE_ERR_IO;
    };
    return PANCAKE_OK;
}

/// Close the connection and free the handle; do not use `conn` afterward.
pub export fn pancake_iroh_conn_release(conn: ?*PancakeIrohConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

// ── Connection buffer/payload lifecycle ──────────────────────────────────────

fn beginConn(alloc: std.mem.Allocator, codec_id: model.CodecId, max_frame_bytes: usize) ?*ConnPayload {
    const read_buf = alloc.alloc(u8, @min(max_frame_bytes, conn_read_buf_bytes)) catch return null;
    const write_buf = alloc.alloc(u8, @min(max_frame_bytes, conn_write_buf_bytes)) catch {
        alloc.free(read_buf);
        return null;
    };
    const payload = alloc.create(ConnPayload) catch {
        alloc.free(read_buf);
        alloc.free(write_buf);
        return null;
    };
    payload.* = .{
        .stream = undefined,
        .spill = .{},
        .codec_id = codec_id,
        .max_frame_bytes = max_frame_bytes,
        .read_buf = read_buf,
        .write_buf = write_buf,
        .allocator = alloc,
    };
    return payload;
}

/// Release a payload whose `.stream` was never installed (a failed dial/accept).
fn abortConn(payload: *ConnPayload) void {
    const alloc = payload.allocator;
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

/// Release a fully established connection: the spill, the sidecar connection and
/// its stream wrapper, then the buffers and the payload.
fn destroyConn(payload: *ConnPayload) void {
    const alloc = payload.allocator;
    payload.spill.deinit(alloc);
    payload.stream.deinit();
    alloc.free(payload.read_buf);
    alloc.free(payload.write_buf);
    alloc.destroy(payload);
}

fn frameReadErrorToCode(err: net_adapter.FrameError) i32 {
    return switch (err) {
        error.Closed => PANCAKE_ERR_CLOSED,
        error.MalformedFrame => PANCAKE_ERR_MALFORMED,
        error.FrameTooLarge => PANCAKE_ERR_FRAME_TOO_LARGE,
        error.TruncatedFrame => blk: {
            setLastError("read_frame: stream closed mid-frame", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.ConnectionLost => blk: {
            setLastError("read_frame: connection lost", .{});
            break :blk PANCAKE_ERR_IO;
        },
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn dialErrorToCode(err: net_adapter.DialError) i32 {
    return switch (err) {
        error.InvalidAddress => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => blk: {
            setLastError("connect: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_IO;
        },
    };
}

fn acceptErrorToCode(err: net_adapter.AcceptError) i32 {
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        else => blk: {
            setLastError("accept: {s}", .{@errorName(err)});
            break :blk PANCAKE_ERR_IO;
        },
    };
}

fn nlFromOpaque(netlayer: ?*PancakeIrohNetlayer) ?*NetlayerPayload {
    const ptr = netlayer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn connFromOpaque(conn: ?*PancakeIrohConn) ?*ConnPayload {
    const ptr = conn orelse return null;
    return @ptrCast(@alignCast(ptr));
}
