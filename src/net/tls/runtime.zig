//! Owned runtime capable of opening many client TLS engines.
//!
//! Concrete engines keep their implementation private. A relay carrier owns
//! this value, opens one client per secure route, and releases it only after
//! every channel lease is gone.

const std = @import("std");
const engine = @import("engine.zig");

const foundation = @import("foundation");

pub const OpenOutcome = union(enum) {
    client: engine.Client,
    failed: engine.Failure,
};

pub const Runtime = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (*anyopaque, []const u8) OpenOutcome,
        same_configuration: *const fn (*anyopaque, *anyopaque) bool,
        deinit_outcome: *const fn (*anyopaque) ?foundation.FailureChain,
    };

    pub fn open(self: Runtime, hostname: []const u8) OpenOutcome {
        return self.vtable.open(self.ctx, hostname);
    }

    /// Compare immutable engine policy without exposing engine-specific trust
    /// material. Different implementations are conservatively distinct even
    /// when they happen to accept the same certificates.
    pub fn sameConfiguration(self: Runtime, other: Runtime) bool {
        if (self.vtable != other.vtable) return false;
        return self.vtable.same_configuration(self.ctx, other.ctx);
    }

    /// Consume the runtime on success. A failure is non-consuming so the
    /// owner can finish remaining client barriers and retry.
    pub fn deinitOutcome(self: *Runtime) ?foundation.FailureChain {
        const failure = self.vtable.deinit_outcome(self.ctx);
        if (failure == null) self.* = undefined;
        return failure;
    }
};
