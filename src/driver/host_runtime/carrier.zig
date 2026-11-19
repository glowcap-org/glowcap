//! Physical carrier close, retirement, and wire allocation release.

const std = @import("std");

const engine = @import("engine");
const net = @import("net");

const runtime = @import("../host_runtime.zig");

const HostRuntime = runtime.HostRuntime;
const Internal = runtime.Internal;
const pending_state = @import("pending.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;
const Wire = HostRuntime.Wire;
const transport_close_ms: i32 = 5_000;

pub fn progressCarrierCloseDeadlines(self: *HostRuntime) void {
    const nearest = self.nearest_carrier_close_ms orelse return;
    const now_ms = self.nowMs();
    if (now_ms < nearest) return;
    var next_nearest: ?i64 = null;
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire| {
        const deadline = wire.*.carrier_close_deadline_ms orelse continue;
        if (deadline <= now_ms) progressWireCarrierClose(self, wire.*);
        if (wire.*.carrier_close_deadline_ms) |left| next_nearest = @min(next_nearest orelse left, left);
    }
    var retiring = self.retiring_wires;
    while (retiring) |wire| {
        const next = wire.retiring_next;
        if (wire.carrier_close_deadline_ms) |deadline|
            if (deadline <= now_ms) progressWireCarrierClose(self, wire);
        if (wire.carrier_close_deadline_ms) |left| next_nearest = @min(next_nearest orelse left, left);
        retiring = next;
    }
    // Exact again after the walk: every deadline still held was just seen.
    self.nearest_carrier_close_ms = if (self.carrier_close_waiters == 0) null else next_nearest;
}

/// Arm one wire's carrier-close deadline and fold it into the cached nearest.
fn armCarrierCloseDeadline(self: *HostRuntime, wire: *Wire, deadline_ms: i64) void {
    std.debug.assert(wire.carrier_close_deadline_ms == null);
    wire.carrier_close_deadline_ms = deadline_ms;
    self.carrier_close_waiters += 1;
    self.nearest_carrier_close_ms = @min(self.nearest_carrier_close_ms orelse deadline_ms, deadline_ms);
}

/// Clear one wire's carrier-close deadline. The cached nearest may now be
/// early. It is re-derived by the walk it wakes, and cleared outright once no
/// wire holds a deadline.
fn clearCarrierCloseDeadline(self: *HostRuntime, wire: *Wire) void {
    if (wire.carrier_close_deadline_ms == null) return;
    wire.carrier_close_deadline_ms = null;
    self.carrier_close_waiters -= 1;
    if (self.carrier_close_waiters == 0) self.nearest_carrier_close_ms = null;
}

/// Hold one close publication for a wire the stepped face is adopting. The
/// blocking face publishes no closes and holds nothing. A wire holds its
/// seat from adoption until its carrier completes or it detaches, so the
/// wire keeps no flag of its own: `suppressWireCloseEvent` and
/// `finishWireCarrierClose` are the only two consumers, and each is reached
/// exactly once per wire.
pub fn reserveCloseEvent(self: *HostRuntime) !void {
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| try stepped.close_observer.reserve(stepped.close_observer.ctx),
    }
}

pub fn releaseCloseEvent(self: *HostRuntime) void {
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| stepped.close_observer.release(stepped.close_observer.ctx),
    }
}

/// Free one wire's transport and buffers. The caller owns the `wires` row.
/// The resident routing row leaves here with the link it routes. A freed
/// wire's carrier has completed, so its close seat is already consumed.
pub fn freeWire(self: *HostRuntime, wire: *Wire) void {
    std.debug.assert(wire.carrierClosed());
    const rl = &wire.link;
    std.debug.assert(self.resident_wires.remove(.{ .resident = rl.index, .conn = rl.conn }));
    if (rl.pending) |*pending| pending.frame.deinit();
    rl.parked.deinit(self.allocator);
    self.allocator.destroy(wire);
}

pub fn dropWire(self: *HostRuntime, peer_handle: engine.PeerHandle) void {
    if (self.wires.fetchRemove(peer_handle)) |wire| retireConsumedWire(self, wire);
}

/// A session released before its carrier completed reports no close: give the
/// seat back now, before the wire detaches into runtime-owned retirement. A
/// wire whose carrier already completed consumed its seat in
/// `finishWireCarrierClose`.
fn suppressWireCloseEvent(self: *HostRuntime, wire: *Wire) void {
    if (wire.carrierClosed()) return;
    std.debug.assert(!wire.detached);
    releaseCloseEvent(self);
}

fn retireConsumedWire(self: *HostRuntime, wire: *Wire) void {
    suppressWireCloseEvent(self, wire);
    if (wire.carrierClosed()) {
        freeWire(self, wire);
        return;
    }
    wire.detached = true;
    wire.retiring_prev = null;
    wire.retiring_next = self.retiring_wires;
    if (self.retiring_wires) |head| head.retiring_prev = wire;
    self.retiring_wires = wire;
    // A close already waiting on the provider has no recipient left: the
    // resident may hand its result to its sink or return the report here.
    if (wire.closed) progressWireCarrierClose(self, wire) else closeWire(self, wire, null);
}

fn unlinkRetiringWire(self: *HostRuntime, wire: *Wire) void {
    std.debug.assert(wire.detached);
    if (wire.retiring_prev) |previous|
        previous.retiring_next = wire.retiring_next
    else
        self.retiring_wires = wire.retiring_next;
    if (wire.retiring_next) |next| next.retiring_prev = wire.retiring_prev;
    wire.detached = false;
    wire.retiring_prev = null;
    wire.retiring_next = null;
}

/// A resident package stays the asynchronous owner of a carrier close and is
/// joined in the deinit barrier. After fail-stop the runtime drains no actions and polls no resident, so
/// a closing session's carrier would never report. Force each one closed as
/// teardown does, carrying the runtime's terminal cause. A resident's package
/// release joins the physical operation.
pub fn forceClosingCarriers(self: *HostRuntime, cause: OperationFailure) void {
    var wires = self.wires.valueIterator();
    while (wires.next()) |wire| {
        if (wire.*.carrierClosed() or wire.*.session.lifecyclePhase() == .active) continue;
        noteWireCloseFailure(wire.*, cause);
        forceWireCarrierClose(self, wire.*);
    }
    var retiring = self.retiring_wires;
    while (retiring) |wire| {
        const next = wire.retiring_next;
        // The terminal latch already owns this cause. A detached wire keeps
        // only its own failures for the diagnostic observer.
        forceWireCarrierClose(self, wire);
        retiring = next;
    }
}

pub fn forceWireCarrierClose(self: *HostRuntime, wire: *Wire) void {
    if (!wire.closed) closeWire(self, wire, null);
    if (wire.carrierClosed()) return;
    finishWireCarrierClose(self, wire);
}

/// Mark a wire closed and break its session vows without freeing its shell.
pub fn closeWire(self: *HostRuntime, wire: *Wire, cause: ?anyerror) void {
    if (wire.closed) return;
    const failure = takeWireFailure(self, wire) orelse
        if (cause) |err| OperationFailure.fromError(err) else null;
    closeWireFailure(self, wire, failure);
}

fn takeWireFailure(self: *HostRuntime, wire: *Wire) ?OperationFailure {
    const rl = &wire.link;
    const report = self.residents.items[rl.index].resident.takeFailure(rl.conn) orelse return null;
    return OperationFailure.fromReport(report);
}

fn closeWireFailure(self: *HostRuntime, wire: *Wire, failure: ?OperationFailure) void {
    if (failure) |reported| noteWireCloseFailure(wire, reported);
    if (!wire.closed) {
        wire.closed = true;
        armCarrierCloseDeadline(self, wire, self.nowMs() +| transport_close_ms);
        const reason = if (wire.close_failure) |value| value.chain.primaryName() else "connection closed";
        wire.session.host.transportClosed(wire.session, reason) catch |err|
            closeTailFailed(self, err);
    }
    progressWireCarrierClose(self, wire);
}

/// The core's close tail failed after the wire closed. The tail is host-wide
/// pump work that can belong to any session, so the wire's own close failure
/// records nothing and a clean close stays clean. A shortage of memory leaves
/// that work queued for the next drain, and outbound pressure leaves it for
/// the flush wake the core already published. Any other failure latches as
/// the loop's terminal failure.
pub fn closeTailFailed(self: *HostRuntime, err: anyerror) void {
    switch (err) {
        // tolerant: the next drain reruns the pump (`resumeWorkForActionDrain`),
        // and a shortage that lasts leaves that drain retained behind the
        // deadline, which wakes the step's wait for the rerun.
        error.OutOfMemory => Internal.noteMemoryDebt(self),
        // tolerant: the core published the flush wake that brings the rerun
        // when the session's window opens, so no deadline is owed.
        error.OutboundBackpressure => {},
        else => Internal.noteTerminalFailure(self, err),
    }
}

fn noteWireCloseFailure(wire: *Wire, later: OperationFailure) void {
    if (wire.close_failure) |*primary|
        primary.noteFailure(later)
    else
        wire.close_failure = later;
}

pub fn progressWireCarrierClose(self: *HostRuntime, wire: *Wire) void {
    if (!wire.closed or wire.carrierClosed()) return;
    const expired = if (wire.carrier_close_deadline_ms) |deadline|
        self.nowMs() >= deadline
    else
        false;
    const rl = &wire.link;
    const resident = self.residents.items[rl.index].resident;
    // A detached wire has no caller left to receive a close result.
    const mode: net.multiplexed_resident.CloseMode = if (wire.detached) .no_wait else .awaited;
    const outcome = if (expired) blk: {
        noteWireCloseFailure(wire, .fromError(error.CloseTimedOut));
        clearCarrierCloseDeadline(self, wire);
        // The partner had `transport_close_ms` to read the close. A resident
        // that can abort drops the connection now, returning its socket and
        // read buffer to the pool. One that cannot still owns the operation
        // and joins it at release: a timeout cannot fabricate physical
        // completion.
        break :blk resident.connAbortOutcome(rl.conn, mode) orelse return;
    } else resident.connCloseOutcome(rl.conn, mode);
    switch (outcome) {
        .complete => finishWireCarrierClose(self, wire),
        // An abort never reports pending, so this is the close waiting on
        // the resident. The carrier stays open until the resident reports
        // complete or failed.
        .pending => {},
        .failed => |reported| {
            noteWireCloseFailure(wire, .fromReport(reported));
            finishWireCarrierClose(self, wire);
        },
    }
}

/// Record a staged session's carrier completion on the row that owns it,
/// keeping an earlier specific cause when this close names none. The core
/// session stays owned until the reporter retires it: a carrier-closing
/// report becomes ready, and one waiting on memory keeps its memory wait.
fn noteOpenCarrierClosed(row: *pending_state.Open, cause: ?OperationFailure) void {
    switch (row.stage) {
        .handshake => |*handshake| handshake.close_cause = cause orelse handshake.close_cause,
        .opened_report => |*opened| {
            opened.close_cause = cause orelse opened.close_cause;
            if (opened.wait == .carrier_closing) opened.wait = .ready;
        },
        .resident_dial, .retry_wait, .failed_report, .reporting => {},
    }
}

fn finishWireCarrierClose(self: *HostRuntime, wire: *Wire) void {
    if (wire.carrierClosed()) return;
    wire.carrier_closed = true;
    clearCarrierCloseDeadline(self, wire);
    if (self.open_wire_count == 0)
        self.failProviderContract()
    else
        self.open_wire_count -= 1;
    if (wire.detached) {
        if (wire.close_failure) |failure| self.reportUnhandledFailure(failure);
        unlinkRetiringWire(self, wire);
        freeWire(self, wire);
        Internal.nudgeIfWorkRemains(self);
        return;
    }
    // A staged dial reports through its dial path; it was never visible to the
    // close observer, so its seat goes back unused.
    if (Internal.pendingOpenFor(self, wire.session)) |row| {
        noteOpenCarrierClosed(row, wire.close_failure);
        releaseCloseEvent(self);
        Internal.nudgeIfWorkRemains(self);
        return;
    }
    switch (self.drive) {
        .blocking => {},
        .stepped => |*stepped| {
            const observer = stepped.close_observer;
            self.observer_callback_depth += 1;
            defer self.observer_callback_depth -= 1;
            observer.closed(observer.ctx, wire.session, wire.close_failure);
        },
    }
    Internal.nudgeIfWorkRemains(self);
}
