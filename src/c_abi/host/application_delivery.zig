//! Sessionless application admission over the existing owning Host queue.
const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

/// Eventual-send through this Host without borrowing a network session. The
/// actual target determines its local or foreign home. Input values borrow
/// this call. The existing queue owns their copies and capability retains.
/// The returned vow is await-only and settles through Host actions. Releasing
/// its observer does not cancel admitted work. Refused inside a callback.
/// `turn_send` owns that turn's transactional delivery instead.
pub fn glowcap_host_send(
    raw: ?*c.GlowcapHost,
    target: ?*const shared.GlowcapReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(raw) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const destination = target orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const output = out_vow orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    inst.core.refuseReentry() catch |err| return common.errToCode(err);
    const message = common.valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return common.errToCode(err);
    output.* = inst.core.sendApplicationValues(inst.core.capabilityFromRaw(destination.id), message.verb, message.args, inst.arg_scratch.allocator()) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}

/// Notification through the target's actual home, with no reply or vow.
/// Input values borrow this call. The owning queue retains admitted work.
/// Refused inside a callback, where turn_tell owns transactional delivery.
pub fn glowcap_host_tell(
    raw: ?*c.GlowcapHost,
    target: ?*const shared.GlowcapReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = common.instanceFrom(raw) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const destination = target orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    inst.core.refuseReentry() catch |err| return common.errToCode(err);
    const message = common.valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return common.errToCode(err);
    inst.core.tellApplicationValues(inst.core.capabilityFromRaw(destination.id), message.verb, message.args, inst.arg_scratch.allocator()) catch |err| return common.errToCode(err);
    return shared.GLOWCAP_OK;
}
