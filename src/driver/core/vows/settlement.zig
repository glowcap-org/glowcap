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
const asFarRef = @import("../host/capabilities/identity.zig").asFarRef;

/// One live public host-vow handle. The row holds the vow's single Vat
/// listener slot from mint (`fire`). Settlement records the outcome and ends
/// the pending session operation, but an embedder-owned handle remains live
/// until explicit release. Only a `peer_visible` answer is remotely
/// addressable and owns an `op:gc-answer`. A listen notification owns a
/// `session_private` answer that can be awaited but never sent to or released
/// on the wire. `inner` receives the resolution as a bounded borrow. Without
/// one, settlement queues an owned completion for the embedder.
pub const VowRow = struct {
    host: *Host,
    owner: union(enum) {
        session: engine.PeerHandle,
        resolver,
        /// A settled local public handle retains no producer or wire answer.
        public_local,
        /// Strong producer custody. Its observer is weak, so cancellation
        /// detaches only the result buffer, not this row or queued input.
        owning: *@import("../host/local_delivery.zig").Producer,
    },
    id: u64,
    vow: actors.Vow,
    kind: Kind = .plain,
    answer_release: AnswerRelease,
    /// Queue ownership prepared by `vowOn` for a remote answer. It remains a
    /// reservation while the observer is pending, becomes a POD engine carrier
    /// at settlement, and is cancelled if the session retires first.
    observer_release: ?engine.Peer.PendingReservation = null,
    pending_cancel: PendingCancel = .unpublished,
    inner: ?actors.Listener = null,
    settled: bool = false,
    /// The actual deferred reply destination, independent of the resolver
    /// row's sessionless storage. Owning results never pass through model refs.
    forwarded: union(enum) {
        none,
        session: struct { peer: engine.PeerHandle, local_answer: bool },
        owning: struct { producer: *@import("../host/local_delivery.zig").Producer, resolver: u64 },
    } = .none,

    pub fn forwardedPeer(self: *const VowRow) ?engine.PeerHandle {
        return if (self.forwarded == .session) self.forwarded.session.peer else null;
    }

    /// Settlement projection applied before dispatch. A fetch enrolls its
    /// fulfilled far capability under a node-unique route.
    pub const Kind = enum { plain, fetch };

    pub fn peer(self: *const VowRow) ?engine.PeerHandle {
        return switch (self.owner) {
            .session => |peer_handle| peer_handle,
            else => null,
        };
    }

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
    shared_peer_visible,
};

/// How explicit release cancels a producer that has not settled yet. Fallible
/// ownership is restricted to rows without an answer release, so retry cannot
/// follow an already-committed wire effect.
pub const PendingCancel = union(enum) {
    unpublished,
    /// Exact installed callback, whose code image may differ from the
    /// archive through which the embedder later releases this row.
    row_listener: actors.Listener,
    infallible: Infallible,
    /// A producer holds one shared answer through pending observation and
    /// settled public handles. The callback retires one member on either edge.
    shared_answer: Infallible,
    fallible_no_answer: Fallible,

    pub const Infallible = struct {
        owner: u64,
        func: *const fn (*Host, vow_id: u64, owner: u64) void,
    };

    /// Vow settlement's fallible half. Implementors are unknown at this
    /// declaration, so `func` keeps an `anyerror` return set.
    pub const Fallible = struct {
        owner: u64,
        func: *const fn (*Host, vow_id: u64, owner: u64) anyerror!void,
        terminal_func: *const fn (*Host, vow_id: u64, owner: u64) void,
    };

    comptime {
        std.debug.assert(@sizeOf(actors.Listener) <= @sizeOf(Fallible));
    }
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
/// Host-core internal. Exposed only because sibling modules share the owner.
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
    if (row.answer_release == .none or row.answer_release == .shared_peer_visible) return;
    const answer = switch (row.vow) {
        .far => |value| value,
        .local => unreachable,
    };
    session.served.port.peer.session_state.releaseOutboundAnswer(answer) catch unreachable;
}

/// The row's single terminal transition. An in-process listener consumes the
/// row. An embedder row remains addressable until explicit release and queues
/// its completion instead.
fn settleRow(self: *Host, row: *VowRow, resolution: actors.Resolution) void {
    std.debug.assert(!row.settled);
    const inner = row.inner;
    const kind = row.kind;
    if (row.owner == .owning) {
        const source = row.owner.owning;
        const public = source.destination == .public;
        if (public) row.owner = .public_local;
        source.settle(resolution);
        markRowSettled(self, row);
        if (!public) {
            std.debug.assert(self.vows.remove(row.id));
            self.allocator.destroy(row);
        }
        source.release();
        return;
    }
    const maybe_peer = row.peer();
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

pub fn settleObservedAnswer(self: *Host, row: *VowRow, session: *HostSession) void {
    switch (row.answer_release) {
        .none => {},
        .shared_peer_visible => {
            const owned = row.pending_cancel.shared_answer;
            owned.func(self, row.id, owned.owner);
        },
        .session_private => retireAnswerInSession(row, session),
        .peer_visible => {
            const reservation = row.observer_release orelse unreachable;
            const answer = switch (row.vow) {
                .far => |value| value,
                .local => unreachable,
            };
            const peer = session.served.port.peer;
            const answer_live = peer.session_state.outboundAnswer(answer) != null or peer.canObserveAnswer(answer);
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
/// routes to its exporter. Already-routed references pass through unchanged.
/// An unenrollable capability breaks rather than surfacing half-routable.
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
