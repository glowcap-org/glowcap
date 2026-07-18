//! The sans-io byte-fed multi-session CapTP host core (ADR-0072), under the
//! `driver_core` I/O ban. A `Host` owns one `engine.Node` (identity, shared
//! gift registry, routing, the redeem serve step) and mints byte-fed
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
//! completion loop over this core, ADR-0076); the C ABI's `libpancake_driver`
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
const vocab = @import("vocab.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const host_action = @import("host_action.zig");
const host_pump = @import("host_pump.zig");
const Served = served_mod.Served;
const CrossedHellos = crossed_hellos.CrossedHellos;
const HostAction = host_action.HostAction;

const crypto = foundation.crypto;

/// The typed refusals the byte-fed host adds over the shared driver vocabulary.
pub const HostError = error{
    /// The session lost the crossed-hellos tiebreak (ADR-0030) and is
    /// condemned: its typed abort is queued for the embedder to drain, and no
    /// further verb may ride it.
    ConnectionCondemned,
    /// A top-level (host-driving) verb was re-entered from inside a listener
    /// or behavior callback. Every public verb is one of two kinds: top-level
    /// verbs refuse this error under the latch, and the enqueueing verbs —
    /// `send`/`tell`, the vow verbs, `gcRelease`, `setExporterLocation` — are
    /// legal there, their effects encoded and pumped when the enclosing
    /// top-level verb unwinds.
    ReenteredHost,
    /// A host vow id names no live row: never minted, or its session was
    /// released.
    NoSuchVow,
    /// A send argument is a capability foreign to the session the send
    /// rides, which would mis-encode the reference for that partner. The send
    /// is refused whole.
    ForeignArgument,
    /// The target token's exporter session is gone; the send is dropped,
    /// not mis-sent (the node's fail-closed contract).
    TokenRetired,
    /// `gcRelease` was given an id below the node's token range; only a
    /// fetched capability's token resolves to a wire import to release.
    NotAToken,
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
    if (fulfilled != .reference or fulfilled.reference != .far) return .{ .resolve = fulfilled };
    const far_id = fulfilled.reference.far.import_position.int();
    // Break reasons reach the wire via vat `@errorName`; Node uses snake_case
    // (`session_not_open`) so the CapTP string is not Zig PascalCase.
    if (try node.proxyForeignPromiseFulfill(peer_id, far_id)) |proxy| {
        return .{ .resolve = .{ .reference = proxy } };
    }
    if (try node.interceptFulfilledRef(peer_id, answer.int(), far_id)) return .claimed;
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
    role: Role,
    /// Set when this session lost the crossed-hellos tiebreak: its typed
    /// abort is queued, and every verb refuses `ConnectionCondemned`.
    condemned: bool = false,
    /// Partner session key this shell is indexed under in `Host.partner_by_key`,
    /// set in `indexPartnerKey` (before apply writes `partnerSessionKey`).
    /// Lets `unindexSession` stay O(1) without scanning the map.
    indexed_partner_key: ?[crypto.PEER_KEY_BYTES]u8 = null,

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
        return self.served.peer.sessionIsOpen();
    }
};

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
    sessions: std.AutoHashMapUnmanaged(engine.PeerId, *HostSession) = .{},
    /// Crossed-hellos tiebreak state (ADR-0030): `openDialedLocator` registers
    /// the outbound before its hello moves; accepted CapTP sessions compare
    /// inbound start-sessions against it.
    hellos: CrossedHellos = .{},
    /// CapTP partner session key → enrolled peer id (ADR-0012). O(1) lookup for
    /// `refuseDuplicatePartnerKey` and keyed `refuseDuplicateDial`. GPA rows with
    /// precise per-row frees on condemn / release — not a bump arena (rows leave
    /// individually). Verified identity only: the handshake signature proves the
    /// key; address-transport designators are never indexed here.
    partner_by_key: std.AutoHashMapUnmanaged([crypto.PEER_KEY_BYTES]u8, engine.PeerId) = .{},
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
    /// Encode worklist: sessions with enqueued-but-unencoded outbound (a
    /// nested verb's send, a settle listener's reply). The top-level verb's
    /// unwind drives each one (`Served.driveFed`) and may then queue a
    /// `HostAction.flush` for the embedder. Distinct from the action FIFO by
    /// design — `pending_flush` is encode work; `actions.flush` is the
    /// embedder write signal.
    pending_flush: std.ArrayListUnmanaged(engine.PeerId) = .empty,
    /// Sessions holding a `withdraw-gift` parked awaiting its deposit
    /// (ADR-0056). A deposit and its matching withdraw travel on different
    /// sessions of one host, so a withdraw that arrives first parks until the
    /// deposit lands — on a *sibling* session. The pump re-steps these when the
    /// shared registry gains a deposit (`last_deposit_gen`), the single-thread
    /// analog of the thread-per-connection driver's continuous per-session
    /// step. Small: only handoff exporters in flight, not every connection.
    parked_withdraw_sessions: std.ArrayListUnmanaged(engine.PeerId) = .empty,
    /// The shared gift registry's deposit generation last acted on. When it
    /// moves, a deposit landed, so `parked_withdraw_sessions` are re-driven
    /// once. Bounds the retry to actual deposits, never a per-frame sweep.
    last_deposit_gen: u64 = 0,
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
        /// Syrup, the Goblins-interop target; both ends of a session must
        /// carry the same codec (`op:start-session` carries no codec operand,
        /// so agreement is the embedder's, exactly as on the raw peer tier).
        codec: model.CodecId = .syrup,
        /// Local-turn amplification cap per drive, applied to every minted
        /// CapTP session's serve core (see `Served.local_turn_budget`). A loop
        /// embedder sets it so one message that amplifies without bound cannot
        /// stall the thread serving every session: the flooded session is
        /// condemned with a `resource_exhausted` abort and a `close` action
        /// names it for the embedder. Null (the default) drives unbounded, the
        /// blocking one-session-per-thread posture.
        local_turn_budget: ?usize = null,

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
        peer_id: engine.PeerId,
        id: u64,
        vow: actors.Vow,
        kind: Kind = .plain,
        inner: ?actors.Listener = null,

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
            session.*.served.vat.breakFarVows(session.*.served.closeReason("host released"));
        }
        var free_it = self.sessions.valueIterator();
        while (free_it.next()) |session| {
            // Drop index rows before freeing borrowed dialed-designator keys.
            self.unindexSession(session.*);
            session.*.served.deinit();
            switch (session.*.role) {
                .dialed => |designator| self.allocator.free(designator),
                .accepted => {},
            }
            self.allocator.destroy(session.*);
        }
        self.sessions.deinit(self.allocator);
        self.hellos.deinit(self.allocator);
        self.partner_by_key.deinit(self.allocator);
        self.dialed_by_designator.deinit(self.allocator);
        if (self.last_action) |last| host_action.freeAction(self.allocator, last);
        for (self.actions.unpopped()) |action| host_action.freeAction(self.allocator, action);
        self.actions.deinit(self.allocator);
        // The far rows retired themselves through the break above; what
        // remains is never-fired local rows, freed here with the vats gone.
        var vow_it = self.vows.valueIterator();
        while (vow_it.next()) |row| self.allocator.destroy(row.*);
        self.vows.deinit(self.allocator);
        self.pending_flush.deinit(self.allocator);
        self.parked_withdraw_sessions.deinit(self.allocator);
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
        // Register the outbound before any bytes move: a crossed inbound
        // start-session from the same partner must find this dial (ADR-0030).
        const our_pid = crypto.derivePublicIdentifier(self.node.secretKey().publicKey());
        try self.hellos.registerOutbound(self.allocator, partner_designator, our_pid);
        errdefer self.hellos.unregister(self.allocator, partner_designator);
        const partner = try self.allocator.dupe(u8, partner_designator);
        errdefer self.allocator.free(partner);

        const session = switch (source) {
            .mint => try self.mint(.{ .dialed = partner }),
            .over => |peer| try self.mintOver(peer, .{ .dialed = partner }),
        };
        // Dialed-specific pin before hello; on failure unwind the mint. The
        // shared open tail's `errdefer failOpen` covers hello failures.
        if (vocab.designatorSchemeForTransport(transport) == .key) {
            const expected = crypto.PeerKey.fromDesignator(partner_designator) orelse {
                self.failOpen(session);
                return error.InvalidAddress;
            };
            session.served.peer.expectPartnerKey(expected);
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
        return self.helloAndEnroll(try self.mint(.accepted), transport, designator, direct_addresses_hint);
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
        return self.helloAndEnroll(try self.mintOver(peer, .accepted), transport, designator, direct_addresses_hint);
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
        if (crypto.PeerKey.fromDesignator(partner_designator)) |want| {
            if (self.liveIndexedSession(self.partner_by_key.get(want.bytes))) |s| return s;
        }
        return null;
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
        const partner_key = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return;
        const existing_pid = self.partner_by_key.get(partner_key.bytes) orelse {
            try self.indexPartnerKey(session, partner_key.bytes);
            return;
        };
        const other = self.liveIndexedSession(existing_pid) orelse {
            // Stale index row (session released without unindex); replace.
            try self.indexPartnerKey(session, partner_key.bytes);
            return;
        };
        if (other == session) return;

        const our_pid = crypto.derivePublicIdentifier(self.node.secretKey().publicKey());
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
        if (loser == other) try self.indexPartnerKey(session, partner_key.bytes);
    }

    /// Index a live session under its verified partner session key. Replaces any
    /// prior row for that key (caller condemned the previous holder). Reserves
    /// its own slot: the partner key is unknown until the partner's
    /// `op:start-session` arrives, so the reservation pairs 1:1 with this insert
    /// rather than with the earlier mint (mints between start-sessions would
    /// otherwise never grow the map, and a burst of un-indexed sessions would
    /// overflow the mint reservation). Fails closed on OOM before apply.
    fn indexPartnerKey(self: *Host, session: *HostSession, key: [crypto.PEER_KEY_BYTES]u8) !void {
        try self.partner_by_key.ensureUnusedCapacity(self.allocator, 1);
        self.partner_by_key.putAssumeCapacity(key, session.peer_id);
        session.indexed_partner_key = key;
    }

    /// Drop this session from the partner-key and dialed-designator indexes.
    /// Idempotent: safe when the session was never indexed.
    pub fn unindexSession(self: *Host, session: *HostSession) void {
        if (session.indexed_partner_key) |key| {
            if (self.partner_by_key.get(key)) |pid| {
                if (pid == session.peer_id) {
                    std.debug.assert(self.partner_by_key.remove(key));
                }
            }
            session.indexed_partner_key = null;
        }
        if (session.role == .dialed) {
            // tolerant: condemn / a prior unindex may already have removed it.
            _ = self.dialed_by_designator.remove(session.role.dialed);
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
        // address and is refused earlier when it is missing). An address
        // transport signs no hints. `model.Hints.forDirectAddresses` owns the
        // `#f`-empty-vs-entry spelling every keyed hello shares.
        var entry_buf: [1]model.HintEntry = undefined;
        const hints = if (vocab.designatorSchemeForTransport(transport) == .key)
            model.Hints.forDirectAddresses(direct_addresses_hint, &entry_buf)
        else
            model.Hints.emptyFalse();
        try session.served.peer.sendKeyedStartSession(.v1_0, .{
            .transport = transport,
            .designator = designator,
            .hints = hints,
        }, self.node.secretKey());
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
        self.in_callback = true;
        session.served.vat.breakFarVows(session.served.closeReason("connection released"));
        self.in_callback = false;

        if (session.role == .dialed) self.hellos.unregister(self.allocator, session.role.dialed);
        self.unindexSession(session);
        std.debug.assert(self.sessions.remove(session.peer_id));
        const peer_id = session.peer_id;
        self.dropVowRows(peer_id);
        session.served.deinit();
        switch (session.role) {
            .dialed => |designator| self.allocator.free(designator),
            .accepted => {},
        }
        self.allocator.destroy(session);
        self.node.removePeer(peer_id);
        try host_pump.finishVerb(self);
    }

    /// One node-registered CapTP session shell over a node-owned peer: mint the
    /// peer, apply the host posture, and allocate the `HostSession`. The
    /// map slot is reserved here so `enroll` cannot fail; a caller that fails
    /// after this unwinds with `failOpen`.
    fn mint(self: *Host, role: HostSession.Role) !*HostSession {
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        if (role == .dialed) try self.dialed_by_designator.ensureUnusedCapacity(self.allocator, 1);
        const peer_id = try self.node.registerPeer(self.negotiatingOptions());
        errdefer self.node.removePeer(peer_id);
        return self.mintShell(self.node.peer(peer_id).?, peer_id, role);
    }

    /// `mint` over a peer the embedder already owns and pins at a stable
    /// address (`engine.Node.registerPeerOver`): the node routes through it
    /// and the host serves it, but neither ever frees it — `releaseSession` and
    /// `deinit` only unregister the slot, and the embedder frees the peer
    /// after `releaseSession`. This is how a peer-owning loop, whose fixed slots
    /// hold each peer inline, puts its sessions under one host.
    fn mintOver(self: *Host, peer: *engine.Peer, role: HostSession.Role) !*HostSession {
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        if (role == .dialed) try self.dialed_by_designator.ensureUnusedCapacity(self.allocator, 1);
        const peer_id = try self.node.registerPeerOver(peer);
        errdefer self.node.removePeer(peer_id);
        return self.mintShell(peer, peer_id, role);
    }

    /// The host posture imposed on every minted or adopted peer.
    fn negotiatingOptions(self: *const Host) engine.Peer.NegotiatingOptions {
        return .{
            .codec = self.opts.codec,
            .verify_partner_handshake = self.opts.verify_partner,
            .limits = self.opts.limits,
        };
    }

    /// The shared mint tail: impose the host's peer posture through the
    /// engine's `reposture` verb (asserted negotiating, no bytes moved) and
    /// allocate the shell, for minted and adopted peers alike. Owned mints
    /// already received the same knobs at `registerPeer`; `reposture` is
    /// idempotent for that path and the only imposition for an adopted peer.
    fn mintShell(self: *Host, peer: *engine.Peer, peer_id: engine.PeerId, role: HostSession.Role) !*HostSession {
        peer.reposture(self.negotiatingOptions());

        const session = try self.allocator.create(HostSession);
        session.* = .{
            .host = self,
            .peer_id = peer_id,
            .served = Served.over(self.allocator, peer),
            .role = role,
        };
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
    fn enroll(self: *Host, session: *HostSession) void {
        session.served.serve_options = .{ .hook_ctx = session, .before_serve = hostBeforeServe };
        session.served.vat.setResolveInterceptor(.{ .ctx = session, .func = hostResolveInterceptor });
        self.sessions.putAssumeCapacity(session.peer_id, session);
        if (session.role == .dialed) {
            self.dialed_by_designator.putAssumeCapacity(session.role.dialed, session.peer_id);
        }
    }

    /// Unwind a failed open: retire the session id (running the node's
    /// fail-closed sweep) and free the shell. The dialed designator, when the
    /// caller already duped it, is the caller's own errdefer.
    fn failOpen(self: *Host, session: *HostSession) void {
        self.unindexSession(session);
        // tolerant: enrolled only when the failure came after `enroll`.
        _ = self.sessions.remove(session.peer_id);
        const peer_id = session.peer_id;
        session.served.deinit();
        self.allocator.destroy(session);
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
                try s.c.served.feedBorrowed(s.f);
            }
        }{ .c = session, .f = frame });
    }

    /// Feed a byte-stream chunk the embedder read from its own transport
    /// (borrowed for the call). The core owns framing: the session's codec
    /// delimits each complete frame at the front of `bytes` — both codecs,
    /// both frame shapes — and dispatches it exactly as `feed`, behavior and
    /// settle callbacks firing inside, the pump running at the unwind.
    /// Returns how many leading bytes were consumed; the embedder keeps the
    /// unconsumed tail and extends it with its next read (a partial frame is
    /// not an error, just an unconsumed tail). Consumption also stops at the
    /// frame that completes the keyed handshake: bytes coalesced behind the
    /// hello stay in the tail while the embedder acts on the fresh session
    /// (publish, fetch), and the next call feeds them — post-open feeding is
    /// unaffected. A frame exceeding the
    /// session's `frame_cap` (`error.FrameTooLarge`) or a malformed prefix
    /// projects a typed `op:abort` and surfaces the error, like any `feed`
    /// failure; the consumed count is not reported then, because the session
    /// is closing, not resuming.
    pub fn feedBytes(self: *Host, session: *HostSession, bytes: []const u8) !usize {
        const was_open = session.served.peer.sessionIsOpen();
        return host_pump.dispatchStreamUnderLatch(self, session, struct {
            c: *HostSession,
            bytes: []const u8,
            was_open: bool,
            pub fn call(s: @This()) !usize {
                var consumed: usize = 0;
                while (consumed < s.bytes.len) {
                    const outcome = s.c.served.peer.applyStreamPrefix(s.bytes[consumed..]) catch |err|
                        return err;
                    switch (outcome) {
                        .incomplete => break,
                        .consumed => |n| {
                            consumed += n;
                            // Serve the frame's events before delimiting the next
                            // frame, so ordering matches the whole-frame path.
                            try s.c.served.driveFed();
                            // Stop at the session-open transition: the frames
                            // behind the hello wait for the embedder's post-open
                            // setup and ride the tail into the next call.
                            if (!s.was_open and s.c.served.peer.sessionIsOpen()) break;
                        },
                    }
                }
                return consumed;
            }
        }{ .c = session, .bytes = bytes, .was_open = was_open });
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
                try s.c.served.serveEvent(s.e);
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
        return self.actions.pop();
    }

    /// Borrow the in-flight pending dial for `ticket`, or null if settled.
    /// Same contract as `Node.pendingDial`.
    pub fn pendingDial(self: *const Host, ticket: engine.Node.PendingId) ?engine.Node.PendingDialView {
        return self.node.pendingDial(ticket);
    }

    /// Report a `dial` action's success: `session` is an `openDialedLocator`
    /// against that ticket's pending locator, driven to an open session. The
    /// node withdraws every give waiting on the ticket; the withdraws and
    /// their flushes pump inside this call. A stale ticket is a no-op.
    pub fn exporterDialed(self: *Host, ticket: engine.Node.PendingId, session: *HostSession) !void {
        try self.refuseReentry();
        try checkLive(session);
        try self.node.exporterDialed(ticket, session.peer_id);
        try host_pump.finishVerb(self);
    }

    /// Report a `dial` action's failure: every redeem waiting on the ticket
    /// breaks with `reason`, firing its settle listener inside this call. A
    /// stale ticket is a no-op.
    pub fn dialFailed(self: *Host, ticket: engine.Node.PendingId, reason: []const u8) !void {
        try self.refuseReentry();
        try self.node.dialFailed(ticket, reason);
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
        const vow = try routed.session.served.send(routed.target, msg);
        const id = try self.mintVow(routed.session, vow, .plain);
        try host_pump.dirtyThenPump(self, routed.session.peer_id);
        return id;
    }

    /// Fire-and-forget eventual-send: `send` with no answer and no vow.
    pub fn tell(self: *Host, session: *HostSession, target: model.Reference, msg: actors.Message) !void {
        const routed = try self.routeSend(session, target, msg.args);
        try routed.session.served.tell(routed.target, msg);
        try host_pump.dirtyThenPump(self, routed.session.peer_id);
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
        try checkLive(session);
        const vow = try session.served.sendBootstrapFetch(name);
        const id = try self.mintVow(session, vow, .fetch);
        try host_pump.dirtyThenPump(self, session.peer_id);
        return id;
    }

    /// Enliven the sturdyref published behind `swissnum` (ADR-0012), minting
    /// a host vow for the live reference. A dedup-cache hit settles the vow
    /// before this returns — its completion is already on the action queue —
    /// and a fresh enliven rides bootstrap-fetch, the host recording the
    /// enlivenment itself when the resolution arrives, before the outcome is
    /// dispatched. Top-level: refused from inside a callback.
    pub fn enliven(self: *Host, session: *HostSession, swissnum: []const u8) !u64 {
        try self.refuseReentry();
        try checkLive(session);
        const peer = session.served.peer;
        // The core tracks no remote locator and never dials; the swissnum
        // alone identifies the cache row.
        const start = try engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, swissnum);
        switch (start) {
            .cached => |reference| {
                // Already settled: queue the completion for a fresh id and
                // never build a row, so the id refuses `NoSuchVow` exactly
                // like any other settled vow.
                const id = self.next_vow;
                try host_pump.queueHostAction(self, .{ .settled = .{ .vow_id = id, .value = .{ .reference = reference } } });
                self.next_vow += 1;
                try host_pump.finishVerb(self);
                return id;
            },
            // An enliven already in flight holds the one listener slot on its
            // answer, so a concurrent duplicate is refused `AlreadyListening`
            // rather than parked where it could never fire.
            .in_flight => |answer| {
                const id = try self.mintEnlivenVow(session, answer);
                try host_pump.finishVerb(self);
                return id;
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
                return id;
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
        try checkLive(session);
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
        self.assertOwner();
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        const session = self.sessions.get(row.peer_id) orelse return HostError.NoSuchVow;
        try checkLive(session);
        if (row.inner != null) return actors.Error.AlreadyListening;
        row.inner = listener;
    }

    /// Promise pipelining: eventual-send `msg` to a host vow before it
    /// resolves, minting a new vow for this call's own answer. A local vow has
    /// no wire answer to pipeline against (`NotPipelineable`).
    pub fn vowSend(self: *Host, vow_id: u64, msg: actors.Message) !u64 {
        self.assertOwner();
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        const session = self.sessions.get(row.peer_id) orelse return HostError.NoSuchVow;
        try checkLive(session);
        const vow = try session.served.sendToAnswer(row.vow, msg);
        const id = try self.mintVow(session, vow, .plain);
        try host_pump.dirtyThenPump(self, session.peer_id);
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
    pub fn gcRelease(self: *Host, token: u64, delta: u64) !void {
        self.assertOwner();
        if (token < engine.Node.REDEEMED_TOKEN_BASE) return HostError.NotAToken;
        const routed = self.node.routeToken(token) orelse return;
        const session = self.sessions.get(routed.peer_id) orelse return;
        try checkLive(session);
        const positions = [_]u64{routed.target.far.import_position.int()};
        const deltas = [_]u64{delta};
        try session.served.peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
        try host_pump.dirtyThenPump(self, session.peer_id);
    }

    /// Break every far vow still parked on `session`'s vat, firing each listener
    /// inside this call with the partner's retained abort diagnostic when one
    /// arrived, else `message`. The embedder calls this when its transport
    /// reports the session gone.
    pub fn breakFarVows(self: *Host, session: *HostSession, message: []const u8) !void {
        try self.refuseReentry();
        try checkLive(session);
        self.in_callback = true;
        session.served.vat.breakFarVows(session.served.closeReason(message));
        self.in_callback = false;
        try host_pump.finishVerb(self);
    }

    /// Record the exporter locator to embed in gives whose exporter is `session`
    /// (see `engine.Node.setExporterLocation`); `null` clears the override back
    /// to the session record. The node encodes the locator to canonical Syrup
    /// record bytes — a URI string is unrepresentable here.
    pub fn setExporterLocation(self: *Host, session: *HostSession, location: ?model.PeerLocator) !void {
        self.assertOwner();
        try checkLive(session);
        try self.node.setExporterLocation(session.peer_id, location);
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

    /// Mint the host row for a fresh vow and install its retire listener —
    /// the row is heap-boxed because its address is the listener's ctx and
    /// the map may rehash. The map slot and a completion's action-queue slot
    /// are both reserved before the listener goes in, so a registered fire
    /// always finds its row and always lands its completion.
    fn mintVow(self: *Host, session: *HostSession, vow: actors.Vow, kind: VowRow.Kind) !u64 {
        const row = try self.createVowRow(session, vow, kind);
        errdefer self.allocator.destroy(row);
        // A fresh vow holds no listener and cannot have settled (nothing has
        // driven since the send), so `on` can only fail on OOM.
        try session.served.vat.on(vow, .{ .ctx = row, .func = VowRow.fire });
        self.vows.putAssumeCapacity(row.id, row);
        self.next_vow += 1;
        return row.id;
    }

    /// The shared row construction under `mintVow` and the enliven bridge:
    /// allocate the row and reserve both the vow-map slot and action-queue
    /// capacity for every live vow plus this one, so no later fire's
    /// completion append can fail — a settled vow with no completion is
    /// unrepresentable. The caller installs the vat listener, then commits
    /// with `putAssumeCapacity` and bumps `next_vow`.
    fn createVowRow(self: *Host, session: *HostSession, vow: actors.Vow, kind: VowRow.Kind) !*VowRow {
        const row = try self.allocator.create(VowRow);
        errdefer self.allocator.destroy(row);
        row.* = .{ .host = self, .peer_id = session.peer_id, .id = self.next_vow, .vow = vow, .kind = kind };
        try self.vows.ensureUnusedCapacity(self.allocator, 1);
        try self.actions.reserve(self.allocator, self.vows.count() + 1);
        return row;
    }

    /// Mint the host vow behind a wire-riding enliven: the row (whose vat
    /// listener slot the bridge holds instead) plus the bridge that keys on the
    /// wire answer and borrows the session-owned swissnum when the resolution
    /// arrives.
    fn mintEnlivenVow(self: *Host, session: *HostSession, answer: model.AnswerPosition) !u64 {
        const bridge = try self.allocator.create(EnlivenListener);
        errdefer self.allocator.destroy(bridge);
        const row = try self.createVowRow(session, .{ .far = answer }, .plain);
        errdefer self.allocator.destroy(row);
        bridge.* = .{ .host = self, .peer_id = session.peer_id, .answer = answer, .vow_id = row.id };
        try session.served.vat.on(.{ .far = answer }, .{ .ctx = bridge, .func = EnlivenListener.fire });
        self.vows.putAssumeCapacity(row.id, row);
        self.next_vow += 1;
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
        const peer_id = row.peer_id;
        const id = row.id;
        std.debug.assert(self.vows.remove(id));
        self.allocator.destroy(row);
        const routed = if (kind == .fetch) self.enrollFetched(peer_id, resolution) else resolution;
        if (inner) |listener| {
            listener.func(listener.ctx, routed);
            return;
        }
        self.queueCompletion(id, routed);
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
        if (resolution == .fulfilled and resolution.fulfilled == .reference and resolution.fulfilled.reference == .far and
            resolution.fulfilled.reference.far.import_position.int() < engine.Node.REDEEMED_TOKEN_BASE)
        {
            const token = self.node.enrollForeign(peer_id, .{ .far = resolution.fulfilled.reference.far }) catch |err| {
                return .{ .broken = @errorName(err) };
            };
            return .{ .fulfilled = .{ .reference = token } };
        }
        return resolution;
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
    fn queueCompletion(self: *Host, vow_id: u64, resolution: actors.Resolution) void {
        switch (resolution) {
            .fulfilled => |value| {
                const cloned = model.cloneArgument(self.allocator, value) catch {
                    self.actions.pushReserved(.{ .failed = .{ .vow_id = vow_id, .message = "" } });
                    return;
                };
                self.actions.pushReserved(.{ .settled = .{ .vow_id = vow_id, .value = cloned } });
            },
            .broken => |message| {
                const owned: []const u8 = self.allocator.dupe(u8, message) catch "";
                self.actions.pushReserved(.{ .failed = .{ .vow_id = vow_id, .message = owned } });
            },
            // Unreachable by construction — the host claims every inbound
            // give before the vat can settle a vow with it (auto-redeem) —
            // but a defensive break beats a crash if that invariant moves.
            .give => {
                const owned: []const u8 = self.allocator.dupe(u8, "raw handoff reached a settle listener") catch "";
                self.actions.pushReserved(.{ .failed = .{ .vow_id = vow_id, .message = owned } });
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
                if (entry.value_ptr.*.peer_id != peer_id) continue;
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

    const RoutedSend = struct { session: *HostSession, target: actors.Ref };

    /// Resolve a send's target to the session and vat reference it rides: a
    /// near export to its local actor on `session`, a far reference through the
    /// node's routing (a token to its exporter session with the real
    /// reference swapped in). Fails closed when a token's exporter is gone.
    fn routeSend(self: *Host, session: *HostSession, target: model.Reference, args: []const model.Argument) !RoutedSend {
        self.assertOwner();
        try checkLive(session);
        switch (target) {
            .near => |near| {
                const ref = session.served.refForExport(near.export_position.int()) orelse return actors.Error.NoSuchActor;
                return .{ .session = session, .target = ref };
            },
            .far => {
                const routed = self.node.routeReference(session.peer_id, target) orelse return HostError.TokenRetired;
                const routed_conn = self.sessions.get(routed.peer_id) orelse return HostError.TokenRetired;
                try checkLive(routed_conn);
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
        self.assertOwner();
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        const session = self.sessions.get(row.peer_id) orelse return HostError.NoSuchVow;
        try checkLive(session);
        const source = switch (row.vow) {
            .far => |answer| answer,
            // A local vow has no wire answer to project against.
            .local => return vocab.Error.NotPipelineable,
        };
        const peer = session.served.peer;
        const answer = model.AnswerPosition.from(peer.allocateAnswer());
        const receiver: model.Reference = .{ .promise = .{ .answer_position = source } };
        switch (projection) {
            .index => |index| try peer.sendCopying(.{ .index = .{ .receiver = receiver, .index = index, .answer = answer } }),
            .untag => |tag| try peer.sendCopying(.{ .untag = .{ .receiver = receiver, .tag = tag, .answer = answer } }),
            .get => |field| try peer.sendCopying(.{ .get = .{ .receiver = receiver, .field = field, .answer = answer } }),
        }
        const id = try self.mintVow(session, .{ .far = answer }, .plain);
        try host_pump.dirtyThenPump(self, session.peer_id);
        return id;
    }

    /// Test seam: session-tagged embedder FIFO dedupe (flush/close).
    pub fn testingQueueUniqueSessionAction(self: *Host, comptime tag: host_pump.UniqueSessionActionTag, peer_id: engine.PeerId) !void {
        try host_pump.testingQueueUniqueSessionAction(self, tag, peer_id);
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
                    event.bytes(),
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
        const view_res = try engine.events.resolutionFromResolverCallback(deliver.args);
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
            const peer = session.served.peer;
            if (peer.session_state.pendingEnlivenSwissnum(bridge.answer)) |swissnum| {
                if (resolution == .fulfilled and resolution.fulfilled == .reference and resolution.fulfilled.reference == .far) {
                    // The far is POD; `recordEnlivenment` caches it and clears
                    // the in-flight marker. It only errors on a non-far/broken
                    // outcome, which a `.far` fulfillment never is.
                    _ = engine.sturdyref.recordEnlivenment(peer.allocator, &peer.session_state, swissnum, .{
                        .fulfilled = .{ .far = resolution.fulfilled.reference.far },
                    }) catch unreachable;
                } else {
                    peer.finishPendingEnliven(swissnum);
                }
            }
        }
        host.fireVow(vow_id, resolution);
    }
};
