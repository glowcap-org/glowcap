//! The sans-io byte-fed multi-session CapTP host core (ADR-0072), under the
//! `driver_core` I/O ban. A `Host` owns one `engine.Node` (identity,
//! live-session directory, routing, the redeem serve step) and mints byte-fed
//! sessions (`HostSession`) whose peers are node-registered, so
//! everything the node decides (where a capability route leads, which exporter a give
//! withdraws from, when a served reply becomes a signed give) happens under
//! every session the host holds, with no socket in sight. The embedder owns
//! the loop, the sockets, and the entropy: it feeds inbound packets with
//! `feedTransportPacket`, or lower-level bytes with `feed` (a bare whole
//! frame), `feedBytes` (outer-framed byte-stream chunks), or `serveEvent`
//! (one already-polled event, the completion-loop hook), drains outbound
//! packets with `HostSession.takeTransportOutbound`, and answers the host's
//! action queue (`nextAction`), meaning dial requests, flush notices, close signals
//! for a condemned session, and gift-id entropy requests, with
//! `exporterDialed` / `dialFailed` / `provideGiftId`. Settlements ride the
//! same queue: a vow with no in-process listener settles as an owned
//! `settled`/`failed` completion the embedder routes by vow id, so one drain
//! hears every outcome. An in-process Zig consumer may instead register a
//! borrowed one-shot listener with `vowOn`, which keeps that vow's settlement
//! zero-copy and off the queue. `driver.HostRuntime` is one such embedder (its
//! transport residents over this core, ADR-0193). The C ABI's
//! `libglowcap_host` is another (byte-fed from a binding-owned loop).
//!
//! One thread drives one host. The node tables, the CapTP session map, the vow
//! map, and the crossed-hellos table are unsynchronized by contract, which is
//! why `CrossedHellos` carries no lock.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const capability = @import("capability.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const session_directory = @import("sessions/directory.zig");
const host_action = @import("host/action.zig");
const host_admission = @import("host/admission.zig");
const host_configuration = @import("host/configuration.zig");
const host_delivery = @import("host/delivery.zig");
const host_errors = @import("host/errors.zig");
const host_hosting = @import("host/hosting.zig");
const host_observation = @import("host/observation.zig");
const host_capability_identity = @import("host/capabilities/identity.zig");
const host_capability_lower = @import("host/capabilities/lower.zig");
const host_capability_lift = @import("host/capabilities/lift.zig");
const host_capability_routing = @import("host/capabilities/routing.zig");
const host_session = @import("host/session.zig");
const host_session_ingress = @import("host/session/ingress.zig");
const host_transports = @import("host/transports.zig");
const host_interception = @import("host/interception.zig");
const host_ownership = @import("host/ownership.zig");
const host_trace = @import("host/trace.zig");
const enliven_mod = @import("enliven.zig");
const vows_mod = @import("vows.zig");
const vow_settlement = @import("vows/settlement.zig");
const vow_release = @import("vows/release.zig");
const vow_resolvers = @import("vows/resolvers.zig");
const sessions_mod = @import("sessions.zig");
const handoff_mod = @import("handoff.zig");
const capability_promise = @import("capability_promise.zig");
const capability_promise_row = @import("capability_promise/row.zig");
const trace = @import("trace.zig");
const publish_mod = @import("publish.zig");
const host_close = @import("host/close.zig");
const CrossedHellos = crossed_hellos.CrossedHellos;
const HostAction = host_action.HostAction;

const crypto = foundation.crypto;

pub const HostError = host_errors.HostError;
pub const SessionReleaseError = host_errors.SessionReleaseError;

/// Domain separator for session-seed derivation, so a root can never yield
/// bytes that collide with another use of the same key material.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub const session_seed_domain = "glowcap session-key v1";

pub const PeerProvenance = enum { verified, dial_target, assertion_only };

/// Enlivenment lives in `enliven.zig`. Its vocabulary is named here because
/// this is the file every consumer of the host core reads first.
pub const EnlivenPeerPolicy = enliven_mod.EnlivenPeerPolicy;
pub const EnlivenStart = enliven_mod.EnlivenStart;

// The session wire owns the shell and byte ingress/egress. These direct aliases
// preserve the supported core surface without exporting its internal module.
pub const HostSession = host_session.HostSession;
pub const host_session_struct_budget_bytes = host_session.host_session_struct_budget_bytes;

pub const DialTarget = crossed_hellos.DialTarget;

/// One identity, one node, many byte-fed CapTP sessions: the sans-io host
/// core. The node serve step decides, and this host executes each action
/// either directly (settle and fail fire the recipient vat's listener through
/// `Vat.settleFar`) or by queueing it for the embedder (dials and gift-id
/// draws are host effects). Free with `deinit`, which breaks every
/// still-parked vow before the shells go.
pub const Host = struct {
    allocator: std.mem.Allocator,
    node: engine.Node,
    opts: Options,
    /// One actor graph and turn scheduler for every session Port in this Host.
    vat: actors.Vat,
    sessions: std.AutoHashMapUnmanaged(engine.PeerHandle, *HostSession) = .{},
    /// Aggregate pending-work count. Session close reads its own compact
    /// counter. Host close reads this O(1) authority instead of rescanning live
    /// sessions or adapter-owned operation rows on every progress turn.
    pending_operations: usize = 0,
    /// Canonical application identities for capabilities lifted out of any
    /// session. Wire positions remain owned by their session. This table keeps
    /// the owning peer beside the target and rejects stale generations.
    capabilities: capability.Registry = .{},
    /// Inline handoff promises. Rows exist only while redemption is pending or
    /// while their opaque capability identity remains live.
    capability_promises: std.AutoHashMapUnmanaged(capability.PromiseId, capability_promise_row.Row) = .empty,
    next_capability_promise: u64 = 1,
    /// Incarnation stamp for remote import rows first lifted into Host space.
    /// Monotonic for the Host lifetime. Zero is never issued.
    next_import_incarnation: u64 = 1,
    /// Crossed-hellos tiebreak state (ADR-0030): `openDialedLocator` registers
    /// the outbound before its hello moves. Accepted CapTP sessions compare
    /// inbound start-sessions against it.
    hellos: CrossedHellos = .{},
    /// Root from which `mintShell` derives each session's signing seed
    /// (ADR-0097). The embedder supplies a fresh root for each process.
    session_seed_root: [crypto.SEED_BYTES]u8,
    /// Counter distinguishing successive sessions' derived seeds. Monotonic
    /// for the host's life, so two sessions never share a key.
    session_seed_counter: u64 = 0,
    /// OCapN side name → the session whose verified partner key derives that
    /// side. A signed give carries the side, not the key, so this directory
    /// authenticates an early withdraw before its deposit row exists. This is
    /// also the one partner-identity index: key lookups derive the side and
    /// compare the selected shell's exact `indexed_partner_key` before use.
    partner_by_side: std.AutoHashMapUnmanaged([32]u8, engine.PeerHandle) = .{},
    /// A partner's **authenticated durable identity** → peer handle: the second
    /// of the two peer directories, and not the same one
    /// (ADR-0097). `partner_by_side` names a session *incarnation* through the
    /// key that signed it, the identity a handoff certificate must resolve
    /// against. This names the durable peer a locator designates, which is
    /// what "do I already have a session reaching P" must ask. They differ by
    /// construction: every session has a fresh signing key, while the
    /// durable peer key is stable across connections. Routing dial dedup
    /// through the side index would therefore miss the existing peer.
    ///
    /// Only an authenticated durable identity is indexed
    /// (`vocab.DurableProvenance`): an unproved claim as a dial-match key is
    /// the squatting hazard `liveSessionForDial` refuses.
    ///
    /// Keyed by the durable key's 32 bytes rather than its hex encoding,
    /// so a row can be written from a borrowed hello view before apply, which
    /// is when duplicate collapse needs it, without retaining bytes the frame
    /// owns.
    peer_by_durable: std.AutoHashMapUnmanaged([crypto.PEER_KEY_BYTES]u8, engine.PeerHandle) = .{},
    /// Our own dialed `(transport, designator)` → peer handle. Key slices borrow
    /// the session shell and leave the index before those bytes free. The
    /// complete locator identity prevents one netlayer from satisfying or
    /// shadowing another netlayer's dial.
    dialed_by_target: session_directory.DialTargetMap = .{},
    /// Runtime provider occupancy and complete session semantics. Built-in keys
    /// borrow `model.transport.Known`'s static symbol. Extension keys are
    /// Host-owned copies. One row per symbol makes routing authority unique.
    /// Designation, dial planning, and sealed-channel composition all read the
    /// same value.
    transport_profiles: std.StringHashMapUnmanaged(model.transport.Metadata) = .empty,
    /// Host-wide bootstrap aliases. A fetch performs one keyed discovery lookup
    /// and lazily projects the actor onto the requesting Port.
    publications: std.StringHashMapUnmanaged(publish_mod.Publication) = .empty,
    /// Lowering receipts held until the running turn's outcome (ADR-0194).
    turn_receipts: host_capability_lower.TurnReceipts = .{},
    publication_lookup: ?*const @import("publication_lookup.zig").Lookup = null,
    /// The embedder-facing action FIFO. `nextAction` drains it.
    actions: engine.ActionFifo(HostAction) = .{},
    /// The most recently popped action. Its byte views stay valid until the
    /// next `nextAction`, which frees them.
    last_action: ?HostAction = null,
    /// A C convenience-pump arm refused before committing its effect. The
    /// borrowed action remains `last_action` and must be projected again before
    /// any later FIFO row. Keeping the retry here preserves action order and
    /// payload ownership without a second queue representation.
    retry_last_action: bool = false,
    /// Rows in `vows` whose producer can still settle. Kept at the row
    /// lifecycle boundary so action reservation and close admission stay O(1)
    /// even when an embedder retains many completed public handles. `u32`
    /// occupies the alignment gap before `trace_sink`. Publication refuses at
    /// its bound instead of enlarging every Host.
    pending_vow_count: u32 = 0,
    /// The live trace tap (`trace.zig`), or null. Installed by the embedder
    /// through `setTrace` / the C `glowcap_host_set_trace`. With none every
    /// emit site is one null check.
    trace_sink: ?trace.Sink = null,

    /// Host vow id to its heap row (the row's address is the settlement
    /// listener's stable ctx, though the map may rehash). In-process listeners consume
    /// their rows at settlement. Embedder-facing rows retain the answer position
    /// through settlement and retire on explicit release, preserving promise
    /// pipelining until the public handle itself dies.
    vows: std.AutoHashMapUnmanaged(u64, *VowRow) = .{},
    next_vow: u64 = 1,
    /// Host resolver id → its session-less vow row and the vat resolver it
    /// settles (ADR-0102). A row is consumed by the first settle attempt, so
    /// the map holds exactly the live settle authorities. Freed with the
    /// host. Ids are host-scoped, from their own counter, and never reused.
    resolver_index: std.AutoHashMapUnmanaged(u64, ResolverIndexEntry) = .{},
    next_resolver: u64 = 1,
    /// Enlivens waiting on a dial this host staged (`enlivenSelectOrDial`,
    /// ADR-0098). Each row holds the vow id minted for the caller *before*
    /// any session exists, so the outcome reaches an embedder that only
    /// drains actions. The sturdyref is owned here because it must outlive the
    /// call that asked. The ticket index makes settlement proportional to the
    /// callers sharing that dial. Each group stores its first row inline.
    pending_enlivens: enliven_mod.PendingEnlivenMap = .empty,
    enliven_groups: @import("enliven/group.zig").Map = .empty,
    /// Total parked rows. The map's own count is ticket groups. Keeping this
    /// scalar makes action reservation and close admission O(1).
    pending_enliven_count: usize = 0,
    /// Encode worklist: sessions with enqueued-but-unencoded outbound (a
    /// nested verb's send, a settle listener's reply). The top-level verb's
    /// unwind drives each one (`Served.driveFed`) and may then queue a
    /// `HostAction.flush` for the embedder. Distinct from the action FIFO by
    /// design: `pending_flush` is encode work and `actions.flush` is the
    /// embedder write signal.
    pending_flush: engine.ActionFifo(engine.PeerHandle) = .{},
    /// At most one host-global continuation notice may be parked in `actions`.
    /// This is distinct from per-session flush deduplication because Node work
    /// may remain with no session that can represent its wake.
    resume_action_pending: bool = false,
    /// The action-drain resume pump refused with outbound backpressure and has
    /// not seen the pressure become actionable since. While set, the drain's
    /// per-action resume pump stands down, so one unfulfillable refusal cannot
    /// re-feed the same drain pass forever: the pass runs out of actions and
    /// returns, so the embedder can reach the write, poll, or close that
    /// moves the pressure. Reset at every drain-pass
    /// entry and wherever the embedder takes outbound bytes. A refusal that
    /// persists re-latches after one bounded retry per reset.
    resume_pump_refused: bool = false,
    /// Next internal work class to inspect. Persisted across finite quanta so a
    /// continuously runnable session cannot starve Node effects or handoff
    /// notifications merely because every resumed slice restarted at lane 0.
    next_work_lane: WorkLane = .session,
    /// Application lifecycle above CapTP's own negotiating/open/closed state.
    /// The core owns admission, quiescence, and close policy. Adapters supply
    /// monotonic time and perform I/O effects.
    lifecycle: Lifecycle = .active,
    /// Finite session-close timing lives out of line so an open session pays no
    /// deadline storage. Unbounded finish and cancel need no row. The session
    /// lifecycle carries those states directly.
    session_close_timing: std.AutoHashMapUnmanaged(engine.PeerHandle, SessionCloseTiming) = .{},
    /// Node actions whose recipient could not take another outbound frame,
    /// parked per recipient so one partner's flow control holds back only what
    /// is bound for it (ADR-0145). A row enters when that recipient refuses
    /// with outbound pressure, on a queue seat reserved before the action
    /// leaves the queue, and re-enters in its original order when the embedder
    /// next takes that recipient's outbound bytes or releases its session.
    /// Out of line, so a session under no pressure pays nothing.
    parked_node_actions: std.AutoHashMapUnmanaged(engine.PeerHandle, std.ArrayListUnmanaged(engine.Node.Action)) = .{},
    /// Cached nearest finite session deadline. The timing map remains the
    /// authority. This avoids an O(n) sweep on every adapter turn.
    next_session_close_deadline_ms: ?i64 = null,
    /// The reentrancy latch: true while a top-level verb is firing callbacks
    /// or pumping. Nested verbs enqueue only, and the enclosing verb's unwind
    /// encodes and pumps. The host-driving verbs refuse `ReenteredHost`.
    in_callback: bool = false,
    /// Owning thread, latched by public admission and released only at an
    /// explicit quiescent handoff. This is runtime contract state in every
    /// build: affinity mistakes are caller refusals, never debug-only panics or
    /// unchecked release-mode data races.
    owner_tid: host_admission.OwnerThreadId = host_admission.initial_owner_thread_id,

    pub const BootstrapDurability = host_configuration.BootstrapDurability;
    pub const InitError = host_configuration.InitError;
    pub const Options = host_configuration.Options;

    pub const WorkLane = @import("host/pump/schedule.zig").WorkLane;

    const SessionCloseTiming = host_close.SessionCloseTiming;
    pub const RuntimeAdoptionError = host_ownership.RuntimeAdoptionError;
    pub const LifecyclePhase = host_close.LifecyclePhase;
    const Lifecycle = host_close.Lifecycle;
    pub const PendingWorkLease = host_admission.PendingWorkLease;
    pub const PublicationLookup = @import("publication_lookup.zig").Lookup;
    pub const PublicationFetch = @import("publication_lookup.zig").Fetch;
    pub const setPublicationLookup = @import("publication_lookup.zig").install;
    pub const clearPublicationLookup = @import("publication_lookup.zig").uninstall;

    // Whole-aggregate construction, destruction, and exclusive transfer live
    // in `host/ownership.zig`; these aliases preserve the supported Host API.
    pub const checkRuntimeAdoption = host_ownership.checkRuntimeAdoption;

    // Close policy lives in `host/close.zig`; these aliases are its Host API
    // index. Transaction steps remain private inside the owning sibling.
    pub const beginClose = host_close.beginClose;
    pub const progressClose = host_close.progressClose;
    pub const closeOutcome = host_close.closeOutcome;
    pub const beginSessionClose = host_close.beginSessionClose;
    pub const closeWaitMs = host_close.closeWaitMs;
    pub const progressSessionCloses = host_close.progressSessionCloses;
    pub const sessionCloseOutcome = host_close.sessionCloseOutcome;
    pub const sessionCloseActionDelivered = host_close.sessionCloseActionDelivered;
    pub const lifecyclePhase = host_close.lifecyclePhase;

    pub const setSessionLimits = host_configuration.setSessionLimits;
    pub const setIngressLimits = host_configuration.setIngressLimits;
    pub const releaseOnDrop = host_configuration.releaseOnDrop;
    pub const setReleaseOnDrop = host_configuration.setReleaseOnDrop;

    pub const init = host_ownership.init;
    pub const deinit = host_ownership.deinit;

    pub const deinitOutcome = host_ownership.deinitOutcome;

    pub const deinitAfterOwnershipTransfer = host_ownership.deinitAfterOwnershipTransfer;
    pub const checkReleaseOwnershipTransfer = host_ownership.checkReleaseOwnershipTransfer;

    // Transport semantics and advertised routes live in `host/transports.zig`.
    // These direct aliases preserve the supported Host configuration surface.
    pub const prepareAdvertisedLocator = host_transports.prepareAdvertisedLocator;
    pub const retainPreparedAdvertisedLocator = host_transports.retainPreparedAdvertisedLocator;
    pub const retainAdvertisedLocator = host_transports.retainAdvertisedLocator;
    pub const setAdvertisedLocator = host_transports.setAdvertisedLocator;
    pub const ensureAdvertisedLocator = host_transports.ensureAdvertisedLocator;
    pub const removeAdvertisedLocator = host_transports.removeAdvertisedLocator;
    pub const retireAdvertisedLocator = host_transports.retireAdvertisedLocator;
    pub const selectAdvertisedLocator = host_transports.selectAdvertisedLocator;
    pub const advertisedLocator = host_transports.advertisedLocator;
    pub const defineTransport = host_transports.defineTransport;
    pub const defineTransports = host_transports.defineTransports;
    pub const transportProfile = host_transports.transportProfile;
    pub const designatorScheme = host_transports.designatorScheme;
    pub const acceptableLocator = host_transports.acceptableLocator;

    // ── Byte-fed session I/O ─────────────────────────────────────────────────

    // Byte-fed session I/O lives in `host/session.zig`; these direct aliases
    // are the supported Host verbs, not a whole-module consumer export.
    pub const feed = host_session_ingress.feed;
    pub const feedBytes = host_session_ingress.feedBytes;
    pub const feedTransportPacket = host_session_ingress.feedTransportPacket;
    pub const serveEvent = host_session_ingress.serveEvent;

    // ── Application verbs ────────────────────────────────────────────────────

    // Send/tell admission, staging, and commit live in `host/delivery.zig`.
    pub const beginSendNamed = host_delivery.beginSendNamed;
    pub const beginTellNamed = host_delivery.beginTellNamed;
    pub const beginSendNamedValues = host_delivery.beginSendNamedValues;
    pub const beginTellNamedValues = host_delivery.beginTellNamedValues;

    pub const send = host_delivery.send;
    pub const queueSend = host_delivery.queueSend;
    pub const sendCapability = host_delivery.sendCapability;
    pub const queueSendCapability = host_delivery.queueSendCapability;
    pub const sendValues = host_delivery.sendValues;
    pub const sendApplicationValues = host_delivery.sendApplicationValues;
    pub const tellApplicationValues = host_delivery.tellApplicationValues;
    pub const queueSendValues = host_delivery.queueSendValues;
    pub const Call = @import("host/owned_call.zig").Call;
    pub const callCapability = @import("host/owned_call.zig").callCapability;
    pub const callLocalCapability = @import("host/local_delivery.zig").callLocalCapability;

    pub const tell = host_delivery.tell;
    pub const tellCapability = host_delivery.tellCapability;
    pub const tellValues = host_delivery.tellValues;

    pub const flushSession = host_session.flushSession;

    // Bootstrap fetch and promise observation are one transaction owner in
    // `host/observation.zig`; these aliases preserve the supported Host verbs.
    pub const fetch = host_observation.fetch;
    pub const queueFetch = host_observation.queueFetch;
    pub const listenTo = host_observation.listenTo;
    pub const queueListenTo = host_observation.queueListenTo;
    pub const CapabilityResolution = host_observation.CapabilityResolution;
    pub const resolveCapability = host_observation.resolveCapability;
    pub const listenToCapability = host_observation.listenToCapability;
    pub const queueListenToCapability = host_observation.queueListenToCapability;

    // ── The Host's responsibilities, by sibling file ─────────────────────────
    // Each group below is implemented in the named sibling and aliased here,
    // not wrapped, so a caller reads one `Host` surface and no call site pays
    // an indirection. This table is the index of the split.

    pub const setTrace = host_trace.setTrace;
    pub const replayTrace = host_trace.replayTrace;

    /// Emit the open fact for `session` once, the first time it is observed
    /// open. Called from the serve path (the accepting side opens during a
    /// feed) and from the outbound verbs (the dialing side may send before
    /// any further inbound event would notice).
    pub const traceNoteOpen = host_trace.traceNoteOpen;

    /// Emit one message fact on `session`, noting the open first so the
    /// dialing side's first outbound cannot precede its own session-open.
    /// Both fact sites sit at the wire boundary (the inbound dispatch
    /// seat and the outbound drain), so `frame` carries the wire bytes in
    /// both directions.
    pub const traceMessage = host_trace.traceMessage;

    /// Emit the close fact, only for a session whose open was reported.
    pub const traceClose = host_trace.traceClose;

    /// Session lifecycle (`sessions.zig`): mint, the dialed and accepted
    /// opens, the live-session directories, and the one teardown funnel.
    pub const openDialedLocator = sessions_mod.openDialedLocator;
    pub const openPendingDial = sessions_mod.openPendingDial;
    pub const openDialedOver = sessions_mod.openDialedOver;
    pub const openDialedOverPending = sessions_mod.openDialedOverPending;
    const openDialedKnowing = sessions_mod.openDialedKnowing;
    pub const ensureAcceptAdvertisedLocator = sessions_mod.ensureAcceptAdvertisedLocator;
    pub const openAcceptedAdvertised = sessions_mod.openAcceptedAdvertised;
    pub const openAcceptedAdvertisedOver = sessions_mod.openAcceptedAdvertisedOver;
    pub const liveSessionForDial = sessions_mod.liveSessionForDial;
    const refuseDuplicateDial = sessions_mod.refuseDuplicateDial;
    const refuseDuplicatePartnerKey = sessions_mod.refuseDuplicatePartnerKey;
    const indexPartnerKey = sessions_mod.indexPartnerKey;
    const nextSessionSeed = sessions_mod.nextSessionSeed;
    const resolveSessionSecret = sessions_mod.resolveSessionSecret;
    pub const unindexSession = sessions_mod.unindexSession;
    const liveIndexedSession = sessions_mod.liveIndexedSession;
    pub const dialedSessionFor = sessions_mod.dialedSessionFor;
    const helloAndEnroll = sessions_mod.helloAndEnroll;
    pub const releaseSession = sessions_mod.releaseSession;
    pub const sessionPublish = sessions_mod.publish;
    pub const sessionPublishHosted = sessions_mod.publishHosted;
    pub const spawn = sessions_mod.spawn;
    pub const spawnHosted = sessions_mod.spawnHosted;
    pub const cancelSessionIngress = sessions_mod.cancelSessionIngress;
    const condemnRemainingSessions = sessions_mod.condemnRemainingSessions;
    const RoleSpec = sessions_mod.RoleSpec;
    const mint = sessions_mod.mint;
    const mintOver = sessions_mod.mintOver;
    const negotiatingOptions = sessions_mod.negotiatingOptions;
    const mintShell = sessions_mod.mintShell;
    const enroll = sessions_mod.enroll;
    pub const finishSessionOpen = sessions_mod.finishSessionOpen;
    const freeSessionShell = sessions_mod.freeSessionShell;
    const failOpen = sessions_mod.failOpen;

    /// Host vows and resolver pairs: `vows.zig` owns their operations.
    /// `vows/settlement.zig` owns their terminal transition.
    const VowRow = vow_settlement.VowRow;
    const ResolverIndexEntry = vows_mod.ResolverIndexEntry;
    pub const vowOn = vows_mod.vowOn;
    pub const vowSession = vows_mod.vowSession;
    pub const pendingVowCount = vows_mod.pendingVowCount;
    pub const vowRelease = vow_release.release;
    pub const deferTurn = vow_resolvers.deferTurn;
    pub const resolverFulfill = vow_resolvers.fulfill;
    pub const resolverFulfillValue = vow_resolvers.fulfillValue;
    pub const resolverBreak = vow_resolvers.breakVow;
    pub const resolverReject = vow_resolvers.reject;
    pub const resolverAbandon = vow_resolvers.abandon;
    pub const vowSend = vows_mod.vowSend;
    pub const queueVowSend = vows_mod.queueVowSend;
    pub const vowSendValues = vows_mod.vowSendValues;
    pub const queueVowSendValues = vows_mod.queueVowSendValues;
    pub const vowTellValues = vows_mod.vowTellValues;
    pub const vowIndex = vows_mod.vowIndex;
    pub const vowUntag = vows_mod.vowUntag;
    pub const vowGet = vows_mod.vowGet;
    const reserveVow = vows_mod.reserveVow;
    pub const reserveVowAt = vows_mod.reserveVowAt;
    pub const cancelVowReservation = vows_mod.cancelVowReservation;
    pub const mintDeferredVow = vows_mod.mintDeferredVow;
    pub const moveDeferredVow = vows_mod.moveDeferredVow;
    pub const attachDeferredVow = vows_mod.attachDeferredVow;
    const commitVow = vows_mod.commitVow;
    pub const commitVowWithListener = vows_mod.commitVowWithListener;
    pub const fireVow = vow_settlement.fireVow;

    /// Publication (`publish.zig`): the Host and durable name registries
    /// and the resolver a fetch consults.
    pub const DurableSwiss = publish_mod.DurableSwiss;
    pub const publish = publish_mod.publish;
    pub const publishHosted = publish_mod.publishHosted;
    pub const unpublish = publish_mod.unpublish;
    pub const publishDurable = publish_mod.publishDurable;
    pub const publishHostedDurable = publish_mod.publishHostedDurable;
    pub const publishDurableCapability = publish_mod.publishDurableCapability;
    pub const DurableReservation = publish_mod.DurableReservation;
    pub const reserveDurableCapability = publish_mod.reserveDurableCapability;
    pub const removeDurable = publish_mod.removeDurable;
    pub const durableProvenance = publish_mod.durableProvenance;
    pub const publishedPosition = publish_mod.publishedPosition;
    pub const publishedCapability = publish_mod.publishedCapability;

    /// The action queue (`host/action.zig`): the payload shapes and the
    /// borrowed/owned pops over the Host-owned FIFO.
    pub const nextAction = host_action.nextAction;
    pub const hasRunnableWork = host_action.hasRunnableWork;
    pub const retryBorrowedAction = host_action.retryBorrowedAction;
    pub const peekAction = host_action.peekAction;
    pub const takeAction = host_action.takeAction;
    pub const freeAction = host_action.freeAdopted;
    pub const reserveActions = host_action.reserveActions;

    /// Third-party handoff (`handoff.zig`): the node-service callbacks, the
    /// embedder's dial-ticket seam, and the give verbs.
    pub const pendingDial = handoff_mod.pendingDial;
    pub const exporterDialed = handoff_mod.exporterDialed;
    pub const completeSelectedExporter = handoff_mod.completeSelectedExporter;
    pub const dialFailed = handoff_mod.dialFailed;
    pub const dialCancelled = handoff_mod.dialCancelled;
    pub const provideGiftId = handoff_mod.provideGiftId;
    pub const giftIdFailed = handoff_mod.giftIdFailed;
    pub const acceptGive = handoff_mod.acceptGive;
    pub const acceptInlineGive = handoff_mod.acceptInlineGive;
    pub const setExporterLocation = handoff_mod.setExporterLocation;

    /// Sturdyref enlivenment (`enliven.zig`): a complete sturdyref becomes a
    /// live capability, selecting a session or staging a dial.
    pub const enliven = enliven_mod.enliven;
    pub const Enliven = enliven_mod.Enliven;
    pub const enlivenCapability = enliven_mod.enlivenCapability;
    pub const enlivenSessionUri = enliven_mod.enlivenSessionUri;
    pub const enlivenSelectOrDial = enliven_mod.enlivenSelectOrDial;
    pub const authenticatedSessionForKey = enliven_mod.authenticatedSessionForKey;
    pub const enlivenUri = enliven_mod.enlivenUri;
    pub const enlivenUriForVersion = enliven_mod.enlivenUriForVersion;
    pub const enlivenWithPolicy = enliven_mod.enlivenWithPolicy;
    const matchSturdyrefPeer = enliven_mod.matchSturdyrefPeer;
    const freeParkedEnliven = enliven_mod.freeParkedEnliven;
    const failParkedEnliven = enliven_mod.failParkedEnliven;
    const continueParkedEnliven = enliven_mod.continueParkedEnliven;
    const settleParkedEnlivens = enliven_mod.settleParkedEnlivens;
    const cancelParkedEnlivens = enliven_mod.cancelParkedEnlivens;

    /// Connection-facing session control stays with the byte-fed shell owner.
    pub const breakFarVows = host_session.breakFarVows;
    pub const transportClosed = host_session.transportClosed;

    pub const partnerIdentity = host_session.partnerIdentity;

    pub const bindVerifiedChannelKey = host_session.bindVerifiedChannelKey;

    // ── The pump ─────────────────────────────────────────────────────────────

    // Thread ownership, callback exclusion, and operation admission live in
    // `host/admission.zig`; private aliases are sibling implementation seams,
    // while `assertOwner` remains public only for Host-core siblings.
    pub const assertOwner = host_admission.assertOwner;
    pub const releaseDriverOwnership = host_admission.releaseDriverOwnership;
    const claimOwner = host_admission.claimOwner;
    const checkOwnerIfClaimed = host_admission.checkOwnerIfClaimed;
    const admitConfigurationMutation = host_admission.admitConfigurationMutation;
    pub const refuseReentry = host_admission.refuseReentry;
    pub const withinCallback = host_admission.withinCallback;
    pub const checkLive = host_admission.checkLive;
    pub const checkSession = host_admission.checkSession;
    pub const checkOutboundAdmission = host_admission.checkOutboundAdmission;
    pub const admitSessionOperation = host_admission.admitSessionOperation;
    pub const beginSessionOperation = host_admission.beginSessionOperation;
    pub const finishSessionOperation = host_admission.finishSessionOperation;
    pub const admitPendingWork = host_admission.admitPendingWork;
    pub const sendLocalValues = @import("host/local_completion.zig").send;
    const beginOperation = host_admission.beginOperation;
    const finishOperation = host_admission.finishOperation;
    pub const admitApplicationOperation = host_admission.admitApplicationOperation;
    pub const checkOwnedSession = host_admission.checkOwnedSession;
    pub const sessionForPeer = host_admission.sessionForPeer;
    // `host/capabilities/identity.zig` owns Host capability observation; this
    // direct-alias table is the Host API index. The Registry stays
    // the independent data owner in `capability.zig`.
    pub const CapabilityLift = host_capability_identity.CapabilityLift;
    pub const liftCapabilityTracked = host_capability_identity.liftCapabilityTracked;
    pub const liftCapability = host_capability_identity.liftCapability;
    pub const commitCapabilityLift = host_capability_identity.commitCapabilityLift;
    pub const retainLocalCapability = host_capability_identity.retainLocalCapability;
    pub const liftLocalActor = host_capability_identity.liftLocalActor;
    pub const rollbackCapabilityLift = host_capability_identity.rollbackCapabilityLift;
    pub const discardCapabilityObservation = host_capability_identity.discardCapabilityObservation;
    pub const reserveFreshCapability = host_capability_identity.reserveFreshCapability;
    pub const retainReservedLocalCapability = host_capability_identity.retainReservedLocalCapability;
    pub const adoptReservedLocalCapability = host_capability_identity.adoptReservedLocalCapability;
    pub const capabilityFromRaw = host_capability_identity.capabilityFromRaw;
    pub const settledCapability = host_capability_identity.settledCapability;
    pub const localActorFor = host_capability_identity.localActorFor;
    pub const capabilitySession = host_capability_identity.capabilitySession;
    pub const releaseCapability = host_capability_identity.releaseCapability;
    pub const releaseCapabilityTerminal = host_capability_identity.releaseCapabilityTerminal;

    // Application Value/capability lowering and its retained staging transaction.
    pub const PreparedValues = host_capability_lower.PreparedValues;
    pub const StagedCapabilityRetain = host_capability_lower.StagedCapabilityRetain;
    pub const retainValueCapabilities = host_capability_lower.retainValueCapabilities;
    pub const releaseUntransferredCapabilityRetains = host_capability_lower.releaseUntransferredCapabilityRetains;
    const releaseValueCapabilitiesTerminalAt = host_capability_lower.releaseValueCapabilitiesTerminalAt;
    const beginOutboundStagingLeases = host_capability_lower.beginOutboundStagingLeases;
    const finishOutboundStagingLeases = host_capability_lower.finishOutboundStagingLeases;
    pub const servedSendWithStaging = host_capability_lower.servedSendWithStaging;
    pub const servedTellWithStaging = host_capability_lower.servedTellWithStaging;
    pub const PreparedCapability = host_capability_lower.PreparedCapability;
    pub const lowerCapability = host_capability_lower.lowerCapability;
    pub const prepareCapability = host_capability_lower.prepareCapability;
    pub const lowerValue = host_capability_lower.lowerValue;
    pub const lowerValues = host_capability_lower.lowerValues;
    pub const prepareValues = host_capability_lower.prepareValues;

    // Inbound Host policy lives in `host/interception.zig`; this direct alias
    // preserves the supported verb without exporting the internal module.
    pub const interceptFulfilledReference = host_interception.interceptFulfilledReference;

    // Session Argument/completion lifting and complete failed-projection retirement.
    pub const liftValue = host_capability_lift.liftValue;
    pub const discardValueObservation = host_capability_lift.discardValueObservation;
    pub const projectValue = host_capability_lift.projectValue;
    pub const projectValues = host_capability_lift.projectValues;
    pub const ProjectedCompletion = @import("host/capabilities/completion.zig").ProjectedCompletion;
    pub const projectCompletion = @import("host/capabilities/completion.zig").projectCompletion;
    /// Project a stable owned result with independent occurrence retains.
    /// Refusal rolls back those grants without changing the result owner.
    pub const projectOwnedValue = @import("host/capabilities/completion.zig").projectOwnedValue;
    pub const liftValues = host_capability_lift.liftValues;

    // Raw/opaque target routing and the bounded foreign-Argument policy.
    pub const RoutedSend = host_capability_routing.RoutedSend;
    pub const routeSend = host_capability_routing.routeSend;
    pub const routeCapability = host_capability_routing.routeCapability;
    pub const routeTurnTarget = host_capability_routing.routeTurnTarget;
    pub const routeTurnCapability = host_capability_routing.routeTurnCapability;

    // ── Inbound interception ─────────────────────────────────────────────────

    pub const hostBeforeServe = host_interception.hostBeforeServe;

    pub const hostResolveInterceptor = host_interception.hostResolveInterceptor;
};

pub const HostTurn = host_hosting.HostTurn;
pub const Hosting = host_hosting.Hosting;
