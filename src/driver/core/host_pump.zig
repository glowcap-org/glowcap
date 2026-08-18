//! Host encode/action pump: dirty-session encode work, node-action
//! execution, and the embedder action FIFO helpers that drain into.
//! Free functions take `*Host` so `host.zig` stays the type home.

const std = @import("std");
const builtin = @import("builtin");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("host.zig");
const host_close = @import("host_close.zig");
const host_action = @import("host_action.zig");
const capability_promise = @import("capability_promise.zig");
const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostAction = host_action.HostAction;

/// Note that `peer_id` has enqueued-but-unencoded outbound; the top-level
/// verb's unwind drives it. Deduplicated, and legal under the latch — this
/// is exactly how a nested verb's outbound reaches the wire.
///
/// `pending_flush` is the encode worklist (sessions that need
/// `Served.driveFed`). `HostAction.flush` is a different queue by design:
/// the embedder signal that outbound frames are ready to write.
pub fn markDirty(self: *Host, peer_id: engine.PeerId) void {
    scheduleSessionWork(self, peer_id, true);
}

/// Stage teardown work without manufacturing an embedder flush wake. Session
/// cancellation requested inside a callback is consumed by that verb's unwind;
/// outside a callback, the embedding's next progress step drives `finishVerb`.
pub fn scheduleDeferredSessionWork(self: *Host, peer_id: engine.PeerId) void {
    scheduleSessionWork(self, peer_id, false);
}

/// A complete stream frame is retained behind local pressure. Reuse the
/// session's already-reserved FLUSH wake: its outbound drain is the exact
/// boundary that can make room, and `HostSession.takeStreamOutbound` resumes
/// the tail once the existing bytes are gone.
pub fn scheduleFeedResume(self: *Host, session: *HostSession) void {
    session.feed_resume_pending = true;
    queueUniqueSessionAction(self, .flush, session.peer_id);
}

fn scheduleSessionWork(self: *Host, peer_id: engine.PeerId, wake_embedder: bool) void {
    const session = self.sessions.get(peer_id) orelse return;
    if (session.control.flush_pending) return;
    // `Host.mint` reserves one FIFO slot per live session. Intrusive
    // membership keeps the queue at or below that count, so scheduling after
    // protocol authority moves is infallible.
    if (self.pending_flush.items.len == self.pending_flush.capacity) compactDirtyPrefix(self);
    std.debug.assert(self.pending_flush.items.len < self.pending_flush.capacity);
    self.pending_flush.appendAssumeCapacity(peer_id);
    session.control.flush_pending = true;
    // Dirty work is also a wake for a byte-fed embedder. This matters when a
    // finite host quantum expires immediately after a node action or handoff
    // marks a session: no outbound frame may exist yet, but another Host verb
    // must still be prompted to resume the dirty FIFO.
    // A terminal close is already the embedder wake and its executor flushes
    // any queued abort before closing. Do not leave a redundant flush behind
    // a condemned session's close action.
    if (wake_embedder and !session.isTerminating() and !session.control.close_action_pending)
        queueUniqueSessionAction(self, .flush, peer_id);
}

/// Wake the embedder when a finite scheduler slice ended on work that belongs
/// to the Host rather than to one session. A resume action is deliberately
/// separate from `.flush`: there may be no session and no bytes to write, but
/// stopping at `nextAction == null` would strand the Node's remaining work.
fn queueResumeAction(self: *Host) !void {
    if (self.resume_action_pending) return;
    try self.reserveActions(1);
    self.actions.pushReserved(.resume_work);
    self.resume_action_pending = true;
}

pub fn hasInternalWork(self: *const Host) bool {
    return self.pending_flush_head < self.pending_flush.items.len or
        self.node.hasAction() or
        self.node.nextHandoffChange() != null;
}

fn compactDirtyPrefix(self: *Host) void {
    std.debug.assert(self.pending_flush_head > 0);
    const remaining = self.pending_flush.items.len - self.pending_flush_head;
    std.mem.copyForwards(
        engine.PeerId,
        self.pending_flush.items[0..remaining],
        self.pending_flush.items[self.pending_flush_head..],
    );
    self.pending_flush.shrinkRetainingCapacity(remaining);
    self.pending_flush_head = 0;
}

fn takeDirty(self: *Host) ?engine.PeerId {
    if (self.pending_flush_head >= self.pending_flush.items.len) {
        self.pending_flush.clearRetainingCapacity();
        self.pending_flush_head = 0;
        return null;
    }
    const peer_id = self.pending_flush.items[self.pending_flush_head];
    self.pending_flush_head += 1;
    if (self.sessions.get(peer_id)) |session| session.control.flush_pending = false;

    const remaining = self.pending_flush.items.len - self.pending_flush_head;
    if (remaining == 0) {
        self.pending_flush.clearRetainingCapacity();
        self.pending_flush_head = 0;
    } else if (self.pending_flush_head >= remaining and self.pending_flush_head >= 64) {
        std.mem.copyForwards(
            engine.PeerId,
            self.pending_flush.items[0..remaining],
            self.pending_flush.items[self.pending_flush_head..],
        );
        self.pending_flush.shrinkRetainingCapacity(remaining);
        self.pending_flush_head = 0;
    }
    return peer_id;
}

/// Remove a dying shell's queued encode row before its intrusive membership
/// bit disappears. Release is uncommon; the linear removal keeps steady-state
/// insertion O(1) without a second index and preserves `queue.len <= sessions`.
pub fn removeDirtySession(self: *Host, session: *HostSession) void {
    if (!session.control.flush_pending) return;
    var index = self.pending_flush_head;
    while (index < self.pending_flush.items.len) : (index += 1) {
        if (self.pending_flush.items[index] != session.peer_id) continue;
        _ = self.pending_flush.orderedRemove(index);
        session.control.flush_pending = false;
        return;
    }
    unreachable;
}

/// Retract the embedder notifications a session-open transaction published
/// before its post-enrollment pump failed. No consumer can have observed an
/// action for this fresh session because the opening verb has not returned.
/// Other sessions retain their relative order and the reserved backing stays
/// available for later admitted work.
pub fn removeFreshSessionActions(self: *Host, session: *HostSession) void {
    var offset: usize = 0;
    while (offset < self.actions.unpopped().len) {
        const action = self.actions.unpopped()[offset];
        const belongs = switch (action) {
            .flush => |peer_id| peer_id == session.peer_id,
            .close => |peer_id| peer_id == session.peer_id,
            else => false,
        };
        if (!belongs) {
            offset += 1;
            continue;
        }
        _ = self.actions.removeUnpopped(offset);
    }
    session.control.flush_action_pending = false;
    session.control.close_action_pending = false;
}

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
                .session => if (takeDirty(self)) |peer_id| {
                    remaining -= 1;
                    const session = self.sessions.get(peer_id) orelse continue :work;
                    if (session.lifecyclePhase() == .cancel_pending) {
                        try condemn(self, session, .normal_shutdown, "session closing");
                        continue :work;
                    }
                    if (session.isTerminating()) {
                        // A condemned Port's ingress is never driven again; its queued
                        // turns died with the verdict. Encode the terminal abort and
                        // keep its close notification visible to the embedder.
                        session.served.port.peer.stepToIdle() catch |err| session.served.port.peer.recordFailure(err);
                        if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, peer_id);
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
                                markDirty(self, peer_id);
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
                            markDirty(self, peer_id);
                            return error.OutOfMemory;
                        },
                        error.OutboundBackpressure => {
                            markDirty(self, peer_id);
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
                        markDirty(self, peer_id);
                        queueUniqueSessionAction(self, .flush, peer_id);
                    }
                    if (progress == .drained and session.lifecyclePhase() == .finishing and
                        session.pendingOperations() == 0)
                    {
                        try condemn(self, session, .graceful_shutdown, "session closing");
                        continue :work;
                    }
                    if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, peer_id);
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
        try queueResumeAction(self);
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
                    return self.node.exporterSelected(d.pending, existing.peer_id);
                }
            }
            try queueHostAction(self, .{ .dial = .{ .ticket = d.pending } });
        },
        .flush => |peer_id| markDirty(self, peer_id),
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
                    @enumFromInt(deferred.id),
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
                    try session.served.port.peer.sendAnswerResolutionCopying(
                        answer.answer,
                        .{ .@"break" = .{ .message = f.reason.bytes() } },
                    );
                    markDirty(self, answer.recipient_peer);
                },
                .deferred => |deferred| try capability_promise.breakPromise(
                    self,
                    @enumFromInt(deferred.id),
                    f.reason.bytes(),
                ),
            }
        },
        .retire_exporter => |peer_id| {
            if (!self.node.claimExporterRetirement(peer_id)) return;
            const session = self.sessions.get(peer_id) orelse return;
            try retireRedeemOnlyExporter(self, session);
        },
        .need_gift_id => |n| if (self.node.hasPendingGift(n.ticket))
            try queueHostAction(self, .{ .need_gift_id = .{ .ticket = n.ticket } }),
        .release_capability => |raw| {
            const ref = self.capabilities.refForRaw(raw) orelse return;
            self.releaseCapabilityTerminal(ref, null);
        },
        .fail_session => |failure| {
            const session = self.sessions.get(failure.peer_id) orelse return;
            condemnAndClose(self, session, .other, failure.reason);
        },
    }
}

pub fn queueHostAction(self: *Host, action: HostAction) !void {
    // The ceiling of already-promised notifications lives on the Host; this
    // append is the one slot beyond it.
    try self.reserveActions(1);
    self.actions.pushReserved(action);
}

/// The one dispatch-failure arm under every feed verb: the peer has
/// already projected a typed op:abort, so the session's admission-reserved
/// flush notification is queued for the embedder and the dispatch error
/// passes through.
pub fn failDispatch(self: *Host, peer_id: engine.PeerId, err: anyerror) anyerror {
    queueUniqueSessionAction(self, .flush, peer_id);
    return err;
}

/// Shared tag type so test seams and the private helper are one enum
/// (anonymous `enum { flush, close }` decls are distinct types in Zig).
pub const UniqueSessionActionTag = enum { flush, close };

/// One concept for session-tagged embedder actions: at most one pending
/// `.flush` / `.close` per `peer_id` in the unpopped FIFO.
fn queueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_id: engine.PeerId) void {
    const session = self.sessions.get(peer_id) orelse return;
    const pending = switch (tag) {
        .flush => &session.control.flush_action_pending,
        .close => &session.control.close_action_pending,
    };
    if (pending.*) return;
    self.actions.pushReserved(switch (tag) {
        .flush => .{ .flush = peer_id },
        .close => .{ .close = peer_id },
    });
    pending.* = true;
}

const markDirtyForTesting = markDirty;
const queueUniqueSessionActionForTesting = queueUniqueSessionAction;

/// White-box pump support. Empty outside test builds.
pub const testing = if (builtin.is_test) struct {
    pub fn markDirty(self: *Host, peer_id: engine.PeerId) void {
        markDirtyForTesting(self, peer_id);
    }

    pub fn queueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_id: engine.PeerId) !void {
        queueUniqueSessionActionForTesting(self, tag, peer_id);
    }
} else struct {};

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
                    return failDispatch(self, session.peer_id, err);
                }
            } else {
                return failDispatch(self, session.peer_id, err);
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
    queueUniqueSessionAction(self, .close, session.peer_id);
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
pub fn dirtyThenPump(self: *Host, peer_id: engine.PeerId) !void {
    markDirty(self, peer_id);
    try finishVerb(self);
}

/// Finish an asynchronous verb after its vow id and semantic operation are
/// committed. From this point no failure is retryable as the original verb:
/// allocator or outbound pressure leaves the dirty row and its wake parked
/// for the next drain, while any other drive failure condemns the affected
/// session so the already-returned vow settles through ordinary teardown.
pub fn finishCommittedVow(self: *Host, session: *HostSession) void {
    markDirty(self, session.peer_id);
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
    try dirtyThenPump(self, session.peer_id);
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
    markDirty(self, session.peer_id);
    if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, session.peer_id);
    queueUniqueSessionAction(self, .close, session.peer_id);
    if (first_error) |err| return err;
}

/// Fail closed when cleanup itself cannot preserve protocol ownership. The
/// session is condemned before its admission-reserved flush and close
/// notifications are queued, so it cannot accept more authority even when
/// encoding the partner diagnostic fails.
pub fn condemnAndClose(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) void {
    condemn(self, session, kind, message) catch |err| session.served.port.peer.recordFailure(err);
}
