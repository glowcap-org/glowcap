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
const dial_retry = @import("../dial_retry.zig");
const host_runtime = @import("../host_runtime.zig");
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
    errdefer Internal.abandonFreshSession(self, session);
    try Internal.bindWire(self, session, locator, options);
    try Internal.pumpHandshake(self, session, self.opts.handshake);
    return session;
}

/// Stage a dial toward `locator` without pumping it (ADR-0024): mint the
/// dialed session, start its transport connect, and return. The
/// handshake advances through whichever pump runs next. `observer` hears
/// `opened` with `tag` when the session opens, or
/// `failed` when the wire closes or the handshake budget expires. The
/// transport connect and the handshake both advance through later pumps,
/// which lets a dial complete against a partner stepped by the same thread.
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
/// supplies the authenticated durable key. This face owns only the
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
    const resident_index = provider.resident;
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
            break :blk try self.core.openDialedLocator(.hintless(transport, &designator_storage));
        },
        .accepted => try self.core.openAcceptedAdvertised(transport),
    };
    errdefer Internal.abandonFreshSession(self, session);
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
/// borrowed for the call. Nothing of it is retained.
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
            // an application-started dial; handoff redemption has an already-open
            // source session that satisfies this requirement.
            if (self.core.advertisedLocator(locator.transport) == null)
                try self.core.ensureAdvertisedLocator(locator.transport);
            break :blk try self.core.openPendingDial(redeem.ticket, redeem.route_index) orelse {
                admission.release();
                return;
            };
        },
    };
    errdefer Internal.abandonFreshSession(self, session);
    const row = try self.allocator.create(PendingOpen);
    errdefer self.allocator.destroy(row);
    try self.pending_opens.ensureUnusedCapacity(self.allocator, 1);
    // The row owns a copy of the caller's borrowed locator so a transient
    // failure can re-issue the dial after the call returns (ADR-0018).
    // Redeem rows re-read the route's own view instead, so they leave the
    // field null. The clone lands before the dial is issued, so a failed
    // clone leaves no attempt behind.
    const dial_locator: ?model.PeerLocator =
        if (authority == .application) try model.clonePeerLocator(self.allocator, locator) else null;
    errdefer if (dial_locator) |owned| model.freePeerLocator(self.allocator, owned);
    const deadline_ms = handshakeDeadline(self);
    const provider = pending_provider orelse
        Internal.providerFor(self, locator.transport) orelse return Error.UnknownTransport;
    const resident_index = provider.resident;
    const runtime = &self.residents.items[resident_index];
    const resident = runtime.resident;
    const dialer = resident.dialer() orelse return Error.UnknownTransport;
    const request_id = try Internal.mintRuntimeId(&runtime.next_request);
    const origin: net.DialOrigin = switch (outcome) {
        .redeem => |redeem| pendingDialOrigin(self, redeem.ticket, redeem.route_index),
        .operation, .listener_accept => .application,
    };
    var attempt = switch (dialer.startDial(
        request_id,
        locator,
        options,
        origin,
    )) {
        .admitted => |attempt| attempt,
        .failed => |failure| {
            row.* = .{
                .admission = admission,
                .session = session,
                .stage = .handshake,
                .deadline_ms = deadline_ms,
                .outcome = outcome,
                .dial_locator = dial_locator,
            };
            self.pending_opens.appendAssumeCapacity(row);
            pending.remove(&self.pending_opens, row);
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
        .dial_locator = dial_locator,
    };
    self.pending_opens.appendAssumeCapacity(row);
}

/// The origin of a handoff dial: the designator the introducing session's
/// partner signed, borrowed from that session for the start call. A closed
/// or unverified introducer, or one that signed no designator, leaves the
/// origin empty, and the provider decides what an offer without one means.
fn pendingDialOrigin(self: *HostRuntime, ticket: u64, route_index: usize) net.DialOrigin {
    const view = self.core.pendingDial(ticket, route_index) orelse return .application;
    const peer = view.introducer orelse return .application;
    const session = self.core.sessionForPeer(peer) orelse return .application;
    const identity = self.core.partnerIdentity(session) catch return .application;
    if (identity.designator.len == 0) return .application;
    return .{ .introducer = identity.designator };
}

pub fn handshakeDeadline(self: *const HostRuntime) ?i64 {
    return switch (self.opts.handshake) {
        .unbounded => null,
        .ms => |v| self.nowMs() + v,
    };
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
        if (row.stage == .retry_wait) {
            // The handshake budget still owns the row's whole life: a wait
            // that outlives it fails the dial even though the interval has
            // not yet elapsed.
            const now_ms = self.nowMs();
            if (row.deadline_ms) |deadline| {
                if (now_ms >= deadline) {
                    std.debug.assert(self.pending_opens.swapRemove(i) == row);
                    try failPendingOpen(self, row, Error.HandshakeTimedOut);
                    continue;
                }
            }
            if (now_ms >= row.stage.retry_wait.due_ms) {
                try reissueRetryingDial(self, row);
                // A failed re-issue removed the row, and the list's last row
                // now sits under the cursor.
                if (i < self.pending_opens.items.len and self.pending_opens.items[i] != row) continue;
            }
            i += 1;
            continue;
        }
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
            if (self.nowMs() >= deadline) {
                std.debug.assert(self.pending_opens.swapRemove(i) == row);
                try failPendingOpen(self, row, Error.HandshakeTimedOut);
                continue;
            }
        }
        i += 1;
    }
}

/// Hand the opened session to its observer. A refusal releases the wire,
/// latches any release failure onto the refusal, and reports it, and the row
/// is then complete.
fn reportOpened(self: *HostRuntime, observation: anytype, row: *PendingOpen) bool {
    const obs = observation.observer;
    obs.opened(obs.ctx, observation.tag, row.session) catch |err| {
        var failure = self.operationFailure(err);
        self.releaseWire(row.session) catch |cleanup| failure.noteFailure(self.operationFailure(cleanup));
        obs.failed(obs.ctx, observation.tag, failure);
        return false;
    };
    return true;
}

/// Report one completed session open. For a redeem row, a refused
/// `exporterDialed` fails closed: the ticket's action was consumed at
/// stage time, so there is no drain retry to lean on. The session
/// unwinds and the waiting redeems break rather than strand.
fn completePendingOpen(self: *HostRuntime, row: *PendingOpen) !void {
    defer {
        if (row.dial_locator) |locator| model.freePeerLocator(self.allocator, locator);
        row.admission.release();
        self.allocator.destroy(row);
    }
    switch (row.outcome) {
        .operation => |observation| if (!reportOpened(self, observation, row)) return,
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
        .listener_accept => |observation| if (!reportOpened(self, observation, row)) return,
    }
    // The settle queued post-open work (withdraws, parked enlivens, the
    // observer's own effects); answer it before the next row's verdict.
    try self.drainActions();
}

/// Unwind and report one failed session open. The still-parked
/// resident connect is canceled. A bound wire drops with its session.
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
        .redeem => |redeem| try self.core.dialFailed(redeem.ticket, redeem.route_index, failure.chain.primaryName()),
        .listener_accept => |observation| {
            const obs = observation.observer;
            obs.abandoned(obs.ctx, observation.tag);
            if (obs.arrival_failed) |notify| notify(obs.ctx, observation.tag, failure);
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
    if (row.dial_locator) |locator| model.freePeerLocator(self.allocator, locator);
    const admission = row.admission;
    var cleanup: ?foundation.FailureChain = null;
    switch (row.stage) {
        .resident_dial => cleanup = row.stage.resident_dial.attempt.deinit(),
        .handshake, .retry_wait => {},
    }
    Internal.dropWire(self, row.session.peer_handle);
    if (Internal.releaseCoreSession(self, row.session)) |release_failure| foundation.latchFailure(&cleanup, release_failure);
    return .{ .admission = admission, .cleanup = cleanup };
}

pub fn pendingOpenByRequest(self: *HostRuntime, resident_index: usize, request_id: usize) ?*PendingOpen {
    for (self.pending_opens.items) |row| switch (row.stage) {
        .resident_dial => |dial| if (dial.resident == resident_index and dial.attempt.id() == request_id) return row,
        .handshake, .retry_wait => {},
    };
    return null;
}

pub fn pendingOpenFor(self: *const HostRuntime, session: *driver_core.HostSession) ?*PendingOpen {
    for (self.pending_opens.items) |row| {
        if (row.session == session) return row;
    }
    return null;
}

fn reportDialOutcome(self: *HostRuntime, outcome: dial_retry.DialOutcome, attempt: u32) void {
    if (self.opts.dial_outcome) |observer| observer.report(observer.ctx, outcome, attempt);
}

/// A failed resident finish either parks the row for its retry interval or
/// fails it as before (ADR-0018 executes ADR-0030's policy). The retry
/// keeps the row's session, admission, observer reservation, and queued
/// hello: only the transport dial is re-issued. A transient fault retries
/// while attempts remain and the handshake deadline leaves room for the
/// next interval. A retry the deadline refuses is a `permanent` verdict,
/// since no future attempt can run inside the budget.
fn retryOrFailResidentDial(
    self: *HostRuntime,
    row: *PendingOpen,
    resident_index: usize,
    failure: net.netlayer.DialFailure,
) !void {
    const policy = self.opts.dial_retry;
    const now_ms = self.nowMs();
    const interval_ms: i64 = @intCast(policy.retry_interval_ms);
    const transient = dial_retry.isTransient(failure.classification);
    const deadline_leaves_room = row.deadline_ms == null or row.deadline_ms.? >= now_ms + interval_ms;
    if (transient and row.dial_attempt < policy.max_attempts and deadline_leaves_room) {
        row.stage = .{ .retry_wait = .{
            .resident = resident_index,
            .attempt = row.dial_attempt,
            .due_ms = now_ms + interval_ms,
        } };
        reportDialOutcome(self, .transient_retry, row.dial_attempt);
        return;
    }
    const verdict: dial_retry.DialOutcome =
        if (!transient or !deadline_leaves_room) .permanent else .exhausted;
    reportDialOutcome(self, verdict, row.dial_attempt);
    pending.remove(&self.pending_opens, row);
    return failPendingOpenFailure(self, row, .fromDialFailure(failure));
}

/// Re-issue a retry_wait row's resident dial once its interval has elapsed:
/// a fresh request id, the same session, admission, and queued hello. The
/// row's owned locator serves application rows. A redeem row re-reads the
/// route's own view, which lives until the ticket settles. A start that
/// fails is one more attempt outcome on the same policy as a failed finish.
fn reissueRetryingDial(self: *HostRuntime, row: *PendingOpen) !void {
    const wait = row.stage.retry_wait;
    const runtime = &self.residents.items[wait.resident];
    const resident = runtime.resident;
    const dialer = resident.dialer() orelse {
        pending.remove(&self.pending_opens, row);
        return failPendingOpen(self, row, Error.UnknownTransport);
    };
    const request_id = try Internal.mintRuntimeId(&runtime.next_request);
    const locator = if (row.dial_locator) |owned| owned else blk: {
        const redeem = switch (row.outcome) {
            .redeem => |value| value,
            .operation, .listener_accept => unreachable,
        };
        const view = self.core.node.pendingDial(redeem.ticket, redeem.route_index) orelse {
            pending.remove(&self.pending_opens, row);
            return failPendingOpen(self, row, error.ProviderContract);
        };
        break :blk view.locator;
    };
    // Resident dialers admit only inherited options, so the faithful
    // re-issue carries the same inherited shape the first attempt passed.
    row.dial_attempt = wait.attempt + 1;
    const origin: net.DialOrigin = switch (row.outcome) {
        .redeem => |redeem| pendingDialOrigin(self, redeem.ticket, redeem.route_index),
        .operation, .listener_accept => .application,
    };
    var attempt = switch (dialer.startDial(request_id, locator, .inherit, origin)) {
        .admitted => |attempt| attempt,
        .failed => |failure| return retryOrFailResidentDial(self, row, wait.resident, failure),
    };
    defer if (attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    row.stage = .{ .resident_dial = .{
        .resident = wait.resident,
        .attempt = attempt.take(),
    } };
}

/// Claim a staged dial's completed resident connect: finish it, bind the
/// channel-proved key and the wire, push the queued hello, and move the
/// row to the handshake stage. `DialAttempt.finish` consumes the request,
/// so a failure settles the row failed with nothing left to cancel.
pub fn adoptPendingResidentDial(self: *HostRuntime, resident_index: usize, row: *PendingOpen) !void {
    std.debug.assert(row.stage.resident_dial.resident == resident_index);
    const resident = self.residents.items[resident_index].resident;
    var conn = switch (row.stage.resident_dial.attempt.finish()) {
        .connected => |conn| blk: {
            reportDialOutcome(self, .ok, row.dial_attempt);
            break :blk conn;
        },
        .failed => |failure| return retryOrFailResidentDial(self, row, resident_index, failure),
    };
    defer if (conn.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    const conn_id = conn.borrow() orelse {
        pending.remove(&self.pending_opens, row);
        return failPendingOpen(self, row, error.ProviderContract);
    };
    const remote_key = resident.connRemoteKey(conn_id) catch |err| {
        pending.remove(&self.pending_opens, row);
        return failPendingOpen(self, row, err);
    };
    row.stage = .handshake;
    if (remote_key) |key| {
        row.session.served.port.peer.bindVerifiedChannelKey(key);
    }
    Internal.adoptResidentConn(self, row.session, resident_index, &conn) catch |err| {
        pending.remove(&self.pending_opens, row);
        return failPendingOpen(self, row, err);
    };
    // The hello's flush action drained to a no-op while the wire did not
    // exist yet; push the queued frame now that it does.
    const wire = self.wires.get(row.session.peer_handle).?;
    Internal.writeOutbound(self, wire) catch |err| Internal.closeWire(self, wire, err);
}
