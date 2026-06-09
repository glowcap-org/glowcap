//! The C ABI for `libpancake`. Deliberately boring.
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

const engine = @import("../engine/mod.zig");

const context = @import("context.zig");
const frame = @import("frame.zig");
const peer = @import("peer.zig");
const endpoint = @import("endpoint.zig");

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
/// A value handed across the typed surface uses a variant the C ABI does not yet
/// carry (a `set`/`tagged`/`handoff`/`keyword` argument, or a `sturdy`/`broken`
/// reference target). Refused loudly rather than dropped.
pub const PANCAKE_ERR_UNSUPPORTED_VALUE: i32 = -13;
/// A promise the partner broke: a `send`/`fetch` the remote side refused with a
/// reason, not a fault in this peer or the transport. No C ABI function *returns*
/// this — a break arrives as a `PANCAKE_RESOLUTION_BREAK` resolve event carrying
/// its message — but it is the shared code a binding surfaces when it turns that
/// break into its own error type, so the reason is distinct from a real failure.
pub const PANCAKE_ERR_BROKEN: i32 = -14;

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
/// promise (the `desc:import-object` vs `desc:import-promise` distinction).
pub const PANCAKE_REF_OBJECT: u32 = 0;
pub const PANCAKE_REF_PROMISE_KIND: u32 = 1;

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

pub const PANCAKE_RESOLUTION_FULFILL: u32 = 0;
pub const PANCAKE_RESOLUTION_BREAK: u32 = 1;

/// A capability reference. `kind` selects the meaning of `id`: a `_NEAR` export
/// id, a `_FAR` import id, or a `_PROMISE` answer id. `sub_kind` is the
/// object/promise distinction for near/far. `_STURDY` and `_BROKEN` carry no
/// payload here (use the resolution's break message for a broken target).
pub const PancakeReference = extern struct {
    kind: u32,
    sub_kind: u32,
    id: u64,
};

/// A passable argument value. `kind` selects which field is live. `bytes`/
/// `bytes_len` carry `_BYTES`/`_STRING`/`_SYMBOL`; `items`/`items_len` carry a
/// `_LIST`'s children. On a projected (received) value the pointers alias the
/// owning arena and are valid until the matching `*_free`.
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
/// release the whole projection with `pancake_deliver_free` exactly once.
pub const PancakeDeliver = extern struct {
    target: PancakeReference,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    has_answer: u32,
    answer: u64,
    owner: ?*anyopaque,
};

/// A received `op:resolve` projected to C. `resolution_kind` selects `fulfill`
/// (a value) or the `break_message` bytes. Release with `pancake_resolve_free`.
pub const PancakeResolve = extern struct {
    answer: u64,
    resolution_kind: u32,
    fulfill: PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
    owner: ?*anyopaque,
};

// ── TCP endpoint handles ─────────────────────────────────────────────────────

pub const PancakeTcpNetlayer = opaque {};
pub const PancakeTcpConn = opaque {};
pub const PancakeTcpListener = opaque {};

// ── Shared error projection ──────────────────────────────────────────────────

/// Classify an inbound-dispatch error into a C ABI return code. Derived from the
/// single error taxonomy ([`engine.abort_projection.classify`]) so the C codes
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

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family files; the plain `@import`s
// above already compile them into the library. These re-exports also surface them
// as members of the `c_abi` namespace so `tools/header_gen.zig`, which reflects
// over `c_abi`, sees the full ABI from one root.

pub const pancake_context_new_default = context.pancake_context_new_default;
pub const pancake_context_new_with_allocator = context.pancake_context_new_with_allocator;
pub const pancake_context_release = context.pancake_context_release;

pub const pancake_managed_frame_release = frame.pancake_managed_frame_release;
pub const pancake_event_release = frame.pancake_event_release;

pub const pancake_peer_new = peer.pancake_peer_new;
pub const pancake_peer_new_in = peer.pancake_peer_new_in;
pub const pancake_peer_new_negotiating = peer.pancake_peer_new_negotiating;
pub const pancake_peer_new_negotiating_in = peer.pancake_peer_new_negotiating_in;
pub const pancake_peer_release = peer.pancake_peer_release;
pub const pancake_peer_feed_borrowed = peer.pancake_peer_feed_borrowed;
pub const pancake_peer_feed_owned = peer.pancake_peer_feed_owned;
pub const pancake_peer_recv_stream = peer.pancake_peer_recv_stream;
pub const pancake_peer_step = peer.pancake_peer_step;
pub const pancake_peer_take_outbound = peer.pancake_peer_take_outbound;
pub const pancake_peer_poll_event = peer.pancake_peer_poll_event;
pub const pancake_peer_start_session_keyed = peer.pancake_peer_start_session_keyed;
pub const pancake_peer_session_is_open = peer.pancake_peer_session_is_open;
pub const pancake_peer_register_bootstrap_cap = peer.pancake_peer_register_bootstrap_cap;
pub const pancake_peer_register_export = peer.pancake_peer_register_export;
pub const pancake_peer_register_import = peer.pancake_peer_register_import;
pub const pancake_peer_peek_event = peer.pancake_peer_peek_event;
pub const pancake_peer_send_deliver = peer.pancake_peer_send_deliver;
pub const pancake_peer_send_resolve = peer.pancake_peer_send_resolve;
pub const pancake_peer_poll_event_deliver = peer.pancake_peer_poll_event_deliver;
pub const pancake_peer_poll_event_resolve = peer.pancake_peer_poll_event_resolve;
pub const pancake_deliver_free = peer.pancake_deliver_free;
pub const pancake_resolve_free = peer.pancake_resolve_free;

pub const pancake_tcp_netlayer_new = endpoint.pancake_tcp_netlayer_new;
pub const pancake_tcp_netlayer_new_in = endpoint.pancake_tcp_netlayer_new_in;
pub const pancake_tcp_netlayer_release = endpoint.pancake_tcp_netlayer_release;
pub const pancake_endpoint_tcp_testing_connect = endpoint.pancake_endpoint_tcp_testing_connect;
pub const pancake_endpoint_tcp_testing_listen = endpoint.pancake_endpoint_tcp_testing_listen;
pub const pancake_endpoint_tcp_listener_port = endpoint.pancake_endpoint_tcp_listener_port;
pub const pancake_endpoint_tcp_testing_accept = endpoint.pancake_endpoint_tcp_testing_accept;
pub const pancake_endpoint_tcp_read_frame = endpoint.pancake_endpoint_tcp_read_frame;
pub const pancake_endpoint_tcp_write_frame = endpoint.pancake_endpoint_tcp_write_frame;
pub const pancake_endpoint_tcp_conn_close = endpoint.pancake_endpoint_tcp_conn_close;
pub const pancake_endpoint_tcp_listener_close = endpoint.pancake_endpoint_tcp_listener_close;

comptime {
    // Force the family files' `export fn`s into the compilation even if the
    // re-exports above are ever pruned; a plain reference is enough.
    _ = context;
    _ = frame;
    _ = peer;
    _ = endpoint;
}
