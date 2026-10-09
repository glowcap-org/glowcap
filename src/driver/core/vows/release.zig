//! Explicit Host-vow release and session-teardown retirement.

const std = @import("std");

const actors = @import("actors");

const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const settlement = @import("settlement.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const VowRow = settlement.VowRow;

fn cancelPending(self: *Host, row: *VowRow, session: *HostSession) !void {
    std.debug.assert(!row.settled);
    switch (row.pending_cancel) {
        .unpublished => unreachable,
        .row_listener => |installed| {
            const listener = session.served.port.takeListener(&self.vat, row.vow) orelse
                unreachable;
            std.debug.assert(listener.func == installed.func and listener.ctx == installed.ctx);
        },
        .infallible, .shared_answer => |owned| owned.func(self, row.id, owned.owner),
        .fallible_no_answer => |owned| {
            std.debug.assert(row.answer_release == .none);
            try owned.func(self, row.id, owned.owner);
        },
    }
    self.finishSessionOperation(session);
    settlement.markRowSettled(self, row);
}

fn cancelPendingTerminal(self: *Host, row: *VowRow, session: *HostSession) void {
    std.debug.assert(!row.settled);
    switch (row.pending_cancel) {
        .unpublished => unreachable,
        .row_listener => |installed| {
            const listener = session.served.port.takeListener(&self.vat, row.vow) orelse
                unreachable;
            std.debug.assert(listener.func == installed.func and listener.ctx == installed.ctx);
        },
        .infallible, .shared_answer => |owned| owned.func(self, row.id, owned.owner),
        .fallible_no_answer => |owned| owned.terminal_func(self, row.id, owned.owner),
    }
    self.finishSessionOperation(session);
    settlement.markRowSettled(self, row);
}

/// Retire an exact owned observer using its admission-reserved answer release.
/// No callback survives this boundary and cancellation requires no allocation.
/// The caller must possess the installed listener, not merely a public vow ID.
pub fn cancelObserved(self: *Host, vow_id: u64, listener: actors.Listener) void {
    self.assertOwner();
    const row = self.vows.get(vow_id) orelse unreachable;
    std.debug.assert(!row.settled and row.inner != null);
    std.debug.assert(row.inner.?.ctx == listener.ctx and row.inner.?.func == listener.func);
    const session = self.sessions.get(row.peer().?) orelse unreachable;
    cancelPendingTerminal(self, row, session);
    settlement.settleObservedAnswer(self, row, session);
    std.debug.assert(self.vows.remove(vow_id));
    self.allocator.destroy(row);
}

/// Release one public Host vow. A peer-visible answer emits `op:gc-answer`; a
/// local listen answer retires directly in Session; a local actor vow owns no
/// answer. Every fallible no-answer cancellation completes before another
/// effect, and peer-visible release is queued before infallible producer teardown,
/// so an error always leaves one retryable public handle.
pub fn release(self: *Host, vow_id: u64) !void {
    try self.refuseReentry();
    const row = self.vows.get(vow_id) orelse return;
    if (row.inner != null) return actors.Error.AlreadyListening;
    if (row.owner == .owning) {
        if (row.owner.owning.destination != .public) return error.SessionlessVow;
        @import("../host/local_completion.zig").releasePending(self, row);
        return;
    }
    const peer_handle = row.peer() orelse {
        std.debug.assert(row.settled);
        std.debug.assert(self.vows.remove(vow_id));
        self.allocator.destroy(row);
        return;
    };
    const session = self.sessions.get(peer_handle) orelse {
        std.debug.assert(row.settled);
        std.debug.assert(self.vows.remove(vow_id));
        self.allocator.destroy(row);
        return;
    };
    const wire_dead = switch (session.lifecyclePhase()) {
        .cancel_pending, .terminating => true,
        .active, .finishing => !session.sessionOpen(),
    };
    if (row.answer_release == .shared_peer_visible) {
        const owned = row.pending_cancel.shared_answer;
        if (!row.settled) {
            cancelPendingTerminal(self, row, session);
        } else {
            owned.func(self, row.id, owned.owner);
        }
        std.debug.assert(self.vows.remove(vow_id));
        self.allocator.destroy(row);
        host_pump.finishCommittedWork(self, session);
        return;
    }
    if (wire_dead) {
        if (!row.settled) cancelPendingTerminal(self, row, session);
        settlement.cancelObserverRelease(row, session);
        settlement.retireAnswerInSession(row, session);
        std.debug.assert(self.vows.remove(vow_id));
        self.allocator.destroy(row);
        return;
    }
    try self.checkSession(session);

    if (!row.settled and row.pending_cancel == .fallible_no_answer)
        try cancelPending(self, row, session);

    var flush = false;
    if (row.answer_release == .peer_visible) {
        const answer = switch (row.vow) {
            .far => |answer| answer,
            .local => unreachable,
        };
        const peer = session.served.port.peer;
        const reservation = try peer.reserveAnswerRelease();
        peer.publishAnswerRelease(reservation, answer);
        flush = true;
    }

    if (!row.settled) try cancelPending(self, row, session);
    if (row.answer_release == .session_private) settlement.retireAnswerInSession(row, session);
    std.debug.assert(self.vows.remove(vow_id));
    self.allocator.destroy(row);

    if (flush) {
        host_pump.markDirty(self, session.peer_handle);
        host_pump.finishCommittedWork(self, session);
    }
}

/// Retire every vow edge owned by `session` before its Port is freed. Resolver
/// rows are sessionless storage but can carry one deferred answer for this
/// session; ordinary rows cancel their exact producer before destruction.
pub fn dropSessionRows(self: *Host, session: *HostSession, reason: []const u8) void {
    const peer_handle = session.peer_handle;
    var doomed: [64]u64 = undefined;

    while (true) {
        var n: usize = 0;
        var resolvers = self.resolver_index.iterator();
        while (resolvers.next()) |entry| {
            const row = self.vows.get(entry.value_ptr.vow_id) orelse unreachable;
            if (row.forwardedPeer() != peer_handle) continue;
            doomed[n] = entry.key_ptr.*;
            n += 1;
            if (n == doomed.len) break;
        }
        if (n == 0) break;
        for (doomed[0..n]) |resolver_id| {
            const entry = self.resolver_index.get(resolver_id) orelse unreachable;
            const row = self.vows.get(entry.vow_id) orelse unreachable;
            std.debug.assert(row.forwardedPeer() == peer_handle);
            self.vat.breakVow(entry.vat_resolver, reason) catch unreachable;
            settlement.markRowSettled(self, row);
            std.debug.assert(self.resolver_index.remove(resolver_id));
            std.debug.assert(self.vows.remove(entry.vow_id));
            self.finishSessionOperation(session);
            self.allocator.destroy(row);
        }
    }

    while (true) {
        var n: usize = 0;
        var it = self.vows.iterator();
        while (it.next()) |entry| {
            const row_peer = entry.value_ptr.*.peer() orelse continue;
            if (row_peer != peer_handle) continue;
            doomed[n] = entry.key_ptr.*;
            n += 1;
            if (n == doomed.len) break;
        }
        if (n == 0) return;
        for (doomed[0..n]) |id| {
            const row = self.vows.get(id) orelse unreachable;
            settlement.cancelObserverRelease(row, session);
            if (!row.settled) {
                cancelPendingTerminal(self, row, session);
            } else if (row.answer_release == .shared_peer_visible) {
                const owned = row.pending_cancel.shared_answer;
                owned.func(self, row.id, owned.owner);
            }
            std.debug.assert(self.vows.remove(id));
            self.allocator.destroy(row);
        }
    }
}
