//! Host-vow rows and their one settlement authority.
//!
//! A row's listener callback, pending-operation accounting, answer-release
//! ownership, action-queue completion, and fetched-capability enrollment all
//! change together. Keeping that transition here lets the public vow verbs
//! reserve and attach rows without carrying the terminal state machine beside
//! every send and projection operation.

const std = @import("std");

const actors = @import("actors");
const engine = @import("engine");

const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const completion = @import("completion.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const asFarRef = host_mod.asFarRef;

/// One live public host-vow handle. The row holds the vow's single Vat
/// listener slot from mint (`fire`). Settlement records the outcome and ends
/// the pending session operation, but an embedder-owned handle remains live
/// until explicit release. Only a `peer_visible` answer is remotely
/// addressable and owns an `op:gc-answer`; a listen notification owns a
/// `session_private` answer that can be awaited but never sent to or released
/// on the wire. `inner` receives the resolution as a bounded borrow; without
/// one, settlement queues an owned completion for the embedder.
pub const VowRow = struct {
    host: *Host,
    /// The session the vow rides, or null for a resolver row (ADR-0102).
    /// Session-scoped vow verbs refuse resolver rows; their holder settles and
    /// normally retires them directly.
    peer_handle: ?engine.PeerHandle,
    id: u64,
    vow: actors.Vow,
    kind: Kind = .plain,
    answer_release: AnswerRelease,
    /// Queue ownership prepared by `vowOn` for a remote answer. It remains a
    /// reservation while the observer is pending, becomes a POD engine carrier
    /// at settlement, and is cancelled if the session retires first.
    observer_release: ?engine.Peer.PendingReservation = null,
    pending_cancel: PendingCancel = .row_listener,
    inner: ?actors.Listener = null,
    settled: bool = false,
    /// The session whose turn deferred its answer onto this sessionless row.
    /// Its resolver settles outside `feed`, so this owner identifies the
    /// session to mark dirty and lets teardown cancel the deferred answer
    /// before freeing its Port.
    forwarded_peer: ?engine.PeerHandle = null,

    /// Settlement projection applied before dispatch. A fetch enrolls its
    /// fulfilled far capability under a node-unique route.
    pub const Kind = enum { plain, fetch };

    /// The retire listener installed at mint.
    pub fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const row: *VowRow = @ptrCast(@alignCast(ctx.?));
        settleRow(row.host, row, resolution);
    }
};

pub const AnswerRelease = enum {
    none,
    session_private,
    peer_visible,
};

/// How explicit release cancels a producer that has not settled yet. Fallible
/// ownership is restricted to rows without an answer release, so retry cannot
/// follow an already-committed wire effect.
pub const PendingCancel = union(enum) {
    row_listener,
    infallible: Infallible,
    fallible_no_answer: Fallible,

    pub const Infallible = struct {
        owner: u64,
        func: *const fn (*Host, vow_id: u64, owner: u64) void,
    };

    pub const Fallible = struct {
        owner: u64,
        func: *const fn (*Host, vow_id: u64, owner: u64) anyerror!void,
        terminal_func: *const fn (*Host, vow_id: u64, owner: u64) void,
    };
};

/// Host-core settlement accounting shared with resolver-pair ownership.
pub fn markRowSettled(self: *Host, row: *VowRow) void {
    std.debug.assert(!row.settled);
    std.debug.assert(self.pending_vow_count != 0);
    row.settled = true;
    self.pending_vow_count -= 1;
}

/// Claim the wire answer a peer-visible row will eventually release.
pub fn claimPeerVisibleAnswer(row: *const VowRow, session: *HostSession) bool {
    if (row.answer_release != .peer_visible) return true;
    const answer = switch (row.vow) {
        .far => |value| value,
        .local => unreachable,
    };
    const state = &session.served.port.peer.session_state;
    if (state.outboundAnswerReleaseClaimed(answer)) return true;
    return state.claimOutboundAnswerRelease(answer);
}

/// Settle a vow by id. A row already retired with its session has no recipient.
/// Host-core internal; exposed only because sibling modules share the owner.
pub fn fireVow(self: *Host, vow_id: u64, resolution: actors.Resolution) void {
    const row = self.vows.get(vow_id) orelse return;
    settleRow(self, row, resolution);
}

/// Cancel observer-owned release capacity before retiring a row.
pub fn cancelObserverRelease(row: *VowRow, session: *HostSession) void {
    const reservation = row.observer_release orelse return;
    session.served.port.peer.cancelPendingReservation(reservation);
    row.observer_release = null;
}

/// Retire the answer position a private or explicitly released row owns.
pub fn retireAnswerInSession(row: *const VowRow, session: *HostSession) void {
    if (row.answer_release == .none) return;
    const answer = switch (row.vow) {
        .far => |value| value,
        .local => unreachable,
    };
    session.served.port.peer.session_state.releaseOutboundAnswer(answer) catch unreachable;
}

/// The row's single terminal transition. An in-process listener consumes the
/// row; an embedder row remains addressable until explicit release and queues
/// its completion instead.
fn settleRow(self: *Host, row: *VowRow, resolution: actors.Resolution) void {
    std.debug.assert(!row.settled);
    const inner = row.inner;
    const kind = row.kind;
    const maybe_peer = row.peer_handle;
    const id = row.id;
    if (maybe_peer) |peer_handle| {
        if (self.sessions.get(peer_handle)) |session| {
            // Inline capability projection may publish the answer after this
            // Host row. A missing answer now means that send failed or the
            // session retired, so no wire release remains.
            if (!claimPeerVisibleAnswer(row, session)) {
                cancelObserverRelease(row, session);
                row.answer_release = .none;
            }
            self.finishSessionOperation(session);
        }
    }
    // Resolver settlement is the holder's own act and never queues an
    // embedder completion. Resolver verbs normally retire before Vat fire;
    // this arm keeps the callback defensive.
    const peer_handle = maybe_peer orelse {
        markRowSettled(self, row);
        std.debug.assert(self.vows.remove(id));
        self.allocator.destroy(row);
        if (inner) |listener| listener.func(listener.ctx, resolution);
        return;
    };
    const routed = if (kind == .fetch) enrollFetched(self, peer_handle, resolution) else resolution;
    if (inner) |listener| {
        const session = self.sessions.get(peer_handle) orelse unreachable;
        settleObservedAnswer(self, row, session);
        markRowSettled(self, row);
        std.debug.assert(self.vows.remove(id));
        self.allocator.destroy(row);
        listener.func(listener.ctx, routed);
        return;
    }
    markRowSettled(self, row);
    completion.queueVowCompletion(self, peer_handle, id, routed);
}

fn settleObservedAnswer(self: *Host, row: *VowRow, session: *HostSession) void {
    switch (row.answer_release) {
        .none => {},
        .session_private => retireAnswerInSession(row, session),
        .peer_visible => {
            const reservation = row.observer_release orelse unreachable;
            const answer = switch (row.vow) {
                .far => |value| value,
                .local => unreachable,
            };
            const answer_live = session.served.port.peer.session_state.outboundAnswer(answer) != null;
            if (answer_live and session.sessionOpen() and switch (session.lifecyclePhase()) {
                .active, .finishing => true,
                .cancel_pending, .terminating => false,
            }) {
                session.served.port.peer.publishAnswerRelease(reservation, answer);
                host_pump.markDirty(self, session.peer_handle);
            } else {
                session.served.port.peer.cancelPendingReservation(reservation);
            }
            row.observer_release = null;
        },
    }
}

/// Enroll a fetched far capability before dispatch so an immediate re-gift
/// routes to its exporter. Already-routed references pass through unchanged;
/// an unenrollable capability breaks rather than surfacing half-routable.
fn enrollFetched(self: *Host, peer_handle: engine.PeerHandle, resolution: actors.Resolution) actors.Resolution {
    if (resolution == .fulfilled and resolution.fulfilled == .reference and
        resolution.fulfilled.reference == .routed) return resolution;
    if (resolution == .fulfilled) if (asFarRef(resolution.fulfilled)) |far| {
        const route = self.node.enrollForeign(peer_handle, .{ .far = far }) catch |err| {
            return .{ .broken = @errorName(err) };
        };
        return .{ .fulfilled = .{ .reference = route } };
    };
    return resolution;
}
