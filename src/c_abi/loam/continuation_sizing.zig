//! Pure demand queries preserve the distinct custody and projection owners.
const std = @import("std");
const common = @import("common.zig");
const shared = common.shared;
const c = common.c;

pub fn glowcap_loam_continuation_size_bound(raw: ?*const c.GlowcapLoamValueBounds, verb_bytes: usize, targets: usize, out_bounds: ?*c.GlowcapLoamContinuationBounds) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_bounds orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = std.mem.zeroes(c.GlowcapLoamContinuationBounds);
    const shape = raw orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const custody = common.hosting.Continuation.sizeBound(.{ .values = shape.values, .struct_entries = shape.struct_entries, .bytes = shape.bytes, .capabilities = shape.capabilities }, verb_bytes, targets) catch |err| return common.code(err);
    var input: common.hosting.references.AllocationBound = .{};
    input.include(std.math.mul(usize, targets, @sizeOf(common.driver.Capability)) catch |err| return common.code(err), @alignOf(common.driver.Capability), 1) catch |err| return common.code(err);
    const call = input.physicalBytes() catch |err| return common.code(err);
    out.* = .{ .custody_bytes = custody, .observer_bytes = @sizeOf(@import("continuations.zig").Control), .call_bytes = call };
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_effect_execution_result_size_bound(reply_bytes: usize, out_bounds: ?*c.GlowcapLoamEffectExecutionBounds) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_bounds orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = std.mem.zeroes(c.GlowcapLoamEffectExecutionBounds);
    const caller = @import("effect_execution.zig").Observer.callerBytes(reply_bytes) catch |err| return common.code(err);
    out.* = .{ .caller_bytes = caller, .host_dispatch_bytes = common.hosting.Execution.metadataBytes() };
    return shared.GLOWCAP_OK;
}
