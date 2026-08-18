//! Byte-fed Host close and release projection for the C ABI.

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

pub fn diagnosticId(host: ?*c.PancakeHost, out_id: ?*u64) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const slot = out_id orelse return shared.PANCAKE_ERR_NULL_POINTER;
    slot.* = inst.diagnostic_id;
    return shared.PANCAKE_OK;
}

fn progress(inst: *common.Instance, now_ms: i64) i32 {
    inst.core.progressClose(now_ms) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}

fn project(inst: *const common.Instance) u32 {
    return switch (inst.core.lifecyclePhase()) {
        .active => c.PANCAKE_LIFECYCLE_ACTIVE,
        .finishing => c.PANCAKE_LIFECYCLE_FINISHING,
        .terminating => c.PANCAKE_LIFECYCLE_TERMINATING,
        .closed => c.PANCAKE_LIFECYCLE_CLOSED,
    };
}

fn outcomeCode(inst: *const common.Instance) i32 {
    return if (inst.core.closeOutcome(inst.core.lifecyclePhase() == .closed) == .timed_out)
        shared.PANCAKE_ERR_TIMEOUT
    else
        shared.PANCAKE_OK;
}

pub fn close(
    host: ?*c.PancakeHost,
    options: ?*const c.PancakeCloseOptions,
    now_ms: i64,
) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "close")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const policy = c.parseCloseOptions(options) catch |err|
        return c.closeOptionsErrorCode("host", err);
    inst.core.beginClose(policy, now_ms);
    return shared.PANCAKE_OK;
}

pub fn closeProgress(host: ?*c.PancakeHost, now_ms: i64, out_state: ?*u32) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "close_progress")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return shared.PANCAKE_ERR_NULL_POINTER;
    const rc = progress(inst, now_ms);
    if (rc != shared.PANCAKE_OK) return rc;
    slot.* = project(inst);
    return outcomeCode(inst);
}

pub fn closeWaitMs(host: ?*c.PancakeHost, now_ms: i64, out_wait_ms: ?*i64) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "close_wait_ms")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_wait_ms orelse return shared.PANCAKE_ERR_NULL_POINTER;
    slot.* = inst.core.closeWaitMs(now_ms);
    return shared.PANCAKE_OK;
}

pub fn state(host: ?*c.PancakeHost, out_state: ?*u32) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "lifecycle_state")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return shared.PANCAKE_ERR_NULL_POINTER;
    slot.* = project(inst);
    return outcomeCode(inst);
}

pub fn release(host: ?*c.PancakeHost) i32 {
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_OK;
    if (inst.drive_owner == .driver) {
        shared.setLastError("host: release refused because the driver owns this host", .{});
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.checkReleaseOwnershipTransfer() catch |err| return common.errToCode(err);
    if (common.releaseInstance(inst)) |failure| return common.errToCode(failure);
    return shared.PANCAKE_OK;
}
