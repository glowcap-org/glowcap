//! The iroh transport's public C ABI — a host-driven netlayer boundary for C,
//! the encrypted-QUIC sibling of the blocking TCP endpoints.
//!
//! This is a *separate artifact* from `libpancake_ocapn` (ADR-0055): it links the
//! Rust iroh sidecar, so folding it into the pure-Zig core would drag cargo
//! into every consumer of the protocol library. The artifact
//! (`libpancake_net_transport_iroh`) is a *companion*, not a superset: it imports only the
//! shared vocabulary leaf (`@import("c_abi_shared")` — frame/context types,
//! codes, allocation, the last-error slot), so it exports just the `pancake_iroh_*`
//! family and shares no core symbol with `libpancake_ocapn`. A consumer links both
//! libraries (core for the peer surface, this for the transport) and reuses the
//! shared types by layout, exactly as a C program including both headers does.
//! The core archives never import this file and stay cargo-free.
//!
//! There is one I/O model (ADR-0057): an event-driven readiness loop, armed at
//! construction, that serves many connections from one host thread. The netlayer
//! hands back a single OS readiness fd (`pancake_iroh_netlayer_readiness_fd`) the
//! host parks on with its own poller; when it signals,
//! `pancake_iroh_netlayer_drain_ready` drains the pending readiness records,
//! `_try_accept` claims accepts, and `_conn_try_read` / `_conn_try_write` move
//! raw bytes without ever parking on a connection. Because no call parks on a
//! specific connection, releasing one cannot race a parked read. The host frames
//! the raw bytes itself (the peer's stream-input path), the same shape the TCP
//! endpoints' consumer uses. The one departure from TCP is addressing: there is
//! no `host:port`. A peer is dialed by its endpoint id (the canonical
//! lowercase-hex designator `pancake_iroh_netlayer_node_id` prints). Whether a
//! dial also needs a comma-separated direct-address hint
//! (`pancake_iroh_netlayer_direct_addrs`) depends on the netlayer's chosen
//! reachability: a `direct` endpoint dials by id plus hints, a discovery
//! endpoint resolves the partner by id alone.
//!
//! Those same calls are the raw byte channel a byte-transparent relay needs for
//! an iroh leg (ADR-0086). One leg composes `pancake_iroh_netlayer_new`, its
//! `readiness_fd` and `drain_ready`, the `_start_connect` /
//! `_finish_connect` lifecycle, `_conn_try_read` / `_conn_try_write`, then
//! `_conn_release` and `pancake_iroh_netlayer_release`.
//! There is no channel object over them, because the wait a channel needs is
//! your own reactor's, and only the caller can hold it.
//!
//! Symbol names deliberately avoid the sidecar's own `pancake_iroh_sidecar_*`
//! exports (`pancake_iroh_sidecar_connect_blocking`, `pancake_iroh_sidecar_conn_close`,
//! …): this public surface is `pancake_iroh_netlayer_*` and
//! `pancake_iroh_conn_{try_read,try_write}` / `_release`, so the private
//! byte-level seam and the public loop-level ABI share no prefix and the two
//! C ABIs link into one library without colliding.
//!
//! Threading: a `PancakeIrohConn` is single-owner like a peer — serialize every
//! call on one onto one thread. Distinct connections are independent. Run the
//! netlayer's readiness wait (the host's poll on `readiness_fd`) and its
//! `drain_ready` on one thread per netlayer, serialized against `_release` of the
//! netlayer.

const std = @import("std");

const net = @import("net");
const iroh = @import("iroh");

// The shared C-ABI vocabulary leaf — types, codes, allocation policy,
// managed-frame machinery, and the per-thread last-error slot — *not* the
// `c_abi` root. Importing the leaf gives this transport ABI the same frame and
// context types `pancake_ocapn.h` declares, with its own compiled copy of the helpers
// and last-error slot, and pulls *none* of libpancake_ocapn's exported `pancake_*`
// surface. That is the companion split (ADR-0055): `libpancake_net_transport_iroh` carries
// only the `pancake_iroh_*` family and shares core types by layout, exactly as
// a C consumer that includes both `pancake_ocapn.h` and `pancake_net_transport_iroh.h` does.
const c = @import("c_abi_shared");

/// The netlayer handle owns the one iroh endpoint (and, through it, the
/// sidecar's runtime) plus the `std.Io.Threaded` the resident captures. Every
/// connection made from it borrows the endpoint, so the netlayer must outlive
/// every connection.
pub const PancakeIrohNetlayer = opaque {};
/// One QUIC connection carrying one OCapN session, framed on the netlayer's
/// codec. Owned by the caller; released with `pancake_iroh_conn_release`.
pub const PancakeIrohConn = opaque {};

const PancakeContext = c.PancakeContext;
const setLastError = c.setLastError;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_BUFFER_TOO_SMALL = c.PANCAKE_ERR_BUFFER_TOO_SMALL;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// Copy the calling thread's last iroh-transport error message into `out_buf`,
/// the iroh sibling of `pancake_last_error`. `libpancake_net_transport_iroh` carries its own
/// per-thread slot (a separate compiled copy of the shared leaf's slot), so a
/// `pancake_iroh_*` call that returns `PANCAKE_ERR_IO` records its cause here,
/// readable independently of libpancake_ocapn's. Copies at most `cap - 1` bytes and
/// always NUL-terminates when `cap > 0`; `out_buf == NULL` or `cap == 0`
/// queries the length. Returns the full message length, or 0 when none is set.
pub export fn pancake_iroh_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's iroh-transport last error slot.
pub export fn pancake_iroh_clear_last_error() void {
    c.lastErrorClear();
}

const NetlayerPayload = struct {
    threaded: std.Io.Threaded,
    resident: iroh.Resident,
    /// The allocator the netlayer and every connection made from it use, so a
    /// connection frees through the same policy as the netlayer that minted it.
    allocator: std.mem.Allocator,
};

/// One loop connection: the sidecar handle, its stable readiness identity, and
/// a back-pointer to the netlayer whose endpoint owns it. No read/write buffers
/// and no spill: the host
/// frames the raw bytes this hands out (the peer's stream-input path), the same
/// shape `tcp` uses, so framing state lives in the host's peer.
const ConnPayload = struct {
    allocator: std.mem.Allocator,
    conn_id: usize,
    conn: *anyopaque,
    netlayer: *NetlayerPayload,
};

// ── The event-driven loop surface (ADR-0057) ─────────────────────────────────
//
// The netlayer's one I/O model: serve many connections from one host thread. The
// loop is armed at construction, so the host parks on the netlayer's single
// readiness fd (`readiness_fd`), drains the ready records (`drain_ready`) when it
// signals, and drives non-blocking byte I/O on the named connections, the same
// model the Zig `iroh.Backend` uses, exposed so a language binding can own the
// loop. No call ever parks on a specific connection, so releasing one never
// races a parked read.

/// Returned by the non-blocking calls when the operation cannot make progress
/// without blocking, the canonical base-ABI `PANCAKE_ERR_WOULD_BLOCK` (-7), so
/// the iroh loop surface speaks the same would-block code as the rest of
/// the C ABI, not the sidecar's private byte-level sentinel.
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;

/// Readiness event bits, mirroring the header's `PANCAKE_IROH_EV_*`. Defined
/// from the resident's `loop_ev_*` values so the compiler holds this mirror and
/// the resident/sidecar values in lockstep; the generated header renders these
/// values. A drained record may carry several at once.
pub const PANCAKE_IROH_EV_READABLE: u32 = iroh.loop_ev_readable;
pub const PANCAKE_IROH_EV_WRITABLE: u32 = iroh.loop_ev_writable;
pub const PANCAKE_IROH_EV_CLOSED: u32 = iroh.loop_ev_closed;
pub const PANCAKE_IROH_EV_ACCEPT: u32 = iroh.loop_ev_accept;
pub const PANCAKE_IROH_EV_CONNECT: u32 = iroh.loop_ev_connect;

/// Reachability postures, mirroring the header's `PANCAKE_IROH_REACH_*`.
/// Defined from the resident's `Reachability` enum so the compiler holds the
/// mirror in lockstep; the generated header and the binding constant modules
/// (`gen-binding-constants`, `gen-ts-abi`) render these values rather than
/// hand-typing them.
pub const PANCAKE_IROH_REACH_DIRECT: u32 = @intFromEnum(iroh.Reachability.direct);
pub const PANCAKE_IROH_REACH_DISCOVERY: u32 = @intFromEnum(iroh.Reachability.discovery);
pub const PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY: u32 = @intFromEnum(iroh.Reachability.discovery_no_relay);
pub const PANCAKE_IROH_REACH_LOCAL_DISCOVERY: u32 = @intFromEnum(iroh.Reachability.local_discovery);

/// The posture a Host redeems a hint-less handoff give under until the embedder
/// sets one: discovery, the maximal-reach choice. The netlayer constructor
/// still takes no default — this names the redeem knob's one starting value so
/// every binding initializes from the same fact instead of hand-typing it.
pub const PANCAKE_IROH_REACH_REDEEM_DEFAULT: u32 = PANCAKE_IROH_REACH_DISCOVERY;

/// One readiness record handed to the host by `pancake_iroh_netlayer_drain_ready`:
/// the subject that became ready and the `PANCAKE_IROH_EV_*` bitset. `subject`
/// is zero for accept, a caller request id for connect completion, and otherwise
/// the stable id returned by `pancake_iroh_conn_id`.
pub const PancakeIrohReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

/// One iroh endpoint's configuration, filled by the caller and passed to
/// `pancake_iroh_netlayer_new` / `_new_in`. `reachability` is mandatory (one of
/// `PANCAKE_IROH_REACH_*`; an unknown value is refused). `connect_timeout_ms` is
/// the per-endpoint stream-establishment deadline in milliseconds — the dial's
/// connect + first-stream open and each accepted stream ride it — with 0 meaning
/// the built-in default. Callers must zero-initialize the whole struct before
/// filling the fields they set, so a field added in a later version defaults to
/// 0 rather than reading a caller's stack garbage. The `extern struct`
/// counterpart of the header's `PancakeIrohConfig`.
pub const PancakeIrohConfig = extern struct {
    reachability: u32,
    connect_timeout_ms: u64,
};

// ── Netlayer lifecycle ───────────────────────────────────────────────────────

/// Create an iroh netlayer (one bound endpoint) allocating through the
/// library-owned allocator. `secret_seed`/`secret_seed_len` is either a 32-byte
/// Ed25519 secret key (borrowed) or empty (`secret_seed_len == 0`) for a fresh
/// random key; any other length is `PANCAKE_ERR_INVALID_ARGUMENT`.
/// `config` carries the mandatory reachability (`PANCAKE_IROH_REACH_*`; an
/// unknown value or a null `config` is `PANCAKE_ERR_INVALID_ARGUMENT` /
/// `PANCAKE_ERR_NULL_POINTER`) and the optional `connect_timeout_ms` (0 = the
/// built-in default). Binds the endpoint and arms
/// the readiness loop, so the returned netlayer is immediately driveable through
/// `pancake_iroh_netlayer_readiness_fd`; `PANCAKE_ERR_IO` (see
/// `pancake_iroh_last_error`) if the endpoint cannot bind or the loop cannot arm.
/// Release with `pancake_iroh_netlayer_release` (prefer releasing every connection
/// made from it first; leftovers are drained on release).
pub export fn pancake_iroh_netlayer_new(
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const PancakeIrohConfig,
    out_netlayer: ?*?*PancakeIrohNetlayer,
) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    const seed = decodeSeed(secret_seed, secret_seed_len) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const reach = reachabilityFromC(cfg.reachability) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    return netlayerNewIn(c.library_allocator, seed, reach, cfg.connect_timeout_ms, slot);
}

/// As `pancake_iroh_netlayer_new`, allocating the netlayer, endpoint, and every
/// per-connection buffer through `context`.
pub export fn pancake_iroh_netlayer_new_in(
    context: ?*PancakeContext,
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const PancakeIrohConfig,
    out_netlayer: ?*?*PancakeIrohNetlayer,
) i32 {
    const cc = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    const seed = decodeSeed(secret_seed, secret_seed_len) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const reach = reachabilityFromC(cfg.reachability) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    return netlayerNewIn(cc.allocator(), seed, reach, cfg.connect_timeout_ms, slot);
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

fn netlayerNewIn(alloc: std.mem.Allocator, seed: ?*const [32]u8, reachability: iroh.Reachability, connect_timeout_ms: u64, slot: *?*PancakeIrohNetlayer) i32 {
    const payload = alloc.create(NetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .threaded = std.Io.Threaded.init(alloc, .{}),
        .resident = undefined,
        .allocator = alloc,
    };
    // `Threaded.io()` borrows `&payload.threaded`, valid because `payload` is
    // heap-pinned; the resident captures it for the connections it mints.
    payload.resident = iroh.Resident.init(payload.threaded.io(), seed, .{ .reachability = reachability, .connect_timeout_ms = connect_timeout_ms }) catch {
        payload.threaded.deinit();
        alloc.destroy(payload);
        setLastError("iroh netlayer_new: endpoint bind failed", .{});
        return PANCAKE_ERR_IO;
    };
    // One I/O model: arm the readiness loop now, so a constructed netlayer is
    // immediately a scale-capable endpoint with a live `readiness_fd`. There is
    // no un-armed mode to toggle into.
    if (!payload.resident.enableLoop()) {
        payload.resident.deinit();
        payload.threaded.deinit();
        alloc.destroy(payload);
        setLastError("iroh netlayer_new: sidecar could not arm the readiness loop", .{});
        return PANCAKE_ERR_IO;
    }
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Close the endpoint without releasing the handle: subsequent dials fail and
/// the readiness loop winds down. Idempotent. The shutdown lever for a host
/// whose readiness wait parks on another thread.
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
/// be at least the id length (64) or the call is `PANCAKE_ERR_BUFFER_TOO_SMALL`.
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
    if (cap < id.len) return PANCAKE_ERR_BUFFER_TOO_SMALL;
    @memcpy(dest[0..id.len], id);
    len_slot.* = id.len;
    return PANCAKE_OK;
}

/// Write this endpoint's comma-separated direct socket addresses into `out`
/// (the hint string a partner passes to `pancake_iroh_netlayer_start_connect`) and
/// the byte count into `out_len`. A buffer too small for the list is
/// `PANCAKE_ERR_BUFFER_TOO_SMALL`; an endpoint with no direct addresses writes
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
        return PANCAKE_ERR_BUFFER_TOO_SMALL;
    };
    len_slot.* = addrs.len;
    return PANCAKE_OK;
}

// ── Connections ──────────────────────────────────────────────────────────────

/// Close the connection and free the handle; do not use `conn` afterward.
/// A later readiness record may still carry its stable id; the host drops that
/// record because its own id-to-connection row is already gone. No call ever
/// parks on the connection, so this free cannot race a parked read.
pub export fn pancake_iroh_conn_release(conn: ?*PancakeIrohConn) void {
    const payload = connFromOpaque(conn) orelse return;
    destroyConn(payload);
}

/// Stable readiness identity for this connection. It is unique for the
/// netlayer's lifetime and is not derived from the handle allocation address.
pub export fn pancake_iroh_conn_id(conn: ?*PancakeIrohConn) usize {
    const payload = connFromOpaque(conn) orelse return 0;
    return payload.conn_id;
}

// ── The event-driven loop surface (ADR-0057) ─────────────────────────────────

/// The netlayer's single read-only OS readiness fd — the borrowed read end of the
/// sidecar's wakeup channel, readable whenever fresh readiness records are
/// pending. Register it once with your poller (`poll`/`epoll`/`kqueue`, or a
/// language runtime's reactor); when it signals, call
/// `pancake_iroh_netlayer_drain_ready`. The fd is owned by the netlayer and
/// stays valid until `pancake_iroh_netlayer_release` — do not close it; `dup` it
/// if your runtime needs to own its copy. Negative only for a null handle.
pub export fn pancake_iroh_netlayer_readiness_fd(netlayer: ?*PancakeIrohNetlayer) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    return nl.resident.readinessFd();
}

/// Clear the fd's coalesced wake bytes, then drain pending readiness records
/// into `out_events` (`out_cap` entries,
/// caller-owned) without blocking: `PANCAKE_OK` with the drained count (0 when
/// none are ready) written to `out_count`, or a `PANCAKE_ERR_*` on fault
/// (`out_count` untouched). Call it when `readiness_fd` signals, then again until
/// it drains fewer than `out_cap` records (more may be queued than one call
/// drains), before re-parking on the fd. A record for a connection already
/// released still carries only its stable id, so the host can discard it
/// without dereferencing freed storage. The drain touches only the endpoint,
/// never a per-connection buffer. Run it on one thread per netlayer, serialized
/// against `_release` of the netlayer.
pub export fn pancake_iroh_netlayer_drain_ready(
    netlayer: ?*PancakeIrohNetlayer,
    out_events: ?[*]PancakeIrohReadyEvent,
    out_cap: usize,
    out_count: ?*usize,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest_ptr = out_events orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_count orelse return PANCAKE_ERR_NULL_POINTER;
    if (out_cap == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    const n = drainInto(nl, dest_ptr[0..out_cap]);
    if (n < 0) return PANCAKE_ERR_INTERNAL;
    slot.* = @intCast(n);
    return PANCAKE_OK;
}

/// Claim one accepted connection (already non-blocking), returning `PANCAKE_OK`
/// with the owned connection in `out_conn`, or `PANCAKE_ERR_WOULD_BLOCK` when
/// none is pending. Drive it after `drain_ready` reports an accept record.
/// Release with `pancake_iroh_conn_release`.
pub export fn pancake_iroh_netlayer_try_accept(
    netlayer: ?*PancakeIrohNetlayer,
    out_conn: ?*?*PancakeIrohConn,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    const raw = nl.resident.loopTryAccept() orelse return PANCAKE_ERR_WOULD_BLOCK;
    const payload = registerNbConn(nl, raw) orelse {
        nl.resident.loopConnClose(raw);
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Admit one non-blocking dial. `request_id` must be nonzero and unique among
/// this netlayer's live requests. PANCAKE_OK promises exactly one EV_CONNECT
/// carrying that id; a synchronous error promises no event.
pub export fn pancake_iroh_netlayer_start_connect(
    netlayer: ?*PancakeIrohNetlayer,
    request_id: usize,
    node_id: ?[*]const u8,
    node_id_len: usize,
    addr_hints: ?[*]const u8,
    addr_hints_len: usize,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const id_ptr = node_id orelse return PANCAKE_ERR_NULL_POINTER;
    const hints: []const u8 = if (addr_hints) |h|
        h[0..addr_hints_len]
    else if (addr_hints_len == 0)
        &.{}
    else
        return PANCAKE_ERR_NULL_POINTER;
    if (request_id == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    const target = iroh.DialResolver.resolve(iroh.transport_name, id_ptr[0..node_id_len], hints) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    nl.resident.loopStartConnectResolved(request_id, target.id, target.hints) catch |err| return dialErrorToCode(err);
    return PANCAKE_OK;
}

/// Consume one terminal dial after EV_CONNECT. Connection allocation and
/// registration happen here, on the readiness owner thread.
pub export fn pancake_iroh_netlayer_finish_connect(
    netlayer: ?*PancakeIrohNetlayer,
    request_id: usize,
    out_conn: ?*?*PancakeIrohConn,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_conn orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    const raw = nl.resident.loopFinishConnect(request_id) catch |err| return dialErrorToCode(err);
    const payload = registerNbConn(nl, raw) orelse {
        nl.resident.loopConnClose(raw);
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Cancel one admitted dial. Its sole EV_CONNECT still arrives and must be
/// finished, which consumes the endpoint-owned terminal row.
pub export fn pancake_iroh_netlayer_cancel_connect(
    netlayer: ?*PancakeIrohNetlayer,
    request_id: usize,
) i32 {
    const nl = nlFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (request_id == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    nl.resident.loopCancelConnect(request_id);
    return PANCAKE_OK;
}

/// Non-blocking read of raw inbound bytes into `buf`: `PANCAKE_OK` with the byte
/// count read written to `out_read`, `PANCAKE_ERR_WOULD_BLOCK` when nothing is
/// buffered yet, `PANCAKE_ERR_CLOSED` on a clean end of stream, or
/// `PANCAKE_ERR_IO` on a fault. `out_read` is untouched on any non-OK return.
/// The host frames these bytes itself (feed them to its peer's stream-input
/// path), the same shape `pancake_tcp_conn_read_frame`'s consumer uses for TCP.
pub export fn pancake_iroh_conn_try_read(conn: ?*PancakeIrohConn, buf: ?[*]u8, len: usize, out_read: ?*usize) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_read orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.netlayer.resident.loopTryRead(payload.conn, dest[0..len]);
    if (n == iroh.loop_would_block) return PANCAKE_ERR_WOULD_BLOCK;
    if (n == 0) return PANCAKE_ERR_CLOSED;
    if (n < 0) {
        setLastError("conn_try_read: connection lost", .{});
        return PANCAKE_ERR_IO;
    }
    slot.* = @intCast(n);
    return PANCAKE_OK;
}

/// Non-blocking write of `len` raw bytes from `buf`: `PANCAKE_OK` with the count
/// written to `out_written` (the whole slice, since the sidecar buffer is
/// all-or-nothing), `PANCAKE_ERR_WOULD_BLOCK` when the outbound buffer is at its
/// bound (retry the same bytes after the next writable record), or
/// `PANCAKE_ERR_IO` on a fault. `out_written` is untouched on any non-OK return.
pub export fn pancake_iroh_conn_try_write(conn: ?*PancakeIrohConn, buf: ?[*]const u8, len: usize, out_written: ?*usize) i32 {
    const payload = connFromOpaque(conn) orelse return PANCAKE_ERR_NULL_POINTER;
    const src = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_written orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.netlayer.resident.loopTryWrite(payload.conn, src[0..len]);
    if (n == iroh.loop_would_block) return PANCAKE_ERR_WOULD_BLOCK;
    if (n < 0) {
        setLastError("conn_try_write: connection lost", .{});
        return PANCAKE_ERR_IO;
    }
    slot.* = @intCast(n);
    return PANCAKE_OK;
}

/// Wrap a freshly accepted/dialed raw loop handle in a `ConnPayload`. Returns
/// null (caller frees the raw handle) on allocation failure.
fn registerNbConn(nl: *NetlayerPayload, raw: *anyopaque) ?*ConnPayload {
    const payload = nl.allocator.create(ConnPayload) catch return null;
    const conn_id = nl.resident.loopConnId(raw);
    if (conn_id == 0) {
        nl.allocator.destroy(payload);
        return null;
    }
    payload.* = .{
        .allocator = nl.allocator,
        .conn_id = conn_id,
        .conn = raw,
        .netlayer = nl,
    };
    return payload;
}

/// Drain pending readiness records into `dest` without translating their stable
/// subjects. Never drains more than `dest` can hold, so no record is lost to a
/// short output buffer.
fn drainInto(nl: *NetlayerPayload, dest: []PancakeIrohReadyEvent) isize {
    var raw: [128]iroh.ReadyEvent = undefined;
    var out_n: usize = 0;
    while (out_n < dest.len) {
        const want = @min(dest.len - out_n, raw.len);
        const n = nl.resident.drainReady(raw[0..want]);
        if (n < 0) return n;
        if (n == 0) break;
        const count: usize = @intCast(n);
        for (raw[0..count]) |rec| {
            dest[out_n] = .{ .subject = rec.subject, .events = rec.events };
            out_n += 1;
        }
        if (count < want) break;
    }
    return @intCast(out_n);
}

// ── Connection payload lifecycle ─────────────────────────────────────────────

/// Release a loop connection and its sidecar handle. The host removes its
/// stable-id routing row before calling this function.
fn destroyConn(payload: *ConnPayload) void {
    const alloc = payload.allocator;
    payload.netlayer.resident.loopConnClose(payload.conn);
    alloc.destroy(payload);
}

fn dialErrorToCode(err: net.netlayer.DialError) i32 {
    return switch (err) {
        // Permanent under ADR-0082 `isTransient` — bindings must not discovery-retry these.
        error.InvalidAddress, error.ConnectionRefused => PANCAKE_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.NetworkUnreachable, error.TimedOut, error.ConnectionLost => blk: {
            setLastError("connect: {s}", .{@errorName(err)});
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
