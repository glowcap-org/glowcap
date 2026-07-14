//! Host encode/action pump: dirty-session encode work, node-action
//! execution, and the embedder action FIFO helpers that drain into.
//! Free functions take `*Host` so `host.zig` stays the type home.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

const host_mod = @import("host.zig");
const host_action = @import("host_action.zig");
const vocab = @import("vocab.zig");
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
                else => return err,
            };
            // Tell the embedder only when a frame is actually queued: a
            // feed that encoded nothing must not cost a flush round-trip.
            if (session.served.hasOutbound()) try queueUniqueSessionAction(self, .flush, peer_id);
        }
        while (self.node.nextAction()) |action| {
            progressed = true;
            try execNodeAction(self, action);
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
            // The node frees its action's bytes at its next `nextAction`;
            // the embedder-facing action owns host dupes.
            const dial = try dialActionFields(self, d.pending, d.locator);
            queueHostAction(self, .{ .dial = dial }) catch |err| {
                host_action.freeAction(self.allocator, .{ .dial = dial });
                return err;
            };
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

/// Build a `dial` action's owned payload: the locator dupe plus its
/// parsed transport, designator, and `direct-addresses` hint, each duped
/// onto the host so all four views carry the popped action's
/// valid-until-next-`nextAction` lifetime. An unparseable locator leaves
/// the parsed pieces empty and the URI intact for the embedder to
/// interpret.
fn dialActionFields(self: *Host, ticket: engine.Node.PendingId, locator_uri: []const u8) !HostAction.Dial {
    const locator = try self.allocator.dupe(u8, locator_uri);
    errdefer self.allocator.free(locator);
    var dial = HostAction.Dial{ .ticket = ticket, .locator = locator };
    const parsed = model.uri.parsePeer(self.allocator, locator_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return dial,
    };
    defer model.freePeerLocator(self.allocator, parsed);
    dial.transport = try self.allocator.dupe(u8, parsed.transport);
    errdefer self.allocator.free(dial.transport);
    dial.designator = try self.allocator.dupe(u8, parsed.designator);
    errdefer self.allocator.free(dial.designator);
    for (parsed.hints.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, vocab.hint_direct_addresses)) continue;
        switch (entry.value) {
            .string, .bytes => |bytes| {
                dial.direct_addresses_hint = try self.allocator.dupe(u8, bytes);
                return dial;
            },
            else => {},
        }
    }
    return dial;
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
    try session.served.peer.sendCopying(.{ .abort = .{ .kind = kind, .message = message } });
    try markDirty(self, session.peer_id);
}
