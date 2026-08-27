//! Host-wide pump, fair readiness wait, and byte feeding.
//!
//! Every blocking and step-driven face shares this one read-feed-react cycle.
//! A sibling's protocol failure closes only that sibling, while the caller's
//! own failure propagates; readiness rotation and resident batch drains retain
//! the existing bounded scheduling and allocation behavior.

const std = @import("std");

const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const pending_state = @import("pending.zig");
const resident_pump = @import("resident_pump.zig");
const runtime_readiness = @import("readiness.zig");
const host_runtime = @import("../host_runtime.zig");
const settle_mailbox = @import("../settle_mailbox.zig");

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const Budget = driver_core.Budget;
const Error = driver_core.Error;
const ExternalEffectMode = lifecycle.ExternalEffectMode;
const ReadySource = runtime_readiness.Source;
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
/// post-open setup (publish, spawn). A stream wire's socket leaves the
/// readiness set so kernel-held bytes cannot spin a parked embedder;
/// `waitAnySource` already skips unattended wires.
pub fn markSessionUnattended(self: *HostRuntime, session: *driver_core.HostSession) void {
    const wire = self.wires.get(session.peer_handle) orelse return;
    if (wire.closed or !wire.attended) return;
    wire.attended = false;
    switch (wire.link) {
        .stream => |*sl| if (sl.conn.socketHandle()) |fd| Internal.removeReadyFd(self, fd),
        .resident => {},
    }
}

/// The embedder announced it is serving `session`: deliver inbound from
/// here on. Bytes that arrived first replay in order — a resident link's
/// parked chunks feed now, a paused handshake tail resumes through the
/// next step's sweep, and a stream socket rejoins the readiness set.
/// Idempotent on a session already delivering; a foreign or unknown
/// handle refuses, exactly as release does, because silently ignoring
/// one leaves the real session's inbound held with nothing to say why.
pub fn attendSession(self: *HostRuntime, session: *driver_core.HostSession) !void {
    if (session.host != self.core) return Error.SessionNotOwned;
    const wire = self.wires.get(session.peer_handle) orelse return Error.SessionNotOwned;
    if (wire.session != session) return Error.SessionNotOwned;
    if (wire.closed or wire.attended) return;
    wire.attended = true;
    switch (wire.link) {
        .stream => |*sl| if (self.ready_set) |*rs| if (sl.conn.socketHandle()) |fd| {
            rs.add(fd) catch |err| {
                wire.attended = false;
                return err;
            };
        },
        .resident => |*rl| {
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
        },
    }
    // A parked embedder must re-poll: the rejoined fd or the resumable
    // tail is progress its current wait set cannot see.
    if (self.ready_set) |*rs| rs.postWake() catch |err| self.noteTerminalFailure(err);
}

/// Resume any session whose `feed_tail` holds paused frames: the core
/// stops consuming at the frame that opens a session, so frames that
/// coalesced behind the handshake hello wait in the tail — and no poll
/// will ever report them, because they already left the kernel. Every
/// binding's serve loop resumes retained input before parking for exactly
/// this reason; this is the owning face's spelling of that contract. A
/// refusal closes that wire like any dispatch refusal.
///
/// `skip` is the session a handshake pump is itself opening: its paused
/// frames must keep waiting, because the pause exists so the embedder can
/// finish post-open setup (publish, spawn) before the partner's coalesced
/// first frames dispatch. Resuming it here would answer a pipelined fetch
/// before the object it names exists.
pub fn resumeFeedTails(self: *HostRuntime, skip: ?*driver_core.HostSession) !void {
    var it = self.wires.valueIterator();
    while (it.next()) |entry| {
        const wire = entry.*;
        if (wire.closed) continue;
        if (!wire.attended) continue;
        if (wire.session == skip) continue;
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

/// The blocking pump: drain actions, check `probe.done()`, wait for any
/// live wire's readable progress under what remains of `budget`, read and
/// feed, repeat. `Error.WaitTimedOut` on deadline; `Error.ConnectionClosed`
/// when the probe's own session closes first.
pub fn pumpUntilProbe(self: *HostRuntime, probe: anytype, budget: Budget) !void {
    const deadline_ms: ?i64 = switch (budget) {
        .unbounded => null,
        .ms => |v| net.clock.nowMs(self.io) + v,
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
            const remaining = d - net.clock.nowMs(self.io);
            if (remaining <= 0) return Error.WaitTimedOut;
            break :blk std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
        } else -1;

        const source = try waitAnySource(self, timeout, false) orelse continue;
        switch (source) {
            .wire => |wire| switch (try serviceReadyWire(self, wire, probeSession(probe))) {
                .fed => {},
                .closed => if (wire.session == probeSession(probe)) return Error.ConnectionClosed,
            },
            // A probe wire closed in here surfaces at the loop top's
            // `wireClosed` check.
            .resident => |index| _ = try resident_pump.serviceResident(self, index, probeSession(probe)),
            .stream_dial => |row| try Internal.adoptPendingStreamDial(self, row),
            .stream_listen => |row| Internal.finishPendingListener(self, row),
            .stream_accept => |listener| _ = try self.acceptReady(listener),
        }
    }
}

const FeedOutcome = union(enum) { fed: usize, closed };

pub fn serviceReadyWire(self: *HostRuntime, wire: *Wire, own: ?*driver_core.HostSession) !FeedOutcome {
    if (wire.closed) {
        Internal.progressWireCarrierClose(self, wire);
        return .closed;
    }
    return feedReadable(self, wire, own);
}

/// One readable wire's read-feed-react cycle, the one reaction every pump
/// spelling shares so their closure semantics cannot diverge. EOF and
/// transport faults close the wire here (vows break; the release stays
/// with the owner). A dispatch refusal already closed the offending wire
/// inside the read-and-feed arm; it propagates only when the misbehaving
/// session is `own` — a sibling's protocol violation is that session's
/// closure, not a reason to abort an innocent caller's wait. A null `own`
/// (a pre-wire resident dial wait) treats every wire as a sibling.
pub fn feedReadable(self: *HostRuntime, wire: *Wire, own: ?*driver_core.HostSession) !FeedOutcome {
    const read_arm = switch (wire.link) {
        .stream => readAndFeed(self, wire),
        .resident => resident_pump.readAndFeed(self, wire),
    };
    const fed = read_arm catch |err| switch (err) {
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
/// resolver ids) to worker threads; their `post` calls wake this host's
/// readiness wait and the settles apply here, on the owning thread. The
/// mailbox lives until the host's own teardown.
pub fn settleMailbox(self: *HostRuntime) !*settle_mailbox.SettleMailbox {
    self.enterDriver();
    defer self.leaveDriver();
    if (self.mailbox) |mb| return mb;
    const mb = try settle_mailbox.SettleMailbox.init(self.allocator, settle_mailbox.default_slots);
    errdefer mb.deinit();
    if (self.ready_set) |*rs| try rs.add(mb.wakeFd());
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

/// Fill the scratch lists with the live stream wires and every resident's
/// readiness descriptor, and wait for the first ready source. Null on
/// timeout, and on the mailbox wake (applying is the loop top's job,
/// which runs whether or not the poll happened to select that row).
pub fn waitAnySource(self: *HostRuntime, timeout_ms: i32, empty_ok: bool) !?ReadySource {
    Internal.progressCarrierCloseDeadlines(self);
    if (self.ready_set) |*rs| rs.drainWake() catch |err| {
        self.noteTerminalFailure(err);
        return err;
    };
    self.conn_scratch.clearRetainingCapacity();
    var it = self.wires.valueIterator();
    while (it.next()) |wire| {
        if (wire.*.link != .stream) continue;
        if (!wire.*.closed and wire.*.attended) {
            try self.conn_scratch.append(self.allocator, wire.*);
        } else if (wire.*.closed and !wire.*.carrierClosed()) switch (wire.*.carrier_close) {
            .wait_read, .wait_write => try self.conn_scratch.append(self.allocator, wire.*),
            .open, .wait_resident, .complete => {},
        };
    }
    var retiring = self.retiring_wires;
    while (retiring) |wire| : (retiring = wire.retiring_next) switch (wire.link) {
        .stream => switch (wire.carrier_close) {
            .wait_read, .wait_write => try self.conn_scratch.append(self.allocator, wire),
            .open, .wait_resident, .complete => {},
        },
        .resident => {},
    };
    const n = self.conn_scratch.items.len;
    // A blocking verb with no source left has nothing that can ever wake
    // it; `stepAny` passes `empty_ok` because a step-driven host with no
    // session yet is parked on its own budget, not stranded.
    var staged_stream_dials: usize = 0;
    for (self.pending_opens.items) |row| if (row.stage == .stream_dial) {
        staged_stream_dials += 1;
    };
    if (n == 0 and self.residents.items.len == 0 and staged_stream_dials == 0 and
        self.pending_listeners.items.len == 0 and !empty_ok)
        return Error.ConnectionClosed;
    if (n > 0) {
        std.mem.rotate(*Wire, self.conn_scratch.items, self.wait_cursor % n);
        self.wait_cursor +%= 1;
    }
    self.extra_fd_scratch.clearRetainingCapacity();
    for (self.residents.items) |runtime| {
        try self.extra_fd_scratch.append(self.allocator, runtime.readiness_fd);
    }
    self.dial_scratch.clearRetainingCapacity();
    for (self.pending_opens.items) |row| switch (row.stage) {
        .stream_dial => |attempt| {
            try self.dial_scratch.append(self.allocator, row);
            try self.extra_fd_scratch.append(self.allocator, attempt.readinessFd());
        },
        .resident_dial, .handshake => {},
    };
    self.listen_scratch.clearRetainingCapacity();
    for (self.pending_listeners.items) |row| switch (row.stage) {
        .stream => |attempt| {
            try self.listen_scratch.append(self.allocator, row);
            try self.extra_fd_scratch.append(self.allocator, attempt.readinessFd());
        },
        .resident => {},
    };
    self.active_listener_scratch.clearRetainingCapacity();
    var listener_it = self.active_listeners.valueIterator();
    while (listener_it.next()) |listener| {
        if (listener.closing) continue;
        switch (listener.transport.source) {
            .stream => |stream| if (stream.handle.readinessFd()) |fd| {
                try self.active_listener_scratch.append(self.allocator, &listener.transport);
                try self.extra_fd_scratch.append(self.allocator, fd);
            },
            .resident => {},
        }
    }
    if (self.mailbox) |mb| try self.extra_fd_scratch.append(self.allocator, mb.wakeFd());
    // The readiness wake polls as its own row, so a cross-thread
    // `wakeReadiness` interrupts a blocking wait here, not only an
    // embedder parked outside on the set descriptor.
    if (self.ready_set) |*rs| try self.extra_fd_scratch.append(self.allocator, rs.wakeFd());
    try self.poll_scratch.resize(self.allocator, n + self.extra_fd_scratch.items.len);
    // Borrow the connections for the wait through retained scratch; net
    // polls, we route by index, and the wait itself allocates nothing
    // once the lists have grown to the live-wire count.
    try self.borrow_scratch.resize(self.allocator, n);
    try self.wait_interest_scratch.resize(self.allocator, n);
    for (self.conn_scratch.items, 0..) |wire, i| {
        self.borrow_scratch.items[i] = &wire.link.stream.conn;
        self.wait_interest_scratch.items[i] = if (!wire.closed or wire.carrier_close == .wait_read)
            .read
        else
            .write;
    }
    const idx = try net.waitAny(
        self.borrow_scratch.items,
        self.wait_interest_scratch.items,
        self.poll_scratch.items,
        Internal.clampTimeoutToPendingWork(self, timeout_ms),
        self.extra_fd_scratch.items,
        &.{},
    ) orelse return null;
    if (idx < n) return .{ .wire = self.conn_scratch.items[idx] };
    const extra = idx - n;
    if (extra < self.residents.items.len) return .{ .resident = extra };
    const dial_index = extra - self.residents.items.len;
    if (dial_index < self.dial_scratch.items.len)
        return .{ .stream_dial = self.dial_scratch.items[dial_index] };
    const listen_index = dial_index - self.dial_scratch.items.len;
    if (listen_index < self.listen_scratch.items.len)
        return .{ .stream_listen = self.listen_scratch.items[listen_index] };
    const accept_index = listen_index - self.listen_scratch.items.len;
    if (accept_index < self.active_listener_scratch.items.len)
        return .{ .stream_accept = self.active_listener_scratch.items[accept_index] };
    return null;
}

/// One raw read off `wire`; the core owns outer framing and its tail.
fn readAndFeed(self: *HostRuntime, wire: *Wire) !usize {
    const r = wire.link.stream.conn.r;
    if (r.bufferedLen() == 0) {
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return if (wire.session.feed_tail.isActive()) error.TruncatedFrame else error.EndOfStream,
            error.ReadFailed => return error.ConnectionLost,
        };
    }
    const chunk = r.buffered();
    self.core.feedBytes(wire.session, chunk) catch |err| {
        // The core projected a typed op:abort for a session-authority
        // refusal; write it (the flush action is queued) and surface the
        // pump vocabulary the borrowing tier speaks, so `serve` and the
        // blocking waits see `ProtocolAbort`, not the raw refusal.
        r.toss(chunk.len);
        const failure = net.classifyApplyError(err);
        self.drainActions() catch |drain_err| {
            Internal.closeWire(self, wire, failure);
            return drain_err;
        };
        Internal.writeOutbound(self, wire) catch |write_err| {
            Internal.closeWire(self, wire, write_err);
            return failure;
        };
        Internal.closeWire(self, wire, failure);
        return failure;
    };
    r.toss(chunk.len);
    return chunk.len;
}
