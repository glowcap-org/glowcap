//! Versioned session-limit configuration at the byte-fed Host boundary.
//!
//! The C record is selective: zero preserves the Host's current value. This
//! leaf validates its layout and numeric representation, then hands one patch
//! to the core authority before any future Session is minted.

const std = @import("std");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

/// Apply the versioned selective session-limit overrides before minting peers.
/// Zero fields remain unchanged. Peers already open keep the limits they were
/// minted with; later mints see the updated `Host.Options`.
pub export fn pancake_host_set_session_limits(
    host: ?*c.PancakeHost,
    options: ?*const c.PancakeSessionLimitOptions,
) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(host) orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "set_session_limits")) return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    const opts = options orelse return shared.PANCAKE_ERR_NULL_POINTER;
    if (opts.abi_version != c.PANCAKE_SESSION_LIMIT_OPTIONS_ABI_VERSION or
        opts.struct_size < @sizeOf(c.PancakeSessionLimitOptions))
    {
        shared.setLastError("host: unsupported PancakeSessionLimitOptions layout", .{});
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    if (opts.max_retained_sent_answer_bytes > std.math.maxInt(u32)) {
        shared.setLastError("host: max_retained_sent_answer_bytes exceeds uint32 capacity", .{});
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.setSessionLimits(
        if (opts.max_frame_bytes != 0) opts.max_frame_bytes else null,
        if (opts.queue_cap != 0) opts.queue_cap else null,
        if (opts.outbound_high_water_bytes != 0) opts.outbound_high_water_bytes else null,
        if (opts.max_retained_sent_answer_bytes != 0)
            @intCast(opts.max_retained_sent_answer_bytes)
        else
            null,
    ) catch |err| return common.errToCode(err);
    return shared.PANCAKE_OK;
}
