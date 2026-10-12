//! Sturdyref enlivenment for the byte-fed host core: turning a complete
//! sturdyref (ADR-0098) into a live capability, and the select-or-dial form
//! (ADR-0098) that stages a dial first when no session to the peer is open yet.
//!
//! Host owns parked rows, vows, and dial actions. Enlivenment selects its
//! completion recipient before admission: ordinary APIs queue public outcomes,
//! while `enlivenCapability` retains an owned result outside the action FIFO.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_action = @import("host/action.zig");
const host_pump = @import("host/pump.zig");
const vows_mod = @import("vows.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const PeerProvenance = host_mod.PeerProvenance;
const fetch_groups = @import("enliven/group.zig");
const identity = @import("enliven/identity.zig");
const observation = @import("enliven/observation.zig");
pub const Enliven = observation.Enliven;
const Recipient = observation.Recipient;
const WorkAdmission = @import("host/admission.zig").WorkAdmission;

pub const EnlivenPeerPolicy = identity.EnlivenPeerPolicy;

pub const EnlivenStart = struct {
    vow_id: u64,
    provenance: PeerProvenance,
};

/// One enliven parked before a session exists. The recipient either receives
/// a public action under the pre-minted vow ID or an owned completion. Host
/// owns the complete sturdyref bytes until continuation or cancellation.
pub const PendingEnliven = struct {
    vow_id: u64,
    sturdyref: model.SturdyRef,
    recipient: Recipient = .action,
};

pub const PendingEnlivenGroup = struct {
    first: PendingEnliven,
    rest: std.ArrayListUnmanaged(PendingEnliven) = .empty,
};

pub const PendingEnlivenMap = std.AutoHashMapUnmanaged(engine.Node.PendingId, PendingEnlivenGroup);

pub const PendingEnlivenOutcome = union(enum) {
    opened: struct {
        session: *HostSession,
        provenance: PeerProvenance,
    },
    failed: []const u8,
};

pub const matchSturdyrefPeer = identity.matchSturdyrefPeer;

/// Enliven the complete sturdyref (ADR-0098), minting a host vow for the live
/// reference. A dedup-cache hit settles the vow before this returns, with its
/// completion already on the action queue. A fresh enliven rides
/// bootstrap-fetch, the host recording the enlivenment itself when the
/// resolution arrives, before the outcome is dispatched. Top-level: refused
/// from inside a callback.
pub fn enliven(self: *Host, session: *HostSession, sturdyref: model.SturdyRef) !u64 {
    return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
}

/// Parse and enliven a session-scoped canonical persistent sturdyref URI.
/// Durable authority is application data rather than a rendering of the live
/// session's negotiated profile. Adapters pass bytes and choose no parser.
pub fn enlivenSessionUri(self: *Host, session: *HostSession, uri: []const u8) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    const sturdyref = try model.uri.parseSturdyref(self.allocator, uri);
    defer model.uri.freeSturdyref(self.allocator, sturdyref);
    return self.enliven(session, sturdyref);
}

/// Select-or-dial enlivenment for a byte-fed embedder (ADR-0098): enliven
/// `sturdyref` over a live dialed session to its peer, or stage a dial through
/// the ordinary `dial` action and finish when the embedder reports it
/// (`exporterDialed` / `dialFailed`), reusing the node's one pending-dial
/// ticket space so the embedder's dial arm never learns a second namespace.
///
/// The returned vow id is minted before any session may exist, so a parked
/// outcome always arrives as that id's `settled` / `failed` action. `vowOn`
/// refuses a parked id (`NoSuchVow`) as it refuses an already-settled one. Peer
/// policy is `.checked`. The accepted-address escape hatch stays on the
/// session-scoped `enlivenWithPolicy`.
pub fn enlivenSelectOrDial(self: *Host, sturdyref: model.SturdyRef) !u64 {
    return selectOrDial(self, sturdyref, .action, .application);
}

/// An owned observation of checked enlivenment. Its result never enters the
/// embedder's action FIFO. The caller's allocator owns this operation. Destroy
/// it before Host destruction. Cancellation detaches observation synchronously.
pub fn enlivenCapability(self: *Host, allocator: std.mem.Allocator, sturdyref: model.SturdyRef) !*Enliven {
    return enlivenAdmitted(self, allocator, sturdyref, .application);
}

/// Internal shared constructor. Retained admission borrows a live parent only
/// until the ordinary parked row or session vow owns the committed work.
pub fn enlivenAdmitted(self: *Host, allocator: std.mem.Allocator, sturdyref: model.SturdyRef, admission: WorkAdmission) !*Enliven {
    try self.refuseReentry();
    try admission.check(self);
    const owned = try allocator.create(Enliven);
    errdefer allocator.destroy(owned);
    owned.* = .{ .host = self, .allocator = allocator };
    _ = try selectOrDial(self, sturdyref, .{ .observed = owned }, admission);
    return owned;
}

fn selectOrDial(self: *Host, sturdyref: model.SturdyRef, recipient: Recipient, admission: WorkAdmission) !u64 {
    try self.refuseReentry();
    try admission.check(self);
    try vows_mod.ensureFreshVowId(self);
    const own_key = self.node.publicKey();
    var prepared = if (std.mem.eql(u8, sturdyref.peer.transport, model.transport.id)) id_route: {
        if (!hostAcceptsRouteVocabulary(self)) return HostError.PeerIdentityMismatch;
        const demanded = self.node.validateIdRouteLocator(sturdyref.peer) catch
            return HostError.PeerIdentityMismatch;
        if (std.mem.eql(u8, &demanded.bytes, &own_key.bytes))
            return @import("publication_lookup.zig").resolveLocal(self, sturdyref.swissnum, recipient, admission);
        if (authenticatedSessionForKey(self, demanded)) |session|
            return (try withRecipient(self, session, sturdyref, .checked, recipient, admission)).vow_id;
        var bundle = self.node.parseIdSturdyrefLocator(self.allocator, sturdyref.peer) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return HostError.PeerIdentityMismatch,
        };
        var bundle_owned = true;
        defer if (bundle_owned) bundle.deinit(self.allocator);
        bundle_owned = false;
        break :id_route self.node.prepareIdRouteBundle(bundle) catch |err| switch (err) {
            error.ConflictingDialPlan => return HostError.PeerIdentityMismatch,
            else => return err,
        };
    } else concrete: {
        if ((try self.designatorScheme(sturdyref.peer.transport)) == .key) {
            const own_designator = own_key.toDesignator();
            if (std.mem.eql(u8, sturdyref.peer.designator, &own_designator))
                return @import("publication_lookup.zig").resolveLocal(self, sturdyref.swissnum, recipient, admission);
        }
        if (self.dialedSessionFor(sturdyref.peer.transport, sturdyref.peer.designator)) |session|
            return (try withRecipient(self, session, sturdyref, .checked, recipient, admission)).vow_id;
        break :concrete self.node.prepareDialLocator(sturdyref.peer) catch |err| switch (err) {
            error.ConflictingDialPlan => return HostError.PeerIdentityMismatch,
            else => return err,
        };
    };
    defer prepared.deinit(&self.node);
    switch (prepared.view()) {
        .open => |peer_handle| {
            const session = self.sessions.get(peer_handle) orelse return HostError.SessionCondemned;
            const start = try withRecipient(self, session, sturdyref, .checked, recipient, admission);
            _ = prepared.commit(&self.node);
            return start.vow_id;
        },
        .pending => |ticket| {
            // Park under a pre-minted id. The sturdyref stays complete:
            // route-bundle validation is part of the later peer check, while
            // the dial's selected concrete path lives in the staged parts.
            if (self.pending_enlivens.getPtr(ticket)) |group| {
                try group.rest.ensureUnusedCapacity(self.allocator, 1);
            } else {
                try self.pending_enlivens.ensureUnusedCapacity(self.allocator, 1);
            }
            // One completion slot per parked enliven, reserved now, so the
            // continuation's settle can never fail to land.
            // This parked enliven's own settle, plus the dial action.
            try self.reserveActions(2);
            const peer = try model.clonePeerLocator(self.allocator, sturdyref.peer);
            errdefer model.freePeerLocator(self.allocator, peer);
            const swissnum = try self.allocator.dupe(u8, sturdyref.swissnum);
            const id = self.next_vow;
            self.next_vow += 1;
            const parked: PendingEnliven = .{
                .vow_id = id,
                .recipient = recipient,
                .sturdyref = .{
                    .peer = peer,
                    .swissnum = swissnum,
                },
            };
            const committed = prepared.commit(&self.node);
            std.debug.assert(committed == .pending and committed.pending == ticket);
            if (self.pending_enlivens.getPtr(ticket)) |group|
                group.rest.appendAssumeCapacity(parked)
            else
                self.pending_enlivens.putAssumeCapacity(ticket, .{ .first = parked });
            self.pending_enliven_count += 1;
            recipient.park(id, ticket);
            return id;
        },
    }
}

/// Parse and select-or-dial a canonical persistent sturdyref URI. Durable
/// authority is application data rather than a rendering of a session or Host
/// preference. Alternate wire spellings use `enlivenUriForVersion` explicitly.
pub fn enlivenUri(self: *Host, uri: []const u8) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const sturdyref = try model.uri.parseSturdyref(self.allocator, uri);
    defer model.uri.freeSturdyref(self.allocator, sturdyref);
    return self.enlivenSelectOrDial(sturdyref);
}

/// Parse and select-or-dial a sturdyref URI under an explicit CapTP profile.
/// This is for authority received on a session whose settled profile may differ
/// from the Host preference. Route selection still belongs to this Host.
pub fn enlivenUriForVersion(
    self: *Host,
    captp_version: model.CaptpVersion,
    uri: []const u8,
) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const sturdyref = try model.uri.parseSturdyrefForProfile(self.allocator, captp_version, uri);
    defer model.uri.freeSturdyref(self.allocator, sturdyref);
    return self.enlivenSelectOrDial(sturdyref);
}

pub const authenticatedSessionForKey = identity.authenticatedSessionForKey;
const hostAcceptsRouteVocabulary = identity.hostAcceptsRouteVocabulary;

pub fn freeParkedEnliven(self: *Host, parked: PendingEnliven) void {
    model.uri.freeSturdyref(self.allocator, parked.sturdyref);
}

/// Settle a parked enliven's vow broken. The message must be host-owned by the
/// action contract. A failed retain uses the action layer's static allocation
/// diagnostic rather than losing either the settle or its reason category.
pub fn failParkedEnliven(
    self: *Host,
    parked: PendingEnliven,
    session_peer: ?engine.PeerHandle,
    failure: host_action.VowFailure,
    reason: []const u8,
) void {
    if (parked.recipient == .observed) {
        parked.recipient.observed.fail(failure, reason);
        return;
    }
    const retained = host_action.retainFailureMessage(self.allocator, reason);
    self.actions.pushReserved(.{ .failed = .{
        .peer_handle = session_peer,
        .vow_id = parked.vow_id,
        .failure = failure,
        .message = retained,
    } });
}

/// Run one parked enliven against the session its ticket opened, settling
/// the pre-minted vow on every path: the dedup-cache hit settles now, a
/// wire-riding fetch bridges the parked id onto its answer, and a refusal
/// breaks the vow instead of escaping `exporterDialed`.
pub fn continueParkedEnliven(
    self: *Host,
    session: *HostSession,
    parked: PendingEnliven,
    provenance: PeerProvenance,
) void {
    const requires_verified_identity = std.mem.eql(
        u8,
        parked.sturdyref.peer.transport,
        model.transport.id,
    ) or (self.designatorScheme(parked.sturdyref.peer.transport) catch {
        failParkedEnliven(self, parked, session.peer_handle, .broken, @errorName(HostError.UnknownTransport));
        return;
    }) == .key;
    if (requires_verified_identity and provenance != .verified) {
        failParkedEnliven(self, parked, session.peer_handle, .broken, @errorName(HostError.PeerIdentityUnverified));
        return;
    }
    self.node.replaceDiscoveredExporterLocation(session.peer_handle, parked.sturdyref.peer) catch |err| {
        failParkedEnliven(self, parked, session.peer_handle, .broken, @errorName(err));
        return;
    };
    const err: anyerror = blk: {
        const peer = session.served.port.peer;
        const reservation = fetch_groups.reserve(self, session, parked.vow_id, parked.recipient, provenance) catch |e| break :blk e;
        var reservation_live = true;
        defer if (reservation_live) fetch_groups.cancel(self, session, reservation);
        const start = engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, parked.sturdyref.swissnum) catch |e| break :blk e;
        switch (start) {
            .cached => |reference| {
                fetch_groups.cancel(self, session, reservation);
                reservation_live = false;
                parked.recipient.cached(self, session, parked.vow_id, reference, provenance);
                return;
            },
            .in_flight => |answer| {
                if (!fetch_groups.hasProducer(self, session, answer)) break :blk actors.Error.AlreadyListening;
                _ = fetch_groups.commit(self, session, answer, reservation);
                reservation_live = false;
                return;
            },
            .fresh => |prepared| {
                peer.sendPreparedFetch(prepared) catch |e| {
                    peer.finishPendingEnliven(parked.sturdyref.swissnum);
                    break :blk e;
                };
                _ = fetch_groups.commit(self, session, prepared.answer_position, reservation);
                reservation_live = false;
                host_pump.markDirty(self, session.peer_handle);
                return;
            },
        }
    };
    failParkedEnliven(self, parked, session.peer_handle, .broken, @errorName(err));
}

/// Continue every enliven parked on `ticket`: run each against the opened
/// session (or break each with the dial's failure), then drop its row.
pub fn settleParkedEnlivens(
    self: *Host,
    ticket: engine.Node.PendingId,
    outcome: PendingEnlivenOutcome,
) void {
    var group = (self.pending_enlivens.fetchRemove(ticket) orelse return).value;
    const count = group.rest.items.len + 1;
    std.debug.assert(self.pending_enliven_count >= count);
    self.pending_enliven_count -= count;
    settleParkedEnliven(self, group.first, outcome);
    for (group.rest.items) |parked|
        settleParkedEnliven(self, parked, outcome);
    group.rest.deinit(self.allocator);
}

fn settleParkedEnliven(
    self: *Host,
    parked: PendingEnliven,
    outcome: PendingEnlivenOutcome,
) void {
    switch (outcome) {
        .opened => |opened| continueParkedEnliven(self, opened.session, parked, opened.provenance),
        .failed => |reason| failParkedEnliven(self, parked, null, .broken, reason),
    }
    freeParkedEnliven(self, parked);
}

/// Cancel every select-or-dial operation that has not reached a session. Each
/// pre-minted vow already reserved one completion seat, so cancellation cannot
/// strand an outcome under allocator pressure.
pub fn cancelParkedEnlivens(self: *Host, reason: []const u8) void {
    var groups = self.pending_enlivens.valueIterator();
    while (groups.next()) |group| {
        failParkedEnliven(self, group.first, null, .closed, reason);
        freeParkedEnliven(self, group.first);
        for (group.rest.items) |parked| {
            failParkedEnliven(self, parked, null, .closed, reason);
            freeParkedEnliven(self, parked);
        }
        self.pending_enliven_count -= 1 + group.rest.items.len;
        group.rest.deinit(self.allocator);
    }
    self.pending_enlivens.clearRetainingCapacity();
}

pub fn deinitParkedEnlivens(self: *Host) void {
    var groups = self.pending_enlivens.valueIterator();
    while (groups.next()) |group| {
        freeParkedEnliven(self, group.first);
        for (group.rest.items) |parked| freeParkedEnliven(self, parked);
        self.pending_enliven_count -= 1 + group.rest.items.len;
        group.rest.deinit(self.allocator);
    }
    self.pending_enlivens.deinit(self.allocator);
    std.debug.assert(self.enliven_groups.count() == 0);
    self.enliven_groups.deinit(self.allocator);
}

/// Low-level accepted-TCP escape hatch. The result reports whether a durable
/// identity was authenticated, the locator was selected as this side's dial
/// target, or the locator remains only a partner assertion. No caller can
/// silently collapse those cases.
pub fn enlivenWithPolicy(
    self: *Host,
    session: *HostSession,
    sturdyref: model.SturdyRef,
    policy: EnlivenPeerPolicy,
) !EnlivenStart {
    return withRecipient(self, session, sturdyref, policy, .action, .application);
}

fn withRecipient(self: *Host, session: *HostSession, sturdyref: model.SturdyRef, policy: EnlivenPeerPolicy, recipient: Recipient, admission: WorkAdmission) !EnlivenStart {
    try self.refuseReentry();
    try admission.check(self);
    try self.admitSessionOperation(session);
    const provenance = try matchSturdyrefPeer(self, session, sturdyref, policy);
    // The complete sturdyref is route advice already verified against this
    // session. Retain its canonical locator once for later three-party gives;
    // applications should not sample and restate the same route through a
    // second RPC and parser pass.
    try self.node.replaceDiscoveredExporterLocation(session.peer_handle, sturdyref.peer);
    const swissnum = sturdyref.swissnum;
    const peer = session.served.port.peer;
    // Admission precedes `prepareEnliven`: its fresh arm records the in-flight
    // marker and retains bootstrap authority, so refusing afterward would need
    // a protocol rollback. Cache hits are cheap but remain retryable under the
    // same application-verb contract rather than duplicating the core's dedup
    // decision at this adapter layer.
    try self.checkOutboundAdmission(session);
    // The peer check above fixes the namespace before this session-local
    // swiss cache is consulted or any bootstrap fetch can be emitted.
    try vows_mod.ensureFreshVowId(self);
    const reservation = try fetch_groups.reserve(self, session, self.next_vow, recipient, provenance);
    var reservation_live = true;
    errdefer if (reservation_live) fetch_groups.cancel(self, session, reservation);
    const start = try engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, swissnum);
    switch (start) {
        .cached => |reference| {
            // No pending producer remains. Retire the unused reservation
            // before delivering the cache observation to its recipient.
            const id = self.next_vow;
            fetch_groups.cancel(self, session, reservation);
            reservation_live = false;
            recipient.cached(self, session, id, reference, provenance);
            self.next_vow += 1;
            self.node.exporterApplicationOwned(session.peer_handle);
            host_pump.finishCommittedWork(self, session);
            return .{ .vow_id = id, .provenance = provenance };
        },
        .in_flight => |answer| {
            if (!fetch_groups.hasProducer(self, session, answer)) return actors.Error.AlreadyListening;
            const id = fetch_groups.commit(self, session, answer, reservation);
            reservation_live = false;
            self.next_vow += 1;
            self.node.exporterApplicationOwned(session.peer_handle);
            host_pump.finishCommittedVow(self, session);
            return .{ .vow_id = id, .provenance = provenance };
        },
        .fresh => |prepared| {
            peer.sendPreparedFetch(prepared) catch |err| {
                // The fresh enliven recorded an in-flight marker; clear it
                // so a failed send does not strand the swissnum.
                peer.finishPendingEnliven(swissnum);
                return err;
            };
            const id = fetch_groups.commit(self, session, prepared.answer_position, reservation);
            reservation_live = false;
            self.next_vow += 1;
            self.node.exporterApplicationOwned(session.peer_handle);
            host_pump.finishCommittedVow(self, session);
            return .{ .vow_id = id, .provenance = provenance };
        },
    }
}
