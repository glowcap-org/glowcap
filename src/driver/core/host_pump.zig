//! Host encode/action pump: dirty-session encode work, node-action
//! execution, and the embedder action FIFO helpers that drain into.
//! Free functions take `*Host` so `host.zig` stays the type home.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("host.zig");
const host_action = @import("host_action.zig");
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
pub fn markDirty(self: *Host, peer_id: engine.PeerId) !void {
    for (self.pending_flush.items) |queued| {
        if (queued == peer_id) return;
    }
    try self.pending_flush.append(self.allocator, peer_id);
}

/// The tail of every top-level verb: encode and pump until quiescent. A
/// nested verb (the latch is held) returns immediately — the enclosing
/// verb's own tail picks up what it enqueued.
pub fn finishVerb(self: *Host) !void {
    if (self.in_callback) return;
    self.in_callback = true;
    defer self.in_callback = false;
    try drainWork(self);
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
    while (true) {
        var progressed = false;
        while (self.pending_flush.items.len > 0) {
            progressed = true;
            const peer_id = self.pending_flush.orderedRemove(0);
            const session = self.sessions.get(peer_id) orelse continue;
            if (session.condemned) {
                // A condemned session's vat is never driven again — its
                // queued turns died with the verdict. Encode what is
                // already queued (the typed abort) so the embedder writes
                // it before closing; best-effort, the session is ending.
                session.served.peer.stepToIdle() catch {};
                if (session.served.hasOutbound()) try queueUniqueSessionAction(self, .flush, peer_id);
                continue;
            }
            // Backstop: any path that skipped the condemned branch above
            // and still reached a drive on a condemned session panics loud.
            std.debug.assert(!session.condemned);
            session.served.driveFed() catch |err| switch (err) {
                error.LocalTurnLimitExceeded => {
                    try condemn(self, session, .resource_exhausted, "local turn budget exceeded");
                    try queueUniqueSessionAction(self, .close, peer_id);
                    continue;
                },
                else => {
                    // `Peer.step` projects aborts itself; failures from
                    // `drainEvents` / `vat.serve` (e.g. an outbound resolve
                    // refused as `UnexpectedMessage`) do not. Record and
                    // project here so `last_abort` and the partner see the
                    // same typed cause the feed path already promises.
                    if (session.served.peer.lastAbort() == null) {
                        session.served.peer.emitFailure(err);
                    }
                    return err;
                },
            };
            // Tell the embedder only when a frame is actually queued: a
            // feed that encoded nothing must not cost a flush round-trip.
            if (session.served.hasOutbound()) try queueUniqueSessionAction(self, .flush, peer_id);
            try noteParkedWithdraws(self, session);
        }
        while (self.node.nextAction()) |action| {
            progressed = true;
            try execNodeAction(self, action);
        }
        // A deposit landed on the shared gift registry since the last drive: a
        // `withdraw-gift` parked on a *sibling* session (its gift lands on the
        // gifter's session, the withdraw on the recipient's — ADR-0056) may now
        // be satisfiable, so re-drive every session holding one. `Peer.step`
        // settles the parked withdraw against the shared registry. Fires once
        // per deposit generation, never a per-frame sweep, and only over the
        // small set of handoff exporters actually holding a parked withdraw —
        // the single-thread host's replacement for the thread-per-connection
        // driver's continuous per-session step.
        if (self.node.gifts.deposits != self.last_deposit_gen and
            self.parked_withdraw_sessions.items.len > 0)
        {
            self.last_deposit_gen = self.node.gifts.deposits;
            var i: usize = 0;
            while (i < self.parked_withdraw_sessions.items.len) {
                const peer_id = self.parked_withdraw_sessions.items[i];
                const session = self.sessions.get(peer_id);
                if (session == null or session.?.condemned) {
                    // tolerant: a released or condemned session drops out of the
                    // parked set; swapRemove hands back the entry we discard.
                    _ = self.parked_withdraw_sessions.swapRemove(i);
                    continue;
                }
                progressed = true;
                try markDirty(self, peer_id);
                i += 1;
            }
        }
        if (!progressed) return;
    }
}

/// Track whether `session` holds a parked `withdraw-gift` so the deposit-gen
/// retry in `drainWork` re-drives exactly the sessions that need it. Called
/// after every drive: a fresh park adds the session, a drive that settled the
/// last parked withdraw drops it.
fn noteParkedWithdraws(self: *Host, session: *HostSession) !void {
    const parked = session.served.peer.hasPendingWithdraws();
    const items = &self.parked_withdraw_sessions;
    for (items.items, 0..) |peer_id, i| {
        if (peer_id == session.peer_id) {
            // tolerant: a session that settled its last parked withdraw leaves
            // the set; swapRemove hands back the entry we discard.
            if (!parked) _ = items.swapRemove(i);
            return;
        }
    }
    if (parked) try items.append(self.allocator, session.peer_id);
}

/// The non-blocking executor of node serve-step actions: settles and
/// fails fire the recipient vat's listener directly (`Vat.settleFar`);
/// dials and gift-id draws are host effects, queued for the embedder;
/// flushes mark the session dirty so the encode loop drives it.
fn execNodeAction(self: *Host, action: engine.Node.Action) !void {
    switch (action) {
        .dial => |d| {
            // Ticket-only action: pending row owns URI + parsed parts.
            // Unparseable gives never reach a dial action (acceptGive fails
            // them). Pre-flight reuses an already-open Host session the Node
            // identity cache may have missed (earlier app dial, accepted
            // inbound hello). ADR-0012 session-pair uniqueness would refuse a
            // duplicate dial and break the redeem.
            const view = self.node.pendingDial(d.pending) orelse return;
            if (self.liveSessionForDial(view.designator)) |existing| {
                if (existing.sessionOpen()) {
                    return self.node.exporterDialed(d.pending, existing.peer_id);
                }
            }
            try queueHostAction(self, .{ .dial = .{ .ticket = d.pending } });
        },
        .flush => |peer_id| try markDirty(self, peer_id),
        .settle => |s| {
            const session = self.sessions.get(s.peer_id) orelse return;
            try session.served.vat.settleFar(
                model.AnswerPosition.from(s.answer),
                .{ .fulfilled = .{ .reference = .{ .far = model.FarRef.object(s.token) } } },
            );
        },
        .fail => |f| {
            const session = self.sessions.get(f.peer_id) orelse return;
            try session.served.vat.settleFar(model.AnswerPosition.from(f.answer), .{ .broken = f.reason });
        },
        .need_gift_id => |n| try queueHostAction(self, .{ .need_gift_id = .{ .ticket = n.ticket } }),
    }
}

pub fn queueHostAction(self: *Host, action: HostAction) !void {
    // Keep one spare completion slot per live vow on top of this append,
    // so a vow fire's `appendAssumeCapacity` can never fail (see
    // `queueCompletion`).
    try self.actions.reserve(self.allocator, self.vows.count() + 1);
    self.actions.pushReserved(action);
}

/// The one dispatch-failure arm under every feed verb: the peer has
/// already projected a typed op:abort, so a flush is queued for the
/// embedder (best-effort — the session is closing either way) and the
/// dispatch error passes through.
pub fn failDispatch(self: *Host, peer_id: engine.PeerId, err: anyerror) anyerror {
    queueUniqueSessionAction(self, .flush, peer_id) catch {};
    return err;
}

/// Shared tag type so test seams and the private helper are one enum
/// (anonymous `enum { flush, close }` decls are distinct types in Zig).
pub const UniqueSessionActionTag = enum { flush, close };

/// One concept for session-tagged embedder actions: at most one pending
/// `.flush` / `.close` per `peer_id` in the unpopped FIFO.
fn queueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_id: engine.PeerId) !void {
    for (self.actions.unpopped()) |queued| {
        switch (tag) {
            .flush => if (queued == .flush and queued.flush == peer_id) return,
            .close => if (queued == .close and queued.close == peer_id) return,
        }
    }
    try queueHostAction(self, switch (tag) {
        .flush => .{ .flush = peer_id },
        .close => .{ .close = peer_id },
    });
}

/// Test seam for the private FIFO dedupe (flush/close). Not a production API.
pub fn testingQueueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_id: engine.PeerId) !void {
    try queueUniqueSessionAction(self, tag, peer_id);
}

/// Whole-frame inbound spine: latch, body, fail projection, finishDispatch.
pub fn dispatchUnderLatch(self: *Host, session: *HostSession, body: anytype) !void {
    try enterCallback(self, session);
    {
        defer leaveCallback(self);
        body.call() catch |err| return failDispatch(self, session.peer_id, err);
    }
    try finishDispatch(self, session);
}

/// Byte-stream inbound spine: same latch / fail / finish as
/// `dispatchUnderLatch`, but the body returns how many leading bytes were
/// consumed (`feedBytes`). One concept for the inbound latch — not a second
/// hand-rolled enter/leave/fail/finish in the Host verb.
pub fn dispatchStreamUnderLatch(self: *Host, session: *HostSession, body: anytype) !usize {
    try enterCallback(self, session);
    const n = blk: {
        defer leaveCallback(self);
        break :blk body.call() catch |err| return failDispatch(self, session.peer_id, err);
    };
    try finishDispatch(self, session);
    return n;
}

/// Shared inbound-dispatch latch: refuse reentry, refuse a condemned
/// session, then arm the callback latch. Pair with `leaveCallback`
/// (defer) and `finishDispatch` (on success). Own callers:
/// `dispatchUnderLatch` and `dispatchStreamUnderLatch`.
fn enterCallback(self: *Host, session: *HostSession) !void {
    try self.refuseReentry();
    try Host.checkLive(session);
    self.in_callback = true;
}

fn leaveCallback(self: *Host) void {
    self.in_callback = false;
}

/// Outbound verb tail: note encode work, then pump to quiescence.
pub fn dirtyThenPump(self: *Host, peer_id: engine.PeerId) !void {
    try markDirty(self, peer_id);
    try finishVerb(self);
}

pub fn finishDispatch(self: *Host, session: *HostSession) !void {
    try dirtyThenPump(self, session.peer_id);
}

/// Condemn a session the host is done with — a crossed-hellos tiebreak
/// loser, or one whose local turns amplified past the budget: queue its
/// typed abort (`kind` names which contract it broke) and mark it so every
/// later verb refuses `ConnectionCondemned`. The abort rides the ordinary
/// flush path; the embedder drains and writes it, then releases the session.
pub fn condemn(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) !void {
    if (session.condemned) return;
    session.condemned = true;
    // Drop uniqueness-index rows immediately so a condemned session cannot
    // squat dial / partner-key slots while its abort drains (ADR-0012).
    self.unindexSession(session);
    try session.served.peer.sendCopying(.{ .abort = .{ .kind = kind, .message = message } });
    try markDirty(self, session.peer_id);
}
