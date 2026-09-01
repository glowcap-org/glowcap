//! Sturdyref enlivenment for the byte-fed host core: turning a complete
//! sturdyref (ADR-0098) into a live capability, and the select-or-dial form
//! (ADR-0098 step 4) that stages a dial first when no session to the peer is
//! open yet.
//!
//! This is one of `host.zig`'s responsibilities, kept beside it rather than in
//! it. The `Host` type still owns the state these read -- the parked rows, the
//! vow map, the action queue -- and still presents `enliven`,
//! `enlivenSelectOrDial`, and `enlivenWithPolicy` as its own verbs; what lives
//! here is the machinery behind them, which no other responsibility calls into.
//!
//! Splitting a Zig struct across files means the helpers this file calls back
//! into are `pub` on `Host` without being part of what an embedder should use.
//! They are marked where they are declared.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_action = @import("host/action.zig");
const host_pump = @import("host/pump.zig");
const vocab = @import("vocab.zig");
const vows_mod = @import("vows.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const PeerProvenance = host_mod.PeerProvenance;
const asFarRef = host_mod.asFarRef;
const crypto = foundation.crypto;

pub const EnlivenPeerPolicy = enum {
    /// Require an authenticated durable key designator or the exact address
    /// this side dialed. An accepted address-session assertion is refused.
    checked,
    /// Permit an accepted address transport's session-signed but unproved
    /// locator claim. The returned provenance remains explicit.
    assertion_only,
};

pub const EnlivenStart = struct {
    vow_id: u64,
    provenance: PeerProvenance,
};

/// One enliven parked on a staged dial (`Host.enlivenSelectOrDial`). The vow
/// id was minted before any session existed, so nothing in the core holds a
/// row for it: the outcome reaches the caller as that id's `settled` / `failed`
/// action, the same way a dedup-cache hit's does. The sturdyref bytes are
/// host-owned for the row's life because the asking call has long returned.
pub const PendingEnliven = struct {
    vow_id: u64,
    sturdyref: model.SturdyRef,
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

/// The host-owned one-shot behind a wire-riding `Host.enliven`: record the
/// enlivenment in the session's dedup cache (or clear the in-flight marker on
/// a break) before the outcome reaches the vow, then free itself. It holds the
/// answer's one vat listener slot; the vow row it settles routes the outcome
/// to `vowOn`'s listener or the action queue like any other settlement.
const EnlivenListener = struct {
    host: *Host,
    peer_handle: engine.PeerHandle,
    answer: model.AnswerPosition,
    vow_id: u64,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const bridge: *EnlivenListener = @ptrCast(@alignCast(ctx.?));
        const host = bridge.host;
        const vow_id = bridge.vow_id;
        defer host.allocator.destroy(bridge);
        // A session already released (this fire is its teardown break)
        // has no session to bookkeep; the vow still settles.
        if (host.sessions.get(bridge.peer_handle)) |session| {
            const peer = session.served.port.peer;
            if (peer.session_state.pendingEnlivenSwissnum(bridge.answer)) |swissnum| {
                if (if (resolution == .fulfilled) asFarRef(resolution.fulfilled) else null) |far| {
                    // The listener has already proved the fulfilled-far arm;
                    // keep that typed fact instead of round-tripping through
                    // the generic, fallible fetch-outcome decoder.
                    peer.session_state.settlePendingEnlivenIntoCache(swissnum, far);
                } else {
                    peer.finishPendingEnliven(swissnum);
                }
            }
        }
        host.fireVow(vow_id, resolution);
    }
};

fn cancelPendingEnliven(self: *Host, vow_id: u64, _: u64) void {
    const row = self.vows.get(vow_id) orelse unreachable;
    const session = self.sessions.get(row.peer_handle.?) orelse unreachable;
    const listener = session.served.port.takeListener(&self.vat, row.vow) orelse
        unreachable;
    std.debug.assert(listener.func == EnlivenListener.fire);
    const bridge: *EnlivenListener = @ptrCast(@alignCast(listener.ctx.?));
    std.debug.assert(bridge.vow_id == vow_id and bridge.peer_handle == session.peer_handle);
    if (session.served.port.peer.session_state.pendingEnlivenSwissnum(bridge.answer)) |swissnum|
        session.served.port.peer.finishPendingEnliven(swissnum);
    self.allocator.destroy(bridge);
}

const EnlivenVowReservation = struct {
    vow: vows_mod.VowReservation,
    bridge: *EnlivenListener,
};

fn reserveEnlivenVowAt(self: *Host, session: *HostSession, id: u64) !EnlivenVowReservation {
    const bridge = try self.allocator.create(EnlivenListener);
    errdefer self.allocator.destroy(bridge);
    return .{
        .vow = try self.reserveVowAt(session, .far, .plain, .peer_visible, id),
        .bridge = bridge,
    };
}

fn cancelEnlivenVow(self: *Host, reservation: EnlivenVowReservation) void {
    self.cancelVowReservation(reservation.vow);
    self.allocator.destroy(reservation.bridge);
}

fn commitEnlivenVow(
    self: *Host,
    session: *HostSession,
    answer: model.AnswerPosition,
    reservation: EnlivenVowReservation,
) u64 {
    const row = reservation.vow.row;
    reservation.bridge.* = .{
        .host = self,
        .peer_handle = session.peer_handle,
        .answer = answer,
        .vow_id = row.id,
    };
    return self.commitVowWithListener(
        session,
        reservation.vow,
        .{ .far = answer },
        .{ .ctx = reservation.bridge, .func = EnlivenListener.fire },
        .{ .infallible = .{ .owner = 0, .func = cancelPendingEnliven } },
    );
}

pub fn matchSturdyrefPeer(
    self: *Host,
    session: *HostSession,
    sturdyref: model.SturdyRef,
    policy: EnlivenPeerPolicy,
) !PeerProvenance {
    try self.checkSession(session);
    const locator = sturdyref.peer;
    if (std.mem.eql(u8, locator.transport, model.transport.id)) {
        if (!hostAcceptsRouteVocabulary(self)) return HostError.PeerIdentityMismatch;
        const demanded = self.node.validateIdRouteLocator(locator) catch
            return HostError.PeerIdentityMismatch;
        return matchIdSturdyrefPeer(session, demanded);
    }
    if (!std.mem.eql(u8, locator.transport, session.transport)) return HostError.PeerIdentityMismatch;

    if (try self.designatorScheme(session.transport) == .key) {
        const identity = try self.partnerIdentity(session);
        if (!std.mem.eql(u8, locator.designator, identity.designator)) return HostError.PeerIdentityMismatch;
        // The provenance-bearing predicate, not key equality (ADR-0097): this
        // needs a proved durable peer. The fresh session key verifies the hello;
        // only authenticated channel evidence proves the durable designator.
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

fn matchIdSturdyrefPeer(session: *HostSession, key: crypto.PeerKey) !PeerProvenance {
    const designator = key.toDesignator();
    if (session.served.port.peer.partnerDurableProvenance(designator[0..]) != .authenticated_transport)
        return HostError.PeerIdentityUnverified;
    return .verified;
}

/// Enliven the complete sturdyref (ADR-0098), minting
/// a host vow for the live reference. A dedup-cache hit settles the vow
/// before this returns — its completion is already on the action queue —
/// and a fresh enliven rides bootstrap-fetch, the host recording the
/// enlivenment itself when the resolution arrives, before the outcome is
/// dispatched. Top-level: refused from inside a callback.
pub fn enliven(self: *Host, session: *HostSession, sturdyref: model.SturdyRef) !u64 {
    return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
}

/// Parse and enliven a session-scoped canonical persistent sturdyref URI.
/// Durable authority is application data rather than a rendering of the live
/// session's negotiated profile; adapters pass bytes and choose no parser.
pub fn enlivenSessionUri(self: *Host, session: *HostSession, uri: []const u8) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    const sturdyref = try model.uri.parseSturdyref(self.allocator, uri);
    defer model.uri.freeSturdyref(self.allocator, sturdyref);
    return self.enliven(session, sturdyref);
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
    try self.admitApplicationOperation();
    try vows_mod.ensureFreshVowId(self);
    var prepared = if (std.mem.eql(u8, sturdyref.peer.transport, model.transport.id)) id_route: {
        if (!hostAcceptsRouteVocabulary(self)) return HostError.PeerIdentityMismatch;
        const demanded = self.node.validateIdRouteLocator(sturdyref.peer) catch
            return HostError.PeerIdentityMismatch;
        if (authenticatedSessionForKey(self, demanded)) |session|
            return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
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
    } else if (self.dialedSessionFor(sturdyref.peer.transport, sturdyref.peer.designator)) |session| {
        return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
    } else self.node.prepareDialLocator(sturdyref.peer) catch |err| switch (err) {
        error.ConflictingDialPlan => return HostError.PeerIdentityMismatch,
        else => return err,
    };
    defer prepared.deinit(&self.node);
    switch (prepared.view()) {
        .open => |peer_handle| {
            const session = self.sessions.get(peer_handle) orelse return HostError.SessionCondemned;
            const start = try enlivenWithPolicy(self, session, sturdyref, .checked);
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
            return id;
        },
    }
}

/// Parse and select-or-dial a canonical persistent sturdyref URI. Durable
/// authority is application data rather than a rendering of a session or Host
/// preference; alternate wire spellings use `enlivenUriForVersion` explicitly.
pub fn enlivenUri(self: *Host, uri: []const u8) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const sturdyref = try model.uri.parseSturdyref(self.allocator, uri);
    defer model.uri.freeSturdyref(self.allocator, sturdyref);
    return self.enlivenSelectOrDial(sturdyref);
}

/// Parse and select-or-dial a sturdyref URI under an explicit CapTP profile.
/// This is for authority received on a session whose settled profile may differ
/// from the Host preference; route selection still belongs to this Host.
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

fn hostAcceptsRouteVocabulary(self: *const Host) bool {
    return self.opts.captp_version == .next and self.opts.features.multi_location;
}

pub fn authenticatedSessionForKey(self: *const Host, key: foundation.crypto.PeerKey) ?*HostSession {
    const session = self.sessions.get(self.peer_by_durable.get(key.bytes) orelse return null) orelse return null;
    if (session.lifecyclePhase() != .active) return null;
    const designator = key.toDesignator();
    if (session.served.port.peer.partnerDurableProvenance(designator[0..]) != .authenticated_transport)
        return null;
    return session;
}

pub fn freeParkedEnliven(self: *Host, parked: PendingEnliven) void {
    model.uri.freeSturdyref(self.allocator, parked.sturdyref);
}

/// Settle a parked enliven's vow broken. The message must be host-owned by the
/// action contract; a failed retain uses the action layer's static allocation
/// diagnostic rather than losing either the settle or its reason category.
pub fn failParkedEnliven(
    self: *Host,
    parked: PendingEnliven,
    session_peer: ?engine.PeerHandle,
    failure: host_action.VowFailure,
    reason: []const u8,
) void {
    const retained = host_action.retainFailureMessage(self.allocator, reason);
    self.actions.pushReserved(.{ .failed = .{
        .peer_handle = session_peer,
        .vow_id = parked.vow_id,
        .failure = failure,
        .message = retained.bytes,
        .message_owned = retained.owned,
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
        const reservation = reserveEnlivenVowAt(self, session, parked.vow_id) catch |e| break :blk e;
        var reservation_live = true;
        defer if (reservation_live) cancelEnlivenVow(self, reservation);
        const start = engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, parked.sturdyref.swissnum) catch |e| break :blk e;
        switch (start) {
            .cached => |reference| {
                cancelEnlivenVow(self, reservation);
                reservation_live = false;
                self.actions.pushReserved(.{ .settled = .{ .peer_handle = session.peer_handle, .vow_id = parked.vow_id, .value = .{ .reference = reference } } });
                return;
            },
            .in_flight => break :blk actors.Error.AlreadyListening,
            .fresh => |prepared| {
                peer.sendPreparedFetch(prepared) catch |e| {
                    peer.finishPendingEnliven(parked.sturdyref.swissnum);
                    break :blk e;
                };
                _ = commitEnlivenVow(self, session, prepared.answer_position, reservation);
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
        group.rest.deinit(self.allocator);
    }
    self.pending_enlivens.clearRetainingCapacity();
    self.pending_enliven_count = 0;
}

pub fn deinitParkedEnlivens(self: *Host) void {
    var groups = self.pending_enlivens.valueIterator();
    while (groups.next()) |group| {
        freeParkedEnliven(self, group.first);
        for (group.rest.items) |parked| freeParkedEnliven(self, parked);
        group.rest.deinit(self.allocator);
    }
    self.pending_enlivens.deinit(self.allocator);
    self.pending_enliven_count = 0;
}

/// Low-level accepted-TCP escape hatch. The result reports whether a durable
/// identity was authenticated, the locator was selected as this side's dial
/// target, or the locator remains only a partner assertion; no caller can
/// silently collapse those cases.
pub fn enlivenWithPolicy(
    self: *Host,
    session: *HostSession,
    sturdyref: model.SturdyRef,
    policy: EnlivenPeerPolicy,
) !EnlivenStart {
    try self.refuseReentry();
    try self.admitApplicationOperation();
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
    const reservation = try reserveEnlivenVowAt(self, session, self.next_vow);
    var reservation_live = true;
    errdefer if (reservation_live) cancelEnlivenVow(self, reservation);
    const start = try engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, swissnum);
    switch (start) {
        .cached => |reference| {
            // Already settled: queue the completion for a fresh id and
            // never build a row, so the id refuses `NoSuchVow` exactly
            // like any other settled vow.
            const id = self.next_vow;
            cancelEnlivenVow(self, reservation);
            reservation_live = false;
            self.actions.pushReserved(.{ .settled = .{ .peer_handle = session.peer_handle, .vow_id = id, .value = .{ .reference = reference } } });
            self.next_vow += 1;
            self.node.exporterApplicationOwned(session.peer_handle);
            host_pump.finishCommittedWork(self, session);
            return .{ .vow_id = id, .provenance = provenance };
        },
        // An enliven already in flight holds the one listener slot on its
        // answer, so a concurrent duplicate is refused `AlreadyListening`
        // rather than parked where it could never fire.
        .in_flight => return actors.Error.AlreadyListening,
        .fresh => |prepared| {
            peer.sendPreparedFetch(prepared) catch |err| {
                // The fresh enliven recorded an in-flight marker; clear it
                // so a failed send does not strand the swissnum.
                peer.finishPendingEnliven(swissnum);
                return err;
            };
            const id = commitEnlivenVow(self, session, prepared.answer_position, reservation);
            reservation_live = false;
            self.next_vow += 1;
            self.node.exporterApplicationOwned(session.peer_handle);
            host_pump.finishCommittedVow(self, session);
            return .{ .vow_id = id, .provenance = provenance };
        },
    }
}
