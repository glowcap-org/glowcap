//! Verdicts of a pending open and the retirement of what its stage owns.
//!
//! A non-redeem row reports to its observer and leaves the set. A redeem row
//! stays listed as a failed report holding the exact verdict, after its actual
//! resources retire once. The core commit belongs to `redeem_reports.zig`.

const foundation = @import("foundation");
const model = @import("model");

const pending = @import("pending.zig");
const sessions = @import("sessions.zig");
const host_runtime = @import("../host_runtime.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

const HostRuntime = host_runtime.HostRuntime;
const Internal = host_runtime.Internal;
const OpenAdmission = pending.OpenAdmission;
const PendingOpen = pending.Open;

/// Take a listed row out of the set and free it, returning its admission for
/// the caller to release once the row's consequences have been reported.
pub fn releaseRow(self: *HostRuntime, row: *PendingOpen) OpenAdmission {
    pending.remove(&self.pending_opens, row);
    if (row.dial_locator) |locator| model.freePeerLocator(self.allocator, locator);
    const admission = row.admission;
    self.allocator.destroy(row);
    return admission;
}

/// Unwind and report one failed session open. The still-parked
/// resident connect is canceled. A bound wire drops with its session. The
/// consequences stay queued for the caller's drain: the failure may arrive
/// inside `Exec.dial` or `startDial`, where a drain would nest. `row` is
/// listed. A redeem row stays listed as a ready failed report holding the
/// exact verdict, and every other row leaves the set.
pub fn failPendingOpen(self: *HostRuntime, row: *PendingOpen, err: anyerror) void {
    failPendingOpenFailure(self, row, self.operationFailure(err));
}

pub fn failPendingOpenFailure(self: *HostRuntime, row: *PendingOpen, original_failure: OperationFailure) void {
    var failure = original_failure;
    switch (row.outcome) {
        .redeem => {
            // Retire the actual resources once, before the resource-free
            // verdict is reportable. A refusal before the core's commit
            // leaves the row owning them under the terminal cleanup, which
            // retires them once, and the verdict joins the terminal cause.
            const retired = retireResources(self, row) catch |err| {
                failure.noteFailure(self.operationFailure(err));
                self.noteTerminalOperationFailure(failure);
                return;
            };
            if (retired) |cleanup| failure.noteChain(cleanup);
            row.stage = .{ .failed_report = .{ .failure = failure, .wait = .ready } };
        },
        .operation => |observation| {
            pending.remove(&self.pending_opens, row);
            var discarded = discardPendingOpen(self, row);
            defer discarded.admission.release();
            if (discarded.cleanup) |cleanup| failure.noteChain(cleanup);
            const obs = observation.observer;
            obs.failed(obs.ctx, observation.tag, failure);
        },
        .listener_accept => |observation| {
            pending.remove(&self.pending_opens, row);
            var discarded = discardPendingOpen(self, row);
            defer discarded.admission.release();
            if (discarded.cleanup) |cleanup| failure.noteChain(cleanup);
            const obs = observation.observer;
            obs.abandoned(obs.ctx, observation.tag);
            if (obs.arrival_failed) |notify| notify(obs.ctx, observation.tag, failure);
        },
    }
}

const DiscardedOpen = struct {
    admission: OpenAdmission,
    cleanup: ?foundation.FailureChain = null,
};

/// Retire what the row's current stage actually owns: the core session with
/// its wire, then the parked resident connect. A report stage that owns no
/// session retires nothing. The one fallible edge is the core's release, which
/// refuses only before its one-way commit. Such a refusal returns with the
/// stage still owning the session, its wire, and the parked connect, so the
/// caller keeps them for terminal cleanup. On success the caller replaces or
/// frees the stage, so the resources are never retired twice.
fn retireResources(self: *HostRuntime, row: *PendingOpen) !?foundation.FailureChain {
    switch (row.stage) {
        // The reporter's non-reentrant core call is the only owner of this
        // payload, and nothing else runs while it does.
        .reporting => unreachable,
        .resident_dial, .handshake, .retry_wait, .opened_report, .failed_report => {},
    }
    if (row.stage.session()) |session| {
        // The row keeps the session through the close, so a carrier that
        // completes synchronously returns its observer seat to this row.
        if (self.wires.contains(session.peer_handle))
            try sessions.retireSessionWire(self, session)
        else
            try self.core.releaseSession(session);
    }
    return switch (row.stage) {
        .resident_dial => |*dial| dial.attempt.deinit(),
        else => null,
    };
}

/// Free an unlisted row's storage after infallibly retiring the transport and
/// session its stage owns. The row must already be out of `pending_opens`.
/// Outcome notification and action draining stay with the caller: listener
/// close uses this after admission is sealed and must not become half-closed
/// because an unrelated queued action failed to drain.
pub fn discardPendingOpen(self: *HostRuntime, row: *PendingOpen) DiscardedOpen {
    defer self.allocator.destroy(row);
    if (row.dial_locator) |locator| model.freePeerLocator(self.allocator, locator);
    const admission = row.admission;
    const cleanup = retireUnlisted(self, row);
    return .{ .admission = admission, .cleanup = cleanup };
}

/// Retire what an unlisted row's stage owns, infallibly. The row is already
/// out of the set, so a synchronous carrier close must find no row: the wire
/// detaches first, which returns its observer seat and keeps the close from
/// reaching the application. A release refusal is the cleanup cause.
fn retireUnlisted(self: *HostRuntime, row: *PendingOpen) ?foundation.FailureChain {
    var cleanup: ?foundation.FailureChain = null;
    switch (row.stage) {
        .resident_dial => |*dial| cleanup = dial.attempt.deinit(),
        .handshake, .retry_wait, .opened_report, .failed_report => {},
        .reporting => unreachable,
    }
    if (row.stage.session()) |session| {
        Internal.dropWire(self, session.peer_handle);
        if (Internal.releaseCoreSession(self, session)) |release_failure| foundation.latchFailure(&cleanup, release_failure);
    }
    return cleanup;
}
