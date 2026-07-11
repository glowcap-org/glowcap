//! The sans-io byte-fed multi-connection host core (ADR-0072), under the
//! `driver_core` I/O ban. A `Host` owns one `engine.Node` (identity, shared
//! gift registry, routing, the redeem serve step) and mints byte-fed
//! connections (`HostConnection`) whose peers are node-registered, so
//! everything the node decides — where a token routes, which exporter a give
//! withdraws from, when a served reply becomes a signed give — happens under
//! every connection the host holds, with no socket in sight. The embedder owns
//! the loop, the sockets, and the entropy: it feeds inbound bytes with `feed`
//! (a whole frame), `feedBytes` (a raw stream the core delimits), or `pumped`
//! (a transport that applied bytes to the peer itself), drains outbound frames
//! with `HostConnection.takeOutbound`, and answers the host's action queue
//! (`nextAction`) — dial requests, flush notices, gift-id entropy requests —
//! with `exporterDialed` / `dialFailed` / `provideGiftId`. Settlements ride
//! the same queue: a vow with no in-process listener settles as an owned
//! `settled`/`failed` completion the embedder routes by vow id, so one drain
//! hears every outcome. An in-process Zig consumer may instead register a
//! borrowed one-shot listener with `vowOn`, which keeps that vow's settlement
//! zero-copy and off the queue. The `driver.BlockingHost` is exactly such an
//! embedder: a socket loop over this core; the C ABI's `libpancake_driver` is
//! another.
//!
//! One thread drives one host. The node tables, the connection map, the vow
//! map, and the crossed-hellos table are unsynchronized by contract, which is
//! why `CrossedHellos` carries no lock.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const served_mod = @import("served.zig");
const vocab = @import("vocab.zig");
const Served = served_mod.Served;

const crypto = foundation.crypto;

/// The typed refusals the byte-fed host adds over the shared driver vocabulary.
pub const HostError = error{
    /// The connection lost the crossed-hellos tiebreak (ADR-0030) and is
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
    /// A host vow id names no live row: never minted, or its connection was
    /// released.
    NoSuchVow,
    /// A send argument is a capability foreign to the connection the send
    /// rides, which would mis-encode the reference for that partner. The send
    /// is refused whole.
    ForeignArgument,
    /// The target token's exporter connection is gone; the send is dropped,
    /// not mis-sent (the node's fail-closed contract).
    TokenRetired,
    /// `gcRelease` was given an id below the node's token range; only a
    /// fetched capability's token resolves to a wire import to release.
    NotAToken,
    /// `setSelfDesignator` was given a designator longer than the retained
    /// 64-byte buffer.
    DesignatorTooLong,
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

/// The served-reply interceptor body every host connection shares: offer a
/// fulfilled far capability to the node, which claims it when its recorded
/// home is another connection (the reply becomes a signed give; the node asks
/// for gift-id entropy and originates it). A claimed reply returns `.claimed`
/// — the vat resolves nothing — and anything else passes through unchanged for
/// the vat to resolve as-is. Same-home token lowering is not this seam's job:
/// the outbound chokepoint (`Peer.send`, ADR-0069) rewrites a node-local token
/// to its wire reference. The actions the claim queued pump at the enclosing
/// verb's unwind.
fn interceptFulfilled(
    node: *engine.Node,
    conn_id: engine.ConnId,
    answer: model.AnswerPosition,
    fulfilled: model.Argument,
) !actors.InterceptOutcome {
    if (fulfilled != .reference or fulfilled.reference != .far) return .{ .resolve = fulfilled };
    const far_id = fulfilled.reference.far.import_position.int();
    if (try node.interceptFulfilledRef(conn_id, answer.int(), far_id)) return .claimed;
    return .{ .resolve = fulfilled };
}

/// Crossed-hellos tiebreak state (ADR-0030): the designator-keyed
/// outbound-dial table, unlocked because one thread drives one host by
/// contract. `openDialed` registers the outbound before its hello moves; an
/// accepted connection's inbound start-session is compared against it, and the
/// host condemns the losing connection immediately rather than deferring a
/// flag to a later pump. Public for its unit tests; embedders never touch it —
/// the host runs the tiebreak itself.
pub const CrossedHellos = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        partner_designator: []const u8,
        our_pid: foundation.PeerId,
    };

    /// The tiebreak verdict for a crossed inbound: the side whose identifier
    /// is *not* lower aborts its inbound session, so both peers keep the
    /// session the higher-keyed peer opened.
    pub const Verdict = struct { abort_inbound: bool };

    pub fn registerOutbound(self: *CrossedHellos, allocator: std.mem.Allocator, partner_designator: []const u8, our_pid: foundation.PeerId) !void {
        const owned = try allocator.dupe(u8, partner_designator);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .partner_designator = owned, .our_pid = our_pid });
    }

    /// Compare an inbound start-session against the registered outbound dials;
    /// null when no dial to `partner_designator` is outstanding (no collision).
    pub fn checkInbound(self: *const CrossedHellos, partner_designator: []const u8, inbound_partner_pid: foundation.PeerId) ?Verdict {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) {
                const order = std.mem.order(u8, &entry.our_pid.bytes, &inbound_partner_pid.bytes);
                return .{ .abort_inbound = order != .lt };
            }
        }
        return null;
    }

    /// Remove exactly one entry for `partner_designator`: one row is appended
    /// per dial, so a sweep would drop a sibling dial's still-live entry.
    pub fn unregister(self: *CrossedHellos, allocator: std.mem.Allocator, partner_designator: []const u8) void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) {
                allocator.free(entry.partner_designator);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *CrossedHellos, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.partner_designator);
        self.entries.deinit(allocator);
    }
};

/// What the embedder must do next. `nextAction` pops borrowed: the action's
/// byte views (`dial`'s locator and its parsed pieces, a completion's value)
/// are host-owned and stay valid until the next `nextAction` call, which
/// frees them — the same contract `engine.Node.nextAction` carries.
/// `takeAction` pops owned instead: the caller adopts the payload and frees
/// it with `Host.freeAction` (or moves it into a durable owner first).
pub const HostAction = union(enum) {
    /// A `dial` action's owned payload. The URI's parsed pieces ride
    /// alongside the locator so the embedder never re-parses on the redeem
    /// path: the transport tag, the designator, and the locator's
    /// `direct-addresses` hint — each empty when the locator does not parse
    /// as an ocapn URI (a verbatim exporter-location override may not) or
    /// when the hint is absent.
    pub const Dial = struct {
        ticket: engine.Node.PendingId,
        locator: []const u8,
        transport: []const u8 = &.{},
        designator: []const u8 = &.{},
        direct_addresses_hint: []const u8 = &.{},
    };

    /// Dial the exporter at `locator` (a full `ocapn://…` URI) with this
    /// host's identity: `openDialed(locator)`, drive the keyed session open by
    /// moving its bytes, then report `exporterDialed(ticket, conn)` — or
    /// `dialFailed(ticket, reason)` if any step refuses.
    dial: Dial,
    /// Outbound frames may be ready on this connection: drain
    /// `HostConnection.takeOutbound` until empty and write them.
    flush: engine.ConnId,
    /// The host condemned this connection mid-pump (its local turns amplified
    /// past `Options.local_turn_budget`): flush its queued outbound — the
    /// typed `resource_exhausted` abort — then tear its transport down and
    /// release the connection. Without this action a byte-fed embedder has no
    /// way to learn a connection died inside the pump; `condemned` alone only
    /// refuses future verbs.
    close: engine.ConnId,
    /// Draw 32 bytes of gift-id entropy and feed them back through
    /// `provideGiftId(ticket, bytes)`. Entropy is a host effect like dialing;
    /// the sans-io host never generates it.
    need_gift_id: struct { ticket: u64 },
    /// A host vow with no in-process listener settled fulfilled: `value` is a
    /// deep clone the host owns, valid until the next `nextAction` call,
    /// which frees it — the dial payload's exact lifetime. Route it to
    /// whatever awaits the vow.
    settled: struct { vow_id: u64, value: model.Argument },
    /// A host vow with no in-process listener settled broken: `message` is
    /// host-owned with the same until-next-`nextAction` lifetime (empty when
    /// the break carried no reason, or when retaining one failed).
    failed: struct { vow_id: u64, message: []const u8 },
};

/// One byte-fed connection: a node-registered peer under a `Served` serve
/// core, minted by `Host.openDialed` / `openAccepted` and freed by
/// `Host.releaseConn`. The embedder writes what `takeOutbound` drains and
/// feeds what it reads through `Host.feed` (never the `Served` directly, so
/// the host's action pump always runs).
pub const HostConnection = struct {
    host: *Host,
    conn_id: engine.ConnId,
    served: Served,
    role: Role,
    /// Set when this connection lost the crossed-hellos tiebreak: its typed
    /// abort is queued, and every verb refuses `ConnectionCondemned`.
    condemned: bool = false,

    /// Which half of the handshake this connection is, carrying the one datum
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
    pub fn takeOutbound(self: *HostConnection) HostError!?foundation.Frame {
        try self.host.refuseReentry();
        return self.served.takeOutbound();
    }

    /// Whether the keyed handshake has completed and the session is open.
    pub fn sessionOpen(self: *const HostConnection) bool {
        return self.served.peer.sessionIsOpen();
    }
};

/// One identity, one node, many byte-fed connections — the sans-io host core.
/// The node serve step decides, and this host executes each action either
/// directly (settle and fail fire the recipient vat's listener through
/// `Vat.settleFar`) or by queueing it for the embedder (dials and gift-id
/// draws are host effects). Free with `deinit`, which breaks every
/// still-parked vow before the shells go.
pub const Host = struct {
    allocator: std.mem.Allocator,
    node: engine.Node,
    opts: Options,
    conns: std.AutoHashMapUnmanaged(engine.ConnId, *HostConnection) = .{},
    /// Crossed-hellos tiebreak state (ADR-0030): `openDialed` registers the
    /// outbound before its hello moves; accepted connections compare inbound
    /// start-sessions against it.
    hellos: CrossedHellos = .{},
    /// The host's own dialable designator, signed into every dial's
    /// start-session — what a partner's crossed-hellos table looks this host
    /// up by, and what its gives can name. Empty for a host that never
    /// listens, which signs the shared unreachable-client placeholder.
    self_designator: [64]u8 = undefined,
    self_designator_len: usize = 0,
    /// The embedder-facing action FIFO; `nextAction` drains it.
    actions: std.ArrayListUnmanaged(HostAction) = .empty,
    action_head: usize = 0,
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
    /// Connections with enqueued-but-unencoded outbound (a nested verb's send,
    /// a settle listener's reply). The top-level verb's unwind drives each one
    /// (`Served.driveFed`) and queues its flush action.
    pending_flush: std.ArrayListUnmanaged(engine.ConnId) = .empty,
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

    pub const Options = struct {
        /// The session's maximum admissible frame, applied to every minted peer.
        frame_cap: usize = 1 << 16,
        /// Verify the partner's `op:start-session` signature — the secure
        /// default a real peer keeps.
        verify_partner: bool = true,
        /// The wire grammar every minted connection negotiates in. Defaults to
        /// Syrup, the Goblins-interop target; both ends of a connection must
        /// carry the same codec (`op:start-session` carries no codec operand,
        /// so agreement is the embedder's, exactly as on the raw peer tier).
        codec: model.CodecId = .syrup,
        /// Local-turn amplification cap per drive, applied to every minted
        /// connection's serve core (see `Served.local_turn_budget`). A loop
        /// embedder sets it so one message that amplifies without bound cannot
        /// stall the thread serving every connection: the flooded connection
        /// is condemned with a `resource_exhausted` abort and a `close` action
        /// names it for the embedder. Null (the default) drives unbounded, the
        /// blocking one-connection-per-thread posture.
        local_turn_budget: ?usize = null,
    };

    /// One live host vow. The row holds the vow's single vat listener slot
    /// from mint (`fire`), so settlement always retires the row. An
    /// in-process listener chains through `inner`, set once by `vowOn`, and
    /// hears the resolution borrowed (zero-copy); a vow with no listener
    /// settles as a queued `settled`/`failed` completion instead, so an
    /// embedder that only drains the action queue still hears every outcome.
    const VowRow = struct {
        host: *Host,
        conn_id: engine.ConnId,
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

    /// Compact the action FIFO's dead prefix once it grows past this many
    /// rows, so an embedder that queues new work before ever draining to
    /// empty cannot grow the list without bound.
    const action_compact_threshold = 32;

    /// A host bound to the caller-supplied identity `seed` (drawn at the
    /// embedder's entropy boundary; the sans-io host never generates it). The
    /// node reuses the identity for every connection, so an exporter verifies
    /// a handoff signature against the one key the gifter named.
    pub fn init(allocator: std.mem.Allocator, seed: [crypto.SEED_BYTES]u8, opts: Options) Host {
        return .{
            .allocator = allocator,
            .node = engine.Node.init(allocator, seed),
            .opts = opts,
        };
    }

    /// Tear down every connection shell, the action queue, the vow map, the
    /// crossed-hellos table, and the node. Every still-parked far vow fires
    /// broken first, so a host-owned enliven bridge (which frees itself only
    /// when it fires) never strands and every in-process listener hears an
    /// outcome; the completions those breaks queue are freed here with the
    /// rest of the undrained queue.
    pub fn deinit(self: *Host) void {
        // The break fires listeners that may call nested verbs; the latch
        // makes them enqueue only, and everything they enqueue frees below.
        self.in_callback = true;
        var break_it = self.conns.valueIterator();
        while (break_it.next()) |conn| {
            conn.*.served.vat.breakFarVows(conn.*.served.closeReason("host released"));
        }
        var free_it = self.conns.valueIterator();
        while (free_it.next()) |conn| {
            conn.*.served.deinit();
            switch (conn.*.role) {
                .dialed => |designator| self.allocator.free(designator),
                .accepted => {},
            }
            self.allocator.destroy(conn.*);
        }
        self.conns.deinit(self.allocator);
        self.hellos.deinit(self.allocator);
        if (self.last_action) |last| freeHostAction(self.allocator, last);
        for (self.actions.items[self.action_head..]) |action| freeHostAction(self.allocator, action);
        self.actions.deinit(self.allocator);
        // The far rows retired themselves through the break above; what
        // remains is never-fired local rows, freed here with the vats gone.
        var vow_it = self.vows.valueIterator();
        while (vow_it.next()) |row| self.allocator.destroy(row.*);
        self.vows.deinit(self.allocator);
        self.pending_flush.deinit(self.allocator);
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

    /// Whether a self designator has been recorded (`setSelfDesignator`), so
    /// a listening embedder records its first bound address exactly once
    /// without reading the retained buffer's fields.
    pub fn hasSelfDesignator(self: *const Host) bool {
        return self.self_designator_len != 0;
    }

    fn selfDesignator(self: *const Host) []const u8 {
        if (self.self_designator_len == 0) return vocab.unreachable_client_designator;
        return self.self_designator[0..self.self_designator_len];
    }

    // ── Connection lifecycle ─────────────────────────────────────────────────

    /// Mint the dialing half of a connection to the peer `locator_uri` names:
    /// register the outbound with the crossed-hellos table, register the conn
    /// on the node, and sign and encode the keyed `op:start-session` under the
    /// host identity, naming this host's own designator. The hello is encoded
    /// before this returns; the embedder drains it with `takeOutbound` (a
    /// flush action is queued) and drives the handshake byte-fed.
    pub fn openDialed(self: *Host, locator_uri: []const u8) !*HostConnection {
        const locator = try model.uri.parsePeer(self.allocator, locator_uri);
        defer model.freePeerLocator(self.allocator, locator);
        return self.openDialedLocator(locator);
    }

    /// `openDialed` for a caller already holding a parsed locator (the
    /// `driver.BlockingHost` dials by `model.PeerLocator`); the locator is
    /// borrowed for the call.
    pub fn openDialedLocator(self: *Host, locator: model.PeerLocator) !*HostConnection {
        try self.refuseReentry();
        // Register the outbound before any bytes move: a crossed inbound
        // start-session from the same partner must find this dial (ADR-0030).
        const our_pid = crypto.derivePublicIdentifier(self.node.secretKey().publicKey());
        try self.hellos.registerOutbound(self.allocator, locator.designator, our_pid);
        errdefer self.hellos.unregister(self.allocator, locator.designator);
        const partner_designator = try self.allocator.dupe(u8, locator.designator);
        errdefer self.allocator.free(partner_designator);

        const conn = try self.mint(.{ .dialed = partner_designator });
        // Dialed-specific pin before hello; on failure unwind the mint. The
        // shared open tail's `errdefer failOpen` covers hello failures.
        if (vocab.designatorSchemeForTransport(locator.transport) == .key) {
            const expected = crypto.PeerKey.fromDesignator(locator.designator) orelse {
                self.failOpen(conn);
                return error.InvalidAddress;
            };
            conn.served.peer.expectPartnerKey(expected);
        }

        return self.helloAndEnroll(conn, locator.transport, self.selfDesignator());
    }

    /// Mint the accepting half of a connection the embedder's own listener
    /// produced: register the conn on the node and sign the keyed
    /// `op:start-session` under the host identity, naming the listener's own
    /// `transport`/`designator` — the address a partner can actually dial, and
    /// the locator record a give made on this host names as the exporter
    /// location.
    pub fn openAccepted(self: *Host, transport: []const u8, designator: []const u8) !*HostConnection {
        try self.refuseReentry();
        return self.helloAndEnroll(try self.mint(.accepted), transport, designator);
    }

    /// `openAccepted` over a peer the embedder owns and pins at a stable
    /// address: identical wiring — the keyed responder hello signed under the
    /// host identity, crossed-hellos registration, enrollment — minus
    /// ownership. The node routes through the adopted peer but never frees
    /// it: the embedder frees the peer itself, only after `releaseConn` has
    /// retired the connection. This is the completion loop's adoption seam —
    /// its fixed slots hold each peer inline, so the loop keeps the peer and
    /// the host serves it.
    pub fn openAcceptedOver(self: *Host, peer: *engine.Peer, transport: []const u8, designator: []const u8) !*HostConnection {
        try self.refuseReentry();
        return self.helloAndEnroll(try self.mintOver(peer, .accepted), transport, designator);
    }

    /// The shared open tail: sign the keyed hello under the host identity,
    /// enroll, queue the flush, pump. `errdefer failOpen` unwinds a failed hello.
    fn helloAndEnroll(self: *Host, conn: *HostConnection, transport: []const u8, designator: []const u8) !*HostConnection {
        errdefer self.failOpen(conn);
        try conn.served.peer.sendKeyedStartSession(.v1_0, .{
            .transport = transport,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        }, self.node.secretKey());
        self.enroll(conn);
        try self.markDirty(conn.conn_id);
        try self.finishVerb();
        return conn;
    }

    /// Release one connection: break its still-parked far vows (their
    /// resolutions can never arrive), retire it from the node — whose
    /// fail-closed sweep queues the fail actions that break *sibling*
    /// connections' answers — and free the shell. The sibling fails fire
    /// inside this call, through the same pump every verb ends with.
    pub fn releaseConn(self: *Host, conn: *HostConnection) !void {
        try self.refuseReentry();
        self.in_callback = true;
        conn.served.vat.breakFarVows(conn.served.closeReason("connection released"));
        self.in_callback = false;

        if (conn.role == .dialed) self.hellos.unregister(self.allocator, conn.role.dialed);
        std.debug.assert(self.conns.remove(conn.conn_id));
        const conn_id = conn.conn_id;
        self.dropVowRows(conn_id);
        conn.served.deinit();
        switch (conn.role) {
            .dialed => |designator| self.allocator.free(designator),
            .accepted => {},
        }
        self.allocator.destroy(conn);
        self.node.removeConn(conn_id);
        try self.finishVerb();
    }

    /// One node-registered connection shell over a node-owned peer: mint the
    /// peer, apply the host posture, and allocate the `HostConnection`. The
    /// map slot is reserved here so `enroll` cannot fail; a caller that fails
    /// after this unwinds with `failOpen`.
    fn mint(self: *Host, role: HostConnection.Role) !*HostConnection {
        try self.conns.ensureUnusedCapacity(self.allocator, 1);
        const conn_id = try self.node.registerConn(self.negotiatingOptions());
        errdefer self.node.removeConn(conn_id);
        return self.mintShell(self.node.peer(conn_id).?, conn_id, role);
    }

    /// `mint` over a peer the embedder already owns and pins at a stable
    /// address (`engine.Node.registerConnOver`): the node routes through it
    /// and the host serves it, but neither ever frees it — `releaseConn` and
    /// `deinit` only unregister the slot, and the embedder frees the peer
    /// after `releaseConn`. This is how a peer-owning loop, whose fixed slots
    /// hold each peer inline, puts its connections under one host.
    fn mintOver(self: *Host, peer: *engine.Peer, role: HostConnection.Role) !*HostConnection {
        try self.conns.ensureUnusedCapacity(self.allocator, 1);
        const conn_id = try self.node.registerConnOver(peer);
        errdefer self.node.removeConn(conn_id);
        return self.mintShell(peer, conn_id, role);
    }

    /// The host posture imposed on every minted or adopted peer.
    fn negotiatingOptions(self: *const Host) engine.Peer.NegotiatingOptions {
        return .{
            .codec = self.opts.codec,
            .verify_partner_handshake = self.opts.verify_partner,
            .limits = .{ .max_frame_bytes = self.opts.frame_cap },
        };
    }

    /// The shared mint tail: impose the host's peer posture through the
    /// engine's `reposture` verb (asserted negotiating, no bytes moved) and
    /// allocate the shell, for minted and adopted peers alike. Owned mints
    /// already received the same knobs at `registerConn`; `reposture` is
    /// idempotent for that path and the only imposition for an adopted peer.
    fn mintShell(self: *Host, peer: *engine.Peer, conn_id: engine.ConnId, role: HostConnection.Role) !*HostConnection {
        peer.reposture(self.negotiatingOptions());

        const conn = try self.allocator.create(HostConnection);
        conn.* = .{
            .host = self,
            .conn_id = conn_id,
            .served = Served.over(self.allocator, peer),
            .role = role,
        };
        conn.served.local_turn_budget = self.opts.local_turn_budget;
        return conn;
    }

    /// Wire a minted connection into the host: the before-serve hook offers
    /// every inbound resolve to the node before the vat sees it (and
    /// auto-redeems gives), and the resolve interceptor turns a served reply
    /// that fulfills with a foreign-homed capability into a signed give.
    /// Infallible: `mint` reserved the map slot.
    fn enroll(self: *Host, conn: *HostConnection) void {
        conn.served.serve_options = .{ .hook_ctx = conn, .before_serve = hostBeforeServe };
        conn.served.vat.setResolveInterceptor(.{ .ctx = conn, .func = hostResolveInterceptor });
        self.conns.putAssumeCapacity(conn.conn_id, conn);
    }

    /// Unwind a failed open: retire the conn id (running the node's
    /// fail-closed sweep) and free the shell. The dialed designator, when the
    /// caller already duped it, is the caller's own errdefer.
    fn failOpen(self: *Host, conn: *HostConnection) void {
        // tolerant: enrolled only when the failure came after `enroll`.
        _ = self.conns.remove(conn.conn_id);
        const conn_id = conn.conn_id;
        conn.served.deinit();
        self.allocator.destroy(conn);
        self.node.removeConn(conn_id);
    }

    // ── The byte pump ────────────────────────────────────────────────────────

    /// Feed one inbound frame the embedder read from its own transport
    /// (borrowed for the call): dispatch what it surfaces into the vat — the
    /// before-serve hook claims withdraw resolves and auto-redeems gives, and
    /// settle listeners fire inside this call — then pump the node actions the
    /// dispatch queued and encode every touched connection's outbound. On a
    /// dispatch failure the peer projects a typed `op:abort` onto the outbound
    /// queue; the flush action is still queued so the embedder writes it
    /// before closing the transport.
    pub fn feed(self: *Host, conn: *HostConnection, frame: foundation.FrameView) !void {
        try self.enterCallback(conn);
        {
            defer self.leaveCallback();
            conn.served.feedBorrowed(frame) catch |err| return self.failDispatch(conn.conn_id, err);
        }
        try self.finishDispatch(conn);
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
    pub fn feedBytes(self: *Host, conn: *HostConnection, bytes: []const u8) !usize {
        try self.enterCallback(conn);
        const was_open = conn.served.peer.sessionIsOpen();
        var consumed: usize = 0;
        {
            defer self.leaveCallback();
            while (consumed < bytes.len) {
                const outcome = conn.served.peer.recvStreamPrefix(bytes[consumed..]) catch |err|
                    return self.failDispatch(conn.conn_id, err);
                switch (outcome) {
                    .incomplete => break,
                    .consumed => |n| {
                        consumed += n;
                        // Serve the frame's events before delimiting the next
                        // frame, so ordering matches the whole-frame path.
                        conn.served.driveFed() catch |err|
                            return self.failDispatch(conn.conn_id, err);
                        // Stop at the session-open transition: the frames
                        // behind the hello wait for the embedder's post-open
                        // setup and ride the tail into the next call.
                        if (!was_open and conn.served.peer.sessionIsOpen()) break;
                    },
                }
            }
        }
        try self.finishDispatch(conn);
        return consumed;
    }

    /// Serve what a peer-coupled transport already fed this connection's
    /// peer: dispatch the surfaced events into the vat (the before-serve hook
    /// and settle listeners fire inside this call), then run the same pump
    /// `feed` ends with. `feed`/`feedBytes` are for embedders that hand the
    /// core the bytes; an embedder whose transport recvs into the peer
    /// directly (`driver.BlockingHost`'s `net.Connection`) calls this
    /// after each pump instead.
    pub fn pumped(self: *Host, conn: *HostConnection) !void {
        try self.enterCallback(conn);
        {
            defer self.leaveCallback();
            conn.served.driveFed() catch |err| return self.failDispatch(conn.conn_id, err);
        }
        try self.finishDispatch(conn);
    }

    /// Serve one already-polled event under the host — the per-event verb for
    /// an embedder loop that polls its connections' peers itself (a
    /// completion loop's serve hook). Structurally `pumped` for one event:
    /// the crossed-hellos hook and the resolve interceptor run, settle
    /// listeners fire under the callback latch, and the node pump runs at the
    /// unwind.
    ///
    /// The batch subtlety: the unwind's pump (`drainWork` → `Served.driveFed`
    /// → `drainEvents`) polls and serves every event *still queued* on this
    /// connection's peer, so a loop's per-event hook typically fires once per
    /// inbound batch — its own `pollEvent` loop then finds null. That is
    /// correct, not lossy: every event is served through the one
    /// `Served.serveEvent` spine either way.
    ///
    /// This verb, not a raw `conn.served.serveEvent`, is the embedder's
    /// entry: the raw call would run settle listeners un-latched (a listener's
    /// nested verb could re-enter the host mid-dispatch) and would skip the
    /// node pump that turns a served reply into a give.
    pub fn serveEvent(self: *Host, conn: *HostConnection, event: *engine.Event) !void {
        try self.enterCallback(conn);
        {
            defer self.leaveCallback();
            conn.served.serveEvent(event) catch |err| return self.failDispatch(conn.conn_id, err);
        }
        try self.finishDispatch(conn);
    }

    /// Pop the next embedder action, borrowed: the previous action's byte
    /// views are freed here, so a popped action is valid until the next call.
    /// Null when no action is pending. Top-level: refused under the callback
    /// latch, where the enclosing verb is still queueing and freeing the
    /// previous action would dangle views the embedder still holds.
    pub fn nextAction(self: *Host) HostError!?HostAction {
        try self.refuseReentry();
        if (self.last_action) |last| {
            freeHostAction(self.allocator, last);
            self.last_action = null;
        }
        const action = self.popAction() orelse return null;
        self.last_action = action;
        return action;
    }

    /// Pop the next embedder action, owned: the caller adopts the payload and
    /// frees it with `freeAction` — or moves it into a durable owner first,
    /// which is how `driver.BlockingHost` parks a completion with zero
    /// copies. Leaves the `nextAction` borrow untouched, so the two pops
    /// compose. Refused under the latch like `nextAction`.
    pub fn takeAction(self: *Host) HostError!?HostAction {
        try self.refuseReentry();
        return self.popAction();
    }

    /// Free an action `takeAction` transferred, once its payload is consumed
    /// (a moved-out payload is the new owner's to free instead).
    pub fn freeAction(self: *Host, action: HostAction) void {
        freeHostAction(self.allocator, action);
    }

    /// The one FIFO pop under both action verbs: compact the dead prefix past
    /// the threshold and hand out the front row, owning nothing.
    fn popAction(self: *Host) ?HostAction {
        if (self.action_head >= self.actions.items.len) {
            self.actions.clearRetainingCapacity();
            self.action_head = 0;
            return null;
        }
        if (self.action_head >= action_compact_threshold) {
            const remaining = self.actions.items.len - self.action_head;
            std.mem.copyForwards(HostAction, self.actions.items[0..remaining], self.actions.items[self.action_head..]);
            self.actions.items.len = remaining;
            self.action_head = 0;
        }
        const action = self.actions.items[self.action_head];
        self.action_head += 1;
        return action;
    }

    /// Report a `dial` action's success: `conn` is an `openDialed` against
    /// that action's locator, driven to an open session. The node withdraws
    /// every give waiting on the ticket; the withdraws and their flushes pump
    /// inside this call. A stale ticket is a no-op.
    pub fn exporterDialed(self: *Host, ticket: engine.Node.PendingId, conn: *HostConnection) !void {
        try self.refuseReentry();
        try checkLive(conn);
        try self.node.exporterDialed(ticket, conn.conn_id);
        try self.finishVerb();
    }

    /// Report a `dial` action's failure: every redeem waiting on the ticket
    /// breaks with `reason`, firing its settle listener inside this call. A
    /// stale ticket is a no-op.
    pub fn dialFailed(self: *Host, ticket: engine.Node.PendingId, reason: []const u8) !void {
        try self.refuseReentry();
        try self.node.dialFailed(ticket, reason);
        try self.finishVerb();
    }

    /// Answer a `need_gift_id` action with 32 host-drawn bytes: the node
    /// originates the claimed handoff and this call flushes its legs,
    /// exporter first. A stale ticket is a no-op.
    pub fn provideGiftId(self: *Host, ticket: u64, gift_id: []const u8) !void {
        try self.refuseReentry();
        try self.node.provideGiftId(ticket, gift_id);
        try self.finishVerb();
    }

    // ── Application verbs ────────────────────────────────────────────────────

    /// Eventual-send `msg` to `target` and mint a host vow for the answer,
    /// observed with `vowOn`. A near target (an export this host bound) runs
    /// in-process; a far target routes through the node, so a redeemed or
    /// fetched token rides its exporter connection transparently. A far
    /// argument foreign to the routed connection is refused whole
    /// (`ForeignArgument`) rather than mis-encoded.
    pub fn send(self: *Host, conn: *HostConnection, target: model.Reference, msg: actors.Message) !u64 {
        const routed = try self.routeSend(conn, target, msg.args);
        const vow = try routed.conn.served.send(routed.target, msg);
        const id = try self.mintVow(routed.conn, vow, .plain);
        try self.markDirty(routed.conn.conn_id);
        try self.finishVerb();
        return id;
    }

    /// Fire-and-forget eventual-send: `send` with no answer and no vow.
    pub fn tell(self: *Host, conn: *HostConnection, target: model.Reference, msg: actors.Message) !void {
        const routed = try self.routeSend(conn, target, msg.args);
        try routed.conn.served.tell(routed.target, msg);
        try self.markDirty(routed.conn.conn_id);
        try self.finishVerb();
    }

    /// Fetch the partner capability published as `name`, minting a host vow
    /// for the outcome: observe it in-process with `vowOn`, or drain its
    /// `settled`/`failed` completion from the action queue. A fulfilled far
    /// capability settles *already enrolled* under a node-unique token
    /// (ADR-0069) — recorded before the outcome is dispatched, so a reply
    /// that immediately re-gifts it routes to the right exporter. Top-level:
    /// refused from inside a callback.
    pub fn fetch(self: *Host, conn: *HostConnection, name: []const u8) !u64 {
        try self.refuseReentry();
        try checkLive(conn);
        const vow = try conn.served.sendBootstrapFetch(name);
        const id = try self.mintVow(conn, vow, .fetch);
        try self.markDirty(conn.conn_id);
        try self.finishVerb();
        return id;
    }

    /// Enliven the sturdyref published behind `swissnum` (ADR-0012), minting
    /// a host vow for the live reference. A dedup-cache hit settles the vow
    /// before this returns — its completion is already on the action queue —
    /// and a fresh enliven rides bootstrap-fetch, the host recording the
    /// enlivenment itself when the resolution arrives, before the outcome is
    /// dispatched. Top-level: refused from inside a callback.
    pub fn enliven(self: *Host, conn: *HostConnection, swissnum: []const u8) !u64 {
        try self.refuseReentry();
        try checkLive(conn);
        const peer = conn.served.peer;
        try peer.importObject(engine.BOOTSTRAP_POSITION);
        // The core tracks no remote locator and never dials; the swissnum
        // alone identifies the cache row.
        const sturdy = model.SturdyRef{
            .peer = .{ .transport = "", .designator = "" },
            .swissnum = swissnum,
        };
        const start = try engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, sturdy);
        switch (start) {
            .cached => |reference| {
                // Already settled: queue the completion for a fresh id and
                // never build a row, so the id refuses `NoSuchVow` exactly
                // like any other settled vow.
                const id = self.next_vow;
                try self.queueHostAction(.{ .settled = .{ .vow_id = id, .value = .{ .reference = reference } } });
                self.next_vow += 1;
                try self.finishVerb();
                return id;
            },
            // An enliven already in flight holds the one listener slot on its
            // answer, so a concurrent duplicate is refused `AlreadyListening`
            // rather than parked where it could never fire.
            .in_flight => |answer| {
                const id = try self.mintEnlivenVow(conn, swissnum, answer);
                try self.finishVerb();
                return id;
            },
            .fresh => |prepared| {
                peer.sendPreparedFetch(prepared) catch |err| {
                    // The fresh enliven recorded an in-flight marker; clear it
                    // so a failed send does not strand the swissnum.
                    peer.finishPendingEnliven(swissnum);
                    return err;
                };
                const id = self.mintEnlivenVow(conn, swissnum, prepared.answer_position) catch |err| {
                    peer.finishPendingEnliven(swissnum);
                    return err;
                };
                try self.markDirty(conn.conn_id);
                try self.finishVerb();
                return id;
            },
        }
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
        const conn = self.conns.get(row.conn_id) orelse return HostError.NoSuchVow;
        try checkLive(conn);
        if (row.inner != null) return actors.Error.AlreadyListening;
        row.inner = listener;
    }

    /// The connection a live host vow is homed on, or null for a settled or
    /// unknown id — the read a blocking embedder anchors its wait on, without
    /// reaching into the vow map.
    pub fn vowConn(self: *const Host, vow_id: u64) ?engine.ConnId {
        const row = self.vows.get(vow_id) orelse return null;
        return row.conn_id;
    }

    /// Promise pipelining: eventual-send `msg` to a host vow before it
    /// resolves, minting a new vow for this call's own answer. A local vow has
    /// no wire answer to pipeline against (`NotPipelineable`).
    pub fn vowSend(self: *Host, vow_id: u64, msg: actors.Message) !u64 {
        self.assertOwner();
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        const conn = self.conns.get(row.conn_id) orelse return HostError.NoSuchVow;
        try checkLive(conn);
        const vow = try conn.served.sendToAnswer(row.vow, msg);
        const id = try self.mintVow(conn, vow, .plain);
        try self.markDirty(conn.conn_id);
        try self.finishVerb();
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

    /// Release `delta` references on the fetched capability `token` holds: the
    /// token resolves through the node to its home connection and real wire
    /// import, and the release rides that peer as `op:gc-exports`. A dead home
    /// is a no-op success — the session teardown already reclaimed the counts.
    pub fn gcRelease(self: *Host, token: u64, delta: u64) !void {
        self.assertOwner();
        if (token < engine.Node.REDEEMED_TOKEN_BASE) return HostError.NotAToken;
        const routed = self.node.routeToken(token) orelse return;
        const conn = self.conns.get(routed.conn_id) orelse return;
        try checkLive(conn);
        const positions = [_]u64{routed.target.far.import_position.int()};
        const deltas = [_]u64{delta};
        try conn.served.peer.sendCopying(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
        try self.markDirty(conn.conn_id);
        try self.finishVerb();
    }

    /// Break every far vow still parked on `conn`'s vat, firing each listener
    /// inside this call with the partner's retained abort diagnostic when one
    /// arrived, else `message`. The embedder calls this when its transport
    /// reports the connection gone.
    pub fn breakFarVows(self: *Host, conn: *HostConnection, message: []const u8) !void {
        try self.refuseReentry();
        try checkLive(conn);
        self.in_callback = true;
        conn.served.vat.breakFarVows(conn.served.closeReason(message));
        self.in_callback = false;
        try self.finishVerb();
    }

    /// Record the exporter locator to embed in gives whose exporter is `conn`
    /// (see `engine.Node.setExporterLocation`); `null` clears the override back
    /// to the session record. The node encodes the locator to canonical Syrup
    /// record bytes — a URI string is unrepresentable here.
    pub fn setExporterLocation(self: *Host, conn: *HostConnection, location: ?model.PeerLocator) !void {
        self.assertOwner();
        try checkLive(conn);
        try self.node.setExporterLocation(conn.conn_id, location);
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

    fn refuseReentry(self: *Host) HostError!void {
        self.assertOwner();
        if (self.in_callback) return HostError.ReenteredHost;
    }

    fn checkLive(conn: *const HostConnection) HostError!void {
        if (conn.condemned) return HostError.ConnectionCondemned;
    }

    /// Shared inbound-dispatch latch: refuse reentry, refuse a condemned
    /// connection, then arm the callback latch. Pair with `leaveCallback`
    /// (defer) and `finishDispatch` (on success).
    fn enterCallback(self: *Host, conn: *HostConnection) !void {
        try self.refuseReentry();
        try checkLive(conn);
        self.in_callback = true;
    }

    fn leaveCallback(self: *Host) void {
        self.in_callback = false;
    }

    fn finishDispatch(self: *Host, conn: *HostConnection) !void {
        try self.markDirty(conn.conn_id);
        try self.finishVerb();
    }

    /// Mint the host row for a fresh vow and install its retire listener —
    /// the row is heap-boxed because its address is the listener's ctx and
    /// the map may rehash. The map slot and a completion's action-queue slot
    /// are both reserved before the listener goes in, so a registered fire
    /// always finds its row and always lands its completion.
    fn mintVow(self: *Host, conn: *HostConnection, vow: actors.Vow, kind: VowRow.Kind) !u64 {
        const row = try self.createVowRow(conn, vow, kind);
        errdefer self.allocator.destroy(row);
        // A fresh vow holds no listener and cannot have settled (nothing has
        // driven since the send), so `on` can only fail on OOM.
        try conn.served.vat.on(vow, .{ .ctx = row, .func = VowRow.fire });
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
    fn createVowRow(self: *Host, conn: *HostConnection, vow: actors.Vow, kind: VowRow.Kind) !*VowRow {
        const row = try self.allocator.create(VowRow);
        errdefer self.allocator.destroy(row);
        row.* = .{ .host = self, .conn_id = conn.conn_id, .id = self.next_vow, .vow = vow, .kind = kind };
        try self.vows.ensureUnusedCapacity(self.allocator, 1);
        try self.actions.ensureUnusedCapacity(self.allocator, self.vows.count() + 1);
        return row;
    }

    /// Mint the host vow behind a wire-riding enliven: the row (whose vat
    /// listener slot the bridge holds instead) plus the bridge that owns the
    /// swissnum copy and does the session bookkeeping before it settles the
    /// row.
    fn mintEnlivenVow(self: *Host, conn: *HostConnection, swissnum: []const u8, answer: model.AnswerPosition) !u64 {
        const owned = try self.allocator.dupe(u8, swissnum);
        errdefer self.allocator.free(owned);
        const bridge = try self.allocator.create(EnlivenBridge);
        errdefer self.allocator.destroy(bridge);
        const row = try self.createVowRow(conn, .{ .far = answer }, .plain);
        errdefer self.allocator.destroy(row);
        bridge.* = .{ .host = self, .conn_id = conn.conn_id, .swissnum = owned, .vow_id = row.id };
        try conn.served.vat.on(.{ .far = answer }, .{ .ctx = bridge, .func = EnlivenBridge.fire });
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
        const conn_id = row.conn_id;
        const id = row.id;
        std.debug.assert(self.vows.remove(id));
        self.allocator.destroy(row);
        const routed = if (kind == .fetch) self.enrollFetched(conn_id, resolution) else resolution;
        if (inner) |listener| {
            listener.func(listener.ctx, routed);
            return;
        }
        self.queueCompletion(id, routed);
    }

    /// Settle a vow by id — the enliven bridge's path to the shared retire
    /// logic. A row already gone (the connection was released and dropped
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
    /// would double-wrap it into a reference no connection can lower. An
    /// unenrollable capability would mis-route a later re-gift, so it fails
    /// loud as a break rather than surfacing half-usable.
    fn enrollFetched(self: *Host, conn_id: engine.ConnId, resolution: actors.Resolution) actors.Resolution {
        if (resolution == .fulfilled and resolution.fulfilled == .reference and resolution.fulfilled.reference == .far and
            resolution.fulfilled.reference.far.import_position.int() < engine.Node.REDEEMED_TOKEN_BASE)
        {
            const token = self.node.enrollForeign(conn_id, .{ .far = resolution.fulfilled.reference.far }) catch |err| {
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
                    self.actions.appendAssumeCapacity(.{ .failed = .{ .vow_id = vow_id, .message = "" } });
                    return;
                };
                self.actions.appendAssumeCapacity(.{ .settled = .{ .vow_id = vow_id, .value = cloned } });
            },
            .broken => |message| {
                const owned: []const u8 = self.allocator.dupe(u8, message) catch "";
                self.actions.appendAssumeCapacity(.{ .failed = .{ .vow_id = vow_id, .message = owned } });
            },
            // Unreachable by construction — the host claims every inbound
            // give before the vat can settle a vow with it (auto-redeem) —
            // but a defensive break beats a crash if that invariant moves.
            .give => {
                const owned: []const u8 = self.allocator.dupe(u8, "raw handoff reached a settle listener") catch "";
                self.actions.appendAssumeCapacity(.{ .failed = .{ .vow_id = vow_id, .message = owned } });
            },
        }
    }

    /// Drop the vow rows homed on a released connection, so the map does not
    /// grow with connection churn. The connection's far rows already retired
    /// through its vow break; what remains is never-fired rows whose vat
    /// listener dies with the vat, freed here. Removal invalidates the
    /// iterator, so each scan collects a bounded batch of doomed ids into
    /// stack scratch (allocation-free — this runs inside teardown) and
    /// removes them between scans; one scan per batch, not one per row.
    fn dropVowRows(self: *Host, conn_id: engine.ConnId) void {
        var doomed: [64]u64 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.vows.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.conn_id != conn_id) continue;
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

    const RoutedSend = struct { conn: *HostConnection, target: actors.Ref };

    /// Resolve a send's target to the connection and vat reference it rides: a
    /// near export to its local actor on `conn`, a far reference through the
    /// node's routing (a token to its exporter connection with the real
    /// reference swapped in). Fails closed when a token's exporter is gone.
    fn routeSend(self: *Host, conn: *HostConnection, target: model.Reference, args: []const model.Argument) !RoutedSend {
        self.assertOwner();
        try checkLive(conn);
        switch (target) {
            .near => |near| {
                const ref = conn.served.vat.refForExport(near.export_position.int()) orelse return actors.Error.NoSuchActor;
                return .{ .conn = conn, .target = ref };
            },
            .far => {
                const routed = self.node.routeReference(conn.conn_id, target) orelse return HostError.TokenRetired;
                const routed_conn = self.conns.get(routed.conn_id) orelse return HostError.TokenRetired;
                try checkLive(routed_conn);
                for (args) |argument| {
                    if (self.argIsForeignDeep(routed_conn.conn_id, argument)) return HostError.ForeignArgument;
                }
                return .{ .conn = routed_conn, .target = .{ .far = routed.target.far } };
            },
            else => return vocab.Error.UncallableTarget,
        }
    }

    /// Whether any reference in `argument`'s tree is foreign to `conn_id`
    /// (see `engine.Node.argIsForeign`). Caller-supplied data, so the walk
    /// recurses the application's own nesting. Public because the C driver
    /// tier's turn-time forward applies the same refusal before it hands a
    /// message to a turn, off the `send` path that checks it here.
    pub fn argIsForeignDeep(self: *Host, conn_id: engine.ConnId, argument: model.Argument) bool {
        return switch (argument) {
            .reference => |ref| self.node.argIsForeign(conn_id, ref),
            .list, .set => |items| for (items) |item| {
                if (self.argIsForeignDeep(conn_id, item)) break true;
            } else false,
            .tagged => |tagged| for (tagged.value) |item| {
                if (self.argIsForeignDeep(conn_id, item)) break true;
            } else false,
            .@"struct" => |entries| for (entries) |entry| {
                if (self.argIsForeignDeep(conn_id, entry.value)) break true;
            } else false,
            else => false,
        };
    }

    const Projection = union(enum) { index: i64, untag: []const u8 };

    fn vowProjection(self: *Host, vow_id: u64, projection: Projection) !u64 {
        self.assertOwner();
        const row = self.vows.get(vow_id) orelse return HostError.NoSuchVow;
        const conn = self.conns.get(row.conn_id) orelse return HostError.NoSuchVow;
        try checkLive(conn);
        const source = switch (row.vow) {
            .far => |answer| answer,
            // A local vow has no wire answer to project against.
            .local => return vocab.Error.NotPipelineable,
        };
        const peer = conn.served.peer;
        const answer = model.AnswerPosition.from(peer.allocateAnswer());
        const receiver: model.Reference = .{ .promise = .{ .answer_position = source } };
        switch (projection) {
            .index => |index| try peer.sendCopying(.{ .index = .{ .receiver = receiver, .index = index, .answer = answer } }),
            .untag => |tag| try peer.sendCopying(.{ .untag = .{ .receiver = receiver, .tag = tag, .answer = answer } }),
        }
        const id = try self.mintVow(conn, .{ .far = answer }, .plain);
        try self.markDirty(conn.conn_id);
        try self.finishVerb();
        return id;
    }

    /// Note that `conn_id` has enqueued-but-unencoded outbound; the top-level
    /// verb's unwind drives it. Deduplicated, and legal under the latch — this
    /// is exactly how a nested verb's outbound reaches the wire.
    fn markDirty(self: *Host, conn_id: engine.ConnId) !void {
        for (self.pending_flush.items) |queued| {
            if (queued == conn_id) return;
        }
        try self.pending_flush.append(self.allocator, conn_id);
    }

    /// The tail of every top-level verb: encode and pump until quiescent. A
    /// nested verb (the latch is held) returns immediately — the enclosing
    /// verb's own tail picks up what it enqueued.
    fn finishVerb(self: *Host) !void {
        if (self.in_callback) return;
        self.in_callback = true;
        defer self.in_callback = false;
        try self.drainWork();
    }

    /// Alternate the two work queues to quiescence: encode every dirty
    /// connection (queueing its flush action), then execute every node
    /// serve-step action. Either side can feed the other — a settle listener's
    /// nested send dirties a connection, an encoded withdraw queues a claim's
    /// actions — so the loop runs until neither moves.
    ///
    /// Attribution under a `local_turn_budget`: a budget breach here belongs
    /// to the connection whose vat amplified, never to the verb that fed the
    /// pump — the fed connection's work may have flooded a *sibling*. The
    /// flooded connection is condemned (typed `resource_exhausted` abort) and
    /// a `close` action names it for the embedder; the verb that ran this
    /// pump succeeds. A budget breach inside the fed connection's own
    /// dispatch (`feed`'s latched `feedBorrowed`) never reaches here: it
    /// keeps `failDispatch` semantics and fails that feed.
    fn drainWork(self: *Host) !void {
        while (true) {
            var progressed = false;
            while (self.pending_flush.items.len > 0) {
                progressed = true;
                const conn_id = self.pending_flush.orderedRemove(0);
                const conn = self.conns.get(conn_id) orelse continue;
                if (conn.condemned) {
                    // A condemned connection's vat is never driven again — its
                    // queued turns died with the verdict. Encode what is
                    // already queued (the typed abort) so the embedder writes
                    // it before closing; best-effort, the session is ending.
                    conn.served.peer.stepToIdle() catch {};
                    if (conn.served.hasOutbound()) try self.queueFlushAction(conn_id);
                    continue;
                }
                // Backstop: any path that skipped the condemned branch above
                // and still reached a drive on a condemned conn panics loud.
                std.debug.assert(!conn.condemned);
                conn.served.driveFed() catch |err| switch (err) {
                    error.LocalTurnLimitExceeded => {
                        try self.condemn(conn, .resource_exhausted, "local turn budget exceeded");
                        try self.queueCloseAction(conn_id);
                        continue;
                    },
                    else => return err,
                };
                // Tell the embedder only when a frame is actually queued: a
                // feed that encoded nothing must not cost a flush round-trip.
                if (conn.served.hasOutbound()) try self.queueFlushAction(conn_id);
            }
            while (self.node.nextAction()) |action| {
                progressed = true;
                try self.execNodeAction(action);
            }
            if (!progressed) return;
        }
    }

    /// The non-blocking executor of node serve-step actions: settles and
    /// fails fire the recipient vat's listener directly (`Vat.settleFar`);
    /// dials and gift-id draws are host effects, queued for the embedder;
    /// flushes mark the connection dirty so the encode loop drives it.
    fn execNodeAction(self: *Host, action: engine.Node.Action) !void {
        switch (action) {
            .dial => |d| {
                // The node frees its action's bytes at its next `nextAction`;
                // the embedder-facing action owns host dupes.
                const dial = try self.dialActionFields(d.pending, d.locator);
                self.queueHostAction(.{ .dial = dial }) catch |err| {
                    freeHostAction(self.allocator, .{ .dial = dial });
                    return err;
                };
            },
            .flush => |conn_id| try self.markDirty(conn_id),
            .settle => |s| {
                const conn = self.conns.get(s.conn_id) orelse return;
                try conn.served.vat.settleFar(
                    model.AnswerPosition.from(s.answer),
                    .{ .fulfilled = .{ .reference = .{ .far = model.FarRef.object(s.token) } } },
                );
            },
            .fail => |f| {
                const conn = self.conns.get(f.conn_id) orelse return;
                try conn.served.vat.settleFar(model.AnswerPosition.from(f.answer), .{ .broken = f.reason });
            },
            .need_gift_id => |n| try self.queueHostAction(.{ .need_gift_id = .{ .ticket = n.ticket } }),
        }
    }

    /// Build a `dial` action's owned payload: the locator dupe plus its
    /// parsed transport, designator, and `direct-addresses` hint, each duped
    /// onto the host so all four views carry the popped action's
    /// valid-until-next-`nextAction` lifetime. An unparseable locator leaves
    /// the parsed pieces empty and the URI intact for the embedder to
    /// interpret.
    fn dialActionFields(self: *Host, ticket: engine.Node.PendingId, locator_uri: []const u8) !HostAction.Dial {
        const locator = try self.allocator.dupe(u8, locator_uri);
        errdefer self.allocator.free(locator);
        var dial = HostAction.Dial{ .ticket = ticket, .locator = locator };
        const parsed = model.uri.parsePeer(self.allocator, locator_uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return dial,
        };
        defer model.freePeerLocator(self.allocator, parsed);
        dial.transport = try self.allocator.dupe(u8, parsed.transport);
        errdefer self.allocator.free(dial.transport);
        dial.designator = try self.allocator.dupe(u8, parsed.designator);
        errdefer self.allocator.free(dial.designator);
        for (parsed.hints.entries) |entry| {
            if (!std.mem.eql(u8, entry.name, "direct-addresses")) continue;
            switch (entry.value) {
                .string, .bytes => |bytes| {
                    dial.direct_addresses_hint = try self.allocator.dupe(u8, bytes);
                    return dial;
                },
                else => {},
            }
        }
        return dial;
    }

    fn queueHostAction(self: *Host, action: HostAction) !void {
        // Keep one spare completion slot per live vow on top of this append,
        // so a vow fire's `appendAssumeCapacity` can never fail (see
        // `queueCompletion`).
        try self.actions.ensureUnusedCapacity(self.allocator, self.vows.count() + 1);
        self.actions.appendAssumeCapacity(action);
    }

    /// Queue a flush action unless an identical one is already pending — a
    /// pump that touches one connection several times tells the embedder once.
    /// The one dispatch-failure arm under every feed verb: the peer has
    /// already projected a typed op:abort, so a flush is queued for the
    /// embedder (best-effort — the session is closing either way) and the
    /// dispatch error passes through.
    fn failDispatch(self: *Host, conn_id: engine.ConnId, err: anyerror) anyerror {
        self.queueFlushAction(conn_id) catch {};
        return err;
    }

    fn queueFlushAction(self: *Host, conn_id: engine.ConnId) !void {
        for (self.actions.items[self.action_head..]) |queued| {
            if (queued == .flush and queued.flush == conn_id) return;
        }
        try self.queueHostAction(.{ .flush = conn_id });
    }

    /// Queue a `close` action unless an identical one is already pending — a
    /// connection is condemned once, but the guard keeps the queue honest if
    /// two pump rounds both reach it.
    fn queueCloseAction(self: *Host, conn_id: engine.ConnId) !void {
        for (self.actions.items[self.action_head..]) |queued| {
            if (queued == .close and queued.close == conn_id) return;
        }
        try self.queueHostAction(.{ .close = conn_id });
    }

    fn freeHostAction(allocator: std.mem.Allocator, action: HostAction) void {
        switch (action) {
            .dial => |d| {
                allocator.free(d.locator);
                if (d.transport.len != 0) allocator.free(d.transport);
                if (d.designator.len != 0) allocator.free(d.designator);
                if (d.direct_addresses_hint.len != 0) allocator.free(d.direct_addresses_hint);
            },
            .settled => |s| model.freeArgument(allocator, s.value),
            .failed => |f| if (f.message.len != 0) allocator.free(f.message),
            .flush, .close, .need_gift_id => {},
        }
    }

    // ── Hooks ────────────────────────────────────────────────────────────────

    /// The before-serve hook on every host connection. Three arms, in order:
    /// an inbound start-session on an accepted connection runs the
    /// crossed-hellos tiebreak (and never skips serve); a resolve fulfilling
    /// with a signed handoff give is auto-redeemed — the node accepts it and
    /// the vat never sees a raw give, so the vow later settles with the
    /// routable token; any other resolve is offered to the node, which claims
    /// it when it settles a pending withdraw.
    fn hostBeforeServe(ctx: ?*anyopaque, served: *Served, event: *engine.Event) anyerror!bool {
        _ = served;
        const conn: *HostConnection = @ptrCast(@alignCast(ctx.?));
        const host = conn.host;
        const body = event.view() catch return false;
        if (body == .start_session) {
            if (conn.role == .accepted) try host.tiebreakInbound(conn, body.start_session);
            return false;
        }
        if (body != .resolve) return false;
        const resolve = body.resolve;
        if (resolve.resolution == .fulfill) {
            const value = resolve.resolution.fulfill;
            if (value == .handoff and value.handoff == .give) {
                var give_bytes: []const u8 = "";
                var locator_uri: ?[]u8 = null;
                if (engine.spanSignedHandoffGive(event.bytes())) |span| {
                    give_bytes = span;
                    locator_uri = engine.handoff_recipient.exporterLocatorUri(
                        host.allocator,
                        value.handoff.give.exporter_location,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.MalformedLocatorRecord => null,
                    };
                }
                defer if (locator_uri) |uri| host.allocator.free(uri);
                // An unprojectable give (no verbatim span, no dialable
                // locator) is still claimed: `acceptGive` fails the answer
                // closed on the empty locator, so the vow breaks instead of
                // surfacing a raw give no settle listener has an arm for.
                try host.node.acceptGive(conn.conn_id, resolve.answer.int(), give_bytes, locator_uri orelse "");
                return true;
            }
        }
        return try host.node.claimResolve(conn.conn_id, resolve.answer.int(), redeemOutcome(resolve));
    }

    fn hostResolveInterceptor(ctx: ?*anyopaque, answer: model.AnswerPosition, fulfilled: model.Argument) anyerror!actors.InterceptOutcome {
        const conn: *HostConnection = @ptrCast(@alignCast(ctx.?));
        // A claim's `need_gift_id` and flush actions pump at the enclosing
        // feed's unwind; nothing blocks here.
        return interceptFulfilled(&conn.host.node, conn.conn_id, answer, fulfilled);
    }

    /// Run the crossed-hellos tiebreak for an inbound start-session on an
    /// accepted connection (ADR-0030): with an outbound dial registered to the
    /// same partner, the not-lower side condemns its accepted connection, and
    /// the strictly lower side condemns its own dialed one — immediately, no
    /// deferred flag, because one thread drives the host.
    fn tiebreakInbound(self: *Host, conn: *HostConnection, ss: model.view.StartSession) !void {
        const partner_key = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return;
        const partner_pid = crypto.derivePublicIdentifier(partner_key);
        const designator = ss.acceptable_location.designator;
        const verdict = self.hellos.checkInbound(designator, partner_pid) orelse return;
        if (verdict.abort_inbound) {
            // Not lower: this accepted connection is the loser; the pair keeps
            // the session our own dial opened.
            try self.condemn(conn, .crossed_hellos, "crossed hellos: higher-keyed side aborting its inbound session");
            return;
        }
        // Strictly lower: our own dial to this partner is the loser; the pair
        // keeps this accepted session.
        var it = self.conns.valueIterator();
        while (it.next()) |candidate| {
            if (candidate.*.role == .dialed and !candidate.*.condemned and
                std.mem.eql(u8, candidate.*.role.dialed, designator))
            {
                try self.condemn(candidate.*, .crossed_hellos, "crossed hellos: lower-keyed side aborting its outbound session");
            }
        }
    }

    /// Condemn a connection the host is done with — a crossed-hellos tiebreak
    /// loser, or one whose local turns amplified past the budget: queue its
    /// typed abort (`kind` names which contract it broke) and mark it so every
    /// later verb refuses `ConnectionCondemned`. The abort rides the ordinary
    /// flush path; the embedder drains and writes it, then releases the conn.
    fn condemn(self: *Host, conn: *HostConnection, kind: model.AbortKind, message: []const u8) !void {
        if (conn.condemned) return;
        conn.condemned = true;
        try conn.served.peer.sendCopying(.{ .abort = .{ .kind = kind, .message = message } });
        try self.markDirty(conn.conn_id);
    }
};

/// The host-owned one-shot behind a wire-riding `Host.enliven`: record the
/// enlivenment in the session's dedup cache (or clear the in-flight marker on
/// a break) before the outcome reaches the vow, then free itself and its
/// owned swissnum copy. It holds the answer's one vat listener slot; the vow
/// row it settles routes the outcome to `vowOn`'s listener or the action
/// queue like any other settlement.
const EnlivenBridge = struct {
    host: *Host,
    conn_id: engine.ConnId,
    swissnum: []const u8,
    vow_id: u64,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const bridge: *EnlivenBridge = @ptrCast(@alignCast(ctx.?));
        const host = bridge.host;
        const vow_id = bridge.vow_id;
        defer {
            host.allocator.free(bridge.swissnum);
            host.allocator.destroy(bridge);
        }
        // A connection already released (this fire is its teardown break)
        // has no session to bookkeep; the vow still settles.
        if (host.conns.get(bridge.conn_id)) |conn| {
            const peer = conn.served.peer;
            if (resolution == .fulfilled and resolution.fulfilled == .reference and resolution.fulfilled.reference == .far) {
                // The far is POD; `recordEnlivenment` caches it and clears
                // the in-flight marker. It only errors on a non-far/broken
                // outcome, which a `.far` fulfillment never is.
                _ = engine.sturdyref.recordEnlivenment(peer.allocator, &peer.session_state, bridge.swissnum, .{
                    .fulfilled = .{ .far = resolution.fulfilled.reference.far },
                }) catch {};
            } else {
                peer.finishPendingEnliven(bridge.swissnum);
            }
        }
        host.fireVow(vow_id, resolution);
    }
};
