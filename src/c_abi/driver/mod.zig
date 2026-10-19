//! `libglowcap_driver` (ADR-0024): the driver archive. It exports only the
//! `glowcap_driver_*` loop family that owns the transport-to-host
//! choreography every binding would otherwise re-implement: park on one readiness
//! descriptor, step, drain one event queue.
//!
//! A consumer of the C driver loop composes `libglowcap_host`, `libglowcap_driver`, and
//! the transport archives it selects. Symbol families stay disjoint.
//!
//! The private `loop.zig` state aggregate and `loop/` transition owners compose
//! here. This root owns the public C types and exact symbol index the header
//! generator and bindings reflect.

const std = @import("std");

const shared = @import("c_abi_shared");
const c_abi_host = @import("c_abi_host");
const driver = @import("driver");
const driver_error = @import("error.zig");
const failure_output = @import("failure_output.zig");
const carrier_phase = @import("carrier_phase.zig");

const loop = @import("loop.zig");
const loop_drive = @import("loop/drive.zig");
const loop_events = @import("loop/events.zig");
const loop_lifecycle = @import("loop/lifecycle.zig");
const loop_listeners = @import("loop/listeners.zig");
const loop_opens = @import("loop/opens.zig");
const loop_sessions = @import("loop/sessions.zig");

/// The annotated export inventory for the `glowcap_driver_*` family
/// (the `glowcap_host_*` half keeps its own inventory in `c_abi_host`).
pub const symbols = @import("symbols.zig");
/// Foreign stream tables as completion-loop providers (ADR-0018).
pub const stream_completion = @import("provider_registry/stream_completion.zig");

pub const contract_layouts = [_]shared.archive_contract.Layout{
    shared.archive_contract.layout("GLOWCAP_DRIVER_OPTIONS", GlowcapDriverOptions),
    shared.archive_contract.layout("GLOWCAP_DRIVER_FAILURE", GlowcapDriverFailure),
    shared.archive_contract.layout("GLOWCAP_DRIVER_EVENT", GlowcapDriverEvent),
};

/// Exact reflected callable/layout identity for the Zig driver archive.
pub const GLOWCAP_DRIVER_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint(
    "driver",
    @This(),
    .{ shared.contract_layouts, c_abi_host.contract_layouts, contract_layouts },
);

pub export fn glowcap_driver_archive_fingerprint() u64 {
    return GLOWCAP_DRIVER_ARCHIVE_FINGERPRINT;
}

// ── Shared value vocabulary (by layout, from the sibling roots) ──────────────

pub const GlowcapContext = shared.GlowcapContext;
pub const GlowcapMultiplexedTransport = shared.GlowcapMultiplexedTransport;
pub const GlowcapMultiplexedReadyEvent = shared.GlowcapMultiplexedReadyEvent;
pub const GlowcapLocatorHintView = shared.GlowcapLocatorHintView;
pub const GlowcapLocatorView = shared.GlowcapLocatorView;
pub const GlowcapStreamTransport = shared.GlowcapStreamTransport;
pub const GlowcapProviderFailure = shared.GlowcapProviderFailure;
pub const GlowcapTransportProfile = shared.GlowcapTransportProfile;
pub const GlowcapTransportOperationOptions = shared.GlowcapTransportOperationOptions;
pub const GlowcapDialOrigin = shared.GlowcapDialOrigin;
pub const GlowcapTransportProviderEntry = shared.GlowcapTransportProviderEntry;
pub const GlowcapTransportProvider = shared.GlowcapTransportProvider;
pub const GlowcapStreamStartConnectFn = shared.transport_provider.GlowcapStreamStartConnectFn;
pub const GlowcapStreamFinishConnectFn = shared.transport_provider.GlowcapStreamFinishConnectFn;
pub const GlowcapStreamCancelConnectFn = shared.transport_provider.GlowcapStreamCancelConnectFn;
pub const GlowcapListenResult = shared.transport_provider.GlowcapListenResult;
pub const GlowcapStreamListenFn = shared.transport_provider.GlowcapStreamListenFn;
pub const GlowcapStreamFinishListenFn = shared.transport_provider.GlowcapStreamFinishListenFn;
pub const GlowcapStreamCancelListenFn = shared.transport_provider.GlowcapStreamCancelListenFn;
pub const GLOWCAP_LISTEN_READY = shared.transport_provider.GLOWCAP_LISTEN_READY;
pub const GLOWCAP_LISTEN_PENDING = shared.transport_provider.GLOWCAP_LISTEN_PENDING;
pub const GlowcapStreamListenerWaitFn = shared.transport_provider.GlowcapStreamListenerWaitFn;
pub const GlowcapStreamListenerReadinessFdFn = shared.transport_provider.GlowcapStreamListenerReadinessFdFn;
pub const GlowcapLocatorSinkFn = shared.GlowcapLocatorSinkFn;
pub const GlowcapTransportListenerLocatorFn = shared.transport_provider.GlowcapTransportListenerLocatorFn;
pub const GlowcapTransportListenerAdvertiseFn = shared.transport_provider.GlowcapTransportListenerAdvertiseFn;
pub const GlowcapTransportListenerRestorationStateFn = shared.transport_provider.GlowcapTransportListenerRestorationStateFn;
pub const GlowcapStreamAcceptFn = shared.transport_provider.GlowcapStreamAcceptFn;
pub const GlowcapStreamListenerCloseFn = shared.transport_provider.GlowcapStreamListenerCloseFn;
pub const GlowcapStreamTryReadFn = shared.transport_provider.GlowcapStreamTryReadFn;
pub const GlowcapStreamTryWriteFn = shared.transport_provider.GlowcapStreamTryWriteFn;
pub const GlowcapStreamConnCloseFn = shared.transport_provider.GlowcapStreamConnCloseFn;
pub const GlowcapStreamConnTakeFailureFn = shared.transport_provider.GlowcapStreamConnTakeFailureFn;
pub const GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION = shared.transport_provider.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION;
pub const GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION = shared.transport_provider.GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION;
pub const GLOWCAP_STREAM_TRANSPORT_ABI_VERSION = shared.transport_provider.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION;
pub const GLOWCAP_TRANSPORT_EXEC_STREAM = shared.transport_provider.GLOWCAP_TRANSPORT_EXEC_STREAM;
pub const GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED = shared.transport_provider.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED;
pub const GLOWCAP_LOCATOR_VIEW_ABI_VERSION = shared.GLOWCAP_LOCATOR_VIEW_ABI_VERSION;
pub const GLOWCAP_HINT_STRING = shared.GLOWCAP_HINT_STRING;
pub const GLOWCAP_HINT_BYTES = shared.GLOWCAP_HINT_BYTES;
pub const GLOWCAP_HINT_BOOLEAN = shared.GLOWCAP_HINT_BOOLEAN;
pub const GLOWCAP_HINT_INTEGER = shared.GLOWCAP_HINT_INTEGER;
pub const GLOWCAP_HINTS_MAP = shared.GLOWCAP_HINTS_MAP;
pub const GLOWCAP_HINTS_BOOLEAN_FALSE = shared.GLOWCAP_HINTS_BOOLEAN_FALSE;
pub const GlowcapMultiplexedReadinessFdFn = shared.multiplexed_transport.GlowcapMultiplexedReadinessFdFn;
pub const GlowcapMultiplexedDrainReadyFn = shared.multiplexed_transport.GlowcapMultiplexedDrainReadyFn;
pub const GlowcapMultiplexedStartConnectFn = shared.multiplexed_transport.GlowcapMultiplexedStartConnectFn;
pub const GlowcapMultiplexedFinishConnectFn = shared.multiplexed_transport.GlowcapMultiplexedFinishConnectFn;
pub const GlowcapMultiplexedClaimExternalFn = shared.multiplexed_transport.GlowcapMultiplexedClaimExternalFn;
pub const GlowcapMultiplexedListenFn = shared.multiplexed_transport.GlowcapMultiplexedListenFn;
pub const GlowcapMultiplexedFinishListenFn = shared.multiplexed_transport.GlowcapMultiplexedFinishListenFn;
pub const GlowcapMultiplexedFinishAcceptFn = shared.multiplexed_transport.GlowcapMultiplexedFinishAcceptFn;
pub const GlowcapMultiplexedStopListenFn = shared.multiplexed_transport.GlowcapMultiplexedStopListenFn;
pub const GlowcapMultiplexedSubjectFn = shared.multiplexed_transport.GlowcapMultiplexedSubjectFn;
pub const GlowcapMultiplexedConnTakeFailureFn = shared.multiplexed_transport.GlowcapMultiplexedConnTakeFailureFn;
pub const GlowcapMultiplexedTryReadFn = shared.multiplexed_transport.GlowcapMultiplexedTryReadFn;
pub const GlowcapMultiplexedTryWriteFn = shared.multiplexed_transport.GlowcapMultiplexedTryWriteFn;
pub const GlowcapMultiplexedConnRemoteKeyFn = shared.multiplexed_transport.GlowcapMultiplexedConnRemoteKeyFn;
pub const GLOWCAP_TRANSPORT_WOULD_BLOCK = shared.transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK;
pub const GLOWCAP_MULTIPLEXED_EV_READABLE = shared.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE;
pub const GLOWCAP_MULTIPLEXED_EV_WRITABLE = shared.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_WRITABLE;
pub const GLOWCAP_MULTIPLEXED_EV_CLOSED = shared.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CLOSED;
pub const GLOWCAP_MULTIPLEXED_EV_ACCEPT = shared.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_ACCEPT;
pub const GLOWCAP_MULTIPLEXED_EV_CONNECT = shared.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT;
pub const GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION = shared.multiplexed_transport.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION;
pub const GLOWCAP_DESIGNATOR_SCHEME_ADDRESS = shared.transport_provider.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS;
pub const GLOWCAP_DESIGNATOR_SCHEME_KEY = shared.transport_provider.GLOWCAP_DESIGNATOR_SCHEME_KEY;
pub const GLOWCAP_SEALED_CHANNEL_NONE = shared.transport_provider.GLOWCAP_SEALED_CHANNEL_NONE;
pub const GLOWCAP_SEALED_CHANNEL_NOISE_XK = shared.transport_provider.GLOWCAP_SEALED_CHANNEL_NOISE_XK;
pub const GLOWCAP_WIRE_FRAMING_BYTE_STREAM = shared.transport_provider.GLOWCAP_WIRE_FRAMING_BYTE_STREAM;
pub const GLOWCAP_WIRE_FRAMING_MESSAGE = shared.transport_provider.GLOWCAP_WIRE_FRAMING_MESSAGE;
pub const GLOWCAP_CARRIER_PHASE_NONE = shared.transport_provider.GLOWCAP_CARRIER_PHASE_NONE;
pub const GLOWCAP_CARRIER_PHASE_RESOLVE = shared.transport_provider.GLOWCAP_CARRIER_PHASE_RESOLVE;
pub const GLOWCAP_CARRIER_PHASE_CONNECT = shared.transport_provider.GLOWCAP_CARRIER_PHASE_CONNECT;
pub const GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE = shared.transport_provider.GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE;
pub const GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE = shared.transport_provider.GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE;
pub const GLOWCAP_CARRIER_PHASE_REGISTRATION = shared.transport_provider.GLOWCAP_CARRIER_PHASE_REGISTRATION;
pub const GLOWCAP_CARRIER_PHASE_RECEIVE = shared.transport_provider.GLOWCAP_CARRIER_PHASE_RECEIVE;
pub const GLOWCAP_CARRIER_PHASE_TRANSMIT = shared.transport_provider.GLOWCAP_CARRIER_PHASE_TRANSMIT;
pub const GLOWCAP_CARRIER_PHASE_SHUTDOWN = shared.transport_provider.GLOWCAP_CARRIER_PHASE_SHUTDOWN;
pub const GLOWCAP_CARRIER_DETAIL_PEER_ALERT = shared.transport_provider.GLOWCAP_CARRIER_DETAIL_PEER_ALERT;
pub const GLOWCAP_CARRIER_DETAIL_ENGINE_CODE = shared.transport_provider.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
pub const GlowcapHost = c_abi_host.GlowcapHost;
pub const GlowcapHostSession = c_abi_host.GlowcapHostSession;
pub const GlowcapHostAction = c_abi_host.GlowcapHostAction;
pub const GlowcapReference = shared.GlowcapReference;
pub const GlowcapCloseOptions = shared.GlowcapCloseOptions;
pub const GLOWCAP_CLOSE_OPTIONS_ABI_VERSION = shared.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION;
pub const GLOWCAP_CLOSE_MAX_GRACE_MS = shared.GLOWCAP_CLOSE_MAX_GRACE_MS;
pub const GLOWCAP_CLOSE_GRACE_UNSPECIFIED = shared.GLOWCAP_CLOSE_GRACE_UNSPECIFIED;
pub const GLOWCAP_CLOSE_GRACE_FINITE = shared.GLOWCAP_CLOSE_GRACE_FINITE;
pub const GLOWCAP_CLOSE_GRACE_UNBOUNDED = shared.GLOWCAP_CLOSE_GRACE_UNBOUNDED;
pub const GLOWCAP_PENDING_CANCEL = shared.GLOWCAP_PENDING_CANCEL;
pub const GLOWCAP_PENDING_FINISH = shared.GLOWCAP_PENDING_FINISH;
pub const GLOWCAP_LIFECYCLE_ACTIVE = c_abi_host.GLOWCAP_LIFECYCLE_ACTIVE;
pub const GLOWCAP_LIFECYCLE_FINISHING = c_abi_host.GLOWCAP_LIFECYCLE_FINISHING;
pub const GLOWCAP_LIFECYCLE_TERMINATING = c_abi_host.GLOWCAP_LIFECYCLE_TERMINATING;
pub const GLOWCAP_LIFECYCLE_CLOSED = c_abi_host.GLOWCAP_LIFECYCLE_CLOSED;

// ── Handles ──────────────────────────────────────────────────────────────────

/// A stepping CapTP loop over one multi-session host: the host, its
/// transports, its listeners, and one readiness descriptor. Created with
/// `glowcap_driver_take_host`. Released with `glowcap_driver_release`. One thread
/// drives one loop. `glowcap_driver_wake` is the one cross-thread verb.
pub const GlowcapDriverLoop = opaque {};
pub const GLOWCAP_DRIVER_FAILURE_ABI_VERSION = failure_output.abi_version;
pub const GlowcapDriverFailure = failure_output.GlowcapDriverFailure;

/// Current layout version for `GlowcapDriverOptions`.
pub const GLOWCAP_DRIVER_OPTIONS_ABI_VERSION: u32 = 1;
/// Largest positive wait budget representable by `driver.Budget`.
pub const GLOWCAP_DRIVER_MAX_WAIT_MS: u32 = std.math.maxInt(i32);
/// A `handshake_ms`, `listener_setup_ms`, or `settle_ms` value with no
/// deadline. SECURITY.md asks deployments to set a finite one.
pub const GLOWCAP_DRIVER_WAIT_UNBOUNDED: u32 = 0;
/// Default bytes retained for each stream direction or multiplexed read staging.
pub const GLOWCAP_DRIVER_DEFAULT_WIRE_BUFFER_BYTES: usize = driver.default_wire_buffer_bytes;
/// Default maximum transport connects and CapTP handshakes admitted at once.
pub const GLOWCAP_DRIVER_DEFAULT_MAX_PENDING_OPENS: usize = driver.default_max_pending_opens;
/// Default CapTP handshake progress budget in milliseconds.
pub const GLOWCAP_DRIVER_DEFAULT_HANDSHAKE_MS: u32 = @intCast(driver.default_handshake_timeout_ms);
/// Default listener-construction progress budget in milliseconds.
pub const GLOWCAP_DRIVER_DEFAULT_LISTENER_SETUP_MS: u32 = @intCast(driver.default_listener_setup_ms);
/// Default application-answer progress budget in milliseconds.
pub const GLOWCAP_DRIVER_DEFAULT_SETTLE_MS: u32 = @intCast(driver.default_settle_ms);
/// Default busy-poll window in nanoseconds: zero parks at once.
pub const GLOWCAP_DRIVER_DEFAULT_BUSY_POLL_NS: u64 = 0;
/// The longest busy-poll window the loop adopts. A cross-thread settle or
/// wake waits out the whole window, so a longer one is refused.
pub const GLOWCAP_DRIVER_MAX_BUSY_POLL_NS: u64 = driver.HostRuntime.max_busy_poll_ns;
/// Construction policy for the Zig driver face. A zero wait budget is the
/// explicit unbounded form. Nonzero values bound progress in milliseconds.
/// `wire_buffer_bytes` is retained
/// once for each stream direction, or once for multiplexed read staging, per live
/// session. `max_pending_opens` bounds pre-open session and wire memory across
/// every transport route. The layout fields must identify this record. Every
/// buffer and admission limits must be positive.
pub const GlowcapDriverOptions = extern struct {
    abi_version: u32,
    struct_size: usize,
    wire_buffer_bytes: usize,
    max_pending_opens: usize,
    /// Handshake progress budget in milliseconds. `GLOWCAP_DRIVER_WAIT_UNBOUNDED` waits unbounded.
    handshake_ms: u32,
    /// Listener-construction budget in milliseconds. `GLOWCAP_DRIVER_WAIT_UNBOUNDED` waits unbounded.
    listener_setup_ms: u32,
    /// Application-answer budget in milliseconds. `GLOWCAP_DRIVER_WAIT_UNBOUNDED` waits unbounded.
    settle_ms: u32,
    /// Nanoseconds the runtime spins reaping its transports before it parks. Zero parks at once. A spinning runtime holds its CPU for the window. A window past `GLOWCAP_DRIVER_MAX_BUSY_POLL_NS` is refused.
    busy_poll_ns: u64,
};

// ── Event queue vocabulary ───────────────────────────────────────────────────

/// `GlowcapDriverEvent.kind`: a dial or external adoption reached an open
/// session. `operation_id` identifies the operation and `session` the handle.
pub const GLOWCAP_DRIVER_EVENT_OPENED: u32 = 0;
/// A dial or external adoption failed. `operation_id` names it and the
/// primary/secondary fields preserve its typed failure chain.
pub const GLOWCAP_DRIVER_EVENT_OPEN_FAILED: u32 = 1;
/// A listener accepted a session. `listener_id` is the id from
/// `glowcap_driver_listen` and `session` the live handle.
pub const GLOWCAP_DRIVER_EVENT_ACCEPTED: u32 = 2;
/// A session's wire closed inside the step. Clean EOF carries
/// `GLOWCAP_OK` and empty failure fields. A transport fault, truncated frame,
/// or protocol refusal carries its stable primary and consequence facts. The
/// handle stays valid until `glowcap_driver_session_release`. Its vows are
/// already broken.
pub const GLOWCAP_DRIVER_EVENT_SESSION_CLOSED: u32 = 3;
/// A vow settled with no in-process listener. `action` carries the byte-fed
/// queue's own SETTLE/FAIL shape (`GlowcapHostAction`), so a binding's
/// existing completion decoding applies unchanged.
pub const GLOWCAP_DRIVER_EVENT_COMPLETION: u32 = 4;
/// Listener construction completed and `listener_id` is active.
pub const GLOWCAP_DRIVER_EVENT_LISTENER_READY: u32 = 5;
/// Listener construction or an active listener's accept infrastructure failed.
/// `listener_id` is retired before publication and the failure fields retain
/// the primary plus first consequence and total count. Sessions and ACCEPTED
/// events already yielded by the listener remain valid.
pub const GLOWCAP_DRIVER_EVENT_LISTENER_FAILED: u32 = 6;
pub const GLOWCAP_DRIVER_ADOPT_DIALED: u32 = 0;
pub const GLOWCAP_DRIVER_ADOPT_ACCEPTED: u32 = 1;

/// One drained loop event. Unused fields are zero/null per `kind`. Borrowed
/// failure-name views and the views inside `action` stay valid until the next
/// `glowcap_driver_next_event` call on the same loop.
pub const GlowcapDriverEvent = extern struct {
    kind: u32,
    /// Stable C result for the primary failure. Zero for success events.
    primary_result: i32,
    /// Stable C result for the first consequence, when present.
    secondary_result: i32,
    /// Total consequences observed, including any beyond `secondary_name`.
    secondary_count: u32,
    /// GLOWCAP_CARRIER_PHASE_* for a carrier-owned failure, otherwise NONE.
    carrier_phase: u32,
    carrier_detail_flags: u32,
    carrier_verification_flags: u32,
    carrier_peer_alert: u32,
    carrier_engine_code: i32,
    operation_id: u64,
    listener_id: u64,
    session: ?*GlowcapHostSession,
    action: GlowcapHostAction,
    primary_name: ?[*]const u8,
    primary_name_len: usize,
    secondary_name: ?[*]const u8,
    secondary_name_len: usize,
};

/// Allocation-free projection of the driver's typed failure chain into one C
/// event. This is data for the event's deterministic recipient, not a journal.
pub const FailureProjection = struct {
    primary_result: i32,
    primary_name: []const u8,
    secondary_result: i32,
    secondary_count: u32,
    carrier_phase: u32,
    carrier_detail_flags: u32,
    carrier_verification_flags: u32,
    carrier_peer_alert: u32,
    carrier_engine_code: i32,
    secondary_name: []const u8,

    pub fn init(failure: driver.OperationFailure) FailureProjection {
        const carrier = carrier_phase.project(failure.carrier_phase, failure.carrier_detail);
        return .{
            .primary_result = driver_error.code(failure.kind()),
            .primary_name = failure.chain.primaryName(),
            .secondary_result = failure_output.secondaryResult(failure),
            .secondary_count = failure.chain.secondary_count,
            .carrier_phase = carrier.phase,
            .carrier_detail_flags = carrier.detail_flags,
            .carrier_verification_flags = carrier.verification_flags,
            .carrier_peer_alert = carrier.peer_alert,
            .carrier_engine_code = carrier.engine_code,
            .secondary_name = failure.chain.secondaryName() orelse "",
        };
    }

    pub fn project(self: FailureProjection, out: *GlowcapDriverEvent) void {
        out.primary_result = self.primary_result;
        out.secondary_result = self.secondary_result;
        out.secondary_count = self.secondary_count;
        out.carrier_phase = self.carrier_phase;
        out.carrier_detail_flags = self.carrier_detail_flags;
        out.carrier_verification_flags = self.carrier_verification_flags;
        out.carrier_peer_alert = self.carrier_peer_alert;
        out.carrier_engine_code = self.carrier_engine_code;
        out.primary_name = self.primary_name.ptr;
        out.primary_name_len = self.primary_name.len;
        out.secondary_name = self.secondary_name.ptr;
        out.secondary_name_len = self.secondary_name.len;
    }
};

// ── Loop family (implemented in loop.zig) ────────────────────────────────────

pub const glowcap_driver_take_host = loop_lifecycle.glowcap_driver_take_host;
pub const glowcap_driver_close = loop_lifecycle.glowcap_driver_close;
pub const glowcap_driver_retire = loop_lifecycle.glowcap_driver_retire;
pub const glowcap_driver_lifecycle_state = loop_lifecycle.glowcap_driver_lifecycle_state;
pub const glowcap_driver_step_wait_ms = loop_lifecycle.glowcap_driver_step_wait_ms;
pub const glowcap_driver_release = loop_lifecycle.glowcap_driver_release;
pub const glowcap_driver_add_provider = loop_opens.glowcap_driver_add_provider;
pub const glowcap_driver_has_transport = loop_opens.glowcap_driver_has_transport;
pub const glowcap_driver_dial = loop_opens.glowcap_driver_dial;
pub const glowcap_driver_adopt_external = loop_opens.glowcap_driver_adopt_external;
pub const glowcap_driver_listen = loop_listeners.glowcap_driver_listen;
pub const glowcap_driver_listener_locator = loop_listeners.glowcap_driver_listener_locator;
pub const glowcap_driver_listener_restoration_state = loop_listeners.glowcap_driver_listener_restoration_state;
pub const glowcap_driver_listener_advertise = loop_listeners.glowcap_driver_listener_advertise;
pub const glowcap_driver_listener_select = loop_listeners.glowcap_driver_listener_select;
pub const glowcap_driver_listener_close = loop_listeners.glowcap_driver_listener_close;
pub const glowcap_driver_readiness_fd = loop_drive.glowcap_driver_readiness_fd;
pub const glowcap_driver_step = loop_drive.glowcap_driver_step;
pub const glowcap_driver_detach_thread = loop_drive.glowcap_driver_detach_thread;
pub const glowcap_driver_wake = loop_drive.glowcap_driver_wake;
pub const glowcap_driver_next_event = loop_events.glowcap_driver_next_event;
pub const glowcap_driver_claim_reference_exporter = loop_sessions.glowcap_driver_claim_reference_exporter;
pub const glowcap_driver_claim_exporter_session = loop_sessions.glowcap_driver_claim_exporter_session;
pub const glowcap_driver_session_close = loop_sessions.glowcap_driver_session_close;
pub const glowcap_driver_session_lifecycle_state = loop_sessions.glowcap_driver_session_lifecycle_state;
pub const glowcap_driver_session_serve = loop_sessions.glowcap_driver_session_serve;
pub const glowcap_driver_session_release = loop_sessions.glowcap_driver_session_release;
pub const glowcap_driver_last_error = loop.glowcap_driver_last_error;
pub const glowcap_driver_clear_last_error = loop.glowcap_driver_clear_last_error;

comptime {
    // Force only the loop family's `export fn`s into this archive. Host
    // implementation imports are not export roots.
    _ = loop;
}
