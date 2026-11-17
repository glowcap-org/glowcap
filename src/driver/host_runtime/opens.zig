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
const verdicts = @import("open_verdicts.zig");
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
        .stage = .{ .handshake = .{ .session = session, .deadline_ms = handshakeDeadline(self) } },
        .outcome = .{ .operation = .{ .observer = observer, .tag = tag } },
    };
    // Publish the ownership row before bytes move. A synchronous EOF must
    // settle through this operation's observer, never the close observer
    // for application-owned sessions.
    self.pending_opens.appendAssumeCapacity(row);
    Internal.startAdoptedWire(self, session);
}

/// Everything `stageDial` proves before a row owns the dial. Each field is
/// already acquired, so `dispatchDial` has no error edge: an allocation or
/// admission refusal can only happen while this value is built, and it leaves
/// the route undecided for the core action's retry owner.
const PreparedDial = struct {
    admission: OpenAdmission,
    session: *driver_core.HostSession,
    row: *PendingOpen,
    dial_locator: ?model.PeerLocator,
    deadline_ms: ?i64,
    resident_index: usize,
    dialer: net.MultiplexedResident.Dialer,
    request_id: usize,
    origin: net.DialOrigin,
};

/// The shared staged-dial mint behind `startDial` and the
/// redeem drain: open the dialed half, start the transport connect, and
/// park a `PendingOpen` row for the pump to settle. `locator` is
/// borrowed for the call. Nothing of it is retained. An error is a refusal
/// before the row owns anything, and commits no verdict: a redeem route stays
/// undecided. Once `dispatchDial` runs the row owns the dial and its result,
/// including an immediate provider failure, which it queues for the reporter.
pub fn stageDial(
    self: *HostRuntime,
    locator: model.PeerLocator,
    options: net.OperationOptions,
    outcome: PendingOpen.Outcome,
    authority: OpenAdmissionAuthority,
) !void {
    const prepared = (try prepareDial(self, locator, outcome, authority)) orelse return;
    dispatchDial(self, prepared, locator, options, outcome);
}

fn prepareDial(
    self: *HostRuntime,
    locator: model.PeerLocator,
    outcome: PendingOpen.Outcome,
    authority: OpenAdmissionAuthority,
) !?PreparedDial {
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
                return null;
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
    const dialer = runtime.resident.dialer() orelse return Error.UnknownTransport;
    const request_id = try Internal.mintRuntimeId(&runtime.next_request);
    const origin: net.DialOrigin = switch (outcome) {
        .redeem => |redeem| try pendingDialOrigin(self, redeem.ticket, redeem.route_index),
        .operation, .listener_accept => .application,
    };
    return .{
        .admission = admission,
        .session = session,
        .row = row,
        .dial_locator = dial_locator,
        .deadline_ms = deadline_ms,
        .resident_index = resident_index,
        .dialer = dialer,
        .request_id = request_id,
        .origin = origin,
    };
}

/// Start the provider connect for a prepared dial and publish its row. No
/// step here can fail: a provider refusal is the row's own verdict.
fn dispatchDial(
    self: *HostRuntime,
    prepared: PreparedDial,
    locator: model.PeerLocator,
    options: net.OperationOptions,
    outcome: PendingOpen.Outcome,
) void {
    const row = prepared.row;
    var attempt = switch (prepared.dialer.startDial(prepared.request_id, locator, options, prepared.origin)) {
        .admitted => |attempt| attempt,
        .failed => |failure| {
            row.* = .{
                .admission = prepared.admission,
                .stage = .{ .handshake = .{ .session = prepared.session, .deadline_ms = prepared.deadline_ms } },
                .outcome = outcome,
                .dial_locator = prepared.dial_locator,
            };
            self.pending_opens.appendAssumeCapacity(row);
            verdicts.failPendingOpenFailure(self, row, .fromDialFailure(failure));
            return;
        },
    };
    defer if (attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    row.* = .{
        .admission = prepared.admission,
        .stage = .{ .resident_dial = .{
            .session = prepared.session,
            .deadline_ms = prepared.deadline_ms,
            .resident = prepared.resident_index,
            .attempt = attempt.take(),
        } },
        .outcome = outcome,
        .dial_locator = prepared.dial_locator,
    };
    self.pending_opens.appendAssumeCapacity(row);
}

/// The origin of a handoff dial, borrowed from the introducing session for
/// the start call (`Host.pendingDialIntroducer`). An empty origin leaves the
/// provider to decide what an offer without one means.
fn pendingDialOrigin(self: *HostRuntime, ticket: u64, route_index: usize) !net.DialOrigin {
    const designator = try self.core.pendingDialIntroducer(ticket, route_index) orelse return .application;
    return .{ .introducer = designator };
}

pub const discardPendingOpen = verdicts.discardPendingOpen;

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
        var discarded = verdicts.discardPendingOpen(self, row);
        if (discarded.cleanup) |cleanup| Internal.noteTerminalFailureChain(self, cleanup);
        const obs = observation.?.observer;
        obs.abandoned(obs.ctx, tag);
        discarded.admission.release();
    }
}

/// Settle every pending open the pump has decided: a session whose
/// handshake opened, a closed wire, or an expired deadline is a verdict. A
/// non-redeem row reports through its observer and leaves the list. A redeem
/// row keeps its place as an opened or failed report that the common
/// operational attempt commits to the core (`redeem_reports.zig`), so this
/// sweep never reports. Runs after every action drain in the pump loops, so
/// an open advances no matter which wait is driving the host. The result
/// helpers queue their consequences and never drain, because an open decided
/// inside `Exec.dial` or `startDial` must not run a drain beneath its caller.
/// This is the top-level owner that answers them: it attempts one drain after
/// each decided row, before the next row's verdict. A shortage of memory
/// leaves them queued behind the retry deadline instead of failing the sweep.
/// The drain can cancel or remove rows below the cursor, so the sweep restarts
/// at the first row after every decided one. A latched terminal failure stops
/// the sweep: terminal cleanup owns every remaining row.
pub fn advancePendingOpens(self: *HostRuntime) !void {
    var i: usize = 0;
    while (i < self.pending_opens.items.len and self.terminal_failure == null) {
        switch (try advanceRow(self, self.pending_opens.items[i])) {
            .kept => i += 1,
            .decided => {
                try answerQueued(self);
                i = 0;
            },
        }
    }
}

fn advanceRow(self: *HostRuntime, row: *PendingOpen) !RowOutcome {
    switch (row.stage) {
        .retry_wait => |wait| {
            // The handshake budget still owns the row's whole life: a wait
            // that outlives it fails the dial even though the interval has
            // not yet elapsed.
            const now_ms = self.nowMs();
            if (wait.deadline_ms) |deadline| {
                if (now_ms >= deadline) {
                    verdicts.failPendingOpen(self, row, Error.HandshakeTimedOut);
                    return .decided;
                }
            }
            if (now_ms >= wait.due_ms) return try reissueRetryingDial(self, row);
            return .kept;
        },
        .handshake => |hs| {
            const wire = self.wires.get(hs.session.peer_handle);
            if (wire == null or (wire.?.closed and wire.?.carrierClosed())) {
                verdicts.failPendingOpenFailure(self, row, hs.close_cause orelse OperationFailure.fromError(Error.ConnectionClosed));
                return .decided;
            }
            if (wire.?.closed) return .kept;
            if (hs.session.sessionOpen()) {
                completePendingOpen(self, row);
                return .decided;
            }
            return expireActive(self, row, hs.deadline_ms);
        },
        .resident_dial => |dial| return expireActive(self, row, dial.deadline_ms),
        .opened_report, .failed_report, .reporting => return .kept,
    }
}

fn expireActive(self: *HostRuntime, row: *PendingOpen, deadline_ms: ?i64) RowOutcome {
    const deadline = deadline_ms orelse return .kept;
    if (self.nowMs() < deadline) return .kept;
    verdicts.failPendingOpen(self, row, Error.HandshakeTimedOut);
    return .decided;
}

/// One drain attempt for what a decided row queued. Memory the drain lacks
/// stays queued behind the retry deadline, so only another failure returns.
fn answerQueued(self: *HostRuntime) !void {
    _ = try Internal.attempt(self, .operational, .turn);
}

/// Hand the opened session to its observer. A refusal releases the wire,
/// latches any release failure onto the refusal, and reports it, and the row
/// is then complete.
fn reportOpened(self: *HostRuntime, observation: anytype, session: *driver_core.HostSession) void {
    const obs = observation.observer;
    obs.opened(obs.ctx, observation.tag, session) catch |err| {
        var failure = self.operationFailure(err);
        self.releaseWire(session) catch |cleanup| failure.noteFailure(self.operationFailure(cleanup));
        obs.failed(obs.ctx, observation.tag, failure);
    };
}

/// Hand an accepted session to its listener's observer. A refusal retires
/// this arrival only: the observer releases its reservation and may hear the
/// cause, and the listener stays open. A wire that cannot be released leaves
/// a session no one owns, so that failure latches.
fn reportAcceptOpened(self: *HostRuntime, observation: SessionAcceptObservation, session: *driver_core.HostSession) void {
    const obs = observation.observer;
    obs.opened(obs.ctx, observation.tag, session) catch |err| {
        var failure = self.operationFailure(err);
        self.releaseWire(session) catch |cleanup| {
            failure.noteFailure(self.operationFailure(cleanup));
            self.noteTerminalOperationFailure(failure);
        };
        obs.abandoned(obs.ctx, observation.tag);
        if (obs.arrival_failed) |notify| notify(obs.ctx, observation.tag, failure);
    };
}

/// Settle one completed session open and queue its consequences without
/// draining them. A redeem row becomes a ready opened report that keeps the
/// session, the wire and the close cause until the reporter commits it.
fn completePendingOpen(self: *HostRuntime, row: *PendingOpen) void {
    const hs = row.stage.handshake;
    switch (row.outcome) {
        .redeem => row.stage = .{ .opened_report = .{
            .session = hs.session,
            .close_cause = hs.close_cause,
            .wait = .ready,
        } },
        .operation => |observation| {
            var admission = verdicts.releaseRow(self, row);
            reportOpened(self, observation, hs.session);
            admission.release();
        },
        .listener_accept => |observation| {
            var admission = verdicts.releaseRow(self, row);
            reportAcceptOpened(self, observation, hs.session);
            admission.release();
        },
    }
}

/// The row whose parked resident connect carries `request_id`.
pub fn pendingOpenByRequest(self: *HostRuntime, resident_index: usize, request_id: usize) ?*PendingOpen {
    for (self.pending_opens.items) |row| switch (row.stage) {
        .resident_dial => |dial| if (dial.resident == resident_index and dial.attempt.id() == request_id) return row,
        .handshake, .retry_wait, .opened_report, .failed_report, .reporting => {},
    };
    return null;
}

/// The row that actually owns `session`. A failed or in-flight report owns no
/// session, so a recycled pointer cannot match it.
pub fn pendingOpenFor(self: *const HostRuntime, session: *driver_core.HostSession) ?*PendingOpen {
    for (self.pending_opens.items) |row| {
        if (row.stage.session() == session) return row;
    }
    return null;
}

fn reportDialOutcome(self: *HostRuntime, outcome: dial_retry.DialOutcome, attempt: u32) void {
    if (self.opts.dial_outcome) |observer| observer.report(observer.ctx, outcome, attempt);
}

/// Whether a sweep decision left its row in the active set. `.decided` means
/// the row reached its next verdict: its result helper already ran, and the
/// sweep restarts because the answering drain may have changed the list.
const RowOutcome = enum { kept, decided };

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
) RowOutcome {
    const policy = self.opts.dial_retry;
    const now_ms = self.nowMs();
    const interval_ms: i64 = std.math.cast(i64, policy.retry_interval_ms) orelse std.math.maxInt(i64);
    const transient = dial_retry.isTransient(failure.classification);
    const session = row.stage.session().?;
    const deadline_ms = row.stage.deadlineMs();
    const deadline_leaves_room = deadline_ms == null or deadline_ms.? >= now_ms +| interval_ms;
    if (transient and row.dial_attempt < policy.max_attempts and deadline_leaves_room) {
        row.stage = .{ .retry_wait = .{
            .session = session,
            .deadline_ms = deadline_ms,
            .resident = resident_index,
            .attempt = row.dial_attempt,
            .due_ms = now_ms +| interval_ms,
        } };
        reportDialOutcome(self, .transient_retry, row.dial_attempt);
        return .kept;
    }
    const verdict: dial_retry.DialOutcome =
        if (!transient or !deadline_leaves_room) .permanent else .exhausted;
    reportDialOutcome(self, verdict, row.dial_attempt);
    verdicts.failPendingOpenFailure(self, row, .fromDialFailure(failure));
    return .decided;
}

/// Re-issue a retry_wait row's resident dial once its interval has elapsed:
/// a fresh request id, the same session, admission, and queued hello. The
/// row's owned locator serves application rows. A redeem row re-reads the
/// route's own view, which lives until the ticket settles. A start that
/// fails is one more attempt outcome on the same policy as a failed finish.
fn reissueRetryingDial(self: *HostRuntime, row: *PendingOpen) !RowOutcome {
    const wait = row.stage.retry_wait;
    const runtime = &self.residents.items[wait.resident];
    const resident = runtime.resident;
    const dialer = resident.dialer() orelse {
        verdicts.failPendingOpen(self, row, Error.UnknownTransport);
        return .decided;
    };
    const request_id = try Internal.mintRuntimeId(&runtime.next_request);
    const locator = if (row.dial_locator) |owned| owned else blk: {
        const redeem = switch (row.outcome) {
            .redeem => |value| value,
            .operation, .listener_accept => unreachable,
        };
        const view = self.core.node.pendingDial(redeem.ticket, redeem.route_index) orelse {
            verdicts.failPendingOpen(self, row, error.ProviderContract);
            return .decided;
        };
        break :blk view.locator;
    };
    const origin: net.DialOrigin = switch (row.outcome) {
        .redeem => |redeem| pendingDialOrigin(self, redeem.ticket, redeem.route_index) catch |err| {
            verdicts.failPendingOpen(self, row, err);
            return .decided;
        },
        .operation, .listener_accept => .application,
    };
    // Resident dialers admit only inherited options, so the faithful
    // re-issue carries the same inherited shape the first attempt passed.
    row.dial_attempt = wait.attempt + 1;
    var attempt = switch (dialer.startDial(request_id, locator, .inherit, origin)) {
        .admitted => |attempt| attempt,
        .failed => |failure| return retryOrFailResidentDial(self, row, wait.resident, failure),
    };
    defer if (attempt.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    row.stage = .{ .resident_dial = .{
        .session = wait.session,
        .deadline_ms = wait.deadline_ms,
        .resident = wait.resident,
        .attempt = attempt.take(),
    } };
    return .kept;
}

/// Claim a staged dial's completed resident connect: finish it, bind the
/// channel-proved key and the wire, move the row to the handshake stage, and
/// start the wire. `DialAttempt.finish` consumes the request,
/// so a failure settles the row failed with nothing left to cancel.
pub fn adoptPendingResidentDial(self: *HostRuntime, resident_index: usize, row: *PendingOpen) void {
    const dial = &row.stage.resident_dial;
    std.debug.assert(dial.resident == resident_index);
    const session = dial.session;
    const deadline_ms = dial.deadline_ms;
    const resident = self.residents.items[resident_index].resident;
    var conn = switch (dial.attempt.finish()) {
        .connected => |conn| blk: {
            reportDialOutcome(self, .ok, row.dial_attempt);
            break :blk conn;
        },
        .failed => |failure| {
            // The servicing step drains whatever a failed dial queued.
            _ = retryOrFailResidentDial(self, row, resident_index, failure);
            return;
        },
    };
    defer if (conn.deinit()) |failure| Internal.noteTerminalFailureChain(self, failure);
    const conn_id = conn.borrow() orelse return verdicts.failPendingOpen(self, row, error.ProviderContract);
    const remote_key = resident.connRemoteKey(conn_id) catch |err| return verdicts.failPendingOpen(self, row, err);
    row.stage = .{ .handshake = .{ .session = session, .deadline_ms = deadline_ms } };
    if (remote_key) |key| {
        session.served.port.peer.bindVerifiedChannelKey(key);
    }
    Internal.adoptResidentConn(self, session, resident_index, &conn) catch |err| return verdicts.failPendingOpen(self, row, err);
    // The hello's flush action drained to a no-op while the wire did not
    // exist yet. The start writes that queued frame.
    Internal.startAdoptedWire(self, session);
}
