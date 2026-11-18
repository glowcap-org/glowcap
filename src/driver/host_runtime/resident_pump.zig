//! Multiplexed-resident ready-record service for HostRuntime.

const std = @import("std");

const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const pending_state = @import("pending.zig");
const resident_state = @import("resident.zig");
const host_runtime = @import("../host_runtime.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const PendingOpen = pending_state.Open;
const ResidentRequestKey = resident_state.RequestKey;
const SessionAcceptObservation = lifecycle.SessionAcceptObservation;
const Wire = HostRuntime.Wire;

/// Ensure a provider cause is latched for a check a provider answers (a drain
/// or remote-key error): an adapted provider has already latched its exact
/// chain, which a second latch would only pad with a duplicate, and a Zig
/// resident latches nothing of its own. A violation only the runtime sees
/// latches through `failProviderContract` whatever is already held, so it
/// joins the chain as a consequence.
fn ensureProviderCause(self: *HostRuntime) void {
    if (self.terminal_failure == null) self.failProviderContract();
}

/// Drain and answer one resident's ready records: dial completions release their
/// awaiting dials, readable connections feed the core, writable ones resume
/// retained outbound, and closed ones close their wires. `own` carries the
/// calling wait's session so a sibling's dispatch refusal closes the sibling
/// instead of aborting the caller, exactly as stream `feedReadable` holds.
pub fn serviceResident(self: *HostRuntime, resident_index: usize, own: ?*driver_core.HostSession) !usize {
    const resident = self.residents.items[resident_index].resident;
    var own_fed: usize = 0;
    const events = resident.drainReady(&self.event_scratch) catch |err| {
        // The provider's own violation: a count past the buffer, or a
        // provider that already failed and reports `ProviderContract` for
        // every later drain. No caller caused it, and no record of the drain
        // survives.
        ensureProviderCause(self);
        return err;
    };
    // `drainReady` already took every record from the resident, so one
    // event's refusal must not abandon the siblings drained behind it: each
    // is served, and the first refusal is reported afterward, as the
    // completion loop's `dispatchBatch` holds.
    const latched_before = self.terminal_failure != null;
    var first_err: ?anyerror = null;
    for (events) |event| {
        own_fed += handleResidentEvent(self, resident_index, event, own) catch |err| blk: {
            if (first_err == null) first_err = err;
            break :blk 0;
        };
    }
    if (first_err) |err| return err;
    // An arrival's own catch absorbs its refusal, but a provider violation or
    // a failed claimed close latches terminal failure inside the batch. Every
    // caller, session waits included, learns of it here and stops.
    if (!latched_before) {
        if (self.terminal_failure) |failure| return failure.chain.cause;
    }
    return own_fed;
}

fn handleResidentEvent(
    self: *HostRuntime,
    resident_index: usize,
    event: net.multiplexed_resident.ReadyEvent,
    own: ?*driver_core.HostSession,
) !usize {
    const er = net.multiplexed_resident;
    if (event.events & er.ev_listen != 0) {
        if (Internal.pendingResidentListener(self, resident_index, event.subject)) |row| {
            Internal.finishPendingListener(self, row);
        } else if (self.resident_listeners.get(.{
            .resident = resident_index,
            .route = event.subject,
        })) |listener| {
            if (self.active_listeners.get(listener.observation.tag)) |active| {
                if (active.closing) {
                    const outcome = Internal.closeActiveListener(self, listener.observation.tag, true);
                    std.debug.assert(outcome.found and !outcome.pending);
                    return 0;
                }
            }
        } else if (self.residents.items[resident_index].resident.acceptor()) |acceptor| {
            if (acceptor.cancelListen(event.subject)) |failure| Internal.noteTerminalFailureChain(self, failure);
        }
        return 0;
    }
    if (event.events & er.ev_accept != 0) {
        const listener = self.resident_listeners.get(.{
            .resident = resident_index,
            .route = event.subject,
        }) orelse return 0;
        if (self.active_listeners.get(listener.observation.tag)) |active| {
            if (active.closing) {
                var refused = switch (listener.listener.finishAcceptOutcome()) {
                    .connection => |conn| conn orelse return 0,
                    .failed => |failure| {
                        self.noteTerminalOperationFailure(.fromAcceptFailure(failure));
                        return 0;
                    },
                };
                if (refused.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
                return 0;
            }
        }
        var conn = switch (listener.listener.finishAcceptOutcome()) {
            .connection => |conn| conn orelse return 0,
            .failed => |failure| {
                Internal.failActiveListener(self, listener.observation.tag, OperationFailure.fromAcceptFailure(failure));
                return 0;
            },
        };
        defer if (conn.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
        // A claim that borrows no connection breaks the accept contract.
        const conn_id = conn.borrow() orelse {
            self.failProviderContract();
            return error.ProviderContract;
        };
        // The provider already removed this connection from its accept queue. An
        // over-limit arrival closes here without a session or retained buffers.
        // Level-shaped readiness brings the next accept through a later step.
        if (!Internal.pendingOpenSlotAvailable(self)) return 0;
        if (!listener.observation.observer.can_accept(listener.observation.observer.ctx)) return 0;
        // A listener is ready before its caller can select a location, and a
        // session cannot open without one. An arrival in that window closes,
        // so a peer's timing never fails the step.
        if (self.core.acceptableLocator() == null) return 0;
        // A local failure admitting this arrival retires only the arrival:
        // `conn`'s deferred release closes it, and the listener, its siblings
        // and the runtime carry on.
        startAcceptedConn(
            self,
            resident_index,
            &conn,
            conn_id,
            listener.transport,
            listener.observation,
        ) catch |err| retireArrival(self, listener.observation, err);
        return 0;
    }
    if (event.events & er.ev_connect != 0) {
        const dialer = self.residents.items[resident_index].resident.dialer() orelse {
            self.failProviderContract();
            return error.ProviderContract;
        };
        const request_key = ResidentRequestKey{ .resident = resident_index, .request = event.subject };
        if (self.pending_resident_dials.get(request_key)) |wait| {
            wait.ready = true;
        } else if (Internal.pendingOpenByRequest(self, resident_index, event.subject)) |row| {
            Internal.adoptPendingResidentDial(self, resident_index, row);
        } else {
            // The awaiting frame unwound before the connect completed; release
            // the resident's half.
            if (dialer.cancelDial(event.subject)) |failure| Internal.noteTerminalFailureChain(self, failure);
        }
        return 0;
    }
    const wire = self.resident_wires.get(.{
        .resident = resident_index,
        .conn = event.subject,
    }) orelse {
        if (event.events & er.ev_closed != 0) switch (self.residents.items[resident_index].resident.connCloseOutcome(event.subject, .no_wait)) {
            .complete => {},
            .pending => self.noteTerminalFailure(error.ProviderContract),
            .failed => |failure| self.noteTerminalOperationFailure(.fromReport(failure)),
        };
        return 0;
    };
    if (wire.closed) {
        Internal.progressWireCarrierClose(self, wire);
        return 0;
    }
    if (event.events & er.ev_writable != 0) {
        Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
        if (wire.closed) return 0;
    }
    var own_fed: usize = 0;
    if (event.events & er.ev_readable != 0) {
        if (event.events & er.ev_closed != 0) wire.link.resident_closed = true;
        const for_own = own != null and wire.session == own.?;
        switch (try Internal.feedReadable(self, wire, own)) {
            .fed => |fed| own_fed = if (for_own) fed else 0,
            .closed => return 0,
        }
    }
    // Clean resident EOF is always READABLE|CLOSED, and the buffered bytes
    // stay readable until the read reaches the end. A read left deferred
    // observes the end itself once the sweep finishes it, so the close waits
    // with it. CLOSED alone is the resident's fault signal.
    const read_left = event.events & er.ev_readable != 0 and wire.link.read_deferred;
    if (event.events & er.ev_closed != 0 and !read_left) Internal.closeWire(self, wire, error.ConnectionLost);
    return own_fed;
}

/// Report an arrival refused before any session took it. A closing Host and
/// the pending-open ceiling are ordinary refusals, as `can_accept` is, and a
/// provider violation was already latched where it was found. Anything else
/// reaches the observer's arrival channel, which leaves its listener open.
fn retireArrival(self: *HostRuntime, observation: SessionAcceptObservation, err: anyerror) void {
    if (err == driver_core.Error.HostClosing or err == driver_core.Error.PendingOpenLimitReached) return;
    if (self.terminal_failure != null) return;
    const observer = observation.observer;
    if (observer.arrival_failed) |notify| notify(observer.ctx, observation.tag, OperationFailure.fromError(err));
}

/// Adopt one connection claimed from a resident accept queue and park its
/// CapTP handshake under the same observer path as a stream listener. Every
/// failure rolls back whatever the arrival took, and `conn` keeps the
/// connection until adoption transfers it.
fn startAcceptedConn(
    self: *HostRuntime,
    resident_index: usize,
    conn: *net.multiplexed_resident.ClaimedConnection,
    conn_id: usize,
    transport: []const u8,
    observation: SessionAcceptObservation,
) !void {
    var admission = try Internal.acquireOpenAdmission(self, .application);
    errdefer admission.release();
    const observer = observation.observer;
    try observer.reserve(observer.ctx, observation.tag);
    errdefer observer.release(observer.ctx, observation.tag);
    const resident = self.residents.items[resident_index].resident;
    const session = try self.core.openAcceptedAdvertised(transport);
    errdefer Internal.abandonFreshSession(self, session);
    const row = try self.allocator.create(PendingOpen);
    errdefer self.allocator.destroy(row);
    try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
    const remote_key = resident.connRemoteKey(conn_id) catch |err| {
        ensureProviderCause(self);
        return err;
    };
    if (remote_key) |key| {
        session.served.port.peer.bindVerifiedChannelKey(key);
    }
    try Internal.adoptResidentConn(self, session, resident_index, conn);
    row.* = .{
        .admission = admission,
        .stage = .{ .handshake = .{ .session = session, .deadline_ms = Internal.handshakeDeadline(self) } },
        .outcome = .{ .listener_accept = observation },
    };
    self.pending_opens.appendAssumeCapacity(row);
    Internal.startAdoptedWire(self, session);
}

/// Drain a resident connection until the runtime window refuses, feeding each
/// chunk. A drained ready record is consumed, so bytes left unread here would
/// wait for a future readiness transition instead of the next wait. A resident
/// that lends its received bytes feeds the core from the loan. Any other
/// copies into the runtime's one read scratch. The loop stops at the chunk
/// that opens the session (`stopAtOpen`) and before a read the session cannot
/// take (`holdRead`). The unread input stays in the resident, which is the
/// flow control the partner sees, and `read_deferred` brings the sweep back
/// to it. Returns the bytes fed.
pub fn readAndFeed(self: *HostRuntime, wire: *Wire) !usize {
    const rl = &wire.link;
    const resident = self.residents.items[rl.index].resident;
    var total: usize = 0;
    rl.read_deferred = false;
    if (resident.vtable.borrowed_read) |borrowed| {
        while (true) {
            if (holdRead(self, wire)) return total;
            switch (borrowed.lend(resident.ctx, rl.conn)) {
                .would_block => return wouldBlock(wire, total),
                .end_of_stream => return endOfRead(wire, total),
                .dead => return error.ConnectionLost,
                .bytes => |chunk| {
                    defer borrowed.release(resident.ctx, rl.conn);
                    if (chunk.len == 0) return error.ConnectionLost;
                    const was_open = wire.session.served.port.peer.sessionIsOpen();
                    try feedChunk(self, wire, chunk);
                    total += chunk.len;
                    if (stopAtOpen(wire, was_open)) return total;
                },
            }
        }
    }
    while (true) {
        if (holdRead(self, wire)) return total;
        const scratch = self.resident_read_scratch;
        const got = resident.tryRead(rl.conn, scratch);
        if (got == net.multiplexed_resident.would_block) return wouldBlock(wire, total);
        if (got == 0) return endOfRead(wire, total);
        if (got < 0) return error.ConnectionLost;
        if (@as(usize, @intCast(got)) > scratch.len) return error.ConnectionLost;
        const chunk = scratch[0..@intCast(got)];
        const was_open = wire.session.served.port.peer.sessionIsOpen();
        try feedChunk(self, wire, chunk);
        total += chunk.len;
        if (stopAtOpen(wire, was_open)) return total;
    }
}

/// The core pauses a chunk at the frame that opens its session so the
/// embedder can publish before the partner's first frames dispatch, but a
/// later chunk would dispatch at once. A stream wire reads one chunk per
/// step, so the open commits in between. A resident read stops here for the
/// same reason and defers the rest, because its drained record will not be
/// reported again.
fn stopAtOpen(wire: *Wire, was_open: bool) bool {
    if (was_open or !wire.session.served.port.peer.sessionIsOpen()) return false;
    wire.link.read_deferred = true;
    return true;
}

/// Whether the next read waits in the resident, which leaves `read_deferred`
/// set for the sweep to finish it. An unattended wire parks what it reads, so
/// it never waits. An attended wire waits while older input is parked ahead
/// of the read, which keeps the reads in order, and while its session is at
/// the outbound waterline after the window was offered the queue
/// (`pressuredAfterOffer`), where the core would refuse the read with a
/// retryable `OutboundBackpressure`. The offer can close the wire, so callers
/// read `wire.closed` after it.
fn holdRead(self: *HostRuntime, wire: *Wire) bool {
    if (!wire.attended) return false;
    const parked_ahead = wire.link.parked.items.len != 0;
    const pressured = !parked_ahead and Internal.pressuredAfterOffer(self, wire);
    if (wire.closed) return true;
    if (!parked_ahead and !pressured) return false;
    wire.link.read_deferred = true;
    return true;
}

/// A read that answers would-block returns what it fed, unless the resident
/// reported the partner's departure: its buffered bytes were the last, so the
/// end of the stream is here (`endOfRead`).
fn wouldBlock(wire: *Wire, total: usize) error{ TruncatedFrame, EndOfStream }!usize {
    return if (wire.link.resident_closed) endOfRead(wire, total) else total;
}

/// The read reached the end of the stream. The end waits while an attended
/// wire's core holds input a resume can move, because it would read as a
/// truncated frame, and `read_deferred` brings the sweep back to it once that
/// input has moved. An unattended wire dispatches nothing, so no resume moves
/// that input and the end is final.
fn endOfRead(wire: *Wire, total: usize) error{ TruncatedFrame, EndOfStream }!usize {
    if (wire.attended and wire.session.inboundResumable()) {
        wire.link.read_deferred = true;
        return total;
    }
    return endOfStream(wire);
}

fn endOfStream(wire: *Wire) error{ TruncatedFrame, EndOfStream } {
    return if (wire.session.feed_tail.isActive()) error.TruncatedFrame else error.EndOfStream;
}

/// Park `chunk` for an unattended wire, or feed it to the core, which keeps
/// no borrow of it past the call. A chunk the core refuses closes the wire
/// here. A chunk that cannot be parked returns its failure and `feedReadable`
/// closes the wire, because the bytes after it would land on a stream with a
/// hole.
fn feedChunk(self: *HostRuntime, wire: *Wire, chunk: []const u8) !void {
    if (!wire.attended) return wire.link.park(self.allocator, wire.session.wire_framing, chunk);
    self.core.feedTransportPacket(wire.session, chunk) catch |err| {
        const failure = net.classifyApplyError(err);
        // A shortage of memory leaves the drain retained behind the retry
        // deadline, so only another failure ends the feed beyond its own.
        _ = Internal.attempt(self, .operational, .turn) catch |drain_err| {
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
}
