//! Zig-only ownership bridge from `libpancake_host` to the sibling driver.
//!
//! The C handle remains owned by this archive. This leaf gives the driver one
//! transactional claim over transport/action draining and projects the few
//! Host internals the driver must consume without exporting another C symbol.

const std = @import("std");

const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

pub const DriverClaim = struct {
    inst: *common.Instance,

    pub fn allocator(self: DriverClaim) std.mem.Allocator {
        return self.inst.allocator;
    }

    pub fn core(self: DriverClaim) *driver_core.Host {
        return &self.inst.core;
    }

    /// Roll back a failed driver construction. No driver-owned operation may
    /// have escaped while construction was fallible.
    pub fn rollback(self: DriverClaim) void {
        std.debug.assert(self.inst.drive_owner == .driver);
        self.inst.drive_owner = .embedder;
    }
};

pub const ClaimError = error{HostAlreadyOwned};

/// Claim the C handle's transport/action-drain ownership for a native driver
/// construction. `HostRuntime.initWithCore` validates whether the core itself
/// can transfer; rollback restores this token if it cannot.
pub fn claimForDriver(handle: ?*c.PancakeHost) ClaimError!?DriverClaim {
    const inst = common.instanceFrom(handle) orelse return null;
    if (inst.drive_owner != .embedder) return error.HostAlreadyOwned;
    inst.drive_owner = .driver;
    return .{ .inst = inst };
}

pub fn releaseFromDriver(handle: *c.PancakeHost) ?anyerror {
    return common.releaseFromDriver(handle);
}

/// The C handle a core session projects as; the driver archive's events carry
/// sessions in the same handle vocabulary every `pancake_host_*` verb takes.
pub fn sessionHandle(hs: *driver_core.HostSession) *c.PancakeHostSession {
    return @ptrCast(hs);
}

pub fn sessionFrom(raw: ?*c.PancakeHostSession) ?*driver_core.HostSession {
    return common.sessionFrom(raw);
}

/// Project one taken settled/failed completion onto the C action shape, with
/// the byte-fed queue's exact lifetime sentence: one scratch reset per pop,
/// then the projection allocates its views there. The caller serializes this
/// with `pancake_host_next_action` on the one driving thread (a loop-tier
/// consumer does not drain the byte-fed queue).
pub fn projectCompletion(
    handle: ?*c.PancakeHost,
    action: driver_core.HostAction,
    slot: *c.PancakeHostAction,
) i32 {
    const inst = common.instanceFrom(handle) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    _ = inst.completion_scratch.reset(.{ .retain_with_limit = common.steady_scratch_bytes });
    return common.projectCompletionInto(inst, action, slot);
}
