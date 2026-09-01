//! Staged session opens across dial, external adoption, and listener accept.
//!
//! One admission lease and one heap-pinned row own each operation until its
//! transport connect and CapTP handshake publish exactly one outcome. Every
//! unwind retires the transport, Session, observer seat, and cleanup chain at
//! the same boundary.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const pending = @import("pending.zig");
const host_runtime = @import("../host_runtime.zig");
const stream_wire = @import("stream_wire.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const crypto = foundation.crypto;
const Error = driver_core.Error;
const ExternalAdoptionRole = HostRuntime.ExternalAdoptionRole;
const OpenAdmissionAuthority = lifecycle.OpenAdmissionAuthority;
const OpenAdmission = pending.OpenAdmission;
const PendingOpen = pending.Open;
const SessionAcceptObserver = HostRuntime.SessionAcceptObserver;
const SessionAcceptObservation = lifecycle.SessionAcceptObservation;
const SessionOpenObserver = HostRuntime.SessionOpenObserver;

/// Dial `locator` into an open session: mint the dialed half (the core
/// registers crossed hellos and encodes the signed hello), bind the
/// transport wire, and pump the keyed handshake under the handshake
/// budget. On any failure the wire, the shell, and the hello registration
/// unwind together.
pub fn connectLocator(
    self: *HostRuntime,
    locator: model.PeerLocator,
    options: net.OperationOptions,
) !*driver_core.HostSession {
    self.enterDriver();
    defer self.leaveDriver();
    var admission = try Internal.acquireOpenAdmission(self, .application);
    defer admission.release();
    try self.core.ensureAdvertisedLocator(locator.transport);
    const session = try self.core.openDialedLocator(locator);
    errdefer {
        Internal.dropWire(self, session.peer_handle);
        if (Internal.releaseCoreSession(self, session)) |failure| Internal.noteTerminalFailureChain(self, failure);
    }
    try Internal.bindWire(self, session, locator, options);
    try Internal.pumpHandshake(self, session, self.opts.handshake);
    return session;
}

/// Stage a dial toward `locator` without pumping it (ADR-0112): mint the
/// dialed session, start its transport connect, and return. The
/// handshake advances through whichever pump runs next; `observer` hears
/// `opened` with `tag` when the session opens, or
/// `failed` when the wire closes or the handshake budget expires.
/// Provider-backed stream starts are nonblocking; a native Zig netlayer
/// without staged dial support retains the blocking fallback. In either
/// case, the handshake advances through later pumps, which lets a dial
/// complete against a partner stepped by the same thread.
pub fn startDial(
    self: *HostRuntime,
    locator: model.PeerLocator,
    options: net.OperationOptions,
    tag: u64,
    observer: SessionOpenObserver,
) !void {
    self.enterDriver();
    defer self.leaveDriver();
    try observer.reserve(observer.ctx, tag);
    errdefer observer.release(observer.ctx, tag);
    try stageDial(self, locator, options, .{ .operation = .{ .observer = observer, .tag = tag } }, .application);
}

/// Begin adopting one externally established provider connection without
/// pumping its handshake. The provider owns the subject namespace and
/// supplies the authenticated durable key; this face owns only the
/// resulting wire.
/// No locator is supplied by the caller. A dialed adoption uses the
/// provider's proved key as its target, while an accepted adoption uses
/// the Host's selected advertised location.
pub fn startAdoptExternal(
    self: *HostRuntime,
    transport: []const u8,
    subject: usize,
    role: ExternalAdoptionRole,
    tag: u64,
    observer: SessionOpenObserver,
) !void {
    self.enterDriver();
    defer self.leaveDriver();
    var admission = try Internal.acquireOpenAdmission(self, .application);
    errdefer admission.release();
    const provider = Internal.providerFor(self, transport) orelse return Error.UnknownTransport;
    const resident_index = switch (provider.source) {
        .stream => return Error.UnknownTransport,
        .resident => |index| index,
    };
    const runtime = self.residents.items[resident_index].resident;
    const claimer = runtime.externalClaimer() orelse return Error.UnknownTransport;
    try observer.reserve(observer.ctx, tag);
    errdefer observer.release(observer.ctx, tag);
    var claimed = switch (claimer.claimExternal(subject)) {
        .claimed => |connection| connection,
        .failed => |failure| {
            admission.release();
            observer.failed(observer.ctx, tag, .fromChain(failure.chain));
            return;
        },
    };
    defer if (claimed.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    const conn_id = claimed.borrow() orelse return error.ProviderContract;
    const key = try runtime.connRemoteKey(conn_id) orelse return error.InvalidAddress;

    var designator_storage: [crypto.PeerKey.designator_len]u8 = undefined;
    const session = switch (role) {
        .dialed => blk: {
            try self.core.ensureAdvertisedLocator(transport);
            designator_storage = key.toDesignator();
            break :blk try self.core.openDialedLocator(.{
                .transport = transport,
                .designator = &designator_storage,
                .hints = model.Hints.emptyFalse(),
            });
        },
        .accepted => try self.core.openAcceptedAdvertised(transport),
    };
    errdefer {
        Internal.dropWire(self, session.peer_handle);
        if (Internal.releaseCoreSession(self, session)) |failure| Internal.noteTerminalFailureChain(self, failure);
    }
    session.served.port.peer.bindVerifiedChannelKey(key);
    try Internal.adoptResidentConn(self, session, resident_index, &claimed);
    const row = try self.allocator.create(PendingOpen);
    errdefer self.allocator.destroy(row);
    try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
    row.* = .{
        .admission = admission,
        .session = session,
        .stage = .handshake,
        .deadline_ms = handshakeDeadline(self),
        .outcome = .{ .operation = .{ .observer = observer, .tag = tag } },
    };
    // Publish the ownership row before bytes move. A synchronous EOF must
    // settle through this operation's observer, never the close observer
    // for application-owned sessions.
    self.pending_opens.appendAssumeCapacity(row);
    const wire = self.wires.get(session.peer_handle).?;
    Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
    if (!wire.closed) _ = Internal.feedReadable(self, wire, null) catch |err| Internal.closeWire(self, wire, err);
}

/// The shared staged-dial mint behind `startDial` and the
/// redeem drain: open the dialed half, start the transport connect, and
/// park a `PendingOpen` row for the pump to settle. `locator` is
/// borrowed for the call; nothing of it is retained.
pub fn stageDial(
    self: *HostRuntime,
    locator: model.PeerLocator,
    options: net.OperationOptions,
    outcome: PendingOpen.Outcome,
    authority: OpenAdmissionAuthority,
) !void {
    var admission = try Internal.acquireOpenAdmission(self, authority);
    errdefer admission.release();
    // A routed dial knows its candidates before it has a session. Prove the
    // provider for this attempt first so an unavailable route cannot become
    // this node's advertised location before fallback. Application dials keep
    // their established ensure-then-provider contract for custom transports.
    const pending_provider = switch (authority) {
        .application => null,
        .pending_dial => Internal.providerFor(self, locator.transport) orelse return Error.UnknownTransport,
    };
    const session = switch (authority) {
        .application => blk: {
            try self.core.ensureAdvertisedLocator(locator.transport);
            break :blk try self.core.openDialedLocator(locator);
        },
        .pending_dial => blk: {
            const redeem = switch (outcome) {
                .redeem => |value| value,
                .operation, .listener_accept => unreachable,
            };
            // A Host-level fetch can be this runtime's first connection. The
            // selected concrete route owns the same dial-side hello default as
            // an application-started dial; handoff redemption merely used to
            // hide this requirement behind its already-open source session.
            if (self.core.advertisedLocator(locator.transport) == null)
                try self.core.ensureAdvertisedLocator(locator.transport);
            break :blk try self.core.openPendingDial(redeem.ticket, redeem.route_index) orelse {
                admission.release();
                return;
            };
        },
    };
    errdefer {
        Internal.dropWire(self, session.peer_handle);
        if (Internal.releaseCoreSession(self, session)) |failure| Internal.noteTerminalFailureChain(self, failure);
    }
    const row = try self.allocator.create(PendingOpen);
    errdefer self.allocator.destroy(row);
    try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
    const deadline_ms = handshakeDeadline(self);
    const provider = pending_provider orelse
        Internal.providerFor(self, locator.transport) orelse return Error.UnknownTransport;
    switch (provider.source) {
        .resident => |resident_index| {
            const runtime = &self.residents.items[resident_index];
            const resident = runtime.resident;
            const dialer = resident.dialer() orelse return Error.UnknownTransport;
            const request_id = try Internal.mintRuntimeId(&runtime.next_request);
            var attempt = switch (dialer.startDial(
                request_id,
                locator,
                options,
            )) {
                .admitted => |attempt| attempt,
                .failed => |failure| {
                    row.* = .{
                        .admission = admission,
                        .session = session,
                        .stage = .handshake,
                        .deadline_ms = deadline_ms,
                        .outcome = outcome,
                    };
                    self.pending_opens.appendAssumeCapacity(row);
                    removePendingRow(self, row);
                    try failPendingOpenFailure(self, row, .fromDialFailure(failure));
                    return;
                },
            };
            defer if (attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
            row.* = .{
                .admission = admission,
                .session = session,
                .stage = .{ .resident_dial = .{
                    .resident = resident_index,
                    .attempt = attempt.take(),
                } },
                .deadline_ms = deadline_ms,
                .outcome = outcome,
            };
        },
        .stream => |nl| {
            if (!nl.supportsDial()) return Error.UnknownTransport;
            if (nl.supportsStagedDial()) {
                var attempt = switch (nl.startDial(locator, options)) {
                    .admitted => |attempt| attempt,
                    .failed => |failure| {
                        row.* = .{
                            .admission = admission,
                            .session = session,
                            .stage = .handshake,
                            .deadline_ms = deadline_ms,
                            .outcome = outcome,
                        };
                        self.pending_opens.appendAssumeCapacity(row);
                        removePendingRow(self, row);
                        try failPendingOpenFailure(self, row, .fromDialFailure(failure));
                        return;
                    },
                };
                errdefer if (attempt.deinit()) |cleanup| Internal.noteTerminalFailureChain(self, cleanup);
                const fd = attempt.readinessFd();
                if (fd < 0) return Error.TransportNotPollable;
                if (Internal.descriptorInUse(self, fd)) return error.ReadinessDescriptorConflict;
                if (self.ready_set) |*rs| try rs.add(fd);
                errdefer Internal.removeReadyFd(self, fd);
                row.* = .{
                    .admission = admission,
                    .session = session,
                    .stage = .{ .stream_dial = attempt.take() },
                    .deadline_ms = deadline_ms,
                    .outcome = outcome,
                };
            } else {
                if (try Internal.bindStreamWireOutcome(self, session, locator, nl, options)) |failure| {
                    row.* = .{
                        .admission = admission,
                        .session = session,
                        .stage = .handshake,
                        .deadline_ms = deadline_ms,
                        .outcome = outcome,
                    };
                    self.pending_opens.appendAssumeCapacity(row);
                    removePendingRow(self, row);
                    try failPendingOpenFailure(self, row, .fromDialFailure(failure));
                    return;
                }
                row.* = .{
                    .admission = admission,
                    .session = session,
                    .stage = .handshake,
                    .deadline_ms = deadline_ms,
                    .outcome = outcome,
                };
            }
        },
    }
    self.pending_opens.appendAssumeCapacity(row);
}

pub fn handshakeDeadline(self: *const HostRuntime) ?i64 {
    return switch (self.opts.handshake) {
        .unbounded => null,
        .ms => |v| net.clock.nowMs(self.io) + v,
    };
}

/// Accept one ready connection from `listener` without pumping its
/// handshake (ADR-0112): mint the accepted half, bind the wire, and park
/// a staged row beside the dials. The accept observer hears `opened` with
/// `tag` only when the partner's hello completes the handshake. A wire
/// close or budget expiry is retired as listener hygiene, so one silent
/// connector cannot park the step or become an application operation
/// failure. Call after the listener reported acceptable, so the accept
/// syscall itself does not block.
pub fn startAcceptWire(
    self: *HostRuntime,
    listener: net.netlayer.Listener,
    transport: []const u8,
    tag: u64,
    observer: SessionAcceptObserver,
) !void {
    self.enterDriver();
    defer self.leaveDriver();
    var admission = try Internal.acquireOpenAdmission(self, .application);
    errdefer admission.release();
    try observer.reserve(observer.ctx, tag);
    errdefer observer.release(observer.ctx, tag);
    const session = try self.core.openAcceptedAdvertised(transport);
    errdefer {
        Internal.dropWire(self, session.peer_handle);
        if (Internal.releaseCoreSession(self, session)) |failure| Internal.noteTerminalFailureChain(self, failure);
    }
    const row = try self.allocator.create(PendingOpen);
    errdefer self.allocator.destroy(row);
    try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
    if (try Internal.bindAcceptedWireOutcome(self, session, listener)) |accept_failure| {
        var failure = OperationFailure.fromAcceptFailure(accept_failure);
        self.allocator.destroy(row);
        if (Internal.releaseCoreSession(self, session)) |cleanup| failure.noteChain(cleanup);
        admission.release();
        observer.release(observer.ctx, tag);
        Internal.failActiveListener(self, tag, failure);
        return;
    }
    row.* = .{
        .admission = admission,
        .session = session,
        .stage = .handshake,
        .deadline_ms = handshakeDeadline(self),
        .outcome = .{ .listener_accept = .{ .observer = observer, .tag = tag } },
    };
    self.pending_opens.appendAssumeCapacity(row);
}

/// Cancel every accepted connection still handshaking for `tag`. A
/// listener owner calls this before closing the listener, establishing
/// that no later accept-observer event can name the closed listener.
pub fn cancelAccepts(self: *HostRuntime, tag: u64) void {
    self.enterDriver();
    defer self.leaveDriver();
    var i: usize = 0;
    while (i < self.pending_opens.items.len) {
        const row = self.pending_opens.items[i];
        const observation = switch (row.outcome) {
            .listener_accept => |value| if (value.tag == tag) value else null,
            else => null,
        };
        if (observation == null) {
            i += 1;
            continue;
        }
        std.debug.assert(self.pending_opens.swapRemove(i) == row);
        var discarded = discardPendingOpen(self, row);
        if (discarded.cleanup) |cleanup| Internal.noteTerminalFailureChain(self, cleanup);
        const obs = observation.?.observer;
        obs.abandoned(obs.ctx, tag);
        discarded.admission.release();
    }
}

/// Settle every pending open the pump has decided: a session whose
/// handshake opened reports opened, a closed wire or an expired deadline
/// reports failed. Runs after every action drain in the pump loops, so a
/// open advances no matter which wait is driving the host. Rows
/// are removed before their notification runs, because a notification
/// may drain actions and stage further dials.
pub fn advancePendingOpens(self: *HostRuntime) !void {
    var i: usize = 0;
    while (i < self.pending_opens.items.len) {
        const row = self.pending_opens.items[i];
        if (row.stage == .handshake) {
            const wire = self.wires.get(row.session.peer_handle);
            if (wire == null or (wire.?.closed and wire.?.carrierClosed())) {
                std.debug.assert(self.pending_opens.swapRemove(i) == row);
                try failPendingOpenFailure(self, row, row.close_cause orelse OperationFailure.fromError(Error.ConnectionClosed));
                continue;
            }
            if (wire.?.closed) {
                i += 1;
                continue;
            }
            if (row.session.sessionOpen()) {
                std.debug.assert(self.pending_opens.swapRemove(i) == row);
                try completePendingOpen(self, row);
                continue;
            }
        }
        if (row.deadline_ms) |deadline| {
            if (net.clock.nowMs(self.io) >= deadline) {
                std.debug.assert(self.pending_opens.swapRemove(i) == row);
                try failPendingOpen(self, row, Error.HandshakeTimedOut);
                continue;
            }
        }
        i += 1;
    }
}

/// Report one completed session open. For a redeem row, a refused
/// `exporterDialed` fails closed: the ticket's action was consumed at
/// stage time, so there is no drain retry to lean on — the session
/// unwinds and the waiting redeems break rather than strand.
fn completePendingOpen(self: *HostRuntime, row: *PendingOpen) !void {
    defer {
        row.admission.release();
        self.allocator.destroy(row);
    }
    switch (row.outcome) {
        .operation => |observation| {
            const obs = observation.observer;
            obs.opened(obs.ctx, observation.tag, row.session) catch |err| {
                var failure = self.operationFailure(err);
                self.releaseWire(row.session) catch |cleanup| failure.noteFailure(self.operationFailure(cleanup));
                obs.failed(obs.ctx, observation.tag, failure);
                return;
            };
        },
        .redeem => |redeem| {
            const adopted = self.core.exporterDialed(redeem.ticket, redeem.route_index, row.session) catch |err| {
                try self.releaseWire(row.session);
                try self.core.dialFailed(redeem.ticket, redeem.route_index, @errorName(err));
                return err;
            };
            if (!adopted) {
                try self.releaseWire(row.session);
                return;
            }
        },
        .listener_accept => |observation| {
            const obs = observation.observer;
            obs.opened(obs.ctx, observation.tag, row.session) catch |err| {
                var failure = self.operationFailure(err);
                self.releaseWire(row.session) catch |cleanup| failure.noteFailure(self.operationFailure(cleanup));
                obs.failed(obs.ctx, observation.tag, failure);
                return;
            };
        },
    }
    // The settle queued post-open work (withdraws, parked enlivens, the
    // observer's own effects); answer it before the next row's verdict.
    try self.drainActions();
}

/// Unwind and report one failed session open. The still-parked
/// resident connect is canceled; a bound wire drops with its session.
fn failPendingOpen(self: *HostRuntime, row: *PendingOpen, err: anyerror) !void {
    return failPendingOpenFailure(self, row, self.operationFailure(err));
}

fn failPendingOpenFailure(self: *HostRuntime, row: *PendingOpen, original_failure: OperationFailure) !void {
    const outcome = row.outcome;
    var discarded = discardPendingOpen(self, row);
    defer discarded.admission.release();
    var failure = original_failure;
    if (discarded.cleanup) |cleanup| failure.noteChain(cleanup);
    switch (outcome) {
        .operation => |observation| {
            const obs = observation.observer;
            obs.failed(obs.ctx, observation.tag, failure);
        },
        .redeem => |redeem| try self.core.dialFailed(redeem.ticket, redeem.route_index, failure.primaryName()),
        .listener_accept => |observation| {
            const obs = observation.observer;
            obs.abandoned(obs.ctx, observation.tag);
        },
    }
    try self.drainActions();
}

/// Infallibly retire the transport and session owned by a failed pending
/// open. Outcome notification and action draining stay with the caller:
/// listener close uses this after admission is sealed and must not become
/// half-closed because an unrelated queued action failed to drain.
const DiscardedOpen = struct {
    admission: OpenAdmission,
    cleanup: ?foundation.FailureChain = null,
};

pub fn discardPendingOpen(self: *HostRuntime, row: *PendingOpen) DiscardedOpen {
    defer self.allocator.destroy(row);
    const admission = row.admission;
    var cleanup: ?foundation.FailureChain = null;
    switch (row.stage) {
        .stream_dial => |*attempt| {
            Internal.removeReadyFd(self, attempt.readinessFd());
            cleanup = attempt.deinit();
        },
        .resident_dial => cleanup = row.stage.resident_dial.attempt.deinit(),
        .handshake => {},
    }
    Internal.dropWire(self, row.session.peer_handle);
    if (Internal.releaseCoreSession(self, row.session)) |release_failure| {
        if (cleanup) |*first|
            first.noteChain(release_failure)
        else
            cleanup = release_failure;
    }
    return .{ .admission = admission, .cleanup = cleanup };
}

pub fn pendingOpenByRequest(self: *HostRuntime, resident_index: usize, request_id: usize) ?*PendingOpen {
    for (self.pending_opens.items) |row| switch (row.stage) {
        .stream_dial => {},
        .resident_dial => |dial| if (dial.resident == resident_index and dial.attempt.id() == request_id) return row,
        .handshake => {},
    };
    return null;
}

pub fn pendingOpenFor(self: *const HostRuntime, session: *driver_core.HostSession) ?*PendingOpen {
    for (self.pending_opens.items) |row| {
        if (row.session == session) return row;
    }
    return null;
}

fn removePendingRow(self: *HostRuntime, row: *PendingOpen) void {
    for (self.pending_opens.items, 0..) |candidate, i| {
        if (candidate == row) {
            std.debug.assert(self.pending_opens.swapRemove(i) == row);
            return;
        }
    }
    unreachable; // the caller found the row in this list
}

/// Claim a staged dial's completed resident connect: finish it, bind the
/// channel-proved key and the wire, push the queued hello, and move the
/// row to the handshake stage. `DialAttempt.finish` consumes the request,
/// so a failure settles the row failed with nothing left to cancel.
pub fn adoptPendingResidentDial(self: *HostRuntime, resident_index: usize, row: *PendingOpen) !void {
    std.debug.assert(row.stage.resident_dial.resident == resident_index);
    const resident = self.residents.items[resident_index].resident;
    var conn = switch (row.stage.resident_dial.attempt.finish()) {
        .connected => |conn| conn,
        .failed => |failure| {
            removePendingRow(self, row);
            return failPendingOpenFailure(self, row, .fromDialFailure(failure));
        },
    };
    defer if (conn.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    const conn_id = conn.borrow() orelse {
        removePendingRow(self, row);
        return failPendingOpen(self, row, error.ProviderContract);
    };
    const remote_key = resident.connRemoteKey(conn_id) catch |err| {
        removePendingRow(self, row);
        return failPendingOpen(self, row, err);
    };
    row.stage = .handshake;
    if (remote_key) |key| {
        row.session.served.port.peer.bindVerifiedChannelKey(key);
    }
    Internal.adoptResidentConn(self, row.session, resident_index, &conn) catch |err| {
        removePendingRow(self, row);
        return failPendingOpen(self, row, err);
    };
    // The hello's flush action drained to a no-op while the wire did not
    // exist yet; push the queued frame now that it does.
    const wire = self.wires.get(row.session.peer_handle).?;
    Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
}

/// Claim a ready per-stream connect, transfer it into an ordinary wire,
/// and advance the row to the shared CapTP handshake stage.
pub fn adoptPendingStreamDial(self: *HostRuntime, row: *PendingOpen) !void {
    std.debug.assert(row.stage == .stream_dial);
    Internal.removeReadyFd(self, row.stage.stream_dial.readinessFd());
    var buffers = stream_wire.Buffers.init(self.allocator, self.opts.wire_buffer_bytes) catch |err| {
        removePendingRow(self, row);
        return failPendingOpen(self, row, err);
    };
    defer buffers.deinit();
    const conn = switch (row.stage.stream_dial.finish(row.session.served.port.peer, buffers.view())) {
        .connected => |conn| conn,
        .failed => |failure| {
            row.stage = .handshake;
            removePendingRow(self, row);
            return failPendingOpenFailure(self, row, .fromDialFailure(failure));
        },
    };
    var prepared = buffers.attach(conn);
    defer prepared.deinit();
    row.stage = .handshake;
    Internal.adoptConn(self, row.session, &prepared) catch |err| {
        removePendingRow(self, row);
        return failPendingOpen(self, row, err);
    };
    // The hello flush drained before the wire existed. Push it now.
    const wire = self.wires.get(row.session.peer_handle).?;
    Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
}
