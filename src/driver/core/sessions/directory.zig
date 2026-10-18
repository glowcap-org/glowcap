//! Session directories for the byte-fed host core: the lookups that find a
//! live session again (by the dial target this host chose, by a partner's
//! proved durable key, or by a side index) and the duplicate refusals and
//! index upkeep those lookups power (ADR-0012, ADR-0068, ADR-0097). Split
//! from `sessions.zig` by responsibility. The `Host` presents
//! each verb through decl aliases there and in `host.zig`.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const crossed_hellos = @import("../crossed_hellos.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const DialTarget = host_mod.DialTarget;
const crypto = foundation.crypto;

const DialTargetContext = struct {
    pub fn hash(_: DialTargetContext, dial_target: DialTarget) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(dial_target.transport);
        hasher.update(&.{0});
        hasher.update(dial_target.designator);
        return hasher.final();
    }

    pub fn eql(_: DialTargetContext, a: DialTarget, b: DialTarget) bool {
        return a.eql(b);
    }
};

/// The Host-owned dial-target directory type. `pub` is cross-file visibility
/// for the aggregate field, not a consumer-root export.
pub const DialTargetMap = std.HashMapUnmanaged(
    DialTarget,
    engine.PeerHandle,
    DialTargetContext,
    std.hash_map.default_max_load_percentage,
);

/// The live, non-condemned session that already reaches `partner_designator`
/// (ADR-0012), or null. One authority two callers read: this host refuses a
/// duplicate app dial against a non-null result, and the node-action pump
/// reuses that session to redeem a give rather than dial a duplicate it would
/// then refuse. Match set: our dialed designator (bytes we chose), or a live
/// session whose partner proved that same *durable* key. Never the partner's
/// signing key, which every session draws fresh and which names an
/// incarnation rather than a peer.
///
/// A partner-declared `acceptable_location.designator`
/// on an address transport is never a match key: the hello signature proves
/// the claim, not ownership of a tcp `host:port`, so trusting it would let an
/// inbound peer squat dial availability. Dedup against an accepted tcp session
/// still runs after the newcomer's start-session via `refuseDuplicatePartnerKey`
/// (verified key). An accepted session racing an in-flight dial stays legal
/// for crossed hellos until start-session (ADR-0068).
pub fn liveSessionForDial(self: *const Host, transport: []const u8, partner_designator: []const u8) HostError!?*HostSession {
    if (liveIndexedSession(self, self.dialed_by_target.get(target(transport, partner_designator)))) |session| return session;
    // The durable-peer directory, never the side index (ADR-0097): this
    // asks "which live session reaches peer P", and P is a durable
    // identity. Deriving a side name from P instead would be asking the
    // session-incarnation directory a question it only answers while
    // every session reuses its host's key.
    if (try self.designatorScheme(transport) != .key) return null;
    const want = crypto.PeerKey.fromDesignator(partner_designator) orelse return null;
    return liveIndexedSession(self, self.peer_by_durable.get(want.bytes));
}

/// Refuse a new dial when a live session already reaches this partner.
pub fn refuseDuplicateDial(self: *const Host, transport: []const u8, partner_designator: []const u8) HostError!void {
    if (try liveSessionForDial(self, transport, partner_designator) != null) return error.SessionPairExists;
}

/// Refuse a new dial unless the caller is trying to prove a stricter durable
/// identity than the live concrete session currently proves. Identity-routed
/// pending dials may share a concrete route with an unverified session. The
/// demanded key, not the route string, is the authority the new session exists
/// to establish.
pub fn refuseDuplicateDialForDemand(
    self: *const Host,
    transport: []const u8,
    partner_designator: []const u8,
    demanded_partner_key: ?crypto.PeerKey,
) HostError!void {
    const existing = try liveSessionForDial(self, transport, partner_designator) orelse return;
    const demanded = demanded_partner_key orelse return HostError.SessionPairExists;
    const demanded_designator = demanded.toDesignator();
    if (existing.served.port.peer.partnerDurableProvenance(demanded_designator[0..]) != .authenticated_transport)
        return;
    return error.SessionPairExists;
}

/// After crossed-hellos tiebreak, keep at most one non-condemned session to
/// the same CapTP partner key (dual-accept settlement, or a dial that
/// slipped past pre-identity refuse). Survivor choice follows the ADR-0068
/// / crossed-hellos key order (`CrossedHellos.checkInbound`): both peers
/// independently keep the session the higher-keyed peer opened (dialed
/// when we are higher, accepted when we are lower), so a crossed pair that
/// missed the designator tiebreak still collapses to the same session
/// on both ends rather than condemning by local arrival order. Same-role
/// duplicates (dual-accept) keep the already-indexed session and condemn
/// the newcomer.
pub const DuplicatePartnerError = error{SessionPairExists} ||
    foundation.error_sets.Of(crypto.PeerKey.fromSlice) ||
    IndexPartnerKeyError ||
    host_pump.CondemnError;

pub fn refuseDuplicatePartnerKey(self: *Host, session: *HostSession, ss: model.view.StartSession) DuplicatePartnerError!void {
    if (session.isTerminating()) return;
    // With signature verification disabled, `session_pubkey` is only a
    // partner assertion. It cannot identify a peer for deduplication or
    // authorize early handoff verification.
    if (!session.served.port.peer.verify_partner_handshake) return;
    const partner_key = try crypto.PeerKey.fromSlice(ss.session_pubkey);
    const side = engine.handoff_names.sideNameForKey(partner_key);
    // Two questions, and only the second identifies a *peer* once each
    // session draws its own key (ADR-0097). A matching session key means
    // the same session incarnation, which is a duplicate of the narrowest
    // kind. A matching proved durable identity means the same peer reached
    // twice, which is the duplicate ADR-0068 exists to collapse. It is
    // the only one that survives fresh keys, because two sessions with one
    // peer no longer share a session key.
    //
    // Only a *proved* durable identity counts: `peer_by_durable` indexes
    // nothing else, so a partner that merely asserts a name cannot use this
    // to condemn a session, which is the same refusal `liveSessionForDial`
    // makes. A transport that proves no durable identity therefore has no
    // collapse here, and the crossed-hellos declared-location match remains
    // its only one, with the weakness ADR-0030 already states.
    const durable_dup: ?engine.PeerHandle = if (durablePeerKeyFor(session, ss.acceptable_location.designator)) |claimed|
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
    // match spans different session keys, so it skips the
    // check that would reject the very case it exists to catch.
    if (durable_dup == null and (other.indexed_partner_key == null or
        !std.mem.eql(u8, &other.indexed_partner_key.?, &partner_key.bytes)))
    {
        // A side-name collision is not partner-key equality. Refuse the
        // newcomer rather than replacing an unrelated live index row.
        return error.SessionPairExists;
    }

    // Ordered by the two *session* identities, as crossed hellos are
    // (ADR-0097): ours on this session against the partner's on it. The
    // durable keys are equal on both racing connection attempts by definition, so
    // they cannot order anything.
    const our_pid = crypto.derivePublicIdentifier(session.sessionPublicKey());
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

/// Index a live session under its verified session key and, when proved, its
/// durable key. Both maps reserve before either publishes, so allocation
/// failure leaves no partial identity authority.
pub const IndexPartnerKeyError = std.mem.Allocator.Error;

pub fn indexPartnerKey(self: *Host, session: *HostSession, key: [crypto.peer_key_bytes]u8, designator: []const u8) IndexPartnerKeyError!void {
    const side = engine.handoff_names.sideNameForKey(.fromBytes(key));
    const durable_key = durablePeerKeyFor(session, designator);
    try self.partner_by_side.ensureUnusedCapacity(self.allocator, 1);
    if (durable_key != null)
        try self.peer_by_durable.ensureUnusedCapacity(self.allocator, 1);

    self.partner_by_side.putAssumeCapacity(side, session.peer_handle);
    if (durable_key) |durable|
        self.peer_by_durable.putAssumeCapacity(durable, session.peer_handle);
    session.indexed_partner_key = key;
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
/// post-apply teardown can pass the session's own retained bytes. Both
/// reach the identical row because a session's claim is written once.
pub fn durablePeerKeyFor(session: *const HostSession, designator: []const u8) ?[crypto.peer_key_bytes]u8 {
    const peer = session.served.port.peer;
    if (!peer.verify_partner_handshake) return null;
    if (Host.durableProvenance(peer, designator) == .unauthenticated) return null;
    const key = crypto.PeerKey.fromDesignator(designator) orelse return null;
    return key.bytes;
}

/// Drop this session from the partner-identity and dialed-designator indexes.
/// Idempotent: safe when the session was never indexed.
pub fn unindexSession(self: *Host, session: *HostSession) void {
    if (session.indexed_partner_key) |key| {
        const side = engine.handoff_names.sideNameForKey(.fromBytes(key));
        if (self.partner_by_side.get(side)) |pid| {
            if (pid == session.peer_handle) {
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
            if (pid == session.peer_handle) {
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
            if (pid == session.peer_handle) {
                // tolerant: a prior unindex may already have removed it.
                _ = self.dialed_by_target.remove(dial_target);
            }
        }
    }
}

pub fn liveIndexedSession(self: *const Host, peer_handle: ?engine.PeerHandle) ?*HostSession {
    const pid = peer_handle orelse return null;
    const session = self.sessions.get(pid) orelse return null;
    if (session.lifecyclePhase().condemned()) return null;
    return session;
}

/// The live dialed session whose selected peer matches `(transport,
/// designator)`, for Host-level select-or-dial (ADR-0098 step 4). Dialed
/// sessions only: an accepted address session cannot prove its claimed
/// designator, and the enliven path re-verifies whatever this returns
/// through the complete sturdyref peer check.
pub fn dialedSessionFor(self: *Host, transport: []const u8, designator: []const u8) ?*HostSession {
    self.assertOwner();
    const peer_handle = self.dialed_by_target.get(target(transport, designator)) orelse return null;
    const session = self.sessions.get(peer_handle) orelse return null;
    if (session.lifecyclePhase() != .active) return null;
    return session;
}

pub fn target(transport: []const u8, designator: []const u8) DialTarget {
    return .{ .transport = transport, .designator = designator };
}
