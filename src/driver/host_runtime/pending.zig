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

    pub fn release(self: *OpenAdmission) void {
        std.debug.assert(self.runtime.open_admissions != 0);
        self.runtime.open_admissions -= 1;
        if (self.pending_work) |*lease| lease.complete();
        self.* = undefined;
    }
};

pub const Open = struct {
    admission: OpenAdmission,
    session: *driver_core.HostSession,
    stage: Stage,
    deadline_ms: ?i64,
    outcome: Outcome,
    /// Preserve an early bound-wire close until the open publishes its result.
    close_cause: ?OperationFailure = null,
    /// The locator the resident dial targets, owned for the row's life so a
    /// transient failure can re-issue it (ADR-0193). Application rows clone
    /// the caller's borrowed locator at stage time. Redeem rows re-read the
    /// route's own view at re-issue. Freed when the row leaves the set.
    dial_locator: ?model.PeerLocator = null,
    /// The 1-based number of the attempt currently in flight.
    dial_attempt: u32 = 1,

    pub const Stage = union(enum) {
        resident_dial: struct {
            resident: usize,
            attempt: net.multiplexed_resident.DialAttempt,
        },
        handshake,
        /// A transient dial failure waiting for its interval to elapse before
        /// the same row re-issues the dial. `attempt` is the failed attempt's
        /// 1-based number, a snapshot of `dial_attempt` at wait entry.
        retry_wait: struct {
            resident: usize,
            attempt: u32,
            due_ms: i64,
        },
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
