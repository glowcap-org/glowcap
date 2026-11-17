//! Heap-pinned staged-open and listener-attempt vocabulary.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");
const net = @import("net");
const driver_core = @import("driver_core");

const lifecycle = @import("lifecycle.zig");
const runtime = @import("../host_runtime.zig");
const OperationFailure = @import("../operation_failure.zig").OperationFailure;

pub const OpenAdmission = struct {
    runtime: *runtime.HostRuntime,
    pending_work: ?driver_core.Host.PendingWorkLease,
    authority: lifecycle.OpenAdmissionAuthority,

    pub fn release(self: *OpenAdmission) void {
        std.debug.assert(self.runtime.open_admissions != 0);
        self.runtime.open_admissions -= 1;
        if (self.authority == .pending_dial) {
            std.debug.assert(self.runtime.redeem_dial_admissions != 0);
            self.runtime.redeem_dial_admissions -= 1;
        }
        if (self.pending_work) |*lease| lease.complete();
        self.* = undefined;
    }
};

pub const Open = struct {
    admission: OpenAdmission,
    stage: Stage,
    outcome: Outcome,
    /// The locator the resident dial targets, owned for the row's life so a
    /// transient failure can re-issue it (ADR-0018). Application rows clone
    /// the caller's borrowed locator at stage time. Redeem rows re-read the
    /// route's own view at re-issue. Freed when the row leaves the set.
    dial_locator: ?model.PeerLocator = null,
    /// The 1-based number of the attempt in flight.
    dial_attempt: u32 = 1,

    /// Why a retained redeem report waits. `ready` waits for the next
    /// permitted attempt, `memory_refused` for the Host's memory retry
    /// deadline, and `carrier_closing` (opened reports only) for the exact
    /// carrier completion.
    const ReportWait = enum { ready, memory_refused, carrier_closing };

    /// Active stages own their live core session and the handshake budget.
    /// Report stages own the verdict a redeem row has decided and the core has
    /// not yet committed. A failed report has retired its resources and holds
    /// no session. `reporting` is the moved payload while the reporter's
    /// non-reentrant core call runs: no lookup can reach it.
    pub const Stage = union(enum) {
        resident_dial: struct {
            session: *driver_core.HostSession,
            deadline_ms: ?i64,
            resident: usize,
            attempt: net.multiplexed_resident.DialAttempt,
        },
        handshake: struct {
            session: *driver_core.HostSession,
            deadline_ms: ?i64,
            /// Preserve an early bound-wire close until the open publishes its result.
            close_cause: ?OperationFailure = null,
        },
        /// A transient dial failure waiting for its interval to elapse before
        /// the same row re-issues the dial. `attempt` is the failed attempt's
        /// 1-based number, a snapshot of `dial_attempt` at wait entry.
        retry_wait: struct {
            session: *driver_core.HostSession,
            deadline_ms: ?i64,
            resident: usize,
            attempt: u32,
            due_ms: i64,
        },
        opened_report: struct {
            session: *driver_core.HostSession,
            close_cause: ?OperationFailure,
            wait: ReportWait,
        },
        failed_report: struct {
            failure: OperationFailure,
            wait: ReportWait,
        },
        reporting,

        /// The core session this stage owns, or null when it owns none.
        pub fn session(self: Stage) ?*driver_core.HostSession {
            return switch (self) {
                .resident_dial => |s| s.session,
                .handshake => |s| s.session,
                .retry_wait => |s| s.session,
                .opened_report => |s| s.session,
                .failed_report, .reporting => null,
            };
        }

        /// The handshake budget of an active stage. Report stages have none.
        pub fn deadlineMs(self: Stage) ?i64 {
            return switch (self) {
                .resident_dial => |s| s.deadline_ms,
                .handshake => |s| s.deadline_ms,
                .retry_wait => |s| s.deadline_ms,
                .opened_report, .failed_report, .reporting => null,
            };
        }
    };

    pub const Outcome = union(enum) {
        operation: lifecycle.SessionOpenObservation,
        redeem: struct {
            ticket: engine.Node.PendingId,
            route_index: usize,
        },
        listener_accept: lifecycle.SessionAcceptObservation,
    };
};

pub const ListenerObservation = struct {
    observer: lifecycle.ListenerObserver,
    tag: u64,
};

pub const Listener = struct {
    attempt: net.MultiplexedResident.ListenAttempt,
    resident: usize,
    transport: []const u8,
    designator_scheme: net.netlayer.DesignatorScheme,
    deadline_ms: ?i64,
    observation: ListenerObservation,
};

/// Remove the heap-pinned `row` from `rows`, which holds it exactly once.
pub fn remove(rows: anytype, row: anytype) void {
    for (rows.items, 0..) |candidate, i| {
        if (candidate != row) continue;
        std.debug.assert(rows.swapRemove(i) == row);
        return;
    }
    unreachable; // the caller found the row in this list
}
