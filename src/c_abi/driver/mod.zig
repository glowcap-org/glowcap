//! `libpancake_driver` (ADR-0112): the driver archive. It exports only the
//! `pancake_driver_*` loop family that owns the transport-to-host
//! choreography every binding used to re-implement: park on one readiness
//! descriptor, step, drain one event queue.
//!
//! A native-loop consumer composes `libpancake_host`, `libpancake_driver`, and
//! the transport archives it selects. Symbol families stay disjoint.
//!
//! The private `loop.zig` state aggregate and `loop/` transition owners compose
//! here; this root owns the public C types and exact symbol index the header
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

/// The annotated export inventory for the `pancake_driver_*` family
/// (the `pancake_host_*` half keeps its own inventory in `c_abi_host`).
pub const symbols = @import("symbols.zig");

pub const contract_layouts = [_]shared.archive_contract.Layout{
    shared.archive_contract.layout("PANCAKE_DRIVER_OPTIONS", PancakeDriverOptions),
    shared.archive_contract.layout("PANCAKE_DRIVER_FAILURE", PancakeDriverFailure),
    shared.archive_contract.layout("PANCAKE_DRIVER_EVENT", PancakeDriverEvent),
};

/// Exact reflected callable/layout identity for the native driver archive.
pub const PANCAKE_DRIVER_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint(
    "driver",
    @This(),
    .{ shared.contract_layouts, c_abi_host.contract_layouts, contract_layouts },
);

pub export fn pancake_driver_archive_fingerprint() u64 {
    return PANCAKE_DRIVER_ARCHIVE_FINGERPRINT;
}

// ── Shared value vocabulary (by layout, from the sibling roots) ──────────────

pub const PancakeContext = shared.PancakeContext;
pub const PancakeMultiplexedTransport = shared.PancakeMultiplexedTransport;
pub const PancakeMultiplexedReadyEvent = shared.PancakeMultiplexedReadyEvent;
pub const PancakeLocatorHintView = shared.PancakeLocatorHintView;
pub const PancakeLocatorView = shared.PancakeLocatorView;
pub const PancakeStreamTransport = shared.PancakeStreamTransport;
pub const PancakeProviderFailure = shared.PancakeProviderFailure;
pub const PancakeTransportProfile = shared.PancakeTransportProfile;
pub const PancakeTransportOperationOptions = shared.PancakeTransportOperationOptions;
pub const PancakeTransportProviderEntry = shared.PancakeTransportProviderEntry;
pub const PancakeTransportProvider = shared.PancakeTransportProvider;
pub const PancakeStreamStartConnectFn = shared.transport_provider.PancakeStreamStartConnectFn;
pub const PancakeStreamFinishConnectFn = shared.transport_provider.PancakeStreamFinishConnectFn;
pub const PancakeStreamCancelConnectFn = shared.transport_provider.PancakeStreamCancelConnectFn;
pub const PancakeListenResult = shared.transport_provider.PancakeListenResult;
pub const PancakeStreamListenFn = shared.transport_provider.PancakeStreamListenFn;
pub const PancakeStreamFinishListenFn = shared.transport_provider.PancakeStreamFinishListenFn;
pub const PancakeStreamCancelListenFn = shared.transport_provider.PancakeStreamCancelListenFn;
pub const PANCAKE_LISTEN_READY = shared.transport_provider.PANCAKE_LISTEN_READY;
pub const PANCAKE_LISTEN_PENDING = shared.transport_provider.PANCAKE_LISTEN_PENDING;
pub const PancakeStreamListenerWaitFn = shared.transport_provider.PancakeStreamListenerWaitFn;
pub const PancakeStreamListenerReadinessFdFn = shared.transport_provider.PancakeStreamListenerReadinessFdFn;
pub const PancakeLocatorSinkFn = shared.PancakeLocatorSinkFn;
pub const PancakeTransportListenerLocatorFn = shared.transport_provider.PancakeTransportListenerLocatorFn;
pub const PancakeTransportListenerAdvertiseFn = shared.transport_provider.PancakeTransportListenerAdvertiseFn;
pub const PancakeTransportListenerRestorationStateFn = shared.transport_provider.PancakeTransportListenerRestorationStateFn;
pub const PancakeStreamAcceptFn = shared.transport_provider.PancakeStreamAcceptFn;
pub const PancakeStreamListenerCloseFn = shared.transport_provider.PancakeStreamListenerCloseFn;
pub const PancakeStreamReadFn = shared.transport_provider.PancakeStreamReadFn;
pub const PancakeStreamWriteAllFn = shared.transport_provider.PancakeStreamWriteAllFn;
pub const PancakeStreamConnCloseFn = shared.transport_provider.PancakeStreamConnCloseFn;
pub const PancakeStreamConnTakeFailureFn = shared.transport_provider.PancakeStreamConnTakeFailureFn;
pub const PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION = shared.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION;
pub const PANCAKE_TRANSPORT_PROFILE_ABI_VERSION = shared.transport_provider.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION;
pub const PANCAKE_STREAM_TRANSPORT_ABI_VERSION = shared.transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION;
pub const PANCAKE_TRANSPORT_EXEC_STREAM = shared.transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM;
pub const PANCAKE_TRANSPORT_EXEC_MULTIPLEXED = shared.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED;
pub const PANCAKE_LOCATOR_VIEW_ABI_VERSION = shared.PANCAKE_LOCATOR_VIEW_ABI_VERSION;
pub const PANCAKE_HINT_STRING = shared.PANCAKE_HINT_STRING;
pub const PANCAKE_HINT_BYTES = shared.PANCAKE_HINT_BYTES;
pub const PANCAKE_HINT_BOOLEAN = shared.PANCAKE_HINT_BOOLEAN;
pub const PANCAKE_HINT_INTEGER = shared.PANCAKE_HINT_INTEGER;
pub const PANCAKE_HINTS_MAP = shared.PANCAKE_HINTS_MAP;
pub const PANCAKE_HINTS_BOOLEAN_FALSE = shared.PANCAKE_HINTS_BOOLEAN_FALSE;
pub const PancakeMultiplexedReadinessFdFn = shared.multiplexed_transport.PancakeMultiplexedReadinessFdFn;
pub const PancakeMultiplexedDrainReadyFn = shared.multiplexed_transport.PancakeMultiplexedDrainReadyFn;
pub const PancakeMultiplexedStartConnectFn = shared.multiplexed_transport.PancakeMultiplexedStartConnectFn;
pub const PancakeMultiplexedFinishConnectFn = shared.multiplexed_transport.PancakeMultiplexedFinishConnectFn;
pub const PancakeMultiplexedClaimExternalFn = shared.multiplexed_transport.PancakeMultiplexedClaimExternalFn;
pub const PancakeMultiplexedListenFn = shared.multiplexed_transport.PancakeMultiplexedListenFn;
pub const PancakeMultiplexedFinishListenFn = shared.multiplexed_transport.PancakeMultiplexedFinishListenFn;
pub const PancakeMultiplexedFinishAcceptFn = shared.multiplexed_transport.PancakeMultiplexedFinishAcceptFn;
pub const PancakeMultiplexedStopListenFn = shared.multiplexed_transport.PancakeMultiplexedStopListenFn;
pub const PancakeMultiplexedSubjectFn = shared.multiplexed_transport.PancakeMultiplexedSubjectFn;
pub const PancakeMultiplexedConnTakeFailureFn = shared.multiplexed_transport.PancakeMultiplexedConnTakeFailureFn;
pub const PancakeMultiplexedTryReadFn = shared.multiplexed_transport.PancakeMultiplexedTryReadFn;
pub const PancakeMultiplexedTryWriteFn = shared.multiplexed_transport.PancakeMultiplexedTryWriteFn;
pub const PancakeMultiplexedConnRemoteKeyFn = shared.multiplexed_transport.PancakeMultiplexedConnRemoteKeyFn;
pub const PANCAKE_MULTIPLEXED_WOULD_BLOCK = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
pub const PANCAKE_MULTIPLEXED_EV_READABLE = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_READABLE;
pub const PANCAKE_MULTIPLEXED_EV_WRITABLE = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_WRITABLE;
pub const PANCAKE_MULTIPLEXED_EV_CLOSED = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CLOSED;
pub const PANCAKE_MULTIPLEXED_EV_ACCEPT = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_ACCEPT;
pub const PANCAKE_MULTIPLEXED_EV_CONNECT = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CONNECT;
pub const PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION = shared.multiplexed_transport.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION;
pub const PANCAKE_DESIGNATOR_SCHEME_ADDRESS = shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_ADDRESS;
pub const PANCAKE_DESIGNATOR_SCHEME_KEY = shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY;
pub const PANCAKE_SEALED_CHANNEL_NONE = shared.transport_provider.PANCAKE_SEALED_CHANNEL_NONE;
pub const PANCAKE_SEALED_CHANNEL_NOISE_XK = shared.transport_provider.PANCAKE_SEALED_CHANNEL_NOISE_XK;
pub const PANCAKE_WIRE_FRAMING_BYTE_STREAM = shared.transport_provider.PANCAKE_WIRE_FRAMING_BYTE_STREAM;
pub const PANCAKE_WIRE_FRAMING_MESSAGE = shared.transport_provider.PANCAKE_WIRE_FRAMING_MESSAGE;
pub const PANCAKE_CARRIER_PHASE_NONE = shared.transport_provider.PANCAKE_CARRIER_PHASE_NONE;
pub const PANCAKE_CARRIER_PHASE_RESOLVE = shared.transport_provider.PANCAKE_CARRIER_PHASE_RESOLVE;
pub const PANCAKE_CARRIER_PHASE_CONNECT = shared.transport_provider.PANCAKE_CARRIER_PHASE_CONNECT;
pub const PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE = shared.transport_provider.PANCAKE_CARRIER_PHASE_SECURE_HANDSHAKE;
pub const PANCAKE_CARRIER_PHASE_WEBSOCKET_UPGRADE = shared.transport_provider.PANCAKE_CARRIER_PHASE_WEBSOCKET_UPGRADE;
pub const PANCAKE_CARRIER_PHASE_REGISTRATION = shared.transport_provider.PANCAKE_CARRIER_PHASE_REGISTRATION;
pub const PANCAKE_CARRIER_PHASE_RECEIVE = shared.transport_provider.PANCAKE_CARRIER_PHASE_RECEIVE;
pub const PANCAKE_CARRIER_PHASE_TRANSMIT = shared.transport_provider.PANCAKE_CARRIER_PHASE_TRANSMIT;
pub const PANCAKE_CARRIER_PHASE_SHUTDOWN = shared.transport_provider.PANCAKE_CARRIER_PHASE_SHUTDOWN;
pub const PANCAKE_CARRIER_DETAIL_PEER_ALERT = shared.transport_provider.PANCAKE_CARRIER_DETAIL_PEER_ALERT;
pub const PANCAKE_CARRIER_DETAIL_ENGINE_CODE = shared.transport_provider.PANCAKE_CARRIER_DETAIL_ENGINE_CODE;
pub const PancakeHost = c_abi_host.PancakeHost;
pub const PancakeHostSession = c_abi_host.PancakeHostSession;
pub const PancakeHostAction = c_abi_host.PancakeHostAction;
pub const PancakeReference = shared.PancakeReference;
pub const PancakeCloseOptions = shared.PancakeCloseOptions;
pub const PANCAKE_CLOSE_OPTIONS_ABI_VERSION = shared.PANCAKE_CLOSE_OPTIONS_ABI_VERSION;
pub const PANCAKE_CLOSE_MAX_GRACE_MS = shared.PANCAKE_CLOSE_MAX_GRACE_MS;
pub const PANCAKE_CLOSE_GRACE_UNSPECIFIED = shared.PANCAKE_CLOSE_GRACE_UNSPECIFIED;
pub const PANCAKE_CLOSE_GRACE_FINITE = shared.PANCAKE_CLOSE_GRACE_FINITE;
pub const PANCAKE_CLOSE_GRACE_UNBOUNDED = shared.PANCAKE_CLOSE_GRACE_UNBOUNDED;
pub const PANCAKE_PENDING_CANCEL = shared.PANCAKE_PENDING_CANCEL;
pub const PANCAKE_PENDING_FINISH = shared.PANCAKE_PENDING_FINISH;
pub const PANCAKE_LIFECYCLE_ACTIVE = c_abi_host.PANCAKE_LIFECYCLE_ACTIVE;
pub const PANCAKE_LIFECYCLE_FINISHING = c_abi_host.PANCAKE_LIFECYCLE_FINISHING;
pub const PANCAKE_LIFECYCLE_TERMINATING = c_abi_host.PANCAKE_LIFECYCLE_TERMINATING;
pub const PANCAKE_LIFECYCLE_CLOSED = c_abi_host.PANCAKE_LIFECYCLE_CLOSED;

// ── Handles ──────────────────────────────────────────────────────────────────

/// A stepping CapTP loop over one multi-session host: the host, its
/// transports, its listeners, and one readiness descriptor. Created with
/// `pancake_driver_take_host`; released with `pancake_driver_release`. One thread
/// drives one loop; `pancake_driver_wake` is the one cross-thread verb.
pub const PancakeDriverLoop = opaque {};
pub const PANCAKE_DRIVER_FAILURE_ABI_VERSION = failure_output.abi_version;
pub const PancakeDriverFailure = failure_output.PancakeDriverFailure;

/// Current layout version for `PancakeDriverOptions`.
pub const PANCAKE_DRIVER_OPTIONS_ABI_VERSION: u32 = 1;
/// Largest positive wait budget representable by `driver.Budget`.
pub const PANCAKE_DRIVER_MAX_WAIT_MS: u32 = std.math.maxInt(i32);
/// Default bytes retained for each stream direction or multiplexed read staging.
pub const PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES: usize = driver.default_wire_buffer_bytes;
/// Default maximum transport connects and CapTP handshakes admitted at once.
pub const PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS: usize = driver.default_max_pending_opens;
/// Default CapTP handshake progress budget in milliseconds.
pub const PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS: u32 = @intCast(driver.default_handshake_timeout_ms);
/// Default listener-construction progress budget in milliseconds.
pub const PANCAKE_DRIVER_DEFAULT_LISTENER_SETUP_MS: u32 = @intCast(driver.default_listener_setup_ms);
/// Default application-answer progress budget in milliseconds.
pub const PANCAKE_DRIVER_DEFAULT_SETTLE_MS: u32 = @intCast(driver.default_settle_ms);
/// Construction policy for the native driver face. A zero wait budget is the
/// explicit unbounded form; nonzero values bound progress in milliseconds.
/// `wire_buffer_bytes` is retained
/// once for each stream direction, or once for multiplexed read staging, per live
/// session. `max_pending_opens` bounds pre-open session and wire memory across
/// every transport route. The layout fields must identify this record; every
/// buffer and admission limits must be positive.
pub const PancakeDriverOptions = extern struct {
    abi_version: u32,
    struct_size: usize,
    wire_buffer_bytes: usize,
    max_pending_opens: usize,
    /// Handshake progress budget in milliseconds; zero waits unbounded.
    handshake_ms: u32,
    /// Listener-construction budget in milliseconds; zero waits unbounded.
    listener_setup_ms: u32,
    /// Application-answer budget in milliseconds; zero waits unbounded.
    settle_ms: u32,
};

// ── Event queue vocabulary ───────────────────────────────────────────────────

/// `PancakeDriverEvent.kind`: a dial or external adoption reached an open
/// session; `operation_id` identifies the operation and `session` the handle.
pub const PANCAKE_DRIVER_EVENT_OPENED: u32 = 0;
/// A dial or external adoption failed; `operation_id` names it and the
/// primary/secondary fields preserve its typed failure chain.
pub const PANCAKE_DRIVER_EVENT_OPEN_FAILED: u32 = 1;
/// A listener accepted a session; `listener_id` is the id from
/// `pancake_driver_listen` and `session` the live handle.
pub const PANCAKE_DRIVER_EVENT_ACCEPTED: u32 = 2;
/// A session's wire closed inside the step. Clean EOF carries
/// `PANCAKE_OK` and empty failure fields; a transport fault, truncated frame,
/// or protocol refusal carries its stable primary and consequence facts. The
/// handle stays valid until `pancake_driver_session_release`; its vows are
/// already broken.
pub const PANCAKE_DRIVER_EVENT_SESSION_CLOSED: u32 = 3;
/// A vow settled with no in-process listener; `action` carries the byte-fed
/// queue's own SETTLE/FAIL shape (`PancakeHostAction`), so a binding's
/// existing completion decoding applies unchanged.
pub const PANCAKE_DRIVER_EVENT_COMPLETION: u32 = 4;
/// Listener construction completed and `listener_id` is active.
pub const PANCAKE_DRIVER_EVENT_LISTENER_READY: u32 = 5;
/// Listener construction or an active listener's accept infrastructure failed;
/// `listener_id` is retired before publication and the failure fields retain
/// the primary plus first consequence and total count. Sessions and ACCEPTED
/// events already yielded by the listener remain valid.
pub const PANCAKE_DRIVER_EVENT_LISTENER_FAILED: u32 = 6;
pub const PANCAKE_DRIVER_ADOPT_DIALED: u32 = 0;
pub const PANCAKE_DRIVER_ADOPT_ACCEPTED: u32 = 1;

/// One drained loop event. Unused fields are zero/null per `kind`; borrowed
/// failure-name views and the views inside `action` stay valid until the next
/// `pancake_driver_next_event` call on the same loop.
pub const PancakeDriverEvent = extern struct {
    kind: u32,
    /// Stable C result for the primary failure; zero for success events.
    primary_result: i32,
    /// Stable C result for the first consequence, when present.
    secondary_result: i32,
    /// Total consequences observed, including any beyond `secondary_name`.
    secondary_count: u32,
    /// PANCAKE_CARRIER_PHASE_* for a carrier-owned failure, otherwise NONE.
    carrier_phase: u32,
    carrier_detail_flags: u32,
    carrier_verification_flags: u32,
    carrier_peer_alert: u32,
    carrier_engine_code: i32,
    operation_id: u64,
    listener_id: u64,
    session: ?*PancakeHostSession,
    action: PancakeHostAction,
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
            .primary_result = driver_error.code(failure.kind),
            .primary_name = failure.primaryName(),
            .secondary_result = if (failure.secondary_cause) |cause|
                if (failure.secondary_kind) |kind| driver_error.code(kind) else driver_error.fromError(cause)
            else
                shared.PANCAKE_OK,
            .secondary_count = failure.secondary_count,
            .carrier_phase = carrier.phase,
            .carrier_detail_flags = carrier.detail_flags,
            .carrier_verification_flags = carrier.verification_flags,
            .carrier_peer_alert = carrier.peer_alert,
            .carrier_engine_code = carrier.engine_code,
            .secondary_name = failure.secondaryName() orelse "",
        };
    }

    pub fn project(self: FailureProjection, out: *PancakeDriverEvent) void {
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

pub const pancake_driver_take_host = loop_lifecycle.pancake_driver_take_host;
pub const pancake_driver_close = loop_lifecycle.pancake_driver_close;
pub const pancake_driver_retire = loop_lifecycle.pancake_driver_retire;
pub const pancake_driver_lifecycle_state = loop_lifecycle.pancake_driver_lifecycle_state;
pub const pancake_driver_step_wait_ms = loop_lifecycle.pancake_driver_step_wait_ms;
pub const pancake_driver_release = loop_lifecycle.pancake_driver_release;
pub const pancake_driver_add_provider = loop_opens.pancake_driver_add_provider;
pub const pancake_driver_has_transport = loop_opens.pancake_driver_has_transport;
pub const pancake_driver_dial = loop_opens.pancake_driver_dial;
pub const pancake_driver_adopt_external = loop_opens.pancake_driver_adopt_external;
pub const pancake_driver_listen = loop_listeners.pancake_driver_listen;
pub const pancake_driver_listener_locator = loop_listeners.pancake_driver_listener_locator;
pub const pancake_driver_listener_restoration_state = loop_listeners.pancake_driver_listener_restoration_state;
pub const pancake_driver_listener_advertise = loop_listeners.pancake_driver_listener_advertise;
pub const pancake_driver_listener_select = loop_listeners.pancake_driver_listener_select;
pub const pancake_driver_listener_close = loop_listeners.pancake_driver_listener_close;
pub const pancake_driver_readiness_fd = loop_drive.pancake_driver_readiness_fd;
pub const pancake_driver_step = loop_drive.pancake_driver_step;
pub const pancake_driver_detach_thread = loop_drive.pancake_driver_detach_thread;
pub const pancake_driver_wake = loop_drive.pancake_driver_wake;
pub const pancake_driver_next_event = loop_events.pancake_driver_next_event;
pub const pancake_driver_claim_reference_exporter = loop_sessions.pancake_driver_claim_reference_exporter;
pub const pancake_driver_session_close = loop_sessions.pancake_driver_session_close;
pub const pancake_driver_session_lifecycle_state = loop_sessions.pancake_driver_session_lifecycle_state;
pub const pancake_driver_session_serve = loop_sessions.pancake_driver_session_serve;
pub const pancake_driver_session_release = loop_sessions.pancake_driver_session_release;
pub const pancake_driver_last_error = loop.pancake_driver_last_error;
pub const pancake_driver_clear_last_error = loop.pancake_driver_clear_last_error;

comptime {
    // Force only the loop family's `export fn`s into this archive. Host
    // implementation imports are deliberately not export roots.
    _ = loop;
}
