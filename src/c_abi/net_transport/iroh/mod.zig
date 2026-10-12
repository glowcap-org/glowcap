//! The iroh transport's public C ABI, a host-driven netlayer boundary for C,
//! the encrypted-QUIC sibling of the blocking TCP endpoints.
//!
//! This is a *separate artifact* from `libglowcap_ocapn` (ADR-0055): it links the
//! Rust iroh sidecar, so folding it into the pure-Zig core would drag cargo
//! into every consumer of the protocol library. The artifact
//! (`libglowcap_net_transport_iroh`) is a *companion*, not a superset: it imports only the
//! shared vocabulary leaf (`@import("c_abi_shared")`, frame/context types,
//! codes, allocation, the last-error slot), so it exports just the `glowcap_iroh_*`
//! family and shares no core symbol with `libglowcap_ocapn`. A consumer links both
//! libraries (core for the peer surface, this for the transport) and reuses the
//! shared types by layout, exactly as a C program including both headers does.
//! The core archives never import this file and stay cargo-free.
//!
//! There is one I/O model (ADR-0057): an event-driven readiness loop, armed at
//! construction, that serves many connections from one host thread. The netlayer
//! hands back a single OS readiness fd (`glowcap_iroh_netlayer_readiness_fd`) the
//! host parks on with its own poller. When it signals,
//! `glowcap_iroh_netlayer_drain_ready` drains the pending readiness records,
//! `_try_accept` claims accepts, and `_conn_try_read` / `_conn_try_write` move
//! raw bytes without ever parking on a connection. Because no call parks on a
//! specific connection, releasing one cannot race a parked read. The host frames
//! the raw bytes itself (the peer's stream-input path), the same shape the TCP
//! endpoints' consumer uses. The one departure from TCP is addressing: there is
//! no `host:port`. A peer is dialed by its endpoint id (the canonical
//! lowercase-hex designator `glowcap_iroh_netlayer_node_id` prints). Whether a
//! dial also needs a comma-separated direct-address hint
//! (`glowcap_iroh_netlayer_direct_addrs`) depends on the netlayer's chosen
//! reachability: a `direct` endpoint dials by id plus hints, a discovery
//! endpoint resolves the partner by id alone.
//!
//! Those same calls are the raw byte channel a byte-transparent relay needs for
//! an iroh leg (ADR-0086). One leg composes `glowcap_iroh_netlayer_new`, its
//! `readiness_fd` and `drain_ready`, the `_start_connect` /
//! `_finish_connect` lifecycle, `_conn_try_read` / `_conn_try_write`, then
//! `_conn_release` and `glowcap_iroh_netlayer_release`.
//! There is no channel object over them, because the wait a channel needs is
//! your own reactor's, and only the caller can hold it.
//!
//! Symbol names avoid the sidecar's own `glowcap_iroh_sidecar_*`
//! exports (`glowcap_iroh_sidecar_connect_blocking`, `glowcap_iroh_sidecar_conn_close`,
//! …): this public surface is `glowcap_iroh_netlayer_*` and
//! `glowcap_iroh_conn_{try_read,try_write}` / `_release`, so the private
//! byte-level seam and the public loop-level ABI share no prefix and the two
//! C ABIs link into one library without colliding.
//!
//! Threading: a `GlowcapIrohConn` is single-owner like a peer: serialize every
//! call on one onto one thread. Distinct connections are independent. Run the
//! netlayer's readiness wait (the host's poll on `readiness_fd`) and its
//! `drain_ready` on one thread per netlayer, serialized against `_release` of the
//! netlayer.

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");

const iroh = @import("iroh");
const ownership = @import("ownership.zig");
const loop = @import("loop.zig");
const provider = @import("provider.zig");

// The shared C-ABI vocabulary leaf (types, codes, allocation policy,
// managed-frame machinery, and the per-thread last-error slot), not the
// `c_abi` root. Importing the leaf gives this transport ABI the same frame and
// context types `glowcap_ocapn.h` declares, with its own compiled copy of the helpers
// and last-error slot, and pulls *none* of libglowcap_ocapn's exported `glowcap_*`
// surface. That is the companion split (ADR-0055): `libglowcap_net_transport_iroh` carries
// only the `glowcap_iroh_*` family and shares core types by layout, exactly as
// a C consumer that includes both `glowcap_ocapn.h` and `glowcap_net_transport_iroh.h` does.
const c = @import("c_abi_shared");

pub const contract_layouts = [_]c.archive_contract.Layout{
    c.archive_contract.layout("GLOWCAP_IROH_READY_EVENT", GlowcapIrohReadyEvent),
    c.archive_contract.layout("GLOWCAP_IROH_CONFIG", GlowcapIrohConfig),
};
pub const GLOWCAP_IROH_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "iroh",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);

pub export fn glowcap_iroh_archive_fingerprint() u64 {
    return GLOWCAP_IROH_ARCHIVE_FINGERPRINT;
}

/// The netlayer handle owns the one iroh endpoint (and, through it, the
/// sidecar's runtime) plus the `std.Io.Threaded` the resident captures. Every
/// connection made from it borrows the endpoint, so the netlayer must outlive
/// every connection.
pub const GlowcapIrohNetlayer = ownership.GlowcapIrohNetlayer;
/// One QUIC connection carrying one OCapN session, framed on the netlayer's
/// codec. Owned by the caller. Released with `glowcap_iroh_conn_release`.
pub const GlowcapIrohConn = ownership.GlowcapIrohConn;

const NetlayerPayload = ownership.NetlayerPayload;

const GlowcapContext = c.GlowcapContext;
const setLastError = c.setLastError;

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_BUFFER_TOO_SMALL = c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from. See `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// Copy the calling thread's last iroh-transport error message into `out_buf`,
/// the iroh sibling of `glowcap_last_error`. `libglowcap_net_transport_iroh` carries its own
/// per-thread slot (a separate compiled copy of the shared leaf's slot), so a
/// `glowcap_iroh_*` call that returns `GLOWCAP_ERR_IO` records its cause here,
/// readable independently of libglowcap_ocapn's. Copies at most `cap - 1` bytes and
/// always NUL-terminates when `cap > 0`. `out_buf == NULL` or `cap == 0`
/// queries the length. Returns the full message length, or 0 when none is set.
pub export fn glowcap_iroh_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's iroh-transport last error slot.
pub export fn glowcap_iroh_clear_last_error() void {
    c.lastErrorClear();
}

/// Readiness event bits, mirroring the header's `GLOWCAP_IROH_EV_*`. Defined
/// from the resident's `loop_ev_*` values so the compiler holds this mirror and
/// the resident/sidecar values in lockstep. The generated header renders these
/// values. A drained record may carry several at once.
pub const GLOWCAP_IROH_EV_READABLE = loop.GLOWCAP_IROH_EV_READABLE;
pub const GLOWCAP_IROH_EV_WRITABLE = loop.GLOWCAP_IROH_EV_WRITABLE;
pub const GLOWCAP_IROH_EV_CLOSED = loop.GLOWCAP_IROH_EV_CLOSED;
pub const GLOWCAP_IROH_EV_ACCEPT = loop.GLOWCAP_IROH_EV_ACCEPT;
pub const GLOWCAP_IROH_EV_CONNECT = loop.GLOWCAP_IROH_EV_CONNECT;

/// Reachability postures, mirroring the header's `GLOWCAP_IROH_REACH_*`.
/// Defined from the resident's `Reachability` enum so the compiler holds the
/// mirror in lockstep. The generated header and the binding constant modules
/// (`gen-binding-constants`, `gen-ts-abi`) render these values rather than
/// hand-typing them.
pub const GLOWCAP_IROH_REACH_DIRECT: u32 = @backingInt(iroh.Reachability.direct);
pub const GLOWCAP_IROH_REACH_DISCOVERY: u32 = @backingInt(iroh.Reachability.discovery);
pub const GLOWCAP_IROH_REACH_DISCOVERY_NO_RELAY: u32 = @backingInt(iroh.Reachability.discovery_no_relay);
pub const GLOWCAP_IROH_REACH_LOCAL_DISCOVERY: u32 = @backingInt(iroh.Reachability.local_discovery);

/// The posture a Host redeems a hint-less handoff give under until the embedder
/// sets one: discovery, the maximal-reach choice. The netlayer constructor
/// still takes no default. This names the redeem knob's one starting value so
/// every binding initializes from the same fact instead of hand-typing it.
pub const GLOWCAP_IROH_REACH_REDEEM_DEFAULT: u32 = GLOWCAP_IROH_REACH_DISCOVERY;
pub const GLOWCAP_IROH_NODE_ID_BYTES: usize = iroh.node_id_len;
pub const GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES: usize = iroh.max_direct_address_bytes;
pub const GLOWCAP_IROH_READ_CHUNK_BYTES: usize = iroh.read_chunk_bytes;

/// One readiness record handed to the host by `glowcap_iroh_netlayer_drain_ready`:
/// the subject that became ready and the `GLOWCAP_IROH_EV_*` bitset. `subject`
/// is zero for accept, a caller request id for connect completion, and otherwise
/// the stable id returned by `glowcap_iroh_conn_id`.
pub const GlowcapIrohReadyEvent = loop.GlowcapIrohReadyEvent;

/// One iroh endpoint's configuration, filled by the caller and passed to
/// `glowcap_iroh_netlayer_new` / `_new_in`. `reachability` is mandatory (one of
/// `GLOWCAP_IROH_REACH_*`, an unknown value is refused). `connect_timeout_ms` is
/// the per-endpoint stream-establishment deadline in milliseconds (the dial's
/// connect + first-stream open and each accepted stream ride it), with 0 meaning
/// glowcap's thirty seconds.
///
/// Every 0 here means glowcap's number, never the QUIC stack's own. That
/// distinction matters most for `idle_timeout_ms` below, where glowcap's
/// replaces a longer one the stack would otherwise use.
///
/// `idle_timeout_ms` bounds how long a connection survives without a packet
/// from the far end. **This is the authority for what that setting means**. The
/// residents and every binding's own config mirror this struct and point here.
///
/// It decides how quickly a peer that was killed rather than closed stops
/// counting as present. Such a peer sends nothing, and UDP has no equivalent of
/// the FIN a dying TCP process gets from the operating system, so nothing else
/// ends the connection. An embedder that reads a live session as presence wants
/// a shorter one than the default.
///
/// There is no keep-alive beside it. The two are one decision, and a timeout
/// shorter than its own heartbeat drops connections whose peers are answering,
/// so the transport derives the heartbeat from this value.
///
/// `worker_threads` sizes this endpoint's runtime. 0 takes glowcap's two. That
/// is glowcap's number rather than the async runtime's own, which sizes itself
/// to the machine's cores. It is a per-endpoint cost, so a process holding many
/// endpoints, or one endpoint holding many connections, is the caller that
/// should name it, and naming the core count is how a caller asks for what the
/// runtime would have chosen alone.
///
/// Callers must zero-initialize the whole struct before
/// filling the fields they set, so a field added in a later version defaults to
/// 0 rather than reading a caller's stack garbage. The `extern struct`
/// counterpart of the header's `GlowcapIrohConfig`.
pub const GlowcapIrohConfig = extern struct {
    reachability: u32,
    connect_timeout_ms: u64,
    idle_timeout_ms: u64,
    worker_threads: u32,
};

// ── Netlayer lifecycle ───────────────────────────────────────────────────────

/// Create an iroh netlayer (one bound endpoint) allocating through the
/// library-owned allocator. `secret_seed`/`secret_seed_len` is either a 32-byte
/// Ed25519 secret key (borrowed) or empty (`secret_seed_len == 0`) for a fresh
/// random key. Any other length is `GLOWCAP_ERR_INVALID_ARGUMENT`.
/// `config` carries the mandatory reachability (`GLOWCAP_IROH_REACH_*`, an
/// unknown value or a null `config` is `GLOWCAP_ERR_INVALID_ARGUMENT` /
/// `GLOWCAP_ERR_NULL_POINTER`) and the optional `connect_timeout_ms` (0 = the
/// glowcap's own default). Binds the endpoint and arms
/// the readiness loop, so the returned netlayer is immediately driveable through
/// `glowcap_iroh_netlayer_readiness_fd`. `GLOWCAP_ERR_IO` (see
/// `glowcap_iroh_last_error`) if the endpoint cannot bind or the loop cannot arm.
/// Release with `glowcap_iroh_netlayer_release` (prefer releasing every connection
/// made from it first, leftovers are drained on release).
fn irohNetlayerNew(
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const GlowcapIrohConfig,
    out_netlayer: ?*?*GlowcapIrohNetlayer,
) i32 {
    const slot = out_netlayer orelse return GLOWCAP_ERR_NULL_POINTER;
    const args = decodeNewArgs(secret_seed, secret_seed_len, config) catch |err|
        return newArgsError(err);
    return netlayerNewIn(c.library_allocator, args.seed, args.config, slot);
}

pub export fn glowcap_iroh_netlayer_new(
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const GlowcapIrohConfig,
    out_netlayer: ?*?*GlowcapIrohNetlayer,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        irohNetlayerNew(secret_seed, secret_seed_len, config, out_netlayer),
        out_error,
        error_cap,
        out_error_len,
    );
}

/// As `glowcap_iroh_netlayer_new`, allocating the netlayer, endpoint, and every
/// per-connection buffer through `context`.
fn irohNetlayerNewIn(
    context: ?*GlowcapContext,
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const GlowcapIrohConfig,
    out_netlayer: ?*?*GlowcapIrohNetlayer,
) i32 {
    const cc = c.ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return GLOWCAP_ERR_NULL_POINTER;
    const args = decodeNewArgs(secret_seed, secret_seed_len, config) catch |err|
        return newArgsError(err);
    return netlayerNewIn(cc.allocator(), args.seed, args.config, slot);
}

pub export fn glowcap_iroh_netlayer_new_in(
    context: ?*GlowcapContext,
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const GlowcapIrohConfig,
    out_netlayer: ?*?*GlowcapIrohNetlayer,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(
        irohNetlayerNewIn(context, secret_seed, secret_seed_len, config, out_netlayer),
        out_error,
        error_cap,
        out_error_len,
    );
}

fn decodeSeed(seed: ?[*]const u8, seed_len: usize) error{InvalidSeed}!?*const [32]u8 {
    if (seed_len == 0) return null;
    if (seed_len != 32) return error.InvalidSeed;
    const p = seed orelse return error.InvalidSeed;
    return @ptrCast(p);
}

const NewArgs = struct {
    seed: ?*const [32]u8,
    config: iroh.Resident.Config,
};

fn decodeNewArgs(
    secret_seed: ?[*]const u8,
    secret_seed_len: usize,
    config: ?*const GlowcapIrohConfig,
) error{ NullConfig, InvalidSeed, InvalidReachability }!NewArgs {
    const cfg = config orelse return error.NullConfig;
    return .{
        .seed = try decodeSeed(secret_seed, secret_seed_len),
        .config = .{
            .reachability = reachabilityFromC(cfg.reachability) orelse
                return error.InvalidReachability,
            .connect_timeout_ms = cfg.connect_timeout_ms,
            .idle_timeout_ms = cfg.idle_timeout_ms,
            .worker_threads = cfg.worker_threads,
        },
    };
}

fn newArgsError(err: error{ NullConfig, InvalidSeed, InvalidReachability }) i32 {
    switch (err) {
        error.NullConfig => {
            setLastError("iroh netlayer_new: config is required", .{});
            return GLOWCAP_ERR_NULL_POINTER;
        },
        error.InvalidSeed => setLastError(
            "iroh netlayer_new: secret_seed must be empty or exactly 32 bytes",
            .{},
        ),
        error.InvalidReachability => setLastError(
            "iroh netlayer_new: reachability is not a GLOWCAP_IROH_REACH_* value",
            .{},
        ),
    }
    return GLOWCAP_ERR_INVALID_ARGUMENT;
}

/// Map a raw `GLOWCAP_IROH_REACH_*` value to the resident's `Reachability`, or
/// null for an unrecognized posture so the caller is refused rather than handed
/// a silent default.
fn reachabilityFromC(reachability: u32) ?iroh.Reachability {
    inline for (@typeInfo(iroh.Reachability).@"enum".field_values) |value| {
        if (reachability == value) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn netlayerNewIn(alloc: std.mem.Allocator, seed: ?*const [32]u8, resident_config: iroh.Resident.Config, slot: *?*GlowcapIrohNetlayer) i32 {
    slot.* = null;
    const payload = alloc.create(NetlayerPayload) catch |err|
        return c.failInternal("iroh netlayer_new", err);
    payload.* = .{
        .threaded = std.Io.Threaded.init(alloc, .{}),
        .resident = undefined,
        .allocator = alloc,
        .references = .init(1),
        .config = resident_config,
    };
    // `Threaded.io()` borrows `&payload.threaded`, valid because `payload` is
    // heap-pinned; the resident captures it for the connections it mints.
    payload.resident = iroh.Resident.init(payload.threaded.io(), seed, resident_config) catch |err| {
        payload.threaded.deinit();
        alloc.destroy(payload);
        return c.failIo("iroh netlayer_new endpoint bind", err);
    };
    // One I/O model: arm the readiness loop now, so a constructed netlayer is
    // immediately a scale-capable endpoint with a live `readiness_fd`. There is
    // no un-armed mode to toggle into.
    if (!payload.resident.enableLoop()) {
        var cleanup_failure: ?anyerror = null;
        payload.resident.deinit() catch |err| {
            cleanup_failure = err;
        };
        payload.threaded.deinit();
        alloc.destroy(payload);
        if (cleanup_failure) |err|
            setLastError("iroh netlayer_new: sidecar could not arm the readiness loop; cleanup: {s}", .{@errorName(err)})
        else
            setLastError("iroh netlayer_new: sidecar could not arm the readiness loop", .{});
        return GLOWCAP_ERR_IO;
    }
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

/// Close the endpoint without releasing the handle: subsequent dials fail and
/// the readiness loop winds down. Idempotent. The shutdown lever for a host
/// whose readiness wait parks on another thread.
pub export fn glowcap_iroh_netlayer_close(netlayer: ?*GlowcapIrohNetlayer) void {
    const nl = nlFromOpaque(netlayer) orelse return;
    nl.resident.close();
}

/// Release the netlayer, its endpoint, and the runtime. Every connection made
/// from it must already be released.
fn irohNetlayerRelease(netlayer: ?*GlowcapIrohNetlayer) i32 {
    const nl = nlFromOpaque(netlayer) orelse return GLOWCAP_OK;
    if (nl.release()) |failure|
        return c.failIo("iroh netlayer release", failure);
    return GLOWCAP_OK;
}

pub export fn glowcap_iroh_netlayer_release(
    netlayer: ?*GlowcapIrohNetlayer,
    out_error: ?[*]u8,
    error_cap: usize,
    out_error_len: ?*usize,
) i32 {
    c.lastErrorClear();
    if (!c.optionalCallErrorOutputIsValid(out_error, error_cap, out_error_len)) {
        return GLOWCAP_ERR_NULL_POINTER;
    }
    return c.captureCallError(irohNetlayerRelease(netlayer), out_error, error_cap, out_error_len);
}

// ── Addressing ───────────────────────────────────────────────────────────────

/// Write this endpoint's id, its Ed25519 public key, the dialable designator,
/// into `out` as lowercase hex, and the byte count into `out_len`. `cap` must
/// be at least `GLOWCAP_IROH_NODE_ID_BYTES`.
/// No terminator is written.
pub export fn glowcap_iroh_netlayer_node_id(
    netlayer: ?*GlowcapIrohNetlayer,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    c.lastErrorClear();
    const nl = nlFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = out orelse return GLOWCAP_ERR_NULL_POINTER;
    const len_slot = out_len orelse return GLOWCAP_ERR_NULL_POINTER;

    var buf: [iroh.node_id_len]u8 = undefined;
    const id = nl.resident.nodeId(&buf);
    if (id.len == 0) {
        setLastError("node_id: sidecar reported no endpoint id", .{});
        return GLOWCAP_ERR_IO;
    }
    if (cap < id.len) return GLOWCAP_ERR_BUFFER_TOO_SMALL;
    @memcpy(dest[0..id.len], id);
    len_slot.* = id.len;
    return GLOWCAP_OK;
}

/// Write this endpoint's comma-separated direct socket addresses into `out`
/// (the hint string a partner passes to `glowcap_iroh_netlayer_start_connect`) and
/// the byte count into `out_len`. A null output is allowed only with `cap == 0`
/// to query the size. A short buffer writes the required byte count before
/// returning `GLOWCAP_ERR_BUFFER_TOO_SMALL`. A list larger than
/// `GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES` is invalid. No terminator is written.
pub export fn glowcap_iroh_netlayer_direct_addrs(
    netlayer: ?*GlowcapIrohNetlayer,
    out: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    c.lastErrorClear();
    const nl = nlFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const len_slot = out_len orelse return GLOWCAP_ERR_NULL_POINTER;
    var empty: [0]u8 = .{};
    const dest: []u8 = if (cap == 0) empty[0..] else (out orelse return GLOWCAP_ERR_NULL_POINTER)[0..cap];

    const addrs = nl.resident.directAddrs(dest) catch {
        setLastError("direct_addrs: sidecar failed to report endpoint addresses", .{});
        return GLOWCAP_ERR_IO;
    };
    switch (addrs) {
        .too_small => |required| {
            len_slot.* = required;
            if (required > iroh.max_direct_address_bytes) {
                setLastError("direct_addrs: endpoint address list exceeds {d} bytes", .{iroh.max_direct_address_bytes});
                return GLOWCAP_ERR_INVALID_ARGUMENT;
            }
            return GLOWCAP_ERR_BUFFER_TOO_SMALL;
        },
        .written => |written| {
            len_slot.* = written.len;
            if (written.len > iroh.max_direct_address_bytes) {
                setLastError("direct_addrs: endpoint address list exceeds {d} bytes", .{iroh.max_direct_address_bytes});
                return GLOWCAP_ERR_INVALID_ARGUMENT;
            }
            return GLOWCAP_OK;
        },
    }
}

// ── Event-loop and provider archive index ────────────────────────────────────
//
// The leaves own the raw readiness/connection projection and the generic
// multiplexed-provider adapter. These declarations keep mod.zig as the one
// public archive inventory without a second implementation or compatibility
// wrapper.

pub const glowcap_iroh_conn_release = loop.glowcap_iroh_conn_release;
pub const glowcap_iroh_conn_id = loop.glowcap_iroh_conn_id;
pub const glowcap_iroh_conn_remote_node_id = loop.glowcap_iroh_conn_remote_node_id;
pub const glowcap_iroh_netlayer_readiness_fd = loop.glowcap_iroh_netlayer_readiness_fd;
pub const glowcap_iroh_netlayer_drain_ready = loop.glowcap_iroh_netlayer_drain_ready;
pub const glowcap_iroh_netlayer_try_accept = loop.glowcap_iroh_netlayer_try_accept;
pub const glowcap_iroh_netlayer_start_connect = loop.glowcap_iroh_netlayer_start_connect;
pub const glowcap_iroh_netlayer_finish_connect = loop.glowcap_iroh_netlayer_finish_connect;
pub const glowcap_iroh_netlayer_cancel_connect = loop.glowcap_iroh_netlayer_cancel_connect;
pub const glowcap_iroh_conn_try_read = loop.glowcap_iroh_conn_try_read;
pub const glowcap_iroh_conn_try_write = loop.glowcap_iroh_conn_try_write;
pub const glowcap_iroh_transport_provider = provider.glowcap_iroh_transport_provider;

comptime {
    // Root every annotated export in this archive, including functions whose
    // implementation lives in a leaf. This is the same one-inventory contract
    // as the Host archive entry root: an alias is the public index, while this
    // walk makes omission from the linked artifact impossible.
    for (symbols.symbols) |symbol| _ = @field(@This(), symbol.name);
}

fn nlFromOpaque(netlayer: ?*GlowcapIrohNetlayer) ?*NetlayerPayload {
    return ownership.netlayerFromOpaque(netlayer);
}
