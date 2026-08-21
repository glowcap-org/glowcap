//! The sans-io byte-fed multi-session CapTP host core (ADR-0072), under the
//! `driver_core` I/O ban. A `Host` owns one `engine.Node` (identity,
//! live-session directory, routing, the redeem serve step) and mints byte-fed
//! sessions (`HostSession`) whose peers are node-registered, so
//! everything the node decides — where a capability route leads, which exporter a give
//! withdraws from, when a served reply becomes a signed give — happens under
//! every session the host holds, with no socket in sight. The embedder owns
//! the loop, the sockets, and the entropy: it feeds inbound packets with
//! `feedTransportPacket`, or lower-level bytes with `feed` (a bare whole
//! frame), `feedBytes` (outer-framed byte-stream chunks), or `serveEvent`
//! (one already-polled event, the completion-loop hook), drains outbound
//! packets with `HostSession.takeTransportOutbound`, and answers the host's
//! action queue (`nextAction`) — dial requests, flush notices, close signals
//! for a condemned session, gift-id entropy requests — with
//! `exporterDialed` / `dialFailed` / `provideGiftId`. Settlements ride the
//! same queue: a vow with no in-process listener settles as an owned
//! `settled`/`failed` completion the embedder routes by vow id, so one drain
//! hears every outcome. An in-process Zig consumer may instead register a
//! borrowed one-shot listener with `vowOn`, which keeps that vow's settlement
//! zero-copy and off the queue. The `driver.Bridge` is one such embedder (a
//! completion loop over this core, ADR-0076); the C ABI's `libpancake_host`
//! is another (byte-fed from a binding-owned loop).
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
const host_pump = @import("host/pump.zig");
const host_trace = @import("host/trace.zig");
const enliven_mod = @import("enliven.zig");
const vows_mod = @import("vows.zig");
const sessions_mod = @import("sessions.zig");
const handoff_mod = @import("handoff.zig");
const capability_promise = @import("capability_promise.zig");
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
pub const session_seed_domain = "pancake session-key v1";

pub const PeerProvenance = enum { verified, dial_target, assertion_only };

/// Enlivenment lives in `enliven.zig`; its vocabulary is named here because
/// this is the file every consumer of the host core reads first.
pub const EnlivenPeerPolicy = enliven_mod.EnlivenPeerPolicy;
pub const EnlivenStart = enliven_mod.EnlivenStart;

/// The far reference `arg` names, or null when `arg` is not a plain far
/// capability — a break, a promise, a near, or a non-reference value. The one
/// unwrap of the `reference → far` shape the foreign-proxy, enroll, and enliven
/// paths each read off a fulfilled resolution.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn asFarRef(arg: model.Argument) ?@FieldType(model.Reference, "far") {
    if (arg != .reference or arg.reference != .far) return null;
    return arg.reference.far;
}

// The session wire owns the shell and byte ingress/egress. These direct aliases
// preserve the supported core surface without exporting its internal module.
pub const HostSession = host_session.HostSession;
pub const host_session_struct_budget_bytes = host_session.host_session_struct_budget_bytes;

/// The Vat-local id carried by `ref`. `pub` only for Host-core siblings: the
/// total result keeps general `actors.Ref` inputs from becoming an implicit
/// local-only precondition at a public Host verb.
pub fn localActorId(ref: actors.Ref) actors.Error!u64 {
    return switch (ref) {
        .local => |id| id,
        .far => actors.Error.NotLocal,
    };
}

pub const DialTarget = crossed_hellos.DialTarget;

/// One identity, one node, many byte-fed CapTP sessions — the sans-io host
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
    /// counter; Host close reads this O(1) authority instead of rescanning live
    /// sessions or adapter-owned operation rows on every progress turn.
    pending_operations: usize = 0,
    /// Canonical application identities for capabilities lifted out of any
    /// session. Wire positions remain owned by their session; this table keeps
    /// the owning peer beside the target and rejects stale generations.
    capabilities: capability.Registry = .{},
    /// Inline handoff promises. Rows exist only while redemption is pending or
    /// while their opaque capability identity remains live.
    capability_promises: std.AutoHashMapUnmanaged(capability.PromiseId, capability_promise.Row) = .empty,
    next_capability_promise: u64 = 1,
    /// Incarnation stamp for remote import rows first lifted into Host space.
    /// Monotonic for the Host lifetime; zero is never issued.
    next_import_incarnation: u64 = 1,
    /// Crossed-hellos tiebreak state (ADR-0030): `openDialedLocator` registers
    /// the outbound before its hello moves; accepted CapTP sessions compare
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
    /// of the two peer directories, and deliberately not the same one
    /// (ADR-0097). `partner_by_side` names a session *incarnation* through the
    /// key that signed it, which is what a handoff certificate must resolve
    /// against; this names the durable peer a locator designates, which is
    /// what "do I already have a session reaching P" must ask. They differ by
    /// construction: every session has a fresh signing key, while the
    /// durable peer key is stable across connections. Routing dial dedup
    /// through the side index would therefore miss the existing peer.
    ///
    /// Only an authenticated durable identity is indexed
    /// (`vocab.DurableProvenance`): an unproved claim as a dial-match key is
    /// exactly the squatting hazard `liveSessionForDial` refuses.
    ///
    /// Keyed by the durable key's own 32 bytes rather than its hex encoding,
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
    /// borrow `model.transport.Known`'s static symbol; extension keys are
    /// Host-owned copies. One row per symbol makes routing authority unique;
    /// designation, dial planning, and sealed-channel composition all read the
    /// same value.
    transport_profiles: std.StringHashMapUnmanaged(model.transport.Metadata) = .empty,
    /// Host-wide bootstrap aliases. A fetch performs one keyed discovery lookup
    /// and lazily projects the actor onto the requesting Port.
    giftables: std.StringHashMapUnmanaged(publish_mod.Publication) = .empty,
    /// The embedder-facing action FIFO; `nextAction` drains it.
    actions: engine.ActionFifo(HostAction) = .{},
    /// The most recently popped action; its byte views stay valid until the
    /// next `nextAction`, which frees them.
    last_action: ?HostAction = null,
    /// A C convenience-pump arm refused before committing its effect. The
    /// borrowed action remains `last_action` and must be projected again before
    /// any later FIFO row; keeping the retry here preserves action order and
    /// payload ownership without a second queue representation.
    retry_last_action: bool = false,
    /// The live trace tap (`trace.zig`), or null. Installed by the embedder
    /// through `setTrace` / the C `pancake_host_set_trace`; with none every
    /// emit site is one null check.
    trace_sink: ?trace.Sink = null,

    /// Host vow id to its heap row (the row's address is the retire
    /// listener's stable ctx; the map may rehash). A row lives exactly until
    /// its vow settles: the reserve/commit transaction installs the listener, the
    /// fire removes and frees the row, and a later verb on the id refuses
    /// `NoSuchVow` — so the map is bounded by unsettled vows, not by every
    /// vow ever minted.
    vows: std.AutoHashMapUnmanaged(u64, *VowRow) = .{},
    next_vow: u64 = 1,
    /// Host resolver id → its session-less vow row and the vat resolver it
    /// settles (ADR-0102). A row is consumed by the first settle attempt, so
    /// the map holds exactly the live settle authorities; freed with the
    /// host. Ids are host-scoped, from their own counter, and never reused.
    resolver_index: std.AutoHashMapUnmanaged(u64, ResolverIndexEntry) = .{},
    next_resolver: u64 = 1,
    /// Enlivens waiting on a dial this host staged (`enlivenSelectOrDial`,
    /// ADR-0098). Each row holds the vow id minted for the caller *before*
    /// any session exists, so the outcome reaches an embedder that only
    /// drains actions; the sturdyref is owned here because it must outlive the
    /// call that asked. A flat list, scanned when a dial settles: it is
    /// bounded by the application's own outstanding select-or-dial enlivens,
    /// and several may legitimately ride one ticket (the node joins dials by
    /// identity), so a map keyed by ticket would hold lists anyway.
    pending_enlivens: std.ArrayListUnmanaged(enliven_mod.PendingEnliven) = .empty,
    /// Encode worklist: sessions with enqueued-but-unencoded outbound (a
    /// nested verb's send, a settle listener's reply). The top-level verb's
    /// unwind drives each one (`Served.driveFed`) and may then queue a
    /// `HostAction.flush` for the embedder. Distinct from the action FIFO by
    /// design — `pending_flush` is encode work; `actions.flush` is the
    /// embedder write signal.
    pending_flush: engine.ActionFifo(engine.PeerHandle) = .{},
    /// At most one host-global continuation notice may be parked in `actions`.
    /// This is distinct from per-session flush deduplication because Node work
    /// may remain with no session that can represent its wake.
    resume_action_pending: bool = false,
    /// Next internal work class to inspect. Persisted across finite quanta so a
    /// continuously runnable session cannot starve Node effects or handoff
    /// notifications merely because every resumed slice restarted at lane 0.
    next_work_lane: WorkLane = .session,
    /// Application lifecycle above CapTP's own negotiating/open/closed state.
    /// The core owns admission, quiescence, and close policy; adapters supply
    /// monotonic time and perform I/O effects.
    lifecycle: Lifecycle = .active,
    /// Finite session-close timing lives out of line so an open session pays no
    /// deadline storage. Unbounded finish and cancel need no row; the session
    /// lifecycle carries those states directly.
    session_close_timing: std.AutoHashMapUnmanaged(engine.PeerHandle, SessionCloseTiming) = .{},
    /// Cached nearest finite session deadline. The timing map remains the
    /// authority; this avoids an O(n) sweep on every adapter turn.
    next_session_close_deadline_ms: ?i64 = null,
    /// The reentrancy latch: true while a top-level verb is firing callbacks
    /// or pumping. Nested verbs enqueue only — the enclosing verb's unwind
    /// encodes and pumps — and the host-driving verbs refuse `ReenteredHost`.
    in_callback: bool = false,
    /// Owning thread, latched by public admission and released only at an
    /// explicit quiescent handoff. This is runtime contract state in every
    /// build: affinity mistakes are caller refusals, never debug-only panics or
    /// unchecked release-mode data races.
    owner_tid: host_admission.OwnerThreadId = host_admission.initial_owner_thread_id,

    pub const BootstrapDurability = host_configuration.BootstrapDurability;
    pub const InitError = host_configuration.InitError;
    pub const Options = host_configuration.Options;

    pub const WorkLane = enum(u2) {
        session,
        node,
        handoff,

        pub fn next(self: WorkLane) WorkLane {
            return switch (self) {
                .session => .node,
                .node => .handoff,
                .handoff => .session,
            };
        }
    };

    const SessionCloseTiming = host_close.SessionCloseTiming;
    pub const RuntimeAdoptionError = host_ownership.RuntimeAdoptionError;
    pub const LifecyclePhase = host_close.LifecyclePhase;
    const Lifecycle = host_close.Lifecycle;
    pub const PendingWorkLease = host_admission.PendingWorkLease;

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
    pub const queueSendValues = host_delivery.queueSendValues;

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
    pub const listenToCapability = host_observation.listenToCapability;
    pub const queueListenToCapability = host_observation.queueListenToCapability;

    // ── The Host's responsibilities, by sibling file ─────────────────────────
    // Each group below is implemented in the named sibling and aliased here,
    // not wrapped, so a caller reads one `Host` surface and no call site pays
    // an indirection. This table is the index of the split.

    pub const setTrace = host_trace.setTrace;

    /// Emit the open fact for `session` once, the first time it is observed
    /// open. Called from the serve path (the accepting side opens during a
    /// feed) and from the outbound verbs (the dialing side may send before
    /// any further inbound event would notice).
    pub const traceNoteOpen = host_trace.traceNoteOpen;

    /// Emit one message fact on `session`, noting the open first so the
    /// dialing side's first outbound cannot precede its own session-open.
    /// Both fact sites sit at the wire boundary — the inbound dispatch
    /// seat and the outbound drain — so `frame` carries the wire bytes in
    /// both directions.
    pub const traceMessage = host_trace.traceMessage;

    /// Emit the close fact, only for a session whose open was reported.
    pub const traceClose = host_trace.traceClose;

    /// Session lifecycle (`sessions.zig`): mint, the dialed and accepted
    /// opens, the live-session directories, and the one teardown funnel.
    pub const openDialedLocator = sessions_mod.openDialedLocator;
    pub const openPendingDial = sessions_mod.openPendingDial;
    pub const openDialedOver = sessions_mod.openDialedOver;
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
    const indexDurablePeer = sessions_mod.indexDurablePeer;
    pub const unindexSession = sessions_mod.unindexSession;
    const liveIndexedSession = sessions_mod.liveIndexedSession;
    pub const dialedSessionFor = sessions_mod.dialedSessionFor;
    const helloAndEnroll = sessions_mod.helloAndEnroll;
    pub const releaseSession = sessions_mod.releaseSession;
    pub const publish = sessions_mod.publish;
    pub const publishHosted = sessions_mod.publishHosted;
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

    /// Host vows and resolver pairs (`vows.zig`): the read side every
    /// asynchronous verb returns, and the settle machinery behind it.
    const VowRow = vows_mod.VowRow;
    const ResolverIndexEntry = vows_mod.ResolverIndexEntry;
    pub const vowOn = vows_mod.vowOn;
    pub const vowSession = vows_mod.vowSession;
    pub const deferTurn = vows_mod.deferTurn;
    pub const resolverFulfill = vows_mod.resolverFulfill;
    pub const resolverBreak = vows_mod.resolverBreak;
    pub const vowSend = vows_mod.vowSend;
    pub const queueVowSend = vows_mod.queueVowSend;
    pub const vowSendValues = vows_mod.vowSendValues;
    pub const queueVowSendValues = vows_mod.queueVowSendValues;
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
    pub const fireVow = vows_mod.fireVow;

    /// Publication (`publish.zig`): the giftable and durable name registries
    /// and the resolver a fetch consults.
    pub const DurableSwiss = publish_mod.DurableSwiss;
    pub const publishGiftable = publish_mod.publishGiftable;
    pub const publishHostedGiftable = publish_mod.publishHostedGiftable;
    pub const unpublish = publish_mod.unpublish;
    pub const publishDurable = publish_mod.publishDurable;
    pub const publishHostedDurable = publish_mod.publishHostedDurable;
    pub const removeDurable = publish_mod.removeDurable;
    pub const durableProvenance = publish_mod.durableProvenance;
    pub const publishedPosition = publish_mod.publishedPosition;
    pub const publishedCapability = publish_mod.publishedCapability;

    /// The action queue (`host/action.zig`): the payload shapes and the
    /// borrowed/owned pops over the Host-owned FIFO.
    pub const nextAction = host_action.nextAction;
    pub const retryBorrowedAction = host_action.retryBorrowedAction;
    pub const peekAction = host_action.peekAction;
    pub const takeAction = host_action.takeAction;
    pub const freeAction = host_action.freeAdopted;
    pub const reserveActions = host_action.reserveActions;

    /// Third-party handoff (`handoff.zig`): the node-service callbacks, the
    /// embedder's dial-ticket seam, and the give verbs.
    pub const pendingDial = handoff_mod.pendingDial;
    pub const exporterDialed = handoff_mod.exporterDialed;
    pub const dialFailed = handoff_mod.dialFailed;
    pub const dialCancelled = handoff_mod.dialCancelled;
    pub const provideGiftId = handoff_mod.provideGiftId;
    pub const giftIdFailed = handoff_mod.giftIdFailed;
    pub const acceptGive = handoff_mod.acceptGive;
    pub const setExporterLocation = handoff_mod.setExporterLocation;

    /// Sturdyref enlivenment (`enliven.zig`): a complete sturdyref becomes a
    /// live capability, selecting a session or staging a dial.
    pub const enliven = enliven_mod.enliven;
    pub const enlivenSessionUri = enliven_mod.enlivenSessionUri;
    pub const enlivenSelectOrDial = enliven_mod.enlivenSelectOrDial;
    pub const enlivenUri = enliven_mod.enlivenUri;
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
    const beginOperation = host_admission.beginOperation;
    const finishOperation = host_admission.finishOperation;
    pub const admitApplicationOperation = host_admission.admitApplicationOperation;
    pub const checkOwnedSession = host_admission.checkOwnedSession;
    pub const sessionForPeer = host_admission.sessionForPeer;
    // `host/capabilities/identity.zig` owns Host capability observation; this
    // direct-alias table is the deliberate Host API index. The Registry stays
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
    pub const projectValue = host_capability_lift.projectValue;
    pub const projectValues = host_capability_lift.projectValues;
    pub const ProjectedCompletion = host_capability_lift.ProjectedCompletion;
    pub const projectCompletion = host_capability_lift.projectCompletion;
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
