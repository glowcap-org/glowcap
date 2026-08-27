//! The owning host face (ADR-0090): a blocking, poll-multiplexed embedding of
//! the sans-io `driver_core.Host`, the native sibling of the byte-fed pump
//! every binding runs on its own event loop.
//!
//! `driver.HostRuntime` owns the composition — the core Host, one transport
//! wire per live session, and the pump — and `session.zig`'s owning
//! `Session`/`Server` are views over it. Every blocking wait runs one loop:
//! drain the core's action queue (write flushes, answer redeem dials, draw
//! gift-id entropy), wait for any live wire to become readable under the
//! caller's `Budget`, feed those outer-framed bytes through `Host.feedBytes`,
//! and repeat until the wait's capture fires. Because the wait spans every
//! live wire, a sibling session's inbound (a deposit arriving while this
//! session waits on a withdraw) is served inside the same wait, which is what
//! makes same-Host gifter and exporter roles work on one fiber with no thread.
//!
//! The wires are `net.Connection`s used through their byte-stream face only —
//! raw reads off `conn.r` into the core's outer framer, and
//! `takeOutbound` frames wrapped onto `conn.w`; the parse-into-peer
//! half (`pump`, the spill) stays the borrowing tier's vocabulary. Multiplexed
//! blocking waits need readiness. A stream netlayer supplies one descriptor
//! per connection, while a `MultiplexedResident` supplies one descriptor for
//! its runtime and routes drained readiness by stable connection id. A
//! transport that can do neither is refused at open
//! (`Error.TransportNotPollable`).

const std = @import("std");

const engine = @import("engine");
const net = @import("net");
const driver_core = @import("driver_core");

pub const default_wire_buffer_bytes: usize = 16 << 10;
pub const default_max_pending_opens: usize = 256;
pub const default_listener_setup_ms: i64 = 10_000;
pub const default_settle_ms: i64 = 10_000;
const settle_mailbox = @import("settle_mailbox.zig");
const runtime_admission = @import("host_runtime/admission.zig");
const runtime_actions = @import("host_runtime/actions.zig");
const runtime_capabilities = @import("host_runtime/capabilities.zig");
const runtime_carrier = @import("host_runtime/carrier.zig");
const runtime_connections = @import("host_runtime/connections.zig");
const runtime_contract = @import("host_runtime/contract.zig");
const runtime_failures = @import("host_runtime/failures.zig");
const runtime_listener_setup = @import("host_runtime/listener_setup.zig");
const runtime_listeners = @import("host_runtime/listeners.zig");
const runtime_opens = @import("host_runtime/opens.zig");
const runtime_pump = @import("host_runtime/pump.zig");
const runtime_readiness = @import("host_runtime/readiness.zig");
const runtime_resident_pump = @import("host_runtime/resident_pump.zig");
const runtime_shutdown = @import("host_runtime/shutdown.zig");
const lifecycle = @import("host_runtime/lifecycle.zig");
const provider_package = @import("host_runtime/provider_package.zig");
const runtime_providers = @import("host_runtime/providers.zig");
const pending_state = @import("host_runtime/pending.zig");
const resident_state = @import("host_runtime/resident.zig");
const runtime_sessions = @import("host_runtime/sessions.zig");
const runtime_step = @import("host_runtime/step.zig");
const wire_state = @import("host_runtime/wire.zig");

const Error = driver_core.Error;
const OperationFailure = @import("operation_failure.zig").OperationFailure;
const Contract = runtime_contract.Vocabulary(
    default_wire_buffer_bytes,
    default_max_pending_opens,
    default_listener_setup_ms,
);

/// The owning face over one `driver_core.Host`: the core, the netlayer slice
/// it dials through, and one wire per live session. One thread drives one
/// `HostRuntime` and its core `Host`; every blocking verb on a view pumps through
/// here.
pub const HostRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The sans-io host, behind one stable pointer. `init` allocates it and
    /// `deinit` frees it, so this face stays the owner; the pointer shape is
    /// what lets an embedding owner hold the core elsewhere (ADR-0112).
    core: *driver_core.Host,
    /// One provider registry for dial and listen dispatch. Entries carry the
    /// Host-owned canonical symbol and point at either a stream vtable copy or
    /// a multiplexed-resident index. Concrete provider contexts remain borrowed
    /// and must outlive the HostRuntime; selection itself has no second authority.
    providers: std.ArrayListUnmanaged(Provider) = .empty,
    /// Installed provider packages and their configuration/lifetime owner.
    /// Package overlap and idempotency are Runtime composition policy; an ABI
    /// adapter supplies only the opaque comparison and release effects.
    provider_packages: std.ArrayListUnmanaged(InstalledProviderPackage) = .empty,
    /// Canonical transport profiles with a listener pending or active. Keys
    /// borrow the provider registry, which outlives this map. The Runtime owns
    /// occupancy; adapter listener ids are only handles onto that authority.
    listener_profiles: std.StringHashMapUnmanaged(void) = .{},
    /// Activated listeners owned by this Runtime, keyed by the observer tag
    /// their accepted sessions report. Keeping the transport handles here
    /// makes Runtime close, readiness service, and accept admission driver
    /// facts instead of adapter choreography.
    active_listeners: std.AutoHashMapUnmanaged(u64, ActiveListener) = .empty,
    opts: Options,
    wires: std.AutoHashMapUnmanaged(engine.PeerHandle, *Wire) = .{},
    /// Wires whose transport is not yet closed. Closed wire rows remain in
    /// `wires` until explicit session release, so close completion cannot use
    /// map cardinality without conflating shutdown with memory lifetime.
    open_wire_count: usize = 0,
    /// Carriers whose session authority has already been consumed. The wire
    /// allocation itself becomes the tombstone, avoiding allocation on
    /// rollback/release and allowing readiness-backed close to finish later.
    retiring_wires: ?*Wire = null,
    /// Application-visible owning session handles. Runtime retirement keeps
    /// their wires and Host active, then begins cancel close when the final
    /// handle releases. Internal redeem wires do not extend this ownership
    /// barrier on their own.
    claimed_session_handles: usize = 0,
    /// Listener admission is sealed while claimed sessions retain this
    /// Runtime. Distinct from Host finish: sessions remain fully active.
    retiring: bool = false,
    /// Callback-time retirement seals admission immediately; listener I/O and
    /// pending setup cancellation wait for the enclosing step to unwind.
    retirement_effects_pending: bool = false,
    /// A callback-time close has already sealed core admission; listener and
    /// transport effects run when the enclosing driver step regains control.
    close_effects_pending: bool = false,
    /// Session wrappers dropped from inside a behavior callback transfer their
    /// release request here. The wrappers themselves carry the intrusive
    /// nodes, so this rare path allocates nothing and keeps every runtime lease
    /// alive until the outermost driver call reaches quiescence.
    deferred_session_releases: ?*DeferredSessionRelease = null,
    draining_session_releases: bool = false,
    /// Runtime observers run inside the pump, after core callbacks have
    /// unwound but before the pump may stop borrowing its current rows. An
    /// owning Session may transfer cleanup through `deferSessionRelease`;
    /// every direct Runtime reentry remains refused until the observer returns.
    observer_callback_depth: usize = 0,
    /// A failure crossed a Runtime callback or post-commit boundary that could
    /// not return it directly. Detection may happen in an ABI adapter or in
    /// Runtime cleanup, but terminality is Runtime policy and every later
    /// application operation observes this one sticky concrete cause.
    terminal_failure: ?OperationFailure = null,
    /// The multiplexed runtimes this host dials and accepts through (ADR-0112),
    /// beside the stream netlayers above. Each runtime handle is borrowed and
    /// its `ctx` and vtable must outlive registration.
    residents: std.ArrayListUnmanaged(RegisteredResident) = .empty,
    /// Active profile listeners routed by the multiplexed runtime's accept-event
    /// subject. The runtime owns readiness; each row owns one profile's
    /// listener handle and observation independently.
    resident_listeners: std.AutoHashMapUnmanaged(ResidentListenerKey, ResidentListener) = .empty,
    /// Live resident connections routed by drained ready records.
    resident_wires: std.AutoHashMapUnmanaged(ResidentConnKey, *Wire) = .empty,
    /// Resident dials awaiting `ev_connect`, keyed by runtime and its
    /// host-minted request id.
    pending_resident_dials: std.AutoHashMapUnmanaged(ResidentRequestKey, *ResidentDialWait) = .{},
    /// Scratch a resident's ready records drain into; batch-sized, so a drain
    /// pass allocates nothing.
    event_scratch: [resident_event_batch]net.multiplexed_resident.ReadyEvent = undefined,
    /// Scratch for the multi-wire readiness wait, sized to the live wires; the
    /// wait itself allocates nothing.
    poll_scratch: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    conn_scratch: std.ArrayListUnmanaged(*Wire) = .empty,
    /// Staged stream dials mirrored into each wait. Pending rows are
    /// heap-pinned, so these pointers survive list growth and callbacks that
    /// stage another open.
    dial_scratch: std.ArrayListUnmanaged(*PendingOpen) = .empty,
    /// Staged stream listener setups mirrored into each wait. Rows are pinned
    /// for the same reason as pending opens: completion callbacks may mutate
    /// the owning list.
    listen_scratch: std.ArrayListUnmanaged(*PendingListener) = .empty,
    /// Active stream listeners mirrored into one readiness wait. Rows live in
    /// `active_listeners` and remain stable because listener mutation never
    /// occurs during the wait.
    active_listener_scratch: std.ArrayListUnmanaged(*TransportListener) = .empty,
    borrow_scratch: std.ArrayListUnmanaged(*net.Connection) = .empty,
    wait_interest_scratch: std.ArrayListUnmanaged(net.WaitInterest) = .empty,
    /// The trailing poll rows: resident readiness descriptors, then the
    /// mailbox wake.
    extra_fd_scratch: std.ArrayListUnmanaged(std.posix.fd_t) = .empty,
    /// Listener descriptors registered through `activateListener`. Kept even
    /// before the aggregate ready set is armed so readiness construction and
    /// later listener activation have one lifecycle path.
    listener_fds: std.ArrayListUnmanaged(i32) = .empty,
    /// The off-turn settle mailbox (ADR-0102 stage 4), minted on first
    /// request; its wake fd rides every readiness wait beside the wires.
    mailbox: ?*settle_mailbox.SettleMailbox = null,
    /// Where the next readiness scan starts. `net.waitAnyReadable` reports the
    /// *first* ready wire, so a fixed order lets one always-readable partner
    /// starve every sibling — unbounded on `serve`/`step`, which carry no
    /// budget at all, and a misattributed `WaitTimedOut` on the budgeted
    /// waits (the timeout would name the innocent caller, not the flooder).
    /// Rotating one position per wait bounds a live wire's turn by the
    /// live-wire count instead of by a partner's send rate.
    wait_cursor: usize = 0,
    /// One vow whose synchronously settled completion the next action drain
    /// hands back instead of dropping: the select-or-dial enliven's
    /// cache-hit arm settles inside the verb, before any listener can
    /// register. Every other wait on this face registers first, so this is
    /// the only claimer.
    awaited_completion: ?u64 = null,
    claimed_completion: ?driver_core.HostAction = null,
    /// The aggregate readiness set (ADR-0112), armed by
    /// `readinessDescriptor`. While armed, every stream wire fd, resident
    /// readiness fd, mailbox wake fd, and watched extra fd is mirrored into
    /// it, so an embedder parks on one descriptor instead of re-tracking the
    /// set per language.
    ready_set: ?net.ReadySet = null,
    /// Where an application-visible completion (`settled` / `failed`) with no
    /// in-process claimer goes instead of being freed (ADR-0112): the loop
    /// archive queues it for its C event queue. Null on the native face,
    /// whose waits observe vows in-process through captures.
    completion_sink: ?CompletionSink = null,
    /// Told when a wire closes inside the pump (EOF, fault, or dispatch
    /// refusal), so a step-driven embedder learns of the closure without
    /// polling every session. The close-and-release split stands: the wire
    /// stays owned until `releaseWire`. A session still staged in
    /// `pending_opens` reports through the dial path instead — the
    /// embedder has never seen it, so a close event would name a stranger.
    close_observer: ?CloseObserver = null,
    /// Session opens advancing across pump iterations instead of blocking one
    /// (ADR-0112): embedder dials, redeem dials, and accepts share the same
    /// handshake lifecycle. Heap rows stay stable when an outcome callback
    /// stages another open during the sweep. Admission lives separately
    /// because blocking opens consume the same bound without owning a row.
    pending_opens: std.ArrayListUnmanaged(*PendingOpen) = .empty,
    /// Listener construction that waits on provider progress. Completed
    /// listeners never remain here: finish transfers ownership to the
    /// observer, while cancellation and failure consume the attempt.
    pending_listeners: std.ArrayListUnmanaged(*PendingListener) = .empty,
    /// One authority for every transport connect and CapTP handshake not yet
    /// open, including synchronous constructors that pump pending actions.
    open_admissions: usize = 0,
    /// Whether `deinit` tears the core down. False for a host adopted over an
    /// embedding owner's core (`initWithCore`), whose owner frees it.
    owns_core: bool = true,
    /// Nesting of native-face calls on the current driver thread. The outer
    /// call owns the unsynchronized core for its whole operation; returning
    /// from it is the explicit quiescent boundary where another joined thread
    /// may take over. Compiled out with the debug thread-affinity checks.
    driver_depth: usize = 0,

    /// The public options and result vocabulary live in one I/O-free contract
    /// leaf; aliases keep HostRuntime as the supported namespace.
    pub const Options = Contract.Options;
    pub const FailureObserver = Contract.FailureObserver;
    pub const AdoptionOptions = Contract.AdoptionOptions;
    pub const ProviderRegistrationError = Contract.ProviderRegistrationError;
    pub const InitError = Contract.InitError;
    pub const AdoptionInitError = Contract.AdoptionInitError;
    pub const PendingWork = Contract.PendingWork;
    pub const CloseOutcome = Contract.CloseOutcome;

    pub const DeferredSessionRelease = wire_state.DeferredSessionRelease;
    pub const Wire = wire_state.Wire;
    pub const unattended_parked_cap_bytes = wire_state.unattended_parked_cap_bytes;

    const ResidentDialWait = resident_state.DialWait;
    const ResidentRequestKey = resident_state.RequestKey;
    const ResidentConnKey = resident_state.ConnectionKey;

    const Provider = provider_package.Selected;

    const RegisteredResident = resident_state.Registered;

    const ResidentListenerKey = resident_state.ListenerKey;

    const ResidentListener = resident_state.Listener;

    pub const TransportListener = lifecycle.TransportListener;
    pub const ListenerStopOutcome = lifecycle.ListenerStopOutcome;
    const ActiveListener = lifecycle.ActiveListener;
    pub const PreparedListenerLocator = lifecycle.PreparedListenerLocator;
    pub const PrepareListenerLocatorOutcome = lifecycle.PrepareListenerLocatorOutcome;

    pub const MultiplexedRegistration = provider_package.MultiplexedRegistration;
    pub const ProviderRegistration = provider_package.Registration;
    pub const ProviderPackage = provider_package.Package;
    const InstalledProviderPackage = provider_package.Installed;

    /// How many ready records one drain pass claims before looping.
    const resident_event_batch = 32;

    pub const CompletionSink = lifecycle.CompletionSink;
    pub const CloseObserver = lifecycle.CloseObserver;
    pub const SessionOpenObserver = lifecycle.SessionOpenObserver;
    pub const SessionAcceptObserver = lifecycle.SessionAcceptObserver;
    pub const ListenerObserver = lifecycle.ListenerObserver;
    pub const ExternalAdoptionRole = lifecycle.ExternalAdoptionRole;
    const PendingOpen = pending_state.Open;
    const PendingListener = pending_state.Listener;

    pub const init = runtime_providers.init;
    pub const initWithCore = runtime_providers.initWithCore;
    pub const addNetlayer = runtime_providers.addNetlayer;
    pub const addResident = runtime_providers.addResident;
    pub const addProviderPackage = runtime_providers.addProviderPackage;
    pub const addProviders = runtime_providers.addProviders;

    pub const startListener = runtime_listener_setup.startListener;
    pub const bindListener = runtime_listener_setup.bindListener;

    const reserveListenerProfile = runtime_listeners.reserveListenerProfile;
    const releaseListenerProfile = runtime_listeners.releaseListenerProfile;
    pub const takeStreamListener = runtime_listeners.takeStreamListener;
    pub const listenerLocatorOutcome = runtime_listeners.listenerLocatorOutcome;
    pub const listenerRestorationStateOutcome = runtime_listeners.listenerRestorationStateOutcome;
    pub const canonicalizeListenerLocatorOutcome = runtime_listeners.canonicalizeListenerLocatorOutcome;
    pub const activateListener = runtime_listeners.activateListener;
    pub const prepareListenerLocatorOutcome = runtime_listeners.prepareListenerLocatorOutcome;
    pub const activateOwnedListener = runtime_listeners.activateOwnedListener;
    pub const ownedListenerLocator = runtime_listeners.ownedListenerLocator;
    pub const ownedListenerRestorationStateOutcome = runtime_listeners.ownedListenerRestorationStateOutcome;
    pub const prepareOwnedListenerAdvertisementOutcome = runtime_listeners.prepareOwnedListenerAdvertisementOutcome;
    pub const commitOwnedListenerAdvertisement = runtime_listeners.commitOwnedListenerAdvertisement;
    pub const selectOwnedListener = runtime_listeners.selectOwnedListener;
    const closeActiveListener = runtime_listeners.closeActiveListener;
    const failActiveListener = runtime_listeners.failActiveListener;
    pub const stopOwnedListener = runtime_listeners.stopOwnedListener;
    const closeOwnedListeners = runtime_listeners.closeOwnedListeners;
    const detachClosingListeners = runtime_listeners.detachClosingListeners;
    pub const acceptReady = runtime_listeners.acceptReady;
    pub const closeListener = runtime_listeners.closeListener;
    pub const readinessDescriptor = runtime_readiness.readinessDescriptor;
    pub const watchFd = runtime_readiness.watchFd;
    pub const unwatchFd = runtime_readiness.unwatchFd;
    const removeReadyFd = runtime_readiness.removeReadyFd;
    const descriptorInUse = runtime_readiness.descriptorInUse;
    pub const wakeReadiness = runtime_readiness.wakeReadiness;
    pub const setCompletionSink = runtime_readiness.setCompletionSink;
    pub const setCloseObserver = runtime_readiness.setCloseObserver;
    pub const clearCloseObserver = runtime_readiness.clearCloseObserver;

    const providerFor = runtime_providers.providerFor;
    const mintRuntimeId = runtime_providers.mintRuntimeId;
    pub const hasTransport = runtime_providers.hasTransport;
    pub const transportName = runtime_providers.transportName;

    pub const enterDriver = runtime_shutdown.enterDriver;
    pub const leaveDriver = runtime_shutdown.leaveDriver;
    pub const detachThread = runtime_shutdown.detachThread;
    pub const deferSessionRelease = runtime_shutdown.deferSessionRelease;
    const drainDeferredSessionReleases = runtime_shutdown.drainDeferredSessionReleases;
    pub const refuseReentry = runtime_shutdown.refuseReentry;
    pub const withinCallback = runtime_shutdown.withinCallback;
    pub const beginClose = runtime_shutdown.beginClose;
    pub const beginSessionClose = runtime_shutdown.beginSessionClose;
    pub const closeSession = runtime_shutdown.closeSession;
    pub const sessionCloseOutcome = runtime_shutdown.sessionCloseOutcome;
    pub const SessionCloseStatus = runtime_shutdown.SessionCloseStatus;
    pub const sessionCloseStatus = runtime_shutdown.sessionCloseStatus;
    pub const freeAction = runtime_shutdown.freeAction;
    const progressSessionCloses = runtime_shutdown.progressSessionCloses;
    pub const close = runtime_shutdown.close;
    pub const beginRetirement = runtime_shutdown.beginRetirement;
    const progressRetirement = runtime_shutdown.progressRetirement;
    pub const listenerOwnershipRetired = runtime_shutdown.listenerOwnershipRetired;
    pub const lifecyclePhase = runtime_shutdown.lifecyclePhase;
    pub const closeOutcome = runtime_shutdown.closeOutcome;
    const progressClose = runtime_shutdown.progressClose;
    pub const deinit = runtime_shutdown.deinit;
    pub const deinitOutcome = runtime_shutdown.deinitOutcome;
    pub const deinitAfterFailedAdoption = runtime_shutdown.deinitAfterFailedAdoption;

    pub const connectLocator = runtime_opens.connectLocator;
    pub const startDial = runtime_opens.startDial;
    pub const startAdoptExternal = runtime_opens.startAdoptExternal;
    const stageDial = runtime_opens.stageDial;
    const handshakeDeadline = runtime_opens.handshakeDeadline;

    pub const cancelListener = runtime_listener_setup.cancelListener;
    const finishPendingListener = runtime_listener_setup.finishPendingListener;
    const failPendingListener = runtime_listener_setup.failPendingListener;
    const pendingResidentListener = runtime_listener_setup.pendingResidentListener;
    const advancePendingListeners = runtime_listener_setup.advancePendingListeners;

    pub const startAcceptWire = runtime_opens.startAcceptWire;
    pub const cancelAccepts = runtime_opens.cancelAccepts;
    const advancePendingOpens = runtime_opens.advancePendingOpens;
    const discardPendingOpen = runtime_opens.discardPendingOpen;
    const pendingOpenByRequest = runtime_opens.pendingOpenByRequest;
    const pendingOpenFor = runtime_opens.pendingOpenFor;
    const adoptPendingResidentDial = runtime_opens.adoptPendingResidentDial;
    const adoptPendingStreamDial = runtime_opens.adoptPendingStreamDial;

    const pendingOpenSlotAvailable = runtime_admission.pendingOpenSlotAvailable;
    const acquireOpenAdmission = runtime_admission.acquireOpenAdmission;
    const admitApplicationOperation = runtime_admission.admitApplicationOperation;
    pub const checkApplicationAdmission = runtime_admission.checkApplicationAdmission;
    pub const noteTerminalFailure = runtime_failures.noteTerminalFailure;
    const noteTerminalFailureChain = runtime_failures.noteTerminalFailureChain;
    const releaseCoreSession = runtime_failures.releaseCoreSession;
    pub const noteTerminalOperationFailure = runtime_failures.noteTerminalOperationFailure;
    pub const reportUnhandledFailure = runtime_failures.reportUnhandledFailure;
    const retainAndReportUnhandledFailure = runtime_failures.retainAndReportUnhandledFailure;
    pub const failProviderContract = runtime_failures.failProviderContract;
    const reportObservedFailure = runtime_failures.reportObservedFailure;
    const reportObservedOperationFailure = runtime_failures.reportObservedOperationFailure;
    const reportObservedFailureChain = runtime_failures.reportObservedFailureChain;
    const reportListenAttemptFailure = runtime_failures.reportListenAttemptFailure;
    pub const terminalFailure = runtime_failures.terminalFailure;
    pub const operationFailure = runtime_failures.operationFailure;

    pub const stepWaitMs = runtime_step.stepWaitMs;
    const clampTimeoutToPendingWork = runtime_step.clampTimeoutToPendingWork;
    const progressCarrierCloseDeadlines = runtime_carrier.progressCarrierCloseDeadlines;

    pub const acceptWire = runtime_connections.acceptWire;
    const bindAcceptedWireOutcome = runtime_connections.bindAcceptedWireOutcome;
    const bindWire = runtime_connections.bindWire;
    const bindStreamWireOutcome = runtime_connections.bindStreamWireOutcome;
    const bindResidentWire = runtime_connections.bindResidentWire;
    const adoptConn = runtime_connections.adoptConn;
    const adoptResidentConn = runtime_connections.adoptResidentConn;

    const freeWire = runtime_carrier.freeWire;
    const dropWire = runtime_carrier.dropWire;
    const forceWireCarrierClose = runtime_carrier.forceWireCarrierClose;
    const closeWire = runtime_carrier.closeWire;
    const progressWireCarrierClose = runtime_carrier.progressWireCarrierClose;

    pub const publishGiftable = runtime_capabilities.publishGiftable;
    pub const unpublish = runtime_capabilities.unpublish;
    const claimCompletion = runtime_capabilities.claimCompletion;
    const wouldClaimCompletion = runtime_capabilities.wouldClaimCompletion;
    pub const enliven = runtime_capabilities.enliven;

    pub const releaseWire = runtime_sessions.releaseWire;
    const releaseWireOwned = runtime_sessions.releaseWireOwned;
    pub const claimSessionHandle = runtime_sessions.claimSessionHandle;
    pub const claimReferenceExporter = runtime_sessions.claimReferenceExporter;
    pub const sessionEventIsLive = runtime_sessions.sessionEventIsLive;

    const writeOutbound = runtime_actions.writeOutbound;
    pub const drainActions = runtime_actions.drainActions;
    const drainActionsWith = runtime_actions.drainActionsWith;

    const pumpHandshake = runtime_pump.pumpHandshake;
    pub const markSessionUnattended = runtime_pump.markSessionUnattended;
    pub const attendSession = runtime_pump.attendSession;
    const resumeFeedTails = runtime_pump.resumeFeedTails;
    const pumpUntilProbe = runtime_pump.pumpUntilProbe;
    const serviceReadyWire = runtime_pump.serviceReadyWire;
    const feedReadable = runtime_pump.feedReadable;
    pub const settleMailbox = runtime_pump.settleMailbox;
    const applySettleMailbox = runtime_pump.applySettleMailbox;
    const applySettleMailboxWith = runtime_pump.applySettleMailboxWith;
    const waitAnySource = runtime_pump.waitAnySource;
    const serviceResident = runtime_resident_pump.serviceResident;
    pub const pumpUntilFlag = runtime_step.pumpUntilFlag;
    pub const stepSession = runtime_step.stepSession;
    pub const stepAny = runtime_step.stepAny;
    const stepAnyToward = runtime_step.stepAnyToward;
    const stepAnyOwned = runtime_step.stepAnyOwned;
    const stepAfterTerminalFailure = runtime_step.stepAfterTerminalFailure;
    const waitForTerminalSignal = runtime_step.waitForTerminalSignal;
    const terminalCleanupPending = runtime_step.terminalCleanupPending;
    const nudgeIfWorkRemains = runtime_step.nudgeIfWorkRemains;
};

/// Package-private friend index for `host_runtime/*` owner modules.
///
/// The supported surface is `HostRuntime`; this namespace lets sibling files
/// compose private lifecycle phases without making those phases methods that
/// callers can select independently. Entries are direct aliases, never a
/// second implementation or a forwarding call layer.
pub const Internal = struct {
    pub const pumpUntilProbe = HostRuntime.pumpUntilProbe;
    pub const progressSessionCloses = HostRuntime.progressSessionCloses;
    pub const progressClose = HostRuntime.progressClose;
    pub const applySettleMailbox = HostRuntime.applySettleMailbox;
    pub const applySettleMailboxWith = HostRuntime.applySettleMailboxWith;
    pub const resumeFeedTails = HostRuntime.resumeFeedTails;
    pub const advancePendingOpens = HostRuntime.advancePendingOpens;
    pub const advancePendingListeners = HostRuntime.advancePendingListeners;
    pub const waitAnySource = HostRuntime.waitAnySource;
    pub const serviceReadyWire = HostRuntime.serviceReadyWire;
    pub const serviceResident = HostRuntime.serviceResident;
    pub const adoptPendingStreamDial = HostRuntime.adoptPendingStreamDial;
    pub const adoptPendingResidentDial = HostRuntime.adoptPendingResidentDial;
    pub const finishPendingListener = HostRuntime.finishPendingListener;
    pub const pendingResidentListener = HostRuntime.pendingResidentListener;
    pub const clampTimeoutToPendingWork = HostRuntime.clampTimeoutToPendingWork;
    pub const progressCarrierCloseDeadlines = HostRuntime.progressCarrierCloseDeadlines;
    pub const progressWireCarrierClose = HostRuntime.progressWireCarrierClose;
    pub const writeOutbound = HostRuntime.writeOutbound;
    pub const feedReadable = HostRuntime.feedReadable;
    pub const closeWire = HostRuntime.closeWire;
    pub const dropWire = HostRuntime.dropWire;
    pub const noteTerminalFailure = HostRuntime.noteTerminalFailure;
    pub const progressRetirement = HostRuntime.progressRetirement;
    pub const admitApplicationOperation = HostRuntime.admitApplicationOperation;
    pub const wouldClaimCompletion = HostRuntime.wouldClaimCompletion;
    pub const claimCompletion = HostRuntime.claimCompletion;
    pub const stageDial = HostRuntime.stageDial;
    pub const discardPendingOpen = HostRuntime.discardPendingOpen;
    pub const pendingOpenByRequest = HostRuntime.pendingOpenByRequest;
    pub const pendingOpenSlotAvailable = HostRuntime.pendingOpenSlotAvailable;
    pub const handshakeDeadline = HostRuntime.handshakeDeadline;
    pub const noteTerminalFailureChain = HostRuntime.noteTerminalFailureChain;
    pub const acquireOpenAdmission = HostRuntime.acquireOpenAdmission;
    pub const releaseCoreSession = HostRuntime.releaseCoreSession;
    pub const pumpHandshake = HostRuntime.pumpHandshake;
    pub const providerFor = HostRuntime.providerFor;
    pub const mintRuntimeId = HostRuntime.mintRuntimeId;
    pub const descriptorInUse = HostRuntime.descriptorInUse;
    pub const removeReadyFd = HostRuntime.removeReadyFd;
    pub const reserveListenerProfile = HostRuntime.reserveListenerProfile;
    pub const retainAndReportUnhandledFailure = HostRuntime.retainAndReportUnhandledFailure;
    pub const pendingOpenFor = HostRuntime.pendingOpenFor;
    pub const nudgeIfWorkRemains = HostRuntime.nudgeIfWorkRemains;
    pub const releaseWireOwned = HostRuntime.releaseWireOwned;
    pub const stepAnyToward = HostRuntime.stepAnyToward;
    pub const closeOwnedListeners = HostRuntime.closeOwnedListeners;
    pub const closeActiveListener = HostRuntime.closeActiveListener;
    pub const failActiveListener = HostRuntime.failActiveListener;
    pub const drainActionsWith = HostRuntime.drainActionsWith;
    pub const reportObservedOperationFailure = HostRuntime.reportObservedOperationFailure;
    pub const reportObservedFailure = HostRuntime.reportObservedFailure;
    pub const reportObservedFailureChain = HostRuntime.reportObservedFailureChain;
    pub const reportListenAttemptFailure = HostRuntime.reportListenAttemptFailure;
    pub const failPendingListener = HostRuntime.failPendingListener;
    pub const detachClosingListeners = HostRuntime.detachClosingListeners;
    pub const forceWireCarrierClose = HostRuntime.forceWireCarrierClose;
    pub const freeWire = HostRuntime.freeWire;
    pub const releaseListenerProfile = HostRuntime.releaseListenerProfile;
    pub const bindAcceptedWireOutcome = HostRuntime.bindAcceptedWireOutcome;
    pub const bindWire = HostRuntime.bindWire;
    pub const bindStreamWireOutcome = HostRuntime.bindStreamWireOutcome;
    pub const adoptConn = HostRuntime.adoptConn;
    pub const adoptResidentConn = HostRuntime.adoptResidentConn;
};
