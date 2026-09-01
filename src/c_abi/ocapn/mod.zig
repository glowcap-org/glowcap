//! Shared C vocabulary for pancake's composable archives: allocation contexts,
//! frames, values, locators, URI grammar, and return codes. CapTP application
//! work enters through `libpancake_host`; the protocol engine remains a native
//! Zig surface.
//!
//! This file is the crate root: it owns the shared vocabulary (return codes,
//! discriminants, the C-visible types) and the per-thread last-error boundary,
//! then pulls in the handle-family files so every `export fn` they declare is
//! compiled into the library. The families are `context` (allocation policy),
//! `frame` (managed-frame ownership), and `uri` (the OCapN locator grammar).
//! This archive is sans-io: the transports
//! (`libpancake_net_transport_*`) carry the netlayer handles in their own
//! companion modules (ADR-0059). Each family `@import`s this root for the shared
//! types and codes; this root re-exports their `export fn`s so the header
//! generator, which reflects over the `c_abi` namespace, sees the full ABI in
//! one place.
//! The allocator behind a context may be called from transport threads, so a
//! caller-supplied allocator must be thread-safe. `pancake_last_error` reports
//! the calling thread's last error.

/// Shared C-ABI vocabulary factored into a leaf module with no `export fn`, so the
/// iroh transport ABI can reuse it without inheriting libpancake_ocapn's exported
/// surface (ADR-0055 companion split). Re-exported here so the handle-family files
/// and `tools/gen/header/ocapn.zig` see the full vocabulary from this root.
const abi = @import("c_abi_shared");

const context = @import("context.zig");
const frame = @import("frame.zig");
const uri = @import("uri.zig");
const uri_record = @import("uri/record.zig");

/// ABI version the library implements. While `major` is 0 the ABI is unstable
/// (see `pancake_ocapn.h`); the shared library's soname tracks `major`.
pub const PANCAKE_VERSION_MAJOR: u32 = 0;
pub const PANCAKE_VERSION_MINOR: u32 = 1;
pub const PANCAKE_VERSION_PATCH: u32 = 0;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");
pub const contract_layouts = abi.contract_layouts;

/// Exact reflected callable/layout identity for the core archive.
pub const PANCAKE_OCAPN_ARCHIVE_FINGERPRINT = abi.archive_contract.fingerprint(
    "ocapn",
    @This(),
    .{abi.contract_layouts},
);

pub export fn pancake_ocapn_archive_fingerprint() u64 {
    return PANCAKE_OCAPN_ARCHIVE_FINGERPRINT;
}

/// Report the ABI version the linked library implements. Any out-pointer may be
/// null to skip that component. Lets a consumer detect header/library skew by
/// comparing against the `PANCAKE_VERSION_*` macros it compiled against.
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
pub const PANCAKE_ERR_TIMEOUT = abi.PANCAKE_ERR_TIMEOUT;

pub const PANCAKE_CAPTP_V1_0 = abi.PANCAKE_CAPTP_V1_0;
pub const PANCAKE_CAPTP_NEXT = abi.PANCAKE_CAPTP_NEXT;
pub const PANCAKE_CODEC_UNKNOWN = abi.PANCAKE_CODEC_UNKNOWN;
pub const PANCAKE_CODEC_SYRUP = abi.PANCAKE_CODEC_SYRUP;
pub const PANCAKE_CODEC_CAPNP = abi.PANCAKE_CODEC_CAPNP;
pub const PANCAKE_FEATURE_PIPELINING = abi.PANCAKE_FEATURE_PIPELINING;
pub const PANCAKE_FEATURE_HANDOFF = abi.PANCAKE_FEATURE_HANDOFF;
pub const PANCAKE_FEATURE_WIRE_DELTA = abi.PANCAKE_FEATURE_WIRE_DELTA;
pub const PANCAKE_FEATURE_STURDYREF = abi.PANCAKE_FEATURE_STURDYREF;
pub const PANCAKE_FEATURE_UNTAG = abi.PANCAKE_FEATURE_UNTAG;
pub const PANCAKE_FEATURE_MULTI_LOCATION = abi.PANCAKE_FEATURE_MULTI_LOCATION;
pub const PANCAKE_FEATURE_MINIMUM = abi.PANCAKE_FEATURE_MINIMUM;
pub const PANCAKE_FEATURE_FULL = abi.PANCAKE_FEATURE_FULL;
pub const PANCAKE_FEATURE_BASELINE = abi.PANCAKE_FEATURE_BASELINE;
pub const PANCAKE_DEFAULT_CODEC = abi.PANCAKE_DEFAULT_CODEC;
pub const PANCAKE_DEFAULT_CAPTP_VERSION = abi.PANCAKE_DEFAULT_CAPTP_VERSION;
pub const PANCAKE_DEFAULT_FEATURES = abi.PANCAKE_DEFAULT_FEATURES;
pub const PANCAKE_INTEROP_CODEC = abi.PANCAKE_INTEROP_CODEC;
pub const PANCAKE_INTEROP_CAPTP_VERSION = abi.PANCAKE_INTEROP_CAPTP_VERSION;
pub const PANCAKE_NATIVE_CODEC = abi.PANCAKE_NATIVE_CODEC;
pub const PANCAKE_NATIVE_CAPTP_VERSION = abi.PANCAKE_NATIVE_CAPTP_VERSION;

/// Decode a `PANCAKE_CODEC_*` value, or null for anything outside the family.
pub const codecFromC = abi.codecFromC;
/// Encode a Zig codec id as a C built-in selector, or UNKNOWN for non-built-ins.
pub const codecToC = abi.codecToC;
/// Encode/decode the `PANCAKE_FEATURE_*` bitmask for Zig tests and generators.
pub const featureSetToC = abi.featureSetToC;
pub const featureSetFromC = abi.featureSetFromC;

pub const PANCAKE_FRAME_SHAPE_BYTE = abi.PANCAKE_FRAME_SHAPE_BYTE;
pub const PANCAKE_FRAME_SHAPE_WORD = abi.PANCAKE_FRAME_SHAPE_WORD;
pub const PANCAKE_RAW_TRANSPORT_DEFAULT_FRAME_CAP = abi.connection.raw_transport_default_frame_cap;
pub const PANCAKE_DEFAULT_FAILURE_CAPACITY = abi.default_failure_capacity;
pub const PANCAKE_DEFAULT_FAILURE_PAYLOAD_CAP = abi.default_failure_payload_cap;

// Borrowed/owned frame types (shared leaf).
pub const PancakeFrame = abi.PancakeFrame;
pub const ReleaseFn = abi.ReleaseFn;
pub const PancakeManagedFrame = abi.PancakeManagedFrame;

// ── Allocation context ───────────────────────────────────────────────────────

// Host allocator surface (shared leaf).
pub const PancakeAllocFn = abi.PancakeAllocFn;
pub const PancakeFreeFn = abi.PancakeFreeFn;
pub const PancakeAllocator = abi.PancakeAllocator;
pub const PancakeContext = abi.PancakeContext;
pub const PancakeFailureEvent = abi.PancakeFailureEvent;
pub const PancakeFailureReport = abi.PancakeFailureReport;
pub const PANCAKE_FAILURE_EVENT_ABI_VERSION = abi.PANCAKE_FAILURE_EVENT_ABI_VERSION;
pub const PANCAKE_FAILURE_LAYER_CORE = abi.PANCAKE_FAILURE_LAYER_CORE;
pub const PANCAKE_FAILURE_LAYER_DRIVER = abi.PANCAKE_FAILURE_LAYER_DRIVER;
pub const PANCAKE_FAILURE_LAYER_TRANSPORT = abi.PANCAKE_FAILURE_LAYER_TRANSPORT;
pub const PANCAKE_FAILURE_LAYER_BINDING = abi.PANCAKE_FAILURE_LAYER_BINDING;
pub const PANCAKE_FAILURE_LAYER_APPLICATION_OBSERVER = abi.PANCAKE_FAILURE_LAYER_APPLICATION_OBSERVER;
pub const PANCAKE_FAILURE_SCOPE_PROCESS = abi.PANCAKE_FAILURE_SCOPE_PROCESS;
pub const PANCAKE_FAILURE_SCOPE_CONTEXT = abi.PANCAKE_FAILURE_SCOPE_CONTEXT;
pub const PANCAKE_FAILURE_SCOPE_HOST = abi.PANCAKE_FAILURE_SCOPE_HOST;
pub const PANCAKE_FAILURE_SCOPE_SESSION = abi.PANCAKE_FAILURE_SCOPE_SESSION;
pub const PANCAKE_FAILURE_SCOPE_LISTENER = abi.PANCAKE_FAILURE_SCOPE_LISTENER;
pub const PANCAKE_FAILURE_SCOPE_TRANSPORT = abi.PANCAKE_FAILURE_SCOPE_TRANSPORT;
pub const PANCAKE_FAILURE_SCOPE_OPERATION = abi.PANCAKE_FAILURE_SCOPE_OPERATION;
pub const PANCAKE_FAILURE_TRUNCATED_OPERATION = abi.PANCAKE_FAILURE_TRUNCATED_OPERATION;
pub const PANCAKE_FAILURE_TRUNCATED_PRIMARY_NAME = abi.PANCAKE_FAILURE_TRUNCATED_PRIMARY_NAME;
pub const PANCAKE_FAILURE_TRUNCATED_PRIMARY_MESSAGE = abi.PANCAKE_FAILURE_TRUNCATED_PRIMARY_MESSAGE;
pub const PANCAKE_FAILURE_TRUNCATED_SECONDARY_NAME = abi.PANCAKE_FAILURE_TRUNCATED_SECONDARY_NAME;
pub const PANCAKE_FAILURE_TRUNCATED_SECONDARY_MESSAGE = abi.PANCAKE_FAILURE_TRUNCATED_SECONDARY_MESSAGE;

// Application value discriminants and structs (shared leaf).
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
pub const PANCAKE_ARG_STRUCT = abi.PANCAKE_ARG_STRUCT;
pub const PANCAKE_ARG_ERROR = abi.PANCAKE_ARG_ERROR;

pub const PANCAKE_RESOLUTION_FULFILL = abi.PANCAKE_RESOLUTION_FULFILL;
pub const PANCAKE_RESOLUTION_BREAK = abi.PANCAKE_RESOLUTION_BREAK;
pub const PANCAKE_RESOLUTION_HANDOFF = abi.PANCAKE_RESOLUTION_HANDOFF;

// Reference/argument struct layouts (shared leaf).
pub const PancakeReference = abi.PancakeReference;
pub const PancakeArgument = abi.PancakeArgument;

// The typed local dispatch-failure projection (shared leaf, so the byte-fed
// driver family reads its connections' aborts through the same layout).
pub const PANCAKE_ABORT_DOMAIN_CODEC = abi.PANCAKE_ABORT_DOMAIN_CODEC;
pub const PANCAKE_ABORT_DOMAIN_SESSION = abi.PANCAKE_ABORT_DOMAIN_SESSION;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN = abi.PANCAKE_ABORT_DOMAIN_FOREIGN;
pub const PancakeLastAbort = abi.PancakeLastAbort;
pub const PancakeLocatorHintView = abi.PancakeLocatorHintView;
pub const PancakeLocatorView = abi.PancakeLocatorView;
pub const PANCAKE_LOCATOR_VIEW_ABI_VERSION = abi.PANCAKE_LOCATOR_VIEW_ABI_VERSION;
pub const PANCAKE_HINT_STRING = abi.PANCAKE_HINT_STRING;
pub const PANCAKE_HINT_BYTES = abi.PANCAKE_HINT_BYTES;
pub const PANCAKE_HINT_BOOLEAN = abi.PANCAKE_HINT_BOOLEAN;
pub const PANCAKE_HINT_INTEGER = abi.PANCAKE_HINT_INTEGER;
pub const PANCAKE_HINTS_MAP = abi.PANCAKE_HINTS_MAP;
pub const PANCAKE_HINTS_BOOLEAN_FALSE = abi.PANCAKE_HINTS_BOOLEAN_FALSE;

// ── OCapN locator handle ─────────────────────────────────────────────────────

/// An owned OCapN peer locator, read through `pancake_locator_*` and released
/// with `pancake_locator_release`.
pub const PancakeLocator = opaque {};

/// An owned OCapN sturdyref. Its embedded peer locator and authority-bearing
/// swissnum remain distinct and are released together.
pub const PancakeSturdyRef = opaque {};

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
pub const pancake_context_allocate_lifecycle_id = context.pancake_context_allocate_lifecycle_id;
pub const pancake_context_report_failure = context.pancake_context_report_failure;
pub const pancake_context_next_failure = context.pancake_context_next_failure;
pub const pancake_context_release = context.pancake_context_release;

pub const pancake_managed_frame_release = frame.pancake_managed_frame_release;

pub const pancake_uri_parse_peer = uri.pancake_uri_parse_peer;
pub const pancake_uri_parse_peer_in = uri.pancake_uri_parse_peer_in;
pub const pancake_uri_parse_sturdyref = uri.pancake_uri_parse_sturdyref;
pub const pancake_uri_parse_sturdyref_in = uri.pancake_uri_parse_sturdyref_in;
pub const pancake_uri_format_peer = uri.pancake_uri_format_peer;
pub const pancake_uri_format_sturdyref = uri.pancake_uri_format_sturdyref;
pub const pancake_locator_new = uri.pancake_locator_new;
pub const pancake_locator_new_in = uri.pancake_locator_new_in;
pub const pancake_locator_clone = uri.pancake_locator_clone;
pub const pancake_locator_clone_in = uri.pancake_locator_clone_in;
pub const pancake_locator_borrow_view = uri.pancake_locator_borrow_view;
pub const pancake_sturdyref_borrow_locator = uri.pancake_sturdyref_borrow_locator;
pub const pancake_sturdyref_swissnum = uri.pancake_sturdyref_swissnum;
pub const pancake_sturdyref_release = uri.pancake_sturdyref_release;
pub const pancake_locator_add_string = uri.pancake_locator_add_string;
pub const pancake_locator_add_bytes = uri.pancake_locator_add_bytes;
pub const pancake_locator_add_boolean = uri.pancake_locator_add_boolean;
pub const pancake_locator_add_integer = uri.pancake_locator_add_integer;
pub const pancake_locator_transport = uri.pancake_locator_transport;
pub const pancake_locator_designator = uri.pancake_locator_designator;
pub const pancake_locator_host_port = uri.pancake_locator_host_port;
pub const pancake_designator_host_port = uri.pancake_designator_host_port;
pub const pancake_locator_hint = uri.pancake_locator_hint;
pub const pancake_locator_hint_count = uri.pancake_locator_hint_count;
pub const pancake_locator_hint_at = uri.pancake_locator_hint_at;
pub const pancake_locator_hint_wire_form = uri.pancake_locator_hint_wire_form;
pub const pancake_locator_release = uri.pancake_locator_release;
pub const pancake_locator_record_encode = uri_record.pancake_locator_record_encode;
pub const pancake_locator_record_bytes_release = uri_record.pancake_locator_record_bytes_release;

comptime {
    // Force the family files' `export fn`s into the compilation even if the
    // re-exports above are ever pruned; a plain reference is enough.
    _ = context;
    _ = frame;
    _ = uri;
    _ = uri_record;
}
