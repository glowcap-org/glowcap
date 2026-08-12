//! `libpancake_driver` (ADR-0112): the driver archive. It exports only the
//! `pancake_driver_*` loop family that owns the transport-to-host
//! choreography every binding used to re-implement: park on one readiness
//! descriptor, step, drain one event queue.
//!
//! A native-loop consumer composes `libpancake_host`, `libpancake_driver`, and
//! the transport archives it selects. Symbol families stay disjoint.
//!
//! The loop family lives in `loop.zig`; this root owns the public C types,
//! the family re-exports the header generator and binding mirrors reflect over.

const std = @import("std");

const shared = @import("c_abi_shared");
const c_abi_host = @import("c_abi_host");
const driver = @import("driver");

const loop = @import("loop.zig");

/// The annotated export inventory for the `pancake_driver_*` family
/// (the `pancake_host_*` half keeps its own inventory in `c_abi_host`).
pub const symbols = @import("symbols.zig");

// ── Shared value vocabulary (by layout, from the sibling roots) ──────────────

pub const PancakeContext = shared.PancakeContext;
pub const PancakeMultiplexedTransport = shared.PancakeMultiplexedTransport;
pub const PancakeMultiplexedReadyEvent = shared.PancakeMultiplexedReadyEvent;
pub const PancakeLocatorHintView = shared.PancakeLocatorHintView;
pub const PancakeLocatorView = shared.PancakeLocatorView;
pub const PancakeStreamTransport = shared.PancakeStreamTransport;
pub const PancakeTransportProfile = shared.PancakeTransportProfile;
pub const PancakeTransportProviderEntry = shared.PancakeTransportProviderEntry;
pub const PancakeTransportProvider = shared.PancakeTransportProvider;
pub const PancakeStreamStartConnectFn = shared.transport_provider.PancakeStreamStartConnectFn;
pub const PancakeStreamFinishConnectFn = shared.transport_provider.PancakeStreamFinishConnectFn;
pub const PancakeStreamCancelConnectFn = shared.transport_provider.PancakeStreamCancelConnectFn;
pub const PancakeStreamListenFn = shared.transport_provider.PancakeStreamListenFn;
pub const PancakeStreamListenerWaitFn = shared.transport_provider.PancakeStreamListenerWaitFn;
pub const PancakeStreamListenerReadinessFdFn = shared.transport_provider.PancakeStreamListenerReadinessFdFn;
pub const PancakeLocatorSinkFn = shared.PancakeLocatorSinkFn;
pub const PancakeTransportListenerLocatorFn = shared.transport_provider.PancakeTransportListenerLocatorFn;
pub const PancakeTransportListenerAdvertiseFn = shared.transport_provider.PancakeTransportListenerAdvertiseFn;
pub const PancakeStreamAcceptFn = shared.transport_provider.PancakeStreamAcceptFn;
pub const PancakeStreamListenerCloseFn = shared.transport_provider.PancakeStreamListenerCloseFn;
pub const PancakeStreamReadFn = shared.transport_provider.PancakeStreamReadFn;
pub const PancakeStreamWriteAllFn = shared.transport_provider.PancakeStreamWriteAllFn;
pub const PancakeStreamConnCloseFn = shared.transport_provider.PancakeStreamConnCloseFn;
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
pub const PancakeMultiplexedStartListenFn = shared.multiplexed_transport.PancakeMultiplexedStartListenFn;
pub const PancakeMultiplexedFinishAcceptFn = shared.multiplexed_transport.PancakeMultiplexedFinishAcceptFn;
pub const PancakeMultiplexedStopListenFn = shared.multiplexed_transport.PancakeMultiplexedStopListenFn;
pub const PancakeMultiplexedSubjectFn = shared.multiplexed_transport.PancakeMultiplexedSubjectFn;
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
pub const PancakeHost = c_abi_host.PancakeHost;
pub const PancakeHostSession = c_abi_host.PancakeHostSession;
pub const PancakeHostAction = c_abi_host.PancakeHostAction;

// ── Handles ──────────────────────────────────────────────────────────────────

/// A stepping CapTP loop over one multi-session host: the host, its
/// transports, its listeners, and one readiness descriptor. Created with
/// `pancake_driver_take_host`; released with `pancake_driver_release`. One thread
/// drives one loop; `pancake_driver_wake` is the one cross-thread verb.
pub const PancakeDriverLoop = opaque {};

/// Current layout version for `PancakeDriverOptions`.
pub const PANCAKE_DRIVER_OPTIONS_ABI_VERSION: u32 = 1;
/// Largest positive wait budget representable by `driver.Budget`.
pub const PANCAKE_DRIVER_MAX_WAIT_MS: u32 = std.math.maxInt(i32);
/// Default bytes retained for each stream direction or multiplexed read staging.
pub const PANCAKE_DRIVER_DEFAULT_WIRE_BUFFER_BYTES: usize = driver.default_wire_buffer_bytes;
/// Default maximum transport connects and CapTP handshakes admitted at once.
pub const PANCAKE_DRIVER_DEFAULT_MAX_PENDING_OPENS: usize = driver.default_max_pending_opens;
/// Default CapTP handshake progress budget in milliseconds.
pub const PANCAKE_DRIVER_DEFAULT_HANDSHAKE_MS: u32 = @intCast(c_abi_host.PANCAKE_HANDSHAKE_TIMEOUT_MS);
/// Default application-answer progress budget in milliseconds.
pub const PANCAKE_DRIVER_DEFAULT_SETTLE_MS: u32 = @intCast(c_abi_host.PANCAKE_HANDSHAKE_TIMEOUT_MS);

/// Construction policy for the native driver face. The wait budgets bound
/// handshake and application-answer progress; `wire_buffer_bytes` is retained
/// once for each stream direction, or once for multiplexed read staging, per live
/// session. `max_pending_opens` bounds pre-open session and wire memory across
/// every transport route. The layout fields must identify this record; every
/// policy field must be positive.
pub const PancakeDriverOptions = extern struct {
    abi_version: u32,
    struct_size: usize,
    wire_buffer_bytes: usize,
    max_pending_opens: usize,
    handshake_ms: u32,
    settle_ms: u32,
};

// ── Event queue vocabulary ───────────────────────────────────────────────────

/// `PancakeDriverEvent.kind`: a ticketed dial or external adoption reached an
/// open session; `ticket` identifies the operation and `session` the handle.
pub const PANCAKE_DRIVER_EVENT_OPENED: u32 = 0;
/// A ticketed dial or external adoption failed; `ticket` names it and
/// `message` says why.
pub const PANCAKE_DRIVER_EVENT_OPEN_FAILED: u32 = 1;
/// A listener accepted a session; `ticket` is the listener id from
/// `pancake_driver_listen` and `session` the live handle.
pub const PANCAKE_DRIVER_EVENT_ACCEPTED: u32 = 2;
/// A session's wire closed inside the step (EOF, fault, or protocol
/// refusal). The handle stays valid until `pancake_driver_session_release`;
/// its vows are already broken.
pub const PANCAKE_DRIVER_EVENT_SESSION_CLOSED: u32 = 3;
/// A vow settled with no in-process listener; `action` carries the byte-fed
/// queue's own SETTLE/FAIL shape (`PancakeHostAction`), so a binding's
/// existing completion decoding applies unchanged.
pub const PANCAKE_DRIVER_EVENT_COMPLETION: u32 = 4;
pub const PANCAKE_DRIVER_ADOPT_DIALED: u32 = 0;
pub const PANCAKE_DRIVER_ADOPT_ACCEPTED: u32 = 1;

/// One drained loop event. Unused fields are zero/null per `kind`; borrowed
/// views (`message`, the views inside `action`) stay valid until the next
/// `pancake_driver_next_event` call on the same loop.
pub const PancakeDriverEvent = extern struct {
    kind: u32,
    ticket: u64,
    session: ?*PancakeHostSession,
    action: PancakeHostAction,
    message: ?[*]const u8,
    message_len: usize,
};

// ── Loop family (implemented in loop.zig) ────────────────────────────────────

pub const pancake_driver_take_host = loop.pancake_driver_take_host;
pub const pancake_driver_release = loop.pancake_driver_release;
pub const pancake_driver_add_provider = loop.pancake_driver_add_provider;
pub const pancake_driver_has_transport = loop.pancake_driver_has_transport;
pub const pancake_driver_dial = loop.pancake_driver_dial;
pub const pancake_driver_adopt_external = loop.pancake_driver_adopt_external;
pub const pancake_driver_listen = loop.pancake_driver_listen;
pub const pancake_driver_listener_locator = loop.pancake_driver_listener_locator;
pub const pancake_driver_listener_advertise = loop.pancake_driver_listener_advertise;
pub const pancake_driver_listener_select = loop.pancake_driver_listener_select;
pub const pancake_driver_listener_close = loop.pancake_driver_listener_close;
pub const pancake_driver_readiness_fd = loop.pancake_driver_readiness_fd;
pub const pancake_driver_step = loop.pancake_driver_step;
pub const pancake_driver_detach_thread = loop.pancake_driver_detach_thread;
pub const pancake_driver_wake = loop.pancake_driver_wake;
pub const pancake_driver_next_event = loop.pancake_driver_next_event;
pub const pancake_driver_session_release = loop.pancake_driver_session_release;
pub const pancake_driver_last_error = loop.pancake_driver_last_error;
pub const pancake_driver_clear_last_error = loop.pancake_driver_clear_last_error;

comptime {
    // Force only the loop family's `export fn`s into this archive. Host
    // implementation imports are deliberately not export roots.
    _ = loop;
}
