//! The opt-in convenience drain for `libglowcap_host` (ADR-0072 fifth
//! amendment): `glowcap_host_pump_drain` runs the one-loop drain over
//! `glowcap_host_next_action` for the embedder, dispatching each action to a
//! `GlowcapHostPumpHooks` arm. The pull-queue stays normative — this wraps it,
//! it does not replace it. The Zig-facing loop helpers live in
//! `embedder_pump.zig`; this leaf only binds the C hook surface onto them.

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");
const embedder_pump = @import("embedder_pump.zig");

const GlowcapHost = c.GlowcapHost;
const GlowcapHostAction = c.GlowcapHostAction;
const GlowcapHostPumpArmFn = c.GlowcapHostPumpArmFn;
const GlowcapHostPumpHooks = c.GlowcapHostPumpHooks;

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INTERNAL = shared.GLOWCAP_ERR_INTERNAL;

/// Opt-in convenience drain over `glowcap_host_next_action` (ADR-0072 fifth
/// amendment). Still pops through the pull-queue internally; does not replace
/// it. NULL `hooks` discards every action (rarely useful). `*out_acted` is 1
/// when any arm reported progress (optional). `*out_yielded` is 1 when the
/// finite Host scheduler requested another embedder turn (optional); return to
/// the reactor before calling the drain again. Resuming work through the
/// underlying pop may synchronously invoke a `GlowcapHostBehavior` before an
/// action hook runs; binding runtimes must install their Host delivery context
/// around this whole call.
pub export fn glowcap_host_pump_drain(
    host: ?*GlowcapHost,
    hooks: ?*const GlowcapHostPumpHooks,
    out_acted: ?*u32,
    out_yielded: ?*u32,
) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(host) orelse {
        shared.setLastError("null host", .{});
        return GLOWCAP_ERR_NULL_POINTER;
    };
    if (!common.embedderOwnsDrive(inst, "pump_drain")) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
    const Exec = struct {
        hooks: ?*const GlowcapHostPumpHooks,
        err: i32 = GLOWCAP_OK,

        fn callArm(self: *@This(), arm: ?GlowcapHostPumpArmFn, h: ?*GlowcapHost, action: *const GlowcapHostAction) !bool {
            const hooks_ptr = self.hooks orelse return false;
            const cb = arm orelse return false;
            var progressed: u32 = 0;
            const rc = cb(hooks_ptr.ctx, h, action, &progressed);
            if (rc != GLOWCAP_OK) {
                // A non-OK arm is a transactional refusal: it must have
                // published no external effect. Keep this exact borrowed pop
                // first for the next drain rather than losing it or appending
                // it behind younger actions.
                self.err = if (c.retryBorrowedAction(h)) rc else GLOWCAP_ERR_INTERNAL;
                return error.ArmFailed;
            }
            return progressed != 0;
        }
        pub fn flush(self: *@This(), h: ?*GlowcapHost, action: *const GlowcapHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.flush else null, h, action);
        }
        pub fn close(self: *@This(), h: ?*GlowcapHost, action: *const GlowcapHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.close else null, h, action);
        }
        pub fn needGiftId(self: *@This(), h: ?*GlowcapHost, action: *const GlowcapHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.need_gift_id else null, h, action);
        }
        pub fn complete(self: *@This(), h: ?*GlowcapHost, action: *const GlowcapHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.complete else null, h, action);
        }
        pub fn dial(self: *@This(), h: ?*GlowcapHost, action: *const GlowcapHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.dial else null, h, action);
        }
    };
    var exec = Exec{ .hooks = hooks };
    const result = embedder_pump.drainHost(c, shared, host, &exec) catch {
        if (exec.err != GLOWCAP_OK) return exec.err;
        shared.setLastError("host action drain failed", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    if (out_acted) |slot| slot.* = if (result.acted) 1 else 0;
    if (out_yielded) |slot| slot.* = if (result.yielded) 1 else 0;
    return GLOWCAP_OK;
}
