//! The C ABI for `libpancake`. It is deliberately boring.
//!
//! The thing that makes this layer easy to use is that ownership is right there in
//! the type names, so you never have to dig through comments to find it. A
//! `PancakeFrame` is borrowed: it's yours for the length of one call, and you keep
//! owning the bytes. A `PancakeManagedFrame` is owned and releases itself: it's
//! yours to keep, and you call its `release` exactly once when you're done. Return
//! codes are a plain `i32`, either `PANCAKE_OK` or a negative `PANCAKE_ERR_*`.
//! Handles like `PancakePeer` are opaque. And an event hands you back the original
//! wire frame, in whatever codec the session negotiated, with no re-encoding in
//! between.
//!
//! This file is the crate root: it owns the shared vocabulary (return codes,
//! discriminants, the C-visible types) and the per-thread last-error boundary,
//! then pulls in the handle-family files so every `export fn` they declare is
//! compiled into the library. The families are `context` (the allocation policy
//! and `PancakeContext`), `frame` (managed-frame machinery and event/shape
//! conversions), `peer` (the `PancakePeer` driving surface), and `endpoint` (the
//! blocking TCP handles). Each family `@import`s this root for the shared types
//! and codes; this root re-exports their `export fn`s so the header generator,
//! which reflects over the `c_abi` namespace, sees the full ABI in one place.
//!
//! Threading contract: a `PancakePeer` is a single-owner state machine and is not
//! safe to drive from more than one thread at once. Serialize every call on a
//! given peer — including `feed`, `step`, `take_outbound`, `poll_event`, and the
//! typed send/poll calls — onto one thread (or behind your own lock). When a peer
//! runs over the blocking TCP netlayer, that means the I/O backend and the
//! application share one thread per peer; the allocator behind a context may still
//! be called from the netlayer's threads, which is why a host allocator must be
//! thread-safe. `pancake_last_error` reports the *calling* thread's last error, so
//! read it on the same thread that made the failing call.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");

const context = @import("context.zig");
const frame = @import("frame.zig");
const peer = @import("peer.zig");
const endpoint = @import("endpoint.zig");
const inproc = @import("inproc.zig");
const uri = @import("uri.zig");

/// ABI version the library implements. While `major` is 0 the ABI is unstable
/// (see `pancake.h`); the shared library's soname tracks `major`.
pub const PANCAKE_VERSION_MAJOR: u32 = 0;
pub const PANCAKE_VERSION_MINOR: u32 = 1;
pub const PANCAKE_VERSION_PATCH: u32 = 0;

/// Report the ABI version the linked library implements. Any out-pointer may be
/// null to skip that component. Lets a consumer detect header/library skew by
/// comparing against the `PANCAKE_VERSION_*` macros it compiled against.
pub export fn pancake_abi_version(out_major: ?*u32, out_minor: ?*u32, out_patch: ?*u32) void {
    if (out_major) |p| p.* = PANCAKE_VERSION_MAJOR;
    if (out_minor) |p| p.* = PANCAKE_VERSION_MINOR;
    if (out_patch) |p| p.* = PANCAKE_VERSION_PATCH;
}

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
/// A typed `poll_event_*` was called but the next event is a different kind.
/// The event is left queued; route on `pancake_peer_peek_event` first.
pub const PANCAKE_ERR_WRONG_EVENT: i32 = -12;
/// A value *sent* across the typed surface uses a variant the C ABI cannot carry:
/// a `handoff` argument, or a `sturdy`/`broken` reference target. Those are
/// refused loudly with this code rather than marshalled wrong. (`set`, `tagged`,
/// and `keyword` arguments do carry, both directions.) A *received* `sturdy` or
/// `broken` reference is a separate case: it projects lossily — the kind is
/// reported but its swissnum/detail is dropped — since the deliver was authored
/// by the partner, not refused on this consumer's behalf.
pub const PANCAKE_ERR_UNSUPPORTED_VALUE: i32 = -13;
/// A promise the partner broke: a `send`/`fetch` the remote side refused with a
/// reason, not a fault in this peer or the transport. No C ABI function *returns*
/// this — a break arrives as a `PANCAKE_RESOLUTION_BREAK` resolve event carrying
/// its message — but it is the shared code a binding surfaces when it turns that
/// break into its own error type, so the reason is distinct from a real failure.
pub const PANCAKE_ERR_BROKEN: i32 = -14;
/// A lookup found nothing: the `pancake_locator_hint` key names no hint on the
/// locator. Distinct from `_INVALID_ARGUMENT` (the request was malformed) — the
/// request was well-formed, the thing asked for is simply absent.
pub const PANCAKE_ERR_NOT_FOUND: i32 = -15;

/// Codec selector: the wire grammar a peer's session speaks
/// (`pancake_peer_new_negotiated`) and the framing an endpoint delimits
/// frames with (`pancake_tcp_connect` / `pancake_tcp_accept`). The
/// two must match — the endpoint splits the stream with the same grammar the
/// session encodes in.
pub const PANCAKE_CODEC_SYRUP: u32 = 0;
pub const PANCAKE_CODEC_CAPNP: u32 = 1;

/// Decode a `PANCAKE_CODEC_*` value, or null for anything outside the family.
pub fn codecFromC(codec: u32) ?model.CodecId {
    return switch (codec) {
        PANCAKE_CODEC_SYRUP => .syrup,
        PANCAKE_CODEC_CAPNP => .capnp,
        else => null,
    };
}

/// `captp_version` selector for `pancake_peer_new_negotiated`: the
/// authenticated v1.0 profile, or PreSpec, the upstream OCapN prerelease
/// profile.
pub const PANCAKE_CAPTP_VERSION_V1_0: u32 = 0;
pub const PANCAKE_CAPTP_VERSION_PRE_SPEC: u32 = 1;

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
/// Word-aligned frame storage: the pointer must be 8-byte aligned and the
/// length divisible by 8. Anything else is refused with
/// `PANCAKE_ERR_INVALID_ARGUMENT`.
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;
/// The no-event sentinel: `pancake_event_release` zeroes a released event's
/// `kind` to this. Never returned by a successful poll.
pub const PANCAKE_EVENT_NONE: u32 = 0;
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
pub const PANCAKE_EVENT_UNTAG: u32 = 11;

/// A frame whose bytes are *borrowed* from the C caller for the duration of one
/// call. The engine reads them during the call and retains nothing; the caller
/// keeps ownership and frees them on its own schedule. Used for inbound feeds.
pub const PancakeFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

/// Release hook a `PancakeManagedFrame` carries; the caller invokes it once to
/// free the frame.
pub const ReleaseFn = *const fn (*PancakeManagedFrame) callconv(.c) void;

/// A frame the engine *owns* and hands to the C caller (outbound frames, event
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

// ── Allocation context ───────────────────────────────────────────────────────

/// Host allocation callbacks (`pancake_context_new_with_allocator`). `alloc`
/// returns memory aligned to `alignment` (a power of two) or null on failure;
/// `free` receives the same `size`/`alignment` the allocation was made with.
/// `user_data` is passed back to every callback unchanged. The callbacks must be
/// thread-safe: a context backing a TCP netlayer is driven from its threaded I/O
/// backend.
///
/// The surface is deliberately `alloc` + `free` only. With both sides told the
/// size, the only sound resize policy for an opaque host allocator is "never
/// resize in place" (see `HostAllocator`), which keeps `free`'s size argument
/// exactly equal to `alloc`'s — correct even for a size-tracking host allocator.
/// A `realloc` callback cannot preserve that invariant or guarantee alignment of
/// the relocated block, so it is intentionally absent rather than a footgun.
pub const PancakeAllocFn = *const fn (user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const PancakeFreeFn = *const fn (user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void;

/// Host allocator specification passed by value to
/// `pancake_context_new_with_allocator`. `alloc` and `free` are required;
/// `user_data` may be null.
pub const PancakeAllocator = extern struct {
    alloc: ?PancakeAllocFn,
    free: ?PancakeFreeFn,
    user_data: ?*anyopaque,
};

pub const PancakeContext = opaque {};

// ── Typed OCapN driving surface types ────────────────────────────────────────

pub const PANCAKE_REF_NEAR: u32 = 0;
pub const PANCAKE_REF_FAR: u32 = 1;
pub const PANCAKE_REF_PROMISE: u32 = 2;
pub const PANCAKE_REF_STURDY: u32 = 3;
pub const PANCAKE_REF_BROKEN: u32 = 4;

/// `sub_kind` for a near/far reference: whether the position names an object or a
/// promise (the `desc:import-object` vs `desc:import-promise` distinction). The
/// SUB names are their own namespace so a `kind` value (`PANCAKE_REF_PROMISE`)
/// can never be mistaken for a `sub_kind` value or assigned to the wrong field
/// unnoticed.
pub const PANCAKE_REF_SUB_OBJECT: u32 = 0;
pub const PANCAKE_REF_SUB_PROMISE: u32 = 1;

pub const PANCAKE_ARG_INTEGER: u32 = 0;
pub const PANCAKE_ARG_FLOAT64: u32 = 1;
pub const PANCAKE_ARG_BOOLEAN: u32 = 2;
pub const PANCAKE_ARG_BYTES: u32 = 3;
pub const PANCAKE_ARG_STRING: u32 = 4;
pub const PANCAKE_ARG_SYMBOL: u32 = 5;
pub const PANCAKE_ARG_VOID: u32 = 6;
pub const PANCAKE_ARG_REFERENCE: u32 = 7;
pub const PANCAKE_ARG_LIST: u32 = 8;
/// A `set` reuses `items`; a `tagged` reuses `bytes` (the tag) and `items` (the
/// value list); a `keyword` reuses `bytes`.
pub const PANCAKE_ARG_SET: u32 = 9;
pub const PANCAKE_ARG_TAGGED: u32 = 10;
pub const PANCAKE_ARG_KEYWORD: u32 = 11;
/// An arbitrary-precision OCapN Integer outside `int64_t`: `bytes`/`bytes_len`
/// carry the canonical decimal magnitude (ASCII digits, no leading zero) and
/// `boolean` carries the sign (1 = negative). A magnitude that fits `int64_t`
/// belongs in `PANCAKE_ARG_INTEGER` and is refused here.
pub const PANCAKE_ARG_BIG_INTEGER: u32 = 12;

pub const PANCAKE_RESOLUTION_FULFILL: u32 = 0;
pub const PANCAKE_RESOLUTION_BREAK: u32 = 1;

/// Wire spelling of the empty locator hints in `pancake_peer_start_session`.
/// `_EMPTY_MAP` encodes the empty hints as `{}`; `_EMPTY_FALSE` encodes them as
/// the boolean `#f`, the spelling Goblins emits and re-encodes when it checks a
/// signed locator. The two are semantically the same empty hints, but a
/// signature computed over one spelling does not verify over the other.
pub const PANCAKE_HINTS_EMPTY_MAP: u32 = 0;
pub const PANCAKE_HINTS_EMPTY_FALSE: u32 = 1;

/// The well-known bootstrap export position every OCapN peer answers `fetch`
/// on — the one authoritative value, surfaced from the engine so a consumer
/// never re-derives the magic `0`.
pub const PANCAKE_BOOTSTRAP_POSITION: u64 = engine.BOOTSTRAP_POSITION;

/// A capability reference. `kind` selects the meaning of `id`: a `_NEAR` export
/// position, a `_FAR` import position, or a `_PROMISE` answer position.
/// `sub_kind` is the
/// object/promise distinction for near/far. `_STURDY` and `_BROKEN` carry no
/// payload here (use the resolution's break message for a broken target).
pub const PancakeReference = extern struct {
    kind: u32,
    sub_kind: u32,
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`/`_KEYWORD`; `items`/
/// `items_len` carry a `_LIST`'s or `_SET`'s elements. A `_TAGGED` uses both:
/// the tag in `bytes`/`bytes_len` and the value list in `items`/`items_len`.
/// A `_BIG_INTEGER` carries the canonical decimal magnitude in `bytes`/
/// `bytes_len` (ASCII digits, no leading zero) and the sign in `boolean`
/// (1 = negative); a magnitude that fits `int64_t` belongs in `_INTEGER` and
/// is refused here. On a projected (received) value the pointers alias the
/// owning arena and are valid until the matching `*_release`.
pub const PancakeArgument = extern struct {
    kind: u32,
    boolean: u32,
    integer: i64,
    float64: f64,
    bytes: ?[*]const u8,
    bytes_len: usize,
    reference: PancakeReference,
    items: ?[*]const PancakeArgument,
    items_len: usize,
};

/// A received `op:deliver` projected to C. `args` aliases an internal arena;
/// release the whole projection with `pancake_deliver_release` exactly once.
pub const PancakeDeliver = extern struct {
    target: PancakeReference,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    has_answer: u32,
    answer: u64,
    owner: ?*anyopaque,
};

/// A received `op:resolve` projected to C. `resolution_kind` selects `fulfill`
/// (a value) or the `break_message` bytes. Release with `pancake_resolve_release`.
pub const PancakeResolve = extern struct {
    answer: u64,
    resolution_kind: u32,
    fulfill: PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
    owner: ?*anyopaque,
};

/// `PancakeLastAbort.domain`: which layer classified the failure. Codec is a
/// decode/encode malformation, session is a state-machine refusal, foreign is
/// a host-internal failure (allocation, …).
pub const PANCAKE_ABORT_DOMAIN_CODEC: u32 = 0;
pub const PANCAKE_ABORT_DOMAIN_SESSION: u32 = 1;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN: u32 = 2;

/// The typed cause of the peer's most recent local dispatch failure, projected
/// to C — the ABI counterpart of `engine.Peer.lastAbort`. `domain` is a
/// `PANCAKE_ABORT_DOMAIN_*` value. When `has_kind` is nonzero, `kind_name`
/// is the wire name of the projected `op:abort` kind (e.g. "MalformedFrame");
/// when zero, the failure projected no abort (a closed session, an allocation
/// failure). All byte views are process-static — read them, never free them.
pub const PancakeLastAbort = extern struct {
    domain: u32,
    has_kind: u32,
    kind_name: ?[*]const u8,
    kind_name_len: usize,
    message: ?[*]const u8,
    message_len: usize,
    error_name: ?[*]const u8,
    error_name_len: usize,
};

// ── TCP endpoint handles ─────────────────────────────────────────────────────

pub const PancakeTcpNetlayer = opaque {};
pub const PancakeTcpConn = opaque {};
pub const PancakeTcpListener = opaque {};

// ── In-process endpoint handles ──────────────────────────────────────────────

pub const PancakeInprocNetlayer = opaque {};
pub const PancakeInprocConn = opaque {};
pub const PancakeInprocListener = opaque {};

// ── OCapN locator handle ─────────────────────────────────────────────────────

/// A parsed OCapN locator: the value a `pancake_uri_parse_*` returns, read
/// through the `pancake_locator_*` accessors and freed with
/// `pancake_locator_release`. One handle carries both a peer and a sturdyref (a
/// sturdyref is a peer locator plus a swissnum), so a parsed peer reports a
/// zero-length swissnum.
pub const PancakeLocator = opaque {};

// ── Shared error projection ──────────────────────────────────────────────────

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy (`engine.abort_projection.classify`) so the C codes
/// cannot drift from the abort projection: codec/decode malformations report
/// `CODEC`, session state-machine refusals (a partner protocol violation, a
/// resource cap, an already-closed session) report `SESSION`, and host-internal
/// failures (allocation, …) report `INTERNAL`.
pub fn feedErrorToCode(err: anyerror) i32 {
    return switch (engine.abort_projection.classify(err).domain) {
        .codec => PANCAKE_ERR_CODEC,
        .session => PANCAKE_ERR_SESSION,
        .foreign => PANCAKE_ERR_INTERNAL,
    };
}

// ── Per-thread last error ────────────────────────────────────────────────────
//
// The Zig side would otherwise hide the concrete `ReadFailed` / `WriteFailed`
// behind a flat `PANCAKE_ERR_IO`. This per-thread slot re-exposes it: a function
// that returns `_IO` first records a human-readable cause here.

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

pub fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch blk: {
        // Message longer than the slot: keep the truncated prefix.
        break :blk last_error_buf[0..];
    };
    last_error_len = written.len;
}

/// Copy the calling thread's last error message into `out_buf`. Copies at most
/// `cap - 1` bytes and always NUL-terminates when `cap > 0`. Returns the full
/// message length; to receive the whole message pass a buffer of that length
/// plus one. `out_buf == NULL` or `cap == 0` queries the length. errno-style:
/// meaningful only right after a call that returned a cause-bearing code
/// (`_IO`, or the address-parse `_INVALID_ARGUMENT`); a later success does not
/// clear it. Returns 0 when none is set.
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

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family files; the plain `@import`s
// above already compile them into the library. These re-exports also surface them
// as members of the `c_abi` namespace so `tools/header_gen.zig`, which reflects
// over `c_abi`, sees the full ABI from one root.

pub const pancake_context_new = context.pancake_context_new;
pub const pancake_context_new_with_allocator = context.pancake_context_new_with_allocator;
pub const pancake_context_release = context.pancake_context_release;

pub const pancake_managed_frame_release = frame.pancake_managed_frame_release;
pub const pancake_event_release = frame.pancake_event_release;

pub const pancake_peer_new = peer.pancake_peer_new;
pub const pancake_peer_new_in = peer.pancake_peer_new_in;
pub const pancake_peer_new_negotiated = peer.pancake_peer_new_negotiated;
pub const pancake_peer_new_negotiated_in = peer.pancake_peer_new_negotiated_in;
pub const pancake_peer_new_raw_open = peer.pancake_peer_new_raw_open;
pub const pancake_peer_new_raw_open_in = peer.pancake_peer_new_raw_open_in;
pub const pancake_peer_release = peer.pancake_peer_release;
pub const pancake_peer_feed_borrowed = peer.pancake_peer_feed_borrowed;
pub const pancake_peer_feed_owned = peer.pancake_peer_feed_owned;
pub const pancake_peer_recv_stream = peer.pancake_peer_recv_stream;
pub const pancake_peer_step = peer.pancake_peer_step;
pub const pancake_peer_take_outbound = peer.pancake_peer_take_outbound;
pub const pancake_peer_poll_event = peer.pancake_peer_poll_event;
pub const pancake_peer_start_session = peer.pancake_peer_start_session;
pub const pancake_peer_session_is_open = peer.pancake_peer_session_is_open;
pub const pancake_peer_codec = peer.pancake_peer_codec;
pub const pancake_peer_register_bootstrap_cap = peer.pancake_peer_register_bootstrap_cap;
pub const pancake_peer_send_bootstrap_fetch = peer.pancake_peer_send_bootstrap_fetch;
pub const pancake_peer_register_export = peer.pancake_peer_register_export;
pub const pancake_peer_next_export = peer.pancake_peer_next_export;
pub const pancake_peer_next_answer = peer.pancake_peer_next_answer;
pub const pancake_peer_last_abort = peer.pancake_peer_last_abort;
pub const pancake_peer_register_import = peer.pancake_peer_register_import;
pub const pancake_peer_peek_event = peer.pancake_peer_peek_event;
pub const pancake_peer_send_deliver = peer.pancake_peer_send_deliver;
pub const pancake_peer_send_resolve = peer.pancake_peer_send_resolve;
pub const pancake_peer_send_gc_export = peer.pancake_peer_send_gc_export;
pub const pancake_peer_send_gc_answer = peer.pancake_peer_send_gc_answer;
pub const pancake_peer_poll_event_deliver = peer.pancake_peer_poll_event_deliver;
pub const pancake_peer_poll_event_resolve = peer.pancake_peer_poll_event_resolve;
pub const pancake_deliver_release = peer.pancake_deliver_release;
pub const pancake_resolve_release = peer.pancake_resolve_release;

pub const pancake_tcp_netlayer_new = endpoint.pancake_tcp_netlayer_new;
pub const pancake_tcp_netlayer_new_in = endpoint.pancake_tcp_netlayer_new_in;
pub const pancake_tcp_netlayer_release = endpoint.pancake_tcp_netlayer_release;
pub const pancake_tcp_connect = endpoint.pancake_tcp_connect;
pub const pancake_tcp_listen = endpoint.pancake_tcp_listen;
pub const pancake_tcp_listener_port = endpoint.pancake_tcp_listener_port;
pub const pancake_tcp_accept = endpoint.pancake_tcp_accept;
pub const pancake_tcp_conn_read_frame = endpoint.pancake_tcp_conn_read_frame;
pub const pancake_tcp_conn_write_frame = endpoint.pancake_tcp_conn_write_frame;
pub const pancake_tcp_conn_release = endpoint.pancake_tcp_conn_release;
pub const pancake_tcp_listener_release = endpoint.pancake_tcp_listener_release;

pub const pancake_inproc_netlayer_new = inproc.pancake_inproc_netlayer_new;
pub const pancake_inproc_netlayer_new_in = inproc.pancake_inproc_netlayer_new_in;
pub const pancake_inproc_netlayer_release = inproc.pancake_inproc_netlayer_release;
pub const pancake_inproc_connect = inproc.pancake_inproc_connect;
pub const pancake_inproc_listen = inproc.pancake_inproc_listen;
pub const pancake_inproc_accept = inproc.pancake_inproc_accept;
pub const pancake_inproc_conn_read_frame = inproc.pancake_inproc_conn_read_frame;
pub const pancake_inproc_conn_write_frame = inproc.pancake_inproc_conn_write_frame;
pub const pancake_inproc_conn_release = inproc.pancake_inproc_conn_release;
pub const pancake_inproc_listener_release = inproc.pancake_inproc_listener_release;

pub const pancake_uri_parse_peer = uri.pancake_uri_parse_peer;
pub const pancake_uri_parse_sturdyref = uri.pancake_uri_parse_sturdyref;
pub const pancake_uri_format_peer = uri.pancake_uri_format_peer;
pub const pancake_uri_format_sturdyref = uri.pancake_uri_format_sturdyref;
pub const pancake_locator_transport = uri.pancake_locator_transport;
pub const pancake_locator_designator = uri.pancake_locator_designator;
pub const pancake_locator_swissnum = uri.pancake_locator_swissnum;
pub const pancake_locator_hint = uri.pancake_locator_hint;
pub const pancake_locator_hint_count = uri.pancake_locator_hint_count;
pub const pancake_locator_hint_at = uri.pancake_locator_hint_at;
pub const pancake_locator_release = uri.pancake_locator_release;

// ── Shared helpers for the out-of-tree iroh C ABI ────────────────────────────
//
// The iroh transport's C ABI (`src/c_abi/iroh.zig`) is a separate artifact: it
// links the Rust sidecar, so it must stay outside `libpancake`'s pure-Zig graph
// (ADR-0055). It still speaks the same managed-frame vocabulary and last-error
// boundary as the TCP endpoints, so these re-exports give that module the
// handful of shared helpers without it reaching into `c_abi`'s sibling files
// (which would compile a second copy of this root). None is a `pancake_*`
// function, so the header generator's coverage guards do not see them.
pub const tryManagedFrame = frame.tryManagedFrame;
pub const library_allocator = context.library_allocator;
pub const ctxFromOpaque = context.ctxFromOpaque;

comptime {
    // Force the family files' `export fn`s into the compilation even if the
    // re-exports above are ever pruned; a plain reference is enough.
    _ = context;
    _ = frame;
    _ = peer;
    _ = endpoint;
    _ = inproc;
    _ = uri;
}
