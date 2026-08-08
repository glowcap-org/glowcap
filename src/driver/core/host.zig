//! The sans-io byte-fed multi-session CapTP host core (ADR-0072), under the
//! `driver_core` I/O ban. A `Host` owns one `engine.Node` (identity,
//! live-session directory, routing, the redeem serve step) and mints byte-fed
//! sessions (`HostSession`) whose peers are node-registered, so
//! everything the node decides — where a token routes, which exporter a give
//! withdraws from, when a served reply becomes a signed give — happens under
//! every session the host holds, with no socket in sight. The embedder owns
//! the loop, the sockets, and the entropy: it feeds inbound bytes with `feed`
//! (a bare whole frame), `feedBytes` (outer-framed byte-stream chunks), or
//! `serveEvent` (one already-polled event, the completion-loop hook), drains
//! outbound frames with `HostSession.takeOutbound`, and answers the host's
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

const served_mod = @import("served.zig");
const capability = @import("capability.zig");
const vocab = @import("vocab.zig");
const value_mod = @import("value.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const host_action = @import("host_action.zig");
const host_pump = @import("host_pump.zig");
const enliven_mod = @import("enliven.zig");
const vows_mod = @import("vows.zig");
const sessions_mod = @import("sessions.zig");
const handoff_mod = @import("handoff.zig");
const trace = @import("trace.zig");
const publish_mod = @import("publish.zig");
const Served = served_mod.Served;
const CrossedHellos = crossed_hellos.CrossedHellos;
const HostAction = host_action.HostAction;

const crypto = foundation.crypto;

/// The typed refusals the byte-fed host adds over the shared driver vocabulary.
pub const HostError = error{
    /// Deferred Host work could not allocate. No action or authority is lost;
    /// retry the action drain after allocator pressure subsides.
    OutOfMemory,
    /// The session lost the crossed-hellos tiebreak (ADR-0030) and is
    /// condemned: its typed abort is queued for the embedder to drain, and no
    /// further verb may ride it.
    ConnectionCondemned,
    /// A top-level (host-driving) verb was re-entered from inside a listener
    /// or behavior callback. Every public verb is one of two kinds: top-level
    /// verbs refuse this error under the latch, and the enqueueing verbs —
    /// `send`/`tell`, `listenTo`, the vow verbs, `gcRelease`,
    /// `setExporterLocation` — are legal there, their effects encoded and
    /// pumped when the enclosing top-level verb unwinds.
    ReenteredHost,
    /// A host vow id names no live row: never minted, or its session was
    /// released.
    NoSuchVow,
    /// A session-scoped vow verb (a listener, a pipelined send or
    /// projection, `vowSession`) was called on a resolver vow, which belongs
    /// to no session (ADR-0102): its whole surface is the turn-scoped
    /// forward and the resolver settle verbs.
    SessionlessVow,
    /// A turn-scoped forward-to-vow named a wire vow. A wire answer belongs
    /// to the session that minted it and settles through that session's own
    /// machinery; only a local resolver vow (ADR-0102) can carry a deferred
    /// answer.
    NotALocalVow,
    /// A send argument is a capability foreign to the session the send
    /// rides, which would mis-encode the reference for that partner; or a
    /// capability appeared in a resolver settle, whose plain-data contract
    /// has no session to home one (ADR-0102). The verb is refused whole.
    ForeignArgument,
    /// The target token's exporter session is gone; the send is dropped,
    /// not mis-sent (the node's fail-closed contract).
    TokenRetired,
    /// `gcRelease` was given an id below the node's token range; only a
    /// fetched capability's token resolves to a wire import to release.
    NotAToken,
    /// `releaseImport` was handed a node-minted token rather than a position
    /// the partner named. `gcRelease` is the verb for those.
    NotAWirePosition,
    /// `partnerIdentity` was asked for an identity the partner has not sent
    /// yet: its `op:start-session` has not arrived with a key.
    HandshakeIncomplete,
    /// `partnerIdentity` was asked on a session opened with
    /// `Options.verify_partner` off. Nothing about the partner was proved, so
    /// there is no verified identity to report rather than an unchecked one.
    PartnerUnverified,
    /// `setSelfDesignator` was given a designator longer than the retained
    /// 64-byte buffer.
    DesignatorTooLong,
    /// A locator on a key-designator transport named a durable key this host
    /// does not hold (ADR-0105). A peer cannot publish another node's identity.
    UnheldIdentity,
    /// No acceptable location has been selected. Dial targets do not supply
    /// this host's route; adapters must publish one explicitly before opening
    /// a session (ADR-0109).
    MissingAdvertisedLocator,
    /// A CapTP session for this partner is already enrolled (ADR-0012):
    /// dial-to-dial by our dial target, or by a durable peer identity that a
    /// matching channel proof authenticated. A partner's locator claim alone
    /// never enters the durable-peer index. Crossed hellos may still open an
    /// accepted session while a dial is in flight; authenticated pairs then
    /// keep at most one non-condemned session (ADR-0068).
    SessionPairExists,
    /// `enrollCapability` was asked to enroll a position already enrolled under
    /// the other kind. The kind lives on the enrolled row and routing reads it
    /// there, so the second caller cannot be given the kind it asked for. Nor
    /// can it be handed the token in silence, because it would then believe the
    /// row agreed with the request it made.
    EnrolledKindConflict,
    /// Every export range in this host's slot is held by a live session, so a
    /// new one cannot be given numbers of its own. The mint is refused rather
    /// than handed a range another session is already using: the point of the
    /// ranges is that a capability offered to the wrong session is refused, and
    /// a shared range gives that back silently.
    ExportRangeExhausted,
    /// A Host verb was given a session owned by another Host. Peer ids and wire
    /// positions are Host/session-scoped and must never be resolved through a
    /// caller-selected owner.
    ForeignSession,
    /// Lift was called again for an import whose wire retains have all already
    /// been surfaced as Host handles.
    NoUnliftedImportRetain,
    /// The legacy position release tried to bypass an opaque Host handle that
    /// now owns release of this import row.
    ImportLifted,
    /// A sturdyref's `(transport, designator)` does not name the selected
    /// session. The swiss is never interpreted outside its peer namespace.
    PeerIdentityMismatch,
    /// The selected session carries only a partner assertion, not provenance
    /// strong enough for default sturdyref enlivenment.
    PeerIdentityUnverified,
    /// `bindVerifiedChannelKey` was given a designator that does not name a
    /// durable key. A realizer's proof names a key; a transport that proves an
    /// address has nothing to assert here.
    InvalidChannelKey,
    /// `bindVerifiedChannelKey` named a durable key different from one this
    /// connection's realizer already asserted. One connection has one realizer
    /// and one far end, so the two statements cannot both be true, and the
    /// second is refused rather than allowed to overwrite the first.
    ChannelKeyConflict,
    /// `bindVerifiedChannelKey` arrived after the partner's `op:start-session`
    /// was applied. The chokepoint that weighs a partner's durable claim has
    /// already run, so this proof is too late to be the evidence it was for.
    /// The mirror of `HandshakeIncomplete`: one names a fact not yet knowable,
    /// this one a fact stated too late to count.
    HandshakeAlreadyApplied,
};

/// Where a session's signing seed comes from (ADR-0097).
///
/// The sans-io core draws no entropy, so this is a supplied source, not a
/// generator. `rooted` is the shipped posture: the adapter hands the host one
/// 32-byte root drawn at its own entropy boundary, and each session's seed is
/// derived from that root and a per-host counter, so every connection signs
/// with its own key while the core stays deterministic given its inputs.
///
/// `reused_durable` is the older posture, kept because it is what a caller
/// gets when it supplies no root, and because deterministic session keys are
/// what fixtures want: every session signs with the host's durable seed, so
/// session identity and durable node identity coincide and a reconnect
/// recreates a prior session's handoff names.
pub const SessionSeedSource = union(enum) {
    /// Every session signs with the host's durable seed.
    reused_durable: [crypto.SEED_BYTES]u8,
    /// Each session's seed is derived from this root and the host's session
    /// counter. A root drawn freshly per process is what makes an old handoff
    /// certificate fail to resolve after a reconnect.
    rooted: [crypto.SEED_BYTES]u8,
};

/// Domain separator for session-seed derivation, so a root can never yield
/// bytes that collide with another use of the same key material.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub const session_seed_domain = "pancake session-key v1";

pub const PeerProvenance = enum { verified, dial_target, assertion_only };

/// Enlivenment lives in `enliven.zig`; its vocabulary is named here because
/// this is the file every consumer of the host core reads first.
pub const EnlivenPeerPolicy = enliven_mod.EnlivenPeerPolicy;
pub const EnlivenStart = enliven_mod.EnlivenStart;

/// Map a served inbound resolve to the outcome `engine.Node.claimResolve`
/// consumes: a fulfilled far capability by wire id, a break by reason, and
/// anything else as not-a-capability.
fn redeemOutcome(resolve: model.view.Resolve) engine.Node.RedeemOutcome {
    return switch (resolve.resolution) {
        .fulfill => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far| .{ .far = far.import_position.int() },
                else => .not_capability,
            },
            else => .not_capability,
        },
        .@"break" => |b| .{ .broken = b.message },
    };
}

/// The far reference `arg` names, or null when `arg` is not a plain far
/// capability — a break, a promise, a near, or a non-reference value. The one
/// unwrap of the `reference → far` shape the foreign-proxy, enroll, and enliven
/// paths each read off a fulfilled resolution.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn asFarRef(arg: model.Argument) ?@FieldType(model.Reference, "far") {
    if (arg != .reference or arg.reference != .far) return null;
    return arg.reference.far;
}

/// The served-reply interceptor body every host session shares: offer a
/// fulfilled far capability to the node. A foreign **promise** token is
/// rewritten to a third-party import-promise on this session (ADR-0009
/// introducing-session proxy). A foreign **object** token whose home is
/// another session becomes a signed give (`.claimed` — the vat resolves
/// nothing; the node asks for gift-id entropy and originates it). Anything
/// else passes through unchanged for the vat to resolve as-is. Same-home
/// token lowering is not this seam's job: the outbound chokepoint
/// (`Peer.send`, ADR-0069) rewrites a node-local token to its wire reference.
/// The actions a claim queued pump at the enclosing verb's unwind.
fn interceptFulfilled(
    node: *engine.Node,
    peer_id: engine.PeerId,
    answer: model.AnswerPosition,
    fulfilled: model.Argument,
) !actors.InterceptOutcome {
    const far = asFarRef(fulfilled) orelse return .{ .resolve = fulfilled };
    const far_id = far.import_position.int();
    // Break reasons reach the wire via vat `@errorName`; Node uses snake_case
    // (`session_not_open`) so the CapTP string is not Zig PascalCase.
    if (try node.proxyForeignPromiseFulfill(peer_id, far_id)) |proxy| {
        return .{ .resolve = .{ .reference = proxy } };
    }
    if (try node.interceptFulfilledRef(peer_id, answer.int(), far_id)) return .claimed;
    // Nothing claimed it, so this reply is about to go out as a plain far on
    // this session. A position this session does not hold names nothing here:
    // the application is replying with a capability it came by somewhere else
    // and never enrolled (`Host.enrollCapability`), so the node was never told
    // the home the gifter intercept above routes on. Refuse it as the foreign
    // argument it is, rather than letting the session spine discover it: the
    // send-side rule would refuse it too, but as an `InvalidReference` that
    // aborts the whole session over one reply.
    if (node.peer(peer_id)) |home_peer| {
        if (!home_peer.session_state.holdsImport(far.import_position)) return HostError.ForeignArgument;
    }
    return .{ .resolve = fulfilled };
}

/// One byte-fed CapTP session shell: a node-registered peer under a `Served`
/// serve core, minted by `Host.openDialedLocator` /
/// `Host.openAcceptedAdvertised` and freed by `Host.releaseSession`. This is
/// not a `net.Connection` — it is the CapTP
/// partner the host routes and serves; the ABI name stays
/// `PancakeHostSession`. The embedder writes what `takeOutbound` drains and feeds
/// what it reads through `Host.feed` (never the `Served` directly, so the
/// host's action pump always runs).
pub const HostSession = struct {
    host: *Host,
    peer_id: engine.PeerId,
    served: Served,
    /// The actual netlayer name this connection was opened through. Owned by
    /// the shell; sturdyref peer equality includes it and never infers it from
    /// a partner's signed claim.
    transport: []const u8,
    role: Role,
    /// Set when either side ended this session: a local verdict queues its
    /// typed abort, while a partner abort closes without an echo. Every later
    /// verb refuses `ConnectionCondemned` in both cases.
    condemned: bool = false,
    /// The Port's Vat ingress was already removed by condemnation/teardown.
    ingress_cancelled: bool = false,
    /// Intrusive membership bit for the Host's encode-work FIFO. Keeps dirty
    /// insertion O(1) without a second map or a linear dedup scan.
    flush_pending: bool = false,
    /// Intrusive membership for embedder notifications. Capacity for one flush
    /// and one close row per live shell is reserved at mint.
    flush_action_pending: bool = false,
    close_action_pending: bool = false,
    /// The live trace reported this session's open (`Host.traceNoteOpen`);
    /// gates the one open fact and the close that pairs with it.
    trace_open_noted: bool = false,
    /// The 32-byte seed of the key this session signs with: its keyed hello,
    /// and every handoff record naming this session (ADR-0097). Held per
    /// session rather than read from the node because session identity and
    /// durable node identity are different facts — they are drawn from the
    /// same value only while a host signs every session with its durable key,
    /// and the seam that reads this is what makes drawing a fresh one per
    /// connection a change of one assignment.
    session_seed: [crypto.SEED_BYTES]u8 = undefined,
    /// Partner session key this shell is indexed under in `Host.partner_by_side`,
    /// set in `indexPartnerKey` (before apply writes `partnerSessionKey`).
    /// Lets `unindexSession` stay O(1) without scanning the map.
    indexed_partner_key: ?[crypto.PEER_KEY_BYTES]u8 = null,

    /// The unconsumed stream tail `Host.feedBytes` keeps between chunks: a
    /// partial frame straddling two reads, or the frames one read coalesced
    /// behind the handshake hello (feeding stops at session-open). Owned by
    /// the shell and freed with it; capacity a burst grew past
    /// `steady_feed_tail_bytes` returns when the tail fully drains.
    ///
    /// It is the same `foundation.Spill` the `net` tier folds its parser over,
    /// which is why the boundedness ADR-0041 argues holds here too. The tiers
    /// differ only in what a drained tail keeps: a stream reader spills for an
    /// oversize frame and frees the burst, while straddling a chunk boundary is
    /// ordinary here, so this one keeps a steady size.
    feed_tail: foundation.Spill = .{},

    /// Which half of the handshake this session is, carrying the one datum
    /// only the dialing half has: the partner designator it dialed — the key
    /// the crossed-hellos tiebreak looks an outbound up by. Host-owned bytes,
    /// freed with the shell.
    pub const Role = union(enum) {
        dialed: []const u8,
        accepted,
    };

    /// Drain one encoded outbound frame for the embedder to write, or null
    /// when the queue is empty. Owned: the caller frees the returned frame.
    /// Top-level: refused under the callback latch — the enclosing verb's
    /// unwind is still encoding, so a mid-callback drain would race it.
    pub fn takeOutbound(self: *HostSession) HostError!?foundation.Frame {
        try self.host.refuseReentry();
        const frame = self.served.takeOutbound() orelse return null;
        self.traceOutboundFrame(&frame);
        return frame;
    }

    /// The live trace's outbound seat — the mirror of the inbound seat in
    /// `hostBeforeServe`: every frame leaves through this drain, so a
    /// deliver's verb and wire bytes are reported here, where the encoded
    /// frame exists. A send-time fact would predate the deferred encode
    /// (no bytes to report) and would report near sends that never touch
    /// the wire. One borrowed view decode per outbound frame, paid only
    /// while a sink is installed; a non-deliver frame or one without a
    /// symbol verb is protocol traffic the trace skips, as inbound.
    fn traceOutboundFrame(self: *HostSession, frame: *const foundation.Frame) void {
        const host = self.host;
        if (host.trace_sink == null) return;
        const codec_id = self.served.port.peer.session_state.codec;
        const body = engine.decodeBodyView(codec_id, frame.view()) catch return;
        if (body != .deliver) return;
        const first = body.deliver.args.at(0) catch return;
        if (first != .symbol) return;
        host.traceMessage(self, true, first.symbol, frame.bytes());
    }

    /// Whether the keyed handshake has completed and the session is open.
    pub fn sessionOpen(self: *const HostSession) bool {
        return self.served.port.peer.sessionIsOpen();
    }

    /// The key this session signs with (ADR-0097). One derivation from
    /// `session_seed`, so the hello signature and every handoff record naming
    /// this session are made by the same key, and no caller reaches for the
    /// node's durable key to stand in for it.
    pub fn sessionSecret(self: *const HostSession) crypto.SecretKey {
        return crypto.SecretKey.fromSeed(self.session_seed);
    }
};

/// Per-connection static-footprint ceiling for the byte-fed host shell. It is
/// the third per-connection static allocation on the 500k Bridge path (ADR-0076),
/// beside `engine.Peer` (gated at 1 KiB in `engine`) and the completion loop's
/// `Conn` wrapper (gated at 128 bytes of overhead in `net.completion`). One
/// `HostSession`, and therefore one inline `Served` Port, is minted per adopted
/// connection in `mintShell`; the Vat is Host-wide and charged once per Host.
/// `engine.Peer` itself lives behind a pointer here, gated on its own. Crossing
/// this ceiling is a design event that raises the budget here and in
/// `docs/ladder.md` step 2 together, with the bytes justified, never a check to
/// route around.
/// 464 rose to 496 for ADR-0097's per-session signing seed: 32 bytes of key
/// material that is per-session state by definition, weighed at 1.5% of the
/// warmed 2 KiB per-session ceiling `docs/ladder.md` step 2 records.
pub const host_session_struct_budget_bytes = 496;
comptime {
    if (@sizeOf(HostSession) > host_session_struct_budget_bytes) @compileError(std.fmt.comptimePrint(
        "driver_core.HostSession is {d} bytes, over the {d}-byte per-connection shell budget (docs/ladder.md step 2). " ++
            "A larger shell is a withdrawal from the 500k footprint budget; raise the source constant and documented budget together.",
        .{ @sizeOf(HostSession), host_session_struct_budget_bytes },
    ));
}

/// Retained-capacity bound for a session's `feed_tail` between bursts — the
/// engine's steady-queue posture at the byte-fed tier. A burst that grew the
/// tail past this frees the excess when the tail drains, at the price of one
/// growth re-allocation when the next burst begins.
const steady_feed_tail_bytes: usize = 4096;

/// Delimit and dispatch complete outer Syrup byte strings from `bytes`. Each
/// body is exactly one bare codec frame. The opening hello remains the pause
/// boundary, so any following outer frames stay in the caller-owned tail.
fn parseOuterStreamPrefix(session: *HostSession, bytes: []const u8, was_open: bool) !usize {
    var consumed: usize = 0;
    while (consumed < bytes.len) {
        const outer = switch (foundation.stream_framing.parsePrefix(
            bytes[consumed..],
            session.served.port.peer.limits().max_frame_bytes,
        )) {
            .incomplete => break,
            .malformed => {
                session.served.port.peer.emitFailure(error.MalformedFrame);
                session.served.port.peer.stepToIdle() catch {};
                return error.MalformedFrame;
            },
            .too_large => {
                session.served.port.peer.emitFailure(error.FrameTooLarge);
                session.served.port.peer.stepToIdle() catch {};
                return error.FrameTooLarge;
            },
            .decoded => |decoded| decoded,
        };
        const shape = engine.frameShape(session.served.port.peer.inboundCodec()) orelse {
            session.served.port.peer.emitFailure(error.MalformedFrame);
            session.served.port.peer.stepToIdle() catch {};
            return error.MalformedFrame;
        };
        try session.served.feedBorrowed(&session.host.vat, .{
            .bytes = outer.body,
            .shape = shape,
        });
        consumed += outer.consumed;
        if (!was_open and session.served.port.peer.sessionIsOpen()) break;
    }
    return consumed;
}

/// One identity, one node, many byte-fed CapTP sessions — the sans-io host
/// core. The node serve step decides, and this host executes each action
/// either directly (settle and fail fire the recipient vat's listener through
/// `Vat.settleFar`) or by queueing it for the embedder (dials and gift-id
/// draws are host effects). Free with `deinit`, which breaks every
/// still-parked vow before the shells go.
/// One host-wide publication: a swiss name discovers one Host-Vat actor. The
/// actor is the identity; a Port projection is minted only when that Port
/// fetches the name (or an embedder explicitly asks for its position). The
/// registry is the one discovery authority: a fetch never leaves a per-session
/// copy of the alias behind, so replacing or removing the name changes every
/// later fetch on every session, while the Port's reverse row keeps a repeated
/// fetch on one session reusing its existing export.
const Publication = struct {
    name: []const u8,
    actor: actors.Ref,
};

/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn actorIdOf(ref: actors.Ref) u64 {
    return switch (ref) {
        .local => |id| id,
        .far => unreachable,
    };
}

pub const DialTarget = crossed_hellos.DialTarget;

const DialTargetContext = struct {
    pub fn hash(_: DialTargetContext, target: DialTarget) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(target.transport);
        hasher.update(&.{0});
        hasher.update(target.designator);
        return hasher.final();
    }

    pub fn eql(_: DialTargetContext, a: DialTarget, b: DialTarget) bool {
        return std.mem.eql(u8, a.transport, b.transport) and
            std.mem.eql(u8, a.designator, b.designator);
    }
};

const DialTargetMap = std.HashMapUnmanaged(
    DialTarget,
    engine.PeerId,
    DialTargetContext,
    std.hash_map.default_max_load_percentage,
);

pub const Host = struct {
    allocator: std.mem.Allocator,
    node: engine.Node,
    opts: Options,
    /// One actor graph and turn scheduler for every session Port in this Host.
    vat: actors.Vat,
    sessions: std.AutoHashMapUnmanaged(engine.PeerId, *HostSession) = .{},
    /// Canonical application identities for capabilities lifted out of any
    /// session. Wire positions remain owned by their session; this table keeps
    /// the owning peer beside the target and rejects stale generations.
    capabilities: capability.Registry = .{},
    /// Incarnation stamp for remote import rows first lifted into Host space.
    /// Monotonic for the Host lifetime; zero is never issued.
    next_import_incarnation: u64 = 1,
    /// Crossed-hellos tiebreak state (ADR-0030): `openDialedLocator` registers
    /// the outbound before its hello moves; accepted CapTP sessions compare
    /// inbound start-sessions against it.
    hellos: CrossedHellos = .{},
    /// Where `mintShell` draws each session's signing seed (ADR-0097).
    session_seed_source: SessionSeedSource = undefined,
    /// Counter distinguishing successive sessions' derived seeds. Monotonic
    /// for the host's life, so two sessions never share a key.
    session_seed_counter: u64 = 0,
    /// OCapN side name → the session whose verified partner key derives that
    /// side. A signed give carries the side, not the key, so this directory
    /// authenticates an early withdraw before its deposit row exists. This is
    /// also the one partner-identity index: key lookups derive the side and
    /// compare the selected shell's exact `indexed_partner_key` before use.
    partner_by_side: std.AutoHashMapUnmanaged([32]u8, engine.PeerId) = .{},
    /// A partner's **authenticated durable identity** → peer id: the second of
    /// the two peer directories, and deliberately not the same one
    /// (ADR-0097). `partner_by_side` names a session *incarnation* through the
    /// key that signed it, which is what a handoff certificate must resolve
    /// against; this names the durable peer a locator designates, which is
    /// what "do I already have a session reaching P" must ask. They differ by
    /// construction: every connection has a fresh session key, while the
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
    peer_by_durable: std.AutoHashMapUnmanaged([crypto.PEER_KEY_BYTES]u8, engine.PeerId) = .{},
    /// Our own dialed `(transport, designator)` → peer id. Key slices borrow
    /// the session shell and leave the index before those bytes free. The
    /// complete locator identity prevents one netlayer from satisfying or
    /// shadowing another netlayer's dial.
    dialed_by_target: DialTargetMap = .{},
    /// The host's own dialable designator, signed into every dial's
    /// start-session — what a partner's crossed-hellos table looks this host
    /// up by, and what its gives can name. Empty for a host that never
    /// listens, which signs the shared unreachable-client placeholder.
    self_designator: [64]u8 = undefined,
    self_designator_len: usize = 0,
    /// Host-wide bootstrap aliases. A fetch performs one keyed discovery lookup
    /// and lazily projects the actor onto the requesting Port.
    giftables: std.StringHashMapUnmanaged(Publication) = .empty,
    /// The embedder-facing action FIFO; `nextAction` drains it.
    actions: engine.ActionFifo(HostAction) = .{},
    /// The most recently popped action; its byte views stay valid until the
    /// next `nextAction`, which frees them.
    last_action: ?HostAction = null,
    /// Host vow id to its heap row (the row's address is the retire
    /// listener's stable ctx; the map may rehash). A row lives exactly until
    /// its vow settles: `mintVow` installs the retire listener at mint, the
    /// fire removes and frees the row, and a later verb on the id refuses
    /// `NoSuchVow` — so the map is bounded by unsettled vows, not by every
    /// vow ever minted.
    /// The live trace tap (`trace.zig`), or null. Installed by the embedder
    /// through `setTrace` / the C `pancake_host_set_trace`; with none every
    /// emit site is one null check.
    trace_sink: ?trace.Sink = null,

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
    pending_flush: std.ArrayListUnmanaged(engine.PeerId) = .empty,
    /// Read cursor for `pending_flush`; the drained queue retains capacity and
    /// compacts a large consumed prefix without front-removing every row.
    pending_flush_head: usize = 0,
    /// The reentrancy latch: true while a top-level verb is firing callbacks
    /// or pumping. Nested verbs enqueue only — the enclosing verb's unwind
    /// encodes and pumps — and the host-driving verbs refuse `ReenteredHost`.
    in_callback: bool = false,
    /// Debug-only owning thread: latched on the first public verb, asserted
    /// on every later one. Zero-sized in release. The host is unsynchronized
    /// by contract; a foreign thread touching it is a silent data race
    /// without this check.
    owner_tid: if (std.debug.runtime_safety) ?std.Thread.Id else void =
        if (std.debug.runtime_safety) null else {},

    /// Bootstrap / sturdyref registry durability (ADR-0082). `ephemeral` is
    /// today's process-lifetime registry. `durable_bootstrap` names the
    /// embedder-store posture; selecting it is refused until a store is wired
    /// (no silent ephemeral twin).
    pub const BootstrapDurability = enum { ephemeral, durable_bootstrap };

    pub const Options = struct {
        /// Full CapTP session limits applied to every minted peer (ADR-0082).
        /// Defaults match `session.SessionLimits{}`, including the 1 MiB
        /// `max_frame_bytes` the driver C ABI publishes as
        /// `PANCAKE_DEFAULT_FRAME_CAP`. The completion loop's read buffers
        /// come from a shared 16 KiB pool (ADR-0054), not from
        /// `max_frame_bytes`, so raising the admission cap costs no
        /// per-session memory.
        limits: engine.SessionLimits = .{},
        /// Registry durability posture (ADR-0082). `.ephemeral` is live;
        /// `.durable_bootstrap` fails closed at `Host.init` until an embedder
        /// store lands.
        bootstrap_durability: BootstrapDurability = .ephemeral,
        /// Verify the partner's `op:start-session` signature — the secure
        /// default a real peer keeps.
        verify_partner: bool = true,
        /// The wire grammar this host *prefers*. What a given session speaks
        /// is settled with its partner, not imposed from here (ADR-0103), so
        /// two ends no longer have to be configured alike: a partner that
        /// cannot follow settles this axis back to the baseline on its own
        /// session and every other session keeps the preference.
        codec: model.CodecId = model.Preference.baseline.codec,
        /// The CapTP profile this host prefers, beside the codec above. The
        /// two are one decision rather than two knobs, and both default to
        /// `model.Preference.baseline` — the profile every conforming peer
        /// speaks, which is what a Goblins vat and the upstream suite speak.
        ///
        /// `next` is a wire difference rather than a label: V1.0 has no
        /// native `op:resolve`, so an answer settles through a
        /// `resolve_me_desc` callback there and through a resolve on `next`.
        /// A hello states this preference in its locator hints and the two
        /// sides settle from the pair, so a host may prefer `next` and still
        /// hold baseline sessions with peers that do not.
        captp_version: model.CaptpVersion = model.Preference.baseline.captp_version,
        /// Optional CapTP features this host offers. Defaults to full pancake
        /// support; each session intersects this set with the partner's offer
        /// at handshake.
        features: model.FeatureSet = model.Preference.baseline.features,
        /// Local-turn amplification cap per drive, applied to every minted
        /// CapTP session's serve core (see `Served.local_turn_budget`). A loop
        /// embedder sets it so one message that amplifies without bound cannot
        /// stall the thread serving every session: the flooded session is
        /// condemned with a `resource_exhausted` abort and a `close` action
        /// names it for the embedder. Null (the default) drives unbounded, the
        /// blocking one-session-per-thread posture.
        local_turn_budget: ?usize = null,
        /// Adapter-owned issuer for capability ids that cross an untyped ABI.
        /// Native `Ref` equality already carries the Registry pointer and leaves
        /// this null; the C adapter supplies its process-scoped opaque source.
        capability_id_issuer: ?capability.IdIssuer = null,
        /// Where each session's signing seed comes from (ADR-0097). Null keeps
        /// the durable-key posture, which is what a caller that supplies no
        /// root gets; an adapter that can draw entropy supplies a `rooted`
        /// source so every connection signs with its own key.
        session_seeds: ?SessionSeedSource = null,

        /// Convenience for the common case: default Options with only the
        /// frame admission cap overridden.
        pub fn withFrameCap(cap: usize) Options {
            var o: Options = .{};
            o.limits.max_frame_bytes = cap;
            return o;
        }

        /// Admission cap shortcut (`limits.max_frame_bytes`).
        pub fn frameCap(self: Options) usize {
            return self.limits.max_frame_bytes;
        }
    };

    /// Override selective session limits before minting peers (ADR-0082).
    /// `null` leaves that field unchanged. Already-open sessions keep the
    /// limits they were minted with.
    pub fn setSessionLimits(self: *Host, max_frame_bytes: ?usize, queue_cap: ?usize) void {
        if (max_frame_bytes) |v| self.opts.limits.max_frame_bytes = v;
        if (queue_cap) |v| self.opts.limits.queue_cap = v;
    }

    /// A host bound to the caller-supplied durable identity `seed` (drawn at the
    /// embedder's entropy boundary; the sans-io host never generates it).
    /// Session signing keys come from `Options.session_seeds`; omitting that
    /// option retains the legacy posture that reuses `seed`.
    ///
    /// `bootstrap_durability` must be `.ephemeral` today. Selecting
    /// `.durable_bootstrap` panics: that posture needs an embedder store
    /// (ADR-0082) and must not silently behave as ephemeral.
    pub fn init(allocator: std.mem.Allocator, seed: [crypto.SEED_BYTES]u8, opts: Options) Host {
        if (opts.bootstrap_durability != .ephemeral) {
            @panic("Host.Options.bootstrap_durability.durable_bootstrap requires an embedder store; use .ephemeral until then");
        }
        return .{
            .allocator = allocator,
            .node = engine.Node.init(allocator, seed),
            .opts = opts,
            .vat = actors.Vat.init(allocator),
            .capabilities = capability.Registry.init(opts.capability_id_issuer),
            // Today's posture, named rather than assumed: every session signs
            // with the host's durable seed. `Options.session_seeds` overrides
            // it, and that override is the whole of ADR-0097's fresh-key
            // switch at this tier.
            .session_seed_source = opts.session_seeds orelse .{ .reused_durable = seed },
        };
    }

    /// Tear down every CapTP session shell, the action queue, the vow map, the
    /// crossed-hellos table, and the node. Every still-parked far vow fires
    /// broken first, so a host-owned enliven bridge (which frees itself only
    /// when it fires) never strands and every in-process listener hears an
    /// outcome; the completions those breaks queue are freed here with the
    /// rest of the undrained queue.
    pub fn deinit(self: *Host) void {
        // The break fires listeners that may call nested verbs; the latch
        // makes them enqueue only, and everything they enqueue frees below.
        self.in_callback = true;
        var break_it = self.sessions.valueIterator();
        while (break_it.next()) |session| {
            session.*.served.port.breakFarVows(session.*.served.closeReason("host released"));
        }
        var free_it = self.sessions.valueIterator();
        while (free_it.next()) |session| {
            // Drop index rows before freeing borrowed dialed-designator keys.
            self.unindexSession(session.*);
            self.cancelSessionIngress(session.*, session.*.served.closeReason("host released")) catch unreachable;
            self.freeSessionShell(session.*);
        }
        self.sessions.deinit(self.allocator);
        self.vat.deinit();
        // Actors outlive every Port and release their own state above. Rows own
        // only the copied bootstrap names.
        var giftables = self.giftables.valueIterator();
        while (giftables.next()) |row| self.allocator.free(@constCast(row.name));
        self.giftables.deinit(self.allocator);
        self.hellos.deinit(self.allocator);
        self.partner_by_side.deinit(self.allocator);
        self.peer_by_durable.deinit(self.allocator);
        self.dialed_by_target.deinit(self.allocator);
        if (self.last_action) |last| host_action.freePayload(self.allocator, last);
        for (self.actions.unpopped()) |action| host_action.freePayload(self.allocator, action);
        self.actions.deinit(self.allocator);
        // The far rows retired themselves through the break above; what
        // remains is never-fired local rows, freed here with the vats gone.
        var vow_it = self.vows.valueIterator();
        while (vow_it.next()) |row| self.allocator.destroy(row.*);
        self.vows.deinit(self.allocator);
        self.resolver_index.deinit(self.allocator);
        // Enlivens still parked on a dial nobody reported: their vows never
        // settle (the embedder is gone), so only the owned bytes remain.
        for (self.pending_enlivens.items) |parked| self.freeParkedEnliven(parked);
        self.pending_enlivens.deinit(self.allocator);
        self.pending_flush.deinit(self.allocator);
        self.capabilities.deinit(self.allocator);
        self.node.deinit();
    }

    /// The sole refusal produced by the bounded address-default setter.
    pub const SetSelfDesignatorError = error{DesignatorTooLong};

    /// Record the address-designator default used by an explicit
    /// `ensureAdvertisedLocator` call. This legacy compatibility setter does
    /// not publish a locator and session opens do not read it directly.
    pub fn setSelfDesignator(self: *Host, designator: []const u8) SetSelfDesignatorError!void {
        if (designator.len > self.self_designator.len) return error.DesignatorTooLong;
        @memcpy(self.self_designator[0..designator.len], designator);
        self.self_designator_len = designator.len;
    }

    /// The address default used by `ensureAdvertisedLocator`: a caller-set
    /// bound address or the unreachable-client placeholder.
    /// `pub` for the Host-core siblings, not for embedders. Host-core internal.
    pub fn selfDesignator(self: *const Host) []const u8 {
        if (self.self_designator_len == 0) return vocab.unreachable_client_designator;
        return self.self_designator[0..self.self_designator_len];
    }

    /// Publish and select this node's complete acceptable location. The node
    /// deep-copies the locator and retains snapshots for other transports so
    /// deployment policy can select a different route later (ADR-0109).
    pub fn setAdvertisedLocator(self: *Host, locator: model.PeerLocator) !void {
        self.assertOwnerIfClaimed();
        if (vocab.designatorSchemeForTransport(locator.transport) == .key)
            try sessions_mod.refuseUnheldIdentity(self, locator.designator);
        var hint_storage: engine.Peer.HelloHints = .{};
        defer hint_storage.deinit(self.allocator);
        const complete = try hint_storage.extend(self.allocator, locator, .{
            .captp_version = self.opts.captp_version,
            .codec = self.opts.codec,
            .features = self.opts.features,
        });
        try self.node.setAdvertisedLocator(complete);
    }

    /// Retain the dial-only default for `transport` once, if an adapter has
    /// not already supplied a complete locator. This does not displace an
    /// acceptable location already selected for another transport. It becomes
    /// the selection only when the node has none. Key transports use this
    /// node's public key, while address transports use `selfDesignator()` and
    /// its unreachable-client default.
    pub fn ensureAdvertisedLocator(self: *Host, transport: []const u8) !void {
        self.assertOwnerIfClaimed();
        var key_designator: [crypto.PeerKey.designator_len]u8 = undefined;
        const designator = switch (vocab.designatorSchemeForTransport(transport)) {
            .key => blk: {
                key_designator = self.node.secretKey().publicKey().toDesignator();
                break :blk key_designator[0..];
            },
            .address => self.selfDesignator(),
        };
        var hint_storage: engine.Peer.HelloHints = .{};
        defer hint_storage.deinit(self.allocator);
        const complete = try hint_storage.extend(self.allocator, .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        }, .{
            .captp_version = self.opts.captp_version,
            .codec = self.opts.codec,
            .features = self.opts.features,
        });
        try self.node.ensureAdvertisedLocator(complete);
    }

    /// Stop retaining a locator for `transport`. If it was selected, the node
    /// has no acceptable location until one is explicitly set or ensured;
    /// another retained route is never selected by map iteration order.
    /// Already-open sessions keep the hello snapshot they signed when opened.
    pub fn removeAdvertisedLocator(self: *Host, transport: []const u8) void {
        self.assertOwnerIfClaimed();
        self.node.removeAdvertisedLocator(transport);
    }

    /// Borrow this node's published locator for `transport`.
    pub fn advertisedLocator(self: *const Host, transport: []const u8) ?model.PeerLocator {
        return self.node.advertisedLocator(transport);
    }

    /// Borrow the route subsequent hellos advertise, independent of the
    /// transport carrying those sessions.
    pub fn acceptableLocator(self: *const Host) ?model.PeerLocator {
        return self.node.acceptableLocator();
    }

    // ── Connection lifecycle ─────────────────────────────────────────────────

    // ── The byte pump ────────────────────────────────────────────────────────

    /// Feed one inbound frame the embedder read from its own transport
    /// (borrowed for the call): dispatch what it surfaces into the vat — the
    /// before-serve hook claims withdraw resolves and auto-redeems gives, and
    /// settle listeners fire inside this call — then pump the node actions the
    /// dispatch queued and encode every touched session's outbound. On a
    /// dispatch failure the peer projects a typed `op:abort` onto the outbound
    /// queue; the flush action is still queued so the embedder writes it
    /// before closing the transport.
    pub fn feed(self: *Host, session: *HostSession, frame: foundation.FrameView) !void {
        try host_pump.dispatchUnderLatch(self, session, struct {
            c: *HostSession,
            f: foundation.FrameView,
            pub fn call(s: @This()) !void {
                s.c.served.feedBorrowed(&s.c.host.vat, s.f) catch |err| {
                    // Condemnation can arise while this very frame is being
                    // dispatched (crossed hellos). It has already cancelled
                    // the Port ingress, so the Served post-batch drive sees an
                    // absent ingress; that is the successful terminal outcome,
                    // not a failure of the fed peer.
                    if (err == error.UnknownIngress and s.c.condemned) return;
                    return err;
                };
            }
        }{ .c = session, .f = frame });
    }

    /// Feed raw bytes from a byte-stream transport. Each bare codec frame must
    /// be wrapped as one canonical Syrup byte string (`length:body`). This
    /// method owns split prefixes/bodies, coalesced outer frames, the bounded
    /// tail, and the handshake pause. With no pending tail it parses the
    /// borrowed chunk in place and retains only an incomplete suffix; while a
    /// tail is active, extending it is the one bounded copy. Whole-frame
    /// callers continue to use `feed`; intrinsically message-framed transports
    /// do not add this envelope.
    pub fn feedBytes(self: *Host, session: *HostSession, bytes: []const u8) !void {
        try self.checkOwnedSession(session);
        if (bytes.len == 0 and !session.feed_tail.isActive()) return;
        const was_open = session.served.port.peer.sessionIsOpen();
        return host_pump.dispatchUnderLatch(self, session, struct {
            gpa: std.mem.Allocator,
            c: *HostSession,
            bytes: []const u8,
            was_open: bool,
            pub fn call(s: @This()) !void {
                const tail = &s.c.feed_tail;
                if (!tail.isActive()) {
                    const consumed = try parseOuterStreamPrefix(s.c, s.bytes, s.was_open);
                    if (consumed < s.bytes.len) {
                        try tail.absorbBytes(s.gpa, s.bytes[consumed..]);
                    }
                    return;
                }
                try tail.absorbBytes(s.gpa, s.bytes);
                const consumed = try parseOuterStreamPrefix(s.c, tail.bytes(), s.was_open);
                tail.consume(s.gpa, consumed, steady_feed_tail_bytes);
            }
        }{ .gpa = self.allocator, .c = session, .bytes = bytes, .was_open = was_open });
    }

    /// Serve one already-polled event under the host — the per-event verb for
    /// an embedder loop that polls its sessions' peers itself (a
    /// completion loop's serve hook). Shares the `feed`/`feedBytes` latch and
    /// `finishDispatch` tail: the crossed-hellos hook and the resolve
    /// interceptor run, settle listeners fire under the callback latch, and
    /// the node pump runs at the unwind.
    ///
    /// The batch subtlety: the unwind's pump (`drainWork`, then `Served.driveFed`,
    /// then `drainEvents`) polls and serves every event *still queued* on this
    /// session's peer, so a loop's per-event hook typically fires once per
    /// inbound batch — its own `pollEvent` loop then finds null. That is
    /// correct, not lossy: every event is served through the one
    /// `Served.serveEvent` spine either way.
    ///
    /// This verb, not a raw `session.served.serveEvent`, is the embedder's
    /// entry: the raw call would run settle listeners un-latched (a listener's
    /// nested verb could re-enter the host mid-dispatch) and would skip the
    /// node pump that turns a served reply into a give.
    pub fn serveEvent(self: *Host, session: *HostSession, event: *engine.Event) !void {
        try host_pump.dispatchUnderLatch(self, session, struct {
            c: *HostSession,
            e: *engine.Event,
            pub fn call(s: @This()) !void {
                try s.c.served.serveEvent(&s.c.host.vat, s.e);
            }
        }{ .c = session, .e = event });
    }

    // ── Application verbs ────────────────────────────────────────────────────

    /// Eventual-send `msg` to `target` and mint a host vow for the answer,
    /// observed with `vowOn`. A near target (an export this host bound) runs
    /// in-process; a far target routes through the node, so a redeemed or
    /// fetched token rides its exporter session transparently. A far
    /// argument foreign to the routed session is refused whole
    /// (`ForeignArgument`) rather than mis-encoded.
    pub fn send(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !u64 {
        const routed = try self.routeSend(session, target, msg.args);
        self.node.exporterApplicationOwned(routed.session.peer_id);
        const vow = try routed.session.served.send(&self.vat, routed.target, msg);
        const id = try self.mintVow(routed.session, vow, .plain);
        try host_pump.dirtyThenPump(self, routed.session.peer_id);
        return id;
    }

    /// Fire-and-forget eventual-send: `send` with no answer and no vow.
    pub fn tell(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !void {
        const routed = try self.routeSend(session, target, msg.args);
        self.node.exporterApplicationOwned(routed.session.peer_id);
        try routed.session.served.tell(&self.vat, routed.target, msg);
        try host_pump.dirtyThenPump(self, routed.session.peer_id);
    }

    /// Encode `session`'s enqueued outbound and queue its flush action — the
    /// public entry point for the pump every host verb ends with, for an embedder
    /// (the owning face, ADR-0090) that drove the served core directly with a
    /// session-local verb and owes the wire the encode.
    pub fn flushSession(self: *Host, session: *HostSession) !void {
        // Latch-legal on purpose, like the `dirtyThenPump` it invokes: a
        // nested verb inside a listener enqueues, and the enclosing top-level
        // verb's unwind encodes — so a session verb that ends in this flush
        // keeps working from callback context, the same contract the old
        // owning tier's pure `served.*` forwards carried.
        self.assertOwner();
        try self.checkSession(session);
        try host_pump.dirtyThenPump(self, session.peer_id);
    }

    /// Fetch the partner capability published as `name`, minting a host vow
    /// for the outcome: observe it in-process with `vowOn`, or drain its
    /// `settled`/`failed` completion from the action queue. A fulfilled far
    /// capability settles *already enrolled* under a node-unique token
    /// (ADR-0069) — recorded before the outcome is dispatched, so a reply
    /// that immediately re-gifts it routes to the right exporter. Top-level:
    /// refused from inside a callback.
    pub fn fetch(self: *Host, session: *HostSession, name: []const u8) !u64 {
        try self.refuseReentry();
        try self.checkSession(session);
        self.node.exporterApplicationOwned(session.peer_id);
        const vow = try session.served.sendBootstrapFetch(&self.vat, name);
        const id = try self.mintVow(session, vow, .fetch);
        try host_pump.dirtyThenPump(self, session.peer_id);
        return id;
    }

    /// Listen on the promise `target` names, minting a host vow for its
    /// settlement (ADR-0095). A promise this session handed us — an
    /// introducing session's proxy for a third party's promise (ADR-0009) —
    /// settles through a notification the partner delivers, and this is the
    /// verb that asks for it. A far target routes through the node first, the
    /// way `send` and `tell` route, so a node token is listened on the session
    /// that exports it rather than the session the token was learned on. The
    /// vow is `.plain`, not `.fetch`: a listen makes no blanket claim that
    /// what arrives is a capability, and a give that does arrive is
    /// auto-redeemed on the way through, exactly as one arriving in a call's
    /// reply is. Enqueueing, like `send`: legal inside a callback, because a
    /// settle callback is where you learn the promise to listen on.
    pub fn listenTo(self: *Host, session: *HostSession, target: model.Reference) !u64 {
        var home = session;
        var wire = target;
        if (target == .far) {
            const routed = try self.routeSend(session, target, &.{});
            home = routed.session;
            wire = .{ .far = routed.target.far };
        } else {
            // Not routed: the engine verb refuses every non-far shape with
            // the `InvalidReference` every tier names, so it flows through.
            try self.checkSession(session);
        }
        self.node.exporterApplicationOwned(home.peer_id);
        const vow = try home.served.listenTo(wire);
        const id = try self.mintVow(home, vow, .plain);
        try host_pump.dirtyThenPump(self, home.peer_id);
        return id;
    }

    // ── The Host's responsibilities, by sibling file ─────────────────────────
    // Each group below is implemented in the named sibling and aliased here,
    // not wrapped, so a caller reads one `Host` surface and no call site pays
    // an indirection. This table is the index of the split.

    /// Install (or clear) the live trace sink (`trace.zig`): the callback
    /// that hears this host's session opens, message verbs, and closes, on
    /// the host's one thread, fields borrowed per call. The embedder's side
    /// stamps time and formats; the core only reports facts.
    pub fn setTrace(self: *Host, sink: ?trace.Sink) void {
        self.trace_sink = sink;
    }

    /// Emit the open fact for `session` once, the first time it is observed
    /// open. Called from the serve path (the accepting side opens during a
    /// feed) and from the outbound verbs (the dialing side may send before
    /// any further inbound event would notice).
    pub fn traceNoteOpen(self: *Host, session: *HostSession) void {
        const sink = self.trace_sink orelse return;
        if (session.trace_open_noted) return;
        if (!session.sessionOpen()) return;
        session.trace_open_noted = true;
        const state = &session.served.port.peer.session_state;
        const claimed = state.partnerDesignator();
        const designator: []const u8 = switch (session.role) {
            .dialed => |target| target,
            .accepted => claimed orelse "peer",
        };
        // What proved the durable name, from the one function that decides
        // it — not a second opinion computed here. A partner that claimed
        // no key at all reads `unauthenticated` alongside one whose claim
        // nothing on its path could prove, and `transport` beside it is
        // what lets a consumer tell those two apart.
        const provenance = if (self.partnerIdentity(session)) |identity|
            identity.provenance
        else |_|
            .unauthenticated;
        // The one name both peers of this session agree on, so a consumer
        // merging two producers' feeds can tell that they are watching the
        // same wire (`trace.wireName`). It needs both session public keys;
        // a partner that sent no key leaves it empty rather than guessed.
        var session_id_digits: trace.SessionId = undefined;
        var session_id: []const u8 = &.{};
        if (state.partnerSessionKey()) |partner_key_bytes| {
            if (crypto.PeerKey.fromSlice(partner_key_bytes)) |partner_key| {
                session_id_digits = trace.sessionId(session.sessionSecret().publicKey(), partner_key);
                session_id = &session_id_digits;
            } else |_| {}
        }
        sink.emit(sink.ctx, .{ .session_open = .{
            .session = session.peer_id,
            .designator = designator,
            .transport = session.transport,
            .provenance = provenance,
            .session_id = session_id,
            .codec = state.codec,
            .captp_version = state.captp_version,
        } });
    }

    /// Emit one message fact on `session`, noting the open first so the
    /// dialing side's first outbound cannot precede its own session-open.
    /// Both fact sites sit at the wire boundary — the inbound dispatch
    /// seat and the outbound drain — so `frame` carries the wire bytes in
    /// both directions.
    pub fn traceMessage(self: *Host, session: *HostSession, outbound: bool, verb: []const u8, frame: []const u8) void {
        const sink = self.trace_sink orelse return;
        self.traceNoteOpen(session);
        if (!session.trace_open_noted) return;
        // Tagged here, the one seam both directions pass through, so all four
        // binding veneers inherit one implementation rather than four that
        // must agree. The bytes are already in hand at both call sites.
        var digest: [trace.digest_bytes]u8 = undefined;
        std.crypto.hash.Blake3.hash(frame, &digest, .{});
        sink.emit(sink.ctx, .{ .message = .{
            .session = session.peer_id,
            .outbound = outbound,
            .verb = verb,
            .frame = frame,
            .digest = digest,
        } });
    }

    /// Emit the close fact, only for a session whose open was reported.
    pub fn traceClose(self: *Host, session: *HostSession) void {
        const sink = self.trace_sink orelse return;
        if (!session.trace_open_noted) return;
        session.trace_open_noted = false;
        sink.emit(sink.ctx, .{ .session_close = .{ .session = session.peer_id } });
    }

    /// Session lifecycle (`sessions.zig`): mint, the dialed and accepted
    /// opens, the live-session directories, and the one teardown funnel.
    pub const openDialedLocator = sessions_mod.openDialedLocator;
    pub const openDialedOver = sessions_mod.openDialedOver;
    const openDialedWith = sessions_mod.openDialedWith;
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
    pub const cancelSessionIngress = sessions_mod.cancelSessionIngress;
    const condemnRemainingSessions = sessions_mod.condemnRemainingSessions;
    const RoleSpec = sessions_mod.RoleSpec;
    const mint = sessions_mod.mint;
    const mintOver = sessions_mod.mintOver;
    const negotiatingOptions = sessions_mod.negotiatingOptions;
    const mintShell = sessions_mod.mintShell;
    const enroll = sessions_mod.enroll;
    const freeSessionShell = sessions_mod.freeSessionShell;
    const failOpen = sessions_mod.failOpen;

    /// Host vows and resolver pairs (`vows.zig`): the read side every
    /// asynchronous verb returns, and the settle machinery behind it.
    const VowRow = vows_mod.VowRow;
    pub const ResolverPair = vows_mod.ResolverPair;
    const ResolverIndexEntry = vows_mod.ResolverIndexEntry;
    pub const vowOn = vows_mod.vowOn;
    pub const vowSession = vows_mod.vowSession;
    pub const spawnResolver = vows_mod.spawnResolver;
    pub const resolverFulfill = vows_mod.resolverFulfill;
    pub const resolverBreak = vows_mod.resolverBreak;
    pub const turnForwardVow = vows_mod.turnForwardVow;
    pub const vowSend = vows_mod.vowSend;
    pub const vowIndex = vows_mod.vowIndex;
    pub const vowUntag = vows_mod.vowUntag;
    pub const vowGet = vows_mod.vowGet;
    const mintVow = vows_mod.mintVow;
    pub const createVowRow = vows_mod.createVowRow;
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

    /// The action queue (`host_action.zig`): the payload shapes and the
    /// borrowed/owned pops over the Host-owned FIFO.
    pub const nextAction = host_action.nextAction;
    pub const takeAction = host_action.takeAction;
    pub const freeAction = host_action.freeAdopted;
    pub const reserveActions = host_action.reserveActions;
    pub const testingQueueUniqueSessionAction = host_action.testingQueueUniqueSessionAction;

    /// Third-party handoff (`handoff.zig`): the node-service callbacks, the
    /// embedder's dial-ticket seam, and the give verbs.
    pub const pendingDial = handoff_mod.pendingDial;
    pub const exporterDialed = handoff_mod.exporterDialed;
    pub const dialFailed = handoff_mod.dialFailed;
    pub const provideGiftId = handoff_mod.provideGiftId;
    pub const acceptGive = handoff_mod.acceptGive;
    pub const setExporterLocation = handoff_mod.setExporterLocation;
    pub const enrollCapability = handoff_mod.enrollCapability;

    /// Sturdyref enlivenment (`enliven.zig`): a complete sturdyref becomes a
    /// live capability, selecting a session or staging a dial.
    pub const enliven = enliven_mod.enliven;
    pub const enlivenSelectOrDial = enliven_mod.enlivenSelectOrDial;
    pub const enlivenWithPolicy = enliven_mod.enlivenWithPolicy;
    const matchSturdyrefPeer = enliven_mod.matchSturdyrefPeer;
    const mintEnlivenVow = enliven_mod.mintEnlivenVow;
    const mintEnlivenVowAt = enliven_mod.mintEnlivenVowAt;
    const freeParkedEnliven = enliven_mod.freeParkedEnliven;
    const failParkedEnliven = enliven_mod.failParkedEnliven;
    const continueParkedEnliven = enliven_mod.continueParkedEnliven;
    const settleParkedEnlivens = enliven_mod.settleParkedEnlivens;

    /// Release `delta` references on the fetched capability `token` holds: the
    /// token resolves through the node to its home session and real wire
    /// import, and the release rides that peer as `op:gc-exports`. A dead home
    /// is a no-op success — the session teardown already reclaimed the counts.
    /// Release `delta` references on an import this session holds, because the
    /// application is done with it.
    ///
    /// The deliberate counterpart to `gcRelease`, which takes a node-minted
    /// token for a *fetched* capability and routes it to its home. This takes
    /// a plain wire position, which is what a capability lifted from a deliver
    /// argument or a reply actually is, and which `gcRelease` refuses. An
    /// import position means something only on the session that holds it, so
    /// the session is the argument rather than something to be looked up.
    ///
    /// Dropping authority deliberately is a capability act, not a memory
    /// optimisation, and it is why this exists beside the finalizer-driven
    /// path in ADR-0063 rather than being replaced by it: that path is
    /// best-effort, opt-in, and scoped to fetch results.
    ///
    /// The caller must stop naming the position afterwards. The partner is
    /// free to reuse it for a different object once its count reaches zero,
    /// so a handle kept past its release names whatever arrives next. The
    /// bindings enforce that by poisoning the handle; a Zig caller holds the
    /// position itself and owns the same rule.
    pub fn releaseImport(self: *Host, session: *HostSession, position: u64, delta: u64) !void {
        self.assertOwner();
        try self.checkSession(session);
        // A token is not a wire position: it names a row in the node's routing
        // table, and releasing it here would send the partner a position it
        // never exported. `gcRelease` is the verb for those.
        switch (model.ImportName.classify(position)) {
            .token => return HostError.NotAWirePosition,
            .wire => {},
        }
        const import_position = model.ImportPosition.from(position);
        if (session.served.port.peer.session_state.hostCapabilityFor(import_position) != null)
            return HostError.ImportLifted;
        // The token memo lives on the import row and disappears with its last
        // retain, so capture it before recordSend applies the decrement.
        const enrolled_token = session.served.port.peer.session_state.foreignTokenFor(import_position);
        const positions = [_]u64{position};
        const deltas = [_]u64{delta};
        try session.served.port.peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
        if (enrolled_token) |token| self.node.retireReleasedToken(token);
        try host_pump.dirtyThenPump(self, session.peer_id);
    }

    pub fn gcRelease(self: *Host, token: u64, delta: u64) !void {
        self.assertOwner();
        // The embedder hands over a bare integer, so this is one of the seams
        // where an id becomes a name. A wire position is not a token, and
        // saying so here is what keeps the rest of the verb honest.
        switch (model.ImportName.classify(token)) {
            .wire => return HostError.NotAToken,
            .token => {},
        }
        const routed = self.node.routeToken(token) orelse return;
        const session = self.sessions.get(routed.peer_id) orelse return;
        try self.checkSession(session);
        if (routed.target == .far and session.served.port.peer.session_state.hostCapabilityFor(routed.target.far.import_position) != null)
            return HostError.ImportLifted;
        const positions = [_]u64{routed.target.far.import_position.int()};
        const deltas = [_]u64{delta};
        try session.served.port.peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
        self.node.retireReleasedToken(token);
        try host_pump.dirtyThenPump(self, session.peer_id);
    }

    /// Break every far vow still parked on `session`'s vat, firing each listener
    /// inside this call with the partner's retained abort diagnostic when one
    /// arrived, else `message`. The embedder calls this when its transport
    /// reports the session gone.
    pub fn breakFarVows(self: *Host, session: *HostSession, message: []const u8) !void {
        try self.refuseReentry();
        try self.checkSession(session);
        self.in_callback = true;
        session.served.port.breakFarVows(session.served.closeReason(message));
        self.in_callback = false;
        try host_pump.finishVerb(self);
    }

    /// The verified session signer, its signed locator claim, and any matching
    /// authenticated-channel provenance for `session` (see
    /// `vocab.PartnerIdentity`), or an error when no verified signer exists.
    ///
    /// `HostError.HandshakeIncomplete` means the partner's `op:start-session`
    /// has not arrived with a key yet. `HostError.PartnerUnverified` means this
    /// session was opened with `Options.verify_partner` off, so the session key
    /// and locator signature were not verified and there is no report to hand
    /// back.
    ///
    /// That second refusal is deliberate: it is what lets every caller treat a
    /// success as "the signature was checked" without having to remember to ask
    /// how the session was configured. The returned views borrow session-owned
    /// bytes and stay valid until the session is released.
    pub fn partnerIdentity(self: *Host, session: *HostSession) !vocab.PartnerIdentity {
        self.assertOwner();
        try self.checkSession(session);
        const peer = session.served.port.peer;
        if (!peer.verify_partner_handshake) return HostError.PartnerUnverified;
        const key = peer.session_state.partnerSessionKey() orelse
            return HostError.HandshakeIncomplete;
        const designator = peer.session_state.partnerDesignator() orelse "";
        return .{
            .session_key = key,
            .designator = designator,
            .locator_record = peer.session_state.partnerLocatorRaw() orelse "",
            .provenance = durableProvenance(peer, designator),
        };
    }

    /// Assert the durable key whoever realized `session`'s byte channel proved
    /// its far end holds (ADR-0105) — the byte-fed tier's counterpart to
    /// `engine.Peer.bindVerifiedChannelKey`, and the writer whose evidence
    /// `partnerIdentity` above reports as provenance.
    ///
    /// This tier realizes nothing itself: the embedder owns the sockets, so the
    /// embedder is the realizer and this is how it testifies. An iroh listener
    /// passes what it read off the QUIC handshake. A Host whose embedder says
    /// nothing asserts nothing, which stays the default and is why the proof is
    /// volunteered rather than demanded.
    ///
    /// `designator` is that key as a locator writes it, the same bytes the
    /// transport archive hands out. It takes the designator text rather than
    /// raw key bytes so the one decoder stays in the layer that owns the rules
    /// for designators, instead of one per binding.
    ///
    /// Refused once the partner's `op:start-session` has been applied
    /// (`HostError.HandshakeAlreadyApplied`), because the pre-open chokepoint
    /// weighs the partner's claim against this proof: a proof arriving
    /// afterwards is evidence for a verdict already reached.
    ///
    /// One connection has one realizer, so naming a second key is refused
    /// (`HostError.ChannelKeyConflict`) where the native verb asserts — a
    /// foreign embedder's bug must not abort its process. Naming the same key
    /// twice is the same statement made twice and succeeds.
    pub fn bindVerifiedChannelKey(self: *Host, session: *HostSession, designator: []const u8) !void {
        self.assertOwner();
        try self.checkSession(session);
        const key = crypto.PeerKey.fromDesignator(designator) orelse
            return HostError.InvalidChannelKey;
        const peer = session.served.port.peer;
        if (peer.session_state.partnerDesignator() != null)
            return HostError.HandshakeAlreadyApplied;
        if (peer.verifiedChannelKey()) |existing| {
            if (!existing.eql(key)) return HostError.ChannelKeyConflict;
            return;
        }
        peer.bindVerifiedChannelKey(key);
    }

    // ── The pump ─────────────────────────────────────────────────────────────

    /// `pub` for the vow/enliven siblings, not for embedders. Host-core internal.
    pub fn assertOwner(self: *Host) void {
        if (comptime !std.debug.runtime_safety) return;
        const tid = std.Thread.getCurrentId();
        if (self.owner_tid) |owned| {
            std.debug.assert(owned == tid);
        } else {
            self.owner_tid = tid;
        }
    }

    /// Setup may publish reachability before the runtime thread starts. Once
    /// a runtime operation claims the Host, locator updates must stay on that
    /// same thread like every other Host mutation.
    fn assertOwnerIfClaimed(self: *const Host) void {
        if (comptime !std.debug.runtime_safety) return;
        if (self.owner_tid) |owned|
            std.debug.assert(owned == std.Thread.getCurrentId());
    }

    /// Refuse a top-level verb when the callback latch is held (and pin the
    /// owning thread under runtime safety).
    pub fn refuseReentry(self: *Host) HostError!void {
        self.assertOwner();
        if (self.in_callback) return HostError.ReenteredHost;
    }

    pub fn checkLive(session: *const HostSession) HostError!void {
        if (session.condemned) return HostError.ConnectionCondemned;
    }

    /// Prove both halves of the application boundary: the session belongs to
    /// this Host, then it is still usable. A peer id alone is insufficient;
    /// every Host starts its own id space at the same value.
    pub fn checkSession(self: *const Host, session: *const HostSession) HostError!void {
        try self.checkOwnedSession(session);
        return checkLive(session);
    }

    /// Ownership-only half for teardown and condemned-session no-op paths,
    /// which must remain legal after ordinary verbs start refusing the session.
    pub fn checkOwnedSession(self: *const Host, session: *const HostSession) HostError!void {
        if (session.host != self) return HostError.ForeignSession;
    }

    pub const CapabilityLift = struct {
        ref: capability.Ref,
        /// This observation claimed one of the import row's wire retains. A
        /// Host-internal re-observation can add only an application retain.
        claimed_wire_retain: bool,
    };

    /// Lift one session-scoped wire reference into this Host's opaque identity
    /// space and report the ownership claimed by this exact observation. Token
    /// references are first resolved to their real owning session, so a direct
    /// import and the same import reached through Node routing reuse one
    /// canonical Host row.
    pub fn liftCapabilityTracked(self: *Host, session: *HostSession, reference: model.Reference) !CapabilityLift {
        self.assertOwner();
        try self.checkSession(session);
        const source_token = engine.Node.tokenIdOf(reference);
        var claimed_wire_retain = false;
        const target: capability.Target = switch (reference) {
            .near => |near| blk: {
                if (near.kind != .object) return vocab.Error.UncallableTarget;
                const actor = session.served.refForExport(near.export_position.int()) orelse return actors.Error.NoSuchActor;
                const actor_id = switch (actor) {
                    .local => |id| id,
                    .far => unreachable,
                };
                break :blk .{ .local = actor_id };
            },
            .far => blk: {
                const routed = self.node.routeReference(session.peer_id, reference) orelse return HostError.TokenRetired;
                const home = self.sessions.get(routed.peer_id) orelse return HostError.TokenRetired;
                try self.checkSession(home);
                const far = switch (routed.target) {
                    .far => |value| value,
                    else => return HostError.ForeignArgument,
                };
                if (!home.served.port.peer.session_state.hasImport(far.import_position)) return HostError.ForeignArgument;
                if (home.served.port.peer.session_state.hostImportIdentity(far.import_position)) |identity| {
                    const existing = self.capabilities.refFromRaw(identity.ref);
                    const existing_target = self.capabilities.resolve(existing) orelse return error.UnknownCapability;
                    switch (existing_target) {
                        .remote => |remote| {
                            if (remote.peer_id != routed.peer_id or remote.far.import_position != far.import_position or remote.far.kind != far.kind)
                                return HostError.EnrolledKindConflict;
                        },
                        .local => return HostError.ForeignArgument,
                    }
                    const retained = try self.capabilities.retain(self.allocator, existing_target);
                    // A fresh wire occurrence contributes another import retain;
                    // claim it under the canonical Host row. A Host-internal
                    // re-observation (notably a sturdyref cache hit) contributes
                    // only an application retain. It must reuse the identity
                    // without inventing wire authority the exporter never sent.
                    if (identity.lifted_retains < home.served.port.peer.session_state.importRefcount(far.import_position)) {
                        home.served.port.peer.session_state.claimHostCapabilityRetain(far.import_position, identity.ref) catch |err| {
                            _ = self.capabilities.release(retained, 1) catch unreachable;
                            return err;
                        };
                        claimed_wire_retain = true;
                    }
                    if (source_token) |token| _ = self.node.consumeRedeemedToken(token);
                    return .{ .ref = retained, .claimed_wire_retain = claimed_wire_retain };
                }
                const incarnation = self.next_import_incarnation;
                if (incarnation == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
                break :blk .{ .remote = .{
                    .peer_id = routed.peer_id,
                    .far = far,
                    .incarnation = incarnation,
                } };
            },
            else => return vocab.Error.UncallableTarget,
        };
        // A fresh canonical local slot roots its actor (ADR-0101); a repeated
        // lift reuses the slot and the root it already holds.
        const fresh_local = target == .local and !self.capabilities.hasTarget(target);
        const ref = try self.capabilities.retain(self.allocator, target);
        if (fresh_local) self.vat.retainActor(target.local);
        if (target == .remote) {
            errdefer _ = self.capabilities.release(ref, 1) catch unreachable;
            const home = self.sessions.get(target.remote.peer_id) orelse return HostError.TokenRetired;
            try home.served.port.peer.session_state.noteHostCapability(target.remote.far.import_position, ref.raw());
            claimed_wire_retain = true;
            self.next_import_incarnation = target.remote.incarnation + 1;
            if (source_token) |token| _ = self.node.consumeRedeemedToken(token);
        }
        return .{ .ref = ref, .claimed_wire_retain = claimed_wire_retain };
    }

    pub fn liftCapability(self: *Host, session: *HostSession, reference: model.Reference) !capability.Ref {
        return (try self.liftCapabilityTracked(session, reference)).ref;
    }

    /// Lift a freshly Vat-spawned local actor into the opaque identity space,
    /// adopting its spawn root into the capability slot (ADR-0101). The owning
    /// spawn verbs use this instead of an eager export binding: the actor
    /// gains wire positions lazily, at first marshal onto a session
    /// (ADR-0074's grant-on-marshal), so an unpassed spawn is rooted by its
    /// handle alone and the final release reclaims it.
    pub fn liftLocalActor(self: *Host, actor: actors.Ref) !capability.Ref {
        self.assertOwner();
        const id = actorIdOf(actor);
        const target: capability.Target = .{ .local = id };
        const fresh = !self.capabilities.hasTarget(target);
        const ref = try self.capabilities.retain(self.allocator, target);
        if (fresh) {
            self.vat.retainActor(id);
            // The transfer: the slot's root replaces the spawn's.
            self.vat.releaseActor(id);
        }
        return ref;
    }

    /// Undo one lift that failed before its application handle became visible.
    /// A claimed remote occurrence is real wire authority even though C never
    /// received it, so queue its exact GC release rather than returning it to
    /// an invisible pool. If allocation pressure prevents that release, condemn
    /// the owning session; it may retain authority only until teardown and
    /// cannot admit another inbound value meanwhile.
    pub fn rollbackCapabilityLift(self: *Host, lifted: CapabilityLift) void {
        self.assertOwner();
        const target = self.capabilities.resolve(lifted.ref) orelse unreachable;
        var cleanup_failed = false;
        if (lifted.claimed_wire_retain) switch (target) {
            .local => unreachable,
            .remote => |remote| {
                const session = self.sessions.get(remote.peer_id) orelse unreachable;
                const positions = [_]u64{remote.far.import_position.int()};
                const deltas = [_]u64{1};
                if (session.served.port.peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } })) |_| {
                    session.served.port.peer.session_state.releaseHostCapabilityRetains(remote.far.import_position, lifted.ref.raw(), 1);
                    host_pump.dirtyThenPump(self, remote.peer_id) catch {
                        cleanup_failed = true;
                    };
                } else |_| {
                    cleanup_failed = true;
                }
            },
        };
        const retired = self.capabilities.release(lifted.ref, 1) catch unreachable;
        if (retired != null and target == .local) self.vat.releaseActor(target.local);
        if (retired != null and target == .remote) {
            const session = self.sessions.get(target.remote.peer_id) orelse unreachable;
            session.served.port.peer.session_state.forgetHostCapability(
                target.remote.far.import_position,
                lifted.ref.raw(),
            );
        }
        if (cleanup_failed and target == .remote) {
            const session = self.sessions.get(target.remote.peer_id) orelse return;
            host_pump.condemnAndClose(self, session, .resource_exhausted, "failed capability projection cleanup");
        }
    }

    /// Discard one wire reference occurrence that a failed application
    /// projection never exposed. A successful lift is immediately rolled back
    /// through exact GC. If even the lift cannot allocate enough bookkeeping to
    /// name what must be released, condemn the source session so it cannot
    /// accumulate more invisible imports before teardown.
    pub fn discardCapabilityObservation(self: *Host, session: *HostSession, reference: model.Reference) void {
        const lifted = self.liftCapabilityTracked(session, reference) catch {
            host_pump.condemnAndClose(self, session, .resource_exhausted, "failed capability projection cleanup");
            return;
        };
        self.rollbackCapabilityLift(lifted);
    }

    /// Reserve the Host-registry capacity needed to lift one fresh capability
    /// homed on `session`. C publish/spawn calls do this before they install an
    /// actor or bootstrap name, so allocating the returned opaque identity
    /// cannot turn a successful publication into a reported failure.
    pub fn reserveFreshCapability(self: *Host, session: *HostSession) !void {
        self.assertOwner();
        try self.checkSession(session);
        try self.capabilities.reserveFreshLocal(self.allocator);
    }

    /// Lower a live Host identity onto the session that can currently name it.
    /// Local actors project on the selected Port; remote capabilities homed on
    /// another Peer lower through `Node.enrollForeign` for handoff.
    pub fn lowerCapability(self: *Host, session: *HostSession, ref: capability.Ref) !model.Reference {
        self.assertOwner();
        try self.checkSession(session);
        const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
        return switch (target) {
            .local => |actor_id| blk: {
                if (!self.vat.hasActor(actor_id)) return actors.Error.NoSuchActor;
                break :blk .{ .near = try session.served.port.projectActor(&self.vat, .{ .local = actor_id }) };
            },
            .remote => |remote| blk: {
                const home = self.sessions.get(remote.peer_id) orelse return error.UnknownCapability;
                try self.checkSession(home);
                if (!home.served.port.peer.session_state.hasImport(remote.far.import_position)) return error.UnknownCapability;
                if (home.served.port.peer.session_state.hostCapabilityFor(remote.far.import_position) != ref.raw())
                    return error.UnknownCapability;
                if (remote.peer_id != session.peer_id)
                    break :blk try self.node.enrollForeign(remote.peer_id, .{ .far = remote.far });
                break :blk .{ .far = remote.far };
            },
        };
    }

    /// Lower one owning-tier `Value` into a wire-shaped `model.Argument` on
    /// `session`: data arms are borrowed as they stand, and each `.capability`
    /// lowers through `lowerCapability`, so a local target projects on this
    /// session's Port and a cross-home capability becomes a routable Node
    /// token. Spine containers (lists, sets, tagged bodies, struct entries)
    /// are allocated in `arena`; leaf bytes stay borrowed from the caller's
    /// value, which the send verbs' borrowed-args contract already covers. A
    /// stale or foreign capability fails the whole value closed with
    /// `error.UnknownCapability` — same posture as the C argument decode,
    /// which also leaves any already-minted projections in place.
    pub fn lowerValue(self: *Host, session: *HostSession, arena: std.mem.Allocator, value: value_mod.Value) anyerror!model.Argument {
        return switch (value) {
            .bytes => |v| .{ .bytes = v },
            .symbol => |v| .{ .symbol = v },
            .capability => |ref| .{ .reference = try self.lowerCapability(session, ref) },
            .string => |v| .{ .string = v },
            .integer => |v| .{ .integer = v },
            .boolean => |v| .{ .boolean = v },
            .list => |items| .{ .list = try self.lowerValues(session, arena, items) },
            .void => .{ .void = {} },
            .float64 => |v| .{ .float64 = v },
            .set => |items| .{ .set = try self.lowerValues(session, arena, items) },
            .tagged => |tagged| .{ .tagged = .{
                .tag = tagged.tag,
                .value = try self.lowerValues(session, arena, tagged.value),
            } },
            .keyword => |v| .{ .keyword = v },
            .big_integer => |v| .{ .big_integer = v },
            .@"struct" => |entries| blk: {
                const out = try arena.alloc(model.StructEntry, entries.len);
                for (entries, 0..) |entry, i| out[i] = .{
                    .key = entry.key,
                    .value = try self.lowerValue(session, arena, entry.value),
                };
                break :blk .{ .@"struct" = out };
            },
        };
    }

    /// `lowerValue` over a whole argument list (see it for the contract).
    pub fn lowerValues(self: *Host, session: *HostSession, arena: std.mem.Allocator, values: []const value_mod.Value) anyerror![]model.Argument {
        const out = try arena.alloc(model.Argument, values.len);
        for (values, 0..) |value, i| out[i] = try self.lowerValue(session, arena, value);
        return out;
    }

    /// Lift one wire-shaped argument into the owning tier's `Value`: every
    /// reference becomes an opaque Host capability through
    /// `liftCapabilityTracked`, so repeated observations of one import reuse
    /// one identity and the row's wire-delta accounting stays exact. Spine
    /// containers are allocated in `arena`; leaf bytes are aliased, so `arg`
    /// must own or outlive them in the same arena (the settle captures do). A
    /// failure mid-tree rolls back every lift this call performed — the same
    /// receipts discipline the C projection carries — so a refused value
    /// retains no invisible authority. The `.@"error"` and `.handoff` arms are
    /// refused `error.UnsupportedValue`: a break surfaces as `Reply.broken`,
    /// and the host redeems a give before the application sees it.
    pub fn liftValue(self: *Host, session: *HostSession, arena: std.mem.Allocator, arg: model.Argument) anyerror!value_mod.Value {
        var lifts: std.ArrayListUnmanaged(CapabilityLift) = .empty;
        errdefer {
            var i = lifts.items.len;
            while (i != 0) {
                i -= 1;
                self.rollbackCapabilityLift(lifts.items[i]);
            }
        }
        return self.liftValueInner(session, arena, arg, &lifts);
    }

    fn liftValueInner(
        self: *Host,
        session: *HostSession,
        arena: std.mem.Allocator,
        arg: model.Argument,
        lifts: *std.ArrayListUnmanaged(CapabilityLift),
    ) anyerror!value_mod.Value {
        return switch (arg) {
            .bytes => |v| .{ .bytes = v },
            .symbol => |v| .{ .symbol = v },
            .reference => |reference| blk: {
                try lifts.ensureUnusedCapacity(arena, 1);
                const lifted = try self.liftCapabilityTracked(session, reference);
                lifts.appendAssumeCapacity(lifted);
                break :blk .{ .capability = lifted.ref };
            },
            .string => |v| .{ .string = v },
            .integer => |v| .{ .integer = v },
            .boolean => |v| .{ .boolean = v },
            .list => |items| .{ .list = try self.liftValuesInner(session, arena, items, lifts) },
            .void => .{ .void = {} },
            .float64 => |v| .{ .float64 = v },
            .set => |items| .{ .set = try self.liftValuesInner(session, arena, items, lifts) },
            .tagged => |tagged| .{ .tagged = .{
                .tag = tagged.tag,
                .value = try self.liftValuesInner(session, arena, tagged.value, lifts),
            } },
            .keyword => |v| .{ .keyword = v },
            .big_integer => |v| .{ .big_integer = v },
            .@"struct" => |entries| blk: {
                const out = try arena.alloc(value_mod.Value.StructEntry, entries.len);
                for (entries, 0..) |entry, i| out[i] = .{
                    .key = entry.key,
                    .value = try self.liftValueInner(session, arena, entry.value, lifts),
                };
                break :blk .{ .@"struct" = out };
            },
            .@"error", .handoff => error.UnsupportedValue,
        };
    }

    fn liftValuesInner(
        self: *Host,
        session: *HostSession,
        arena: std.mem.Allocator,
        args: []const model.Argument,
        lifts: *std.ArrayListUnmanaged(CapabilityLift),
    ) anyerror![]value_mod.Value {
        const out = try arena.alloc(value_mod.Value, args.len);
        for (args, 0..) |arg, i| out[i] = try self.liftValueInner(session, arena, arg, lifts);
        return out;
    }

    /// `liftValue` over a whole argument list, under one receipts scope: a
    /// failure anywhere rolls back every lift the list performed.
    pub fn liftValues(self: *Host, session: *HostSession, arena: std.mem.Allocator, args: []const model.Argument) anyerror![]value_mod.Value {
        var lifts: std.ArrayListUnmanaged(CapabilityLift) = .empty;
        errdefer {
            var i = lifts.items.len;
            while (i != 0) {
                i -= 1;
                self.rollbackCapabilityLift(lifts.items[i]);
            }
        }
        return self.liftValuesInner(session, arena, args, &lifts);
    }

    /// Re-scope an ABI-stored raw id to this Host. Resolution still validates
    /// the generation; this constructor grants no authority by itself.
    pub fn capabilityFromRaw(self: *const Host, raw: u64) capability.Ref {
        return self.capabilities.refFromRaw(raw);
    }

    /// The Vat actor a live local capability names, or null for a remote or
    /// stale ref. The owning send verbs use it to run a same-side call as a
    /// direct local send: no wire position is minted and no export-binding
    /// root taken (ADR-0101), so a spawned-and-called actor still reclaims on
    /// its final release.
    pub fn localActorFor(self: *Host, ref: capability.Ref) ?actors.Ref {
        const target = self.capabilities.resolve(ref) orelse return null;
        return switch (target) {
            .local => |id| .{ .local = id },
            .remote => null,
        };
    }

    /// The live session homing a remote `ref`, for application routing
    /// metadata. Local actors belong to the Host Vat and return null because
    /// any Port may project them. A returned shell remains Host-owned and is
    /// invalidated with its remote import session.
    pub fn capabilitySession(self: *Host, ref: capability.Ref) ?*HostSession {
        const target = self.capabilities.resolve(ref) orelse return null;
        return switch (target) {
            .local => null,
            .remote => |remote| self.sessions.get(remote.peer_id),
        };
    }

    /// Release application retains on one Host capability. A remote Host row
    /// may have more application retains than wire retains (for example when a
    /// sturdyref cache reissues the same identity). Keep enough wire retains to
    /// back the surviving application retains and return only the surplus; the
    /// final application release returns every remaining wire retain. Local
    /// releases affect only the Host identity row.
    pub fn releaseCapability(self: *Host, ref: capability.Ref, delta: u64) !void {
        self.assertOwner();
        const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
        const retains = self.capabilities.retainCount(ref) orelse return error.UnknownCapability;
        if (delta > retains) return error.ReleaseExceedsRetains;
        if (delta == 0) return;

        var flush_peer: ?engine.PeerId = null;
        switch (target) {
            .local => {},
            .remote => |remote| {
                const session = self.sessions.get(remote.peer_id) orelse return error.UnknownCapability;
                try self.checkSession(session);
                const position = remote.far.import_position;
                // A partner may already have reused the numeric position after
                // another retain released the old import row. The stale Host
                // row must remain releasable, but it must not GC the replacement.
                if (session.served.port.peer.session_state.hostCapabilityFor(position) == ref.raw()) {
                    const identity = session.served.port.peer.session_state.hostImportIdentity(position) orelse
                        return error.UnknownCapability;
                    const remaining_app_retains = retains - delta;
                    const wire_delta = identity.lifted_retains -| remaining_app_retains;
                    if (wire_delta != 0) {
                        const enrolled_token = session.served.port.peer.session_state.foreignTokenFor(position);
                        const positions = [_]u64{position.int()};
                        const deltas = [_]u64{wire_delta};
                        try session.served.port.peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
                        if (enrolled_token) |token| self.node.retireReleasedToken(token);
                        session.served.port.peer.session_state.releaseHostCapabilityRetains(position, ref.raw(), wire_delta);
                        flush_peer = remote.peer_id;
                    }
                }
            },
        }
        // Every fallible protocol operation is above this commit point. The
        // retain count was validated before the wire release, so registry
        // mutation cannot now fail without an internal invariant breach.
        const retired = self.capabilities.release(ref, delta) catch unreachable;
        if (retired != null and target == .remote) {
            if (self.sessions.get(target.remote.peer_id)) |session|
                session.served.port.peer.session_state.forgetHostCapability(target.remote.far.import_position, ref.raw());
        }
        // A retired local slot releases the actor root it held (ADR-0101).
        if (retired != null and target == .local) self.vat.releaseActor(target.local);
        if (flush_peer) |peer_id| {
            host_pump.dirtyThenPump(self, peer_id) catch {
                // The GC message, import decrement, and Host retain release
                // already committed. Report consumed success and surface the
                // cleanup failure as a typed close instead of inviting retry.
                if (self.sessions.get(peer_id)) |session|
                    host_pump.condemnAndClose(self, session, .resource_exhausted, "capability release cleanup failed");
            };
        }
    }

    pub const RoutedSend = struct { session: *HostSession, target: actors.Ref };

    /// Resolve a send's target to the session and vat reference it rides: a
    /// near export to its local actor on `session`, a far reference through the
    /// node's routing (a token to its exporter session with the real
    /// reference swapped in). Fails closed when a token's exporter is gone.
    pub fn routeSend(self: *Host, session: *HostSession, target: model.Reference, args: []const model.Argument) !RoutedSend {
        self.assertOwner();
        try self.checkSession(session);
        switch (target) {
            .near => |near| {
                const ref = session.served.refForExport(near.export_position.int()) orelse return actors.Error.NoSuchActor;
                return .{ .session = session, .target = ref };
            },
            .far => {
                const routed = self.node.routeReference(session.peer_id, target) orelse return HostError.TokenRetired;
                const routed_conn = self.sessions.get(routed.peer_id) orelse return HostError.TokenRetired;
                try self.checkSession(routed_conn);
                for (args) |argument| {
                    if (self.argIsForeignDeep(routed_conn.peer_id, argument)) return HostError.ForeignArgument;
                }
                return .{ .session = routed_conn, .target = .{ .far = routed.target.far } };
            },
            else => return vocab.Error.UncallableTarget,
        }
    }

    /// Whether any reference in `argument`'s tree is foreign to `peer_id`
    /// (see `engine.Node.argIsForeign`). Caller-supplied data, so the walk
    /// recurses the application's own nesting. Public because the C driver
    /// tier's turn-time forward applies the same refusal before it hands a
    /// message to a turn, off the `send` path that checks it here.
    pub fn argIsForeignDeep(self: *Host, peer_id: engine.PeerId, argument: model.Argument) bool {
        return switch (argument) {
            .reference => |ref| self.node.argIsForeign(peer_id, ref),
            .list, .set => |items| for (items) |item| {
                if (self.argIsForeignDeep(peer_id, item)) break true;
            } else false,
            .tagged => |tagged| for (tagged.value) |item| {
                if (self.argIsForeignDeep(peer_id, item)) break true;
            } else false,
            .@"struct" => |entries| for (entries) |entry| {
                if (self.argIsForeignDeep(peer_id, entry.value)) break true;
            } else false,
            else => false,
        };
    }

    /// Test seam for the irreversible condemnation boundary.
    pub fn testingCondemn(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) !void {
        try host_pump.condemn(self, session, kind, message);
    }

    pub fn testingMarkDirty(self: *Host, peer_id: engine.PeerId) void {
        host_pump.testingMarkDirty(self, peer_id);
    }

    // ── Hooks ────────────────────────────────────────────────────────────────

    /// The before-serve hook on every host CapTP session. Three arms, in order:
    /// an inbound start-session on an accepted session runs the
    /// crossed-hellos tiebreak and partner-key refuse (skipping serve when
    /// this session is condemned); a resolve fulfilling with a signed handoff
    /// give is auto-redeemed — the node accepts it and the vat never sees a
    /// raw give, so the vow later settles with the routable token; any other
    /// resolve is offered to the node, which claims it when it settles a
    /// pending withdraw.
    /// `pub` for the Host-core siblings, not for embedders. Host-core internal.
    pub fn hostBeforeServe(ctx: ?*anyopaque, served: *Served, event: *engine.Event) anyerror!bool {
        _ = served;
        const session: *HostSession = @ptrCast(@alignCast(ctx.?));
        const host = session.host;
        const body = event.view() catch return false;
        // The live trace's inbound seat: every event notices a just-opened
        // session (the accepting side opens during the previous feed's
        // start-session), and an inbound deliver reports its verb. The verb
        // is the deliver's first argument by the engine's [verb, args...]
        // splice; a deliver without one is protocol traffic the trace skips.
        host.traceNoteOpen(session);
        if (host.trace_sink != null and body == .deliver) trace_verb: {
            const args = body.deliver.args;
            const first = args.at(0) catch break :trace_verb;
            if (first == .symbol) host.traceMessage(session, false, first.symbol, event.bytes());
        }
        if (body == .start_session) {
            if (session.role == .accepted) try host.tiebreakInbound(session, body.start_session);
            // After tiebreak (or when there was no crossed dial), keep at most
            // one non-condemned session per CapTP partner key (ADR-0012).
            try host.refuseDuplicatePartnerKey(session, body.start_session);
            // Condemnation must skip apply: a duplicate/tiebreak loser must not
            // learn partner key / open the session on this same feed turn.
            return session.condemned;
        }
        // Introducing-session proxy: a home-session listen fire for a
        // re-exported foreign promise is Node choreography, not a vat deliver.
        if (try claimProxyListenerFire(host, session.peer_id, event)) {
            // A converged subscription may serve Node proxy recipients and
            // application answers from the same callback. The Node takes its
            // owned materialization above; the Vat still receives the
            // semantic resolve and its aliases.
            if (body != .resolve) return true;
        }
        if (body != .resolve) {
            switch (body) {
                .deliver, .listen, .get, .index, .untag => host.node.exporterApplicationOwned(session.peer_id),
                .resolve, .gc_export, .gc_answer, .start_session, .abort => {},
            }
            return false;
        }
        const resolve = body.resolve;
        if (resolve.resolution == .fulfill) {
            const value = resolve.resolution.fulfill;
            if (value == .handoff and value.handoff == .give) {
                var projected = try engine.handoff_recipient.projectGiveForRedeem(
                    host.allocator,
                    value.handoff.give,
                );
                defer projected.deinit(host.allocator);
                // A give whose locator no longer projects still claims:
                // `acceptGive` fails the answer closed on the empty locator, so
                // the vow breaks instead of surfacing a raw give no settle
                // listener has an arm for.
                const locator = switch (projected.locator) {
                    .uri => |uri| uri,
                    .absent, .malformed => "",
                };
                // Empty give octets when projection failed: `acceptGive` fails
                // the answer closed instead of surfacing a raw give.
                try host.node.acceptGive(session.peer_id, resolve.answer.int(), projected.bytes() orelse "", locator);
                return true;
            }
        }
        const claimed = try host.node.claimResolve(session.peer_id, resolve.answer.int(), redeemOutcome(resolve));
        if (!claimed) host.node.exporterApplicationOwned(session.peer_id);
        return claimed;
    }

    /// `pub` for the Host-core siblings, not for embedders. Host-core internal.
    pub fn hostResolveInterceptor(ctx: ?*anyopaque, answer: model.AnswerPosition, fulfilled: model.Argument) anyerror!actors.InterceptOutcome {
        const session: *HostSession = @ptrCast(@alignCast(ctx.?));
        // A claim's `need_gift_id` and flush actions pump at the enclosing
        // feed's unwind; nothing blocks here.
        return interceptFulfilled(&session.host.node, session.peer_id, answer, fulfilled);
    }

    /// Claim an inbound deliver that fires a Node proxy home-listener export
    /// (ADR-0009). True when the node relayed; false leaves the event for the vat.
    /// Peeks before materializing so ordinary listen fires pay no deep clone on
    /// the miss path. Once the export is a proxy listener, malformed resolver
    /// args fail closed (never fall through to the vat).
    fn claimProxyListenerFire(host: *Host, peer_id: engine.PeerId, event: *const engine.Event) !bool {
        const body = event.wireView() catch return false;
        if (body != .deliver) return false;
        const deliver = body.deliver;
        const export_pos = switch (deliver.target) {
            .near => |near| near.export_position.int(),
            else => return false,
        };
        if (!host.node.isProxyHomeListener(peer_id, export_pos)) return false;
        // The partner holds this export legitimately: it was mentioned on the
        // wire in the `op:listen` that armed the proxy. So a deliver arriving
        // here in a shape other than a resolver callback is a partner that
        // used a reference it holds in a way the export does not accept — a
        // session-state violation. The frame itself decoded, and reporting it
        // as a codec malformation would send whoever reads the abort looking
        // for a wire bug that is not there.
        const view_res = engine.events.resolutionFromResolverCallback(deliver.args) catch
            return error.UnexpectedMessage;
        return try host.node.claimProxyListenerFire(host.allocator, peer_id, export_pos, view_res);
    }

    /// Run the crossed-hellos tiebreak for an inbound start-session on an
    /// accepted CapTP session (ADR-0030): with an outbound dial registered to the
    /// same partner, the not-lower side condemns its accepted session, and
    /// the strictly lower side condemns its own dialed one — immediately, no
    /// deferred flag, because one thread drives the host.
    fn tiebreakInbound(self: *Host, session: *HostSession, ss: model.view.StartSession) !void {
        const partner_key = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return;
        const partner_pid = crypto.derivePublicIdentifier(partner_key);
        const designator = ss.acceptable_location.designator;
        // The designator here is a claim, not a proof. The handshake signature
        // establishes that the partner holds `session_pubkey` and made this
        // locator claim; it does not establish ownership of the durable key or
        // address the claim names. On the transports
        // whose designator *is* the identity, the two must agree, or any peer
        // able to open a connection could name a designator we are dialing and
        // have us abort our own verified outbound session to it — repeatedly,
        // and against an exporter it never has to reach or hold a key for.
        // `liveSessionForDial` already refuses to trust this same field as a
        // dial match key for the same reason.
        //
        // An address designator stays an unverifiable claim, and it still
        // decides the tiebreak, because the OCapN suite's crossed-hellos test
        // requires exactly that: an address transport has nothing else to match
        // on at hello time. Refusing to act on it there is not ours to choose —
        // dropping it makes that test hang waiting for the abort. So on an
        // address transport a peer that can open a connection and name an
        // address we are dialing can condemn our dial to it. That exposure is
        // ADR-0030's model, not an oversight, and it is why a designator that
        // *is* an identity is the one that gets checked; see
        // `docs/boundaries.md`.
        if (vocab.designatorSchemeForTransport(ss.acceptable_location.transport) == .key) {
            const claimed = crypto.PeerKey.fromDesignator(designator) orelse return;
            if (!std.mem.eql(u8, &claimed.bytes, &partner_key.bytes)) return;
        }
        const dial_target: DialTarget = .{
            .transport = ss.acceptable_location.transport,
            .designator = designator,
        };
        const verdict = self.hellos.checkInbound(dial_target, partner_pid) orelse return;
        if (verdict.abort_inbound) {
            // Not lower: this accepted session is the loser; the pair keeps
            // the session our own dial opened.
            try host_pump.condemn(self, session, .crossed_hellos, "crossed hellos: higher-keyed side aborting its inbound session");
            return;
        }
        // Strictly lower: our own dial to this partner is the loser; the pair
        // keeps this accepted session. `dialed_by_target` is the O(1)
        // index (populated at enroll); do not rescan every live session.
        if (self.liveIndexedSession(self.dialed_by_target.get(dial_target))) |candidate| {
            try host_pump.condemn(self, candidate, .crossed_hellos, "crossed hellos: lower-keyed side aborting its outbound session");
        }
    }
};

/// One delivery into a Value-shaped hosted behavior (see `Hosting`): the
/// behavior's window onto the owning tier. It carries the composed Host, the
/// ingress session, and the underlying actor turn, so a handler can mint new
/// opaque capabilities without touching wire positions.
pub const HostTurn = struct {
    host: *Host,
    session: *HostSession,
    turn: *actors.Turn,

    /// Spawn a fresh local actor mid-turn and return its opaque capability —
    /// the owning-tier twin of `spawnAt`. The spawned behavior is Value-shaped
    /// like every owning-tier behavior.
    pub fn spawn(self: *HostTurn, comptime Behavior: type, initial: Behavior) !capability.Ref {
        const ref = try self.turn.vat.spawn(Hosting(Behavior), .{ .inner = initial });
        errdefer self.turn.vat.discardFreshActor(ref);
        return self.host.liftLocalActor(ref);
    }
};

/// Adapt a Value-shaped behavior to the actor layer's wire-shaped contract —
/// the native twin of the C ABI's hosted-behavior trampoline. `B` declares
///
/// ```zig
/// pub fn handle(self: *B, ht: *HostTurn, verb: []const u8, args: []const Value) !Value
/// ```
///
/// Inbound wire arguments are lifted through the ingress session (so a
/// delivered capability arrives as one canonical opaque identity), and the
/// returned reply is lowered through the same session's Port. Both walks use
/// the turn arena, whose lifetime is exactly the borrowed reply's contract.
/// The owning `Session.spawn` / `Session.publish` and Host-wide
/// `publishGiftable` wrap every behavior in this adapter; the base Vat and the
/// borrowing tier keep the wire-shaped contract.
pub fn Hosting(comptime B: type) type {
    return struct {
        inner: B,

        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
            const port = turn.port orelse return actors.Error.NotConnected;
            const served: *Served = @fieldParentPtr("port", port);
            const session: *HostSession = @alignCast(@fieldParentPtr("served", served));
            const host = session.host;
            const values = try host.liftValues(session, turn.arena, msg.args);
            var host_turn = HostTurn{ .host = host, .session = session, .turn = turn };
            const reply = try self.inner.handle(&host_turn, msg.verb, values);
            return host.lowerValue(session, turn.arena, reply);
        }

        /// Forward the wrapped behavior's state teardown, so a reclaimed or
        /// torn-down actor releases what its state owns. Like the C hosted
        /// bridge, the adapter itself declares no `clone`, so a Vat holding a
        /// Value-shaped actor is not snapshottable.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (@hasDecl(B, "deinit")) self.inner.deinit(allocator);
        }
    };
}
