//! The smallest content callbacks a C attach accepts: no requirement, a void
//! reply, and fixed entropy. Tests about attaching share them.
const std = @import("std");
const c = @import("c_abi_loam");
const shared = @import("c_abi_shared");

pub fn requirements(_: ?*anyopaque, _: *const c.GlowcapLoamInvocation, out: *c.GlowcapLoamRequirement) callconv(.c) i32 {
    out.* = std.mem.zeroes(c.GlowcapLoamRequirement);
    return shared.GLOWCAP_OK;
}
pub fn invoke(_: ?*anyopaque, call: *c.GlowcapLoamCall, _: *const c.GlowcapLoamInvocation) callconv(.c) i32 {
    var value = std.mem.zeroes(shared.GlowcapArgument);
    value.kind = shared.GLOWCAP_ARG_VOID;
    return c.glowcap_loam_call_reply(call, &value);
}
pub fn entropy(_: ?*anyopaque, bytes: [*]u8, len: usize) callconv(.c) i32 {
    @memset(bytes[0..len], 9);
    return shared.GLOWCAP_OK;
}
