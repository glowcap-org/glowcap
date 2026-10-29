//! Host encode/action pump: dirty-session encode work, node-action execution,
//! and terminal session retirement. Free functions take `*Host` so `host.zig`
//! stays the type home.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const actors = @import("actors");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const host_close = @import("close.zig");
const pump_schedule = @import("pump/schedule.zig");
const pending_dial_identity = @import("../pending_dial_identity.zig");
const capability_promise = @import("../capability_promise.zig");
const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

pub const markDirty = pump_schedule.markDirty;
pub const scheduleDeferredSessionWork = pump_schedule.scheduleDeferredSessionWork;
pub const scheduleFeedResume = pump_schedule.scheduleFeedResume;
pub const hasInternalWork = pump_schedule.hasInternalWork;
pub const removeDirtySession = pump_schedule.removeDirtySession;
pub const flushHeldReleases = pump_schedule.flushHeldReleases;
pub const removeHeldReleases = pump_schedule.removeHeldReleases;
pub const removeFreshSessionActions = pump_schedule.removeFreshSessionActions;
pub const queueHostAction = pump_schedule.queueHostAction;
pub const UniqueSessionActionTag = pump_schedule.UniqueSessionActionTag;
const queueUniqueSessionAction = pump_schedule.queueUniqueSessionAction;

/// The tail of every top-level verb: encode and pump until quiescent. A nested
/// verb returns immediately. A Host callback or Zig Vat execution owns that
/// boundary. The next top-level Host tail picks up queued effects.
pub fn finishVerb(self: *Host) !void {
    if (self.withinCallback()) return;
    const hold = self.callback_latch.hold();
    defer hold.release();
    if (self.lifecyclePhase() == .terminating) {
        // Establish the terminal verdict before driving work, so queued
        // application turns are cancelled with their ingress instead of being
        // mistaken for finish work. Keep driving on later calls as well: a
        // finite Host quantum may leave terminal work for another slice.
        _ = host_close.advanceCloseLifecycle(self);
        try drainWork(self);
        _ = host_close.advanceCloseLifecycle(self);
        return;
    }
    try drainWork(self);
    if (host_close.advanceCloseLifecycle(self)) {
        // Terminal aborts were staged after the ordinary work drain. Encode
        // them now so their FLUSH actions precede CLOSE for every session.
        try drainWork(self);
        _ = host_close.advanceCloseLifecycle(self);
    }
}

/// Alternate the two work queues to quiescence: encode every dirty session
/// (queueing its flush action), then execute every node serve-step action.
/// Either side can feed the other (a settle listener's nested send dirties a
/// session, an encoded withdraw queues a claim's actions), so the loop runs
/// until neither moves.
///
/// Attribution under a `local_turn_budget`: a budget breach here belongs to the
/// session whose vat amplified, never to the verb that fed the pump, because
/// the fed session's work may have flooded a *sibling*. The flooded session is
/// condemned (typed `resource_exhausted` abort) and a `close` action names it
/// for the embedder. The verb that ran this pump succeeds. A budget breach
/// inside the fed session's own dispatch (`feed`'s latched `feedBorrowed`)
/// never reaches here: it keeps `failDispatch` semantics and fails that feed.
fn drainWork(self: *Host) !void {
    var remaining = self.opts.host_work_quantum;
    work: while (remaining != 0) {
        var lanes_checked: u3 = 0;
        while (lanes_checked < 4) : (lanes_checked += 1) {
            const lane = self.next_work_lane;
            self.next_work_lane = lane.next();
            switch (lane) {
                .session => if (pump_schedule.takeDirty(self)) |peer_handle| {
                    remaining -= 1;
                    const session = self.sessions.get(peer_handle) orelse continue :work;
                    if (session.lifecyclePhase() == .cancel_pending) {
                        try condemn(self, session, .normal_shutdown, "session closing");
                        continue :work;
                    }
                    if (session.isTerminating()) {
                        // A condemned Port's ingress is never driven again; its queued
                        // turns died with the verdict. Encode the terminal abort and
                        // keep its close notification visible to the embedder.
                        session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
                        if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, peer_handle);
                        continue :work;
                    }
                    std.debug.assert(!session.isTerminating());
                    const progress = session.served.driveFedBudgeted(&self.vat) catch |err| switch (err) {
                        error.EventServeOutOfMemory => {
                            // The event was already removed from Peer.events before
                            // serveEvent failed; retrying would silently lose it.
                            // Condemn instead of replaying a partially applied event.
                            try condemn(self, session, .resource_exhausted, "event serve failed under memory pressure");
                            continue :work;
                        },
                        error.OutOfMemory => {
                            // No event was consumed at this boundary, or the failure
                            // occurred during resumable local driving/encoding.
                            markDirty(self, peer_handle);
                            return error.OutOfMemory;
                        },
                        error.OutboundBackpressure => {
                            markDirty(self, peer_handle);
                            return error.OutboundBackpressure;
                        },
                        error.LocalTurnLimitExceeded => {
                            // Latch the cause so the embedder's CLOSE carries why.
                            session.served.port.peer.recordFailure(err);
                            try condemn(self, session, .resource_exhausted, "local turn budget exceeded");
                            continue :work;
                        },
                        else => {
                            if (session.served.port.peer.lastAbort() == null)
                                session.served.port.peer.emitFailure(err);
                            return err;
                        },
                    };
                    if (session.served.port.peer.holdsAnswerReleases()) pump_schedule.holdReleases(self, session);
                    if (progress == .more_pending) {
                        // The Host quantum is only a scheduler slice. Per-session
                        // amplification has its own resumable counter in `Served` and
                        // reports `LocalTurnLimitExceeded` above.
                        markDirty(self, peer_handle);
                        queueUniqueSessionAction(self, .flush, peer_handle);
                    }
                    if (progress == .drained and session.lifecyclePhase() == .finishing and
                        session.pendingOperations() == 0)
                    {
                        try condemn(self, session, .graceful_shutdown, "session closing");
                        continue :work;
                    }
                    if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, peer_handle);
                    continue :work;
                },
                .local => if (self.vat.local_ingress.pending_turns != 0) {
                    remaining -= 1;
                    if (!self.lifecyclePhase().serving()) {
                        @import("local_delivery.zig").cancel(self);
                    } else {
                        _ = try self.vat.driveIngressBudgeted(.local, 1);
                    }
                    continue :work;
                },
                .node => if (try drainNodeAction(self)) {
                    remaining -= 1;
                    continue :work;
                },
                .handoff => if (drainHandoffChange(self)) {
                    remaining -= 1;
                    continue :work;
                },
            }
        }
        return;
    }
    // The quantum is a yield point. Preserve liveness even when the exhausted
    // work was entirely Node-owned and therefore produced neither a session
    // flush nor an embedder effect.
    if (hasInternalWork(self)) try pump_schedule.queueResumeAction(self);
}

/// What executing one Node action concluded. A settle or break that could not
/// reach its recipient because that session's outbound is full is not done
/// and not failed: it parks on that recipient until its bytes move.
pub const ActionOutcome = union(enum) {
    done,
    parked_on: engine.PeerHandle,
};

fn drainNodeAction(self: *Host) !bool {
    if (!self.node.hasAction()) return false;
    // Reserve the largest Host-side consequence, then execute through the
    // Node's peek/commit seam. A fulfilled settle may still need a fallible
    // Vat clone; if it fails, the action remains at the queue head.
    try self.reserveActions(1);
    const action = self.node.peekAction().?;
    switch (try execNodeAction(self, action)) {
        .done => try self.node.consumePeekedAction(),
        .parked_on => |recipient| try parkNodeAction(self, recipient),
    }
    return true;
}

/// Move the peeked Node action off the shared queue into `recipient`'s parked
/// row (ADR-0017): the recipient's outbound pressure is that partner's flow
/// control, and the queue behind it belongs to other sessions. Every fallible
/// step precedes the take, including the queue seat the action returns to, so
/// a refusal here leaves the action at the queue head and this pass ends on
/// the pressure as before, while the return never allocates.
fn parkNodeAction(self: *Host, recipient: engine.PeerHandle) !void {
    const gop = try self.parked_node_actions.getOrPut(self.allocator, recipient);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    errdefer if (!gop.found_existing) {
        gop.value_ptr.deinit(self.allocator);
        std.debug.assert(self.parked_node_actions.remove(recipient));
    };
    try gop.value_ptr.ensureUnusedCapacity(self.allocator, 1);
    gop.value_ptr.appendAssumeCapacity(try self.node.parkPeekedAction());
}

/// Return `recipient`'s parked Node actions to the queue, in the order they
/// parked, on the seats their parking reserved. Called when the embedder
/// takes that recipient's outbound bytes, the one event that can have moved
/// its pressure, and when the recipient's session is released: a parked
/// deferred settle also owes projections to other sessions, and an action
/// bound only for the released recipient finds no session and is consumed.
pub fn requeueParkedNodeActions(self: *Host, recipient: engine.PeerHandle) void {
    var row = (self.parked_node_actions.fetchRemove(recipient) orelse return).value;
    for (row.items) |action| self.node.pushParked(action);
    row.deinit(self.allocator);
}

/// Free every parked row at Host teardown, when nothing will run again.
pub fn deinitParkedNodeActions(self: *Host) void {
    var rows = self.parked_node_actions.valueIterator();
    while (rows.next()) |row| {
        for (row.items) |action| self.node.freeParked(action);
        row.deinit(self.allocator);
    }
    self.parked_node_actions.deinit(self.allocator);
}

fn drainHandoffChange(self: *Host) bool {
    const dependency = self.node.nextHandoffChange() orelse return false;
    var waiters = self.node.handoffWaiters(dependency);
    while (waiters.next()) |receiver| {
        const session = self.sessions.get(receiver) orelse continue;
        if (session.isTerminating()) continue;
        session.served.port.peer.noteHandoffChange(dependency);
        markDirty(self, receiver);
    }
    self.node.consumeHandoffChange(dependency);
    return true;
}

/// The non-blocking executor of node serve-step actions: settles and fails fire
/// the recipient vat's listener directly (`Vat.settleFar`). Dials and gift-id
/// draws are host effects, queued for the embedder. Flushes mark the session
/// dirty so the encode loop drives it.
fn execNodeAction(self: *Host, action: engine.Node.Action) !ActionOutcome {
    switch (action) {
        .dial => |d| {
            // Attempt-only action: pending row owns URI + parsed parts.
            // Unparseable gives never reach a dial action (acceptGive fails
            // them). Pre-flight reuses an already-open Host session the Node
            // identity cache may have missed (earlier app dial, accepted status-allow: event or source ordering
            // inbound hello). ADR-0007 session-pair uniqueness would refuse a
            // duplicate dial and break the redeem.
            const view = self.node.pendingDial(d.pending, d.route_index) orelse return .done;
            const locator = view.locator;
            const existing = if (view.demanded_partner_key) |key|
                self.authenticatedSessionForKey(key)
            else
                try self.liveSessionForDial(locator.transport, locator.designator);
            if (existing) |session| {
                if (session.lifecyclePhase() == .active and session.sessionOpen() and
                    pending_dial_identity.selectedSessionSatisfies(self, d.pending, d.route_index, session))
                {
                    if (!self.node.beginDialEffect(d.pending, d.route_index)) return .done;
                    const adopted = self.completeSelectedExporter(
                        d.pending,
                        d.route_index,
                        session,
                    ) catch |err| {
                        self.node.rollbackDialEffect(d.pending, d.route_index);
                        return err;
                    };
                    if (!adopted)
                        self.node.rollbackDialEffect(d.pending, d.route_index);
                    return .done;
                }
            }
            try pump_schedule.queueHostAction(self, .{ .dial = .{
                .ticket = d.pending,
                .route_index = d.route_index,
            } });
        },
        .cancel_dial => |d| try pump_schedule.queueHostAction(self, .{ .cancel_dial = .{
            .ticket = d.pending,
            .route_index = d.route_index,
        } }),
        .flush => |peer_handle| markDirty(self, peer_handle),
        .settle => |s| {
            switch (s.dest) {
                .answer => |answer| {
                    const session = self.sessions.get(answer.recipient_peer) orelse return .done;
                    try session.served.port.settleFar(
                        &self.vat,
                        answer.answer,
                        .{ .fulfilled = .{ .reference = .{ .routed = .{ .id = s.route_id } } } },
                    );
                    markDirty(self, answer.recipient_peer);
                },
                .deferred => |deferred| return capability_promise.fulfill(
                    self,
                    @fromBackingInt(@intCast(deferred.id)),
                    s.route_id,
                ),
            }
        },
        .fail => |f| {
            switch (f.dest) {
                .answer => |answer| {
                    const session = self.sessions.get(answer.recipient_peer) orelse return .done;
                    try session.served.port.settleFar(&self.vat, answer.answer, .{ .broken = f.reason.bytes() });
                    markDirty(self, answer.recipient_peer);
                },
                .served_answer => |answer| {
                    const session = self.sessions.get(answer.recipient_peer) orelse return .done;
                    session.served.port.peer.sendAnswerTargetResolutionCopying(
                        answer.answer,
                        .{ .@"break" = .{ .message = f.reason.bytes() } },
                    ) catch |err| switch (err) {
                        error.OutboundBackpressure => return .{ .parked_on = answer.recipient_peer },
                        else => return err,
                    };
                    markDirty(self, answer.recipient_peer);
                },
                .deferred => |deferred| return capability_promise.breakPromise(
                    self,
                    @fromBackingInt(@intCast(deferred.id)),
                    f.reason.bytes(),
                ),
            }
        },
        .retire_exporter => |peer_handle| {
            if (!self.node.claimExporterRetirement(peer_handle)) return .done;
            const session = self.sessions.get(peer_handle) orelse return .done;
            try retireRedeemOnlyExporter(self, session);
        },
        .need_gift_id => |n| if (self.node.hasPendingGift(n.ticket))
            try pump_schedule.queueHostAction(self, .{ .need_gift_id = .{ .ticket = n.ticket } }),
        .release_capability => |raw| {
            const ref = self.capabilities.refForRaw(raw) orelse return .done;
            self.releaseCapabilityTerminal(ref, null);
        },
        .promise_settled => |id| return capability_promise.finishSettlement(self, @fromBackingInt(@intCast(id))),
    }
    return .done;
}

/// The one dispatch-failure arm under every feed verb: the peer has
/// already projected a typed op:abort, so the session's admission-reserved
/// flush notification is queued for the embedder and the dispatch error
/// passes through.
pub fn failDispatch(self: *Host, peer_handle: engine.PeerHandle, err: anytype) @TypeOf(err) {
    queueUniqueSessionAction(self, .flush, peer_handle);
    return err;
}

pub const testing = pump_schedule.testing;

/// Whole-frame inbound spine: latch, body, fail projection, finishDispatch.
pub fn dispatchUnderLatch(self: *Host, session: *HostSession, body: anytype) !void {
    try self.refuseReentry();
    try self.checkSession(session);
    {
        const hold = self.callback_latch.hold();
        defer {
            if (session.sessionOpen()) self.finishSessionOpen(session);
            hold.release();
        }
        body.call() catch |err| if (!condemnedByDispatch(session, err)) {
            if (session.sessionClosed()) {
                if (session.served.partnerAbort() != null) {
                    // A partner abort is the successful terminal outcome of
                    // this feed. Keep unwinding through `finishDispatch` so
                    // the queued close reaches the embedder.
                    try retirePartnerAbortedSession(self, session);
                } else {
                    self.unindexSession(session);
                    return failDispatch(self, session.peer_handle, err);
                }
            } else {
                return failDispatch(self, session.peer_handle, err);
            }
        };
        if (session.sessionClosed()) {
            if (session.served.partnerAbort() != null)
                try retirePartnerAbortedSession(self, session)
            else
                self.unindexSession(session);
        }
    }
    finishDispatch(self, session) catch |err| switch (err) {
        // `body` has committed its frame/event. Both pressure failures leave
        // the exact dirty row and its wake parked, so they are continuation
        // state, not a reason to replay the caller's input.
        error.OutOfMemory, error.OutboundBackpressure => return,
        else => return err,
    };
}

/// Condemnation can arise while the fed input is dispatched (crossed hellos, a
/// superseded duplicate), and it has already cancelled the Port ingress, so the
/// post-batch drive meets an absent ingress. That is the dispatch's successful
/// terminal outcome on every ingress verb, not a failure of the fed peer.
fn condemnedByDispatch(session: *const HostSession, err: anyerror) bool {
    return err == error.UnknownIngress and session.isTerminating();
}

/// A partner abort is a complete remote verdict, not merely a closed session
/// bit. Retire every Host-owned consequence while the dispatch latch is still
/// held, then tell the embedder to close the transport without echoing an
/// abort. Notification capacity was reserved when the shell was minted.
fn retirePartnerAbortedSession(self: *Host, session: *HostSession) !void {
    return retireQuietly(self, session, session.served.closeReason("partner aborted session"));
}

/// Retire a session the Host opened only to redeem a handoff that failed. This
/// is ownership cleanup, not a partner protocol violation, so it closes the
/// transport without manufacturing an `op:abort`.
fn retireRedeemOnlyExporter(self: *Host, session: *HostSession) !void {
    return retireQuietly(self, session, "handoff redemption failed");
}

/// Retire a session after its adapter reports that the transport is gone. The
/// adapter owns that physical fact. The core owns every authority and lifecycle
/// consequence of it.
pub fn retireTransportClosed(self: *Host, session: *HostSession, reason: []const u8) !void {
    return retireQuietly(self, session, reason);
}

/// Retire a session whose sealed channel refused (ADR-0041): a handshake or
/// record that did not verify. There may be no CapTP session at all yet, and status-allow: pending state or quoted runtime label
/// after one opens no plaintext byte may follow the failure, so no `op:abort`
/// is manufactured in either case. The embedder is told to close the transport
/// and every later verb refuses `SessionCondemned`. Any ingress cancellation or
/// verb-tail failure is retained on the condemned peer while the channel's own
/// refusal remains the caller-visible cause.
pub fn retireSealedSession(self: *Host, session: *HostSession) void {
    var cleanup_failed = false;
    const hold = self.callback_latch.hold();
    retireQuietly(self, session, "sealed channel refused") catch |err|
        recordRetirementFailure(session.served.port.peer, &cleanup_failed, err);
    hold.release();
    // Under an outer hold this returns at once and the outer tail pumps.
    finishVerb(self) catch |err|
        recordRetirementFailure(session.served.port.peer, &cleanup_failed, err);
}

/// Start one fresh cleanup diagnostic chain for this retirement, then retain
/// later consequences behind it. A peer may carry an older abort before the
/// channel refuses. That unrelated record must not turn this retirement's first
/// cleanup failure into a secondary.
fn recordRetirementFailure(peer: *engine.Peer, failed: *bool, err: anyerror) void {
    if (failed.*) {
        peer.recordSecondaryFailure(err);
    } else {
        peer.recordFailure(err);
        failed.* = true;
    }
}

/// The shared no-abort teardown: condemn, unindex, break parked vows, cancel
/// the Vat ingress, and queue the embedder's close. This is everything a
/// terminal verdict owes except an `op:abort` echo. Runs under the callback
/// latch. Notification capacity was reserved when the shell was minted.
fn retireQuietly(self: *Host, session: *HostSession, reason: []const u8) !void {
    if (session.isTerminating()) return;
    host_close.markSessionTerminating(self, session);
    self.unindexSession(session);
    session.served.port.breakFarVows(reason);
    var first_error: ?actors.IngressCancellationError = null;
    self.cancelSessionIngress(session, reason) catch |err| {
        first_error = err;
    };
    pump_schedule.queueUniqueSessionAction(self, .close, session.peer_handle);
    if (first_error) |err| return err;
}

/// Outbound verb tail: note encode work, then pump to quiescence.
pub fn dirtyThenPump(self: *Host, peer_handle: engine.PeerHandle) !void {
    markDirty(self, peer_handle);
    try finishVerb(self);
}

/// Finish an asynchronous verb after its vow id and semantic operation are
/// committed. From this point no failure is retryable as the original verb:
/// allocator or outbound pressure leaves the dirty row and its wake parked
/// for the next drain, while any other drive failure condemns the affected
/// session so the already-returned vow settles through ordinary teardown.
pub fn finishCommittedVow(self: *Host, session: *HostSession) void {
    markDirty(self, session.peer_handle);
    finishCommittedWork(self, session);
}

/// Finish already-committed Host work that did not itself dirty a session
/// (for example a sturdyref cache hit whose completion is already queued).
pub fn finishCommittedWork(self: *Host, session: *HostSession) void {
    finishVerb(self) catch |err| switch (err) {
        error.OutOfMemory, error.OutboundBackpressure => {},
        else => condemnAndClose(self, session, .other, @errorName(err)),
    };
}

pub fn finishDispatch(self: *Host, session: *HostSession) !void {
    try dirtyThenPump(self, session.peer_handle);
}

/// What condemning a session can report after it has already retired the
/// session's authority: the abort frame's encode, or the ingress cancel.
pub const CondemnError = foundation.error_sets.Of(engine.Peer.commitAbortOutbound) ||
    actors.IngressCancellationError;

/// Condemn a session the host is done with (a crossed-hellos tiebreak loser, or
/// one whose local turns amplified past the budget). Queue its typed abort
/// (`kind` names which contract it broke) and mark it so every later verb
/// refuses `SessionCondemned`. The abort rides the ordinary flush path. The
/// embedder drains and writes it, then releases the session.
pub fn condemn(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) CondemnError!void {
    if (session.isTerminating()) return;
    host_close.markSessionTerminating(self, session);
    const hold = self.callback_latch.hold();
    defer hold.release();
    // Drop uniqueness-index rows immediately so a condemned session cannot
    // squat dial / partner-key slots while its abort drains (ADR-0007).
    self.unindexSession(session);
    // Encode the terminal frame and close the Peer in one operation. If encode
    // fails, close explicitly: authority retirement cannot depend on whether
    // the partner receives the diagnostic.
    var first_error: ?CondemnError = null;
    session.served.port.peer.commitAbortOutbound(.{
        .kind = kind,
        .message = message,
    }) catch |err| {
        session.served.port.peer.closeSession();
        first_error = err;
    };
    // Vows and queued turns cannot survive until an embedder observes CLOSE.
    // Break first so every admitted operation settles before close reaches its
    // barrier, including listeners installed while an earlier break fires. status-allow: event or source ordering
    session.served.port.breakFarVows(session.served.closeReason(message));
    self.cancelSessionIngress(session, message) catch |err| if (first_error == null) {
        first_error = err;
    };
    markDirty(self, session.peer_handle);
    if (session.served.hasOutbound()) pump_schedule.queueUniqueSessionAction(self, .flush, session.peer_handle);
    pump_schedule.queueUniqueSessionAction(self, .close, session.peer_handle);
    if (first_error) |err| return err;
}

/// Fail closed when cleanup itself cannot preserve protocol ownership. The
/// session is condemned before its admission-reserved flush and close
/// notifications are queued, so it cannot accept more authority even when
/// encoding the partner diagnostic fails.
pub fn condemnAndClose(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) void {
    condemn(self, session, kind, message) catch |err| session.served.port.peer.recordFailure(err);
}
