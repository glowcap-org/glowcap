//! Host-wide pump, fair readiness wait, and byte feeding.
//!
//! Every blocking and step-driven face shares this one read-feed-react cycle.
//! A sibling's protocol failure closes only that sibling, while the caller's
//! own failure propagates. A wire that cannot take its input for lack of
//! memory closes with that cause and ends nothing else. The wait rotates
//! which resident it reports first, and each resident drains its ready
//! records in bounded batches.

const std = @import("std");
const builtin = @import("builtin");

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
/// input feeds now while the session admits it, and a paused handshake tail
/// resumes through the next step's sweep. A session whose outbound stays at
/// its waterline keeps its parked input, and the sweep replays it once the
/// outbound drains.
/// Idempotent on a session already delivering. A foreign or unknown
/// handle refuses, exactly as release does, because silently ignoring
/// one leaves the real session's inbound held with nothing to say why.
pub fn attendSession(self: *HostRuntime, session: *driver_core.HostSession) !void {
    if (session.host != self.core) return Error.SessionNotOwned;
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    if (wire.closed or wire.attended) return;
    wire.attended = true;
    try replayParked(self, wire);
    self.held_input_possible = self.held_input_possible or holdsInput(wire);
    // A parked embedder must re-poll: the resumable tail is progress its
    // current wait set cannot see.
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| stepped.ready_set.postWake() catch |err| self.noteTerminalFailure(err),
    }
}

/// Feed the wire's parked input to the core, in order, while its session is
/// not pressured. Input the core took leaves the buffer, and the rest stays
/// parked for the sweep. A byte stream feeds as one buffer, and the core
/// keeps a suffix it paused on in its own tail. A message-framed wire feeds
/// one packet at a time and stops at the first pressured one. A refusal other
/// than pressure closes the wire.
fn replayParked(self: *HostRuntime, wire: *Wire) !void {
    const rl = &wire.link;
    if (rl.parked.items.len == 0) return;
    switch (wire.session.wire_framing) {
        .byte_stream => {
            if (pressuredAfterOffer(self, wire) or wire.closed) return;
            self.core.feedBytes(wire.session, rl.parked.items) catch |err| switch (err) {
                error.OutboundBackpressure => return,
                else => return closeWireForRefusedFeed(self, wire, err),
            };
            rl.dropParked(self.allocator, rl.parked.items.len);
        },
        .message => {
            var packets = rl.parkedPackets();
            var consumed: usize = 0;
            defer rl.dropParked(self.allocator, consumed);
            while (!pressuredAfterOffer(self, wire) and !wire.closed) {
                const packet = packets.next() orelse break;
                self.core.feedTransportPacket(wire.session, packet) catch |err| switch (err) {
                    // The refused packet stays parked.
                    error.OutboundBackpressure => return,
                    else => return closeWireForRefusedFeed(self, wire, err),
                };
                consumed = rl.parked.items.len - packets.rest.len;
            }
        },
    }
}

/// Whether `wire`'s session is at its outbound waterline once the window has
/// been offered what the core queued for it. The offer is made unless a
/// writable event is owed (`writableOwed`): queued output with no pending
/// write has not met the window, and a pending write after the closed edge
/// (`resident_closed`) has no event to report a window that reopened, so
/// holding input for either would strand the wire. A pending write with its
/// event owed means the window refused, so no attempt is made, and the
/// event's drain re-arms the sweep. A failed offer closes the wire the way a
/// writable event does. A wire still pressured after the closed edge closes
/// with `error.ConnectionLost`. Closing the wire answers false, so the caller
/// finds `wire.closed` set and holds nothing.
pub fn pressuredAfterOffer(self: *HostRuntime, wire: *Wire) bool {
    if (!wire.session.outboundPressured()) return false;
    if (!writableOwed(wire)) {
        Internal.writeOutbound(self, wire) catch |err| {
            Internal.closeWire(self, wire, err);
            return false;
        };
    }
    if (!wire.session.outboundPressured()) return false;
    if (wire.link.resident_closed) {
        Internal.closeWire(self, wire, error.ConnectionLost);
        return false;
    }
    return true;
}

/// Close `wire` for a feed the core refused, after draining the actions the
/// partial feed committed and offering the wire the output they queued. A
/// host retry deadline that is not due retains the drain, and the offer still
/// runs, because the output is already on the wire's session. The drain's own
/// failure is the caller's and closes the wire with the feed's cause,
/// unoffered. A failed offer closes the wire with its own failure, and the
/// send stays best effort.
fn closeWireForRefusedFeed(self: *HostRuntime, wire: *Wire, err: anyerror) !void {
    const failure = net.classifyApplyError(err);
    _ = Internal.attempt(self, .operational, .turn) catch |drain_err| {
        Internal.closeWire(self, wire, failure);
        return drain_err;
    };
    if (!wire.closed) Internal.writeOutbound(self, wire) catch |write_err| {
        Internal.closeWire(self, wire, write_err);
        return;
    };
    Internal.closeWire(self, wire, failure);
}

/// Move the input the runtime and the core hold, wire by wire, and report
/// whether any wire acted, which is progress no source reports.
/// The core stops consuming at the frame that opens a session, so frames
/// that coalesced behind the handshake hello wait in its tail, and no poll
/// will report them, because they already left the kernel. A wire's input
/// moves oldest first. Parked bytes replay first, then the core's held
/// input resumes, and then the read a hold left in the resident finishes.
/// A wire at its outbound waterline is offered its queued output first
/// (`pressuredAfterOffer`), so a window that opened since the last drain
/// releases the hold in the same sweep. A refusal closes that wire like any
/// dispatch refusal. The drain that follows a refused replay or resume is
/// host-wide work, so its failure (`closeWireForRefusedFeed`) ends the sweep.
/// The two `feedReadable` calls pass no owner and never fail, because that
/// function turns every failure into `.closed`.
/// A sweep that ends early has not asked the wires behind it. The wire it
/// stopped on held input, so `held_input_possible` is already set and the
/// next sweep walks them all.
///
/// The pause at the open exists so the embedder can finish post-open setup
/// (publish, spawn) before the partner's coalesced first frames dispatch, so
/// a session whose open has not yet committed keeps waiting: `skip`, the
/// session a handshake pump is itself opening, and any session a pending
/// open still owns, such as a listener arrival its accept observer has not
/// yet taken. Resuming either would answer a pipelined fetch before the
/// object it names exists. An unattended wire dispatches nothing, so the sweep
/// only finishes the read's end it owes (`endOwed`).
pub fn resumeFeedTails(self: *HostRuntime, skip: ?*driver_core.HostSession) !bool {
    var acted = false;
    self.held_input_possible = false;
    var it = self.wires.valueIterator();
    while (it.next()) |entry| {
        const wire = entry.*;
        const holds = !wire.closed and holdsInput(wire);
        self.held_input_possible = self.held_input_possible or holds;
        if (wire.session == skip or !sweepHolds(self, wire)) continue;
        if (!wire.attended) {
            acted = true;
            _ = try feedReadable(self, wire, null);
            continue;
        }
        if (pressuredAfterOffer(self, wire) or wire.closed) continue;
        acted = true;
        try replayParked(self, wire);
        if (wire.closed or wire.link.parked.items.len != 0) continue;
        wire.session.resumeFeed() catch |err| switch (err) {
            // The documented retry: the input stays held.
            error.OutboundBackpressure => {},
            else => {
                try closeWireForRefusedFeed(self, wire, err);
                continue;
            },
        };
        if (wire.link.read_deferred) {
            if (try feedReadable(self, wire, null) == .closed) continue;
        }
    }
    return acted;
}

/// Whether the next sweep has work on `wire` that no readiness source
/// reports: the sweep holds input for it (`sweepHolds`) and no writable
/// event is owed (`writableOwed`). With nothing held, the wire's own events
/// bring whatever remains. With a writable event owed, that event wakes the
/// embedder when the window opens, so polling for it would only spin. Held
/// input with no event owed is work the sweep acts on: it offers the queue,
/// then moves the input, closes the wire, or skips it while it is still
/// pressured, and the drain after it writes what the offer could not.
fn sweepCanMove(self: *const HostRuntime, wire: *const Wire) bool {
    return sweepHolds(self, wire) and !writableOwed(wire);
}

/// Whether the resident owes `wire` a writable event whose drain re-arms the
/// sweep: its session is at the waterline with a refused write pending, and
/// the resident has not reported the closed edge, after which the runtime
/// counts on no further event.
fn writableOwed(wire: *const Wire) bool {
    return wire.session.outboundPressured() and wire.link.pending != null and
        !wire.link.resident_closed;
}

/// Whether an unattended wire still owes the read of its stream's end: a read
/// was left for the sweep and the resident reported the partner's departure,
/// both while the wire was attended.
fn endOwed(wire: *const Wire) bool {
    return wire.link.resident_closed and wire.link.read_deferred;
}

/// Whether `wire` holds input no readiness source will report: bytes the
/// runtime kept (parked input or a deferred read) or input the core can
/// resume. The wire's own fields and its session's answer.
pub fn holdsInput(wire: *const Wire) bool {
    return wire.link.read_deferred or wire.link.parked.items.len != 0 or
        wire.session.inboundResumable();
}

/// Whether the sweep has work on `wire`, the one answer the sweep and the
/// park bound share. The wire is live and its open has committed. An attended
/// wire has work while it holds input (`holdsInput`). An unattended wire
/// dispatches nothing, so its only work is the read's end it owes
/// (`endOwed`), which the sweep reads and parks without feeding the core.
fn sweepHolds(self: *const HostRuntime, wire: *const Wire) bool {
    if (wire.closed or openPending(self, wire.session)) return false;
    return if (wire.attended) holdsInput(wire) else endOwed(wire);
}

/// Whether the next sweep would act on some wire other than `skip`'s: input
/// the runtime or the core holds that no readiness source will report. A
/// wait that parks with such work left strands it, so `stepSession`,
/// `stepAnyOwned` and `pumpUntilProbe` read this after the drain and poll
/// instead. `awaitResidentConnect` waits on one connect and does not.
pub fn sweepWorkRemains(self: *const HostRuntime, skip: ?*const driver_core.HostSession) bool {
    var it = self.wires.valueIterator();
    while (it.next()) |wire| {
        if (wire.*.session == skip) continue;
        if (sweepCanMove(self, wire.*)) return true;
    }
    return false;
}

/// The longest a wait may park: zero while the sweep has work for a wire
/// other than `skip`'s, because no source reports that work, else `timeout_ms`.
/// A zero timeout is already a poll. The walk runs only while
/// `held_input_possible`. Debug builds check that a skipped walk was right.
pub fn parkBoundMs(self: *const HostRuntime, timeout_ms: i32, skip: ?*const driver_core.HostSession) i32 {
    if (timeout_ms == 0) return 0;
    if (!self.held_input_possible) {
        if (comptime builtin.optimize == .debug) std.debug.assert(!sweepWorkRemains(self, skip));
        return timeout_ms;
    }
    return if (sweepWorkRemains(self, skip)) 0 else timeout_ms;
}

/// Bounded by `Options.max_pending_opens`, and reached only for a session
/// holding deferred or resumable input.
fn openPending(self: *const HostRuntime, session: *const driver_core.HostSession) bool {
    for (self.pending_opens.items) |row| if (row.stage.session() == session) return true;
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
        _ = try resumeFeedTails(self, probe.resumeSkip());
        _ = try Internal.attempt(self, .operational, .turn);
        try Internal.advancePendingOpens(self);
        Internal.advancePendingListeners(self);
        if (probe.done()) return;
        if (wireClosed(self, probe)) return Error.ConnectionClosed;

        const timeout: i32 = if (deadline_ms) |d| blk: {
            const remaining = d - self.nowMs();
            if (remaining <= 0) return Error.WaitTimedOut;
            break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
        } else -1;
        const wait_ms = parkBoundMs(self, timeout, probe.resumeSkip());

        // A probe wire closed in here surfaces at the loop top's
        // `wireClosed` check.
        const woke = try waitAnySource(self, wait_ms, false);
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
/// (a pre-wire resident dial wait) treats every wire as a sibling. A chunk
/// the wire could not retain for lack of memory is such a failure: the wire
/// closes with `OutOfMemory`, which `own` hears and a sibling does not, so
/// a blocking connect keeps its cause and the any-session step, which passes
/// no owner, never fails for it. Every failure leaves the wire closed,
/// because a read that failed after consuming its bytes must not feed the
/// next.
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
        else => |e| {
            Internal.closeWire(self, wire, e);
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

/// The off-turn settle mailbox (ADR-0014 stage 4), minted on the owning
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
    _ = Internal.attempt(self, effect_mode, .turn) catch |err| {
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
    _ = try Internal.attempt(self, .operational, .park);
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
        self.extra_fd_scratch.appendAssumeCapacity(self.residents.items[(start + k) % residents].readiness_fd);
    }
    if (self.mailbox) |mb| self.extra_fd_scratch.appendAssumeCapacity(mb.wakeFd());
    // The readiness wake polls as its own row, so a cross-thread
    // `wakeReadiness` interrupts a blocking wait here, not only an
    // embedder parked outside on the set descriptor.
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| self.extra_fd_scratch.appendAssumeCapacity(stepped.ready_set.wakeFd()),
    }
    // Admission reserved these rows (`providers.reserveWaitScratch`).
    std.debug.assert(self.extra_fd_scratch.items.len <= self.poll_scratch.capacity);
    self.poll_scratch.items.len = self.extra_fd_scratch.items.len;
    const idx = try net.waitAnyDescriptor(self.poll_scratch.items, wait_ms, self.extra_fd_scratch.items) orelse
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
