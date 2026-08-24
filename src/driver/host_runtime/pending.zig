//! Heap-pinned staged-open and listener-attempt vocabulary.

const std = @import("std");

const engine = @import("engine");
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

    pub const Stage = union(enum) {
        stream_dial: net.netlayer.DialAttempt,
        resident_dial: struct {
            resident: usize,
            attempt: net.multiplexed_resident.DialAttempt,
        },
        handshake,
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
    stage: union(enum) {
        stream: net.netlayer.ListenAttempt,
        resident: struct {
            attempt: net.MultiplexedResident.ListenAttempt,
            resident: usize,
        },
    },
    transport: []const u8,
    designator_scheme: net.netlayer.DesignatorScheme,
    deadline_ms: ?i64,
    observation: ListenerObservation,
};
