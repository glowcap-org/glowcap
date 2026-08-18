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

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_action = @import("host_action.zig");
const host_pump = @import("host_pump.zig");
const vocab = @import("vocab.zig");
const vows_mod = @import("vows.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const PeerProvenance = host_mod.PeerProvenance;
const asFarRef = host_mod.asFarRef;

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
    ticket: engine.Node.PendingId,
    vow_id: u64,
    sturdyref: model.SturdyRef,
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

const EnlivenVowReservation = struct {
    vow: vows_mod.VowReservation,
    bridge: *EnlivenListener,
};

fn reserveEnlivenVowAt(self: *Host, session: *HostSession, id: u64) !EnlivenVowReservation {
    const bridge = try self.allocator.create(EnlivenListener);
    errdefer self.allocator.destroy(bridge);
    return .{
        .vow = try self.reserveVowAt(session, .far, .plain, id),
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
        .peer_id = session.peer_id,
        .answer = answer,
        .vow_id = row.id,
    };
    return self.commitVowWithListener(
        session,
        reservation.vow,
        .{ .far = answer },
        .{ .ctx = reservation.bridge, .func = EnlivenListener.fire },
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

/// Enliven the complete sturdyref (ADR-0098), minting
/// a host vow for the live reference. A dedup-cache hit settles the vow
/// before this returns — its completion is already on the action queue —
/// and a fresh enliven rides bootstrap-fetch, the host recording the
/// enlivenment itself when the resolution arrives, before the outcome is
/// dispatched. Top-level: refused from inside a callback.
pub fn enliven(self: *Host, session: *HostSession, sturdyref: model.SturdyRef) !u64 {
    return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
}

/// Parse and enliven a session-scoped sturdyref URI under the negotiated
/// profile owned by that session. Adapters pass bytes and never select the
/// parser profile themselves.
pub fn enlivenSessionUri(self: *Host, session: *HostSession, uri: []const u8) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    const sturdyref = try model.uri.parseSturdyrefForProfile(self.allocator, session.captpVersion(), uri);
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
    if (self.dialedSessionFor(sturdyref.peer.transport, sturdyref.peer.designator)) |session| {
        return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
    }
    // The dial's authority is the staged parts, so the locator round-trips
    // through the same writer every give's exporter location uses; the
    // sturdyref arrived parsed, so this cannot re-introduce a parse hole.
    const locator = try model.uri.writePeer(self.allocator, sturdyref.peer);
    defer self.allocator.free(locator);
    switch (try self.node.stageDial(locator)) {
        .open => |peer_id| {
            const session = self.sessions.get(peer_id) orelse return HostError.SessionCondemned;
            return (try enlivenWithPolicy(self, session, sturdyref, .checked)).vow_id;
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

/// Parse and select-or-dial a sturdyref URI under this Host's preferred
/// profile. The Host owns both the parser choice and enliven admission;
/// adapters provide only the borrowed URI bytes.
pub fn enlivenUri(self: *Host, uri: []const u8) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    const sturdyref = try model.uri.parseSturdyrefForProfile(self.allocator, self.opts.captp_version, uri);
    defer model.uri.freeSturdyref(self.allocator, sturdyref);
    return self.enlivenSelectOrDial(sturdyref);
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
    session_peer: ?engine.PeerId,
    failure: host_action.VowFailure,
    reason: []const u8,
) void {
    const retained = host_action.retainFailureMessage(self.allocator, reason);
    self.actions.pushReserved(.{ .failed = .{
        .peer_id = session_peer,
        .vow_id = parked.vow_id,
        .failure = failure,
        .message = retained.bytes,
        .message_owned = retained.owned,
    } });
}

/// Run one parked enliven against the session its dial opened, settling
/// the pre-minted vow on every path: the dedup-cache hit settles now, a
/// wire-riding fetch bridges the parked id onto its answer, and any
/// refusal (the peer check included — the dial was staged before a
/// session existed to check against) breaks the vow instead of raising
/// out of the embedder's `exporterDialed` report.
pub fn continueParkedEnliven(self: *Host, session: *HostSession, parked: PendingEnliven) void {
    const err: anyerror = blk: {
        _ = matchSturdyrefPeer(self, session, parked.sturdyref, .checked) catch |e| break :blk e;
        const peer = session.served.port.peer;
        const reservation = reserveEnlivenVowAt(self, session, parked.vow_id) catch |e| break :blk e;
        var reservation_live = true;
        defer if (reservation_live) cancelEnlivenVow(self, reservation);
        const start = engine.sturdyref.prepareEnliven(peer.allocator, &peer.session_state, parked.sturdyref.swissnum) catch |e| break :blk e;
        switch (start) {
            .cached => |reference| {
                cancelEnlivenVow(self, reservation);
                reservation_live = false;
                self.actions.pushReserved(.{ .settled = .{ .peer_id = session.peer_id, .vow_id = parked.vow_id, .value = .{ .reference = reference } } });
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
                host_pump.markDirty(self, session.peer_id);
                return;
            },
        }
    };
    failParkedEnliven(self, parked, session.peer_id, .broken, @errorName(err));
}

/// Continue every enliven parked on `ticket`: run each against the opened
/// session (or break each with the dial's failure), then drop its row.
pub fn settleParkedEnlivens(self: *Host, ticket: engine.Node.PendingId, opened: ?*HostSession, fail_reason: []const u8) void {
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
            continueParkedEnliven(self, session, parked);
        } else {
            failParkedEnliven(self, parked, null, .broken, fail_reason);
        }
        freeParkedEnliven(self, parked);
    }
}

/// Cancel every select-or-dial operation that has not reached a session. Each
/// pre-minted vow already reserved one completion seat, so cancellation cannot
/// strand an outcome under allocator pressure.
pub fn cancelParkedEnlivens(self: *Host, reason: []const u8) void {
    while (self.pending_enlivens.pop()) |parked| {
        failParkedEnliven(self, parked, null, .closed, reason);
        freeParkedEnliven(self, parked);
    }
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
            self.actions.pushReserved(.{ .settled = .{ .peer_id = session.peer_id, .vow_id = id, .value = .{ .reference = reference } } });
            self.next_vow += 1;
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
            host_pump.finishCommittedVow(self, session);
            return .{ .vow_id = id, .provenance = provenance };
        },
    }
}
