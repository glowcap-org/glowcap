//! Zig-only ownership bridge from `libglowcap_host` to the sibling driver. The
//! C handle remains owned by this archive. The bridge gives the driver one
//! transactional claim over transport/action draining and projects the few Host
//! internals the driver must consume without exporting another C symbol.

const std = @import("std");

const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const instance = @import("instance.zig");
const marshal = @import("marshal.zig");

pub const DriverClaim = struct {
    inst: *instance.Instance,

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

/// Borrow the existing Host for a companion attachment. Terminal release is
/// refused until the companion returns this borrow. It owns no driving rights.
pub const AttachmentBorrow = struct {
    inst: *instance.Instance,
    pub fn core(self: AttachmentBorrow) *driver_core.Host {
        return &self.inst.core;
    }
    pub fn release(self: AttachmentBorrow) void {
        std.debug.assert(self.inst.attachment_borrows != 0);
        self.inst.attachment_borrows -= 1;
    }
};

pub fn borrowForAttachment(handle: ?*c.GlowcapHost) !AttachmentBorrow {
    const inst = instance.instanceFrom(handle) orelse return error.NullPointer;
    if (inst.core.withinCallback()) return error.ReenteredHost;
    if (inst.core.lifecyclePhase() != .active) return error.Closed;
    inst.attachment_borrows = try std.math.add(usize, inst.attachment_borrows, 1);
    return .{ .inst = inst };
}

pub fn checkAttachmentsReleased(handle: ?*c.GlowcapHost) !void {
    const inst = instance.instanceFrom(handle) orelse return error.NullPointer;
    if (inst.attachment_borrows != 0) return error.Busy;
}

pub const valueToC = marshal.valueToC;
pub const valueProjectionBound = marshal.valueProjectionBound;

/// Claim the C handle's transport/action-drain ownership for a Zig driver
/// construction. `HostRuntime.initWithCore` validates whether the core itself
/// can transfer. Rollback restores this token if it cannot.
pub fn claimForDriver(handle: ?*c.GlowcapHost) ClaimError!?DriverClaim {
    const inst = instance.instanceFrom(handle) orelse return null;
    if (inst.drive_owner != .embedder) return error.HostAlreadyOwned;
    inst.drive_owner = .driver;
    return .{ .inst = inst };
}

pub const releaseFromDriver = instance.releaseFromDriver;

/// The C handle a core session projects as. The driver archive's events carry
/// sessions in the same handle vocabulary every `glowcap_host_*` verb takes.
pub fn sessionHandle(hs: *driver_core.HostSession) *c.GlowcapHostSession {
    return @ptrCast(hs);
}

pub const sessionFrom = instance.sessionFrom;

/// Project one taken settled/failed completion onto the C action shape, with
/// the byte-fed queue's exact lifetime sentence: one scratch reset per pop,
/// then the projection allocates its views there. The caller serializes this
/// with `glowcap_host_next_action` on the one driving thread (a loop-tier
/// consumer does not drain the byte-fed queue).
pub fn projectCompletion(
    handle: ?*c.GlowcapHost,
    action: driver_core.HostAction,
    slot: *c.GlowcapHostAction,
) i32 {
    const inst = instance.instanceFrom(handle) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    _ = inst.completion_scratch.reset(.{ .retain_with_limit = instance.steady_scratch_bytes });
    return marshal.projectCompletionInto(inst, action, slot);
}
