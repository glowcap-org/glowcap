//! The opt-in convenience drain for `libpancake_host` (ADR-0072 fifth
//! amendment): `pancake_host_pump_drain` runs the one-loop drain over
//! `pancake_host_next_action` for the embedder, dispatching each action to a
//! `PancakeHostPumpHooks` arm. The pull-queue stays normative — this wraps it,
//! it does not replace it. The Zig-facing loop helpers live in
//! `embedder_pump.zig`; this leaf only binds the C hook surface onto them.

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const embedder_pump = @import("embedder_pump.zig");

const PancakeHost = c.PancakeHost;
const PancakeHostAction = c.PancakeHostAction;
const PancakeHostPumpArmFn = c.PancakeHostPumpArmFn;
const PancakeHostPumpHooks = c.PancakeHostPumpHooks;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INTERNAL = shared.PANCAKE_ERR_INTERNAL;

/// Opt-in convenience drain over `pancake_host_next_action` (ADR-0072 fifth
/// amendment). Still pops through the pull-queue internally; does not replace
/// it. NULL `hooks` discards every action (rarely useful). `*out_acted` is 1
/// when any arm reported progress (optional).
pub export fn pancake_host_pump_drain(
    host: ?*PancakeHost,
    hooks: ?*const PancakeHostPumpHooks,
    out_acted: ?*u32,
) i32 {
    if (host == null) {
        shared.setLastError("null host", .{});
        return PANCAKE_ERR_NULL_POINTER;
    }
    const Exec = struct {
        hooks: ?*const PancakeHostPumpHooks,
        err: i32 = PANCAKE_OK,

        fn callArm(self: *@This(), arm: ?PancakeHostPumpArmFn, h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            const hooks_ptr = self.hooks orelse return false;
            const cb = arm orelse return false;
            var progressed: u32 = 0;
            const rc = cb(hooks_ptr.ctx, h, action, &progressed);
            if (rc != PANCAKE_OK) {
                self.err = rc;
                return error.ArmFailed;
            }
            return progressed != 0;
        }
        pub fn flush(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.flush else null, h, action);
        }
        pub fn close(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.close else null, h, action);
        }
        pub fn needGiftId(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.need_gift_id else null, h, action);
        }
        pub fn complete(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.complete else null, h, action);
        }
        pub fn dial(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.dial else null, h, action);
        }
    };
    var exec = Exec{ .hooks = hooks };
    const acted = embedder_pump.drainHost(c, shared, host, &exec) catch {
        if (exec.err != PANCAKE_OK) return exec.err;
        shared.setLastError("host action drain failed", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    if (out_acted) |slot| slot.* = if (acted) 1 else 0;
    return PANCAKE_OK;
}
