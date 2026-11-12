//! Byte-fed Host close and release projection for the C ABI Host subject.

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const host_error = @import("error.zig");
const instance = @import("instance.zig");

pub fn diagnosticId(host: ?*c.GlowcapHost, out_id: ?*u64) i32 {
    const inst = instance.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const slot = out_id orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = inst.diagnostic_id;
    return shared.GLOWCAP_OK;
}

fn progress(inst: *instance.Instance, now_ms: i64) i32 {
    inst.core.progressClose(now_ms) catch |err| return host_error.errToCode(err);
    return shared.GLOWCAP_OK;
}

fn project(inst: *const instance.Instance) u32 {
    return switch (inst.core.lifecyclePhase()) {
        .active => c.GLOWCAP_LIFECYCLE_ACTIVE,
        .finishing => c.GLOWCAP_LIFECYCLE_FINISHING,
        .terminating => c.GLOWCAP_LIFECYCLE_TERMINATING,
        .closed => c.GLOWCAP_LIFECYCLE_CLOSED,
    };
}

fn outcomeCode(inst: *const instance.Instance) i32 {
    return if (inst.core.closeOutcome(inst.core.lifecyclePhase() == .closed) == .timed_out)
        shared.GLOWCAP_ERR_TIMEOUT
    else
        shared.GLOWCAP_OK;
}

pub fn close(
    host: ?*c.GlowcapHost,
    options: ?*const c.GlowcapCloseOptions,
    now_ms: i64,
) i32 {
    const inst = instance.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!instance.embedderOwnsDrive(inst, "close")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const policy = c.parseCloseOptions(options) catch |err|
        return c.closeOptionsErrorCode("host", err);
    inst.core.claimOwner() catch |err| return host_error.errToCode(err);
    inst.core.beginClose(policy, now_ms);
    return shared.GLOWCAP_OK;
}

pub fn closeProgress(host: ?*c.GlowcapHost, now_ms: i64, out_state: ?*u32) i32 {
    const inst = instance.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!instance.embedderOwnsDrive(inst, "close_progress")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const rc = progress(inst, now_ms);
    if (rc != shared.GLOWCAP_OK) return rc;
    slot.* = project(inst);
    return outcomeCode(inst);
}

pub fn closeWaitMs(host: ?*c.GlowcapHost, now_ms: i64, out_wait_ms: ?*i64) i32 {
    const inst = instance.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!instance.embedderOwnsDrive(inst, "close_wait_ms")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_wait_ms orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = inst.core.closeWaitMs(now_ms);
    return shared.GLOWCAP_OK;
}

pub fn state(host: ?*c.GlowcapHost, out_state: ?*u32) i32 {
    const inst = instance.instanceFrom(host) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (!instance.embedderOwnsDrive(inst, "lifecycle_state")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = project(inst);
    return outcomeCode(inst);
}

pub fn release(host: ?*c.GlowcapHost) i32 {
    const inst = instance.instanceFrom(host) orelse return shared.ReleaseResult.consumed(shared.GLOWCAP_OK).raw();
    if (inst.drive_owner == .driver) {
        shared.setLastError("host: release refused because the driver owns this host", .{});
        return shared.ReleaseResult.retained(shared.GLOWCAP_ERR_INVALID_ARGUMENT).raw();
    }
    inst.core.checkReleaseOwnershipTransfer() catch |err| return shared.ReleaseResult.retained(host_error.errToCode(err)).raw();
    c.embedding.checkAttachmentsReleased(host) catch {
        shared.setLastError("host: release refused while storage attachments borrow this host", .{});
        return shared.ReleaseResult.retained(shared.GLOWCAP_ERR_INVALID_ARGUMENT).raw();
    };
    if (instance.releaseInstance(inst)) |failure| return shared.ReleaseResult.consumed(host_error.errToCode(failure)).raw();
    return shared.ReleaseResult.consumed(shared.GLOWCAP_OK).raw();
}
