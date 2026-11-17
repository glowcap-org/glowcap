//! Retained redeem reports: the one owner that commits a redeem row's
//! verdict to the core.
//!
//! A redeem row keeps its place, admission and observer-free ownership until
//! the core commits the opened session (`exporterDialed`) or the failure
//! (`dialFailed`). Producers (the sweep, completion, the carrier, an
//! immediate provider refusal inside `Exec.dial`) only enqueue a ready
//! verdict. The common operational attempt runs the single pass here, so a
//! report never nests inside the core action drain or a provider callback.
//! A memory refusal keeps the same row and waits for the Host's memory retry
//! deadline. A closing carrier waits for its own completion instead.

const driver_core = @import("driver_core");

const pending = @import("pending.zig");
const sessions = @import("sessions.zig");
const verdicts = @import("open_verdicts.zig");
const host_runtime = @import("../host_runtime.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const HostRuntime = host_runtime.HostRuntime;
const Error = driver_core.Error;
const PendingOpen = pending.Open;

/// Whether the operational attempt may run a report now: the runtime is not
/// terminal and no memory deadline is armed. Terminal latch clears memory
/// debt, so an absent deadline alone is not permission. One predicate governs
/// the readiness nudge and the zero-wait clamp.
fn consumerPermitted(self: *const HostRuntime) bool {
    return self.terminal_failure == null and self.core.memory_retry_due_ms == null;
}

/// Whether some redeem report is ready for the next permitted attempt.
pub fn readyReportWaiting(self: *const HostRuntime) bool {
    for (self.pending_opens.items) |row| switch (row.stage) {
        .opened_report => |report| if (report.wait == .ready) return true,
        .failed_report => |report| if (report.wait == .ready) return true,
        .resident_dial, .handshake, .retry_wait, .reporting => {},
    };
    return false;
}

/// A ready report whose attempt can run, so the wait must not park.
pub fn readyReportRunnable(self: *const HostRuntime) bool {
    return consumerPermitted(self) and readyReportWaiting(self);
}

const Result = enum { kept, refused, removed };

/// Commit every report a permitted attempt can run. Returns whether the core
/// actually refused one for memory, so the attempt arms its retry deadline.
/// A memory refusal retains its row and never redials. Any other failure
/// retires the row's actual resources and reports the failure, or latches the
/// runtime terminal when the failure cannot be reported. Nothing here drains
/// actions or calls an observer.
pub fn reportRedeems(self: *HostRuntime) bool {
    var refused = false;
    var i: usize = 0;
    while (i < self.pending_opens.items.len and self.terminal_failure == null) {
        switch (reportRow(self, self.pending_opens.items[i])) {
            .kept => i += 1,
            .refused => {
                refused = true;
                i += 1;
            },
            // The last row moved under the cursor and is not yet visited.
            .removed => {},
        }
    }
    return refused;
}

fn reportRow(self: *HostRuntime, row: *PendingOpen) Result {
    const redeem = switch (row.outcome) {
        .redeem => |value| value,
        .operation, .listener_accept => return .kept,
    };
    switch (row.stage) {
        .opened_report => |opened| {
            if (opened.wait == .carrier_closing) return .kept;
            return reportOpened(self, row, redeem, opened.session);
        },
        .failed_report => return reportFailed(self, row, redeem),
        .resident_dial, .handshake, .retry_wait, .reporting => return .kept,
    }
}

fn reportOpened(self: *HostRuntime, row: *PendingOpen, redeem: anytype, session: *driver_core.HostSession) Result {
    const opened = row.stage.opened_report;
    const wire = self.wires.get(session.peer_handle);
    if (wire) |open_wire| {
        if (open_wire.closed and !open_wire.carrierClosed()) {
            // The wire started closing: the report waits for this exact
            // carrier, not for the memory clock.
            row.stage.opened_report.wait = .carrier_closing;
            return .kept;
        }
    }
    if (wire == null or wire.?.closed) {
        verdicts.failPendingOpenFailure(self, row, opened.close_cause orelse OperationFailure.fromError(Error.ConnectionClosed));
        return reportRetired(self, row, redeem);
    }
    row.stage = .reporting;
    const adopted = self.core.exporterDialed(redeem.ticket, redeem.route_index, session) catch |err| {
        if (err == error.OutOfMemory) {
            // Pre-commit: the open exporter stays alive and the same report
            // retries once the Host's memory deadline is due.
            row.stage = .{ .opened_report = .{
                .session = session,
                .close_cause = opened.close_cause,
                .wait = .memory_refused,
            } };
            return .refused;
        }
        row.stage = .{ .opened_report = .{ .session = session, .close_cause = opened.close_cause, .wait = .ready } };
        verdicts.failPendingOpenFailure(self, row, self.operationFailure(err));
        return reportRetired(self, row, redeem);
    };
    if (!adopted) {
        // A stale or not-adopted report leaves the unclaimed session to
        // this owner. The non-reentrant call has returned, so the row owns
        // the session again until retirement commits: a synchronous carrier
        // close finds it and returns its seat instead of publishing a close
        // for a session the application never saw. Retire it once, without
        // draining.
        row.stage = .{ .opened_report = .{ .session = session, .close_cause = opened.close_cause, .wait = .ready } };
        sessions.retireSessionWire(self, session) catch |err| {
            // A release refusal before the core's commit is an ownership
            // violation. The row keeps the actual resources for terminal
            // cleanup, which retires them once.
            self.noteTerminalFailure(err);
            return .kept;
        };
    }
    return finish(self, row);
}

/// Report the failure the row just retired its resources for. A refused
/// release latched the runtime terminal and left the row in its resource-owning
/// stage for terminal cleanup, so no core report follows.
fn reportRetired(self: *HostRuntime, row: *PendingOpen, redeem: anytype) Result {
    if (row.stage != .failed_report) return .kept;
    return reportFailed(self, row, redeem);
}

fn reportFailed(self: *HostRuntime, row: *PendingOpen, redeem: anytype) Result {
    const failed = row.stage.failed_report;
    row.stage = .reporting;
    self.core.dialFailed(redeem.ticket, redeem.route_index, failed.failure.routeFailure(), failed.failure.chain.primaryName()) catch |err| {
        if (err == error.OutOfMemory) {
            row.stage = .{ .failed_report = .{ .failure = failed.failure, .wait = .memory_refused } };
            return .refused;
        }
        // The verdict cannot reach the core: keep the whole failure, with
        // the report's own cause, as the terminal cause. Resources already
        // retired, so the row leaves with nothing orphaned.
        var failure = failed.failure;
        failure.noteFailure(self.operationFailure(err));
        self.noteTerminalOperationFailure(failure);
        return finish(self, row);
    };
    return finish(self, row);
}

fn finish(self: *HostRuntime, row: *PendingOpen) Result {
    var admission = verdicts.releaseRow(self, row);
    admission.release();
    return .removed;
}
