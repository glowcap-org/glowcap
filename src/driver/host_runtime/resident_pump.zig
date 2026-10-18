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
const unattended_parked_cap_bytes = HostRuntime.unattended_parked_cap_bytes;

/// Drain and answer one resident's ready records: dial completions release their
/// awaiting dials, readable connections feed the core, writable ones resume
/// retained outbound, and closed ones close their wires. `own` carries the
/// calling wait's session so a sibling's dispatch refusal closes the sibling
/// instead of aborting the caller, exactly as stream `feedReadable` holds.
pub fn serviceResident(self: *HostRuntime, resident_index: usize, own: ?*driver_core.HostSession) !usize {
    const resident = self.residents.items[resident_index].resident;
    var own_fed: usize = 0;
    const events = try resident.drainReady(&self.event_scratch);
    for (events) |event| own_fed += try handleResidentEvent(self, resident_index, event, own);
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
        // The provider already removed this connection from its accept queue. An
        // over-limit arrival closes here without a session or retained buffers.
        // Level-shaped readiness brings the next accept through a later step.
        if (!Internal.pendingOpenSlotAvailable(self)) return 0;
        if (!listener.observation.observer.can_accept(listener.observation.observer.ctx)) return 0;
        try startAcceptedConn(
            self,
            resident_index,
            &conn,
            listener.transport,
            listener.observation,
        );
        return 0;
    }
    if (event.events & er.ev_connect != 0) {
        const dialer = self.residents.items[resident_index].resident.dialer() orelse return error.ProviderContract;
        const request_key = ResidentRequestKey{ .resident = resident_index, .request = event.subject };
        if (self.pending_resident_dials.get(request_key)) |wait| {
            wait.ready = true;
        } else if (Internal.pendingOpenByRequest(self, resident_index, event.subject)) |row| {
            try Internal.adoptPendingResidentDial(self, resident_index, row);
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
        if (event.events & er.ev_closed != 0) switch (self.residents.items[resident_index].resident.connCloseOutcome(event.subject)) {
            .complete => {},
            .pending => self.noteTerminalFailure(error.ProviderContract),
            .failed => |failure| Internal.noteTerminalFailureChain(self, failure),
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
        const for_own = own != null and wire.session == own.?;
        switch (try Internal.feedReadable(self, wire, own)) {
            .fed => |fed| own_fed = if (for_own) fed else 0,
            .closed => return 0,
        }
    }
    // Clean resident EOF is always READABLE|CLOSED: `feedReadable` drains the
    // buffered tail and observes the zero read above. CLOSED alone is the
    // resident's fault signal.
    if (event.events & er.ev_closed != 0) Internal.closeWire(self, wire, error.ConnectionLost);
    return own_fed;
}

/// Adopt one connection claimed from a resident accept queue and park its
/// CapTP handshake under the same observer path as a stream listener.
fn startAcceptedConn(
    self: *HostRuntime,
    resident_index: usize,
    conn: *net.multiplexed_resident.ClaimedConnection,
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
    const conn_id = conn.borrow() orelse return error.ProviderContract;
    if (try resident.connRemoteKey(conn_id)) |key| {
        session.served.port.peer.bindVerifiedChannelKey(key);
    }
    try Internal.adoptResidentConn(self, session, resident_index, conn);
    row.* = .{
        .admission = admission,
        .session = session,
        .stage = .handshake,
        .deadline_ms = Internal.handshakeDeadline(self),
        .outcome = .{ .listener_accept = observation },
    };
    self.pending_opens.appendAssumeCapacity(row);
    const wire = self.wires.get(session.peer_handle).?;
    Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
}

/// Drain a resident connection until the runtime window refuses, feeding each
/// chunk. A drained ready record is consumed, so bytes left unread here would
/// wait for a future readiness transition instead of the next wait. A resident
/// that lends its received bytes feeds the core from the loan. Any other
/// copies into the runtime's one read scratch.
pub fn readAndFeed(self: *HostRuntime, wire: *Wire) !usize {
    const rl = &wire.link;
    const resident = self.residents.items[rl.index].resident;
    var total: usize = 0;
    if (resident.vtable.borrowed_read) |borrowed| {
        while (true) switch (borrowed.lend(resident.ctx, rl.conn)) {
            .would_block => return total,
            .end_of_stream => return endOfStream(wire),
            .dead => return error.ConnectionLost,
            .bytes => |chunk| {
                defer borrowed.release(resident.ctx, rl.conn);
                if (chunk.len == 0) return error.ConnectionLost;
                const was_open = wire.session.served.port.peer.sessionIsOpen();
                try feedChunk(self, wire, chunk);
                total += chunk.len;
                if (stopAtOpen(wire, was_open)) return total;
            },
        };
    }
    while (true) {
        const scratch = self.resident_read_scratch;
        const got = resident.tryRead(rl.conn, scratch);
        if (got == net.multiplexed_resident.would_block) return total;
        if (got == 0) return endOfStream(wire);
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

fn endOfStream(wire: *Wire) error{ TruncatedFrame, EndOfStream } {
    return if (wire.session.feed_tail.isActive()) error.TruncatedFrame else error.EndOfStream;
}

/// Park `chunk` for an unattended wire, or feed it to the core, which keeps
/// no borrow of it past the call.
fn feedChunk(self: *HostRuntime, wire: *Wire, chunk: []const u8) !void {
    const rl = &wire.link;
    if (!wire.attended) {
        switch (wire.session.wire_framing) {
            .byte_stream => {
                if (rl.parked.items.len + chunk.len > unattended_parked_cap_bytes)
                    return error.ConnectionLost;
                try rl.parked.appendSlice(self.allocator, chunk);
            },
            .message => {
                if (rl.parked_packet_bytes + chunk.len > unattended_parked_cap_bytes)
                    return error.ConnectionLost;
                const packet = try self.allocator.dupe(u8, chunk);
                errdefer self.allocator.free(packet);
                try rl.parked_packets.append(self.allocator, packet);
                rl.parked_packet_bytes += packet.len;
            },
        }
        return;
    }
    self.core.feedTransportPacket(wire.session, chunk) catch |err| {
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
}
