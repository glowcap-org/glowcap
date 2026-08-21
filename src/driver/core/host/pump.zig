//! Host encode/action pump: dirty-session encode work, node-action execution,
//! and terminal session retirement. Free functions take `*Host` so `host.zig`
//! stays the type home.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../host.zig");
const host_close = @import("close.zig");
const pump_schedule = @import("pump/schedule.zig");
const capability_promise = @import("../capability_promise.zig");
const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

pub const markDirty = pump_schedule.markDirty;
pub const scheduleDeferredSessionWork = pump_schedule.scheduleDeferredSessionWork;
pub const scheduleFeedResume = pump_schedule.scheduleFeedResume;
pub const hasInternalWork = pump_schedule.hasInternalWork;
pub const removeDirtySession = pump_schedule.removeDirtySession;
pub const removeFreshSessionActions = pump_schedule.removeFreshSessionActions;
pub const queueHostAction = pump_schedule.queueHostAction;
pub const UniqueSessionActionTag = pump_schedule.UniqueSessionActionTag;
const queueUniqueSessionAction = pump_schedule.queueUniqueSessionAction;

/// The tail of every top-level verb: encode and pump until quiescent. A
/// nested verb (the latch is held) returns immediately — the enclosing
/// verb's own tail picks up what it enqueued.
pub fn finishVerb(self: *Host) !void {
    if (self.in_callback) return;
    self.in_callback = true;
    defer self.in_callback = false;
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

/// Alternate the two work queues to quiescence: encode every dirty
/// session (queueing its flush action), then execute every node
/// serve-step action. Either side can feed the other — a settle listener's
/// nested send dirties a session, an encoded withdraw queues a claim's
/// actions — so the loop runs until neither moves.
///
/// Attribution under a `local_turn_budget`: a budget breach here belongs
/// to the session whose vat amplified, never to the verb that fed the
/// pump — the fed session's work may have flooded a *sibling*. The
/// flooded session is condemned (typed `resource_exhausted` abort) and
/// a `close` action names it for the embedder; the verb that ran this
/// pump succeeds. A budget breach inside the fed session's own
/// dispatch (`feed`'s latched `feedBorrowed`) never reaches here: it
/// keeps `failDispatch` semantics and fails that feed.
fn drainWork(self: *Host) !void {
    var remaining = self.opts.host_work_quantum orelse std.math.maxInt(usize);
    work: while (remaining != 0) {
        var lanes_checked: u2 = 0;
        while (lanes_checked < 3) : (lanes_checked += 1) {
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
                    const progress = if (self.opts.host_work_quantum == null) blk: {
                        session.served.driveFed(&self.vat) catch |err| switch (err) {
                            error.EventServeOutOfMemory => {
                                try condemn(self, session, .resource_exhausted, "event serve failed under memory pressure");
                                continue :work;
                            },
                            error.OutOfMemory, error.OutboundBackpressure => {
                                markDirty(self, peer_handle);
                                return err;
                            },
                            else => return err,
                        };
                        break :blk actors.Vat.DriveProgress.drained;
                    } else session.served.driveFedBudgeted(&self.vat) catch |err| switch (err) {
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
                            try condemn(self, session, .resource_exhausted, "local turn budget exceeded");
                            continue :work;
                        },
                        else => {
                            if (session.served.port.peer.lastAbort() == null)
                                session.served.port.peer.emitFailure(err);
                            return err;
                        },
                    };
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
                .node => if (self.node.hasAction()) {
                    remaining -= 1;
                    // Reserve the largest Host-side consequence, then execute through
                    // the Node's peek/commit seam. A fulfilled settle may still need a
                    // fallible Vat clone; if it fails, the action remains parked.
                    try self.reserveActions(1);
                    const action = self.node.peekAction().?;
                    try execNodeAction(self, action);
                    try self.node.consumePeekedAction();
                    continue :work;
                },
                .handoff => if (self.node.nextHandoffChange()) |dependency| {
                    remaining -= 1;
                    var waiters = self.node.handoffWaiters(dependency);
                    while (waiters.next()) |receiver| {
                        const session = self.sessions.get(receiver) orelse continue;
                        if (session.isTerminating()) continue;
                        session.served.port.peer.noteHandoffChange(dependency);
                        markDirty(self, receiver);
                    }
                    self.node.consumeHandoffChange(dependency);
                    continue :work;
                },
            }
        }
        return;
    }
    // A finite quantum is a yield point. Preserve liveness even when the
    // exhausted work was entirely Node-owned and therefore produced neither a
    // session flush nor an embedder effect.
    if (self.opts.host_work_quantum != null and hasInternalWork(self))
        try pump_schedule.queueResumeAction(self);
}

/// The non-blocking executor of node serve-step actions: settles and
/// fails fire the recipient vat's listener directly (`Vat.settleFar`);
/// dials and gift-id draws are host effects, queued for the embedder;
/// flushes mark the session dirty so the encode loop drives it.
fn execNodeAction(self: *Host, action: engine.Node.Action) anyerror!void {
    switch (action) {
        .dial => |d| {
            // Ticket-only action: pending row owns URI + parsed parts.
            // Unparseable gives never reach a dial action (acceptGive fails
            // them). Pre-flight reuses an already-open Host session the Node
            // identity cache may have missed (earlier app dial, accepted
            // inbound hello). ADR-0012 session-pair uniqueness would refuse a
            // duplicate dial and break the redeem.
            const view = self.node.pendingDial(d.pending) orelse return;
            if (try self.liveSessionForDial(view.transport, view.designator)) |existing| {
                if (existing.sessionOpen()) {
                    return self.node.exporterSelected(d.pending, existing.peer_handle);
                }
            }
            try pump_schedule.queueHostAction(self, .{ .dial = .{ .ticket = d.pending } });
        },
        .flush => |peer_handle| markDirty(self, peer_handle),
        .settle => |s| {
            switch (s.dest) {
                .answer => |answer| {
                    const session = self.sessions.get(answer.recipient_peer) orelse return;
                    try session.served.port.settleFar(
                        &self.vat,
                        answer.answer,
                        .{ .fulfilled = .{ .reference = .{ .routed = .{ .id = s.route_id } } } },
                    );
                    markDirty(self, answer.recipient_peer);
                },
                .deferred => |deferred| try capability_promise.fulfill(
                    self,
                    @fromBackingInt(@intCast(deferred.id)),
                    s.route_id,
                ),
            }
        },
        .fail => |f| {
            switch (f.dest) {
                .answer => |answer| {
                    const session = self.sessions.get(answer.recipient_peer) orelse return;
                    try session.served.port.settleFar(&self.vat, answer.answer, .{ .broken = f.reason.bytes() });
                    markDirty(self, answer.recipient_peer);
                },
                .served_answer => |answer| {
                    const session = self.sessions.get(answer.recipient_peer) orelse return;
                    try session.served.port.peer.sendAnswerTargetResolutionCopying(
                        answer.answer,
                        .{ .@"break" = .{ .message = f.reason.bytes() } },
                    );
                    markDirty(self, answer.recipient_peer);
                },
                .deferred => |deferred| try capability_promise.breakPromise(
                    self,
                    @fromBackingInt(@intCast(deferred.id)),
                    f.reason.bytes(),
                ),
            }
        },
        .retire_exporter => |peer_handle| {
            if (!self.node.claimExporterRetirement(peer_handle)) return;
            const session = self.sessions.get(peer_handle) orelse return;
            try retireRedeemOnlyExporter(self, session);
        },
        .need_gift_id => |n| if (self.node.hasPendingGift(n.ticket))
            try pump_schedule.queueHostAction(self, .{ .need_gift_id = .{ .ticket = n.ticket } }),
        .release_capability => |raw| {
            const ref = self.capabilities.refForRaw(raw) orelse return;
            self.releaseCapabilityTerminal(ref, null);
        },
        .fail_session => |failure| {
            const session = self.sessions.get(failure.peer_handle) orelse return;
            condemnAndClose(self, session, .other, failure.reason);
        },
    }
}

/// The one dispatch-failure arm under every feed verb: the peer has
/// already projected a typed op:abort, so the session's admission-reserved
/// flush notification is queued for the embedder and the dispatch error
/// passes through.
pub fn failDispatch(self: *Host, peer_handle: engine.PeerHandle, err: anyerror) anyerror {
    queueUniqueSessionAction(self, .flush, peer_handle);
    return err;
}

pub const testing = pump_schedule.testing;

/// Whole-frame inbound spine: latch, body, fail projection, finishDispatch.
pub fn dispatchUnderLatch(self: *Host, session: *HostSession, body: anytype) !void {
    try enterCallback(self, session);
    {
        defer {
            if (session.sessionOpen()) self.finishSessionOpen(session);
            leaveCallback(self);
        }
        body.call() catch |err| {
            if (!session.sessionOpen()) {
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
        if (!session.sessionOpen()) {
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

/// Retire a session after its adapter reports that the transport is gone.
/// The adapter owns that physical fact; the core owns every authority and
/// lifecycle consequence of it.
pub fn retireTransportClosed(self: *Host, session: *HostSession, reason: []const u8) !void {
    return retireQuietly(self, session, reason);
}

/// Retire a session whose sealed channel refused (ADR-0107): a handshake or
/// record that did not verify. There may be no CapTP session at all yet, and
/// after one opens no plaintext byte may follow the failure, so no `op:abort`
/// is manufactured in either case — the embedder is told to close the
/// transport and every later verb refuses `SessionCondemned`. Any ingress
/// cancellation or verb-tail failure is retained on the condemned peer while
/// the channel's own refusal remains the caller-visible cause.
pub fn retireSealedSession(self: *Host, session: *HostSession) void {
    const latched = self.in_callback;
    var cleanup_failed = false;
    if (!latched) self.in_callback = true;
    retireQuietly(self, session, "sealed channel refused") catch |err|
        recordRetirementFailure(session.served.port.peer, &cleanup_failed, err);
    if (!latched) {
        self.in_callback = false;
        finishVerb(self) catch |err|
            recordRetirementFailure(session.served.port.peer, &cleanup_failed, err);
    }
}

/// Start one fresh cleanup diagnostic chain for this retirement, then retain
/// later consequences behind it. A peer may carry an older abort before the
/// channel refuses; that unrelated record must not turn this retirement's
/// first cleanup failure into a secondary.
fn recordRetirementFailure(peer: *engine.Peer, failed: *bool, err: anyerror) void {
    if (failed.*) {
        peer.recordSecondaryFailure(err);
    } else {
        peer.recordFailure(err);
        failed.* = true;
    }
}

/// The shared no-abort teardown: condemn, unindex, break parked vows, cancel
/// the Vat ingress, and queue the embedder's close — everything a terminal
/// verdict owes except an `op:abort` echo. Runs under the callback latch;
/// notification capacity was reserved when the shell was minted.
fn retireQuietly(self: *Host, session: *HostSession, reason: []const u8) !void {
    if (session.isTerminating()) return;
    host_close.markSessionTerminating(self, session);
    self.unindexSession(session);
    session.served.port.breakFarVows(reason);
    var first_error: ?anyerror = null;
    self.cancelSessionIngress(session, reason) catch |err| {
        first_error = err;
    };
    pump_schedule.queueUniqueSessionAction(self, .close, session.peer_handle);
    if (first_error) |err| return err;
}

/// Shared inbound-dispatch latch: refuse reentry, refuse a condemned
/// session, then arm the callback latch. Pair with `leaveCallback`
/// (defer) and `finishDispatch` (on success). Own caller:
/// `dispatchUnderLatch`.
fn enterCallback(self: *Host, session: *HostSession) !void {
    try self.refuseReentry();
    try self.checkSession(session);
    self.in_callback = true;
}

fn leaveCallback(self: *Host) void {
    self.in_callback = false;
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

/// Condemn a session the host is done with — a crossed-hellos tiebreak
/// loser, or one whose local turns amplified past the budget: queue its
/// typed abort (`kind` names which contract it broke) and mark it so every
/// later verb refuses `SessionCondemned`. The abort rides the ordinary
/// flush path; the embedder drains and writes it, then releases the session.
pub fn condemn(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) !void {
    if (session.isTerminating()) return;
    host_close.markSessionTerminating(self, session);
    const was_in_callback = self.in_callback;
    self.in_callback = true;
    defer self.in_callback = was_in_callback;
    // Drop uniqueness-index rows immediately so a condemned session cannot
    // squat dial / partner-key slots while its abort drains (ADR-0012).
    self.unindexSession(session);
    // Encode the terminal frame and close the Peer in one operation. If encode
    // fails, close explicitly: authority retirement cannot depend on whether
    // the partner receives the diagnostic.
    var first_error: ?anyerror = null;
    session.served.port.peer.commitAbortOutbound(.{
        .kind = kind,
        .message = message,
    }) catch |err| {
        session.served.port.peer.closeSession();
        first_error = err;
    };
    // Vows and queued turns cannot survive until an embedder observes CLOSE.
    // Break first so every admitted operation settles before close reaches its
    // barrier, including listeners installed while an earlier break fires.
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
