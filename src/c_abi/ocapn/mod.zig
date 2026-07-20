//! The C ABI for `libpancake_ocapn` — the sans-io OCapN family. It is
//! deliberately boring.
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
//! conversions), `peer` (the `PancakePeer` driving surface), and `uri` (the
//! OCapN locator grammar). This archive is sans-io: the transports
//! (`libpancake_net_transport_*`) carry the netlayer handles in their own
//! companion modules (ADR-0059). Each family `@import`s this root for the shared
//! types and codes; this root re-exports their `export fn`s so the header
//! generator, which reflects over the `c_abi` namespace, sees the full ABI in
//! one place.
//!
//! Threading contract: a `PancakePeer` is a single-owner state machine and is not
//! safe to drive from more than one thread at once. Serialize every call on a
//! given peer — including `feed`, `step`, `take_outbound`, `poll_event`, and the
//! typed send/poll calls — onto one thread (or behind your own lock). When a peer
//! runs over a blocking transport netlayer, that means the I/O backend and the
//! application share one thread per peer; the allocator behind a context may still
//! be called from the netlayer's threads, which is why a host allocator must be
//! thread-safe. `pancake_last_error` reports the *calling* thread's last error, so
//! read it on the same thread that made the failing call.

const engine = @import("engine");

/// Shared C-ABI vocabulary factored into a leaf module with no `export fn`, so the
/// iroh transport ABI can reuse it without inheriting libpancake_ocapn's exported
/// surface (ADR-0055 companion split). Re-exported here so the handle-family files
/// and `tools/gen/header/ocapn.zig` see the full vocabulary from this root.
const abi = @import("c_abi_shared");

const context = @import("context.zig");
const frame = @import("frame.zig");
const peer = @import("peer.zig");
const uri = @import("uri.zig");

/// ABI version the library implements. While `major` is 0 the ABI is unstable
/// (see `pancake_ocapn.h`); the shared library's soname tracks `major`.
pub const PANCAKE_VERSION_MAJOR: u32 = 0;
pub const PANCAKE_VERSION_MINOR: u32 = 1;
pub const PANCAKE_VERSION_PATCH: u32 = 0;

/// Report the ABI version the linked library implements. Any out-pointer may be
/// null to skip that component. Lets a consumer detect header/library skew by
/// comparing against the `PANCAKE_VERSION_*` macros it compiled against.
/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");

pub export fn pancake_abi_version(out_major: ?*u32, out_minor: ?*u32, out_patch: ?*u32) void {
    if (out_major) |p| p.* = PANCAKE_VERSION_MAJOR;
    if (out_minor) |p| p.* = PANCAKE_VERSION_MINOR;
    if (out_patch) |p| p.* = PANCAKE_VERSION_PATCH;
}

// Return codes and codec selector (shared leaf; re-exported for header reflection).
pub const PANCAKE_OK = abi.PANCAKE_OK;
pub const PANCAKE_ERR_NULL_POINTER = abi.PANCAKE_ERR_NULL_POINTER;
pub const PANCAKE_ERR_INVALID_ARGUMENT = abi.PANCAKE_ERR_INVALID_ARGUMENT;
pub const PANCAKE_ERR_SESSION = abi.PANCAKE_ERR_SESSION;
pub const PANCAKE_ERR_CODEC = abi.PANCAKE_ERR_CODEC;
pub const PANCAKE_ERR_INTERNAL = abi.PANCAKE_ERR_INTERNAL;
pub const PANCAKE_ERR_WOULD_BLOCK = abi.PANCAKE_ERR_WOULD_BLOCK;
pub const PANCAKE_ERR_CLOSED = abi.PANCAKE_ERR_CLOSED;
pub const PANCAKE_ERR_IO = abi.PANCAKE_ERR_IO;
pub const PANCAKE_ERR_MALFORMED = abi.PANCAKE_ERR_MALFORMED;
pub const PANCAKE_ERR_FRAME_TOO_LARGE = abi.PANCAKE_ERR_FRAME_TOO_LARGE;
pub const PANCAKE_ERR_UNSUPPORTED_VALUE = abi.PANCAKE_ERR_UNSUPPORTED_VALUE;
pub const PANCAKE_ERR_BROKEN = abi.PANCAKE_ERR_BROKEN;
pub const PANCAKE_ERR_NOT_FOUND = abi.PANCAKE_ERR_NOT_FOUND;
pub const PANCAKE_ERR_BUFFER_TOO_SMALL = abi.PANCAKE_ERR_BUFFER_TOO_SMALL;

pub const PANCAKE_CODEC_SYRUP = abi.PANCAKE_CODEC_SYRUP;
pub const PANCAKE_CODEC_CAPNP = abi.PANCAKE_CODEC_CAPNP;

/// Decode a `PANCAKE_CODEC_*` value, or null for anything outside the family.
pub const codecFromC = abi.codecFromC;

/// `captp_version` selector for `pancake_peer_new_negotiated`: the
/// authenticated v1.0 interop profile, or next (pancake-forward private track).
pub const PANCAKE_CAPTP_VERSION_V1_0: u32 = 0;
pub const PANCAKE_CAPTP_VERSION_NEXT: u32 = 1;

pub const PANCAKE_FRAME_SHAPE_BYTE = abi.PANCAKE_FRAME_SHAPE_BYTE;
pub const PANCAKE_FRAME_SHAPE_WORD = abi.PANCAKE_FRAME_SHAPE_WORD;
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

// Borrowed/owned frame types (shared leaf).
pub const PancakeFrame = abi.PancakeFrame;
pub const ReleaseFn = abi.ReleaseFn;
pub const PancakeManagedFrame = abi.PancakeManagedFrame;

pub const PancakeEvent = extern struct {
    kind: u32,
    frame: PancakeManagedFrame,
};

pub const PancakePeer = opaque {};

/// The base of the reserved redeemed-handoff-token far-id range (ADR-0066): a
/// far id at or above this names a capability the host redeemed and routes to
/// its exporter connection, never a wire import, so a token can never alias a
/// partner's import. A host that keys per-import state (GC, caches) by far id
/// uses this bound to tell the two apart.
pub const PANCAKE_REDEEMED_TOKEN_BASE: u64 = engine.Node.REDEEMED_TOKEN_BASE;

// ── Allocation context ───────────────────────────────────────────────────────

// Host allocator surface (shared leaf).
pub const PancakeAllocFn = abi.PancakeAllocFn;
pub const PancakeFreeFn = abi.PancakeFreeFn;
pub const PancakeAllocator = abi.PancakeAllocator;
pub const PancakeContext = abi.PancakeContext;

// Typed OCapN value discriminants and structs (shared leaf).
pub const PANCAKE_REF_NEAR = abi.PANCAKE_REF_NEAR;
pub const PANCAKE_REF_FAR = abi.PANCAKE_REF_FAR;
pub const PANCAKE_REF_PROMISE = abi.PANCAKE_REF_PROMISE;
pub const PANCAKE_REF_STURDY = abi.PANCAKE_REF_STURDY;
pub const PANCAKE_REF_BROKEN = abi.PANCAKE_REF_BROKEN;

pub const PANCAKE_REF_SUB_OBJECT = abi.PANCAKE_REF_SUB_OBJECT;
pub const PANCAKE_REF_SUB_PROMISE = abi.PANCAKE_REF_SUB_PROMISE;

pub const PANCAKE_ARG_INTEGER = abi.PANCAKE_ARG_INTEGER;
pub const PANCAKE_ARG_FLOAT64 = abi.PANCAKE_ARG_FLOAT64;
pub const PANCAKE_ARG_BOOLEAN = abi.PANCAKE_ARG_BOOLEAN;
pub const PANCAKE_ARG_BYTES = abi.PANCAKE_ARG_BYTES;
pub const PANCAKE_ARG_STRING = abi.PANCAKE_ARG_STRING;
pub const PANCAKE_ARG_SYMBOL = abi.PANCAKE_ARG_SYMBOL;
pub const PANCAKE_ARG_VOID = abi.PANCAKE_ARG_VOID;
pub const PANCAKE_ARG_REFERENCE = abi.PANCAKE_ARG_REFERENCE;
pub const PANCAKE_ARG_LIST = abi.PANCAKE_ARG_LIST;
pub const PANCAKE_ARG_SET = abi.PANCAKE_ARG_SET;
pub const PANCAKE_ARG_TAGGED = abi.PANCAKE_ARG_TAGGED;
pub const PANCAKE_ARG_KEYWORD = abi.PANCAKE_ARG_KEYWORD;
pub const PANCAKE_ARG_BIG_INTEGER = abi.PANCAKE_ARG_BIG_INTEGER;

pub const PANCAKE_RESOLUTION_FULFILL = abi.PANCAKE_RESOLUTION_FULFILL;
pub const PANCAKE_RESOLUTION_BREAK = abi.PANCAKE_RESOLUTION_BREAK;
pub const PANCAKE_RESOLUTION_HANDOFF = abi.PANCAKE_RESOLUTION_HANDOFF;

/// Wire spelling of the empty locator hints in `pancake_peer_start_session`.
/// `_EMPTY_MAP` encodes the empty hints as `{}`; `_EMPTY_FALSE` encodes them as
/// the boolean `#f`, the spelling Goblins emits and re-encodes when it checks a
/// signed locator. The two are semantically the same empty hints, but a
/// signature computed over one spelling does not verify over the other.
pub const PANCAKE_HINTS_EMPTY_MAP: u32 = 0;
pub const PANCAKE_HINTS_EMPTY_FALSE: u32 = 1;

/// The well-known bootstrap export position every OCapN peer answers `fetch`
/// on, the one authoritative value, surfaced from the engine so a consumer
/// never re-derives the magic `0`.
pub const PANCAKE_BOOTSTRAP_POSITION: u64 = engine.BOOTSTRAP_POSITION;

// Reference/argument struct layouts (shared leaf).
pub const PancakeReference = abi.PancakeReference;
pub const PancakeArgument = abi.PancakeArgument;

/// A received `op:deliver` projected to C. `args` aliases an internal arena
/// owned by the enclosing `PancakeAnyEvent`; the views die with
/// `pancake_any_event_release`.
pub const PancakeDeliver = extern struct {
    target: PancakeReference,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    has_answer: u32,
    answer: u64,
    owner: ?*anyopaque,
};

/// A `desc:handoff-give` projected to C for a binding to redeem (ADR-0009/
/// ADR-0056). `give`/`give_len` is the verbatim `<desc:sig-envelope …>` span the
/// recipient relays unaltered to the exporter, feed it straight to
/// `pancake_peer_send_withdraw_gift`. `exporter_locator`/`exporter_locator_len`
/// is the exporter's dialable `ocapn://…` URI, or empty when the give's location
/// is not a flat transport locator (the binding then cannot dial it). `recipient_key`
/// is the 32-byte Ed25519 public key the give is addressed to, so a binding can
/// confirm the gift names its own identity. All views alias the owning
/// projection's arena and die with `pancake_any_event_release`.
pub const PancakeHandoffGive = extern struct {
    give: ?[*]const u8,
    give_len: usize,
    exporter_locator: ?[*]const u8,
    exporter_locator_len: usize,
    recipient_key: ?[*]const u8,
    recipient_key_len: usize,
};

/// A received `op:resolve` projected to C. `resolution_kind` selects `fulfill`
/// (a value), the `break_message` bytes, or `handoff` (a `desc:handoff-give` to
/// redeem). The views alias the enclosing `PancakeAnyEvent`'s arena and die
/// with `pancake_any_event_release`.
pub const PancakeResolve = extern struct {
    answer: u64,
    resolution_kind: u32,
    fulfill: PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
    handoff: PancakeHandoffGive,
    owner: ?*anyopaque,
};

/// `PancakeAnyEvent.projection`: which arm of the polled event is live.
/// `_NONE` is the released/empty sentinel `pancake_any_event_release` writes
/// back; a successful poll never returns it.
pub const PANCAKE_PROJECTION_NONE: u32 = 0;
pub const PANCAKE_PROJECTION_DELIVER: u32 = 1;
pub const PANCAKE_PROJECTION_RESOLVE: u32 = 2;
pub const PANCAKE_PROJECTION_FRAME: u32 = 3;

/// One polled event, fully projected — what `pancake_peer_next_event`
/// fills. `kind` is the event's `PANCAKE_EVENT_*`; `projection` names the arm
/// that carries it: a typed `deliver` or `resolve`, or the originating wire
/// `frame` for every other kind and for a deliver/resolve whose value the typed
/// surface cannot carry. Exactly one arm is live at a time. Release with
/// `pancake_any_event_release` exactly once; the deliver/resolve views die with
/// the release.
pub const PancakeAnyEvent = extern struct {
    kind: u32,
    projection: u32,
    deliver: PancakeDeliver,
    resolve: PancakeResolve,
    frame: PancakeManagedFrame,
};

/// `PancakeEnlivenStart.status`: how `pancake_peer_prepare_enliven` resolved
/// before any wire traffic (ADR-0012). `_FRESH` queued a fresh bootstrap-fetch
/// whose answer the caller drives and then settles with
/// `pancake_peer_record_enlivenment`; `_CACHED` short-circuited to an
/// already-enlivened reference (no wire, read `import_position`/`kind`); and
/// `_IN_FLIGHT` collapsed onto an enliven already outstanding on `answer`.
pub const PANCAKE_ENLIVEN_FRESH: u32 = 0;
pub const PANCAKE_ENLIVEN_CACHED: u32 = 1;
pub const PANCAKE_ENLIVEN_IN_FLIGHT: u32 = 2;

/// `pancake_peer_record_enlivenment.outcome`: whether the partner settled the
/// enliven's bootstrap-fetch with a capability (`_FULFILLED`, cache it) or broke
/// it (`_BROKEN`, only clear the in-flight marker).
pub const PANCAKE_ENLIVEN_OUTCOME_FULFILLED: u32 = 0;
pub const PANCAKE_ENLIVEN_OUTCOME_BROKEN: u32 = 1;

/// The outcome of `pancake_peer_prepare_enliven`. `status` selects which fields
/// are live: `_FRESH`/`_IN_FLIGHT` carry the `answer` to drive; `_CACHED`
/// carries the reconstructed far reference (`import_position` + `kind`, a
/// `PANCAKE_REF_SUB_*` value). The unused fields are zeroed.
pub const PancakeEnlivenStart = extern struct {
    status: u32,
    kind: u32,
    answer: u64,
    import_position: u64,
};

// The typed local dispatch-failure projection (shared leaf, so the byte-fed
// driver family reads its connections' aborts through the same layout).
pub const PANCAKE_ABORT_DOMAIN_CODEC = abi.PANCAKE_ABORT_DOMAIN_CODEC;
pub const PANCAKE_ABORT_DOMAIN_SESSION = abi.PANCAKE_ABORT_DOMAIN_SESSION;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN = abi.PANCAKE_ABORT_DOMAIN_FOREIGN;
pub const PancakeLastAbort = abi.PancakeLastAbort;

// ── OCapN locator handle ─────────────────────────────────────────────────────

/// A parsed OCapN locator: the value a `pancake_uri_parse_*` returns, read
/// through the `pancake_locator_*` accessors and freed with
/// `pancake_locator_release`. One handle carries both a peer and a sturdyref (a
/// sturdyref is a peer locator plus a swissnum), so a parsed peer reports a
/// zero-length swissnum.
pub const PancakeLocator = opaque {};

// ── Shared error projection ──────────────────────────────────────────────────

/// Classify an inbound-dispatch error into a C ABI return code. Defined once in
/// the shared leaf (`c_abi_shared.feedErrorToCode`, derived from
/// `engine.abort_projection.classify`) so every archive reports the same code
/// for the same error.
pub const feedErrorToCode = abi.feedErrorToCode;

// Per-thread last error (shared leaf; read through the exports below).
pub const setLastError = abi.setLastError;

/// Copy the calling thread's last error message into `out_buf`. Copies at most
/// `cap - 1` bytes and always NUL-terminates when `cap > 0`. Returns the full
/// message length; to receive the whole message pass a buffer of that length
/// plus one. `out_buf == NULL` or `cap == 0` queries the length. errno-style:
/// meaningful only right after a call that returned a cause-bearing code
/// (`_IO`, or the address-parse `_INVALID_ARGUMENT`); a later success does not
/// clear it. Returns 0 when none is set.
pub export fn pancake_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return abi.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's last error slot.
pub export fn pancake_clear_last_error() void {
    abi.lastErrorClear();
}

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family files; the plain `@import`s
// above already compile them into the library. These re-exports also surface them
// as members of the `c_abi` namespace so `tools/gen/header/ocapn.zig`, which reflects
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
pub const pancake_peer_recv_borrowed = peer.pancake_peer_recv_borrowed;
pub const pancake_peer_feed_owned = peer.pancake_peer_feed_owned;
pub const pancake_peer_recv_stream = peer.pancake_peer_recv_stream;
pub const pancake_peer_step = peer.pancake_peer_step;
pub const pancake_peer_take_outbound = peer.pancake_peer_take_outbound;
pub const pancake_peer_poll_event = peer.pancake_peer_poll_event;
pub const pancake_peer_start_session = peer.pancake_peer_start_session;
pub const pancake_peer_session_is_open = peer.pancake_peer_session_is_open;
pub const pancake_peer_expect_partner_key = peer.pancake_peer_expect_partner_key;
pub const pancake_peer_codec = peer.pancake_peer_codec;
pub const pancake_peer_register_bootstrap_cap = peer.pancake_peer_register_bootstrap_cap;
pub const pancake_peer_send_bootstrap_fetch = peer.pancake_peer_send_bootstrap_fetch;
pub const pancake_peer_prepare_enliven = peer.pancake_peer_prepare_enliven;
pub const pancake_peer_record_enlivenment = peer.pancake_peer_record_enlivenment;
pub const pancake_peer_register_export = peer.pancake_peer_register_export;
pub const pancake_peer_next_export = peer.pancake_peer_next_export;
pub const pancake_peer_next_answer = peer.pancake_peer_next_answer;
pub const pancake_peer_last_abort = peer.pancake_peer_last_abort;
pub const pancake_peer_register_import = peer.pancake_peer_register_import;
pub const pancake_peer_peek_event = peer.pancake_peer_peek_event;
pub const pancake_peer_send_deliver = peer.pancake_peer_send_deliver;
pub const pancake_peer_send_resolve = peer.pancake_peer_send_resolve;
pub const pancake_peer_send_get = peer.pancake_peer_send_get;
pub const pancake_peer_send_index = peer.pancake_peer_send_index;
pub const pancake_peer_send_untag = peer.pancake_peer_send_untag;
pub const pancake_peer_send_abort = peer.pancake_peer_send_abort;
pub const pancake_peer_send_gc_export = peer.pancake_peer_send_gc_export;
pub const pancake_peer_send_gc_answer = peer.pancake_peer_send_gc_answer;
pub const pancake_peer_send_withdraw_gift = peer.pancake_peer_send_withdraw_gift;
pub const pancake_peer_partner_locator_raw = peer.pancake_peer_partner_locator_raw;
pub const pancake_build_handoff_give = peer.pancake_build_handoff_give;
pub const pancake_handoff_give_bytes_release = peer.pancake_handoff_give_bytes_release;
pub const pancake_encode_peer_locator = peer.pancake_encode_peer_locator;
pub const pancake_peer_locator_bytes_release = peer.pancake_peer_locator_bytes_release;
pub const pancake_peer_send_deposit_gift = peer.pancake_peer_send_deposit_gift;
pub const pancake_peer_send_resolve_handoff_give = peer.pancake_peer_send_resolve_handoff_give;
pub const pancake_peer_next_event = peer.pancake_peer_next_event;
pub const pancake_any_event_release = peer.pancake_any_event_release;

pub const pancake_uri_parse_peer = uri.pancake_uri_parse_peer;
pub const pancake_uri_parse_sturdyref = uri.pancake_uri_parse_sturdyref;
pub const pancake_uri_format_peer = uri.pancake_uri_format_peer;
pub const pancake_uri_format_sturdyref = uri.pancake_uri_format_sturdyref;
pub const pancake_locator_transport = uri.pancake_locator_transport;
pub const pancake_locator_designator = uri.pancake_locator_designator;
pub const pancake_locator_host_port = uri.pancake_locator_host_port;
pub const pancake_designator_host_port = uri.pancake_designator_host_port;
pub const pancake_locator_swissnum = uri.pancake_locator_swissnum;
pub const pancake_locator_hint = uri.pancake_locator_hint;
pub const pancake_locator_hint_count = uri.pancake_locator_hint_count;
pub const pancake_locator_hint_at = uri.pancake_locator_hint_at;
pub const pancake_locator_release = uri.pancake_locator_release;

comptime {
    // Force the family files' `export fn`s into the compilation even if the
    // re-exports above are ever pruned; a plain reference is enough.
    _ = context;
    _ = frame;
    _ = peer;
    _ = uri;
}
