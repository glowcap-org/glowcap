//! Session lifecycle for the byte-fed host core: minting a node-registered
//! CapTP session shell, the dialed and accepted open paths over it, the
//! directories that find a live session again (by dialed designator, partner
//! key, or durable peer identity), and the one teardown funnel every release,
//! condemnation, and failed open goes through.
//!
//! One of `host.zig`'s responsibilities, kept beside it rather than in it.
//! The `Host` still owns the state — the session map, the side indexes, the
//! seed counter — and still presents `openDialedLocator`,
//! `openAcceptedAdvertised`, `releaseSession`, and their siblings as its own
//! verbs through decl aliases, so a caller reads one `Host` surface.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_pump = @import("host_pump.zig");
const served_mod = @import("served.zig");
const vocab = @import("vocab.zig");
const crossed_hellos = @import("crossed_hellos.zig");
const vows_mod = @import("vows.zig");
const handoff_mod = @import("handoff.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const DialTarget = host_mod.DialTarget;
const Served = served_mod.Served;
const crypto = foundation.crypto;
const session_seed_domain = host_mod.session_seed_domain;

/// Mint the dialing half of a session to the peer `locator` names:
/// register the outbound with the crossed-hellos table, register the session
/// on the node, and sign and encode `op:start-session` with this session's key,
/// carrying this node's selected acceptable location. The hello
/// is encoded before this returns; the embedder drains it with `takeOutbound`
/// (a flush action is queued) and drives the handshake byte-fed. URI holders
/// parse first (`model.uri.parsePeer`) — same spine as
/// `pancake_host_session_open_dialed_locator`. The locator is borrowed for
/// the call. The loop-fed bridge adopts with `openDialedOver` after
/// `Loop.dialLocator` completes; this path mints the peer.
pub fn openDialedLocator(self: *Host, locator: model.PeerLocator) !*HostSession {
    return openDialedWith(self, .mint, locator.transport, locator.designator);
}

/// `openDialedLocator` over a peer the embedder owns and pins at a stable
/// address: identical wiring — crossed-hellos outbound registration, the
/// initiator hello carrying the Node-owned acceptable location, the key-scheme
/// dial's demand on the partner
/// (`engine.Peer.demandPartnerDurableKey`) — minus ownership.
/// The node routes through the adopted peer but never frees it: the
/// embedder frees the peer itself, only after `releaseSession`. This is the
/// completion loop's dialed adoption seam — the dial half of
/// `openAcceptedAdvertisedOver` (ADR-0076 loop-side dial executor).
pub fn openDialedOver(
    self: *Host,
    peer: *engine.Peer,
    transport: []const u8,
    partner_designator: []const u8,
) !*HostSession {
    return openDialedWith(self, .{ .over = peer }, transport, partner_designator);
}

/// Shared dialed-open core: `openDialedLocator` mints a node-owned peer;
/// `openDialedOver` adopts an embedder-owned one. Everything else is one
/// path — crossed-hellos, role, keyed pin, hello — so the two entry
/// points cannot drift.
pub fn openDialedWith(
    self: *Host,
    source: union(enum) { mint: void, over: *engine.Peer },
    transport: []const u8,
    partner_designator: []const u8,
) !*HostSession {
    try self.refuseReentry();
    const advertised = try requireAcceptableLocator(self);
    try refuseDuplicateDial(self, transport, partner_designator);
    // The designator is borrowed all the way to `mintShell`, which dupes it
    // into the shell. One owner from birth: `freeSessionShell` is the only
    // free, so a refusal below can unwind the mint without this frame
    // holding an obligation to discharge as well.
    const session = switch (source) {
        .mint => try mint(self, .{ .dialed = partner_designator }, transport),
        .over => |peer| try mintOver(self, peer, .{ .dialed = partner_designator }, transport),
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
    const dial_target = target(session.transport, session.role.dialed);
    self.hellos.registerOutbound(self.allocator, dial_target, our_session_id) catch |err| {
        failOpen(self, session);
        return err;
    };
    errdefer self.hellos.unregister(self.allocator, dial_target);
    // The dial's own demand, before the hello; on failure unwind the mint. The
    // shared open tail's `errdefer failOpen` covers hello failures.
    if (vocab.designatorSchemeForTransport(transport) == .key) {
        const expected = crypto.PeerKey.fromDesignator(partner_designator) orelse {
            failOpen(self, session);
            return error.InvalidAddress;
        };
        session.served.port.peer.demandPartnerDurableKey(expected);
    }

    return helloAndEnroll(self, session, advertised);
}

/// Mint the accepting half of a session using this node's selected acceptable
/// location, which may intentionally use another transport (ADR-0109).
pub fn openAcceptedAdvertised(self: *Host, transport: []const u8) !*HostSession {
    try self.refuseReentry();
    const advertised = try requireAcceptableLocator(self);
    return helloAndEnroll(self, try mint(self, .accepted, transport), advertised);
}

/// `openAcceptedAdvertised` over an embedder-owned, pinned peer. The node
/// routes through the peer but never frees it.
pub fn openAcceptedAdvertisedOver(self: *Host, peer: *engine.Peer, transport: []const u8) !*HostSession {
    try self.refuseReentry();
    const advertised = try requireAcceptableLocator(self);
    return helloAndEnroll(self, try mintOver(self, peer, .accepted, transport), advertised);
}

/// The live, non-condemned session that already reaches `partner_designator`
/// (ADR-0012), or null. One authority two callers read: this host refuses a
/// duplicate app dial against a non-null result, and the node-action pump
/// reuses that session to redeem a give rather than dial a duplicate it would
/// then refuse. Match set: our dialed designator (bytes we chose), or a live
/// session whose partner proved that same *durable* key. Never the partner's
/// session key, which every connection draws fresh and which names an
/// incarnation rather than a peer.
///
/// A partner-declared `acceptable_location.designator`
/// on an address transport is never a match key: the hello signature proves
/// the claim, not ownership of a tcp `host:port`, so trusting it would let an
/// inbound peer squat dial availability. Dedup against an accepted tcp session
/// still runs after the newcomer's start-session via `refuseDuplicatePartnerKey`
/// (verified key); an accepted session racing an in-flight dial stays legal
/// for crossed hellos until start-session (ADR-0068).
pub fn liveSessionForDial(self: *const Host, transport: []const u8, partner_designator: []const u8) ?*HostSession {
    if (liveIndexedSession(self, self.dialed_by_target.get(target(transport, partner_designator)))) |session| return session;
    // The durable-peer directory, never the side index (ADR-0097): this
    // asks "which live session reaches peer P", and P is a durable
    // identity. Deriving a side name from P instead would be asking the
    // session-incarnation directory a question it only answers while
    // every session reuses its host's key.
    if (vocab.designatorSchemeForTransport(transport) != .key) return null;
    const want = crypto.PeerKey.fromDesignator(partner_designator) orelse return null;
    return liveIndexedSession(self, self.peer_by_durable.get(want.bytes));
}

/// Refuse a new dial when a live session already reaches this partner.
pub fn refuseDuplicateDial(self: *const Host, transport: []const u8, partner_designator: []const u8) HostError!void {
    if (liveSessionForDial(self, transport, partner_designator) != null) return HostError.SessionPairExists;
}

/// After crossed-hellos tiebreak, keep at most one non-condemned session to
/// the same CapTP partner key (dual-accept settlement, or a dial that
/// slipped past pre-identity refuse). Survivor choice follows the ADR-0068
/// / crossed-hellos key order (`CrossedHellos.checkInbound`): both peers
/// independently keep the session the higher-keyed peer opened — dialed
/// when we are higher, accepted when we are lower — so a crossed pair that
/// missed the designator tiebreak still collapses to the same session
/// on both ends rather than condemning by local arrival order. Same-role
/// duplicates (dual-accept) keep the already-indexed session and condemn
/// the newcomer.
pub fn refuseDuplicatePartnerKey(self: *Host, session: *HostSession, ss: model.view.StartSession) !void {
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
        try indexPartnerKey(self, session, partner_key.bytes, ss.acceptable_location.designator);
        return;
    };
    const other = liveIndexedSession(self, existing_pid) orelse {
        // Stale index row (session released without unindex); replace.
        try indexPartnerKey(self, session, partner_key.bytes, ss.acceptable_location.designator);
        return;
    };
    if (other == session) {
        try indexPartnerKey(self, session, partner_key.bytes, ss.acceptable_location.designator);
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
    if (loser == other) try indexPartnerKey(self, session, partner_key.bytes, ss.acceptable_location.designator);
}

/// Index a live session under its verified partner session key. Replaces any
/// prior row for that key (caller condemned the previous holder). Reserves
/// its own slot: the partner key is unknown until the partner's
/// `op:start-session` arrives, so the reservation pairs 1:1 with this insert
/// rather than with the earlier mint (mints between start-sessions would
/// otherwise never grow the map, and a burst of un-indexed sessions would
/// overflow the mint reservation). Fails closed on OOM before apply.
pub fn indexPartnerKey(self: *Host, session: *HostSession, key: [crypto.PEER_KEY_BYTES]u8, designator: []const u8) !void {
    try self.partner_by_side.ensureUnusedCapacity(self.allocator, 1);
    const side = try engine.handoff_names.sideName(&key);
    self.partner_by_side.putAssumeCapacity(side, session.peer_id);
    session.indexed_partner_key = key;
    try indexDurablePeer(self, session, designator);
}

/// The authenticated durable designator this session's partner proved, or
/// null when it proved none (ADR-0105). The one derivation both the index
/// and unindex paths read, which is why the shell stores no copy.
///
/// Both readings agree because neither input can move once a session is
/// indexed. The partner's designator is written when its handshake half
/// arrives and never rewritten, and the evidence provenance reads is settled
/// at that same hello: `engine.inbound` weighs a hello only while the session
/// still awaits one (`session.Session.awaitsPartnerHello`), so an open
/// session's verdict is fixed. Keeping it out of the shell also keeps the
/// per-connection footprint budget intact.
fn durablePeerName(session: *const HostSession) ?[]const u8 {
    const peer = session.served.port.peer;
    if (!peer.verify_partner_handshake) return null;
    const designator = peer.session_state.partnerDesignator() orelse return null;
    if (Host.durableProvenance(peer, designator) == .unauthenticated) return null;
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
    if (Host.durableProvenance(peer, designator) == .unauthenticated) return null;
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
pub fn nextSessionSeed(self: *Host) [crypto.SEED_BYTES]u8 {
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

pub fn resolveSessionSecret(ctx: ?*anyopaque, peer_id: engine.PeerId) ?crypto.SecretKey {
    const self: *Host = @ptrCast(@alignCast(ctx orelse return null));
    const session = self.sessions.get(peer_id) orelse return null;
    return session.sessionSecret();
}

pub fn indexDurablePeer(self: *Host, session: *HostSession, designator: []const u8) !void {
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
        const dial_target = target(session.transport, session.role.dialed);
        if (self.dialed_by_target.get(dial_target)) |pid| {
            if (pid == session.peer_id) {
                // tolerant: a prior unindex may already have removed it.
                _ = self.dialed_by_target.remove(dial_target);
            }
        }
    }
}

pub fn liveIndexedSession(self: *const Host, peer_id: ?engine.PeerId) ?*HostSession {
    const pid = peer_id orelse return null;
    const session = self.sessions.get(pid) orelse return null;
    if (session.condemned) return null;
    return session;
}

/// The live dialed session whose selected peer matches `(transport,
/// designator)`, for Host-level select-or-dial (ADR-0098 step 4). Dialed
/// sessions only: an accepted address session cannot prove its claimed
/// designator, and the enliven path re-verifies whatever this returns
/// through the complete sturdyref peer check.
pub fn dialedSessionFor(self: *Host, transport: []const u8, designator: []const u8) ?*HostSession {
    self.assertOwner();
    const peer_id = self.dialed_by_target.get(target(transport, designator)) orelse return null;
    const session = self.sessions.get(peer_id) orelse return null;
    if (session.condemned) return null;
    return session;
}

fn target(transport: []const u8, designator: []const u8) DialTarget {
    return .{ .transport = transport, .designator = designator };
}

/// Refuse a durable identity this host does not own. The caller first decides
/// from the transport scheme that the designator is a key; byte shape alone
/// carries no such authority.
pub fn refuseUnheldIdentity(self: *const Host, designator: []const u8) error{UnheldIdentity}!void {
    const claimed = crypto.PeerKey.fromDesignator(designator) orelse return;
    const held = self.node.secretKey().publicKey();
    if (!std.mem.eql(u8, claimed.asBytes(), held.asBytes())) return error.UnheldIdentity;
}

fn requireAcceptableLocator(self: *const Host) HostError!model.PeerLocator {
    return self.node.acceptableLocator() orelse
        HostError.MissingAdvertisedLocator;
}

/// Sign exactly one Node-owned locator snapshot, then enroll and pump the
/// session. `errdefer failOpen` unwinds a failed hello.
pub fn helloAndEnroll(self: *Host, session: *HostSession, advertised: model.PeerLocator) !*HostSession {
    errdefer failOpen(self, session);
    try session.served.port.peer.sendKeyedStartSessionExact(advertised, session.sessionSecret());
    enroll(self, session);
    try host_pump.dirtyThenPump(self, session.peer_id);
    return session;
}

/// Release one session: break its still-parked far vows (their
/// resolutions can never arrive), retire it from the node — whose
/// fail-closed sweep queues the fail actions that break *sibling*
/// sessions' answers — and free the shell. The sibling fails fire
/// inside this call, through the same pump every verb ends with.
pub fn releaseSession(self: *Host, session: *HostSession) !void {
    self.traceClose(session);
    try self.refuseReentry();
    try self.checkOwnedSession(session);
    self.in_callback = true;
    {
        defer self.in_callback = false;
        session.served.port.breakFarVows(session.served.closeReason("connection released"));
        try cancelSessionIngress(self, session, session.served.closeReason("connection released"));
    }

    if (session.role == .dialed)
        self.hellos.unregister(self.allocator, target(session.transport, session.role.dialed));
    unindexSession(self, session);
    std.debug.assert(self.sessions.remove(session.peer_id));
    const peer_id = session.peer_id;
    _ = self.capabilities.invalidatePeer(peer_id);
    vows_mod.dropVowRows(self, peer_id);
    freeSessionShell(self, session);
    self.node.removePeer(peer_id);
    host_pump.finishVerb(self) catch |err| switch (err) {
        // Dirty-FIFO capacity was reserved when each shell was minted, and
        // a receiver drive that hits OOM requeues itself before returning.
        // The exact wake therefore remains retryable by the next Host verb;
        // condemning unrelated sessions would turn coordination pressure
        // into a Host-wide authority failure.
        error.OutOfMemory => {},
        else => condemnRemainingSessions(self, "session release cleanup failed"),
    };
}

pub fn cancelSessionIngress(self: *Host, session: *HostSession, reason: []const u8) !void {
    if (session.ingress_cancelled) return;
    try self.vat.cancelIngress(session.served.port.ingress, reason);
    session.ingress_cancelled = true;
}

pub fn condemnRemainingSessions(self: *Host, message: []const u8) void {
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
pub const RoleSpec = union(enum) {
    dialed: []const u8,
    accepted,
};

pub fn mint(self: *Host, spec: RoleSpec, transport: []const u8) !*HostSession {
    try self.sessions.ensureUnusedCapacity(self.allocator, 1);
    try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
    // The session being minted owes a flush and a close of its own.
    try self.reserveActions(2);
    if (spec == .dialed) try self.dialed_by_target.ensureUnusedCapacity(self.allocator, 1);
    const peer_id = try self.node.registerPeer(negotiatingOptions(
        self,
    ));
    errdefer self.node.removePeer(peer_id);
    return mintShell(self, self.node.peer(peer_id).?, peer_id, spec, transport);
}

/// `mint` over a peer the embedder already owns and pins at a stable
/// address (`engine.Node.registerPeerOver`): the node routes through it
/// and the host serves it, but neither ever frees it — `releaseSession` and
/// `deinit` only unregister the slot, and the embedder frees the peer
/// after `releaseSession`. This is how a peer-owning loop, whose fixed slots
/// hold each peer inline, puts its sessions under one host.
pub fn mintOver(self: *Host, peer: *engine.Peer, spec: RoleSpec, transport: []const u8) !*HostSession {
    try self.sessions.ensureUnusedCapacity(self.allocator, 1);
    try self.pending_flush.ensureTotalCapacity(self.allocator, self.sessions.count() + 1);
    // The session being minted owes a flush and a close of its own.
    try self.reserveActions(2);
    if (spec == .dialed) try self.dialed_by_target.ensureUnusedCapacity(self.allocator, 1);
    const peer_id = try self.node.registerPeerOver(peer);
    errdefer self.node.removePeer(peer_id);
    return mintShell(self, peer, peer_id, spec, transport);
}

/// The host posture imposed on every minted or adopted peer. The export
/// range is not in it: `engine.Node` hands each session one at
/// registration, so no posture can carry one and none can overwrite one.
pub fn negotiatingOptions(self: *const Host) engine.Peer.NegotiatingOptions {
    return .{
        .codec = self.opts.codec,
        .captp_version = self.opts.captp_version,
        .features = self.opts.features,
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
pub fn mintShell(self: *Host, peer: *engine.Peer, peer_id: engine.PeerId, spec: RoleSpec, transport: []const u8) !*HostSession {
    peer.reposture(negotiatingOptions(
        self,
    ));
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
        .session_seed = nextSessionSeed(
            self,
        ),
        .served = Served.over(self.allocator, peer),
        .transport = owned_transport,
        .role = role,
    };
    // `Host.init` returns by value, so only a live Host method knows the
    // object's stable address. Store the seam once per Node (reassigning
    // the same value on later mints is harmless) rather than in each Peer.
    // The projection and gifter callbacks live with the publication and
    // handoff code in `host.zig`; the wiring is theirs too.
    handoff_mod.wireNodeServices(self);
    self.node.setSessionSecretResolver(.{ .ctx = self, .resolve = resolveSessionSecret });
    session.served.port.ingress = try self.vat.openIngress();
    session.served.local_turn_budget = self.opts.local_turn_budget;
    return session;
}

pub fn enroll(self: *Host, session: *HostSession) void {
    session.served.serve_options = .{ .hook_ctx = session, .before_serve = Host.hostBeforeServe };
    session.served.port.setResolveInterceptor(.{ .ctx = session, .func = Host.hostResolveInterceptor });
    self.sessions.putAssumeCapacity(session.peer_id, session);
    if (session.role == .dialed) {
        self.dialed_by_target.putAssumeCapacity(
            target(session.transport, session.role.dialed),
            session.peer_id,
        );
    }
}

/// Free one session's owned shell after it has been unregistered from every
/// index and its Vat ingress has been canceled: the served Port, unconsumed feed tail, connection identity bytes,
/// then the shell itself. Every session teardown funnels through here so no
/// path drops one of these frees. Call only after `unindexSession` (and, for
/// a dialed session, `hellos.unregister`): the transport and designator bytes
/// back the dial index key until this frees their shared block.
pub fn freeSessionShell(self: *Host, session: *HostSession) void {
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

pub fn failOpen(self: *Host, session: *HostSession) void {
    unindexSession(self, session);
    // tolerant: enrolled only when the failure came after `enroll`.
    _ = self.sessions.remove(session.peer_id);
    const peer_id = session.peer_id;
    cancelSessionIngress(self, session, session.served.closeReason("session open failed")) catch unreachable;
    freeSessionShell(self, session);
    self.node.removePeer(peer_id);
}
