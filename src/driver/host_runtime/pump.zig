//! Host-wide pump, fair readiness wait, and byte feeding.
//!
//! Every blocking and step-driven face shares this one read-feed-react cycle.
//! A sibling's protocol failure closes only that sibling, while the caller's
//! own failure propagates. The wait rotates which resident it reports first,
//! and each resident drains its ready records in bounded batches.

const std = @import("std");

const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const resident_pump = @import("resident_pump.zig");
const host_runtime = @import("../host_runtime.zig");
const settle_mailbox = @import("../settle_mailbox.zig");

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const Budget = driver_core.Budget;
const Error = driver_core.Error;
const ExternalEffectMode = lifecycle.ExternalEffectMode;
const Wire = HostRuntime.Wire;

/// Pump until `session`'s keyed handshake opens, under `budget`.
pub fn pumpHandshake(self: *HostRuntime, session: *driver_core.HostSession, budget: Budget) !void {
    var open = session.sessionOpen();
    var probe = SessionOpenProbe{ .session = session, .open = &open };
    pumpUntilProbe(self, &probe, budget) catch |err| switch (err) {
        Error.WaitTimedOut => return Error.HandshakeTimedOut,
        else => |e| return e,
    };
}

const SessionOpenProbe = struct {
    session: *driver_core.HostSession,
    open: *bool,
    fn done(self: *SessionOpenProbe) bool {
        self.open.* = self.session.sessionOpen();
        return self.open.*;
    }
    fn resumeSkip(self: *SessionOpenProbe) ?*driver_core.HostSession {
        return self.session;
    }
};

/// Stop dispatching `session`'s inbound until `attendSession`: the event
/// queue is about to surface it, and the embedder has not run its
/// post-open setup (publish, spawn). The resident parks what arrives in the
/// wire's bounded buffer until then.
pub fn markSessionUnattended(self: *HostRuntime, session: *driver_core.HostSession) void {
    const wire = self.wires.get(session.peer_handle) orelse return;
    if (wire.closed or !wire.attended) return;
    wire.attended = false;
}

/// The embedder announced it is serving `session`: deliver inbound from
/// here on. Bytes that arrived first replay in order: the link's parked
/// chunks feed now, and a paused handshake tail resumes through the next
/// step's sweep.
/// Idempotent on a session already delivering. A foreign or unknown
/// handle refuses, exactly as release does, because silently ignoring
/// one leaves the real session's inbound held with nothing to say why.
pub fn attendSession(self: *HostRuntime, session: *driver_core.HostSession) !void {
    if (session.host != self.core) return Error.SessionNotOwned;
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    if (wire.closed or wire.attended) return;
    wire.attended = true;
    const rl = &wire.link;
    if (rl.parked.items.len > 0) {
        const parked = rl.parked.items;
        self.core.feedBytes(wire.session, parked) catch |err| {
            const failure = net.classifyApplyError(err);
            self.drainActions() catch |drain_err| {
                Internal.closeWire(self, wire, failure);
                return drain_err;
            };
            Internal.closeWire(self, wire, failure);
            return;
        };
        rl.parked.clearAndFree(self.allocator);
    }
    while (rl.parked_packets.items.len > 0) {
        const packet = rl.parked_packets.orderedRemove(0);
        defer self.allocator.free(packet);
        rl.parked_packet_bytes -= packet.len;
        self.core.feedTransportPacket(wire.session, packet) catch |err| {
            const failure = net.classifyApplyError(err);
            self.drainActions() catch |drain_err| {
                Internal.closeWire(self, wire, failure);
                return drain_err;
            };
            Internal.closeWire(self, wire, failure);
            return;
        };
    }
    rl.parked_packets.clearAndFree(self.allocator);
    // A parked embedder must re-poll: the resumable tail is progress its
    // current wait set cannot see.
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| stepped.ready_set.postWake() catch |err| self.noteTerminalFailure(err),
    }
}

/// Resume any session whose `feed_tail` holds paused frames: the core
/// stops consuming at the frame that opens a session, so frames that
/// coalesced behind the handshake hello wait in the tail, and no poll
/// will ever report them, because they already left the kernel. Every
/// binding's serve loop resumes retained input before parking for exactly
/// this reason. This is the owning face's spelling of that contract. A
/// refusal closes that wire like any dispatch refusal.
///
/// The pause exists so the embedder can finish post-open setup (publish,
/// spawn) before the partner's coalesced first frames dispatch, so a session
/// whose open has not yet committed keeps waiting: `skip`, the session a
/// handshake pump is itself opening, and any session a pending open still
/// owns, such as a listener arrival its accept observer has not yet taken.
/// Resuming either would answer a pipelined fetch before the object it names
/// exists.
pub fn resumeFeedTails(self: *HostRuntime, skip: ?*driver_core.HostSession) !void {
    var it = self.wires.valueIterator();
    while (it.next()) |entry| {
        const wire = entry.*;
        if (wire.closed) continue;
        if (!wire.attended) continue;
        if (wire.session == skip) continue;
        const deferred = wire.link.read_deferred;
        if (!deferred and !wire.session.pausedInboundPending()) continue;
        if (openPending(self, wire.session)) continue;
        if (deferred) {
            wire.link.read_deferred = false;
            if (try feedReadable(self, wire, null) == .closed) continue;
        }
        if (wire.session.pausedInboundPending()) {
            wire.session.resumeFeed() catch |err| {
                const failure = net.classifyApplyError(err);
                self.drainActions() catch |drain_err| {
                    Internal.closeWire(self, wire, failure);
                    return drain_err;
                };
                Internal.closeWire(self, wire, failure);
                continue;
            };
        }
    }
}

/// Bounded by `Options.max_pending_opens`, and reached only for a session
/// holding deferred or paused input.
fn openPending(self: *const HostRuntime, session: *const driver_core.HostSession) bool {
    for (self.pending_opens.items) |row| if (row.session == session) return true;
    return false;
}

/// The blocking pump: drain actions, check `probe.done()`, wait for any
/// live wire's readable progress under what remains of `budget`, read and
/// feed, repeat. `Error.WaitTimedOut` on deadline. `Error.ConnectionClosed`
/// when the probe's own session closes first.
pub fn pumpUntilProbe(self: *HostRuntime, probe: anytype, budget: Budget) !void {
    self.readTurnClock();
    defer self.turn_ms = null;
    const deadline_ms: ?i64 = switch (budget) {
        .unbounded => null,
        .ms => |v| self.nowMs() + v,
    };
    while (true) {
        // Apply posted settles before anything else can consume the
        // iteration. The wake fd rides the poll set too, but a poll
        // reports the first ready row and a busy wire always precedes
        // it, so relying on that alone would starve the mailbox exactly
        // under the sustained traffic it exists for. This is one
        // uncontended lock and a count check, next to nothing beside the
        // poll below.
        try applySettleMailbox(self);
        try resumeFeedTails(self, probe.resumeSkip());
        try self.drainActions();
        try Internal.advancePendingOpens(self);
        Internal.advancePendingListeners(self);
        if (probe.done()) return;
        if (wireClosed(self, probe)) return Error.ConnectionClosed;

        const timeout: i32 = if (deadline_ms) |d| blk: {
            const remaining = d - self.nowMs();
            if (remaining <= 0) return Error.WaitTimedOut;
            break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
        } else -1;

        // A probe wire closed in here surfaces at the loop top's
        // `wireClosed` check.
        const woke = try waitAnySource(self, timeout, false);
        self.readTurnClock();
        const index = woke orelse continue;
        _ = try resident_pump.serviceResident(self, index, probeSession(probe));
        // A service is a turn of its own, so the next remaining-budget read
        // at the loop top counts the time it took.
        self.readTurnClock();
    }
}

const FeedOutcome = union(enum) { fed: usize, closed };

/// One readable wire's read-feed-react cycle, the one reaction every pump
/// spelling shares so their closure semantics cannot diverge. EOF and
/// transport faults close the wire here (vows break, the release stays
/// with the owner). A dispatch refusal already closed the offending wire
/// inside the read-and-feed arm. It propagates only when the misbehaving
/// session is `own`, because a sibling's protocol violation is that session's
/// closure, not a reason to abort an innocent caller's wait. A null `own`
/// (a pre-wire resident dial wait) treats every wire as a sibling.
pub fn feedReadable(self: *HostRuntime, wire: *Wire, own: ?*driver_core.HostSession) !FeedOutcome {
    const fed = resident_pump.readAndFeed(self, wire) catch |err| switch (err) {
        error.ConnectionLost => {
            Internal.closeWire(self, wire, error.ConnectionLost);
            return .closed;
        },
        error.TruncatedFrame => {
            Internal.closeWire(self, wire, error.TruncatedFrame);
            return .closed;
        },
        error.EndOfStream => {
            Internal.closeWire(self, wire, null);
            return .closed;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            if (own != null and wire.session == own.?) return e;
            return .closed;
        },
    };
    return .{ .fed = fed };
}

fn probeSession(probe: anytype) *driver_core.HostSession {
    return probe.session;
}

fn wireClosed(self: *HostRuntime, probe: anytype) bool {
    const session = probeSession(probe);
    const wire = self.wires.get(session.peer_handle) orelse return true;
    return wire.closed;
}

/// The off-turn settle mailbox (ADR-0102 stage 4), minted on the owning
/// thread the first time it is asked for. Hand the returned pointer (and
/// resolver ids) to worker threads. Their `post` calls wake this host's
/// readiness wait and the settles apply here, on the owning thread. The
/// mailbox lives until the host's own teardown.
pub fn settleMailbox(self: *HostRuntime) !*settle_mailbox.SettleMailbox {
    self.enterDriver();
    defer self.leaveDriver();
    if (self.mailbox) |mb| return mb;
    const mb = try settle_mailbox.SettleMailbox.init(self.allocator, settle_mailbox.default_slots);
    errdefer mb.deinit();
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try stepped.ready_set.add(mb.wakeFd()),
    }
    self.mailbox = mb;
    return mb;
}

/// Apply whatever a worker thread posted, on this owning thread. Cheap
/// and unconditional: the mailbox is empty in the ordinary case, and the
/// check is one lock acquisition.
pub fn applySettleMailbox(self: *HostRuntime) !void {
    try applySettleMailboxWith(self, .operational);
}

pub fn applySettleMailboxWith(self: *HostRuntime, effect_mode: ExternalEffectMode) !void {
    const mb = self.mailbox orelse return;
    var first_failure: ?anyerror = null;
    mb.drainWake() catch |err| {
        first_failure = err;
    };
    mb.apply(self.io, self.core) catch |err| {
        if (first_failure == null) first_failure = err;
    };
    Internal.drainActionsWith(self, effect_mode) catch |err| {
        if (first_failure == null) first_failure = err;
    };
    if (first_failure) |err| {
        self.noteTerminalFailure(err);
        return err;
    }
}

/// Wait for the first resident with a record, and return its index. Null on
/// timeout, and on the mailbox or readiness wake (applying is the loop top's
/// job, which runs whether or not the wait happened to select that row). A
/// resident holding records no descriptor reports is returned before any
/// wait, and a resident with timed work bounds the wait and is serviced when
/// the wait ends on its bound.
///
/// When every resident parks, the first one is the park: it watches the
/// mailbox, the stepped ready set's wake, and its siblings' readiness
/// descriptors, and the wait runs inside its kernel queue, so the work the
/// kernel owes this thread for a completion runs inside the one wake.
/// Otherwise the wait polls every readiness descriptor.
pub fn waitAnySource(self: *HostRuntime, requested_ms: i32, empty_ok: bool) !?usize {
    const timeout_ms = requested_ms;
    Internal.progressCarrierCloseDeadlines(self);
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| stepped.ready_set.drainWake() catch |err| {
            self.noteTerminalFailure(err);
            return err;
        },
    }
    // The park is where no message of ours will come along for a held
    // answer release to ride: encode them now, and write them with the
    // drain, so the submit below carries them.
    if (try self.core.flushHeldReleases()) try self.drainActions();
    // A blocking verb with no source left has nothing that can ever wake
    // it; `stepAny` passes `empty_ok` because a step-driven host with no
    // session yet is parked on its own budget, not stranded.
    if (self.residents.items.len == 0 and !empty_ok)
        return Error.ConnectionClosed;
    const residents = self.residents.items.len;
    const start = if (residents > 0) self.wait_cursor % residents else 0;
    self.wait_cursor +%= 1;
    const parking = Internal.parkingResident(self);
    if (parking) try Internal.watchWakeSources(self);
    Internal.flushResidents(self, .park);
    if (Internal.readyResident(self, start)) |index| return index;
    // The nearest pending deadline bounds the spin as it bounds the park, so
    // a close grace or a dial budget due inside the window is noticed by the
    // wait that spans it.
    var wait_ms = Internal.clampTimeoutToPendingWork(self, timeout_ms);
    // A runtime that owns its core spins here before it parks, reaping
    // every resident on each pass, so a reply that lands inside the window
    // is serviced without a descriptor wake.
    if (self.opts.busy_poll_ns != 0 and residents > 0) {
        const found = Internal.spinForRecords(self, start, &wait_ms);
        // The spin is a wait: the turn clock moves past it, so the park's
        // remaining budget and the deadlines below are read from now.
        self.readTurnClock();
        if (found) |index| return index;
        // The spin reaped with every resident looking. The park is next, so
        // a resident whose writers wake only a parked owner arms its wake
        // now, and what that flush completes is taken before the park.
        Internal.flushResidents(self, .park);
        if (Internal.readyResident(self, start)) |index| return index;
    }
    var timed_resident: ?usize = null;
    for (self.residents.items, 0..) |registered, index| {
        const bound = registered.resident.waitBoundMs(wait_ms);
        if (bound >= 0 and (wait_ms < 0 or bound < wait_ms)) {
            wait_ms = bound;
            timed_resident = index;
        }
    }
    if (parking) {
        const woke = self.residents.items[0].resident.park(wait_ms);
        // A sibling's readiness ended the park through the watch on its
        // descriptor: it reaps now, as the descriptor poll would have
        // selected it.
        for (self.residents.items[1..]) |registered| registered.resident.reap();
        if (Internal.readyResident(self, start)) |index| return index;
        return if (woke) null else timed_resident;
    }
    self.extra_fd_scratch.clearRetainingCapacity();
    for (0..residents) |k| {
        try self.extra_fd_scratch.append(self.allocator, self.residents.items[(start + k) % residents].readiness_fd);
    }
    if (self.mailbox) |mb| try self.extra_fd_scratch.append(self.allocator, mb.wakeFd());
    // The readiness wake polls as its own row, so a cross-thread
    // `wakeReadiness` interrupts a blocking wait here, not only an
    // embedder parked outside on the set descriptor.
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try self.extra_fd_scratch.append(self.allocator, stepped.ready_set.wakeFd()),
    }
    try self.poll_scratch.resize(self.allocator, self.extra_fd_scratch.items.len);
    const idx = try net.waitAnyReadable(&.{}, self.poll_scratch.items, wait_ms, self.extra_fd_scratch.items) orelse
        return timed_resident;
    if (idx < residents) return (start + idx) % residents;
    return null;
}

/// Whether the first resident is the park: every resident offers one, and
/// there is at least one.
pub fn parkingResident(self: *const HostRuntime) bool {
    if (self.residents.items.len == 0) return false;
    for (self.residents.items) |registered| if (!registered.resident.parks()) return false;
    return true;
}

/// Hand the parking resident every wake descriptor it does not watch yet:
/// the mailbox, the stepped ready set's wake, and its siblings' readiness
/// descriptors. A source minted after the last park is handed over at the
/// next one, so `watched_fds` only grows.
pub fn watchWakeSources(self: *HostRuntime) !void {
    const parker = self.residents.items[0].resident;
    for (self.residents.items[1..]) |registered| try watchWakeSource(self, parker, registered.readiness_fd);
    if (self.mailbox) |mb| try watchWakeSource(self, parker, mb.wakeFd());
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try watchWakeSource(self, parker, stepped.ready_set.wakeFd()),
    }
}

fn watchWakeSource(self: *HostRuntime, parker: net.MultiplexedResident, fd: i32) !void {
    for (self.watched_fds.items) |known| if (known == fd) return;
    try self.watched_fds.ensureUnusedCapacity(self.allocator, 1);
    try parker.watch(fd);
    self.watched_fds.appendAssumeCapacity(fd);
}
