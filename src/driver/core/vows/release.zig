//! Explicit Host-vow release and session-teardown retirement.

const std = @import("std");

const actors = @import("actors");

const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const settlement = @import("settlement.zig");
const capability_promise = @import("../capability_promise.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const VowRow = settlement.VowRow;
const PendingCancel = settlement.PendingCancel;

fn cancelPending(self: *Host, row: *VowRow, session: *HostSession) PendingCancel.CancelError!void {
    return cancelPendingWith(self, row, session, .fallible);
}

fn cancelPendingTerminal(self: *Host, row: *VowRow, session: *HostSession) void {
    cancelPendingWith(self, row, session, .terminal);
}

/// Whether a cancel may refuse. A terminal cancel runs where no refusal has
/// a receiver (teardown, a failed admission's unwind), so the fallible half
/// takes its terminal callback there.
const CancelMode = enum { fallible, terminal };

fn CancelResult(comptime mode: CancelMode) type {
    return switch (mode) {
        .fallible => PendingCancel.CancelError!void,
        .terminal => void,
    };
}

fn cancelPendingWith(self: *Host, row: *VowRow, session: *HostSession, comptime mode: CancelMode) CancelResult(mode) {
    std.debug.assert(!row.settled);
    switch (row.pending_cancel) {
        .unpublished => unreachable,
        .row_listener => |installed| {
            const listener = session.served.port.takeListener(&self.vat, row.vow) orelse
                unreachable;
            std.debug.assert(listener.func == installed.func and listener.ctx == installed.ctx);
        },
        .infallible, .shared_answer => |owned| owned.func(self, row.id, owned.owner),
        .fallible_no_answer => |owned| switch (mode) {
            .fallible => {
                std.debug.assert(row.answer_release == .none);
                try owned.func(self, row.id, owned.owner);
            },
            .terminal => owned.terminal_func(self, row.id, owned.owner),
        },
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
    if (row.watcher != null) {
        // A watching promise still needs the fire. The observer's release
        // reservation carries over to the row's own release there.
        row.inner = null;
        row.handle_released = true;
        return;
    }
    const session = self.sessions.get(row.peer().?) orelse unreachable;
    retireUnwatched(self, row, session);
}

/// Retire an unsettled row nothing holds any more, neither a handle, an
/// observer, nor a watching promise: cancel its producer, settle the answer
/// it observed, and free it.
pub fn retireUnwatched(self: *Host, row: *VowRow, session: *HostSession) void {
    cancelPendingTerminal(self, row, session);
    settlement.settleObservedAnswer(self, row, session);
    settlement.retireRow(self, row);
}

/// Release one public Host vow. A peer-visible answer emits `op:gc-answer`. A
/// local listen answer retires directly in Session. A local actor vow owns no
/// answer. Every fallible no-answer cancellation completes before another
/// effect, and peer-visible release is queued before infallible producer teardown,
/// so an error always leaves one retryable public handle.
///
/// Cancelling a producer can publish wire GC for its retained arguments. A pump
/// at that point could run the producer's own settlement, such as a promise
/// break parked behind outbound pressure, while this release still holds the
/// row and the operation. The callback latch holds until the row is retired,
/// and the committed work drains once afterward, including after a refusal.
pub fn release(self: *Host, vow_id: u64) !void {
    try self.refuseReentry();
    const row = self.vows.get(vow_id) orelse return;
    // A handle released while a promise watched the row is gone to the
    // application, so a second release finds nothing, as with a retired row.
    if (row.handle_released) return;
    if (row.inner != null) return error.AlreadyListening;
    // A row settled by its fire has a completion queued for the drain, or
    // drained already. A row this release cancels has neither.
    const fired = row.settled;
    if (row.owner == .owning) {
        if (row.owner.owning.destination != .public) return error.SessionlessVow;
        @import("../host/local_completion.zig").releasePending(self, row);
        return;
    }
    const peer_handle = row.peer() orelse {
        std.debug.assert(row.settled);
        retireReleased(self, row, fired);
        return;
    };
    const session = self.sessions.get(peer_handle) orelse {
        std.debug.assert(row.settled);
        retireReleased(self, row, fired);
        return;
    };
    const hold = self.callback_latch.hold();
    defer {
        hold.release();
        host_pump.finishCommittedWork(self, session);
    }
    const wire_dead = !session.wireLive();
    // A watching promise settles from the fire, so the row outlives its
    // handle and releases itself there (ADR-0068). A dead wire has no fire
    // to wait for, and the session's close breaks the promise.
    if (row.watcher != null and !row.settled and !wire_dead) {
        try self.checkSession(session);
        if (settlement.ownsWireAnswer(row, session))
            row.observer_release = try session.served.port.peer.reserveAnswerRelease();
        row.handle_released = true;
        return;
    }
    if (row.answer_release == .shared) {
        const owned = row.pending_cancel.shared_answer;
        if (!row.settled) {
            cancelPendingTerminal(self, row, session);
        } else {
            owned.func(self, row.id, owned.owner);
        }
        retireReleased(self, row, fired);
        return;
    }
    if (wire_dead) {
        if (!row.settled) cancelPendingTerminal(self, row, session);
        settlement.cancelObserverRelease(row, session);
        settlement.retireAnswerInSession(row, session);
        retireReleased(self, row, fired);
        return;
    }
    try self.checkSession(session);

    if (!row.settled and row.pending_cancel == .fallible_no_answer)
        try cancelPending(self, row, session);

    const wire_answer = settlement.ownsWireAnswer(row, session);
    if (wire_answer) {
        const answer = switch (row.vow) {
            .far => |answer| answer,
            .local => unreachable,
        };
        const peer = session.served.port.peer;
        const reservation = try peer.reserveAnswerRelease();
        peer.publishAnswerRelease(reservation, answer);
        host_pump.markDirty(self, session.peer_handle);
    }

    if (!row.settled) try cancelPending(self, row, session);
    if (row.answer_release == .owned and !wire_answer) settlement.retireAnswerInSession(row, session);
    retireReleased(self, row, fired);
}

/// Retire a released row, unless it fired and a promise asked for since
/// still waits on the drain for its staging (ADR-0068): then the handle goes
/// and the row stays for the drain, which stages the promise and retires the
/// row. A row this release cancelled has no drain coming and retires here.
fn retireReleased(self: *Host, row: *VowRow, fired: bool) void {
    if (fired and row.completion == .none) if (row.watcher) |watcher| if (capability_promise.vowPromiseAwaitsStaging(self, watcher)) {
        row.handle_released = true;
        return;
    };
    settlement.retireRow(self, row);
}

/// Retire every vow edge owned by `session` before its Port is freed. Resolver
/// rows are sessionless storage but can carry one deferred answer for this
/// session. Ordinary rows cancel their exact producer before destruction.
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
            self.vat.breakVow(entry.vat_resolver, reason) catch |err| switch (err) {
                // The reason could not be copied into the settle arena. The
                // vow still breaks, under a reason that needs no allocation.
                error.OutOfMemory => self.vat.breakVowTerminal(entry.vat_resolver, "session released"),
                // The row is indexed and unsettled, and rows drop only at the
                // top level, outside any turn or callback.
                else => unreachable,
            };
            settlement.markRowSettled(self, row);
            std.debug.assert(self.resolver_index.remove(resolver_id));
            settlement.retireRow(self, row);
            self.finishSessionOperation(session);
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
            } else if (row.answer_release == .shared) {
                const owned = row.pending_cancel.shared_answer;
                owned.func(self, row.id, owned.owner);
            }
            settlement.retireRow(self, row);
        }
    }
}
