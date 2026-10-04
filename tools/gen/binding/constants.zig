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
    .{ .path = "bindings/python/glowcap/_constants_gen.py", .generate = generatePython },
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
    con("OK", c.GLOWCAP_OK, .int, null),
    con("WOULD_BLOCK", c.GLOWCAP_ERR_WOULD_BLOCK, .int, null),
    con("ERR_NULL_POINTER", c.GLOWCAP_ERR_NULL_POINTER, .int, null),
    con("ERR_INVALID_ARGUMENT", c.GLOWCAP_ERR_INVALID_ARGUMENT, .int, null),
    con("ERR_SESSION", c.GLOWCAP_ERR_SESSION, .int, null),
    con("ERR_CODEC", c.GLOWCAP_ERR_CODEC, .int, null),
    con("ERR_INTERNAL", c.GLOWCAP_ERR_INTERNAL, .int, null),
    con("ERR_CLOSED", c.GLOWCAP_ERR_CLOSED, .int, null),
    con("ERR_IO", c.GLOWCAP_ERR_IO, .int, null),
    con("ERR_MALFORMED", c.GLOWCAP_ERR_MALFORMED, .int, null),
    con("ERR_FRAME_TOO_LARGE", c.GLOWCAP_ERR_FRAME_TOO_LARGE, .int, null),
    con("ERR_UNSUPPORTED_VALUE", c.GLOWCAP_ERR_UNSUPPORTED_VALUE, .int, null),
    con("ERR_BROKEN", c.GLOWCAP_ERR_BROKEN, .int, null),
    con("ERR_NOT_FOUND", c.GLOWCAP_ERR_NOT_FOUND, .int, null),
    con("ERR_BUFFER_TOO_SMALL", c.GLOWCAP_ERR_BUFFER_TOO_SMALL, .int, null),
    con("ERR_TIMEOUT", c.GLOWCAP_ERR_TIMEOUT, .int, null),
    // Structured diagnostic vocabulary (c_uint).
    con("FAILURE_LAYER_CORE", c.GLOWCAP_FAILURE_LAYER_CORE, .uint, null),
    con("FAILURE_LAYER_DRIVER", c.GLOWCAP_FAILURE_LAYER_DRIVER, .uint, null),
    con("FAILURE_LAYER_TRANSPORT", c.GLOWCAP_FAILURE_LAYER_TRANSPORT, .uint, null),
    con("FAILURE_LAYER_BINDING", c.GLOWCAP_FAILURE_LAYER_BINDING, .uint, null),
    con("FAILURE_LAYER_APPLICATION_OBSERVER", c.GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER, .uint, null),
    con("FAILURE_SCOPE_PROCESS", c.GLOWCAP_FAILURE_SCOPE_PROCESS, .uint, null),
    con("FAILURE_SCOPE_CONTEXT", c.GLOWCAP_FAILURE_SCOPE_CONTEXT, .uint, null),
    con("FAILURE_SCOPE_HOST", c.GLOWCAP_FAILURE_SCOPE_HOST, .uint, null),
    con("FAILURE_SCOPE_SESSION", c.GLOWCAP_FAILURE_SCOPE_SESSION, .uint, null),
    con("FAILURE_SCOPE_LISTENER", c.GLOWCAP_FAILURE_SCOPE_LISTENER, .uint, null),
    con("FAILURE_SCOPE_TRANSPORT", c.GLOWCAP_FAILURE_SCOPE_TRANSPORT, .uint, null),
    con("FAILURE_SCOPE_OPERATION", c.GLOWCAP_FAILURE_SCOPE_OPERATION, .uint, null),
    // Frame shape (c_uint).
    con("FRAME_SHAPE_BYTE", c.GLOWCAP_FRAME_SHAPE_BYTE, .uint, null),
    // Argument kinds (c_uint).
    con("ARG_INTEGER", c.GLOWCAP_ARG_INTEGER, .uint, null),
    con("ARG_FLOAT64", c.GLOWCAP_ARG_FLOAT64, .uint, null),
    con("ARG_BOOLEAN", c.GLOWCAP_ARG_BOOLEAN, .uint, null),
    con("ARG_BYTES", c.GLOWCAP_ARG_BYTES, .uint, null),
    con("ARG_STRING", c.GLOWCAP_ARG_STRING, .uint, null),
    con("ARG_SYMBOL", c.GLOWCAP_ARG_SYMBOL, .uint, null),
    con("ARG_VOID", c.GLOWCAP_ARG_VOID, .uint, null),
    con("ARG_REFERENCE", c.GLOWCAP_ARG_REFERENCE, .uint, null),
    con("ARG_LIST", c.GLOWCAP_ARG_LIST, .uint, null),
    con("ARG_SET", c.GLOWCAP_ARG_SET, .uint, null),
    con("ARG_TAGGED", c.GLOWCAP_ARG_TAGGED, .uint, null),
    con("ARG_KEYWORD", c.GLOWCAP_ARG_KEYWORD, .uint, null),
    con("ARG_BIG_INTEGER", c.GLOWCAP_ARG_BIG_INTEGER, .uint, null),
    con("ARG_STRUCT", c.GLOWCAP_ARG_STRUCT, .uint, null),
    con("ARG_ERROR", c.GLOWCAP_ARG_ERROR, .uint, null),
    // Wire-grammar codec selectors (c_uint).
    con("CODEC_UNKNOWN", c.GLOWCAP_CODEC_UNKNOWN, .uint, null),
    con("CODEC_SYRUP", c.GLOWCAP_CODEC_SYRUP, .uint, null),
    con("CODEC_CAPNP", c.GLOWCAP_CODEC_CAPNP, .uint, null),
    con("CAPTP_V1_0", c.GLOWCAP_CAPTP_V1_0, .uint, null),
    con("CAPTP_NEXT", c.GLOWCAP_CAPTP_NEXT, .uint, null),
    con("FEATURE_PIPELINING", c.GLOWCAP_FEATURE_PIPELINING, .uint, null),
    con("FEATURE_HANDOFF", c.GLOWCAP_FEATURE_HANDOFF, .uint, null),
    con("FEATURE_WIRE_DELTA", c.GLOWCAP_FEATURE_WIRE_DELTA, .uint, null),
    con("FEATURE_STURDYREF", c.GLOWCAP_FEATURE_STURDYREF, .uint, null),
    con("FEATURE_UNTAG", c.GLOWCAP_FEATURE_UNTAG, .uint, null),
    con("FEATURE_MULTI_LOCATION", c.GLOWCAP_FEATURE_MULTI_LOCATION, .uint, null),
    con("FEATURE_MINIMUM", c.GLOWCAP_FEATURE_MINIMUM, .uint, null),
    con("FEATURE_BASELINE", c.GLOWCAP_FEATURE_BASELINE, .uint, null),
    con("FEATURE_FULL", c.GLOWCAP_FEATURE_FULL, .uint, null),
    con("DEFAULT_CODEC", c.GLOWCAP_DEFAULT_CODEC, .uint, null),
    con("DEFAULT_CAPTP_VERSION", c.GLOWCAP_DEFAULT_CAPTP_VERSION, .uint, null),
    con("DEFAULT_FEATURES", c.GLOWCAP_DEFAULT_FEATURES, .uint, null),
    con("INTEROP_CODEC", c.GLOWCAP_INTEROP_CODEC, .uint, null),
    con("INTEROP_CAPTP_VERSION", c.GLOWCAP_INTEROP_CAPTP_VERSION, .uint, null),
    con("NATIVE_CODEC", c.GLOWCAP_NATIVE_CODEC, .uint, null),
    con("NATIVE_CAPTP_VERSION", c.GLOWCAP_NATIVE_CAPTP_VERSION, .uint, null),
    // GlowcapLastAbort.domain (c_uint).
    con("ABORT_DOMAIN_CODEC", c.GLOWCAP_ABORT_DOMAIN_CODEC, .uint, null),
    con("ABORT_DOMAIN_SESSION", c.GLOWCAP_ABORT_DOMAIN_SESSION, .uint, null),
    con("ABORT_DOMAIN_FOREIGN", c.GLOWCAP_ABORT_DOMAIN_FOREIGN, .uint, null),
    // Callerless-failure journal defaults (libglowcap_ocapn). Bindings use
    // the same bounded schema for their runtime-local fallback journals.
    con("DEFAULT_FAILURE_CAPACITY", c.GLOWCAP_DEFAULT_FAILURE_CAPACITY, .usize, null),
    con("DEFAULT_FAILURE_PAYLOAD_CAP", c.GLOWCAP_DEFAULT_FAILURE_PAYLOAD_CAP, .usize, null),
    // Host trace event kinds (c_uint, libglowcap_host).
    con("TRACE_SESSION_OPEN", cd.GLOWCAP_TRACE_SESSION_OPEN, .uint, null),
    con("TRACE_MESSAGE", cd.GLOWCAP_TRACE_MESSAGE, .uint, null),
    con("TRACE_SESSION_CLOSE", cd.GLOWCAP_TRACE_SESSION_CLOSE, .uint, null),
    con("TRACE_DIGEST_BYTES", cd.GLOWCAP_TRACE_DIGEST_BYTES, .uint, null),
    con("PENDING_CANCEL", cd.GLOWCAP_PENDING_CANCEL, .uint, null),
    con("PENDING_FINISH", cd.GLOWCAP_PENDING_FINISH, .uint, null),
    con("LIFECYCLE_ACTIVE", cd.GLOWCAP_LIFECYCLE_ACTIVE, .uint, null),
    con("LIFECYCLE_FINISHING", cd.GLOWCAP_LIFECYCLE_FINISHING, .uint, null),
    con("LIFECYCLE_TERMINATING", cd.GLOWCAP_LIFECYCLE_TERMINATING, .uint, null),
    con("LIFECYCLE_CLOSED", cd.GLOWCAP_LIFECYCLE_CLOSED, .uint, null),
    con("DESIGNATOR_SCHEME_ADDRESS", cd.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS, .uint, null),
    con("DESIGNATOR_SCHEME_KEY", cd.GLOWCAP_DESIGNATOR_SCHEME_KEY, .uint, null),
    // GlowcapPartnerIdentity.provenance: how the partner's advertised durable
    // identity was authenticated (ADR-0097).
    con("DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT", cd.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT, .uint, null),
    con("DURABLE_PROVENANCE_UNAUTHENTICATED", cd.GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED, .uint, null),
    // Frame-cap defaults: Host protocol admission comes from libglowcap_host;
    // the direct raw transport helper default comes from shared C vocabulary.
    con("DEFAULT_FRAME_CAP", cd.GLOWCAP_DEFAULT_FRAME_CAP, .usize, null),
    con("RAW_TRANSPORT_DEFAULT_FRAME_CAP", c.GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP, .usize, null),
    // Local Forward hop bound (usize, libglowcap_host).
    con("MAX_LOCAL_FORWARD_HOPS", cd.GLOWCAP_MAX_LOCAL_FORWARD_HOPS, .usize, null),
    con("HANDSHAKE_TIMEOUT_MS", cd.GLOWCAP_HANDSHAKE_TIMEOUT_MS, .usize, null),
    con("LOCAL_TURN_BUDGET_DEFAULT", cd.GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT, .uint, null),
    con("LOCAL_TURN_BUDGET_UNBOUNDED", cd.GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED, .uint, null),
    con("HOST_OUTBOUND_PREFIX_CAP", cd.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP, .usize, null),
    con("HOST_DURABLE_ENTROPY_LEN", cd.GLOWCAP_HOST_DURABLE_ENTROPY_LEN, .usize, null),
    con("HOST_DURABLE_SWISS_LEN", cd.GLOWCAP_HOST_DURABLE_SWISS_LEN, .usize, null),
    con("DEFAULT_PENDING_ACCEPTS", cd.GLOWCAP_DEFAULT_PENDING_ACCEPTS, .usize, null),
    con("DEFAULT_HANDSHAKE_CONCURRENCY", cd.GLOWCAP_DEFAULT_HANDSHAKE_CONCURRENCY, .usize, null),
    con("MAX_HANDSHAKE_CONCURRENCY", cd.GLOWCAP_MAX_HANDSHAKE_CONCURRENCY, .usize, null),
    con("DISCOVERY_DIAL_RETRY_MS", cd.GLOWCAP_DISCOVERY_DIAL_RETRY_MS, .usize, null),
    con("DISCOVERY_DIAL_MAX_ATTEMPTS", cd.GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS, .usize, null),
    // Iroh reachability postures and the redeem knob's starting value (c_uint,
    // libglowcap_net_transport_iroh, reflected through the sidecar stub so this
    // stays cargo-free). Each binding's `Reachability` surface and its
    // hint-less-redeem default read these instead of hand-typing the numbers.
    // GlowcapDriverEvent.kind values the driver archive's event queue carries.
    con("CLOSE_OPTIONS_ABI_VERSION", cd.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION, .uint, null),
    con("CLOSE_MAX_GRACE_MS", cd.GLOWCAP_CLOSE_MAX_GRACE_MS, .uint, null),
    con("CLOSE_GRACE_UNSPECIFIED", cd.GLOWCAP_CLOSE_GRACE_UNSPECIFIED, .uint, null),
    con("CLOSE_GRACE_FINITE", cd.GLOWCAP_CLOSE_GRACE_FINITE, .uint, null),
    con("CLOSE_GRACE_UNBOUNDED", cd.GLOWCAP_CLOSE_GRACE_UNBOUNDED, .uint, null),
    con("SESSION_LIMIT_OPTIONS_ABI_VERSION", cd.GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION, .uint, null),
    con("DRIVER_OPTIONS_ABI_VERSION", cdr.GLOWCAP_DRIVER_OPTIONS_ABI_VERSION, .uint, null),
    con("DRIVER_FAILURE_ABI_VERSION", cdr.GLOWCAP_DRIVER_FAILURE_ABI_VERSION, .uint, null),
    con("CARRIER_PHASE_NONE", cdr.GLOWCAP_CARRIER_PHASE_NONE, .uint, null),
    con("CARRIER_PHASE_RESOLVE", cdr.GLOWCAP_CARRIER_PHASE_RESOLVE, .uint, null),
    con("CARRIER_PHASE_CONNECT", cdr.GLOWCAP_CARRIER_PHASE_CONNECT, .uint, null),
    con("CARRIER_PHASE_SECURE_HANDSHAKE", cdr.GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE, .uint, null),
    con("CARRIER_PHASE_WEBSOCKET_UPGRADE", cdr.GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE, .uint, null),
    con("CARRIER_PHASE_REGISTRATION", cdr.GLOWCAP_CARRIER_PHASE_REGISTRATION, .uint, null),
    con("CARRIER_PHASE_RECEIVE", cdr.GLOWCAP_CARRIER_PHASE_RECEIVE, .uint, null),
    con("CARRIER_PHASE_TRANSMIT", cdr.GLOWCAP_CARRIER_PHASE_TRANSMIT, .uint, null),
    con("CARRIER_PHASE_SHUTDOWN", cdr.GLOWCAP_CARRIER_PHASE_SHUTDOWN, .uint, null),
    con("CARRIER_DETAIL_PEER_ALERT", cdr.GLOWCAP_CARRIER_DETAIL_PEER_ALERT, .uint, null),
    con("CARRIER_DETAIL_ENGINE_CODE", cdr.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE, .uint, null),
    con("DRIVER_MAX_WAIT_MS", cdr.GLOWCAP_DRIVER_MAX_WAIT_MS, .uint, null),
    con("DRIVER_DEFAULT_WIRE_BUFFER_BYTES", cdr.GLOWCAP_DRIVER_DEFAULT_WIRE_BUFFER_BYTES, .usize, null),
    con("DRIVER_DEFAULT_MAX_PENDING_OPENS", cdr.GLOWCAP_DRIVER_DEFAULT_MAX_PENDING_OPENS, .usize, null),
    con("DRIVER_DEFAULT_HANDSHAKE_MS", cdr.GLOWCAP_DRIVER_DEFAULT_HANDSHAKE_MS, .uint, null),
    con("DRIVER_DEFAULT_LISTENER_SETUP_MS", cdr.GLOWCAP_DRIVER_DEFAULT_LISTENER_SETUP_MS, .uint, null),
    con("DRIVER_DEFAULT_SETTLE_MS", cdr.GLOWCAP_DRIVER_DEFAULT_SETTLE_MS, .uint, null),
    con("DRIVER_EVENT_OPENED", cdr.GLOWCAP_DRIVER_EVENT_OPENED, .uint, null),
    con("DRIVER_EVENT_OPEN_FAILED", cdr.GLOWCAP_DRIVER_EVENT_OPEN_FAILED, .uint, null),
    con("DRIVER_EVENT_ACCEPTED", cdr.GLOWCAP_DRIVER_EVENT_ACCEPTED, .uint, null),
    con("DRIVER_EVENT_SESSION_CLOSED", cdr.GLOWCAP_DRIVER_EVENT_SESSION_CLOSED, .uint, null),
    con("DRIVER_EVENT_COMPLETION", cdr.GLOWCAP_DRIVER_EVENT_COMPLETION, .uint, null),
    con("DRIVER_EVENT_LISTENER_READY", cdr.GLOWCAP_DRIVER_EVENT_LISTENER_READY, .uint, null),
    con("DRIVER_EVENT_LISTENER_FAILED", cdr.GLOWCAP_DRIVER_EVENT_LISTENER_FAILED, .uint, null),
    con("LOCATOR_VIEW_ABI_VERSION", cdr.GLOWCAP_LOCATOR_VIEW_ABI_VERSION, .uint, null),
    con("HINT_STRING", cdr.GLOWCAP_HINT_STRING, .uint, null),
    con("HINT_BYTES", cdr.GLOWCAP_HINT_BYTES, .uint, null),
    con("HINT_BOOLEAN", cdr.GLOWCAP_HINT_BOOLEAN, .uint, null),
    con("HINT_INTEGER", cdr.GLOWCAP_HINT_INTEGER, .uint, null),
    con("HINTS_MAP", cdr.GLOWCAP_HINTS_MAP, .uint, null),
    con("HINTS_BOOLEAN_FALSE", cdr.GLOWCAP_HINTS_BOOLEAN_FALSE, .uint, null),
    con("OCAPN_ARCHIVE_FINGERPRINT", c.GLOWCAP_OCAPN_ARCHIVE_FINGERPRINT, .u64, null),
    con("HOST_ARCHIVE_FINGERPRINT", cd.GLOWCAP_HOST_ARCHIVE_FINGERPRINT, .u64, null),
    con("DRIVER_ARCHIVE_FINGERPRINT", cdr.GLOWCAP_DRIVER_ARCHIVE_FINGERPRINT, .u64, null),
    con("TCP_ARCHIVE_FINGERPRINT", ct.GLOWCAP_TCP_ARCHIVE_FINGERPRINT, .u64, null),
    con("INPROC_ARCHIVE_FINGERPRINT", cn.GLOWCAP_INPROC_ARCHIVE_FINGERPRINT, .u64, null),
    con("ONION_ARCHIVE_FINGERPRINT", co.GLOWCAP_ONION_ARCHIVE_FINGERPRINT, .u64, null),
    con("ONION_AUTH_NONE", co.GLOWCAP_ONION_AUTH_NONE, .uint, null),
    con("ONION_AUTH_COOKIE", co.GLOWCAP_ONION_AUTH_COOKIE, .uint, null),
    con("ONION_AUTH_PASSWORD", co.GLOWCAP_ONION_AUTH_PASSWORD, .uint, null),
    con("ONION_SERVICE_ID_LEN", co.GLOWCAP_ONION_SERVICE_ID_LEN, .usize, null),
    con("ONION_SERVICE_KEY_CAP", co.GLOWCAP_ONION_SERVICE_KEY_CAP, .usize, null),
    con("IROH_ARCHIVE_FINGERPRINT", ci.GLOWCAP_IROH_ARCHIVE_FINGERPRINT, .u64, null),
    con("RELAY_ARCHIVE_FINGERPRINT", cr.GLOWCAP_RELAY_ARCHIVE_FINGERPRINT, .u64, null),
    con("RELAY_CONFIG_ABI_VERSION", cr.GLOWCAP_RELAY_CONFIG_ABI_VERSION, .uint, null),
    con("RELAY_TRUST_SYSTEM", cr.GLOWCAP_RELAY_TRUST_SYSTEM, .uint, null),
    con("RELAY_TRUST_COPIED_PEM", cr.GLOWCAP_RELAY_TRUST_COPIED_PEM, .uint, null),
    con("RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES", cr.GLOWCAP_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES, .usize, null),
    con("WEBRTC_ARCHIVE_FINGERPRINT", cw.GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT, .u64, null),
    con("IROH_REACH_DIRECT", ci.GLOWCAP_IROH_REACH_DIRECT, .uint, null),
    con("IROH_REACH_DISCOVERY", ci.GLOWCAP_IROH_REACH_DISCOVERY, .uint, null),
    con("IROH_REACH_DISCOVERY_NO_RELAY", ci.GLOWCAP_IROH_REACH_DISCOVERY_NO_RELAY, .uint, null),
    con("IROH_REACH_LOCAL_DISCOVERY", ci.GLOWCAP_IROH_REACH_LOCAL_DISCOVERY, .uint, null),
    con("IROH_REACH_REDEEM_DEFAULT", ci.GLOWCAP_IROH_REACH_REDEEM_DEFAULT, .uint, null),
    con("IROH_NODE_ID_BYTES", ci.GLOWCAP_IROH_NODE_ID_BYTES, .usize, null),
    con("IROH_MAX_DIRECT_ADDRESS_BYTES", ci.GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES, .usize, null),
    // Iroh readiness event bits (c_uint, libglowcap_net_transport_iroh): the
    // GLOWCAP_IROH_EV_* bitset a drain_ready record carries.
    con("IROH_EV_READABLE", ci.GLOWCAP_IROH_EV_READABLE, .uint, null),
    con("IROH_EV_WRITABLE", ci.GLOWCAP_IROH_EV_WRITABLE, .uint, null),
    con("IROH_EV_CLOSED", ci.GLOWCAP_IROH_EV_CLOSED, .uint, null),
    con("IROH_EV_ACCEPT", ci.GLOWCAP_IROH_EV_ACCEPT, .uint, null),
    con("IROH_EV_CONNECT", ci.GLOWCAP_IROH_EV_CONNECT, .uint, null),
    con("WEBRTC_EV_OPEN", cw.GLOWCAP_WEBRTC_EV_OPEN, .uint, null),
    con("WEBRTC_EV_CANDIDATE", cw.GLOWCAP_WEBRTC_EV_CANDIDATE, .uint, null),
    con("WEBRTC_EV_READABLE", cw.GLOWCAP_WEBRTC_EV_READABLE, .uint, null),
    con("WEBRTC_EV_WRITABLE", cw.GLOWCAP_WEBRTC_EV_WRITABLE, .uint, null),
    con("WEBRTC_EV_CLOSED", cw.GLOWCAP_WEBRTC_EV_CLOSED, .uint, null),
    con("WEBRTC_MAX_SIGNAL_BYTES", cw.GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES, .usize, null),
    con("WEBRTC_MAX_ICE_CANDIDATE_BYTES", cw.GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES, .usize, null),
    con("WEBRTC_MAX_ICE_SERVERS", cw.GLOWCAP_WEBRTC_MAX_ICE_SERVERS, .usize, null),
    con("WEBRTC_MAX_ICE_URLS_PER_SERVER", cw.GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER, .usize, null),
    con("WEBRTC_MAX_ICE_URL_BYTES", cw.GLOWCAP_WEBRTC_MAX_ICE_URL_BYTES, .usize, null),
    con("WEBRTC_MAX_ICE_CREDENTIAL_BYTES", cw.GLOWCAP_WEBRTC_MAX_ICE_CREDENTIAL_BYTES, .usize, null),
    con("WEBRTC_MAX_PENDING_ICE_CANDIDATES", cw.GLOWCAP_WEBRTC_MAX_PENDING_ICE_CANDIDATES, .usize, null),
    con("WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES", cw.GLOWCAP_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES, .usize, null),
    con("WEBRTC_DATA_CHANNEL_QUEUE_BYTES", cw.GLOWCAP_WEBRTC_DATA_CHANNEL_QUEUE_BYTES, .usize, null),
    // Binding-only policy shared by async bindings.
    con("BINDING_UNOBSERVED_OUTCOME_CAP", binding_policy.unobserved_outcome_cap, .usize, null),
    con("BINDING_READINESS_DRAIN_CAP", binding_policy.readiness_drain_cap, .usize, null),
    con("BINDING_STREAM_READ_CHUNK_BYTES", binding_policy.stream_read_chunk_bytes, .usize, null),
    con("BINDING_IROH_READ_CHUNK_BYTES", ci.GLOWCAP_IROH_READ_CHUNK_BYTES, .usize, null),
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
    con("BINDING_BROWSER_CHANNEL_CLOSE_TIMEOUT_MS", binding_policy.browser_channel_close_timeout_ms, .usize, null),
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
    try out.print(gpa, "pub const HINT_ALT_LOCATORS: &str = \"{s}\";\n", .{model.transport.hint_alt_locators});
    try out.print(gpa, "pub const HINT_VIA: &str = \"{s}\";\n", .{model.transport.hint_via});
    inline for (std.enums.values(model.transport.Known)) |known| {
        try out.appendSlice(gpa, "pub const ");
        try writeTransportName(&out, gpa, known, '_');
        try out.print(gpa, ": &str = \"{s}\";\n", .{known.metadata().symbol});
        if (known.metadata().max_packet_bytes != 0) {
            try out.appendSlice(gpa, "pub const ");
            try writeTransportName(&out, gpa, known, '_');
            try out.print(gpa, "_MAX_PACKET_BYTES: usize = {d};\n", .{known.metadata().max_packet_bytes});
        }
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
    try out.print(gpa, "HINT_ALT_LOCATORS = \"{s}\"\n", .{model.transport.hint_alt_locators});
    try out.print(gpa, "HINT_VIA = \"{s}\"\n", .{model.transport.hint_via});
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
    try out.appendSlice(gpa, "  ABI-RETURN-CODES\n  HINT-ALT-LOCATORS\n  HINT-DIRECT-ADDRESSES\n  HINT-VIA\n");
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
    try out.print(gpa, "(define HINT-ALT-LOCATORS \"{s}\")\n", .{model.transport.hint_alt_locators});
    try out.print(gpa, "(define HINT-VIA \"{s}\")\n", .{model.transport.hint_via});
    inline for (std.enums.values(model.transport.Known)) |known| {
        try out.appendSlice(gpa, "(define ");
        try writeTransportName(&out, gpa, known, '-');
        try out.print(gpa, " \"{s}\")\n", .{known.metadata().symbol});
    }
    return out.toOwnedSlice(gpa);
}
