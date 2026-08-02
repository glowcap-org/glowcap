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
pub fn markDirty(self: *Host, peer_id: engine.PeerId) void {
    const session = self.sessions.get(peer_id) orelse return;
    if (session.flush_pending) return;
    // `Host.mint` reserves one FIFO slot per live session. Intrusive
    // membership keeps the queue at or below that count, so scheduling after
    // protocol authority moves is infallible.
    if (self.pending_flush.items.len == self.pending_flush.capacity) compactDirtyPrefix(self);
    std.debug.assert(self.pending_flush.items.len < self.pending_flush.capacity);
    self.pending_flush.appendAssumeCapacity(peer_id);
    session.flush_pending = true;
}

/// Test seam for staging already-owned deferred encode work.
pub fn testingMarkDirty(self: *Host, peer_id: engine.PeerId) void {
    markDirty(self, peer_id);
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
    if (self.sessions.get(peer_id)) |session| session.flush_pending = false;

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
    if (!session.flush_pending) return;
    var index = self.pending_flush_head;
    while (index < self.pending_flush.items.len) : (index += 1) {
        if (self.pending_flush.items[index] != session.peer_id) continue;
        _ = self.pending_flush.orderedRemove(index);
        session.flush_pending = false;
        return;
    }
    unreachable;
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
        while (takeDirty(self)) |peer_id| {
            progressed = true;
            const session = self.sessions.get(peer_id) orelse continue;
            if (session.condemned) {
                // A condemned Port's ingress is never driven again; its queued
                // turns died with the verdict. Encode what is
                // already queued (the typed abort) so the embedder writes
                // it before closing; best-effort, the session is ending.
                session.served.port.peer.stepToIdle() catch {};
                if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, peer_id);
                continue;
            }
            // Backstop: any path that skipped the condemned branch above
            // and still reached a drive on a condemned session panics loud.
            std.debug.assert(!session.condemned);
            session.served.driveFed(&self.vat) catch |err| switch (err) {
                error.LocalTurnLimitExceeded => {
                    try condemn(self, session, .resource_exhausted, "local turn budget exceeded");
                    continue;
                },
                error.OutOfMemory => {
                    // A handoff change may already have been consumed into
                    // this intrusive row. Requeue before propagating so a
                    // release-side catch cannot strand the accepted withdraw.
                    markDirty(self, peer_id);
                    return error.OutOfMemory;
                },
                else => {
                    // `Peer.step` projects aborts itself; failures from
                    // `drainEvents` / `vat.serve` (e.g. an outbound resolve
                    // refused as `UnexpectedMessage`) do not. Record and
                    // project here so `last_abort` and the partner see the
                    // same typed cause the feed path already promises.
                    if (session.served.port.peer.lastAbort() == null) {
                        session.served.port.peer.emitFailure(err);
                    }
                    return err;
                },
            };
            // Tell the embedder only when a frame is actually queued: a
            // feed that encoded nothing must not cost a flush round-trip.
            if (session.served.hasOutbound()) queueUniqueSessionAction(self, .flush, peer_id);
        }
        while (self.node.hasAction()) {
            // Reserve the largest Host-side consequence, then execute through
            // the Node's peek/commit seam. A fulfilled settle may still need a
            // fallible Vat clone; if it fails, the listener and Node action
            // both remain parked for the next action drain.
            try self.reserveActionsFor(1);
            const action = self.node.peekAction().?;
            progressed = true;
            try execNodeAction(self, action);
            self.node.consumePeekedAction();
        }
        if (self.node.nextHandoffChange()) |dependency| {
            var waiters = self.node.handoffWaiters(dependency);
            while (waiters.next()) |receiver| {
                const session = self.sessions.get(receiver) orelse continue;
                if (session.condemned) continue;
                session.served.port.peer.noteHandoffChange(dependency);
                markDirty(self, receiver);
            }
            self.node.consumeHandoffChange(dependency);
            // Reach receiver quiescence before accepting another exact wake.
            // That makes one scalar wake on each Peer sufficient and gives an
            // OOM retry ownership: the receiver keeps the key until it settles.
            continue;
        }
        if (!progressed) return;
    }
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
        .flush => |peer_id| markDirty(self, peer_id),
        .settle => |s| {
            const session = self.sessions.get(s.peer_id) orelse return;
            try session.served.port.settleFar(
                &self.vat,
                model.AnswerPosition.from(s.answer),
                .{ .fulfilled = .{ .reference = .{ .far = model.FarRef.object(s.token) } } },
            );
        },
        .fail => |f| {
            const session = self.sessions.get(f.peer_id) orelse return;
            try session.served.port.settleFar(&self.vat, model.AnswerPosition.from(f.answer), .{ .broken = f.reason.bytes() });
        },
        .need_gift_id => |n| try queueHostAction(self, .{ .need_gift_id = .{ .ticket = n.ticket } }),
    }
}

pub fn queueHostAction(self: *Host, action: HostAction) !void {
    // The ceiling of already-promised notifications lives on the Host; this
    // append is the one slot beyond it.
    try self.reserveActionsFor(1);
    self.actions.pushReserved(action);
}

/// The one dispatch-failure arm under every feed verb: the peer has
/// already projected a typed op:abort, so a flush is queued for the
/// embedder (best-effort — the session is closing either way) and the
/// dispatch error passes through.
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
        .flush => &session.flush_action_pending,
        .close => &session.close_action_pending,
    };
    if (pending.*) return;
    self.actions.pushReserved(switch (tag) {
        .flush => .{ .flush = peer_id },
        .close => .{ .close = peer_id },
    });
    pending.* = true;
}

/// Test seam for the private FIFO dedupe (flush/close). Not a production API.
pub fn testingQueueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_id: engine.PeerId) !void {
    queueUniqueSessionAction(self, tag, peer_id);
}

/// Whole-frame inbound spine: latch, body, fail projection, finishDispatch.
pub fn dispatchUnderLatch(self: *Host, session: *HostSession, body: anytype) !void {
    try enterCallback(self, session);
    {
        defer leaveCallback(self);
        body.call() catch |err| {
            if (!session.sessionOpen()) self.unindexSession(session);
            return failDispatch(self, session.peer_id, err);
        };
        if (!session.sessionOpen()) self.unindexSession(session);
    }
    try finishDispatch(self, session);
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
    // Encode the terminal frame and close the Peer in one operation. If encode
    // fails, close explicitly: authority retirement cannot depend on whether
    // the partner receives the diagnostic.
    var first_error: ?anyerror = null;
    session.served.port.peer.commitAbortOutbound(.{
        .kind = kind,
        .message = message,
    }, .close) catch |err| {
        session.served.port.peer.closeSession();
        first_error = err;
    };
    // Queued turns/listeners cannot survive until an embedder observes CLOSE.
    self.cancelSessionIngress(session, message) catch |err| if (first_error == null) {
        first_error = err;
    };
    markDirty(self, session.peer_id);
    queueUniqueSessionAction(self, .close, session.peer_id);
    if (first_error) |err| return err;
}

/// Fail closed when cleanup itself cannot preserve protocol ownership. The
/// session is condemned before either best-effort enqueue, so it cannot accept
/// more authority even when allocation pressure also prevents the abort or
/// close notification from being queued.
pub fn condemnAndClose(self: *Host, session: *HostSession, kind: model.AbortKind, message: []const u8) void {
    condemn(self, session, kind, message) catch {};
}
