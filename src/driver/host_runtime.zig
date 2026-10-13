//! The owning host face (ADR-0090): a blocking, poll-multiplexed embedding of
//! the sans-io `driver_core.Host`, the native sibling of the byte-fed pump
//! every binding runs on its own event loop.
//!
//! `driver.HostRuntime` owns the composition: the core Host, one transport
//! wire per live session, and the pump. `session.zig`'s owning
//! `Session`/`Server` are views over it. Every blocking wait runs one loop:
//! drain the core's action queue (write flushes, answer redeem dials, draw
//! gift-id entropy), wait for any live wire to become readable under the
//! caller's `Budget`, feed those outer-framed bytes through `Host.feedBytes`,
//! and repeat until the wait's capture fires. Because the wait spans every
//! live wire, a sibling session's inbound (a deposit arriving while this
//! session waits on a withdraw) is served inside the same wait. That is how
//! same-Host gifter and exporter roles work on one fiber with no thread.
//!
//! Every wire belongs to a `MultiplexedResident`: a transport runtime with
//! one readiness descriptor that routes drained ready records by stable
//! connection id. The pump polls those descriptors, never a socket per
//! connection.

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

/// The owning face over one `driver_core.Host`: the core, the transports
/// it dials through, and one wire per live session. One thread drives one
/// `HostRuntime` and its core `Host`. Every blocking verb on a view pumps through
/// here.
pub const HostRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The sans-io host, behind one stable pointer. `init` allocates it and
    /// `deinit` frees it, so this face stays the owner. The pointer shape is
    /// what lets an embedding owner hold the core elsewhere (ADR-0112).
    core: *driver_core.Host,
    /// One provider registry for dial and listen dispatch. Entries carry the
    /// Host-owned canonical symbol and a multiplexed-resident index. Concrete provider contexts remain borrowed
    /// and must outlive the HostRuntime. Selection itself has no second authority.
    providers: std.ArrayListUnmanaged(Provider) = .empty,
    /// Installed provider packages and their configuration/lifetime owner.
    /// Package overlap and idempotency are Runtime composition policy. An ABI
    /// adapter supplies only the opaque comparison and release effects.
    provider_packages: std.ArrayListUnmanaged(InstalledProviderPackage) = .empty,
    /// Canonical transport profiles with a listener pending or active. Keys
    /// borrow the provider registry, which outlives this map. The Runtime owns
    /// occupancy. Adapter listener ids are only handles onto that authority.
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
    /// Callback-time retirement seals admission immediately. Listener I/O and
    /// pending setup cancellation wait for the enclosing step to unwind.
    retirement_effects_pending: bool = false,
    /// A callback-time close has already sealed core admission. Listener and
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
    /// owning Session may transfer cleanup through `deferSessionRelease`.
    /// Every direct Runtime reentry remains refused until the observer returns.
    observer_callback_depth: usize = 0,
    /// A failure crossed a Runtime callback or post-commit boundary that could
    /// not return it directly. Detection may happen in an ABI adapter or in
    /// Runtime cleanup, but terminality is Runtime policy and every later
    /// application operation observes this one sticky concrete cause.
    terminal_failure: ?OperationFailure = null,
    /// The multiplexed runtimes this host dials and accepts through (ADR-0112).
    /// Each runtime handle is borrowed and
    /// its `ctx` and vtable must outlive registration.
    residents: std.ArrayListUnmanaged(RegisteredResident) = .empty,
    /// Active profile listeners routed by the multiplexed runtime's accept-event
    /// subject. The runtime owns readiness. Each row owns one profile's
    /// listener handle and observation independently.
    resident_listeners: std.AutoHashMapUnmanaged(ResidentListenerKey, ResidentListener) = .empty,
    /// Live resident connections routed by drained ready records.
    resident_wires: std.AutoHashMapUnmanaged(ResidentConnKey, *Wire) = .empty,
    /// The one buffer every resident wire reads into. A read feeds the core
    /// before the next begins (byte streams copy only a partial tail, and a
    /// message packet dispatches during the call), and the pump never reads
    /// two wires at once, so an idle resident wire holds no read buffer. It
    /// grows at adoption to the largest packet a live wire may deliver and is
    /// retained, so the read path never allocates.
    resident_read_scratch: []u8 = &.{},
    /// Resident dials awaiting `ev_connect`, keyed by runtime and its
    /// host-minted request id.
    pending_resident_dials: std.AutoHashMapUnmanaged(ResidentRequestKey, *ResidentDialWait) = .{},
    /// Scratch a resident's ready records drain into. Batch-sized, so a drain
    /// pass allocates nothing.
    event_scratch: [resident_event_batch]net.multiplexed_resident.ReadyEvent = undefined,
    /// Scratch for the readiness wait: one poll row per resident readiness
    /// descriptor, then the mailbox and readiness wakes. Retained, so the
    /// wait itself allocates nothing.
    poll_scratch: std.ArrayListUnmanaged(std.posix.pollfd) = .empty,
    extra_fd_scratch: std.ArrayListUnmanaged(std.posix.fd_t) = .empty,
    /// Descriptors watched through `watchFd`. Kept on both faces, so
    /// descriptor-conflict detection and `unwatchFd` have one lifecycle path
    /// whether or not a ready set mirrors them.
    listener_fds: std.ArrayListUnmanaged(i32) = .empty,
    /// The off-turn settle mailbox (ADR-0102 stage 4), minted on first
    /// request. Its wake fd rides every readiness wait beside the wires.
    mailbox: ?*settle_mailbox.SettleMailbox = null,
    /// Which resident the next readiness wait polls first. A poll reports the
    /// first ready row, so a fixed order lets one always-ready resident
    /// starve its siblings. Starting one position later per wait bounds a
    /// resident's turn by the resident count instead of by its traffic.
    wait_cursor: usize = 0,
    /// The nearest carrier-close deadline any wire holds, and how many hold
    /// one. Both sibling tiers cache this rather than walk every slot before
    /// each wait (`completion/loop/connections/deadlines.zig`,
    /// `driver/core/host/close.zig`). An open wire holds no deadline, so the
    /// common wait pays one comparison. A cleared deadline may leave the
    /// cache early, and the one walk that finds nothing due re-derives it.
    nearest_carrier_close_ms: ?i64 = null,
    carrier_close_waiters: usize = 0,
    /// Which face drives this runtime, chosen once at construction through
    /// `Options.drive` and never changed. The blocking native face waits
    /// through `net.waitAnyReadable` and observes vows in-process through
    /// captures. The stepped face (ADR-0112) carries the aggregate readiness
    /// set an embedder parks on and the two recipients it publishes through.
    /// Every site that services one face names the other's arm as empty, so
    /// the code says which half is unreachable natively.
    drive: Drive,
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
    /// call owns the unsynchronized core for its whole operation. Returning
    /// from it is the explicit quiescent boundary where another joined thread
    /// may take over. Compiled out with the debug thread-affinity checks.
    driver_depth: usize = 0,

    /// The public options and result vocabulary live in one I/O-free contract
    /// leaf. Aliases keep HostRuntime as the supported namespace.
    pub const Options = Contract.Options;
    pub const FailureObserver = Contract.FailureObserver;
    pub const AdoptionOptions = Contract.AdoptionOptions;
    pub const ProviderRegistrationError = Contract.ProviderRegistrationError;
    pub const PendingWork = Contract.PendingWork;
    pub const CloseOutcome = Contract.CloseOutcome;

    pub const DeferredSessionRelease = wire_state.DeferredSessionRelease;
    pub const Wire = wire_state.Wire;
    pub const unattended_parked_cap_bytes = wire_state.unattended_parked_cap_bytes;

    /// The construction-time choice behind `drive`. See `Options.drive`.
    pub const DriveOptions = lifecycle.DriveOptions;
    pub const SteppedOptions = lifecycle.SteppedOptions;

    /// The face a runtime is driven by. The tag is fixed at construction, so
    /// there is no arming verb and no second arm to refuse: a stepped runtime
    /// is stepped from its first wire, and a blocking one has no descriptor
    /// to hand out.
    pub const Drive = union(enum) {
        blocking,
        stepped: Stepped,

        pub fn init(options: DriveOptions) error{ReadinessUnavailable}!Drive {
            return switch (options) {
                .blocking => .blocking,
                .stepped => |stepped| .{ .stepped = .{
                    .ready_set = try net.ReadySet.init(),
                    .completion_sink = stepped.completion_sink,
                    .close_observer = stepped.close_observer,
                } },
            };
        }

        pub fn deinit(self: *Drive) void {
            switch (self.*) {
                .blocking => {},
                .stepped => |*stepped| stepped.ready_set.deinit(),
            }
        }
    };

    /// The stepped face's state (ADR-0112). All three are installed together,
    /// before any wire exists, so none is optional here: every resident
    /// readiness fd, mailbox wake fd, and watched extra fd is
    /// mirrored into `ready_set` from the moment it appears, every wire
    /// reserves its close publication with `close_observer` at adoption, and
    /// every application-visible completion with no in-process claimer has
    /// `completion_sink` as its taker instead of being freed. A wire the
    /// pump closes (EOF, fault, or dispatch refusal) reaches the observer
    /// under the close-and-release split: it stays owned until `releaseWire`.
    /// A session still staged in `pending_opens` reports through the dial
    /// path instead, because the embedder has never seen it and a close
    /// event would name a stranger.
    pub const Stepped = struct {
        ready_set: net.ReadySet,
        completion_sink: CompletionSink,
        close_observer: CloseObserver,
    };

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
    pub const Transports = @import("host_runtime/transports.zig").Transports;
    pub const initWithCore = runtime_providers.initWithCore;
    pub const addResident = runtime_providers.addResident;
    pub const addProviderPackage = runtime_providers.addProviderPackage;
    pub const addProviders = runtime_providers.addProviders;

    pub const startListener = runtime_listener_setup.startListener;
    pub const bindListener = runtime_listener_setup.bindListener;

    const reserveListenerProfile = runtime_listeners.reserveListenerProfile;
    const releaseListenerProfile = runtime_listeners.releaseListenerProfile;
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
    pub const closeListener = runtime_listeners.closeListener;
    pub const readinessDescriptor = runtime_readiness.readinessDescriptor;
    pub const watchFd = runtime_readiness.watchFd;
    pub const unwatchFd = runtime_readiness.unwatchFd;
    const removeReadyFd = runtime_readiness.removeReadyFd;
    const descriptorInUse = runtime_readiness.descriptorInUse;
    pub const wakeReadiness = runtime_readiness.wakeReadiness;

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

    pub const cancelAccepts = runtime_opens.cancelAccepts;
    const advancePendingOpens = runtime_opens.advancePendingOpens;
    const discardPendingOpen = runtime_opens.discardPendingOpen;
    const pendingOpenByRequest = runtime_opens.pendingOpenByRequest;
    const pendingOpenFor = runtime_opens.pendingOpenFor;
    const adoptPendingResidentDial = runtime_opens.adoptPendingResidentDial;

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

    const bindWire = runtime_connections.bindWire;
    const bindResidentWire = runtime_connections.bindResidentWire;
    const adoptResidentConn = runtime_connections.adoptResidentConn;

    const freeWire = runtime_carrier.freeWire;
    const dropWire = runtime_carrier.dropWire;
    const reserveCloseEvent = runtime_carrier.reserveCloseEvent;
    const releaseCloseEvent = runtime_carrier.releaseCloseEvent;
    const forceWireCarrierClose = runtime_carrier.forceWireCarrierClose;
    const closeWire = runtime_carrier.closeWire;
    const progressWireCarrierClose = runtime_carrier.progressWireCarrierClose;

    pub const publish = runtime_capabilities.publish;
    pub const unpublish = runtime_capabilities.unpublish;
    pub const enliven = runtime_capabilities.enliven;

    pub const releaseWire = runtime_sessions.releaseWire;
    const releaseWireOwned = runtime_sessions.releaseWireOwned;
    pub const claimSessionHandle = runtime_sessions.claimSessionHandle;
    pub const claimReferenceExporter = runtime_sessions.claimReferenceExporter;
    pub const claimExporterSession = runtime_sessions.claimExporterSession;
    pub const sessionEventIsLive = runtime_sessions.sessionEventIsLive;

    const writeOutbound = runtime_actions.writeOutbound;
    pub const drainActions = runtime_actions.drainActions;
    const drainActionsWith = runtime_actions.drainActionsWith;

    const pumpHandshake = runtime_pump.pumpHandshake;
    pub const markSessionUnattended = runtime_pump.markSessionUnattended;
    pub const attendSession = runtime_pump.attendSession;
    const resumeFeedTails = runtime_pump.resumeFeedTails;
    const pumpUntilProbe = runtime_pump.pumpUntilProbe;
    const feedReadable = runtime_pump.feedReadable;
    pub const settleMailbox = runtime_pump.settleMailbox;
    const applySettleMailbox = runtime_pump.applySettleMailbox;
    const applySettleMailboxWith = runtime_pump.applySettleMailboxWith;
    const waitAnySource = runtime_pump.waitAnySource;
    const serviceResident = runtime_resident_pump.serviceResident;
    pub const pumpUntilFlag = runtime_step.pumpUntilFlag;
    pub const stepSession = runtime_step.stepSession;
    pub const stepAny = runtime_step.stepAny;
    pub const stepAnyToward = runtime_step.stepAnyToward;
    const stepAnyOwned = runtime_step.stepAnyOwned;
    const stepAfterTerminalFailure = runtime_step.stepAfterTerminalFailure;
    const waitForTerminalSignal = runtime_step.waitForTerminalSignal;
    const terminalCleanupPending = runtime_step.terminalCleanupPending;
    const nudgeIfWorkRemains = runtime_step.nudgeIfWorkRemains;
};

/// Package-private friend index for `host_runtime/*` owner modules.
///
/// The supported surface is `HostRuntime`. This namespace lets sibling files
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
    pub const serviceResident = HostRuntime.serviceResident;
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
    pub const reserveCloseEvent = HostRuntime.reserveCloseEvent;
    pub const releaseCloseEvent = HostRuntime.releaseCloseEvent;
    pub const noteTerminalFailure = HostRuntime.noteTerminalFailure;
    pub const progressRetirement = HostRuntime.progressRetirement;
    pub const admitApplicationOperation = HostRuntime.admitApplicationOperation;
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
    pub const bindWire = HostRuntime.bindWire;
    pub const adoptResidentConn = HostRuntime.adoptResidentConn;
};
