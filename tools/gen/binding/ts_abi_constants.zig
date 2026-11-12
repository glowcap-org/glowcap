//! The constant table the TypeScript ABI mirror prints into `@glowcap/abi`.
//!
//! Each group carries the sentence every member shares, and each member the
//! C declaration it mirrors or, for a binding policy value, the sentence
//! `policy.zig` owns. `ts_abi.zig` prints the table.

const c = @import("c_abi");
const cd = @import("c_abi_host");
const cdr = @import("c_abi_driver");
const ci = @import("c_abi_net_transport_iroh");
const ct = @import("c_abi_net_transport_tcp");
const cin = @import("c_abi_net_transport_inproc");
const con = @import("c_abi_net_transport_onion");
const cw = @import("c_abi_net_transport_webrtc");
const cr = @import("c_abi_net_transport_relay");
const binding_policy = @import("binding_policy");

/// One generated constant: the TypeScript name, the value, and the sentence
/// that follows its group's doc. Referencing the `c_abi` declaration makes a
/// C-side rename a compile error here rather than a stale mirror.
const Const = struct {
    ts: []const u8,
    value: i64,
    /// The sentence after the group's: the C declaration the value mirrors,
    /// or for a binding policy value, what it bounds.
    tail: []const u8,
};

/// A run of constants that share one doc sentence, so the package reader
/// sees what the family means on every member.
const Group = struct {
    doc: []const u8,
    entries: []const Const,
};

const BigConst = struct {
    ts: []const u8,
    value: u64,
    archive: []const u8,
};

pub const archive_fingerprints = [_]BigConst{
    .{ .ts = "OCAPN_ARCHIVE_FINGERPRINT", .value = c.GLOWCAP_OCAPN_ARCHIVE_FINGERPRINT, .archive = "libglowcap_ocapn" },
    .{ .ts = "HOST_ARCHIVE_FINGERPRINT", .value = cd.GLOWCAP_HOST_ARCHIVE_FINGERPRINT, .archive = "libglowcap_host" },
    .{ .ts = "DRIVER_ARCHIVE_FINGERPRINT", .value = cdr.GLOWCAP_DRIVER_ARCHIVE_FINGERPRINT, .archive = "libglowcap_driver" },
    .{ .ts = "TCP_ARCHIVE_FINGERPRINT", .value = ct.GLOWCAP_TCP_ARCHIVE_FINGERPRINT, .archive = "libglowcap_net_transport_tcp" },
    .{ .ts = "INPROC_ARCHIVE_FINGERPRINT", .value = cin.GLOWCAP_INPROC_ARCHIVE_FINGERPRINT, .archive = "libglowcap_net_transport_inproc" },
    .{ .ts = "ONION_ARCHIVE_FINGERPRINT", .value = con.GLOWCAP_ONION_ARCHIVE_FINGERPRINT, .archive = "libglowcap_net_transport_onion" },
    .{ .ts = "IROH_ARCHIVE_FINGERPRINT", .value = ci.GLOWCAP_IROH_ARCHIVE_FINGERPRINT, .archive = "libglowcap_net_transport_iroh" },
    .{ .ts = "RELAY_ARCHIVE_FINGERPRINT", .value = cr.GLOWCAP_RELAY_ARCHIVE_FINGERPRINT, .archive = "libglowcap_net_transport_relay" },
    .{ .ts = "WEBRTC_ARCHIVE_FINGERPRINT", .value = cw.GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT, .archive = "libglowcap_net_transport_webrtc" },
};

fn mirrored(comptime ts: []const u8, comptime decl: []const u8, value: anytype) Const {
    return .{ .ts = ts, .value = @intCast(value), .tail = "Mirrors `" ++ decl ++ "`." };
}

fn k(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(c, decl));
}

/// `k` reading from the byte-fed host archive (`c_abi_host`) instead of ocapn.
fn kd(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(cd, decl));
}

/// `k` reading from the driver archive (`c_abi_driver`, ADR-0024).
fn kdr(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(cdr, decl));
}

/// `k` reading from the iroh transport archive (`c_abi_net_transport_iroh`),
/// reflected through the sidecar stub so generation stays cargo-free.
fn ki(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(ci, decl));
}

fn kw(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(cw, decl));
}

fn kr(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(cr, decl));
}

fn kt(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(ct, decl));
}

fn ko(comptime ts: []const u8, comptime decl: []const u8) Const {
    return mirrored(ts, decl, @field(con, decl));
}

/// A binding policy value with no C declaration: `policy.zig` owns both the
/// value and the sentence printed beside it.
fn kp(comptime ts: []const u8, comptime name: []const u8) Const {
    const policy = @field(binding_policy, name);
    return .{ .ts = ts, .value = @intCast(policy.value), .tail = policy.doc };
}

pub const groups = [_]Group{
    .{
        // The subset the binding branches on; the rest surface through `check`
        // as thrown errors carrying the raw code.
        .doc = "A status code a glowcap C call returns: `OK`, or the cause of its refusal.",
        .entries = &.{
            k("OK", "GLOWCAP_OK"),
            k("INVALID_ARGUMENT", "GLOWCAP_ERR_INVALID_ARGUMENT"),
            k("SESSION", "GLOWCAP_ERR_SESSION"),
            k("CODEC", "GLOWCAP_ERR_CODEC"),
            k("INTERNAL", "GLOWCAP_ERR_INTERNAL"),
            k("WOULD_BLOCK", "GLOWCAP_ERR_WOULD_BLOCK"),
            k("CLOSED", "GLOWCAP_ERR_CLOSED"),
            k("IO", "GLOWCAP_ERR_IO"),
            k("FRAME_TOO_LARGE", "GLOWCAP_ERR_FRAME_TOO_LARGE"),
            k("BUFFER_TOO_SMALL", "GLOWCAP_ERR_BUFFER_TOO_SMALL"),
            k("NOT_FOUND", "GLOWCAP_ERR_NOT_FOUND"),
            k("UNSUPPORTED_VALUE", "GLOWCAP_ERR_UNSUPPORTED_VALUE"),
            k("BROKEN", "GLOWCAP_ERR_BROKEN"),
            k("TIMEOUT", "GLOWCAP_ERR_TIMEOUT"),
        },
    },
    .{
        .doc = "A `GlowcapFailureReport.layer` value: the tier that recorded a failure with no surviving caller.",
        .entries = &.{
            k("FAILURE_LAYER_CORE", "GLOWCAP_FAILURE_LAYER_CORE"),
            k("FAILURE_LAYER_DRIVER", "GLOWCAP_FAILURE_LAYER_DRIVER"),
            k("FAILURE_LAYER_TRANSPORT", "GLOWCAP_FAILURE_LAYER_TRANSPORT"),
            k("FAILURE_LAYER_BINDING", "GLOWCAP_FAILURE_LAYER_BINDING"),
            k("FAILURE_LAYER_APPLICATION_OBSERVER", "GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER"),
        },
    },
    .{
        .doc = "A `GlowcapFailureReport.scope` value: the owner a journaled failure belongs to.",
        .entries = &.{
            k("FAILURE_SCOPE_PROCESS", "GLOWCAP_FAILURE_SCOPE_PROCESS"),
            k("FAILURE_SCOPE_CONTEXT", "GLOWCAP_FAILURE_SCOPE_CONTEXT"),
            k("FAILURE_SCOPE_HOST", "GLOWCAP_FAILURE_SCOPE_HOST"),
            k("FAILURE_SCOPE_SESSION", "GLOWCAP_FAILURE_SCOPE_SESSION"),
            k("FAILURE_SCOPE_LISTENER", "GLOWCAP_FAILURE_SCOPE_LISTENER"),
            k("FAILURE_SCOPE_TRANSPORT", "GLOWCAP_FAILURE_SCOPE_TRANSPORT"),
            k("FAILURE_SCOPE_OPERATION", "GLOWCAP_FAILURE_SCOPE_OPERATION"),
        },
    },
    .{
        .doc = "A default bound of the failure journal: how many reports it keeps, and how many payload bytes each keeps.",
        .entries = &.{
            k("DEFAULT_FAILURE_CAPACITY", "GLOWCAP_DEFAULT_FAILURE_CAPACITY"),
            k("DEFAULT_FAILURE_PAYLOAD_CAP", "GLOWCAP_DEFAULT_FAILURE_PAYLOAD_CAP"),
        },
    },
    .{
        .doc = "A `GlowcapFrame.shape` value: byte-addressed storage, or 8-byte-word storage.",
        .entries = &.{
            k("FRAME_SHAPE_BYTE", "GLOWCAP_FRAME_SHAPE_BYTE"),
            k("FRAME_SHAPE_WORD", "GLOWCAP_FRAME_SHAPE_WORD"),
        },
    },
    .{
        .doc = "A `GlowcapHostAction.kind` value: one effect the byte-fed host (libglowcap_host) asks its embedder to perform.",
        .entries = &.{
            kd("HOST_ACTION_DIAL", "GLOWCAP_HOST_ACTION_DIAL"),
            kd("HOST_ACTION_FLUSH", "GLOWCAP_HOST_ACTION_FLUSH"),
            kd("HOST_ACTION_NEED_GIFT_ID", "GLOWCAP_HOST_ACTION_NEED_GIFT_ID"),
            kd("HOST_ACTION_SETTLE", "GLOWCAP_HOST_ACTION_SETTLE"),
            kd("HOST_ACTION_FAIL", "GLOWCAP_HOST_ACTION_FAIL"),
            kd("HOST_ACTION_CLOSE", "GLOWCAP_HOST_ACTION_CLOSE"),
            kd("HOST_ACTION_RESUME", "GLOWCAP_HOST_ACTION_RESUME"),
            kd("HOST_ACTION_CANCEL_DIAL", "GLOWCAP_HOST_ACTION_CANCEL_DIAL"),
        },
    },
    .{
        .doc = "A `GlowcapCloseOptions.pending` value: whether a close cancels admitted work or finishes it before the terminal close.",
        .entries = &.{
            kd("PENDING_CANCEL", "GLOWCAP_PENDING_CANCEL"),
            kd("PENDING_FINISH", "GLOWCAP_PENDING_FINISH"),
        },
    },
    .{
        .doc = "A lifecycle state of a Host, driver loop, or driver session, from admitting work to past its close barrier.",
        .entries = &.{
            kd("LIFECYCLE_ACTIVE", "GLOWCAP_LIFECYCLE_ACTIVE"),
            kd("LIFECYCLE_FINISHING", "GLOWCAP_LIFECYCLE_FINISHING"),
            kd("LIFECYCLE_TERMINATING", "GLOWCAP_LIFECYCLE_TERMINATING"),
            kd("LIFECYCLE_CLOSED", "GLOWCAP_LIFECYCLE_CLOSED"),
        },
    },
    .{
        .doc = "A `GlowcapCloseOptions` version, grace mode, or grace bound for closing a host-owned object.",
        .entries = &.{
            kd("CLOSE_OPTIONS_ABI_VERSION", "GLOWCAP_CLOSE_OPTIONS_ABI_VERSION"),
            kd("CLOSE_MAX_GRACE_MS", "GLOWCAP_CLOSE_MAX_GRACE_MS"),
            kd("CLOSE_GRACE_UNSPECIFIED", "GLOWCAP_CLOSE_GRACE_UNSPECIFIED"),
            kd("CLOSE_GRACE_FINITE", "GLOWCAP_CLOSE_GRACE_FINITE"),
            kd("CLOSE_GRACE_UNBOUNDED", "GLOWCAP_CLOSE_GRACE_UNBOUNDED"),
        },
    },
    .{
        .doc = "The `GlowcapSessionLimitOptions.abi_version` the host expects.",
        .entries = &.{
            kd("SESSION_LIMIT_OPTIONS_ABI_VERSION", "GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION"),
        },
    },
    .{
        // Host protocol admission and direct raw transport frame-shuttle
        // helpers keep separate memory postures.
        .doc = "A default maximum frame size in bytes: the host's protocol admission cap, or the raw transport shuttle cap.",
        .entries = &.{
            kd("DEFAULT_FRAME_CAP", "GLOWCAP_DEFAULT_FRAME_CAP"),
            k("RAW_TRANSPORT_DEFAULT_FRAME_CAP", "GLOWCAP_RAW_TRANSPORT_DEFAULT_FRAME_CAP"),
        },
    },
    .{
        .doc = "A host default or bound (libglowcap_host) for forwarding, handshakes, accepts, and discovery dials.",
        .entries = &.{
            kd("MAX_LOCAL_FORWARD_HOPS", "GLOWCAP_MAX_LOCAL_FORWARD_HOPS"),
            kd("HANDSHAKE_TIMEOUT_MS", "GLOWCAP_HANDSHAKE_TIMEOUT_MS"),
            kd("DEFAULT_PENDING_ACCEPTS", "GLOWCAP_DEFAULT_PENDING_ACCEPTS"),
            kd("DEFAULT_HANDSHAKE_CONCURRENCY", "GLOWCAP_DEFAULT_HANDSHAKE_CONCURRENCY"),
            kd("MAX_HANDSHAKE_CONCURRENCY", "GLOWCAP_MAX_HANDSHAKE_CONCURRENCY"),
            kd("DISCOVERY_DIAL_RETRY_MS", "GLOWCAP_DISCOVERY_DIAL_RETRY_MS"),
            kd("DISCOVERY_DIAL_MAX_ATTEMPTS", "GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS"),
        },
    },
    .{
        .doc = "A driver loop options or failure layout version, default, or bound (libglowcap_driver).",
        .entries = &.{
            kdr("DRIVER_OPTIONS_ABI_VERSION", "GLOWCAP_DRIVER_OPTIONS_ABI_VERSION"),
            kdr("DRIVER_FAILURE_ABI_VERSION", "GLOWCAP_DRIVER_FAILURE_ABI_VERSION"),
            kdr("DRIVER_MAX_WAIT_MS", "GLOWCAP_DRIVER_MAX_WAIT_MS"),
            kdr("DRIVER_WAIT_UNBOUNDED", "GLOWCAP_DRIVER_WAIT_UNBOUNDED"),
            kdr("DRIVER_DEFAULT_WIRE_BUFFER_BYTES", "GLOWCAP_DRIVER_DEFAULT_WIRE_BUFFER_BYTES"),
            kdr("DRIVER_DEFAULT_MAX_PENDING_OPENS", "GLOWCAP_DRIVER_DEFAULT_MAX_PENDING_OPENS"),
            kdr("DRIVER_DEFAULT_HANDSHAKE_MS", "GLOWCAP_DRIVER_DEFAULT_HANDSHAKE_MS"),
            kdr("DRIVER_DEFAULT_LISTENER_SETUP_MS", "GLOWCAP_DRIVER_DEFAULT_LISTENER_SETUP_MS"),
            kdr("DRIVER_DEFAULT_SETTLE_MS", "GLOWCAP_DRIVER_DEFAULT_SETTLE_MS"),
            kdr("DRIVER_DEFAULT_BUSY_POLL_NS", "GLOWCAP_DRIVER_DEFAULT_BUSY_POLL_NS"),
            kdr("DRIVER_MAX_BUSY_POLL_NS", "GLOWCAP_DRIVER_MAX_BUSY_POLL_NS"),
        },
    },
    .{
        .doc = "A `GlowcapTraceEvent` kind, or the digest length a trace event carries (libglowcap_host).",
        .entries = &.{
            kd("TRACE_SESSION_OPEN", "GLOWCAP_TRACE_SESSION_OPEN"),
            kd("TRACE_MESSAGE", "GLOWCAP_TRACE_MESSAGE"),
            kd("TRACE_SESSION_CLOSE", "GLOWCAP_TRACE_SESSION_CLOSE"),
            kd("TRACE_DIGEST_BYTES", "GLOWCAP_TRACE_DIGEST_BYTES"),
        },
    },
    .{
        .doc = "A `GlowcapTransportProfile.designator_scheme` value: whether a transport's locator designator is a dialable address or a peer key.",
        .entries = &.{
            kd("DESIGNATOR_SCHEME_ADDRESS", "GLOWCAP_DESIGNATOR_SCHEME_ADDRESS"),
            kd("DESIGNATOR_SCHEME_KEY", "GLOWCAP_DESIGNATOR_SCHEME_KEY"),
        },
    },
    .{
        .doc = "A host outbound buffer capacity, or a durable swiss-number entropy or length, in bytes (libglowcap_host).",
        .entries = &.{
            kd("HOST_OUTBOUND_PREFIX_CAP", "GLOWCAP_HOST_OUTBOUND_PREFIX_CAP"),
            kd("HOST_DURABLE_ENTROPY_LEN", "GLOWCAP_HOST_DURABLE_ENTROPY_LEN"),
            kd("HOST_DURABLE_SWISS_LEN", "GLOWCAP_HOST_DURABLE_SWISS_LEN"),
        },
    },
    .{
        .doc = "A `GlowcapDriverEvent.kind` value from the driver archive's event queue (libglowcap_driver, ADR-0024).",
        .entries = &.{
            kdr("DRIVER_EVENT_OPENED", "GLOWCAP_DRIVER_EVENT_OPENED"),
            kdr("DRIVER_EVENT_OPEN_FAILED", "GLOWCAP_DRIVER_EVENT_OPEN_FAILED"),
            kdr("DRIVER_EVENT_ACCEPTED", "GLOWCAP_DRIVER_EVENT_ACCEPTED"),
            kdr("DRIVER_EVENT_SESSION_CLOSED", "GLOWCAP_DRIVER_EVENT_SESSION_CLOSED"),
            kdr("DRIVER_EVENT_COMPLETION", "GLOWCAP_DRIVER_EVENT_COMPLETION"),
            kdr("DRIVER_EVENT_LISTENER_READY", "GLOWCAP_DRIVER_EVENT_LISTENER_READY"),
            kdr("DRIVER_EVENT_LISTENER_FAILED", "GLOWCAP_DRIVER_EVENT_LISTENER_FAILED"),
        },
    },
    .{
        .doc = "A `GlowcapDriverFailure` carrier phase, or a detail flag saying which carrier detail fields are present.",
        .entries = &.{
            kdr("CARRIER_PHASE_NONE", "GLOWCAP_CARRIER_PHASE_NONE"),
            kdr("CARRIER_PHASE_RESOLVE", "GLOWCAP_CARRIER_PHASE_RESOLVE"),
            kdr("CARRIER_PHASE_CONNECT", "GLOWCAP_CARRIER_PHASE_CONNECT"),
            kdr("CARRIER_PHASE_SECURE_HANDSHAKE", "GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE"),
            kdr("CARRIER_PHASE_WEBSOCKET_UPGRADE", "GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE"),
            kdr("CARRIER_PHASE_REGISTRATION", "GLOWCAP_CARRIER_PHASE_REGISTRATION"),
            kdr("CARRIER_PHASE_RECEIVE", "GLOWCAP_CARRIER_PHASE_RECEIVE"),
            kdr("CARRIER_PHASE_TRANSMIT", "GLOWCAP_CARRIER_PHASE_TRANSMIT"),
            kdr("CARRIER_PHASE_SHUTDOWN", "GLOWCAP_CARRIER_PHASE_SHUTDOWN"),
            kdr("CARRIER_DETAIL_PEER_ALERT", "GLOWCAP_CARRIER_DETAIL_PEER_ALERT"),
            kdr("CARRIER_DETAIL_ENGINE_CODE", "GLOWCAP_CARRIER_DETAIL_ENGINE_CODE"),
        },
    },
    .{
        .doc = "How the driver loop adopted a session: this side dialed it, or a listener accepted it.",
        .entries = &.{
            kdr("DRIVER_ADOPT_DIALED", "GLOWCAP_DRIVER_ADOPT_DIALED"),
            kdr("DRIVER_ADOPT_ACCEPTED", "GLOWCAP_DRIVER_ADOPT_ACCEPTED"),
        },
    },
    .{
        .doc = "A `GlowcapLocatorView` version, a hint value kind, or the wire form of a locator's hint set.",
        .entries = &.{
            kdr("LOCATOR_VIEW_ABI_VERSION", "GLOWCAP_LOCATOR_VIEW_ABI_VERSION"),
            kdr("HINT_STRING", "GLOWCAP_HINT_STRING"),
            kdr("HINT_BYTES", "GLOWCAP_HINT_BYTES"),
            kdr("HINT_BOOLEAN", "GLOWCAP_HINT_BOOLEAN"),
            kdr("HINT_INTEGER", "GLOWCAP_HINT_INTEGER"),
            kdr("HINTS_MAP", "GLOWCAP_HINTS_MAP"),
            kdr("HINTS_BOOLEAN_FALSE", "GLOWCAP_HINTS_BOOLEAN_FALSE"),
        },
    },
    .{
        // A caller needing a proved durable peer reads this, never a
        // designator-equals-session-key comparison.
        .doc = "A `GlowcapPartnerIdentity.provenance` value: how the partner's advertised durable identity was authenticated (ADR-0028).",
        .entries = &.{
            kd("DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT", "GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT"),
            kd("DURABLE_PROVENANCE_UNAUTHENTICATED", "GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED"),
        },
    },
    .{
        .doc = "A `GlowcapTcpConfig.profiles` bit, or the set of every TCP profile (libglowcap_net_transport_tcp).",
        .entries = &.{
            kt("TCP_PROFILE_TCP", "GLOWCAP_TCP_PROFILE_TCP"),
            kt("TCP_PROFILE_KEYED_TCP", "GLOWCAP_TCP_PROFILE_KEYED_TCP"),
            kt("TCP_PROFILE_NOISE_TCP", "GLOWCAP_TCP_PROFILE_NOISE_TCP"),
            kt("TCP_PROFILES_ALL", "GLOWCAP_TCP_PROFILES_ALL"),
        },
    },
    .{
        .doc = "An onion transport control-port authentication mode, an onion service id length, or a service key capacity (libglowcap_net_transport_onion).",
        .entries = &.{
            ko("ONION_AUTH_NONE", "GLOWCAP_ONION_AUTH_NONE"),
            ko("ONION_AUTH_COOKIE", "GLOWCAP_ONION_AUTH_COOKIE"),
            ko("ONION_AUTH_PASSWORD", "GLOWCAP_ONION_AUTH_PASSWORD"),
            ko("ONION_SERVICE_ID_LEN", "GLOWCAP_ONION_SERVICE_ID_LEN"),
            ko("ONION_SERVICE_KEY_CAP", "GLOWCAP_ONION_SERVICE_KEY_CAP"),
        },
    },
    .{
        // The stack's `Reachability` surface and its hint-less-redeem default
        // read these instead of hand-typing numbers.
        .doc = "An iroh reachability posture, the redeem posture's default, an iroh id length or address bound, or a read chunk size (libglowcap_net_transport_iroh).",
        .entries = &.{
            ki("IROH_REACH_DIRECT", "GLOWCAP_IROH_REACH_DIRECT"),
            ki("IROH_REACH_DISCOVERY", "GLOWCAP_IROH_REACH_DISCOVERY"),
            ki("IROH_REACH_DISCOVERY_NO_RELAY", "GLOWCAP_IROH_REACH_DISCOVERY_NO_RELAY"),
            ki("IROH_REACH_LOCAL_DISCOVERY", "GLOWCAP_IROH_REACH_LOCAL_DISCOVERY"),
            ki("IROH_REACH_REDEEM_DEFAULT", "GLOWCAP_IROH_REACH_REDEEM_DEFAULT"),
            ki("IROH_NODE_ID_BYTES", "GLOWCAP_IROH_NODE_ID_BYTES"),
            ki("IROH_MAX_DIRECT_ADDRESS_BYTES", "GLOWCAP_IROH_MAX_DIRECT_ADDRESS_BYTES"),
            ki("BINDING_IROH_READ_CHUNK_BYTES", "GLOWCAP_IROH_READ_CHUNK_BYTES"),
        },
    },
    .{
        .doc = "A bit of the readiness bitset an iroh drain record carries.",
        .entries = &.{
            ki("IROH_EV_READABLE", "GLOWCAP_IROH_EV_READABLE"),
            ki("IROH_EV_WRITABLE", "GLOWCAP_IROH_EV_WRITABLE"),
            ki("IROH_EV_CLOSED", "GLOWCAP_IROH_EV_CLOSED"),
            ki("IROH_EV_ACCEPT", "GLOWCAP_IROH_EV_ACCEPT"),
            ki("IROH_EV_CONNECT", "GLOWCAP_IROH_EV_CONNECT"),
        },
    },
    .{
        .doc = "A bit of the readiness bitset a WebRTC drain record carries.",
        .entries = &.{
            kw("WEBRTC_EV_OPEN", "GLOWCAP_WEBRTC_EV_OPEN"),
            kw("WEBRTC_EV_CANDIDATE", "GLOWCAP_WEBRTC_EV_CANDIDATE"),
            kw("WEBRTC_EV_READABLE", "GLOWCAP_WEBRTC_EV_READABLE"),
            kw("WEBRTC_EV_WRITABLE", "GLOWCAP_WEBRTC_EV_WRITABLE"),
            kw("WEBRTC_EV_CLOSED", "GLOWCAP_WEBRTC_EV_CLOSED"),
        },
    },
    .{
        .doc = "A WebRTC signaling, ICE, or queue bound (libglowcap_net_transport_webrtc).",
        .entries = &.{
            kw("WEBRTC_MAX_SIGNAL_BYTES", "GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES"),
            kw("WEBRTC_MAX_ICE_CANDIDATE_BYTES", "GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES"),
            kw("WEBRTC_MAX_ICE_SERVERS", "GLOWCAP_WEBRTC_MAX_ICE_SERVERS"),
            kw("WEBRTC_MAX_ICE_URLS_PER_SERVER", "GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER"),
            kw("WEBRTC_MAX_ICE_URL_BYTES", "GLOWCAP_WEBRTC_MAX_ICE_URL_BYTES"),
            kw("WEBRTC_MAX_ICE_CREDENTIAL_BYTES", "GLOWCAP_WEBRTC_MAX_ICE_CREDENTIAL_BYTES"),
            kw("WEBRTC_MAX_PENDING_ICE_CANDIDATES", "GLOWCAP_WEBRTC_MAX_PENDING_ICE_CANDIDATES"),
            kw("WEBRTC_MAX_ACCEPTS_IN_FLIGHT", "GLOWCAP_WEBRTC_MAX_ACCEPTS_IN_FLIGHT"),
            kw("WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES", "GLOWCAP_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES"),
            kw("WEBRTC_DATA_CHANNEL_QUEUE_BYTES", "GLOWCAP_WEBRTC_DATA_CHANNEL_QUEUE_BYTES"),
        },
    },
    .{
        .doc = "A resource policy the language bindings own, with no C declaration behind it.",
        .entries = &.{
            kp("BINDING_UNOBSERVED_OUTCOME_CAP", "unobserved_outcome_cap"),
            kp("BINDING_READINESS_DRAIN_CAP", "readiness_drain_cap"),
            kp("BINDING_STREAM_READ_CHUNK_BYTES", "stream_read_chunk_bytes"),
            kp("BINDING_TRACE_PAYLOAD_CAP_BYTES", "trace_payload_cap_bytes"),
            kp("BINDING_SECONDARY_FAILURE_CAP", "secondary_failure_cap"),
            kp("BINDING_RELAY_IDLE_TIMEOUT_MS", "relay_idle_timeout_ms"),
            kp("BINDING_RELAY_MAX_BYTES_PER_SESSION", "relay_max_bytes_per_session"),
            kp("BINDING_RELAY_READ_CHUNK_BYTES", "relay_read_chunk_bytes"),
            kp("BINDING_RELAY_TCP_DIAL_TIMEOUT_MS", "relay_tcp_dial_timeout_ms"),
            kp("BINDING_RELAY_WEBSOCKET_BUFFER_BYTES", "relay_websocket_buffer_bytes"),
            kp("BINDING_WEBSOCKET_MESSAGE_CAP_BYTES", "websocket_message_cap_bytes"),
            kp("BINDING_WEBSOCKET_SEND_HIGH_WATER_BYTES", "websocket_send_high_water_bytes"),
            kp("BINDING_WEBSOCKET_DRAIN_POLL_MS", "websocket_drain_poll_ms"),
            kp("BINDING_WEBSOCKET_CLOSE_TIMEOUT_MS", "websocket_close_timeout_ms"),
            kp("BINDING_WEBSOCKET_INBOUND_HIGH_WATER_BYTES", "websocket_inbound_high_water_bytes"),
        },
    },
    .{
        .doc = "A relay transport config version, TLS trust mode, or hint bound (libglowcap_net_transport_relay).",
        .entries = &.{
            kr("RELAY_CONFIG_ABI_VERSION", "GLOWCAP_RELAY_CONFIG_ABI_VERSION"),
            kr("RELAY_TRUST_SYSTEM", "GLOWCAP_RELAY_TRUST_SYSTEM"),
            kr("RELAY_TRUST_COPIED_PEM", "GLOWCAP_RELAY_TRUST_COPIED_PEM"),
            kr("RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES", "GLOWCAP_RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES"),
        },
    },
    .{
        .doc = "A `GlowcapArgument.kind` tag: the shape of value an argument carries.",
        .entries = &.{
            k("ARG_INTEGER", "GLOWCAP_ARG_INTEGER"),
            k("ARG_FLOAT64", "GLOWCAP_ARG_FLOAT64"),
            k("ARG_BOOLEAN", "GLOWCAP_ARG_BOOLEAN"),
            k("ARG_BYTES", "GLOWCAP_ARG_BYTES"),
            k("ARG_STRING", "GLOWCAP_ARG_STRING"),
            k("ARG_SYMBOL", "GLOWCAP_ARG_SYMBOL"),
            k("ARG_VOID", "GLOWCAP_ARG_VOID"),
            k("ARG_REFERENCE", "GLOWCAP_ARG_REFERENCE"),
            k("ARG_LIST", "GLOWCAP_ARG_LIST"),
            k("ARG_SET", "GLOWCAP_ARG_SET"),
            k("ARG_TAGGED", "GLOWCAP_ARG_TAGGED"),
            k("ARG_KEYWORD", "GLOWCAP_ARG_KEYWORD"),
            k("ARG_BIG_INTEGER", "GLOWCAP_ARG_BIG_INTEGER"),
            k("ARG_STRUCT", "GLOWCAP_ARG_STRUCT"),
            k("ARG_ERROR", "GLOWCAP_ARG_ERROR"),
            k("ARG_INTEGERS", "GLOWCAP_ARG_INTEGERS"),
        },
    },
    .{
        .doc = "A wire codec selector the host constructor and the transports take.",
        .entries = &.{
            k("CODEC_UNKNOWN", "GLOWCAP_CODEC_UNKNOWN"),
            k("CODEC_SYRUP", "GLOWCAP_CODEC_SYRUP"),
            k("CODEC_CAPNP", "GLOWCAP_CODEC_CAPNP"),
        },
    },
    .{
        .doc = "A CapTP profile selector: the pinned Goblins-compatible `1.0` profile, or the one tracking current OCapN direction.",
        .entries = &.{
            k("CAPTP_V1_0", "GLOWCAP_CAPTP_V1_0"),
            k("CAPTP_NEXT", "GLOWCAP_CAPTP_NEXT"),
        },
    },
    .{
        .doc = "A feature bit a host offers in its handshake, or a named set of them.",
        .entries = &.{
            k("FEATURE_PIPELINING", "GLOWCAP_FEATURE_PIPELINING"),
            k("FEATURE_HANDOFF", "GLOWCAP_FEATURE_HANDOFF"),
            k("FEATURE_WIRE_DELTA", "GLOWCAP_FEATURE_WIRE_DELTA"),
            k("FEATURE_STURDYREF", "GLOWCAP_FEATURE_STURDYREF"),
            k("FEATURE_UNTAG", "GLOWCAP_FEATURE_UNTAG"),
            k("FEATURE_MULTI_LOCATION", "GLOWCAP_FEATURE_MULTI_LOCATION"),
            k("FEATURE_MINIMUM", "GLOWCAP_FEATURE_MINIMUM"),
            k("FEATURE_BASELINE", "GLOWCAP_FEATURE_BASELINE"),
            k("FEATURE_FULL", "GLOWCAP_FEATURE_FULL"),
        },
    },
    .{
        .doc = "The codec, CapTP profile, or feature set a host uses when its caller names none, and the pairs for interoperating and for glowcap's own peers.",
        .entries = &.{
            k("DEFAULT_CODEC", "GLOWCAP_DEFAULT_CODEC"),
            k("DEFAULT_CAPTP_VERSION", "GLOWCAP_DEFAULT_CAPTP_VERSION"),
            k("DEFAULT_FEATURES", "GLOWCAP_DEFAULT_FEATURES"),
            k("INTEROP_CODEC", "GLOWCAP_INTEROP_CODEC"),
            k("INTEROP_CAPTP_VERSION", "GLOWCAP_INTEROP_CAPTP_VERSION"),
            k("OWN_CODEC", "GLOWCAP_OWN_CODEC"),
            k("OWN_CAPTP_VERSION", "GLOWCAP_OWN_CAPTP_VERSION"),
        },
    },
    .{
        .doc = "A `GlowcapLastAbort.domain` value: which layer classified the failure.",
        .entries = &.{
            k("ABORT_DOMAIN_CODEC", "GLOWCAP_ABORT_DOMAIN_CODEC"),
            k("ABORT_DOMAIN_SESSION", "GLOWCAP_ABORT_DOMAIN_SESSION"),
            k("ABORT_DOMAIN_FOREIGN", "GLOWCAP_ABORT_DOMAIN_FOREIGN"),
        },
    },
};
