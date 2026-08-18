//! Heap-stable HostRuntime lease shared by a Server and yielded Sessions.
//!
//! The listener begins with one lease and every accepted Session owns another.
//! The last explicit release returns the runtime teardown result; implicit and
//! deferred release retain an otherwise callerless failure at the runtime.

const std = @import("std");

const driver = @import("../mod.zig");
const host_runtime = @import("../host_runtime.zig");

/// Heap-stable ownership shared by a one-call Server and the Sessions it has
/// already yielded. The listener owns one lease and each accepted Session owns
/// one more; closing the listener drops only its lease. The last lease tears
/// down the runtime and every runtime-internal session that was never yielded.
pub const SharedRuntime = struct {
    runtime: host_runtime.HostRuntime,
    allocator: std.mem.Allocator,
    leases: usize = 1,

    pub fn init(allocator: std.mem.Allocator, runtime: host_runtime.HostRuntime) SharedRuntime {
        return .{ .runtime = runtime, .allocator = allocator };
    }

    pub fn retain(self: *SharedRuntime) void {
        // Every lease beyond the listener's owns a distinct heap-allocated
        // Session, so the address space is exhausted before usize can be.
        std.debug.assert(self.leases != std.math.maxInt(usize));
        self.leases += 1;
    }

    pub fn releaseOutcome(self: *SharedRuntime) ?driver.OperationFailure {
        std.debug.assert(self.leases != 0);
        self.leases -= 1;
        if (self.leases != 0) return null;
        const allocator = self.allocator;
        const failure = self.runtime.deinitOutcome();
        allocator.destroy(self);
        return failure;
    }

    pub fn releaseImplicit(self: *SharedRuntime) bool {
        std.debug.assert(self.leases != 0);
        self.leases -= 1;
        if (self.leases != 0) return false;
        const allocator = self.allocator;
        if (self.runtime.deinitOutcome()) |failure| self.runtime.reportUnhandledFailure(failure);
        allocator.destroy(self);
        return true;
    }

    /// Deferred Session cleanup runs from HostRuntime's quiescent tail. True
    /// means this was the final lease and the callback destroyed that runtime;
    /// its caller must return without dereferencing the HostRuntime again.
    pub fn releaseDeferred(self: *SharedRuntime) bool {
        return self.releaseImplicit();
    }
};
