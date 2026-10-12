//! Shared C vocabulary for glowcap's composable archives: allocation contexts,
//! frames, values, locators, URI grammar, and return codes. CapTP application
//! work enters through `libglowcap_host`. The protocol engine stays a Zig
//! surface.
//!
//! This file is the crate root: it owns the shared vocabulary (return codes,
//! discriminants, the C-visible types) and the per-thread last-error boundary,
//! then pulls in the handle-family files so every `export fn` they declare is
//! compiled into the library. The families are `context` (allocation policy),
//! `frame` (managed-frame ownership), and `uri` (the OCapN locator grammar).
//! This archive is sans-io: the transports
//! (`libglowcap_net_transport_*`) carry the netlayer handles in their own
//! companion modules (ADR-0059). Each family `@import`s this root for the shared
//! types and codes. This root re-exports their `export fn`s so the header
//! generator, which reflects over the `c_abi` namespace, sees the full ABI in
//! one place.
//! The allocator behind a context may be called from transport threads, so a
//! caller-supplied allocator must be thread-safe. `glowcap_last_error` reports
//! the calling thread's last error.

/// Shared C-ABI vocabulary factored into a leaf module with no `export fn`, so the
/// iroh transport ABI can reuse it without inheriting libglowcap_ocapn's exported
/// surface (ADR-0055 companion split). Re-exported here so the handle-family files
/// and `tools/gen/header/ocapn.zig` see the full vocabulary from this root.
pub const std_options = @import("c_abi_shared").library_options;

const abi = @import("c_abi_shared");

const context = @import("context.zig");
const frame = @import("frame.zig");
const uri = @import("uri.zig");
const uri_record = @import("uri/record.zig");

/// ABI version the library implements. While `major` is 0 the ABI is unstable
/// (see `glowcap_ocapn.h`). The shared library's soname tracks `major`.
pub const GLOWCAP_VERSION_MAJOR: u32 = 0;
pub const GLOWCAP_VERSION_MINOR: u32 = 1;
pub const GLOWCAP_VERSION_PATCH: u32 = 0;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from. See `symbols.zig`.
pub const symbols = @import("symbols.zig");
pub const contract_layouts = abi.contract_layouts;

/// Exact reflected callable/layout identity for the core archive.
pub const GLOWCAP_OCAPN_ARCHIVE_FINGERPRINT = abi.archive_contract.fingerprint(
    "ocapn",
    @This(),
    .{abi.contract_layouts},
);

pub export fn glowcap_ocapn_archive_fingerprint() u64 {
    return GLOWCAP_OCAPN_ARCHIVE_FINGERPRINT;
}

/// Report the ABI version the linked library implements. Any out-pointer may be
/// null to skip that component. Lets a consumer detect header/library skew by
/// comparing against the `GLOWCAP_VERSION_*` macros it compiled against.
pub export fn glowcap_abi_version(out_major: ?*u32, out_minor: ?*u32, out_patch: ?*u32) void {
    if (out_major) |p| p.* = GLOWCAP_VERSION_MAJOR;
    if (out_minor) |p| p.* = GLOWCAP_VERSION_MINOR;
    if (out_patch) |p| p.* = GLOWCAP_VERSION_PATCH;
}

// Return codes and codec selector (shared leaf; re-exported for header reflection).
pub const GLOWCAP_OK = abi.GLOWCAP_OK;
pub const GLOWCAP_ERR_NULL_POINTER = abi.GLOWCAP_ERR_NULL_POINTER;
pub const GLOWCAP_ERR_INVALID_ARGUMENT = abi.GLOWCAP_ERR_INVALID_ARGUMENT;
pub const GLOWCAP_ERR_SESSION = abi.GLOWCAP_ERR_SESSION;
pub const GLOWCAP_ERR_CODEC = abi.GLOWCAP_ERR_CODEC;
pub const GLOWCAP_ERR_INTERNAL = abi.GLOWCAP_ERR_INTERNAL;
pub const GLOWCAP_ERR_WOULD_BLOCK = abi.GLOWCAP_ERR_WOULD_BLOCK;
pub const GLOWCAP_ERR_CLOSED = abi.GLOWCAP_ERR_CLOSED;
pub const GLOWCAP_ERR_IO = abi.GLOWCAP_ERR_IO;
pub const GLOWCAP_ERR_MALFORMED = abi.GLOWCAP_ERR_MALFORMED;
pub const GLOWCAP_ERR_FRAME_TOO_LARGE = abi.GLOWCAP_ERR_FRAME_TOO_LARGE;
pub const GLOWCAP_ERR_UNSUPPORTED_VALUE = abi.GLOWCAP_ERR_UNSUPPORTED_VALUE;
pub const GLOWCAP_ERR_BROKEN = abi.GLOWCAP_ERR_BROKEN;
pub const GLOWCAP_ERR_NOT_FOUND = abi.GLOWCAP_ERR_NOT_FOUND;
pub const GLOWCAP_ERR_BUFFER_TOO_SMALL = abi.GLOWCAP_ERR_BUFFER_TOO_SMALL;
pub const GLOWCAP_ERR_TIMEOUT = abi.GLOWCAP_ERR_TIMEOUT;

pub const GLOWCAP_CAPTP_V1_0 = abi.GLOWCAP_CAPTP_V1_0;
pub const GLOWCAP_CAPTP_NEXT = abi.GLOWCAP_CAPTP_NEXT;
pub const GLOWCAP_CODEC_UNKNOWN = abi.GLOWCAP_CODEC_UNKNOWN;
pub const GLOWCAP_CODEC_SYRUP = abi.GLOWCAP_CODEC_SYRUP;
pub const GLOWCAP_CODEC_CAPNP = abi.GLOWCAP_CODEC_CAPNP;
pub const GLOWCAP_FEATURE_PIPELINING = abi.GLOWCAP_FEATURE_PIPELINING;
pub const GLOWCAP_FEATURE_HANDOFF = abi.GLOWCAP_FEATURE_HANDOFF;
pub const GLOWCAP_FEATURE_WIRE_DELTA = abi.GLOWCAP_FEATURE_WIRE_DELTA;
pub const GLOWCAP_FEATURE_STURDYREF = abi.GLOWCAP_FEATURE_STURDYREF;
pub const GLOWCAP_FEATURE_UNTAG = abi.GLOWCAP_FEATURE_UNTAG;
pub const GLOWCAP_FEATURE_MULTI_LOCATION = abi.GLOWCAP_FEATURE_MULTI_LOCATION;
pub const GLOWCAP_FEATURE_MINIMUM = abi.GLOWCAP_FEATURE_MINIMUM;
pub const GLOWCAP_FEATURE_FULL = abi.GLOWCAP_FEATURE_FULL;
pub const GLOWCAP_FEATURE_BASELINE = abi.GLOWCAP_FEATURE_BASELINE;
pub const GLOWCAP_DEFAULT_CODEC = abi.GLOWCAP_DEFAULT_CODEC;
pub const GLOWCAP_DEFAULT_CAPTP_VERSION = abi.GLOWCAP_DEFAULT_CAPTP_VERSION;
pub const GLOWCAP_DEFAULT_FEATURES = abi.GLOWCAP_DEFAULT_FEATURES;
pub const GLOWCAP_INTEROP_CODEC = abi.GLOWCAP_INTEROP_CODEC;
pub const GLOWCAP_INTEROP_CAPTP_VERSION = abi.GLOWCAP_INTEROP_CAPTP_VERSION;
pub const GLOWCAP_NATIVE_CODEC = abi.GLOWCAP_NATIVE_CODEC;
pub const GLOWCAP_NATIVE_CAPTP_VERSION = abi.GLOWCAP_NATIVE_CAPTP_VERSION;

/// Decode a `GLOWCAP_CODEC_*` value, or null for anything outside the family.
pub const codecFromC = abi.codecFromC;
/// Encode a Zig codec id as a C built-in selector, or UNKNOWN for non-built-ins.
pub const codecToC = abi.codecToC;
/// Encode/decode the `GLOWCAP_FEATURE_*` bitmask for Zig tests and generators.
pub const featureSetToC = abi.featureSetToC;
pub const featureSetFromC = abi.featureSetFromC;

pub const GLOWCAP_FRAME_SHAPE_BYTE = abi.GLOWCAP_FRAME_SHAPE_BYTE;
pub const GLOWCAP_FRAME_SHAPE_WORD = abi.GLOWCAP_FRAME_SHAPE_WORD;
pub const GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP = abi.connection.raw_transport_default_frame_cap;
pub const GLOWCAP_DEFAULT_FAILURE_CAPACITY = abi.default_failure_capacity;
pub const GLOWCAP_DEFAULT_FAILURE_PAYLOAD_CAP = abi.default_failure_payload_cap;

// Borrowed/owned frame types (shared leaf).
pub const GlowcapFrame = abi.GlowcapFrame;
pub const ReleaseFn = abi.ReleaseFn;
pub const GlowcapManagedFrame = abi.GlowcapManagedFrame;

// ── Allocation context ───────────────────────────────────────────────────────

// Host allocator surface (shared leaf).
pub const GlowcapAllocFn = abi.GlowcapAllocFn;
pub const GlowcapFreeFn = abi.GlowcapFreeFn;
pub const GlowcapAllocator = abi.GlowcapAllocator;
pub const GlowcapContext = abi.GlowcapContext;
pub const GlowcapFailureEvent = abi.GlowcapFailureEvent;
pub const GlowcapFailureReport = abi.GlowcapFailureReport;
pub const GLOWCAP_FAILURE_EVENT_ABI_VERSION = abi.GLOWCAP_FAILURE_EVENT_ABI_VERSION;
pub const GLOWCAP_FAILURE_LAYER_CORE = abi.GLOWCAP_FAILURE_LAYER_CORE;
pub const GLOWCAP_FAILURE_LAYER_DRIVER = abi.GLOWCAP_FAILURE_LAYER_DRIVER;
pub const GLOWCAP_FAILURE_LAYER_TRANSPORT = abi.GLOWCAP_FAILURE_LAYER_TRANSPORT;
pub const GLOWCAP_FAILURE_LAYER_BINDING = abi.GLOWCAP_FAILURE_LAYER_BINDING;
pub const GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER = abi.GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER;
pub const GLOWCAP_FAILURE_SCOPE_PROCESS = abi.GLOWCAP_FAILURE_SCOPE_PROCESS;
pub const GLOWCAP_FAILURE_SCOPE_CONTEXT = abi.GLOWCAP_FAILURE_SCOPE_CONTEXT;
pub const GLOWCAP_FAILURE_SCOPE_HOST = abi.GLOWCAP_FAILURE_SCOPE_HOST;
pub const GLOWCAP_FAILURE_SCOPE_SESSION = abi.GLOWCAP_FAILURE_SCOPE_SESSION;
pub const GLOWCAP_FAILURE_SCOPE_LISTENER = abi.GLOWCAP_FAILURE_SCOPE_LISTENER;
pub const GLOWCAP_FAILURE_SCOPE_TRANSPORT = abi.GLOWCAP_FAILURE_SCOPE_TRANSPORT;
pub const GLOWCAP_FAILURE_SCOPE_OPERATION = abi.GLOWCAP_FAILURE_SCOPE_OPERATION;
pub const GLOWCAP_FAILURE_TRUNCATED_OPERATION = abi.GLOWCAP_FAILURE_TRUNCATED_OPERATION;
pub const GLOWCAP_FAILURE_TRUNCATED_PRIMARY_NAME = abi.GLOWCAP_FAILURE_TRUNCATED_PRIMARY_NAME;
pub const GLOWCAP_FAILURE_TRUNCATED_PRIMARY_MESSAGE = abi.GLOWCAP_FAILURE_TRUNCATED_PRIMARY_MESSAGE;
pub const GLOWCAP_FAILURE_TRUNCATED_SECONDARY_NAME = abi.GLOWCAP_FAILURE_TRUNCATED_SECONDARY_NAME;
pub const GLOWCAP_FAILURE_TRUNCATED_SECONDARY_MESSAGE = abi.GLOWCAP_FAILURE_TRUNCATED_SECONDARY_MESSAGE;

// Application value discriminants and structs (shared leaf).
pub const GLOWCAP_ARG_INTEGER = abi.GLOWCAP_ARG_INTEGER;
pub const GLOWCAP_ARG_FLOAT64 = abi.GLOWCAP_ARG_FLOAT64;
pub const GLOWCAP_ARG_BOOLEAN = abi.GLOWCAP_ARG_BOOLEAN;
pub const GLOWCAP_ARG_BYTES = abi.GLOWCAP_ARG_BYTES;
pub const GLOWCAP_ARG_STRING = abi.GLOWCAP_ARG_STRING;
pub const GLOWCAP_ARG_SYMBOL = abi.GLOWCAP_ARG_SYMBOL;
pub const GLOWCAP_ARG_VOID = abi.GLOWCAP_ARG_VOID;
pub const GLOWCAP_ARG_REFERENCE = abi.GLOWCAP_ARG_REFERENCE;
pub const GLOWCAP_ARG_LIST = abi.GLOWCAP_ARG_LIST;
pub const GLOWCAP_ARG_SET = abi.GLOWCAP_ARG_SET;
pub const GLOWCAP_ARG_TAGGED = abi.GLOWCAP_ARG_TAGGED;
pub const GLOWCAP_ARG_KEYWORD = abi.GLOWCAP_ARG_KEYWORD;
pub const GLOWCAP_ARG_BIG_INTEGER = abi.GLOWCAP_ARG_BIG_INTEGER;
pub const GLOWCAP_ARG_STRUCT = abi.GLOWCAP_ARG_STRUCT;
pub const GLOWCAP_ARG_ERROR = abi.GLOWCAP_ARG_ERROR;

pub const GLOWCAP_RESOLUTION_FULFILL = abi.GLOWCAP_RESOLUTION_FULFILL;
pub const GLOWCAP_RESOLUTION_BREAK = abi.GLOWCAP_RESOLUTION_BREAK;
pub const GLOWCAP_RESOLUTION_HANDOFF = abi.GLOWCAP_RESOLUTION_HANDOFF;

// Reference/argument struct layouts (shared leaf).
pub const GlowcapReference = abi.GlowcapReference;
pub const GlowcapArgument = abi.GlowcapArgument;

// The typed local dispatch-failure projection (shared leaf, so the byte-fed
// driver family reads its connections' aborts through the same layout).
pub const GLOWCAP_ABORT_DOMAIN_CODEC = abi.GLOWCAP_ABORT_DOMAIN_CODEC;
pub const GLOWCAP_ABORT_DOMAIN_SESSION = abi.GLOWCAP_ABORT_DOMAIN_SESSION;
pub const GLOWCAP_ABORT_DOMAIN_FOREIGN = abi.GLOWCAP_ABORT_DOMAIN_FOREIGN;
pub const GlowcapLastAbort = abi.GlowcapLastAbort;
pub const GlowcapLocatorHintView = abi.GlowcapLocatorHintView;
pub const GlowcapLocatorView = abi.GlowcapLocatorView;
pub const GLOWCAP_LOCATOR_VIEW_ABI_VERSION = abi.GLOWCAP_LOCATOR_VIEW_ABI_VERSION;
pub const GLOWCAP_HINT_STRING = abi.GLOWCAP_HINT_STRING;
pub const GLOWCAP_HINT_BYTES = abi.GLOWCAP_HINT_BYTES;
pub const GLOWCAP_HINT_BOOLEAN = abi.GLOWCAP_HINT_BOOLEAN;
pub const GLOWCAP_HINT_INTEGER = abi.GLOWCAP_HINT_INTEGER;
pub const GLOWCAP_HINTS_MAP = abi.GLOWCAP_HINTS_MAP;
pub const GLOWCAP_HINTS_BOOLEAN_FALSE = abi.GLOWCAP_HINTS_BOOLEAN_FALSE;

// ── OCapN locator handle ─────────────────────────────────────────────────────

/// An owned OCapN peer locator, read through `glowcap_locator_*` and released
/// with `glowcap_locator_release`.
pub const GlowcapLocator = opaque {};

/// An owned OCapN sturdyref. Its embedded peer locator and authority-bearing
/// swissnum remain distinct and are released together.
pub const GlowcapSturdyRef = opaque {};

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
/// message length. To receive the whole message pass a buffer of that length
/// plus one. `out_buf == NULL` or `cap == 0` queries the length. errno-style:
/// meaningful only right after a call that returned a cause-bearing code
/// (`_IO`, or the address-parse `_INVALID_ARGUMENT`). A later success does not
/// clear it. Returns 0 when none is set.
pub export fn glowcap_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return abi.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's last error slot.
pub export fn glowcap_clear_last_error() void {
    abi.lastErrorClear();
}

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family files; the plain `@import`s
// above already compile them into the library. These re-exports also surface them
// as members of the `c_abi` namespace so `tools/gen/header/ocapn.zig`, which reflects
// over `c_abi`, sees the full ABI from one root.

pub const glowcap_context_new = context.glowcap_context_new;
pub const glowcap_context_new_with_allocator = context.glowcap_context_new_with_allocator;
pub const glowcap_context_allocate_lifecycle_id = context.glowcap_context_allocate_lifecycle_id;
pub const glowcap_context_report_failure = context.glowcap_context_report_failure;
pub const glowcap_context_next_failure = context.glowcap_context_next_failure;
pub const glowcap_context_release = context.glowcap_context_release;

pub const glowcap_managed_frame_release = frame.glowcap_managed_frame_release;

pub const glowcap_uri_parse_peer = uri.glowcap_uri_parse_peer;
pub const glowcap_uri_parse_peer_in = uri.glowcap_uri_parse_peer_in;
pub const glowcap_uri_parse_sturdyref = uri.glowcap_uri_parse_sturdyref;
pub const glowcap_uri_parse_sturdyref_in = uri.glowcap_uri_parse_sturdyref_in;
pub const glowcap_uri_format_peer = uri.glowcap_uri_format_peer;
pub const glowcap_uri_format_sturdyref = uri.glowcap_uri_format_sturdyref;
pub const glowcap_locator_new = uri.glowcap_locator_new;
pub const glowcap_locator_new_in = uri.glowcap_locator_new_in;
pub const glowcap_locator_clone = uri.glowcap_locator_clone;
pub const glowcap_locator_clone_in = uri.glowcap_locator_clone_in;
pub const glowcap_locator_borrow_view = uri.glowcap_locator_borrow_view;
pub const glowcap_sturdyref_borrow_locator = uri.glowcap_sturdyref_borrow_locator;
pub const glowcap_sturdyref_swissnum = uri.glowcap_sturdyref_swissnum;
pub const glowcap_sturdyref_release = uri.glowcap_sturdyref_release;
pub const glowcap_locator_add_string = uri.glowcap_locator_add_string;
pub const glowcap_locator_add_bytes = uri.glowcap_locator_add_bytes;
pub const glowcap_locator_add_boolean = uri.glowcap_locator_add_boolean;
pub const glowcap_locator_add_integer = uri.glowcap_locator_add_integer;
pub const glowcap_locator_transport = uri.glowcap_locator_transport;
pub const glowcap_locator_designator = uri.glowcap_locator_designator;
pub const glowcap_locator_host_port = uri.glowcap_locator_host_port;
pub const glowcap_designator_host_port = uri.glowcap_designator_host_port;
pub const glowcap_locator_hint = uri.glowcap_locator_hint;
pub const glowcap_locator_hint_count = uri.glowcap_locator_hint_count;
pub const glowcap_locator_hint_at = uri.glowcap_locator_hint_at;
pub const glowcap_locator_hint_wire_form = uri.glowcap_locator_hint_wire_form;
pub const glowcap_locator_release = uri.glowcap_locator_release;
pub const glowcap_locator_record_encode = uri_record.glowcap_locator_record_encode;
pub const glowcap_locator_record_bytes_release = uri_record.glowcap_locator_record_bytes_release;

comptime {
    // Force the family files' `export fn`s into the compilation even if the
    // re-exports above are ever pruned. A plain reference is enough.
    _ = context;
    _ = frame;
    _ = uri;
    _ = uri_record;
}
