//! The sans-io byte-fed multi-session CapTP host core (ADR-0072), under the
//! `driver_core` I/O ban. A `Host` owns one `engine.Node` (identity,
//! live-session directory, routing, the redeem serve step) and mints byte-fed
//! sessions (`HostSession`) whose peers are node-registered, so
//! everything the node decides — where a token routes, which exporter a give
//! withdraws from, when a served reply becomes a signed give — happens under
//! every session the host holds, with no socket in sight. The embedder owns
//! the loop, the sockets, and the entropy: it feeds inbound bytes with `feed`
//! (a whole frame), `feedBytes` (a raw stream the core delimits), or
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
    /// A `keyed-tcp` accept was opened with an empty `direct_addresses_hint`.
    /// TCP has no discovery, so the signed locator must carry where to dial
    /// (ADR-0075). `iroh` accepts may omit the hint (discovery can resolve by
    /// node id alone).
    MissingDirectAddressesHint,
    /// A CapTP session for this partner identity is already enrolled (ADR-0012):
    /// dial↔dial by our dialed designator, or a keyed dial whose designator is
    /// a live verified partner session key. Crossed hellos may still open an
    /// accepted session while a dial is in flight; after the partner key is
    /// known the Host keeps at most one non-condemned session (ADR-0068 key
    /// order collapses the race, including mismatched designator spellings).
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
};

pub const EnlivenPeerPolicy = enum {
    /// Require a verified key-designator identity or the exact address this
    /// side dialed. An accepted address-session assertion is refused.
    checked,
    /// Permit an accepted address transport's signed-but-unproved locator
    /// claim. The returned provenance remains explicit.
    assertion_only,
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
const session_seed_domain = "pancake session-key v1";

pub const PeerProvenance = enum { verified, dial_target, assertion_only };

pub const EnlivenStart = struct {
    vow_id: u64,
    provenance: PeerProvenance,
};

/// One enliven parked on a staged dial (`Host.enlivenSelectOrDial`). The vow
/// id was minted before any session existed, so nothing in the core holds a
/// row for it: the outcome reaches the caller as that id's `settled` / `failed`
/// action, the same way a dedup-cache hit's does. The sturdyref bytes are
/// host-owned for the row's life because the asking call has long returned.
const PendingEnliven = struct {
    ticket: engine.Node.PendingId,
    vow_id: u64,
    sturdyref: model.SturdyRef,
};

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
fn asFarRef(arg: model.Argument) ?@FieldType(model.Reference, "far") {
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
/// serve core, minted by `Host.openDialedLocator` / `openAccepted` and freed
/// by `Host.releaseSession`. This is not a `net.Connection` — it is the CapTP
/// partner the host routes and serves; the ABI spelling stays
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
    /// Set when this session lost the crossed-hellos tiebreak: its typed
    /// abort is queued, and every verb refuses `ConnectionCondemned`.
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
        return self.served.takeOutbound();
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

/// Delimit and dispatch every complete frame at the front of `bytes`,
/// returning how many leading bytes were consumed. Serves each frame's
/// events before delimiting the next, so ordering matches the whole-frame
/// path, and pauses at the session-open transition: the frames behind the
/// hello wait for the embedder's post-open setup.
fn parseStreamPrefix(session: *HostSession, bytes: []const u8, was_open: bool) !usize {
    var consumed: usize = 0;
    while (consumed < bytes.len) {
        const outcome = try session.served.port.peer.recvStreamPrefix(bytes[consumed..]);
        switch (outcome) {
            .incomplete => break,
            .consumed => |n| {
                consumed += n;
                try session.served.driveFed(&session.host.vat);
                if (!was_open and session.served.port.peer.sessionIsOpen()) break;
            },
        }
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

fn resolvePublishedTarget(ctx: ?*anyopaque, scope: engine.PeerId, swissnum: []const u8) !?model.ExportPosition {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return null;
    const row = host.giftables.get(swissnum) orelse return null;
    return (try session.served.port.projectActor(&host.vat, row.actor)).export_position;
}

fn actorIdOf(ref: actors.Ref) u64 {
    return switch (ref) {
        .local => |id| id,
        .far => unreachable,
    };
}

fn captureGiftTarget(ctx: ?*anyopaque, scope: engine.PeerId, export_position: model.ExportPosition) ?u64 {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return null;
    const ref = session.served.port.refForExport(export_position.int()) orelse return null;
    const actor_id = switch (ref) {
        .local => |id| id,
        .far => return null,
    };
    if (!session.host.vat.hasActor(actor_id)) return null;
    // The exact gift row roots its actor (ADR-0101); `release_target` hands
    // the root back when the row dies, and the deposit path hands it back
    // itself if the row is never admitted.
    host.vat.retainActor(actor_id);
    return actor_id;
}

fn releaseGiftTarget(ctx: ?*anyopaque, target: u64) void {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    host.vat.releaseActor(target);
}

fn projectGiftTarget(ctx: ?*anyopaque, scope: engine.PeerId, target: u64) !engine.bootstrap.ProjectedLocalTarget {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return error.UnknownCapability;
    if (!session.host.vat.hasActor(target)) return actors.Error.NoSuchActor;
    const projection = try session.served.port.prepareProjection(&host.vat, .{ .local = target });
    return .{
        .export_position = projection.near.export_position,
        .created = projection.created,
    };
}

fn rollbackGiftTarget(ctx: ?*anyopaque, scope: engine.PeerId, target: u64, projected: engine.bootstrap.ProjectedLocalTarget) void {
    if (!projected.created) return;
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const session = host.sessions.get(scope) orelse return;
    session.served.port.rollbackExport(&host.vat, .{ .local = target }, projected.export_position.int());
}

fn resolveGifterSession(ctx: ?*anyopaque, gifter_side: [32]u8, session_name: []const u8) ?engine.bootstrap.GifterSession {
    const host: *Host = @ptrCast(@alignCast(ctx.?));
    const peer_id = host.partner_by_side.get(gifter_side) orelse return null;
    const session = host.liveIndexedSession(peer_id) orelse return null;
    if (!session.sessionOpen()) return null;
    const peer = session.served.port.peer;
    if (!peer.verify_partner_handshake) return null;
    const key = engine.bootstrap.gifterKeyForSession(&peer.session_state, gifter_side, session_name) orelse return null;
    return .{ .peer_id = peer_id, .key = key, .gifts = peer.giftRegistry() };
}

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
    /// what "do I already have a session reaching P" must ask. They coincide
    /// today only because every session reuses its host's key, and they stop
    /// coinciding the moment each connection draws a fresh one — at which
    /// point a dial-dedup question routed through the side index would find
    /// nothing and open a duplicate session per dial.
    ///
    /// Only an authenticated durable identity is indexed
    /// (`vocab.DurableProvenance`): an unproved claim as a dial-match key is
    /// exactly the squatting hazard `liveSessionForDial` refuses.
    ///
    /// Keyed by the durable key's own 32 bytes rather than its hex spelling,
    /// so a row can be written from a borrowed hello view before apply, which
    /// is when duplicate collapse needs it, without retaining bytes the frame
    /// owns.
    peer_by_durable: std.AutoHashMapUnmanaged([crypto.PEER_KEY_BYTES]u8, engine.PeerId) = .{},
    /// Our own dialed designator → peer id. Keys borrow `session.role.dialed`
    /// (removed in `unindexSession` before those bytes free). O(1) dial↔dial
    /// refuse; the dial target bytes are ones we chose, not partner-declared
    /// location claims.
    dialed_by_designator: std.StringHashMapUnmanaged(engine.PeerId) = .{},
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
    pending_enlivens: std.ArrayListUnmanaged(PendingEnliven) = .empty,
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
        /// The wire grammar every minted session negotiates in. Defaults to
        /// Syrup, the v1.0 interop floor; both ends of a session must
        /// carry the same codec (`op:start-session` carries no codec operand,
        /// so agreement is the embedder's).
        codec: model.CodecId = .syrup,
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

    /// One live host vow. The row holds the vow's single vat listener slot
    /// from mint (`fire`), so settlement always retires the row. An
    /// in-process listener chains through `inner`, set once by `vowOn`, and
    /// hears the resolution borrowed (zero-copy); a vow with no listener
    /// settles as a queued `settled`/`failed` completion instead, so an
    /// embedder that only drains the action queue still hears every outcome.
    const VowRow = struct {
        host: *Host,
        /// The session the vow rides, or null for a resolver row (ADR-0102),
        /// which belongs to no session: session release never drops it, the
        /// session-scoped vow verbs refuse it (`SessionlessVow`), and its
        /// retire is the resolver settle itself.
        peer_id: ?engine.PeerId,
        id: u64,
        vow: actors.Vow,
        kind: Kind = .plain,
        inner: ?actors.Listener = null,
        /// The session whose turn deferred its answer onto this resolver vow
        /// (ADR-0102), recorded by `turnForwardVow` so the settle can mark it
        /// dirty — a resolver settle is the one vat settle that runs outside
        /// any `feed`, so nothing else would encode the resolved answer.
        /// Distinct from `peer_id` on purpose: that session's release must
        /// not drop this row (the resolver stays settleable; the dead wire
        /// answer just has no one to hear it).
        forwarded_peer: ?engine.PeerId = null,

        /// What settlement does to the resolution before it is dispatched: a
        /// `fetch` vow's fulfilled far capability is enrolled under a
        /// node-unique token first (ADR-0069).
        const Kind = enum { plain, fetch };

        /// The retire listener installed at mint.
        fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const row: *VowRow = @ptrCast(@alignCast(ctx.?));
            row.host.settleRow(row, resolution);
        }
    };

    /// A host bound to the caller-supplied identity `seed` (drawn at the
    /// embedder's entropy boundary; the sans-io host never generates it). The
    /// node reuses the identity for every CapTP session, so an exporter verifies
    /// a handoff signature against the one key the gifter named.
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
        self.dialed_by_designator.deinit(self.allocator);
        if (self.last_action) |last| host_action.freeAction(self.allocator, last);
        for (self.actions.unpopped()) |action| host_action.freeAction(self.allocator, action);
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

    /// Record the designator this host's dials sign as their own dialable
    /// address (a host that also listens). Copied into the retained buffer;
    /// empty resets to the unreachable-client placeholder.
    pub fn setSelfDesignator(self: *Host, designator: []const u8) HostError!void {
        if (designator.len > self.self_designator.len) return HostError.DesignatorTooLong;
        @memcpy(self.self_designator[0..designator.len], designator);
        self.self_designator_len = designator.len;
    }

    fn selfDesignator(self: *const Host) []const u8 {
        if (self.self_designator_len == 0) return vocab.unreachable_client_designator;
        return self.self_designator[0..self.self_designator_len];
    }

    // ── Connection lifecycle ─────────────────────────────────────────────────

    /// Mint the dialing half of a session to the peer `locator` names:
    /// register the outbound with the crossed-hellos table, register the session
    /// on the node, and sign and encode the keyed `op:start-session` under the
    /// host identity, naming this host's own designator. The hello is encoded
    /// before this returns; the embedder drains it with `takeOutbound` (a
    /// flush action is queued) and drives the handshake byte-fed. URI holders
    /// parse first (`model.uri.parsePeer`) — same spine as
    /// `pancake_host_session_open_dialed_locator`. The locator is borrowed for
    /// the call. The loop-fed bridge adopts with `openDialedOver` after
    /// `Loop.dialLocator` completes; this path mints the peer.
    pub fn openDialedLocator(self: *Host, locator: model.PeerLocator) !*HostSession {
        return self.openDialedWith(.mint, locator.transport, locator.designator);
    }

    /// `openDialedLocator` over a peer the embedder owns and pins at a stable
    /// address: identical wiring — crossed-hellos outbound registration, the
    /// keyed initiator hello signed under the host identity naming this
    /// host's own designator, optional `expectPartnerKey` — minus ownership.
    /// The node routes through the adopted peer but never frees it: the
    /// embedder frees the peer itself, only after `releaseSession`. This is the
    /// completion loop's dialed adoption seam — the dial half of
    /// `openAcceptedOver` (ADR-0076 loop-side dial executor).
    pub fn openDialedOver(
        self: *Host,
        peer: *engine.Peer,
        transport: []const u8,
        partner_designator: []const u8,
    ) !*HostSession {
        return self.openDialedWith(.{ .over = peer }, transport, partner_designator);
    }

    /// Shared dialed-open core: `openDialedLocator` mints a node-owned peer;
    /// `openDialedOver` adopts an embedder-owned one. Everything else is one
    /// path — crossed-hellos, role, keyed pin, hello — so the two entry
    /// points cannot drift.
    fn openDialedWith(
        self: *Host,
        source: union(enum) { mint: void, over: *engine.Peer },
        transport: []const u8,
        partner_designator: []const u8,
    ) !*HostSession {
        try self.refuseReentry();
        try self.refuseDuplicateDial(partner_designator);
        // The designator is borrowed all the way to `mintShell`, which dupes it
        // into the shell. One owner from birth: `freeSessionShell` is the only
        // free, so a refusal below can unwind the mint without this frame
        // holding an obligation to discharge as well.
        const session = switch (source) {
            .mint => try self.mint(.{ .dialed = partner_designator }, transport),
            .over => |peer| try self.mintOver(peer, .{ .dialed = partner_designator }, transport),
        };
        // Register the outbound before any bytes move: a crossed inbound
        // start-session from the same partner must find this dial (ADR-0030).
        // The mint above moves none, so this is still ahead of the hello.
        //
        // Two identities, two roles (ADR-0097). `partner_designator` is the
        // durable peer this dial races for, which is what decides *which two
        // attempts are racing*. The identifier beside it is this outbound
        // connection's own session identity, which is what decides *which of
        // the two survives*. Registering after the mint is what lets the
        // second one be the session's key rather than the host's: they are the
        // same value only when a host signs every session with its durable
        // key, and reading the wrong one would order the tiebreak by a
        // quantity both connections to a peer share.
        const our_session_id = crypto.derivePublicIdentifier(session.sessionSecret().publicKey());
        self.hellos.registerOutbound(self.allocator, partner_designator, our_session_id) catch |err| {
            self.failOpen(session);
            return err;
        };
        errdefer self.hellos.unregister(self.allocator, partner_designator);
        // Dialed-specific pin before hello; on failure unwind the mint. The
        // shared open tail's `errdefer failOpen` covers hello failures.
        if (vocab.designatorSchemeForTransport(transport) == .key) {
            const expected = crypto.PeerKey.fromDesignator(partner_designator) orelse {
                self.failOpen(session);
                return error.InvalidAddress;
            };
            session.served.port.peer.expectPartnerDurableKey(expected, .dial_expectation);
        }

        return self.helloAndEnroll(session, transport, self.selfDesignator(), &.{});
    }

    /// Mint the accepting half of a session the embedder's own listener
    /// produced: register the session on the node and sign the keyed
    /// `op:start-session` under the host identity, naming the listener's own
    /// `transport`/`designator` — the address a partner can actually dial, and
    /// the locator record a give made on this host names as the exporter
    /// location. On `keyed-tcp` `direct_addresses_hint` is required (TCP has no
    /// discovery). `iroh` is also a key-designator transport, but discovery can
    /// resolve a node id with no direct-address hint, so an empty hint keeps the
    /// `#f` empty-hints spelling. An address-designator transport ignores the
    /// hint the same way.
    pub fn openAccepted(self: *Host, transport: []const u8, designator: []const u8, direct_addresses_hint: []const u8) !*HostSession {
        try self.refuseReentry();
        if (vocab.requiresDirectAddressesHint(transport) and direct_addresses_hint.len == 0)
            return HostError.MissingDirectAddressesHint;
        return self.helloAndEnroll(try self.mint(.accepted, transport), transport, designator, direct_addresses_hint);
    }

    /// `openAccepted` over a peer the embedder owns and pins at a stable
    /// address: identical wiring — the keyed responder hello signed under the
    /// host identity, crossed-hellos registration, enrollment — minus
    /// ownership. The node routes through the adopted peer but never frees
    /// it: the embedder frees the peer itself, only after `releaseSession` has
    /// retired the session. This is the completion loop's adoption seam —
    /// its fixed slots hold each peer inline, so the loop keeps the peer and
    /// the host serves it. `direct_addresses_hint` follows `openAccepted`.
    pub fn openAcceptedOver(self: *Host, peer: *engine.Peer, transport: []const u8, designator: []const u8, direct_addresses_hint: []const u8) !*HostSession {
        try self.refuseReentry();
        if (vocab.requiresDirectAddressesHint(transport) and direct_addresses_hint.len == 0)
            return HostError.MissingDirectAddressesHint;
        return self.helloAndEnroll(try self.mintOver(peer, .accepted, transport), transport, designator, direct_addresses_hint);
    }

    /// The live, non-condemned session that already reaches `partner_designator`
    /// (ADR-0012), or null. One authority two callers read: this host refuses a
    /// duplicate app dial against a non-null result, and the node-action pump
    /// reuses that session to redeem a give rather than dial a duplicate it would
    /// then refuse. Match set: our dialed designator (bytes we chose), or — for
    /// key-designator transports only — a live session whose verified partner
    /// session key matches. A partner-declared `acceptable_location.designator`
    /// on an address transport is never a match key: the hello signature proves
    /// the claim, not ownership of a tcp `host:port`, so trusting it would let an
    /// inbound peer squat dial availability. Dedup against an accepted tcp session
    /// still runs after the newcomer's start-session via `refuseDuplicatePartnerKey`
    /// (verified key); an accepted session racing an in-flight dial stays legal
    /// for crossed hellos until start-session (ADR-0068).
    pub fn liveSessionForDial(self: *const Host, partner_designator: []const u8) ?*HostSession {
        if (self.liveIndexedSession(self.dialed_by_designator.get(partner_designator))) |s| return s;
        // The durable-peer directory, never the side index (ADR-0097): this
        // asks "which live session reaches peer P", and P is a durable
        // identity. Deriving a side name from P instead would be asking the
        // session-incarnation directory a question it only answers while
        // every session reuses its host's key.
        const want = crypto.PeerKey.fromDesignator(partner_designator) orelse return null;
        return self.liveIndexedSession(self.peer_by_durable.get(want.bytes));
    }

    /// Refuse a new dial when a live session already reaches this partner.
    fn refuseDuplicateDial(self: *const Host, partner_designator: []const u8) HostError!void {
        if (self.liveSessionForDial(partner_designator) != null) return HostError.SessionPairExists;
    }

    /// After crossed-hellos tiebreak, keep at most one non-condemned session to
    /// the same CapTP partner key (dual-accept settlement, or a dial that
    /// slipped past pre-identity refuse). Survivor choice follows the ADR-0068
    /// / crossed-hellos key order (`CrossedHellos.checkInbound`): both peers
    /// independently keep the session the higher-keyed peer opened — dialed
    /// when we are higher, accepted when we are lower — so a crossed pair that
    /// missed designator-spelling tiebreak still collapses to the same session
    /// on both ends rather than condemning by local arrival order. Same-role
    /// duplicates (dual-accept) keep the already-indexed session and condemn
    /// the newcomer.
    fn refuseDuplicatePartnerKey(self: *Host, session: *HostSession, ss: model.view.StartSession) !void {
        if (session.condemned) return;
        // With signature verification disabled, `session_pubkey` is only a
        // partner assertion. It cannot identify a peer for deduplication or
        // authorize early handoff verification.
        if (!session.served.port.peer.verify_partner_handshake) return;
        const partner_key = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return;
        const side = try engine.handoff_names.sideName(&partner_key.bytes);
        // Two questions, and only the second identifies a *peer* once each
        // connection draws its own key (ADR-0097). A matching session key means
        // the same session incarnation, which is a duplicate of the narrowest
        // kind. A matching proved durable identity means the same peer reached
        // twice, which is the duplicate ADR-0068 exists to collapse — and it is
        // the only one that survives fresh keys, because two connections to one
        // peer no longer share a session key.
        //
        // Only a *proved* durable identity counts: `peer_by_durable` indexes
        // nothing else, so a partner that merely asserts a name cannot use this
        // to condemn a session, which is the same refusal `liveSessionForDial`
        // makes. A transport that proves no durable identity therefore has no
        // collapse here, and the crossed-hellos declared-location match remains
        // its only one, with the weakness ADR-0030 already states.
        const durable_dup: ?engine.PeerId = if (durablePeerKeyFor(session, ss.acceptable_location.designator)) |claimed|
            self.peer_by_durable.get(claimed)
        else
            null;
        const existing_pid = durable_dup orelse self.partner_by_side.get(side) orelse {
            try self.indexPartnerKey(session, partner_key.bytes, ss.acceptable_location.designator);
            return;
        };
        const other = self.liveIndexedSession(existing_pid) orelse {
            // Stale index row (session released without unindex); replace.
            try self.indexPartnerKey(session, partner_key.bytes, ss.acceptable_location.designator);
            return;
        };
        if (other == session) {
            try self.indexPartnerKey(session, partner_key.bytes, ss.acceptable_location.designator);
            return;
        }
        // A side-name match must still be exact-key equality; a durable-peer
        // match is deliberately across different session keys, so it skips the
        // check that would reject precisely the case it is here to catch.
        if (durable_dup == null and (other.indexed_partner_key == null or
            !std.mem.eql(u8, &other.indexed_partner_key.?, &partner_key.bytes)))
        {
            // A side-name collision is not partner-key equality. Refuse the
            // newcomer rather than replacing an unrelated live index row.
            return HostError.SessionPairExists;
        }

        // Ordered by the two *session* identities, as crossed hellos are
        // (ADR-0097): ours on this connection against the partner's on it. The
        // durable keys are equal on both racing connections by definition, so
        // they cannot order anything.
        const our_pid = crypto.derivePublicIdentifier(session.sessionSecret().publicKey());
        const partner_pid = crypto.derivePublicIdentifier(partner_key);
        // Same rule as crossed hellos: not-lower aborts inbound / keeps dialed.
        const we_are_lower = std.mem.order(u8, &our_pid.bytes, &partner_pid.bytes) == .lt;
        const prefer_accepted = we_are_lower;

        const loser: *HostSession = blk: {
            const session_accepted = session.role == .accepted;
            const other_accepted = other.role == .accepted;
            if (session_accepted != other_accepted) {
                const session_preferred = session_accepted == prefer_accepted;
                break :blk if (session_preferred) other else session;
            }
            // Same role: keep the already-indexed session (stable under dual-accept).
            break :blk session;
        };
        try host_pump.condemn(self, loser, .protocol_error, "session pair exists: duplicate CapTP partner identity");
        if (loser == other) try self.indexPartnerKey(session, partner_key.bytes, ss.acceptable_location.designator);
    }

    /// Index a live session under its verified partner session key. Replaces any
    /// prior row for that key (caller condemned the previous holder). Reserves
    /// its own slot: the partner key is unknown until the partner's
    /// `op:start-session` arrives, so the reservation pairs 1:1 with this insert
    /// rather than with the earlier mint (mints between start-sessions would
    /// otherwise never grow the map, and a burst of un-indexed sessions would
    /// overflow the mint reservation). Fails closed on OOM before apply.
    fn indexPartnerKey(self: *Host, session: *HostSession, key: [crypto.PEER_KEY_BYTES]u8, designator: []const u8) !void {
        try self.partner_by_side.ensureUnusedCapacity(self.allocator, 1);
        const side = try engine.handoff_names.sideName(&key);
        self.partner_by_side.putAssumeCapacity(side, session.peer_id);
        session.indexed_partner_key = key;
        try self.indexDurablePeer(session, designator);
    }

    /// The authenticated durable designator this session's partner proved, or
    /// null when it proved none (ADR-0097). The one derivation both the index
    /// and unindex paths read, which is why the shell stores no copy: session
    /// identity state is written once when the partner's handshake half
    /// arrives and never rewritten, and the verification contract is installed
    /// before the first byte, so the two calls cannot disagree. Keeping it out
    /// of the shell also keeps the per-connection footprint budget intact.
    fn durablePeerName(session: *const HostSession) ?[]const u8 {
        const peer = session.served.port.peer;
        if (!peer.verify_partner_handshake) return null;
        const designator = peer.session_state.partnerDesignator() orelse return null;
        if (durableProvenance(session.transport, peer, designator) == .unauthenticated) return null;
        return designator;
    }

    /// The proved durable key `designator` names on `session`'s transport, or
    /// null when nothing proved it. Takes the designator explicitly so the
    /// pre-apply duplicate check can pass a borrowed hello's claim, and the
    /// post-apply teardown can pass the session's own retained bytes; both
    /// reach the identical row because a session's claim is written once.
    fn durablePeerKeyFor(session: *const HostSession, designator: []const u8) ?[crypto.PEER_KEY_BYTES]u8 {
        const peer = session.served.port.peer;
        if (!peer.verify_partner_handshake) return null;
        if (durableProvenance(session.transport, peer, designator) == .unauthenticated) return null;
        const key = crypto.PeerKey.fromDesignator(designator) orelse return null;
        return key.bytes;
    }

    /// Index this session under the durable identity its partner *proved*, if
    /// any (ADR-0097). Runs beside the side index but answers the other
    /// question; an unauthenticated claim is not indexed, so a peer that can
    /// merely open a connection and assert a name cannot occupy dial
    /// availability for it.
    /// `engine.Node.SessionSecretResolver`: the key `peer_id`'s session signs
    /// its handoff records with (ADR-0097). The node holds one durable key and
    /// no session key material, so this is where a give learns which key names
    /// its session.
    /// The signing seed for the session being minted (ADR-0097). Under
    /// `rooted` each call derives a distinct seed from the host's root and a
    /// monotonic counter, so two sessions never sign with the same key and a
    /// host restarted with a fresh root cannot recreate a prior session's
    /// handoff names. The derivation is keyed and domain-separated, so the
    /// root is not recoverable from a session key and these bytes cannot
    /// collide with another use of the same material.
    fn nextSessionSeed(self: *Host) [crypto.SEED_BYTES]u8 {
        const root = switch (self.session_seed_source) {
            .reused_durable => |seed| return seed,
            .rooted => |root| root,
        };
        self.session_seed_counter += 1;
        var counter_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &counter_bytes, self.session_seed_counter, .little);
        var out: [crypto.SEED_BYTES]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.initKdf(session_seed_domain, .{});
        hasher.update(&root);
        hasher.update(&counter_bytes);
        hasher.final(&out);
        return out;
    }

    fn resolveSessionSecret(ctx: ?*anyopaque, peer_id: engine.PeerId) ?crypto.SecretKey {
        const self: *Host = @ptrCast(@alignCast(ctx orelse return null));
        const session = self.sessions.get(peer_id) orelse return null;
        return session.sessionSecret();
    }

    fn indexDurablePeer(self: *Host, session: *HostSession, designator: []const u8) !void {
        const key = durablePeerKeyFor(session, designator) orelse return;
        try self.peer_by_durable.ensureUnusedCapacity(self.allocator, 1);
        self.peer_by_durable.putAssumeCapacity(key, session.peer_id);
    }

    /// Drop this session from the partner-identity and dialed-designator indexes.
    /// Idempotent: safe when the session was never indexed.
    pub fn unindexSession(self: *Host, session: *HostSession) void {
        if (session.indexed_partner_key) |key| {
            const side = engine.handoff_names.sideName(&key) catch unreachable;
            if (self.partner_by_side.get(side)) |pid| {
                if (pid == session.peer_id) {
                    std.debug.assert(self.partner_by_side.remove(side));
                }
            }
            session.indexed_partner_key = null;
        }
        if (durablePeerName(session)) |designator| blk: {
            const key = durablePeerKeyFor(session, designator) orelse break :blk;
            // Identity-checked like every arm here: a condemned session
            // unindexes twice, and a blind remove would evict a newer
            // session's row for the same durable peer.
            if (self.peer_by_durable.get(key)) |pid| {
                if (pid == session.peer_id) {
                    // tolerant: a prior unindex may already have removed it.
                    _ = self.peer_by_durable.remove(key);
                }
            }
        }
        if (session.role == .dialed) {
            // Identity-checked like the partner-key arm above: this map is
            // keyed by designator content, and unindexSession runs twice for a
            // condemned session. A blind remove lets a released session evict
            // the row a *newer* dial to the same designator just inserted,
            // which would silently disable both refuseDuplicateDial and the
            // crossed-hellos tiebreak.
            if (self.dialed_by_designator.get(session.role.dialed)) |pid| {
                if (pid == session.peer_id) {
                    // tolerant: a prior unindex may already have removed it.
                    _ = self.dialed_by_designator.remove(session.role.dialed);
                }
            }
        }
    }

    fn liveIndexedSession(self: *const Host, peer_id: ?engine.PeerId) ?*HostSession {
        const pid = peer_id orelse return null;
        const session = self.sessions.get(pid) orelse return null;
        if (session.condemned) return null;
        return session;
    }

    /// The shared open tail: sign the keyed hello under the host identity,
    /// enroll, queue the flush, pump. `errdefer failOpen` unwinds a failed hello.
    fn helloAndEnroll(self: *Host, session: *HostSession, transport: []const u8, designator: []const u8, direct_addresses_hint: []const u8) !*HostSession {
        errdefer self.failOpen(session);
        // A key-designator transport advertises its bound address as a hint
        // (empty to `#f`, native `connectVia` dial; accept passes the bound
        // address and is refused earlier when it is missing) and, on a
        // durable-key-attestation transport whose own designator is a key
        // spelling, the ADR-0097 credential. An address transport signs no
        // hints. `engine.keyedHelloHints` owns the assembly and the `#f`
        // empty spelling every keyed hello shares; borrowed entries clone at
        // `sendCopying`.
        var entry_buf: [2]model.HintEntry = undefined;
        var attestation_sig: crypto.Signature = undefined;
        const keyed = vocab.designatorSchemeForTransport(transport) == .key;
        // The durable key signs the credential; the session key is what it
        // authorizes and what signs the hello itself (ADR-0097).
        const durable_secret = self.node.secretKey();
        const session_secret = session.sessionSecret();
        const hints = if (keyed) try engine.keyedHelloHints(
            &entry_buf,
            &attestation_sig,
            direct_addresses_hint,
            vocab.authenticationMechanismForTransport(transport) == .durable_key_attestation,
            &durable_secret,
            session_secret.publicKey(),
            transport,
            designator,
        ) else model.Hints.emptyFalse();
        try session.served.port.peer.sendKeyedStartSession(.v1_0, .{
            .transport = transport,
            .designator = designator,
            .hints = hints,
        }, session_secret);
        self.enroll(session);
        try host_pump.dirtyThenPump(self, session.peer_id);
        return session;
    }

    /// Release one session: break its still-parked far vows (their
    /// resolutions can never arrive), retire it from the node — whose
    /// fail-closed sweep queues the fail actions that break *sibling*
    /// sessions' answers — and free the shell. The sibling fails fire
    /// inside this call, through the same pump every verb ends with.
    pub fn releaseSession(self: *Host, session: *HostSession) !void {
        try self.refuseReentry();
        try self.checkOwnedSession(session);
        self.in_callback = true;
        {
            defer self.in_callback = false;
            session.served.port.breakFarVows(session.served.closeReason("connection released"));
            try self.cancelSessionIngress(session, session.served.closeReason("connection released"));
        }

        if (session.role == .dialed) self.hellos.unregister(self.allocator, session.role.dialed);
        self.unindexSession(session);
        std.debug.assert(self.sessions.remove(session.peer_id));
        const peer_id = session.peer_id;
        _ = self.capabilities.invalidatePeer(peer_id);
        self.dropVowRows(peer_id);
        self.freeSessionShell(session);
        self.node.removePeer(peer_id);
        host_pump.finishVerb(self) catch |err| switch (err) {
            // Dirty-FIFO capacity was reserved when each shell was minted, and
            // a receiver drive that hits OOM requeues itself before returning.
            // The exact wake therefore remains retryable by the next Host verb;
            // condemning unrelated sessions would turn coordination pressure
            // into a Host-wide authority failure.
            error.OutOfMemory => {},
            else => self.condemnRemainingSessions("session release cleanup failed"),
        };
    }

    pub fn cancelSessionIngress(self: *Host, session: *HostSession, reason: []const u8) !void {
        if (session.ingress_cancelled) return;
        try self.vat.cancelIngress(session.served.port.ingress, reason);
        session.ingress_cancelled = true;
    }

    fn condemnRemainingSessions(self: *Host, message: []const u8) void {
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |remaining|
            host_pump.condemnAndClose(self, remaining.*, .resource_exhausted, message);
    }

    /// One node-registered CapTP session shell over a node-owned peer: mint the
    /// peer, apply the host posture, and allocate the `HostSession`. The
    /// map slot is reserved here so `enroll` cannot fail; a caller that fails
    /// after this unwinds with `failOpen`.
    /// What a mint is told about the half being minted. The transport and
    /// dialed designator are borrowed here: `mintShell` copies them into one
    /// shell-owned identity block, so a caller never transfers ownership.
    const RoleSpec = union(enum) {
        dialed: []const u8,
        accepted,
    };

    fn mint(self: *Host, spec: RoleSpec, transport: []const u8) !*HostSession {
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
        // The session being minted owes a flush and a close of its own.
        try self.reserveActions(2);
        if (spec == .dialed) try self.dialed_by_designator.ensureUnusedCapacity(self.allocator, 1);
        const peer_id = try self.node.registerPeer(self.negotiatingOptions());
        errdefer self.node.removePeer(peer_id);
        return self.mintShell(self.node.peer(peer_id).?, peer_id, spec, transport);
    }

    /// `mint` over a peer the embedder already owns and pins at a stable
    /// address (`engine.Node.registerPeerOver`): the node routes through it
    /// and the host serves it, but neither ever frees it — `releaseSession` and
    /// `deinit` only unregister the slot, and the embedder frees the peer
    /// after `releaseSession`. This is how a peer-owning loop, whose fixed slots
    /// hold each peer inline, puts its sessions under one host.
    fn mintOver(self: *Host, peer: *engine.Peer, spec: RoleSpec, transport: []const u8) !*HostSession {
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
        // The session being minted owes a flush and a close of its own.
        try self.reserveActions(2);
        if (spec == .dialed) try self.dialed_by_designator.ensureUnusedCapacity(self.allocator, 1);
        const peer_id = try self.node.registerPeerOver(peer);
        errdefer self.node.removePeer(peer_id);
        return self.mintShell(peer, peer_id, spec, transport);
    }

    /// The host posture imposed on every minted or adopted peer. The export
    /// range is not in it: `engine.Node` hands each session one at
    /// registration, so no posture can carry one and none can overwrite one.
    fn negotiatingOptions(self: *const Host) engine.Peer.NegotiatingOptions {
        return .{
            .codec = self.opts.codec,
            .verify_partner_handshake = self.opts.verify_partner,
            .limits = self.opts.limits,
        };
    }

    /// The shared mint tail: impose the host's peer posture through the
    /// engine's `reposture` verb (asserted negotiating, no bytes moved) and
    /// allocate the shell, for minted and adopted peers alike. The export range
    /// is not among the knobs: `engine.Node` draws one at registration on both
    /// paths, and `reposture` cannot overwrite it because `NegotiatingOptions`
    /// does not carry one.
    fn mintShell(self: *Host, peer: *engine.Peer, peer_id: engine.PeerId, spec: RoleSpec, transport: []const u8) !*HostSession {
        peer.reposture(self.negotiatingOptions());
        // ADR-0097: a transport whose key designator has no lower-layer proof
        // selects the durable-key-attestation contract for every session it
        // carries — dial and accept alike — installed here, the one shell
        // chokepoint, before any partner byte can be fed.
        if (vocab.authenticationMechanismForTransport(transport) == .durable_key_attestation) {
            peer.requirePartnerAttestation();
        }

        const session = try self.allocator.create(HostSession);
        errdefer self.allocator.destroy(session);
        const designator_len = switch (spec) {
            .dialed => |designator| designator.len,
            .accepted => 0,
        };
        const identity_len = std.math.add(usize, transport.len, designator_len) catch return error.OutOfMemory;
        const identity = try self.allocator.alloc(u8, identity_len);
        errdefer self.allocator.free(identity);
        @memcpy(identity[0..transport.len], transport);
        const owned_transport = identity[0..transport.len];
        const role: HostSession.Role = switch (spec) {
            .dialed => |designator| blk: {
                @memcpy(identity[transport.len..], designator);
                break :blk .{ .dialed = identity[transport.len..] };
            },
            .accepted => .accepted,
        };
        session.* = .{
            .host = self,
            .peer_id = peer_id,
            .session_seed = self.nextSessionSeed(),
            .served = Served.over(self.allocator, peer),
            .transport = owned_transport,
            .role = role,
        };
        // `Host.init` returns by value, so only a live Host method knows the
        // object's stable address. Store the seam once per Node (reassigning
        // the same value on later mints is harmless) rather than in each Peer.
        self.node.setLocalObjectProjection(.{
            .ctx = self,
            .resolve_name = resolvePublishedTarget,
            .capture = captureGiftTarget,
            .project = projectGiftTarget,
            .rollback = rollbackGiftTarget,
            .release_target = releaseGiftTarget,
        });
        self.node.setGifterSessionResolver(.{ .ctx = self, .resolve = resolveGifterSession });
        self.node.setSessionSecretResolver(.{ .ctx = self, .resolve = resolveSessionSecret });
        session.served.port.ingress = try self.vat.openIngress();
        session.served.local_turn_budget = self.opts.local_turn_budget;
        return session;
    }

    /// Wire a minted session into the host: the before-serve hook offers
    /// every inbound resolve to the node before the vat sees it (and
    /// auto-redeems gives), and the resolve interceptor turns a served reply
    /// that fulfills with a foreign-homed capability into a signed give.
    /// Infallible: `mint` reserved the session map slot and, for dialed
    /// sessions, the designator-index slot. Dialed sessions join the
    /// designator index here (key borrows `role.dialed`).
    /// Bind a freshly Host-spawned actor. Private so an unscoped `actors.Ref`
    /// from another Vat can never enter this Host's publication namespace.
    /// The alias row adopts the fresh actor's spawn root (ADR-0101): binding
    /// takes no extra retain, replacement releases the displaced actor's
    /// adopted root, and `unpublish` releases the row's. A caller-chosen
    /// mutable name structurally cannot enter the reserved durable namespace
    /// (ADR-0098): the prefix, not a tombstone, is what keeps an old
    /// sturdyref from being retargeted after restart.
    fn bindPublication(self: *Host, name: []const u8, actor: actors.Ref) !void {
        self.assertOwner();
        if (engine.isDurableSwiss(name)) return error.ReservedDurableNamespace;
        if (self.giftables.getPtr(name)) |existing| {
            const displaced = existing.actor;
            existing.actor = actor;
            self.vat.releaseActor(actorIdOf(displaced));
            return;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.giftables.putNoClobber(self.allocator, owned, .{ .name = owned, .actor = actor });
    }

    /// Spawn `initial` in this Host's Vat and bind `name` as a Host-wide alias.
    /// Replacement changes discovery only; existing capabilities keep reaching
    /// the displaced actor until Host teardown.
    pub fn publishGiftable(self: *Host, name: []const u8, comptime Behavior: type, initial: Behavior) !actors.Ref {
        const actor = try self.vat.spawn(Behavior, initial);
        errdefer self.vat.discardFreshActor(actor);
        try self.bindPublication(name, actor);
        return actor;
    }

    /// Foreign-callback twin of `publishGiftable`. `hosted` transfers into the
    /// Vat on every outcome, preserving one owner for its context.
    pub fn publishHostedGiftable(self: *Host, name: []const u8, hosted: actors.HostedActor) !actors.Ref {
        const actor = try self.vat.spawnHosted(hosted);
        errdefer self.vat.discardFreshActor(actor);
        try self.bindPublication(name, actor);
        return actor;
    }

    /// Remove the host-wide alias `name`. Discovery-only, alias-only
    /// (ADR-0096): a later fetch of the name misses on every session, while
    /// capabilities already issued, live Port projections, and deposited
    /// gifts keep naming the exact actor, which stays in the Host Vat until
    /// teardown. An absent alias is refused `UnknownPublication`, so a typo
    /// is loud instead of an idempotent no-op.
    pub fn unpublish(self: *Host, name: []const u8) error{ UnknownPublication, ReservedDurableNamespace }!void {
        self.assertOwner();
        // The mutable-alias verb refuses durable rows: a minted sturdyref's
        // name is removed only through `removeDurable`, so the two authority
        // surfaces stay distinct (ADR-0098).
        if (engine.isDurableSwiss(name)) return error.ReservedDurableNamespace;
        const removed = self.giftables.fetchRemove(name) orelse return error.UnknownPublication;
        // Key and row name are one allocation (`bindPublication`); free once.
        self.allocator.free(@constCast(removed.value.name));
        // Release the alias root the row adopted (ADR-0101): with no other
        // rooting relationship, the actor is reclaimed here rather than at
        // Host teardown.
        self.vat.releaseActor(actorIdOf(removed.value.actor));
    }

    /// A minted durable swiss name: fixed-size, POD, returned by value so
    /// the caller owns the bytes with no allocation (ADR-0098).
    pub const DurableSwiss = struct {
        bytes: [engine.durable_swiss_len]u8,

        pub fn slice(self: *const DurableSwiss) []const u8 {
            return self.bytes[0..];
        }
    };

    /// Mint a durable swiss name from caller-supplied entropy: the reserved
    /// prefix plus the hex spelling of `entropy`. Entropy stays an explicit
    /// input because this core is sans-io; the driver tier draws it at the
    /// I/O boundary (ADR-0098).
    fn mintDurableSwiss(entropy: [engine.durable_swiss_entropy_len]u8) DurableSwiss {
        var out: DurableSwiss = undefined;
        @memcpy(out.bytes[0..engine.durable_swiss_prefix.len], engine.durable_swiss_prefix);
        const hex = "0123456789abcdef";
        for (entropy, 0..) |byte, i| {
            out.bytes[engine.durable_swiss_prefix.len + i * 2] = hex[byte >> 4];
            out.bytes[engine.durable_swiss_prefix.len + i * 2 + 1] = hex[byte & 0xf];
        }
        return out;
    }

    /// Publish `initial` under a freshly minted durable swiss name
    /// (ADR-0098): unpredictable, never reassigned, removable only through
    /// `removeDurable`, and structurally disjoint from every mutable alias.
    /// The active table is still checked before insertion, so even an
    /// entropy-collision fails loud instead of retargeting. The row adopts
    /// the spawn root (ADR-0101). Durability across process restart requires
    /// durable registry storage, which remains unimplemented: today a
    /// restart makes the old sturdyref miss, which is the fail-closed half
    /// of the contract.
    pub fn publishDurable(
        self: *Host,
        entropy: [engine.durable_swiss_entropy_len]u8,
        comptime Behavior: type,
        initial: Behavior,
    ) !DurableSwiss {
        self.assertOwner();
        const actor = try self.vat.spawn(Behavior, initial);
        errdefer self.vat.discardFreshActor(actor);
        return self.bindDurable(entropy, actor);
    }

    /// Foreign-callback twin of `publishDurable`. `hosted` transfers into the
    /// Vat on every outcome, preserving one owner for its context.
    pub fn publishHostedDurable(
        self: *Host,
        entropy: [engine.durable_swiss_entropy_len]u8,
        hosted: actors.HostedActor,
    ) !DurableSwiss {
        self.assertOwner();
        const actor = try self.vat.spawnHosted(hosted);
        errdefer self.vat.discardFreshActor(actor);
        return self.bindDurable(entropy, actor);
    }

    fn bindDurable(self: *Host, entropy: [engine.durable_swiss_entropy_len]u8, actor: actors.Ref) !DurableSwiss {
        const minted = mintDurableSwiss(entropy);
        if (self.giftables.contains(minted.slice())) return error.DurableNameCollision;
        const owned = try self.allocator.dupe(u8, minted.slice());
        errdefer self.allocator.free(owned);
        try self.giftables.putNoClobber(self.allocator, owned, .{ .name = owned, .actor = actor });
        return minted;
    }

    /// Remove a minted durable publication (ADR-0098): its live row is
    /// reclaimed, future enlivenment of the old sturdyref misses, and a
    /// later mint never deliberately reuses the bytes. Alias-only like
    /// `unpublish` — issued capabilities and deposited gifts keep the exact
    /// actor — and it releases the row's adopted root (ADR-0101). A name
    /// outside the durable namespace is refused: mutable aliases leave
    /// through `unpublish`.
    pub fn removeDurable(self: *Host, swiss: []const u8) error{ UnknownPublication, NotDurableName }!void {
        self.assertOwner();
        if (!engine.isDurableSwiss(swiss)) return error.NotDurableName;
        const removed = self.giftables.fetchRemove(swiss) orelse return error.UnknownPublication;
        self.allocator.free(@constCast(removed.value.name));
        self.vat.releaseActor(actorIdOf(removed.value.actor));
    }

    fn enroll(self: *Host, session: *HostSession) void {
        session.served.serve_options = .{ .hook_ctx = session, .before_serve = hostBeforeServe };
        session.served.port.setResolveInterceptor(.{ .ctx = session, .func = hostResolveInterceptor });
        self.sessions.putAssumeCapacity(session.peer_id, session);
        if (session.role == .dialed) {
            self.dialed_by_designator.putAssumeCapacity(session.role.dialed, session.peer_id);
        }
    }

    /// Free one session's owned shell after it has been unregistered from every
    /// index and its Vat ingress has been canceled: the served Port, unconsumed feed tail, connection identity bytes,
    /// then the shell itself. Every session teardown funnels through here so no
    /// path drops one of these frees. Call only after `unindexSession` (and, for
    /// a dialed session, `hellos.unregister`): the designator bytes back those
    /// index keys until this frees their shared block.
    fn freeSessionShell(self: *Host, session: *HostSession) void {
        // The export range is not given back here: `engine.Node.removePeer`
        // reclaims it from the peer that held it, so the draw and the return
        // sit on the same side of the boundary.
        host_pump.removeDirtySession(self, session);
        session.served.deinit(&self.vat);
        session.feed_tail.deinit(self.allocator);
        const identity_len = session.transport.len + switch (session.role) {
            .dialed => |designator| designator.len,
            .accepted => 0,
        };
        self.allocator.free(session.transport.ptr[0..identity_len]);
        self.allocator.destroy(session);
    }

    fn failOpen(self: *Host, session: *HostSession) void {
        self.unindexSession(session);
        // tolerant: enrolled only when the failure came after `enroll`.
        _ = self.sessions.remove(session.peer_id);
        const peer_id = session.peer_id;
        self.cancelSessionIngress(session, session.served.closeReason("session open failed")) catch unreachable;
        self.freeSessionShell(session);
        self.node.removePeer(peer_id);
    }

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

    /// Feed a byte-stream chunk the embedder read from its own transport
    /// (borrowed for the call). The core owns framing *and the tail*: the
    /// session's codec delimits each complete frame at the front — both
    /// codecs, both frame shapes — and dispatches it exactly as `feed`,
    /// behavior and settle callbacks firing inside, the pump running at the
    /// unwind; a partial frame straddling two reads stays in the session's
    /// own `feed_tail`, so on success every byte of the chunk is consumed and
    /// the embedder just reads and feeds. The steady path (no pending tail)
    /// parses the borrowed chunk in place with zero copies and stashes only
    /// the leftover; while a tail is pending the chunk coalesces into it —
    /// the one bounded copy on this path, paid only while a frame straddles.
    /// Consumption also pauses at the frame that completes the keyed
    /// handshake: frames coalesced behind the hello wait in the tail while
    /// the embedder acts on the fresh session (publish, fetch), and the next
    /// call — an empty chunk works — feeds them. A frame exceeding the
    /// session's `frame_cap` (`error.FrameTooLarge`) or a malformed prefix
    /// projects a typed `op:abort` and surfaces the error, like any `feed`
    /// failure; the session is closing then, and the tail frees with the
    /// shell.
    pub fn feedBytes(self: *Host, session: *HostSession, bytes: []const u8) !void {
        try self.checkOwnedSession(session);
        // An empty resume with nothing held is a pure no-op — before the
        // latch, so a pump's unconditional serve-start resume does not turn
        // a condemned session (a crossed-hellos tiebreak loss, routine under
        // concurrent introductions) into a spurious serve failure.
        if (bytes.len == 0 and !session.feed_tail.isActive()) return;
        const was_open = session.served.port.peer.sessionIsOpen();
        return host_pump.dispatchUnderLatch(self, session, struct {
            gpa: std.mem.Allocator,
            c: *HostSession,
            bytes: []const u8,
            was_open: bool,
            pub fn call(s: @This()) !void {
                const tail = &s.c.feed_tail;
                // Nothing held: parse the borrowed chunk in place (the zero-copy
                // steady path) and stash only what did not complete a frame.
                if (!tail.isActive()) {
                    const consumed = try parseStreamPrefix(s.c, s.bytes, s.was_open);
                    if (consumed < s.bytes.len) {
                        try tail.absorbBytes(s.gpa, s.bytes[consumed..]);
                    }
                    return;
                }
                // A frame is already straddling, so the tail owns every newly
                // arrived byte: extend it and parse from there, the one bounded
                // copy this path pays.
                try tail.absorbBytes(s.gpa, s.bytes);
                const consumed = try parseStreamPrefix(s.c, tail.bytes(), s.was_open);
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

    /// Pop the next embedder action, borrowed: the previous action's byte
    /// views are freed here, so a popped action is valid until the next call.
    /// Null when no action is pending. Top-level: refused under the callback
    /// latch, where the enclosing verb is still queueing and freeing the
    /// previous action would dangle views the embedder still holds.
    pub fn nextAction(self: *Host) HostError!?HostAction {
        try self.refuseReentry();
        try self.resumeWorkForActionDrain();
        if (self.last_action) |last| {
            host_action.freeAction(self.allocator, last);
            self.last_action = null;
        }
        const action = self.popAction() orelse return null;
        self.last_action = action;
        return action;
    }

    /// Pop the next embedder action, owned: the caller adopts the payload and
    /// frees it with `freeAction` — or moves it into a durable owner first,
    /// which is how `driver.Bridge` parks a completion with zero
    /// copies. Leaves the `nextAction` borrow untouched, so the two pops
    /// compose. Refused under the latch like `nextAction`.
    pub fn takeAction(self: *Host) HostError!?HostAction {
        try self.refuseReentry();
        try self.resumeWorkForActionDrain();
        return self.popAction();
    }

    /// Free an action `takeAction` transferred, once its payload is consumed
    /// (a moved-out payload is the new owner's to free instead).
    pub fn freeAction(self: *Host, action: HostAction) void {
        host_action.freeAction(self.allocator, action);
    }

    /// The one FIFO pop under both action verbs: compact the dead prefix past
    /// the threshold and hand out the front row, owning nothing.
    fn popAction(self: *Host) ?HostAction {
        const action = self.actions.pop(self.allocator) orelse return null;
        switch (action) {
            .flush => |peer_id| {
                if (self.sessions.get(peer_id)) |session|
                    session.flush_action_pending = false;
            },
            .close => |peer_id| {
                if (self.sessions.get(peer_id)) |session|
                    session.close_action_pending = false;
            },
            else => {},
        }
        return action;
    }

    fn resumeWorkForActionDrain(self: *Host) HostError!void {
        host_pump.finishVerb(self) catch |err| switch (err) {
            error.OutOfMemory => return HostError.OutOfMemory,
            else => self.condemnRemainingSessions("host action cleanup failed"),
        };
    }

    /// Borrow the in-flight pending dial for `ticket`, or null if settled.
    /// Same contract as `Node.pendingDial`.
    pub fn pendingDial(self: *const Host, ticket: engine.Node.PendingId) ?engine.Node.PendingDialView {
        return self.node.pendingDial(ticket);
    }

    /// The exporter `HostSession` a redeemed-handoff reply token routes to, or
    /// null when `reference` names no live redeemed route (an ordinary far
    /// reply, or an exporter connection already gone). Deterministic: a
    /// redeem's originating send resolves the reply it holds to the exact
    /// exporter session, with no capture window and no dependence on which dial
    /// completed first — the reply token's route is the single source of truth.
    pub fn exporterSessionFor(self: *Host, reference: model.Reference) ?*HostSession {
        const peer = self.node.exporterPeerFor(reference) orelse return null;
        return self.sessions.get(peer);
    }

    /// Report a `dial` action's success: `session` is an `openDialedLocator`
    /// against that ticket's pending locator, driven to an open session. The
    /// node withdraws every give waiting on the ticket; the withdraws and
    /// their flushes pump inside this call. A stale ticket is a no-op.
    pub fn exporterDialed(self: *Host, ticket: engine.Node.PendingId, session: *HostSession) !void {
        try self.refuseReentry();
        try self.checkSession(session);
        try self.node.exporterDialed(ticket, session.peer_id);
        // Enlivens parked on this ticket continue over the opened session,
        // each settling its pre-minted vow; their fetch frames ride the same
        // finish pump the withdraws do.
        self.settleParkedEnlivens(ticket, session, "");
        try host_pump.finishVerb(self);
    }

    /// Report a `dial` action's failure: every redeem waiting on the ticket
    /// breaks with `reason`, firing its settle listener inside this call. A
    /// stale ticket is a no-op.
    pub fn dialFailed(self: *Host, ticket: engine.Node.PendingId, reason: []const u8) !void {
        try self.refuseReentry();
        try self.node.dialFailed(ticket, reason);
        self.settleParkedEnlivens(ticket, null, reason);
        try host_pump.finishVerb(self);
    }

    /// Answer a `need_gift_id` action with 32 host-drawn bytes: the node
    /// originates the claimed handoff and this call flushes its legs,
    /// exporter first. A stale ticket is a no-op.
    pub fn provideGiftId(self: *Host, ticket: u64, gift_id: []const u8) !void {
        try self.refuseReentry();
        try self.node.provideGiftId(ticket, gift_id);
        try host_pump.finishVerb(self);
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
        const vow = try routed.session.served.send(&self.vat, routed.target, msg);
        const id = try self.mintVow(routed.session, vow, .plain);
        try host_pump.dirtyThenPump(self, routed.session.peer_id);
        return id;
    }

    /// Fire-and-forget eventual-send: `send` with no answer and no vow.
    pub fn tell(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !void {
        const routed = try self.routeSend(session, target, msg.args);
        try routed.session.served.tell(&self.vat, routed.target, msg);
        try host_pump.dirtyThenPump(self, routed.session.peer_id);
    }

    /// Encode `session`'s enqueued outbound and queue its flush action — the
    /// public spelling of the pump every host verb ends with, for an embedder
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
        const vow = try home.served.listenTo(wire);
        const id = try self.mintVow(home, vow, .plain);
        try host_pump.dirtyThenPump(self, home.peer_id);
        return id;
    }

    fn matchSturdyrefPeer(
        self: *Host,
        session: *HostSession,
        sturdyref: model.SturdyRef,
        policy: EnlivenPeerPolicy,
    ) !PeerProvenance {
        try self.checkSession(session);
        const locator = sturdyref.peer;
        if (!std.mem.eql(u8, locator.transport, session.transport)) return HostError.PeerIdentityMismatch;

        if (vocab.designatorSchemeForTransport(session.transport) == .key) {
            const identity = try self.partnerIdentity(session);
            if (!std.mem.eql(u8, locator.designator, identity.designator)) return HostError.PeerIdentityMismatch;
            // The provenance-bearing predicate, not key equality (ADR-0097):
            // what this needs is a proved durable peer, and once session keys
            // go fresh a keyed partner's designator stops equaling its session
            // key while staying fully authenticated.
            if (!identity.durableIdentityAuthenticated()) return HostError.PeerIdentityUnverified;
            return .verified;
        }

        switch (session.role) {
            .dialed => |target| {
                if (!std.mem.eql(u8, locator.designator, target)) return HostError.PeerIdentityMismatch;
                return .dial_target;
            },
            .accepted => {
                const claimed = session.served.port.peer.session_state.partnerDesignator() orelse
                    return HostError.HandshakeIncomplete;
                if (!std.mem.eql(u8, locator.designator, claimed)) return HostError.PeerIdentityMismatch;
                if (policy != .assertion_only) return HostError.PeerIdentityUnverified;
                return .assertion_only;
            },
        }
    }

    /// Enliven the complete sturdyref (ADR-0098), minting
    /// a host vow for the live reference. A dedup-cache hit settles the vow
    /// before this returns — its completion is already on the action queue —
    /// and a fresh enliven rides bootstrap-fetch, the host recording the
    /// enlivenment itself when the resolution arrives, before the outcome is
    /// dispatched. Top-level: refused from inside a callback.
    pub fn enliven(self: *Host, session: *HostSession, sturdyref: model.SturdyRef) !u64 {
        return (try self.enlivenWithPolicy(session, sturdyref, .checked)).vow_id;
    }

    /// Select-or-dial enlivenment for a byte-fed embedder (ADR-0098 step 4):
    /// enliven `sturdyref` over a live dialed session to its peer, or stage a
    /// dial through the ordinary `dial` action and finish when the embedder
    /// reports it (`exporterDialed` / `dialFailed`), reusing the node's one
    /// pending-dial ticket space so the embedder's dial arm never learns a
    /// second namespace.
    ///
    /// The returned vow id is minted before any session may exist, so a
    /// parked outcome always arrives as that id's `settled` / `failed`
    /// action; `vowOn` refuses a parked id (`NoSuchVow`) exactly as it
    /// refuses an already-settled one. Peer policy is `.checked` — the
    /// accepted-address escape hatch stays on the session-scoped
    /// `enlivenWithPolicy`, native-only by construction.
    pub fn enlivenSelectOrDial(self: *Host, sturdyref: model.SturdyRef) !u64 {
        try self.refuseReentry();
        if (self.dialedSessionFor(sturdyref.peer.transport, sturdyref.peer.designator)) |session| {
            return (try self.enlivenWithPolicy(session, sturdyref, .checked)).vow_id;
        }
        // The dial's authority is the staged parts, so the locator round-trips
        // through the same writer every give's exporter location uses; the
        // sturdyref arrived parsed, so this cannot re-introduce a parse hole.
        const locator = try model.uri.writePeer(self.allocator, sturdyref.peer);
        defer self.allocator.free(locator);
        switch (try self.node.stageDial(locator)) {
            .open => |peer_id| {
                const session = self.sessions.get(peer_id) orelse return HostError.ConnectionCondemned;
                return (try self.enlivenWithPolicy(session, sturdyref, .checked)).vow_id;
            },
            .pending => |ticket| {
                // Park under a pre-minted id. The parked sturdyref drops the
                // locator hints: the peer check reads transport + designator,
                // and the dial's routing detail lives in the staged parts.
                try self.pending_enlivens.ensureUnusedCapacity(self.allocator, 1);
                // One completion slot per parked enliven, reserved now, so the
                // continuation's settle can never fail to land.
                // This parked enliven's own settle, plus the dial action.
                try self.reserveActions(2);
                const transport = try self.allocator.dupe(u8, sturdyref.peer.transport);
                errdefer self.allocator.free(transport);
                const designator = try self.allocator.dupe(u8, sturdyref.peer.designator);
                errdefer self.allocator.free(designator);
                const swissnum = try self.allocator.dupe(u8, sturdyref.swissnum);
                const id = self.next_vow;
                self.next_vow += 1;
                self.pending_enlivens.appendAssumeCapacity(.{
                    .ticket = ticket,
                    .vow_id = id,
                    .sturdyref = .{
                        .peer = .{ .transport = transport, .designator = designator, .hints = model.Hints.emptyFalse() },
                        .swissnum = swissnum,
                    },
                });
                return id;
            },
        }
    }

    fn freeParkedEnliven(self: *Host, parked: PendingEnliven) void {
        self.allocator.free(parked.sturdyref.peer.transport);
        self.allocator.free(parked.sturdyref.peer.designator);
        self.allocator.free(parked.sturdyref.swissnum);
    }

    /// Settle a parked enliven's vow broken. The message must be host-owned
    /// by the action contract; a failed retain degrades to the empty reason
    /// rather than losing the settle (the slot was reserved at park).
    fn failParkedEnliven(self: *Host, parked: PendingEnliven, session_peer: ?engine.PeerId, reason: []const u8) void {
        const owned = self.allocator.dupe(u8, reason) catch "";
        self.actions.pushReserved(.{ .failed = .{ .peer_id = session_peer, .vow_id = parked.vow_id, .message = owned } });
    }

    /// Run one parked enliven against the session its dial opened, settling
    /// the pre-minted vow on every path: the dedup-cache hit settles now, a
    /// wire-riding fetch bridges the parked id onto its answer, and any
    /// refusal (the peer check included — the dial was staged before a
    /// session existed to check against) breaks the vow instead of raising
    /// out of the embedder's `exporterDialed` report.
    fn continueParkedEnliven(self: *Host, session: *HostSession, parked: PendingEnliven) void {
        const err: anyerror = blk: {
            _ = self.matchSturdyrefPeer(session, parked.sturdyref, .checked) catch |e| break :blk e;
            const peer = session.served.port.peer;
            const start = engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, parked.sturdyref.swissnum) catch |e| break :blk e;
            switch (start) {
                .cached => |reference| {
                    self.actions.pushReserved(.{ .settled = .{ .peer_id = session.peer_id, .vow_id = parked.vow_id, .value = .{ .reference = reference } } });
                    return;
                },
                .in_flight => |answer| {
                    _ = self.mintEnlivenVowAt(session, answer, parked.vow_id) catch |e| break :blk e;
                    return;
                },
                .fresh => |prepared| {
                    peer.sendPreparedFetch(prepared) catch |e| {
                        peer.finishPendingEnliven(parked.sturdyref.swissnum);
                        break :blk e;
                    };
                    _ = self.mintEnlivenVowAt(session, prepared.answer_position, parked.vow_id) catch |e| {
                        peer.finishPendingEnliven(parked.sturdyref.swissnum);
                        break :blk e;
                    };
                    host_pump.markDirty(self, session.peer_id);
                    return;
                },
            }
        };
        self.failParkedEnliven(parked, session.peer_id, @errorName(err));
    }

    /// Continue every enliven parked on `ticket`: run each against the opened
    /// session (or break each with the dial's failure), then drop its row.
    fn settleParkedEnlivens(self: *Host, ticket: engine.Node.PendingId, opened: ?*HostSession, fail_reason: []const u8) void {
        var i: usize = 0;
        while (i < self.pending_enlivens.items.len) {
            const parked = self.pending_enlivens.items[i];
            if (parked.ticket != ticket) {
                i += 1;
                continue;
            }
            // The row is the one this index just read; the swap-remove returns
            // it and is never absent.
            std.debug.assert(std.meta.eql(self.pending_enlivens.swapRemove(i).ticket, parked.ticket));
            if (opened) |session| {
                self.continueParkedEnliven(session, parked);
            } else {
                self.failParkedEnliven(parked, null, fail_reason);
            }
            self.freeParkedEnliven(parked);
        }
    }

    /// Low-level accepted-TCP escape hatch. The result reports whether the peer
    /// was verified, selected as this side's dial target, or accepted only as a
    /// partner assertion; no caller can silently collapse those cases.
    pub fn enlivenWithPolicy(
        self: *Host,
        session: *HostSession,
        sturdyref: model.SturdyRef,
        policy: EnlivenPeerPolicy,
    ) !EnlivenStart {
        try self.refuseReentry();
        const provenance = try self.matchSturdyrefPeer(session, sturdyref, policy);
        const swissnum = sturdyref.swissnum;
        const peer = session.served.port.peer;
        // The peer check above fixes the namespace before this session-local
        // swiss cache is consulted or any bootstrap fetch can be emitted.
        const start = try engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, swissnum);
        switch (start) {
            .cached => |reference| {
                // Already settled: queue the completion for a fresh id and
                // never build a row, so the id refuses `NoSuchVow` exactly
                // like any other settled vow.
                const id = self.next_vow;
                try host_pump.queueHostAction(self, .{ .settled = .{ .peer_id = session.peer_id, .vow_id = id, .value = .{ .reference = reference } } });
                self.next_vow += 1;
                try host_pump.finishVerb(self);
                return .{ .vow_id = id, .provenance = provenance };
            },
            // An enliven already in flight holds the one listener slot on its
            // answer, so a concurrent duplicate is refused `AlreadyListening`
            // rather than parked where it could never fire.
            .in_flight => |answer| {
                const id = try self.mintEnlivenVow(session, answer);
                try host_pump.finishVerb(self);
                return .{ .vow_id = id, .provenance = provenance };
            },
            .fresh => |prepared| {
                peer.sendPreparedFetch(prepared) catch |err| {
                    // The fresh enliven recorded an in-flight marker; clear it
                    // so a failed send does not strand the swissnum.
                    peer.finishPendingEnliven(swissnum);
                    return err;
                };
                const id = self.mintEnlivenVow(session, prepared.answer_position) catch |err| {
                    peer.finishPendingEnliven(swissnum);
                    return err;
                };
                try host_pump.dirtyThenPump(self, session.peer_id);
                return .{ .vow_id = id, .provenance = provenance };
            },
        }
    }

    /// Redeem a `desc:handoff-give` this recipient `session` received outside
    /// the auto-redeem path — a give delivered to an application object rather
    /// than surfaced as the `op:resolve` `hostBeforeServe` claims — by dialing
    /// the exporter `exporter_locator` names and withdrawing the gift under the
    /// host identity, settling `answer` with the redeemed capability. This is
    /// the same node redeem the before-serve hook runs for an inbound
    /// give-as-resolve (ADR-0009), exposed for an embedder whose protocol
    /// carries gives another way — the OCapN conformance greeter delivers the
    /// give as a plain argument. Running it as a host verb (not a raw
    /// `node.acceptGive`) is what moves the queued dial onto the embedder's
    /// action queue; a bare node call strands it. Top-level: refused from
    /// inside a callback.
    pub fn acceptGive(self: *Host, session: *HostSession, answer: u64, give: []const u8, exporter_locator: []const u8) !void {
        try self.refuseReentry();
        try self.checkSession(session);
        try self.node.acceptGive(session.peer_id, answer, give, exporter_locator);
        try host_pump.finishVerb(self);
    }

    /// Register a one-shot in-process listener on a host vow, which hears
    /// the resolution borrowed (zero-copy) and keeps that vow's settlement
    /// off the action queue. A settled vow's row is already retired, so a
    /// settled id and an unknown id refuse alike with `NoSuchVow` — register
    /// before the feed that can settle it (an embedder that drains the
    /// action queue instead has no such window: the completion waits on the
    /// queue). A second listener on a live row is refused `AlreadyListening`.
    pub fn vowOn(self: *Host, vow_id: u64, listener: actors.Listener) !void {
        const resolved = try self.resolveVowSession(vow_id);
        if (resolved.row.inner != null) return actors.Error.AlreadyListening;
        resolved.row.inner = listener;
    }

    /// Owning session for a still-live vow, used by adapters to lower opaque
    /// Host references in a pipelined send before entering the wire surface.
    pub fn vowSession(self: *Host, vow_id: u64) !*HostSession {
        return (try self.resolveVowSession(vow_id)).session;
    }

    /// A host resolver pair (ADR-0102): the vow id is the read side — its
    /// whole surface is the turn-scoped forward — and the resolver id is the
    /// settle authority. Separate values, so holding one never confers the
    /// other.
    pub const ResolverPair = struct { vow_id: u64, resolver_id: u64 };

    const ResolverIndexEntry = struct { vow_id: u64, vat_resolver: u64 };

    /// Mint a resolver pair at the host tier (ADR-0102). Legal inside a
    /// behavior callback, which is the primary use: the behavior mints,
    /// defers its answer onto the vow (the turn-scoped forward), hands the
    /// resolver id to whatever completes the work, and returns. The vow row
    /// belongs to no session, so no session's release drops it; it retires
    /// with the resolver settle. On an allocation failure after the vat pair
    /// minted, that pair stays until vat teardown — a bounded remainder, not
    /// a dangling authority.
    pub fn spawnResolver(self: *Host) !ResolverPair {
        self.assertOwner();
        const pair = try self.vat.spawnVow();
        const row = try self.createVowRow(null, pair.vow, .plain, self.next_vow);
        errdefer self.allocator.destroy(row);
        try self.resolver_index.ensureUnusedCapacity(self.allocator, 1);
        self.vows.putAssumeCapacity(row.id, row);
        self.next_vow += 1;
        const resolver_id = self.next_resolver;
        self.next_resolver += 1;
        self.resolver_index.putAssumeCapacity(resolver_id, .{
            .vow_id = row.id,
            .vat_resolver = pair.resolver,
        });
        return .{ .vow_id = row.id, .resolver_id = resolver_id };
    }

    /// Settle a resolver vow fulfilled (ADR-0102). Top-level: the settle
    /// runs the deferred answers' listeners and pumps every session they
    /// dirtied, so it refuses from inside a callback (`ReenteredHost`) — the
    /// worker's completion re-enters between events, on the owning thread.
    /// One attempt: the resolver is consumed up front, so a second settle
    /// and an unknown id refuse alike (`AlreadySettled`). `value` must be
    /// capability-free — plain data is the off-turn contract; an answer that
    /// carries authority takes the existing forward-to-send path instead.
    pub fn resolverFulfill(self: *Host, resolver_id: u64, value: model.Argument) !void {
        try self.refuseReentry();
        try self.settleResolverRow(resolver_id, .{ .fulfilled = value });
    }

    /// Settle a resolver vow broken (ADR-0102); `reason` is borrowed for the
    /// call. The same contract as `resolverFulfill`.
    pub fn resolverBreak(self: *Host, resolver_id: u64, reason: []const u8) !void {
        try self.refuseReentry();
        try self.settleResolverRow(resolver_id, .{ .broken = reason });
    }

    fn settleResolverRow(self: *Host, resolver_id: u64, resolution: actors.Resolution) !void {
        const entry = self.resolver_index.fetchRemove(resolver_id) orelse return actors.Error.AlreadySettled;
        // Retire the row before the settle, mirroring `settleRow`: every
        // later verb on the vow id refuses `NoSuchVow` from here on.
        const row = self.vows.fetchRemove(entry.value.vow_id) orelse unreachable; // index row implies vow row
        const forwarded_peer = row.value.forwarded_peer;
        self.allocator.destroy(row.value);
        switch (resolution) {
            .fulfilled => |value| try self.vat.fulfillVow(entry.value.vat_resolver, value),
            .broken => |reason| try self.vat.breakVow(entry.value.vat_resolver, reason),
            .give => unreachable, // no resolver verb spells a give
        }
        // This settle runs outside any feed, so the deferred answer's session
        // is encoded here or not at all.
        if (forwarded_peer) |peer_id| host_pump.markDirty(self, peer_id);
        try host_pump.finishVerb(self);
    }

    /// Defer `turn`'s answer onto a resolver vow (ADR-0102): the answer
    /// settles when the resolver fires later, as its own top-level event.
    /// Legal inside a behavior callback — the turn-scoped half of the
    /// resolver pair. Only a resolver vow can carry a deferred answer; a
    /// wire vow's answer belongs to its session (`NotALocalVow`). Records
    /// the turn's session so the later settle can encode the resolved
    /// answer.
    pub fn turnForwardVow(self: *Host, turn: *actors.Turn, vow_id: u64) !void {
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        if (row.peer_id != null) return HostError.NotALocalVow;
        try turn.forwardVow(row.vow);
        // forwardVow refused every non-served turn, and every served turn in
        // this vat runs on a session's Port, so the recovery cannot miss.
        const served: *Served = @fieldParentPtr("port", turn.port.?);
        const session: *HostSession = @alignCast(@fieldParentPtr("served", served));
        row.forwarded_peer = session.peer_id;
    }

    /// Promise pipelining: eventual-send `msg` to a host vow before it
    /// resolves, minting a new vow for this call's own answer. A local vow has
    /// no wire answer to pipeline against (`NotPipelineable`).
    pub fn vowSend(self: *Host, vow_id: u64, msg: actors.Message) !u64 {
        const resolved = try self.resolveVowSession(vow_id);
        const vow = try resolved.session.served.sendToAnswer(&self.vat, resolved.row.vow, msg);
        const id = try self.mintVow(resolved.session, vow, .plain);
        try host_pump.dirtyThenPump(self, resolved.session.peer_id);
        return id;
    }

    /// Pipeline an `op:index` projection against a far host vow, minting a new
    /// vow for the projected element.
    pub fn vowIndex(self: *Host, vow_id: u64, index: i64) !u64 {
        return self.vowProjection(vow_id, .{ .index = index });
    }

    /// Pipeline an `op:untag` projection against a far host vow, minting a new
    /// vow for the unwrapped payload.
    pub fn vowUntag(self: *Host, vow_id: u64, tag: []const u8) !u64 {
        return self.vowProjection(vow_id, .{ .untag = tag });
    }

    /// Pipeline an `op:get` projection against a far host vow, minting a new
    /// vow for the named Struct field (ADR-0050).
    pub fn vowGet(self: *Host, vow_id: u64, field: []const u8) !u64 {
        return self.vowProjection(vow_id, .{ .get = field });
    }

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

    /// Reserve action-queue capacity for every irreversible notification the
    /// host has already promised, plus the `extra` slots this caller is about
    /// to owe. The one owner of that ceiling.
    ///
    /// The promises, and why each is a slot: every live vow settles exactly
    /// once, through a `settled` or `failed` action, and the fire that
    /// carries it is infallible by then. Every parked select-or-dial enliven
    /// (ADR-0098) settles the same way, under an id its caller already holds.
    /// Every live session owes at most one flush and one close notification,
    /// both irreversible once a frame or a close verdict exists. A caller
    /// naming `extra` is saying what it is adding on top: the action it is
    /// about to push, the vow or parked enliven it is about to mint, or the
    /// session whose two notifications do not exist yet.
    ///
    /// Reserving ahead is what lets those pushes be infallible later. A
    /// settled vow with no completion is unrepresentable, so the capacity has
    /// to exist before the promise does.
    fn reserveActions(self: *Host, extra: usize) !void {
        try self.actions.reserve(
            self.allocator,
            self.vows.count() + self.pending_enlivens.items.len + 2 * self.sessions.count() + extra,
        );
    }

    /// `reserveActions` for the sibling module that drives the pump; the
    /// ceiling itself stays owned here.
    pub fn reserveActionsFor(self: *Host, extra: usize) !void {
        return self.reserveActions(extra);
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

    /// Record the exporter locator to embed in gives whose exporter is `session`
    /// (see `engine.Node.setExporterLocation`); `null` clears the override back
    /// to the session record. The node encodes the locator to canonical Syrup
    /// record bytes — a URI string is unrepresentable here.
    pub fn setExporterLocation(self: *Host, session: *HostSession, location: ?model.PeerLocator) !void {
        self.assertOwner();
        try self.checkSession(session);
        try self.node.setExporterLocation(session.peer_id, location);
    }

    /// The partner identity `session`'s handshake proved (see
    /// `vocab.PartnerIdentity`), or an error when there is none to report.
    ///
    /// `HostError.HandshakeIncomplete` means the partner's `op:start-session`
    /// has not arrived with a key yet. `HostError.PartnerUnverified` means this
    /// session was opened with `Options.verify_partner` off, so nothing here was
    /// proved and there is no identity to hand back.
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
            .provenance = durableProvenance(session.transport, peer, designator),
        };
    }

    /// What authenticated the durable identity a partner advertised
    /// (ADR-0097). Reads the verification contract the adapter installed
    /// before the handshake, never a transport string alone: the transport
    /// table selects which mechanism *applies*, and the peer's own contract
    /// state says whether it was actually satisfied. A partner that advertised
    /// an address rather than a key claimed no durable identity, so there is
    /// nothing to have authenticated.
    fn durableProvenance(
        transport: []const u8,
        peer: *const engine.Peer,
        designator: []const u8,
    ) vocab.DurableProvenance {
        if (crypto.PeerKey.fromDesignator(designator) == null) return .unauthenticated;
        return switch (vocab.authenticationMechanismForTransport(transport)) {
            // The binding is installed pre-feed and the engine refuses any
            // hello claiming another key, so a live session whose claim is a
            // key spelling has had that claim proved by the transport.
            .authenticated_transport => if (peer.durable_key_transport_proved)
                .authenticated_transport
            else
                .unauthenticated,
            // The contract makes a key-designator claim without a verifying
            // credential a pre-open refusal, so an open session under it has
            // verified the credential for this designator.
            .durable_key_attestation => if (peer.require_partner_attestation)
                .durable_key_attestation
            else
                .unauthenticated,
            .none => .unauthenticated,
        };
    }

    // ── The pump ─────────────────────────────────────────────────────────────

    fn assertOwner(self: *Host) void {
        if (comptime !std.debug.runtime_safety) return;
        const tid = std.Thread.getCurrentId();
        if (self.owner_tid) |owned| {
            std.debug.assert(owned == tid);
        } else {
            self.owner_tid = tid;
        }
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

    /// Mint the host row for a fresh vow and install its retire listener —
    /// the row is heap-boxed because its address is the listener's ctx and
    /// the map may rehash. The map slot and a completion's action-queue slot
    /// are both reserved before the listener goes in, so a registered fire
    /// always finds its row and always lands its completion.
    fn mintVow(self: *Host, session: *HostSession, vow: actors.Vow, kind: VowRow.Kind) !u64 {
        const row = try self.createVowRow(session, vow, kind, self.next_vow);
        errdefer self.allocator.destroy(row);
        // A fresh vow holds no listener and cannot have settled (nothing has
        // driven since the send), so `on` can only fail on OOM.
        try session.served.port.on(&self.vat, vow, .{ .ctx = row, .func = VowRow.fire });
        self.vows.putAssumeCapacity(row.id, row);
        self.next_vow += 1;
        return row.id;
    }

    /// The shared row construction under `mintVow` and the enliven bridges:
    /// allocate the row under the caller-chosen `id` and reserve both the
    /// vow-map slot and action-queue capacity for every live vow plus this
    /// one, so no later fire's completion append can fail — a settled vow with
    /// no completion is unrepresentable. The caller installs the vat listener,
    /// then commits with `putAssumeCapacity`; an id drawn fresh from
    /// `next_vow` is bumped by that caller, while a parked select-or-dial
    /// enliven brings the id it minted when it staged the dial.
    fn createVowRow(self: *Host, session: ?*HostSession, vow: actors.Vow, kind: VowRow.Kind, id: u64) !*VowRow {
        const row = try self.allocator.create(VowRow);
        errdefer self.allocator.destroy(row);
        row.* = .{
            .host = self,
            .peer_id = if (session) |s| s.peer_id else null,
            .id = id,
            .vow = vow,
            .kind = kind,
        };
        try self.vows.ensureUnusedCapacity(self.allocator, 1);
        // The vow this row is for settles exactly once.
        try self.reserveActions(1);
        return row;
    }

    /// Mint the host vow behind a wire-riding enliven: the row (whose vat
    /// listener slot the bridge holds instead) plus the bridge that keys on the
    /// wire answer and borrows the session-owned swissnum when the resolution
    /// arrives.
    fn mintEnlivenVow(self: *Host, session: *HostSession, answer: model.AnswerPosition) !u64 {
        const id = try self.mintEnlivenVowAt(session, answer, self.next_vow);
        self.next_vow += 1;
        return id;
    }

    /// The explicit-id half of `mintEnlivenVow`: a parked select-or-dial
    /// enliven settles under the id its caller already holds, so the id is an
    /// argument rather than a draw, and `next_vow` moves only where an id is
    /// genuinely fresh.
    fn mintEnlivenVowAt(self: *Host, session: *HostSession, answer: model.AnswerPosition, id: u64) !u64 {
        const bridge = try self.allocator.create(EnlivenListener);
        errdefer self.allocator.destroy(bridge);
        const row = try self.createVowRow(session, .{ .far = answer }, .plain, id);
        errdefer self.allocator.destroy(row);
        bridge.* = .{ .host = self, .peer_id = session.peer_id, .answer = answer, .vow_id = row.id };
        try session.served.port.on(&self.vat, .{ .far = answer }, .{ .ctx = bridge, .func = EnlivenListener.fire });
        self.vows.putAssumeCapacity(row.id, row);
        return row.id;
    }

    /// Retire a vow row with its resolution: remove and free the row first —
    /// every later verb on the id refuses `NoSuchVow` — then route the
    /// outcome. An `inner` listener hears the resolution borrowed, exactly
    /// the `actors.Listener` contract; with no listener the outcome is
    /// queued as an owned `settled`/`failed` completion.
    fn settleRow(self: *Host, row: *VowRow, resolution: actors.Resolution) void {
        const inner = row.inner;
        const kind = row.kind;
        const maybe_peer = row.peer_id;
        const id = row.id;
        std.debug.assert(self.vows.remove(id));
        self.allocator.destroy(row);
        // A resolver row (ADR-0102) has no session and never queues a
        // completion: the settle is the resolver holder's own act, so it
        // already knows the outcome. Defensive — the resolver verbs retire
        // their row before the vat settles, so no fire reaches here.
        const peer_id = maybe_peer orelse {
            if (inner) |listener| listener.func(listener.ctx, resolution);
            return;
        };
        const routed = if (kind == .fetch) self.enrollFetched(peer_id, resolution) else resolution;
        if (inner) |listener| {
            listener.func(listener.ctx, routed);
            return;
        }
        self.queueCompletion(peer_id, id, routed);
    }

    /// Settle a vow by id — the enliven bridge's path to the shared retire
    /// logic. A row already gone (the session was released and dropped
    /// its rows) has no one to tell.
    fn fireVow(self: *Host, vow_id: u64, resolution: actors.Resolution) void {
        const row = self.vows.get(vow_id) orelse return;
        self.settleRow(row, resolution);
    }

    /// The fetch settlement mapping: enroll a fulfilled far capability under
    /// a node-unique token *before* the outcome is dispatched, so a reply
    /// that immediately re-gifts it routes to the right exporter. A
    /// reference already in the token range (an auto-redeemed give settled
    /// with a routable token) passes through unwrapped — enrolling a token
    /// would double-wrap it into a reference no session can lower. An
    /// unenrollable capability would mis-route a later re-gift, so it fails
    /// loud as a break rather than surfacing half-usable.
    fn enrollFetched(self: *Host, peer_id: engine.PeerId, resolution: actors.Resolution) actors.Resolution {
        if (resolution == .fulfilled) if (asFarRef(resolution.fulfilled)) |far| {
            switch (model.ImportName.classify(far.import_position.int())) {
                // Already a token: enrolling again would double-wrap it into a
                // reference no session can lower.
                .token => {},
                .wire => {
                    const token = self.node.enrollForeign(peer_id, .{ .far = far }) catch |err| {
                        return .{ .broken = @errorName(err) };
                    };
                    return .{ .fulfilled = .{ .reference = token } };
                },
            }
        };
        return resolution;
    }

    /// Enroll a capability `session` holds under a node-unique token, so it can
    /// be handed to a third party, and return that token.
    ///
    /// An import position is a name on one session and nowhere else, so the
    /// node cannot route a capability it has never been told the home of. That
    /// is why `fetch` enrolls its result (`enrollFetched`): the gifter
    /// intercept looks the reply's capability up by token, and a capability
    /// with no token has no recorded home, so the intercept declines and the
    /// reply goes out as a raw position naming nothing on the recipient's
    /// session. Every other way to come by a capability — returned from a
    /// call, lifted from a delivered argument — arrives without one. This is
    /// the verb that gives it one.
    ///
    /// Enrolling is how an application says it intends to hand this capability
    /// on, which is a capability act rather than bookkeeping, and it is the
    /// same reason `releaseImport` exists beside the finalizer path. It is not
    /// done for every capability that settles: a token is what the node routes,
    /// not what the partner named, so blanket enrollment would hand back ids
    /// that no longer answer to `releaseImport` and would switch on the node's
    /// per-send lowering walk for applications that never introduce anyone.
    ///
    /// Idempotent per import, by `Node.enrollForeign`: the same capability
    /// keeps the token it was first given, so enrolling twice cannot give one
    /// object two identities. A position already in the token range is already
    /// routable and is returned unchanged, because enrolling a token would
    /// double-wrap it into a reference no session can lower.
    ///
    /// A position with no import row on this session is refused
    /// `ForeignArgument`, and the rule is the row rather than reachability.
    /// A row is usually missing because the position names nothing here, and
    /// minting a token for it would route a later gift to a capability the
    /// partner never exported. It is also where `Node.enrollForeign` remembers
    /// the token a capability already has, so a position with no row could not
    /// be enrolled idempotently: a second call would mint a second token, and
    /// one object wearing two identities is what the idempotency above exists
    /// to prevent. The partner's pinned bootstrap is the one addressable
    /// position that can be missing a row (it is reachable without one until
    /// something fetches through it, which registers it), and it answers to
    /// the same rule rather than an exception.
    ///
    /// `kind` says whether the position names a settled capability or a promise
    /// the partner has not settled, and the caller has to supply it because the
    /// session cannot. A far reference encodes as `desc:export` whatever it
    /// points at (`session.slot`'s `remote_value` carries no kind field), so the
    /// import row records the position and nothing about its settledness. The
    /// one place a received reference's promise-ness survives is the reference
    /// the application was handed. Routing reads the kind off the enrolled row:
    /// a promise enrolled as an object is not recognized by the
    /// introducing-session proxy (`Node.proxyForeignPromiseFulfill`), so
    /// replying with it hands a recipient a position rather than a promise it
    /// can wait on.
    ///
    /// A row already enrolled under the other kind is refused
    /// `EnrolledKindConflict`. The kind lives on the row, and the row is what
    /// routing reads, so `Node.enrollForeign` answers a second caller with the
    /// kind it recorded rather than the one just asked for. Returning that token
    /// in silence would leave the caller believing the row agreed with the kind
    /// it asked for, and the proxy would then decline the token the caller was
    /// told to expect a settlement through. A fresh enroll cannot conflict,
    /// since the row is created with the kind asked for; only re-enrolling one
    /// position under both kinds does. The native `driver.Session.enroll` takes
    /// a whole `model.FarRef`, so it cannot name a kind the reference disagrees
    /// with in the first place; this tier is C-shaped and takes the two apart.
    ///
    /// The token fast path below returns `position` unchanged and ignores
    /// `kind`: a token is already routable, and the row it was minted from
    /// holds the kind, so there is nothing here to record or to disagree with.
    pub fn enrollCapability(
        self: *Host,
        session: *HostSession,
        position: u64,
        kind: model.RefKind,
    ) !u64 {
        self.assertOwner();
        try self.checkSession(session);
        switch (model.ImportName.classify(position)) {
            .token => return position,
            .wire => {},
        }
        if (!session.served.port.peer.session_state.hasImport(model.ImportPosition.from(position)))
            return HostError.ForeignArgument;
        const token = try self.node.enrollForeign(
            session.peer_id,
            .{ .far = .{ .import_position = .from(position), .kind = kind } },
        );
        if (token.far.kind != kind) return HostError.EnrolledKindConflict;
        return token.far.import_position.int();
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

    /// The live dialed session whose selected peer matches `(transport,
    /// designator)`, for Host-level select-or-dial (ADR-0098 step 4). Dialed
    /// sessions only: an accepted address session cannot prove its claimed
    /// designator, and the enliven path re-verifies whatever this returns
    /// through the complete sturdyref peer check.
    pub fn dialedSessionFor(self: *Host, transport: []const u8, designator: []const u8) ?*HostSession {
        self.assertOwner();
        const peer_id = self.dialed_by_designator.get(designator) orelse return null;
        const session = self.sessions.get(peer_id) orelse return null;
        if (session.condemned) return null;
        if (!std.mem.eql(u8, session.transport, transport)) return null;
        return session;
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

    /// The Port position serving `name` on `session`: a name this session's
    /// own publish bound resolves in its bootstrap registry, and a Host-wide
    /// alias lazily projects its Vat actor onto the session's Port. Null when
    /// neither namespace holds the name.
    pub fn publishedPosition(self: *Host, session: *HostSession, name: []const u8) !?u64 {
        self.assertOwner();
        try self.checkSession(session);
        if (session.served.port.peer.session_state.bootstrapLookup(name)) |position| return position.int();
        const position = try resolvePublishedTarget(self, session.peer_id, name) orelse return null;
        return position.int();
    }

    /// Queue a settled vow's completion for the embedder — infallible by
    /// reservation (`createVowRow` and every fallible enqueue keep one spare
    /// slot per live vow), so a fire can never strand. The fulfilled value
    /// is deep-cloned onto the host: the settle fires inside `feed` while
    /// the resolution is turn-borrowed, and the embedder drains after `feed`
    /// returns, so an owning completion is the only correct holder (the
    /// in-process `vowOn` path stays borrowed and pays no clone). A clone
    /// failure degrades to a `failed` completion with an empty message —
    /// zero-allocation — rather than a stranded vow.
    fn queueCompletion(self: *Host, peer_id: engine.PeerId, vow_id: u64, resolution: actors.Resolution) void {
        switch (resolution) {
            .fulfilled => |value| {
                const cloned = model.cloneArgument(self.allocator, value) catch {
                    self.actions.pushReserved(.{ .failed = .{ .peer_id = peer_id, .vow_id = vow_id, .message = "" } });
                    return;
                };
                self.actions.pushReserved(.{ .settled = .{ .peer_id = peer_id, .vow_id = vow_id, .value = cloned } });
            },
            .broken => |message| {
                const owned: []const u8 = self.allocator.dupe(u8, message) catch "";
                self.actions.pushReserved(.{ .failed = .{ .peer_id = peer_id, .vow_id = vow_id, .message = owned } });
            },
            // Unreachable by construction — the host claims every inbound
            // give before the vat can settle a vow with it (auto-redeem) —
            // but a defensive break beats a crash if that invariant moves.
            .give => {
                const owned: []const u8 = self.allocator.dupe(u8, "raw handoff reached a settle listener") catch "";
                self.actions.pushReserved(.{ .failed = .{ .peer_id = peer_id, .vow_id = vow_id, .message = owned } });
            },
        }
    }

    /// Drop the vow rows homed on a released session, so the map does not
    /// grow with session churn. The session's far rows already retired
    /// through its vow break; what remains is never-fired rows whose vat
    /// listener dies with the vat, freed here. Removal invalidates the
    /// iterator, so each scan collects a bounded batch of doomed ids into
    /// stack scratch (allocation-free — this runs inside teardown) and
    /// removes them between scans; one scan per batch, not one per row.
    fn dropVowRows(self: *Host, peer_id: engine.PeerId) void {
        var doomed: [64]u64 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.vows.iterator();
            while (it.next()) |entry| {
                const row_peer = entry.value_ptr.*.peer_id orelse continue; // a resolver row outlives every session
                if (row_peer != peer_id) continue;
                doomed[n] = entry.key_ptr.*;
                n += 1;
                if (n == doomed.len) break;
            }
            if (n == 0) return;
            for (doomed[0..n]) |id| {
                const row = self.vows.fetchRemove(id) orelse unreachable;
                self.allocator.destroy(row.value);
            }
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

    const Projection = union(enum) { index: i64, untag: []const u8, get: []const u8 };

    fn vowProjection(self: *Host, vow_id: u64, projection: Projection) !u64 {
        const resolved = try self.resolveVowSession(vow_id);
        const source = switch (resolved.row.vow) {
            .far => |answer| answer,
            // A local vow has no wire answer to project against.
            .local => return vocab.Error.NotPipelineable,
        };
        const peer = resolved.session.served.port.peer;
        const answer = model.AnswerPosition.from(peer.allocateAnswer());
        const receiver: model.Reference = .{ .promise = .{ .answer_position = source } };
        switch (projection) {
            .index => |index| try peer.sendCopying(.{ .index = .{ .receiver = receiver, .index = index, .answer = answer } }),
            .untag => |tag| try peer.sendCopying(.{ .untag = .{ .receiver = receiver, .tag = tag, .answer = answer } }),
            .get => |field| try peer.sendCopying(.{ .get = .{ .receiver = receiver, .field = field, .answer = answer } }),
        }
        const id = try self.mintVow(resolved.session, .{ .far = answer }, .plain);
        try host_pump.dirtyThenPump(self, resolved.session.peer_id);
        return id;
    }

    /// The live session and row a latch-legal vow verb operates on: assert the
    /// owner, resolve the vow's row and its session, and refuse a settled or
    /// unknown vow (its row already retired) or a dead session alike with
    /// `NoSuchVow`. `vowOn`, `vowSend`, and `vowProjection` share this prelude
    /// and differ only in the body that follows.
    fn resolveVowSession(self: *Host, vow_id: u64) HostError!struct { row: *VowRow, session: *HostSession } {
        self.assertOwner();
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        const peer_id = row.peer_id orelse return HostError.SessionlessVow;
        const session = self.sessions.get(peer_id) orelse return HostError.NoSuchVow;
        try self.checkSession(session);
        return .{ .row = row, .session = session };
    }

    /// Test seam: session-tagged embedder FIFO dedupe (flush/close).
    pub fn testingQueueUniqueSessionAction(self: *Host, comptime tag: host_pump.UniqueSessionActionTag, peer_id: engine.PeerId) !void {
        try host_pump.testingQueueUniqueSessionAction(self, tag, peer_id);
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
    fn hostBeforeServe(ctx: ?*anyopaque, served: *Served, event: *engine.Event) anyerror!bool {
        _ = served;
        const session: *HostSession = @ptrCast(@alignCast(ctx.?));
        const host = session.host;
        const body = event.view() catch return false;
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
        if (try claimProxyListenerFire(host, session.peer_id, body)) return true;
        if (body != .resolve) return false;
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
        return try host.node.claimResolve(session.peer_id, resolve.answer.int(), redeemOutcome(resolve));
    }

    fn hostResolveInterceptor(ctx: ?*anyopaque, answer: model.AnswerPosition, fulfilled: model.Argument) anyerror!actors.InterceptOutcome {
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
    fn claimProxyListenerFire(host: *Host, peer_id: engine.PeerId, body: model.view.Body) !bool {
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
        // establishes that the partner holds `session_pubkey`; it says nothing
        // about the location the partner names as its own. On the transports
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
        if (crypto.PeerKey.fromDesignator(designator)) |claimed| {
            if (!std.mem.eql(u8, &claimed.bytes, &partner_key.bytes)) return;
        }
        const verdict = self.hellos.checkInbound(designator, partner_pid) orelse return;
        if (verdict.abort_inbound) {
            // Not lower: this accepted session is the loser; the pair keeps
            // the session our own dial opened.
            try host_pump.condemn(self, session, .crossed_hellos, "crossed hellos: higher-keyed side aborting its inbound session");
            return;
        }
        // Strictly lower: our own dial to this partner is the loser; the pair
        // keeps this accepted session. `dialed_by_designator` is the O(1)
        // index (populated at enroll); do not rescan every live session.
        if (self.liveIndexedSession(self.dialed_by_designator.get(designator))) |candidate| {
            try host_pump.condemn(self, candidate, .crossed_hellos, "crossed hellos: lower-keyed side aborting its outbound session");
        }
    }
};

/// The host-owned one-shot behind a wire-riding `Host.enliven`: record the
/// enlivenment in the session's dedup cache (or clear the in-flight marker on
/// a break) before the outcome reaches the vow, then free itself. It holds the
/// answer's one vat listener slot; the vow row it settles routes the outcome
/// to `vowOn`'s listener or the action queue like any other settlement.
const EnlivenListener = struct {
    host: *Host,
    peer_id: engine.PeerId,
    answer: model.AnswerPosition,
    vow_id: u64,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const bridge: *EnlivenListener = @ptrCast(@alignCast(ctx.?));
        const host = bridge.host;
        const vow_id = bridge.vow_id;
        defer host.allocator.destroy(bridge);
        // A session already released (this fire is its teardown break)
        // has no session to bookkeep; the vow still settles.
        if (host.sessions.get(bridge.peer_id)) |session| {
            const peer = session.served.port.peer;
            if (peer.session_state.pendingEnlivenSwissnum(bridge.answer)) |swissnum| {
                if (if (resolution == .fulfilled) asFarRef(resolution.fulfilled) else null) |far| {
                    // The far is POD; `recordEnlivenment` caches it and clears
                    // the in-flight marker. It only errors on a non-far/broken
                    // outcome, which a `.far` fulfillment never is.
                    _ = engine.sturdyref.recordEnlivenment(peer.allocator, &peer.session_state, swissnum, .{
                        .fulfilled = .{ .far = far },
                    }) catch unreachable;
                } else {
                    peer.finishPendingEnliven(swissnum);
                }
            }
        }
        host.fireVow(vow_id, resolution);
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
