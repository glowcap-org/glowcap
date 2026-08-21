//! Host pump scheduling and embedder action admission.
//!
//! The pump executor alternates between dirty sessions, Node actions, and
//! handoff changes. This leaf owns the mutable queue mechanics behind that:
//! deduplicated dirty-session encode work, host-global resume wakes, unique
//! per-session FLUSH/CLOSE notifications, and the one reserved action append.

const std = @import("std");
const builtin = @import("builtin");

const engine = @import("engine");
const host_mod = @import("../../host.zig");
const host_action = @import("../action.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostAction = host_action.HostAction;

/// Note that `peer_handle` has enqueued-but-unencoded outbound; the top-level
/// verb's unwind drives it. Deduplicated, and legal under the latch — this
/// is exactly how a nested verb's outbound reaches the wire.
///
/// `pending_flush` is the encode worklist (sessions that need
/// `Served.driveFed`). `HostAction.flush` is a different queue by design:
/// the embedder signal that outbound frames are ready to write.
pub fn markDirty(self: *Host, peer_handle: engine.PeerHandle) void {
    scheduleSessionWork(self, peer_handle, true);
}

/// Stage teardown work without manufacturing an embedder flush wake. Session
/// cancellation requested inside a callback is consumed by that verb's unwind;
/// outside a callback, the embedding's next progress step drives `finishVerb`.
pub fn scheduleDeferredSessionWork(self: *Host, peer_handle: engine.PeerHandle) void {
    scheduleSessionWork(self, peer_handle, false);
}

/// A complete stream frame is retained behind local pressure. Reuse the
/// session's already-reserved FLUSH wake: its outbound drain is the exact
/// boundary that can make room, and `HostSession.takeStreamOutbound` resumes
/// the tail once the existing bytes are gone.
pub fn scheduleFeedResume(self: *Host, session: *HostSession) void {
    session.feed_resume_pending = true;
    queueUniqueSessionAction(self, .flush, session.peer_handle);
}

fn scheduleSessionWork(self: *Host, peer_handle: engine.PeerHandle, wake_embedder: bool) void {
    const session = self.sessions.get(peer_handle) orelse return;
    if (session.control.flush_pending) return;
    // `Host.mint` reserves one FIFO slot per live session. Intrusive
    // membership keeps the queue at or below that count, so scheduling after
    // protocol authority moves is infallible.
    self.pending_flush.pushReserved(peer_handle);
    session.control.flush_pending = true;
    // Dirty work is also a wake for a byte-fed embedder. This matters when a
    // finite host quantum expires immediately after a node action or handoff
    // marks a session: no outbound frame may exist yet, but another Host verb
    // must still be prompted to resume the dirty FIFO.
    // A terminal close is already the embedder wake and its executor flushes
    // any queued abort before closing. Do not leave a redundant flush behind
    // a condemned session's close action.
    if (wake_embedder and !session.isTerminating() and !session.control.close_action_pending)
        queueUniqueSessionAction(self, .flush, peer_handle);
}

/// Wake the embedder when a finite scheduler slice ended on work that belongs
/// to the Host rather than to one session. A resume action is deliberately
/// separate from `.flush`: there may be no session and no bytes to write, but
/// stopping at `nextAction == null` would strand the Node's remaining work.
pub fn queueResumeAction(self: *Host) !void {
    if (self.resume_action_pending) return;
    try self.reserveActions(1);
    self.actions.pushReserved(.resume_work);
    self.resume_action_pending = true;
}

pub fn hasInternalWork(self: *const Host) bool {
    return self.pending_flush.peek() != null or
        self.node.hasAction() or
        self.node.nextHandoffChange() != null;
}

pub fn takeDirty(self: *Host) ?engine.PeerHandle {
    const peer_handle = self.pending_flush.pop(self.allocator) orelse return null;
    if (self.sessions.get(peer_handle)) |session| session.control.flush_pending = false;
    return peer_handle;
}

/// Remove a dying shell's queued encode row before its intrusive membership
/// bit disappears. Release is uncommon; the linear removal keeps steady-state
/// insertion O(1) without a second index and preserves `queue.len <= sessions`.
pub fn removeDirtySession(self: *Host, session: *HostSession) void {
    if (!session.control.flush_pending) return;
    var offset: usize = 0;
    while (offset < self.pending_flush.unpopped().len) : (offset += 1) {
        if (self.pending_flush.unpopped()[offset] != session.peer_handle) continue;
        _ = self.pending_flush.removeUnpopped(offset);
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
            .flush => |peer_handle| peer_handle == session.peer_handle,
            .close => |peer_handle| peer_handle == session.peer_handle,
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

pub fn queueHostAction(self: *Host, action: HostAction) !void {
    // The ceiling of already-promised notifications lives on the Host; this
    // append is the one slot beyond it.
    try self.reserveActions(1);
    self.actions.pushReserved(action);
}

/// Shared tag type so test seams and the private helper are one enum
/// (anonymous `enum { flush, close }` decls are distinct types in Zig).
pub const UniqueSessionActionTag = enum { flush, close };

/// One concept for session-tagged embedder actions: at most one pending
/// `.flush` / `.close` per `peer_handle` in the unpopped FIFO.
pub fn queueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_handle: engine.PeerHandle) void {
    const session = self.sessions.get(peer_handle) orelse return;
    const pending = switch (tag) {
        .flush => &session.control.flush_action_pending,
        .close => &session.control.close_action_pending,
    };
    if (pending.*) return;
    self.actions.pushReserved(switch (tag) {
        .flush => .{ .flush = peer_handle },
        .close => .{ .close = peer_handle },
    });
    pending.* = true;
}

const markDirtyForTesting = markDirty;
const queueUniqueSessionActionForTesting = queueUniqueSessionAction;

/// White-box pump support. Empty outside test builds.
pub const testing = if (builtin.is_test) struct {
    pub fn markDirty(self: *Host, peer_handle: engine.PeerHandle) void {
        markDirtyForTesting(self, peer_handle);
    }

    pub fn queueUniqueSessionAction(self: *Host, comptime tag: UniqueSessionActionTag, peer_handle: engine.PeerHandle) !void {
        queueUniqueSessionActionForTesting(self, tag, peer_handle);
    }
} else struct {};
