//! Generates the Rust, Python, and Racket ABI constant mirrors.
//!
//! Numeric values reflect the C ABI roots. Transport strings reflect
//! `model.transport`, and binding-only policy comes from `binding_policy`.
//! A new binding adds one emitter and one `outputs` row; the reflected table
//! remains the only place this family names a value.

const std = @import("std");

const c = @import("c_abi");
const cd = @import("c_abi_host");
const ci = @import("c_abi_net_transport_iroh");
const cdr = @import("c_abi_driver");
const cw = @import("c_abi_net_transport_webrtc");
const ct = @import("c_abi_net_transport_tcp");
const cn = @import("c_abi_net_transport_inproc");
const co = @import("c_abi_net_transport_onion");
const cr = @import("c_abi_net_transport_relay");
const model = @import("model");
const binding_policy = @import("binding_policy");

const Output = @import("output").Output;

pub const step_name = "gen-binding-constants";

pub const outputs = [_]Output{
    .{ .path = "bindings/rust/src/abi_constants_gen.rs", .generate = generateRust },
    .{ .path = "bindings/rust/relay/src/policy_gen.rs", .generate = generateRustRelay },
    .{ .path = "bindings/python/pancake/_constants_gen.py", .generate = generatePython },
    .{ .path = "bindings/racket/private/constants-gen.rkt", .generate = generateRacket },
};

/// The Rust storage type for a reflected constant. Python and Racket are
/// untyped, so this steers only the Rust emitter: a return code is `c_int`,
/// an enum kind is `c_uint`, and a size or count is `usize`.
const RustTy = enum {
    int,
    uint,
    usize,
    u64,

    fn spelling(self: RustTy) []const u8 {
        return switch (self) {
            .int => "c_int",
            .uint => "c_uint",
            .usize => "usize",
            .u64 => "u64",
        };
    }
};

/// One reflected integer constant. `stem` is the canonical SCREAMING_SNAKE
/// name Rust and Python emit verbatim and Racket kebab-cases. `rkt` overrides
/// the Racket name only where the binding's established spelling is not the
/// mechanical kebab of `stem`. `value` is taken from the C ABI declaration, so
/// it cannot be hand-typed and drift.
const Const = struct {
    stem: []const u8,
    value: i128,
    rust_ty: RustTy,
    rkt: ?[]const u8 = null,
};

fn con(comptime stem: []const u8, value: anytype, rust_ty: RustTy, rkt: ?[]const u8) Const {
    return .{ .stem = stem, .value = @intCast(value), .rust_ty = rust_ty, .rkt = rkt };
}

// TypeScript uses its own generator because it also emits struct layouts and a
// smaller, host-shaped constant set. Both generators reflect the same Zig
// declarations, so values still have one source without a hard-to-read
// inclusion matrix.
const constants = [_]Const{
    // Return codes (c_int). The bindings branch on a few and keep the family
    // whole so a member that rounds out the enum stays even while unread.
    con("OK", c.PANCAKE_OK, .int, null),
    con("WOULD_BLOCK", c.PANCAKE_ERR_WOULD_BLOCK, .int, null),
    con("ERR_NULL_POINTER", c.PANCAKE_ERR_NULL_POINTER, .int, null),
    con("ERR_INVALID_ARGUMENT", c.PANCAKE_ERR_INVALID_ARGUMENT, .int, null),
    con("ERR_SESSION", c.PANCAKE_ERR_SESSION, .int, null),
    con("ERR_CODEC", c.PANCAKE_ERR_CODEC, .int, null),
    con("ERR_INTERNAL", c.PANCAKE_ERR_INTERNAL, .int, null),
    con("ERR_CLOSED", c.PANCAKE_ERR_CLOSED, .int, null),
    con("ERR_IO", c.PANCAKE_ERR_IO, .int, null),
    con("ERR_MALFORMED", c.PANCAKE_ERR_MALFORMED, .int, null),
    con("ERR_FRAME_TOO_LARGE", c.PANCAKE_ERR_FRAME_TOO_LARGE, .int, null),
    con("ERR_UNSUPPORTED_VALUE", c.PANCAKE_ERR_UNSUPPORTED_VALUE, .int, null),
    con("ERR_BROKEN", c.PANCAKE_ERR_BROKEN, .int, null),
    con("ERR_NOT_FOUND", c.PANCAKE_ERR_NOT_FOUND, .int, null),
    con("ERR_BUFFER_TOO_SMALL", c.PANCAKE_ERR_BUFFER_TOO_SMALL, .int, null),
    con("ERR_TIMEOUT", c.PANCAKE_ERR_TIMEOUT, .int, null),
    // Structured diagnostic vocabulary (c_uint).
    con("FAILURE_LAYER_CORE", c.PANCAKE_FAILURE_LAYER_CORE, .uint, null),
    con("FAILURE_LAYER_DRIVER", c.PANCAKE_FAILURE_LAYER_DRIVER, .uint, null),
    con("FAILURE_LAYER_TRANSPORT", c.PANCAKE_FAILURE_LAYER_TRANSPORT, .uint, null),
    con("FAILURE_LAYER_BINDING", c.PANCAKE_FAILURE_LAYER_BINDING, .uint, null),
    con("FAILURE_LAYER_APPLICATION_OBSERVER", c.PANCAKE_FAILURE_LAYER_APPLICATION_OBSERVER, .uint, null),
    con("FAILURE_SCOPE_PROCESS", c.PANCAKE_FAILURE_SCOPE_PROCESS, .uint, null),
    con("FAILURE_SCOPE_CONTEXT", c.PANCAKE_FAILURE_SCOPE_CONTEXT, .uint, null),
    con("FAILURE_SCOPE_HOST", c.PANCAKE_FAILURE_SCOPE_HOST, .uint, null),
    con("FAILURE_SCOPE_SESSION", c.PANCAKE_FAILURE_SCOPE_SESSION, .uint, null),
    con("FAILURE_SCOPE_LISTENER", c.PANCAKE_FAILURE_SCOPE_LISTENER, .uint, null),
    con("FAILURE_SCOPE_TRANSPORT", c.PANCAKE_FAILURE_SCOPE_TRANSPORT, .uint, null),
    con("FAILURE_SCOPE_OPERATION", c.PANCAKE_FAILURE_SCOPE_OPERATION, .uint, null),
    // Frame shape (c_uint).
    con("FRAME_SHAPE_BYTE", c.PANCAKE_FRAME_SHAPE_BYTE, .uint, null),
    // Argument kinds (c_uint).
    con("ARG_INTEGER", c.PANCAKE_ARG_INTEGER, .uint, null),
    con("ARG_FLOAT64", c.PANCAKE_ARG_FLOAT64, .uint, null),
    con("ARG_BOOLEAN", c.PANCAKE_ARG_BOOLEAN, .uint, null),
    con("ARG_BYTES", c.PANCAKE_ARG_BYTES, .uint, null),
    con("ARG_STRING", c.PANCAKE_ARG_STRING, .uint, null),
    con("ARG_SYMBOL", c.PANCAKE_ARG_SYMBOL, .uint, null),
    con("ARG_VOID", c.PANCAKE_ARG_VOID, .uint, null),
    con("ARG_REFERENCE", c.PANCAKE_ARG_REFERENCE, .uint, null),
    con("ARG_LIST", c.PANCAKE_ARG_LIST, .uint, null),
    con("ARG_SET", c.PANCAKE_ARG_SET, .uint, null),
    con("ARG_TAGGED", c.PANCAKE_ARG_TAGGED, .uint, null),
    con("ARG_KEYWORD", c.PANCAKE_ARG_KEYWORD, .uint, null),
    con("ARG_BIG_INTEGER", c.PANCAKE_ARG_BIG_INTEGER, .uint, null),
    con("ARG_STRUCT", c.PANCAKE_ARG_STRUCT, .uint, null),
    con("ARG_ERROR", c.PANCAKE_ARG_ERROR, .uint, null),
    // Wire-grammar codec selectors (c_uint).
    con("CODEC_UNKNOWN", c.PANCAKE_CODEC_UNKNOWN, .uint, null),
    con("CODEC_SYRUP", c.PANCAKE_CODEC_SYRUP, .uint, null),
    con("CODEC_CAPNP", c.PANCAKE_CODEC_CAPNP, .uint, null),
    con("CAPTP_V1_0", c.PANCAKE_CAPTP_V1_0, .uint, null),
    con("CAPTP_NEXT", c.PANCAKE_CAPTP_NEXT, .uint, null),
    con("FEATURE_PIPELINING", c.PANCAKE_FEATURE_PIPELINING, .uint, null),
    con("FEATURE_HANDOFF", c.PANCAKE_FEATURE_HANDOFF, .uint, null),
    con("FEATURE_WIRE_DELTA", c.PANCAKE_FEATURE_WIRE_DELTA, .uint, null),
    con("FEATURE_STURDYREF", c.PANCAKE_FEATURE_STURDYREF, .uint, null),
    con("FEATURE_UNTAG", c.PANCAKE_FEATURE_UNTAG, .uint, null),
    con("FEATURE_MINIMUM", c.PANCAKE_FEATURE_MINIMUM, .uint, null),
    con("FEATURE_BASELINE", c.PANCAKE_FEATURE_BASELINE, .uint, null),
    con("FEATURE_FULL", c.PANCAKE_FEATURE_FULL, .uint, null),
    con("DEFAULT_CODEC", c.PANCAKE_DEFAULT_CODEC, .uint, null),
    con("DEFAULT_CAPTP_VERSION", c.PANCAKE_DEFAULT_CAPTP_VERSION, .uint, null),
    con("DEFAULT_FEATURES", c.PANCAKE_DEFAULT_FEATURES, .uint, null),
    // PancakeLastAbort.domain (c_uint).
    con("ABORT_DOMAIN_CODEC", c.PANCAKE_ABORT_DOMAIN_CODEC, .uint, null),
    con("ABORT_DOMAIN_SESSION", c.PANCAKE_ABORT_DOMAIN_SESSION, .uint, null),
    con("ABORT_DOMAIN_FOREIGN", c.PANCAKE_ABORT_DOMAIN_FOREIGN, .uint, null),
    // Callerless-failure journal defaults (libpancake_ocapn). Bindings use
    // the same bounded schema for their runtime-local fallback journals.
    con("DEFAULT_FAILURE_CAPACITY", c.PANCAKE_DEFAULT_FAILURE_CAPACITY, .usize, null),
    con("DEFAULT_FAILURE_PAYLOAD_CAP", c.PANCAKE_DEFAULT_FAILURE_PAYLOAD_CAP, .usize, null),
    // Host trace event kinds (c_uint, libpancake_host).
    con("TRACE_SESSION_OPEN", cd.PANCAKE_TRACE_SESSION_OPEN, .uint, null),
    con("TRACE_MESSAGE", cd.PANCAKE_TRACE_MESSAGE, .uint, null),
    con("TRACE_SESSION_CLOSE", cd.PANCAKE_TRACE_SESSION_CLOSE, .uint, null),
    con("TRACE_DIGEST_BYTES", cd.PANCAKE_TRACE_DIGEST_BYTES, .uint, null),
    con("PENDING_CANCEL", cd.PANCAKE_PENDING_CANCEL, .uint, null),
    con("PENDING_FINISH", cd.PANCAKE_PENDING_FINISH, .uint, null),
    con("LIFECYCLE_ACTIVE", cd.PANCAKE_LIFECYCLE_ACTIVE, .uint, null),
    con("LIFECYCLE_FINISHING", cd.PANCAKE_LIFECYCLE_FINISHING, .uint, null),
    con("LIFECYCLE_TERMINATING", cd.PANCAKE_LIFECYCLE_TERMINATING, .uint, null),
    con("LIFECYCLE_CLOSED", cd.PANCAKE_LIFECYCLE_CLOSED, .uint, null),
    con("DESIGNATOR_SCHEME_ADDRESS", cd.PANCAKE_DESIGNATOR_SCHEME_ADDRESS, .uint, null),
    con("DESIGNATOR_SCHEME_KEY", cd.PANCAKE_DESIGNATOR_SCHEME_KEY, .uint, null),
    // PancakePartnerIdentity.provenance: how the partner's advertised durable
    // identity was authenticated (ADR-0097).
    con("DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT", cd.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT, .uint, null),
    con("DURABLE_PROVENANCE_UNAUTHENTICATED", cd.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED, .uint, null),
    // Frame-cap defaults: Host protocol admission comes from libpancake_host;
    // the direct raw transport helper default comes from shared C vocabulary.
    con("DEFAULT_FRAME_CAP", cd.PANCAKE_DEFAULT_FRAME_CAP, .usize, null),
    con("RAW_TRANSPORT_DEFAULT_FRAME_CAP", c.PANCAKE_RAW_TRANSPORT_DEFAULT_FRAME_CAP, .usize, null),
    // Local Forward hop bound (usize, libpancake_host).
    con("MAX_LOCAL_FORWARD_HOPS", cd.PANCAKE_MAX_LOCAL_FORWARD_HOPS, .usize, null),
    con("HANDSHAKE_TIMEOUT_MS", cd.PANCAKE_HANDSHAKE_TIMEOUT_MS, .usize, null),
    con("HOST_OUTBOUND_PREFIX_CAP", cd.PANCAKE_HOST_OUTBOUND_PREFIX_CAP, .usize, null),
    con("HOST_DURABLE_ENTROPY_LEN", cd.PANCAKE_HOST_DURABLE_ENTROPY_LEN, .usize, null),
    con("HOST_DURABLE_SWISS_LEN", cd.PANCAKE_HOST_DURABLE_SWISS_LEN, .usize, null),
    con("DEFAULT_PENDING_ACCEPTS", cd.PANCAKE_DEFAULT_PENDING_ACCEPTS, .usize, null),
    con("DEFAULT_HANDSHAKE_CONCURRENCY", cd.PANCAKE_DEFAULT_HANDSHAKE_CONCURRENCY, .usize, null),
    con("MAX_HANDSHAKE_CONCURRENCY", cd.PANCAKE_MAX_HANDSHAKE_CONCURRENCY, .usize, null),
    con("DISCOVERY_DIAL_RETRY_MS", cd.PANCAKE_DISCOVERY_DIAL_RETRY_MS, .usize, null),
    con("DISCOVERY_DIAL_MAX_ATTEMPTS", cd.PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS, .usize, null),
    // Iroh reachability postures and the redeem knob's starting value (c_uint,
    // libpancake_net_transport_iroh, reflected through the sidecar stub so this
    // stays cargo-free). Each binding's `Reachability` surface and its
    // hint-less-redeem default read these instead of hand-typing the numbers.
    // PancakeDriverEvent.kind values the driver archive's event queue carries.
    con("CLOSE_OPTIONS_ABI_VERSION", cd.PANCAKE_CLOSE_OPTIONS_ABI_VERSION, .uint, null),
    con("CLOSE_MAX_GRACE_MS", cd.PANCAKE_CLOSE_MAX_GRACE_MS, .uint, null),
    con("CLOSE_GRACE_UNSPECIFIED", cd.PANCAKE_CLOSE_GRACE_UNSPECIFIED, .uint, null),
    con("CLOSE_GRACE_FINITE", cd.PANCAKE_CLOSE_GRACE_FINITE, .uint, null),
    con("CLOSE_GRACE_UNBOUNDED", cd.PANCAKE_CLOSE_GRACE_UNBOUNDED, .uint, null),
    con("DRIVER_OPTIONS_ABI_VERSION", cdr.PANCAKE_DRIVER_OPTIONS_ABI_VERSION, .uint, null),
    con("DRIVER_FAILURE_ABI_VERSION", cdr.PANCAKE_DRIVER_FAILURE_ABI_VERSION, .uint, null),
    con("CARRIER_PHASE_NONE", cdr.PANCAKE_CARRIER_PHASE_NONE, .uint, null),
    con("CARRIER_PHASE_RESOLVE", cdr.PANCAKE_CARRIER_PHASE_RESOLVE, .uint, null),
    con("CARRIER_PHASE_CONNECT", cdr.PANCAKE_CARRIER_PHASE_CONNECT, .uint, null),
    con("CARRIER_PHASE_SECURE_HANDSHAKE", cdr.PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE, .uint, null),
    con("CARRIER_PHASE_WEBSOCKET_UPGRADE", cdr.PANCAKE_CARRIER_PHASE_WEBSOCKET_UPGRADE, .uint, null),
    con("CARRIER_PHASE_REGISTRATION", cdr.PANCAKE_CARRIER_PHASE_REGISTRATION, .uint, null),
    con("CARRIER_PHASE_RECEIVE", cdr.PANCAKE_CARRIER_PHASE_RECEIVE, .uint, null),
    con("CARRIER_PHASE_TRANSMIT", cdr.PANCAKE_CARRIER_PHASE_TRANSMIT, .uint, null),
    con("CARRIER_PHASE_SHUTDOWN", cdr.PANCAKE_CARRIER_PHASE_SHUTDOWN, .uint, null),
    con("CARRIER_DETAIL_PEER_ALERT", cdr.PANCAKE_CARRIER_DETAIL_PEER_ALERT, .uint, null),
    con("CARRIER_DETAIL_ENGINE_CODE", cdr.PANCAKE_CARRIER_DETAIL_ENGINE_CODE, .uint, null),
    con("DRIVER_MAX_WAIT_MS", cdr.PANCAKE_DRIVER_MAX_WAIT_MS, .uint, null),
    con("DRIVER_DEFAULT_WIRE_BUFFER_BYTES", cdr.PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES, .usize, null),
    con("DRIVER_DEFAULT_MAX_PENDING_OPENS", cdr.PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS, .usize, null),
    con("DRIVER_DEFAULT_HANDSHAKE_MS", cdr.PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS, .uint, null),
    con("DRIVER_DEFAULT_LISTENER_SETUP_MS", cdr.PANCAKE_DRIVER_DEFAULT_LISTENER_SETUP_MS, .uint, null),
    con("DRIVER_DEFAULT_SETTLE_MS", cdr.PANCAKE_DRIVER_DEFAULT_SETTLE_MS, .uint, null),
    con("DRIVER_EVENT_OPENED", cdr.PANCAKE_DRIVER_EVENT_OPENED, .uint, null),
    con("DRIVER_EVENT_OPEN_FAILED", cdr.PANCAKE_DRIVER_EVENT_OPEN_FAILED, .uint, null),
    con("DRIVER_EVENT_ACCEPTED", cdr.PANCAKE_DRIVER_EVENT_ACCEPTED, .uint, null),
    con("DRIVER_EVENT_SESSION_CLOSED", cdr.PANCAKE_DRIVER_EVENT_SESSION_CLOSED, .uint, null),
    con("DRIVER_EVENT_COMPLETION", cdr.PANCAKE_DRIVER_EVENT_COMPLETION, .uint, null),
    con("DRIVER_EVENT_LISTENER_READY", cdr.PANCAKE_DRIVER_EVENT_LISTENER_READY, .uint, null),
    con("DRIVER_EVENT_LISTENER_FAILED", cdr.PANCAKE_DRIVER_EVENT_LISTENER_FAILED, .uint, null),
    con("LOCATOR_VIEW_ABI_VERSION", cdr.PANCAKE_LOCATOR_VIEW_ABI_VERSION, .uint, null),
    con("HINT_STRING", cdr.PANCAKE_HINT_STRING, .uint, null),
    con("HINT_BYTES", cdr.PANCAKE_HINT_BYTES, .uint, null),
    con("HINT_BOOLEAN", cdr.PANCAKE_HINT_BOOLEAN, .uint, null),
    con("HINT_INTEGER", cdr.PANCAKE_HINT_INTEGER, .uint, null),
    con("HINTS_MAP", cdr.PANCAKE_HINTS_MAP, .uint, null),
    con("HINTS_BOOLEAN_FALSE", cdr.PANCAKE_HINTS_BOOLEAN_FALSE, .uint, null),
    con("TCP_ARCHIVE_FINGERPRINT", ct.PANCAKE_TCP_ARCHIVE_FINGERPRINT, .u64, null),
    con("INPROC_ARCHIVE_FINGERPRINT", cn.PANCAKE_INPROC_ARCHIVE_FINGERPRINT, .u64, null),
    con("ONION_ARCHIVE_FINGERPRINT", co.PANCAKE_ONION_ARCHIVE_FINGERPRINT, .u64, null),
    con("ONION_AUTH_NONE", co.PANCAKE_ONION_AUTH_NONE, .uint, null),
    con("ONION_AUTH_COOKIE", co.PANCAKE_ONION_AUTH_COOKIE, .uint, null),
    con("ONION_AUTH_PASSWORD", co.PANCAKE_ONION_AUTH_PASSWORD, .uint, null),
    con("ONION_SERVICE_ID_LEN", co.PANCAKE_ONION_SERVICE_ID_LEN, .usize, null),
    con("ONION_SERVICE_KEY_CAP", co.PANCAKE_ONION_SERVICE_KEY_CAP, .usize, null),
    con("IROH_ARCHIVE_FINGERPRINT", ci.PANCAKE_IROH_ARCHIVE_FINGERPRINT, .u64, null),
    con("RELAY_ARCHIVE_FINGERPRINT", cr.PANCAKE_RELAY_ARCHIVE_FINGERPRINT, .u64, null),
    con("RELAY_CONFIG_ABI_VERSION", cr.PANCAKE_RELAY_CONFIG_ABI_VERSION, .uint, null),
    con("RELAY_TRUST_SYSTEM", cr.PANCAKE_RELAY_TRUST_SYSTEM, .uint, null),
    con("RELAY_TRUST_COPIED_PEM", cr.PANCAKE_RELAY_TRUST_COPIED_PEM, .uint, null),
    con("RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES", cr.PANCAKE_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES, .usize, null),
    con("WEBRTC_ARCHIVE_FINGERPRINT", cw.PANCAKE_WEBRTC_ARCHIVE_FINGERPRINT, .u64, null),
    con("IROH_REACH_DIRECT", ci.PANCAKE_IROH_REACH_DIRECT, .uint, null),
    con("IROH_REACH_DISCOVERY", ci.PANCAKE_IROH_REACH_DISCOVERY, .uint, null),
    con("IROH_REACH_DISCOVERY_NO_RELAY", ci.PANCAKE_IROH_REACH_DISCOVERY_NO_RELAY, .uint, null),
    con("IROH_REACH_LOCAL_DISCOVERY", ci.PANCAKE_IROH_REACH_LOCAL_DISCOVERY, .uint, null),
    con("IROH_REACH_REDEEM_DEFAULT", ci.PANCAKE_IROH_REACH_REDEEM_DEFAULT, .uint, null),
    con("IROH_NODE_ID_BYTES", ci.PANCAKE_IROH_NODE_ID_BYTES, .usize, null),
    con("IROH_MAX_DIRECT_ADDRESS_BYTES", ci.PANCAKE_IROH_MAX_DIRECT_ADDRESS_BYTES, .usize, null),
    // Iroh readiness event bits (c_uint, libpancake_net_transport_iroh): the
    // PANCAKE_IROH_EV_* bitset a drain_ready record carries.
    con("IROH_EV_READABLE", ci.PANCAKE_IROH_EV_READABLE, .uint, null),
    con("IROH_EV_WRITABLE", ci.PANCAKE_IROH_EV_WRITABLE, .uint, null),
    con("IROH_EV_CLOSED", ci.PANCAKE_IROH_EV_CLOSED, .uint, null),
    con("IROH_EV_ACCEPT", ci.PANCAKE_IROH_EV_ACCEPT, .uint, null),
    con("IROH_EV_CONNECT", ci.PANCAKE_IROH_EV_CONNECT, .uint, null),
    con("WEBRTC_EV_OPEN", cw.PANCAKE_WEBRTC_EV_OPEN, .uint, null),
    con("WEBRTC_EV_CANDIDATE", cw.PANCAKE_WEBRTC_EV_CANDIDATE, .uint, null),
    con("WEBRTC_EV_READABLE", cw.PANCAKE_WEBRTC_EV_READABLE, .uint, null),
    con("WEBRTC_EV_WRITABLE", cw.PANCAKE_WEBRTC_EV_WRITABLE, .uint, null),
    con("WEBRTC_EV_CLOSED", cw.PANCAKE_WEBRTC_EV_CLOSED, .uint, null),
    con("WEBRTC_MAX_SIGNAL_BYTES", cw.PANCAKE_WEBRTC_MAX_SIGNAL_BYTES, .usize, null),
    con("WEBRTC_MAX_ICE_CANDIDATE_BYTES", cw.PANCAKE_WEBRTC_MAX_ICE_CANDIDATE_BYTES, .usize, null),
    con("WEBRTC_MAX_ICE_SERVERS", cw.PANCAKE_WEBRTC_MAX_ICE_SERVERS, .usize, null),
    con("WEBRTC_MAX_ICE_URLS_PER_SERVER", cw.PANCAKE_WEBRTC_MAX_ICE_URLS_PER_SERVER, .usize, null),
    con("WEBRTC_MAX_ICE_URL_BYTES", cw.PANCAKE_WEBRTC_MAX_ICE_URL_BYTES, .usize, null),
    con("WEBRTC_MAX_ICE_CREDENTIAL_BYTES", cw.PANCAKE_WEBRTC_MAX_ICE_CREDENTIAL_BYTES, .usize, null),
    con("WEBRTC_MAX_PENDING_ICE_CANDIDATES", cw.PANCAKE_WEBRTC_MAX_PENDING_ICE_CANDIDATES, .usize, null),
    con("WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES", cw.PANCAKE_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES, .usize, null),
    con("WEBRTC_DATA_CHANNEL_QUEUE_BYTES", cw.PANCAKE_WEBRTC_DATA_CHANNEL_QUEUE_BYTES, .usize, null),
    // Binding-only policy shared by async bindings.
    con("BINDING_UNOBSERVED_OUTCOME_CAP", binding_policy.unobserved_outcome_cap, .usize, null),
    con("BINDING_READINESS_DRAIN_CAP", binding_policy.readiness_drain_cap, .usize, null),
    con("BINDING_STREAM_READ_CHUNK_BYTES", binding_policy.stream_read_chunk_bytes, .usize, null),
    con("BINDING_IROH_READ_CHUNK_BYTES", ci.PANCAKE_IROH_READ_CHUNK_BYTES, .usize, null),
    con("BINDING_TRACE_PAYLOAD_CAP_BYTES", binding_policy.trace_payload_cap_bytes, .usize, null),
    con("BINDING_SECONDARY_FAILURE_CAP", binding_policy.secondary_failure_cap, .usize, null),
    con("BINDING_RELAY_IDLE_TIMEOUT_MS", binding_policy.relay_idle_timeout_ms, .usize, null),
    con("BINDING_RELAY_MAX_BYTES_PER_SESSION", binding_policy.relay_max_bytes_per_session, .usize, null),
    con("BINDING_RELAY_READ_CHUNK_BYTES", binding_policy.relay_read_chunk_bytes, .usize, null),
    con("BINDING_RELAY_TCP_DIAL_TIMEOUT_MS", binding_policy.relay_tcp_dial_timeout_ms, .usize, null),
    con("BINDING_RELAY_WEBSOCKET_BUFFER_BYTES", binding_policy.relay_websocket_buffer_bytes, .usize, null),
    con("BINDING_WEBSOCKET_MESSAGE_CAP_BYTES", binding_policy.websocket_message_cap_bytes, .usize, null),
    con("BINDING_WEBSOCKET_SEND_HIGH_WATER_BYTES", binding_policy.websocket_send_high_water_bytes, .usize, null),
    con("BINDING_WEBSOCKET_DRAIN_POLL_MS", binding_policy.websocket_drain_poll_ms, .usize, null),
    con("BINDING_WEBSOCKET_CLOSE_TIMEOUT_MS", binding_policy.websocket_close_timeout_ms, .usize, null),
    con("BINDING_WEBSOCKET_INBOUND_HIGH_WATER_BYTES", binding_policy.websocket_inbound_high_water_bytes, .usize, null),
};

fn writeKebab(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) !void {
    for (name) |ch| try out.append(gpa, if (ch == '_') '-' else ch);
}

fn isReturnCode(k: Const) bool {
    return std.mem.eql(u8, k.stem, "OK") or
        std.mem.eql(u8, k.stem, "WOULD_BLOCK") or
        std.mem.startsWith(u8, k.stem, "ERR_");
}

fn writeTransportName(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    known: model.transport.Known,
    separator: u8,
) !void {
    try out.appendSlice(gpa, if (separator == '_') "TRANSPORT_" else "TRANSPORT-");
    for (@tagName(known)) |ch| {
        try out.append(gpa, if (ch == '_') separator else std.ascii.toUpper(ch));
    }
}

fn generateRust(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\//! GENERATED by `zig build gen-binding-constants` from src/c_abi
        \\//! and binding policy. Do not edit.
        \\//! `zig build gen-binding-constants-check` keeps this fresh.
        \\
        \\#![allow(dead_code)]
        \\
        \\use core::ffi::{c_int, c_uint};
        \\
        \\
    );
    for (constants) |k| {
        try out.print(gpa, "pub const {s}: {s} = {d};\n", .{ k.stem, k.rust_ty.spelling(), k.value });
    }
    try out.print(gpa, "pub const HINT_DIRECT_ADDRESSES: &str = \"{s}\";\n", .{model.transport.hint_direct_addresses});
    inline for (std.enums.values(model.transport.Known)) |known| {
        try out.appendSlice(gpa, "pub const ");
        try writeTransportName(&out, gpa, known, '_');
        try out.print(gpa, ": &str = \"{s}\";\n", .{known.metadata().symbol});
    }
    return out.toOwnedSlice(gpa);
}

fn generateRustRelay(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\//! GENERATED by `zig build gen-binding-constants` from binding policy.
        \\//! Do not edit. `zig build gen-binding-constants-check` keeps this fresh.
        \\
        \\
    );
    try out.print(gpa, "pub const RELAY_IDLE_TIMEOUT_MS: u64 = {d};\n", .{binding_policy.relay_idle_timeout_ms});
    try out.print(gpa, "pub const RELAY_MAX_BYTES_PER_SESSION: usize = {d};\n", .{binding_policy.relay_max_bytes_per_session});
    try out.print(gpa, "pub const RELAY_READ_CHUNK_BYTES: usize = {d};\n", .{binding_policy.relay_read_chunk_bytes});
    try out.print(gpa, "pub const RELAY_WEBSOCKET_BUFFER_BYTES: usize = {d};\n", .{binding_policy.relay_websocket_buffer_bytes});
    try out.print(gpa, "pub const WEBSOCKET_MESSAGE_CAP_BYTES: usize = {d};\n", .{binding_policy.websocket_message_cap_bytes});
    return out.toOwnedSlice(gpa);
}

fn generatePython(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\# GENERATED by `zig build gen-binding-constants` from src/c_abi
        \\# and binding policy. Do not edit.
        \\# `zig build gen-binding-constants-check` keeps this fresh.
        \\
        \\
    );
    for (constants) |k| {
        try out.print(gpa, "{s} = {d}\n", .{ k.stem, k.value });
    }
    try out.print(gpa, "HINT_DIRECT_ADDRESSES = \"{s}\"\n", .{model.transport.hint_direct_addresses});
    inline for (std.enums.values(model.transport.Known)) |known| {
        try writeTransportName(&out, gpa, known, '_');
        try out.print(gpa, " = \"{s}\"\n", .{known.metadata().symbol});
    }
    return out.toOwnedSlice(gpa);
}

fn generateRacket(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\#lang racket/base
        \\;; GENERATED by `zig build gen-binding-constants` from src/c_abi
        \\;; and binding policy. Do not edit.
        \\;; `zig build gen-binding-constants-check` keeps this fresh.
        \\
        \\(provide
        \\
    );
    for (constants) |k| {
        try out.appendSlice(gpa, "  ");
        if (k.rkt) |name| {
            try out.appendSlice(gpa, name);
        } else {
            try writeKebab(&out, gpa, k.stem);
        }
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, "  ABI-RETURN-CODES\n  HINT-DIRECT-ADDRESSES\n");
    inline for (std.enums.values(model.transport.Known)) |known| {
        try out.appendSlice(gpa, "  ");
        try writeTransportName(&out, gpa, known, '-');
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, ")\n\n");
    for (constants) |k| {
        try out.appendSlice(gpa, "(define ");
        if (k.rkt) |name| try out.appendSlice(gpa, name) else try writeKebab(&out, gpa, k.stem);
        try out.print(gpa, " {d})\n", .{k.value});
    }
    try out.appendSlice(gpa, "(define ABI-RETURN-CODES\n  (list\n");
    for (constants) |k| {
        if (!isReturnCode(k)) continue;
        try out.appendSlice(gpa, "   (cons '");
        if (k.rkt) |name| try out.appendSlice(gpa, name) else try writeKebab(&out, gpa, k.stem);
        try out.appendSlice(gpa, " ");
        if (k.rkt) |name| try out.appendSlice(gpa, name) else try writeKebab(&out, gpa, k.stem);
        try out.appendSlice(gpa, ")\n");
    }
    try out.appendSlice(gpa, "  ))\n");
    try out.print(gpa, "(define HINT-DIRECT-ADDRESSES \"{s}\")\n", .{model.transport.hint_direct_addresses});
    inline for (std.enums.values(model.transport.Known)) |known| {
        try out.appendSlice(gpa, "(define ");
        try writeTransportName(&out, gpa, known, '-');
        try out.print(gpa, " \"{s}\")\n", .{known.metadata().symbol});
    }
    return out.toOwnedSlice(gpa);
}
