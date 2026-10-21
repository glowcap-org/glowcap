//! The `Peer` you hold, and the loop that drives it. Synchronous, no I/O.
//!
//! We call this the engine, not the runtime, and that difference is the whole
//! point. glowcap has no runtime in the usual sense: no scheduler, no background
//! tasks, no ambient executor driving things behind your back. The engine is the
//! explicit, synchronous alternative, you feed it frames, you call `step`, you
//! drain and poll. When the project's values say "no hidden runtime", this layer
//! is what they mean stays absent.
//!
//! A `Peer` is the engine object an adapter hangs onto. It owns a `Session`,
//! keeps one queue of inbound frames and one of outbound messages, and surfaces
//! events for your application to handle. It does no I/O and runs no scheduler of
//! its own. You drive it: feed it frames with `feedOwned` or `recvBorrowed`,
//! call `step` to turn queued work into wire bytes, drain `outbound`, and poll for
//! events. Everything that touches the outside world lives above this layer.

const std = @import("std");
const builtin = @import("builtin");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

pub const abort_projection = @import("abort_projection.zig");
const abort_info = @import("abort_info.zig");
pub const AbortInfo = abort_info.AbortInfo;
pub const bootstrap = @import("bootstrap.zig");
pub const cross_peer = @import("cross_peer.zig");
pub const events = @import("events.zig");
pub const fetch = @import("fetch.zig");
pub const handoff_gifter = @import("handoff_gifter.zig");
const hello = @import("hello.zig");
pub const handoff_recipient = @import("handoff_recipient.zig");
pub const handoff_names = @import("handoff_names.zig");
/// Asking the partner how a promise we hold settles (CapTP `op:listen`), the
/// recipient half of a relayed resolution (ADR-0003).
pub const listen = @import("listen.zig");
/// Lowering node-local foreign-import tokens to their wire reference at the
/// outbound chokepoint (ADR-0026). A node hands the application synthetic far
/// tokens. The peer swaps each back to its wire reference in `send`, so a token
/// never leaks onto the wire.
pub const lower = @import("lower.zig");
pub const node_services = @import("node_services.zig");
/// A reference could not be lowered to a wire name on the connection it is being
/// emitted on, re-exported so a `send` caller can catch it.
pub const LoweringError = node_services.LoweringError;
/// The per-peer composition link a `Node` installs at registration.
pub const NodeServices = node_services.NodeServices;
pub const negotiation = @import("negotiation.zig");
const outbound = @import("outbound.zig");
const node = @import("node.zig");
const passable = @import("node/passable.zig");
const peer_queue = @import("peer/queue.zig");
const peer_identity = @import("peer/identity.zig");
const peer_lifecycle = @import("peer/lifecycle.zig");
const peer_outbound = @import("peer/outbound.zig");
const peer_provisional = @import("peer/provisional.zig");
const peer_drive = @import("peer/drive.zig");
const peer_failures = @import("peer/failures.zig");
const peer_handoffs = @import("peer/handoffs.zig");
const peer_references = @import("peer/references.zig");
const peer_send = @import("peer/send.zig");
const peer_session = @import("peer/session.zig");
/// The sans-io cross-connection handoff router (ADR-0026): a tier above the
/// per-connection `Peer` that owns the retained node identity, live-session
/// directory, and redeemed-token / foreign-home routing that makes
/// three-party handoff transparent. It lives in the engine core (not the
/// I/O-bearing driver) because it is pure routing data, so the sans-io C ABI and
/// native callers reach it without dragging in a transport.
pub const Node = node.Node;
const fifo = @import("fifo.zig");
/// The head-indexed FIFO spine shared by the peer's queues and the action
/// queues, so their compaction and reclaim rules cannot drift apart.
pub const ActionFifo = fifo.ActionFifo;
/// Narrow white-box support for engine tests. Empty in production builds so
/// fixture constructors and budget constants never become library API.
pub const testing = if (builtin.is_test) struct {
    /// The queue-retention bound, exposed so a test can size a burst past it
    /// without hardcoding the production value.
    pub const queue_retain_bytes = peer_queue.steady_retain_bytes;
    /// Fixed semantic carrier charge used while a named settlement is staged.
    /// Tests consume the production type instead of mirroring its layout.
    pub const answer_settlement_staging_carrier_bytes = @sizeOf(passable.AnswerSettlement);

    /// Already-open v1.0 peer for tests that inject frames directly. Real
    /// sessions start with `Peer.initNegotiating` and authenticate
    /// `op:start-session`.
    pub fn initRawOpenPeer(allocator: std.mem.Allocator) Peer {
        return Peer.initWithSession(allocator, session.Session.initWith(allocator, .{
            .captp_version = model.CaptpVersion.v1_0,
        }));
    }
} else struct {};
/// A `Node` connection handle (ADR-0026), re-exported alongside `Node`.
pub const PeerHandle = @import("peer_handle.zig").PeerHandle;
pub const pairing = @import("pairing.zig");
pub const pipeline = @import("pipeline.zig");
/// Outbound queue carriers and encode helpers. `FireTarget` is re-exported here
/// for `pipeline` and binding docs that name `engine.FireTarget`.
pub const FireTarget = outbound.FireTarget;
pub const StoreTarget = outbound.StoreTarget;
pub const sturdyref = @import("sturdyref.zig");
pub const v1_0 = @import("v1_0.zig");

pub const PendingOutbound = peer_outbound.PendingOutbound;

pub const StepOutcome = events.StepOutcome;
pub const EventKind = events.EventKind;
pub const Event = events.Event;
pub const AnswerTarget = session.AnswerTarget;
pub const OutboundAnswerTarget = session.OutboundAnswerTarget;

/// Encode a verbatim `<ocapn-peer …>` Syrup record carrying hint entries, so a
/// gifter can name an exporter reachable only by a dial hint (an iroh exporter's
/// direct addresses). Decode materializes a structural `PeerLocator`. Redeem
/// URI projection reads that peer (`handoff_recipient.exporterLocatorUri`).
/// Surfaced here so the C ABI builds a give location without reaching past the
/// engine into the codec.
pub const encodePeerLocatorRecord = codec.signed.encodeLocatorRecord;
pub const encodePeerLocatorViewRecord = hello.encodePeerLocatorViewRecord;

/// Parse a verbatim `<ocapn-peer …>` Syrup record into an owned `PeerLocator`.
/// The matching decode of `encodePeerLocatorRecord`. The C ABI's
/// `set_exporter_location` boundary uses this so a URI (or any non-record)
/// fails loud instead of being spliced into a signed give.
pub const readLocatorOwned = codec.signed.readLocatorOwned;
pub const readLocatorView = codec.signed.readLocatorView;

/// Decode a borrowed body view from an encoded frame under the session's
/// negotiated CapTP version, the same wire projection `Event.wireView`
/// performs on an inbound frame. Surfaced so the host tier can inspect an
/// outbound frame it drained without reaching past the engine into the codec.
pub const decodeBodyView = codec.dispatch.decodeBodyForProfile;
/// Resolve the registered wire shape for a negotiated codec without exposing
/// codec internals to higher layers that already depend on the engine.
pub const frameShape = codec.dispatch.frameShape;

/// The well-known bootstrap export position every OCapN peer answers `fetch` on,
/// owned by the session and surfaced here so consumers above the engine name the
/// one authoritative value rather than re-deriving the magic `0`.
pub const bootstrap_position = session.bootstrap_position;

/// Session resource bounds. Re-exported so the driver C ABI can mirror the
/// default frame cap without a direct `session` import.
pub const SessionLimits = session.SessionLimits;

/// The reserved durable swiss namespace (ADR-0007), re-exported so the host
/// tier's durable mint and mutable-alias guards name the session's one
/// authority without a direct `session` import.
pub const durable_swiss_prefix = session.Session.durable_swiss_prefix;
pub const durable_swiss_entropy_len = session.Session.durable_swiss_entropy_len;
pub const durable_swiss_len = session.Session.durable_swiss_len;
pub const isDurableSwiss = session.Session.isDurableSwiss;

/// What a session knows about the durable identities at the other end of it
/// (ADR-0028). Two parties, so two keys: the CapTP partner this session
/// converses with, and the far end of the byte channel those bytes travel
/// over. They are the same node on a direct dial and different nodes the
/// moment a byte-transparent relay (ADR-0033) sits between them, so one field
/// could hold only one of the two facts and would be read as the other.
///
/// Every consumer asks about a designator, and each field answers for the key
/// it names and no other. That is the whole shape: a name that indexes
/// evidence carries whose namespace it belongs to, or the evidence gets read
/// against the wrong party.
pub const DurablePin = peer_identity.DurablePin;

/// What authenticated the durable identity a partner advertised (ADR-0028).
/// Derived from the evidence one session holds, never from its
/// transport symbol: same transport name, different code realizing the
/// connection, different answer. `Peer.partnerDurableProvenance` is the one
/// derivation. `driver_core.vocab.DurableProvenance` aliases this type so the
/// byte-fed tier, the trace, and the C ABI all read one verdict.
pub const DurableProvenance = peer_identity.DurableProvenance;

pub const EngineError = @import("peer/errors.zig").Error;

const Queue = peer_queue.Queue;

fn frameByteLen(frame: *const foundation.Frame) usize {
    return frame.bytes().len;
}

/// The caller-owned CapTP engine: one peer per session, no I/O, no hidden
/// scheduler. The host feeds inbound frames (`recvBorrowed` / `feedOwned`),
/// advances the peer with `step`, drains `outbound`, and reads surfaced
/// events. Everything the peer queues is allocated on its `allocator` and
/// freed in `deinit`.
pub const Peer = struct {
    allocator: std.mem.Allocator,
    session_state: session.Session,
    inbound: Queue(foundation.Frame, null),
    pending_send: Queue(PendingOutbound, null),
    /// Bytes charged to staged outbound rows. Each row stores its charge so
    /// dequeueing is O(1) and cannot accidentally re-walk a message tree.
    pending_send_bytes: usize = 0,
    /// Queue seats reserved by transactions that have not published their
    /// carrier yet. Every later reservation includes these seats when growing status-allow: pending state or quoted runtime label
    /// the backing store, so an infallible commit remains valid across a
    /// callback or other intervening producer.
    pending_send_reservations: usize = 0,
    outbound: Queue(foundation.Frame, frameByteLen),
    /// One shared ceiling for staged messages plus encoded frames. A standalone
    /// Peer is unlimited. Hosts install their explicit high-water
    /// at the negotiating seam.
    outbound_budget: usize = std.math.maxInt(usize),
    events: Queue(events.Event, null),
    /// This session's gift and handoff-count authority. A cross-session
    /// withdrawal reaches a sibling's deposits only through the live-session
    /// resolver. The Vat does not own protocol transcript state.
    gift_registry: bootstrap.gifts.GiftRegistry = .{},
    /// Inbound `withdraw-gift`s grouped by exact scheduler dependency because
    /// the deposit travels on a different session and can arrive second. The
    /// grouping makes a deposit retry only its own waits, never all 4096 rows.
    /// Each row still owns the exact verified receive and its accepted replay
    /// count. `pending_withdraw_count` is bounded by
    /// `SessionLimits.max_pending_withdraws`.
    pending_withdraws: std.AutoHashMapUnmanaged(
        node_services.HandoffDependency,
        peer_handoffs.PendingWithdrawGroup,
    ) = .empty,
    pending_withdraw_count: usize = 0,
    /// Variable bytes retained by parked receives. The fixed certificate subset
    /// lives inline. Only exact gift ids count here, and their aggregate may not
    /// exceed this session's already-configured frame cap.
    pending_withdraw_bytes: usize = 0,
    /// One exact Node wake at a time. Host consumes scheduler changes one at a
    /// time and drives this Peer before taking another, so no second queue or
    /// allocation is needed after deposit authority commits.
    pending_handoff_change: ?node_services.HandoffDependency = null,
    /// Bounds the chain of local deliveries a single resolution can trigger
    /// (a drained pipelined call resolving to a local export, whose own
    /// resolution drains more calls). Capped by `SessionLimits.max_local_deliveries`.
    local_delivery_depth: usize = 0,
    /// When set, an inbound `op:start-session` is admitted only if its location
    /// signature verifies against the claimed `session_pubkey` over the canonical
    /// `<my-location …>` bytes (ADR-0002), at the engine boundary, the session
    /// core still runs no crypto. A failure projects an
    /// `InvalidStartSessionSignature` abort and the session never opens.
    /// `initNegotiating` turns this on: a peer doing a real keyed handshake
    /// verifies the session signature over its locator claim by default.
    /// Durable locator ownership still requires matching channel provenance.
    /// The raw `init` peer leaves verification off (it
    /// never handshakes), and the stub-key in-process fixtures opt out through
    /// `NegotiatingOptions` because their handshakes carry no real signature.
    verify_partner_handshake: bool = false,
    /// A Vat turn's far sends are being held retractable (ADR-0058).
    provisional: bool = false,
    /// Guaranteed projection settlements stored without their carrier because
    /// the queue refused it. Nonzero makes `step` retry one row. The
    /// projection rows are the authority, so session teardown can leave this
    /// count high and the next scan repairs it.
    deferred_settlements: u32 = 0,
    /// What this session knows about durable identity at the other end: the
    /// target a dial named and the byte channel's far end a realizer verified.
    /// Both are installed before any partner byte is fed. Both empty is every
    /// address-transport session and every byte-fed session whose embedder
    /// proved nothing.
    ///
    /// It constrains *durable* names, never `session_pubkey`: each connection
    /// signs with its own key, so a session key is not an identity and
    /// comparing the two proves nothing.
    ///
    /// Nothing outside this file names this field. Reads go through
    /// `demandedPartnerKey`, `verifiedChannelKey`, and
    /// `partnerDurableProvenance`. Writes go through the two verbs below,
    /// so those two are the whole story. `source-check`'s
    /// `checkDurablePinWriters` holds both halves.
    durable_pin: DurablePin = .{},
    /// The typed cause of the most recent local dispatch failure, read it
    /// through `lastAbort`. Overwritten on each failure. Never reset on
    /// success, so it stays readable after the error has propagated.
    last_abort: ?AbortInfo = null,
    /// The node-installed composition link: outbound token lowering, exact
    /// local-object projection, and live gifter-session resolution. Set only
    /// for a peer registered under a `Node`. A standalone peer leaves it null.
    /// See `lower.zig`.
    node_services: ?NodeServices = null,

    pub const NegotiatingOptions = peer_lifecycle.NegotiatingOptions;
    pub const init = peer_lifecycle.init;
    pub const initNegotiating = peer_lifecycle.initNegotiating;
    pub const initNegotiatingWith = peer_lifecycle.initNegotiatingWith;
    pub const reposture = peer_lifecycle.reposture;
    pub const initWithSession = peer_lifecycle.initWithSession;
    pub const deinit = peer_lifecycle.deinit;
    pub const giftRegistry = peer_lifecycle.giftRegistry;
    pub const localObjectProjection = peer_lifecycle.localObjectProjection;
    pub const gifterSessionResolver = peer_lifecycle.gifterSessionResolver;
    pub const pendingWithdrawCount = peer_lifecycle.pendingWithdrawCount;
    pub const pendingWithdrawCapacity = peer_lifecycle.pendingWithdrawCapacity;
    pub const detachNodeServices = peer_lifecycle.detachNodeServices;

    pub const demandPartnerDurableKey = peer_identity.demandPartnerDurableKey;
    pub const bindVerifiedChannelKey = peer_identity.bindVerifiedChannelKey;
    pub const demandedPartnerKey = peer_identity.demandedPartnerKey;
    pub const verifiedChannelKey = peer_identity.verifiedChannelKey;
    pub const partnerDurableProvenance = peer_identity.partnerDurableProvenance;

    pub const PendingReservation = peer_outbound.PendingReservation;
    pub const InlinePassableStagingReservation = peer_outbound.InlinePassableStagingReservation;
    pub const PendingBatch = peer_outbound.PendingBatch;
    pub const pendingOutboundCharge = peer_outbound.pendingOutboundCharge;
    pub const reservePending = peer_outbound.reservePending;
    pub const reservePendingCharged = peer_outbound.reservePendingCharged;
    pub const reserveAnswerRelease = peer_outbound.reserveAnswerRelease;
    pub const publishAnswerRelease = peer_outbound.publishAnswerRelease;
    pub const reserveInlinePassableStaging = peer_outbound.reserveInlinePassableStaging;
    pub const cancelInlinePassableStaging = peer_outbound.cancelInlinePassableStaging;
    pub const transferInlinePassableStaging = peer_outbound.transferInlinePassableStaging;
    pub const beginPendingBatch = peer_outbound.beginPendingBatch;
    pub const ensurePendingCapacity = peer_outbound.ensurePendingCapacity;
    pub const pushPendingAssume = peer_outbound.pushPendingAssume;
    pub const cancelPendingReservation = peer_outbound.cancelPendingReservation;
    pub const transferPendingChargeToAnswerStore = peer_outbound.transferPendingChargeToAnswerStore;
    pub const takePending = peer_outbound.takePending;
    pub const popPendingBack = peer_outbound.popPendingBack;
    pub const reserveStagedRow = peer_outbound.reserveStagedRow;
    pub const canObserveAnswer = peer_outbound.canObserveAnswer;
    pub const fillStagedRow = peer_outbound.fillStagedRow;
    pub const removeStagedRow = peer_outbound.removeStagedRow;
    pub const blockedOnStaging = peer_outbound.blockedOnStaging;
    pub const stagedRowProvisional = peer_outbound.stagedRowProvisional;
    pub const withdrawQueuedListen = peer_outbound.withdrawQueuedListen;
    pub const openProvisional = peer_provisional.open;
    pub const commitProvisional = peer_provisional.commit;
    pub const retractProvisional = peer_provisional.retract;
    pub const checkOutboundWaterline = peer_outbound.checkOutboundWaterline;
    pub const admitOutboundProducer = peer_outbound.admitOutboundProducer;
    pub const ensureOutboundCapacity = peer_outbound.ensureOutboundCapacity;
    pub const queuedOutboundBytes = peer_outbound.queuedOutboundBytes;
    pub const outboundSaturated = peer_outbound.outboundSaturated;
    pub const encodedOutboundBytes = peer_outbound.encodedOutboundBytes;
    pub const hasOutbound = peer_outbound.hasOutbound;

    pub const hasEvent = peer_drive.hasEvent;
    pub const recvPacket = peer_drive.recvPacket;

    pub const send = peer_send.send;
    pub const sendPreparedFetch = peer_send.sendPreparedFetch;
    pub const sendBorrowed = peer_send.sendBorrowed;
    pub const sendFreight = peer_send.sendFreight;
    pub const encodeOutbound = peer_send.encodeOutbound;
    pub const encodeOutboundBody = peer_send.encodeOutboundBody;
    pub const sendAnswerResolutionCopying = peer_send.sendAnswerResolutionCopying;
    pub const sendAnswerTargetResolutionCopying = peer_send.sendAnswerTargetResolutionCopying;
    pub const sendAnswerTargetResolutionViewCopying = peer_send.sendAnswerTargetResolutionViewCopying;

    pub const sendWithdrawSettled = peer_handoffs.sendWithdrawSettled;
    pub const parkPendingWithdraw = peer_handoffs.parkPendingWithdraw;
    pub const peerHandleScope = peer_handoffs.peerHandleScope;
    pub const noteHandoffChange = peer_handoffs.noteHandoffChange;

    // ── The keyed hello (`hello.zig`) ────────────────────────────────────────
    // `op:start-session` assembly: hint stamping, transport canonicalization,
    // signing, the partner-knowledge seams (ADR-0042), and the profile
    // settle. `hello.zig` owns the bodies behind these aliases.
    pub const sendKeyedStartSession = hello.sendKeyedStartSession;
    pub const sendKeyedStartSessionAdvertised = hello.sendKeyedStartSessionAdvertised;
    pub const sendKeyedStartSessionExact = hello.sendKeyedStartSessionExact;
    pub const noteKnownGlowcapPartner = hello.noteKnownGlowcapPartner;
    pub const dialedLocatorIdentifiesGlowcap = hello.dialedLocatorIdentifiesGlowcap;
    pub const answerDeferredHello = hello.answerDeferredHello;
    pub const advertisedLocator = hello.advertisedLocator;
    pub const HelloHints = hello.HelloHints;
    pub const settleNegotiatedProfile = hello.settleNegotiatedProfile;

    pub const sendWithdrawGift = peer_handoffs.sendWithdrawGift;
    pub const sendDepositGift = peer_handoffs.sendDepositGift;
    pub const sendResolveHandoffGive = peer_handoffs.sendResolveHandoffGive;
    pub const settleAnswerOwned = outbound.enqueueAnswerTargetResolutionOwned;
    pub const inventoryMessage = outbound.inventoryMessage;
    pub const inventoryResolution = outbound.inventoryResolution;
    pub const certifyFreight = outbound.certifyFreight;

    pub const sessionIsOpen = peer_session.isOpen;
    pub const sessionIsClosed = peer_session.isClosed;
    pub const retireClosedSessionAuthority = peer_session.retireClosedAuthority;
    pub const closeSession = peer_session.close;
    pub const limits = peer_session.limits;
    pub const codecId = peer_session.codecId;
    pub const inboundCodec = peer_session.inboundCodec;
    pub const inboundProfile = peer_session.inboundProfile;
    pub const partnerSessionKey = peer_session.partnerSessionKey;
    pub const partnerLocatorRaw = peer_session.partnerLocatorRaw;

    pub const registerBootstrapCap = peer_references.registerBootstrapCap;
    pub const exportObject = peer_references.exportObject;
    pub const reserveExport = peer_references.reserveExport;
    pub const exportNextObject = peer_references.exportNextObject;
    pub const importObject = peer_references.importObject;
    pub const allocateAnswer = peer_references.allocateAnswer;
    pub const finishPendingEnliven = peer_references.finishPendingEnliven;

    pub const settleAnswerTargetGuaranteed = outbound.settleAnswerTargetGuaranteed;
    pub const breakAnswerTargetGuaranteed = outbound.breakAnswerTargetGuaranteed;

    pub const feedOwned = peer_drive.feedOwned;
    pub const step = peer_drive.step;
    pub const stepToIdle = peer_drive.stepToIdle;
    pub const flushAnswerReleases = peer_drive.flushAnswerReleases;
    pub const holdsAnswerReleases = @import("outbound/drain.zig").holdsAnswerReleases;

    pub const emitFailure = peer_failures.emitFailure;
    pub const lastAbort = peer_failures.lastAbort;
    pub const recordFailure = peer_failures.recordFailure;
    pub const recordFailureChain = peer_failures.recordFailureChain;
    pub const recordAbortDeliveryFailure = peer_failures.recordAbortDeliveryFailure;
    pub const recordSecondaryFailure = peer_failures.recordSecondaryFailure;

    pub const pushEncoded = peer_send.pushEncoded;
    pub const pushEncodedFromPending = peer_send.pushEncodedFromPending;
    pub const pushEncodedPairFromPending = peer_send.pushEncodedPairFromPending;
    pub const commitAbortOutbound = peer_send.commitAbortOutbound;
    pub const takeOutbound = peer_send.takeOutbound;

    pub const recvBorrowed = peer_drive.recvBorrowed;
    pub const pollEvent = peer_drive.pollEvent;
};

/// The per-session inline footprint budget, held by the compiler.
///
/// A `Peer` is what one CapTP session costs before it touches the heap, and the
/// 500k-connection destination treats that cost as a budget: a field added here
/// is a withdrawal from it. `test/engine/footprint_budget_test.zig` holds the
/// runtime half, the heap a warmed session grows. Crossing this ceiling is not
/// a build failure to route around. It is a design event that raises the
/// budget here with the bytes justified.
///
/// Three deliberate purchases sit in the struct:
///
/// - The end of the session's export range (8 bytes). The allocator is monotonic
///   and counts positions ever minted rather than live ones, so without a far
///   end a long-lived session that mints and releases walks into the next
///   session's range and silently starts naming its objects, the whole hazard
///   the ranges exist to remove. The word buys a typed refusal instead.
/// - The import table's enrolled-token side (8 bytes), one word for a map that
///   is only allocated once a session enrolls a capability under a node-unique
///   token (ADR-0026). Most sessions never do, so the ordinary session pays the
///   word and nothing else. It lives on the import row rather than in a
///   node-side memo so it is forgotten when the import is released. A token
///   that outlived its row would name whatever capability the partner put at
///   that position next.
/// - The low end of the session's export range (8 bytes). The high end alone
///   stops the allocator being dragged past the range. It says nothing about a
///   position from *below* the range, which names an object this session does
///   not host just as surely. A name used in a namespace that is not its own is
///   the class of bug this core has paid for most.
///
/// ADR-0028 gives the session two distinct durable-key facts: the target a dial
/// named and the far end the byte-channel realizer verified. A
/// byte-transparent relay can make those different parties, so one slot cannot
/// represent both without confusing a target requirement with evidence.
/// Identity is per-session state by design, the second key is paid only in the
/// struct (the keys are fixed-width and nothing here allocates), and the warmed
/// per-session ceiling in `test/engine/footprint_budget_test.zig` holds.
///
/// The number is where a 64-bit build measures under runtime safety, so a field
/// added here is a build failure rather than a withdrawal nobody watches. Forty
/// of the bytes are std's, not glowcap's: each of the five embedded
/// `std.ArrayList` headers (the four peer queues and the session's sturdyref
/// cache) carries std's one-byte `pointer_stability` lock, padded to a word, in
/// Debug and ReleaseSafe, the same lock every hash map here already pays.
/// ReleaseFast and ReleaseSmall make the lock zero-sized and measure smaller.
/// Forty-eight more are the wire-hash secret (ADR-0037): one word on the
/// session and one in each of the five tables keyed by positions the peer
/// chooses, because those tables' verbs run without the session in hand.
/// Eight bytes hold the cold result-import release outbox (ADR-0065). Its
/// stable heap owner lets answer payloads retire their imports without a
/// fallible finalizer. It stays null until a forwarded result introduces caps.
/// Eight bytes hold the cold local promise registry. It lets collection visit
/// projections without scanning partner-sized answer tables on every release.
/// It stays null until the session projects a local promise.
/// Sixteen bytes are the two own-side position slabs (exports and outbound
/// answers): each keeps a free-list head and a live count beside its vector
/// where the hash map it replaced kept only a header, and the export table
/// keeps its base and span beside its rows.
/// Every footprint budget is stated under the safe modes, because every gate runs there and `release-pack` names ReleaseSafe as
/// the mode to ship.
///
/// It is a ceiling and not an equality, unlike the `Conn` slot overhead in
/// `src/net/completion/loop/state.zig`. That one measures a *difference*
/// between two sizes on whatever target is building, which is stable across
/// targets. This one measures a whole struct full of pointers and `usize`s, and
/// `wasm32` (the sans-io core under `zig build cross-check`) makes it smaller,
/// as does a fast build. So no single number is the measurement on every target
/// and mode, and an equality here would fail the narrow ones.
pub const peer_session_struct_budget_bytes = 1176;
comptime {
    if (@sizeOf(Peer) > peer_session_struct_budget_bytes) @compileError(std.fmt.comptimePrint(
        "engine.Peer is {d} bytes, over the {d}-byte per-session struct budget. " ++
            "A larger session struct is a withdrawal from the 500k footprint budget. Raise the budget deliberately, do not route around it.",
        .{ @sizeOf(Peer), peer_session_struct_budget_bytes },
    ));
}

/// Shared keyed-hello signature verifier, surfaced at the engine boundary.
pub const verifyPartnerStartSession = hello.verifyPartnerStartSession;

/// The one shape-aware borrowed-to-owned frame materialization.
pub const ownedFrameFromView = peer_drive.ownedFrameFromView;
