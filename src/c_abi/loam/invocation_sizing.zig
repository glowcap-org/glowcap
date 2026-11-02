//! Pure managed-content demand projection. Invocation and admission stay owned.
const std = @import("std");
const owners = @import("owners.zig");
const access = @import("loam_access");
const c = @import("layouts.zig");
const cd = @import("c_abi_host");
const driver = @import("driver_core");
const hosting = @import("loam_hosting");
const shared = @import("c_abi_shared");
const refusal = @import("refusal.zig");

pub fn glowcap_loam_invocation_call_size_bound(raw: ?*const c.GlowcapLoamInvocationBounds, out_bytes: ?*usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_bytes orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const source = raw orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = (allocationBound(source.*) catch |err| return refusal.code(err)).physicalBytes() catch |err| return refusal.code(err);
    return shared.GLOWCAP_OK;
}

/// Reference and graph contributions are separate. Application callbacks,
/// single-record content/reference edits, resource/control edits, sharing,
/// observation and external forwarding need their own demand. Store staging,
/// Capabilities operations, registration,
/// settlement arenas, Rust buffers and Host network state have separate owners.
pub fn allocationBound(raw: c.GlowcapLoamInvocationBounds) !hosting.references.AllocationBound {
    if (raw.receipt > 1 or raw.dependent > 1) return error.InvalidArgument;
    const arguments = valueBounds(raw.arguments);
    const reply = valueBounds(raw.reply);
    var bound = try access.hosting.invocationAllocationBound(.{ .arguments = arguments, .reply = reply, .verb_bytes = raw.verb_bytes, .held_occurrences = raw.held_occurrences, .receipt = raw.receipt != 0, .dependent = raw.dependent != 0 });
    const projection = try cd.embedding.valueProjectionBound(hosting.references.AllocationBound, arguments.values, arguments.struct_entries);
    // One cached requirement, one reference declaration, one invocation.
    for (0..3) |_| try bound.merge(projection);
    try bound.include(try std.math.mul(usize, access.core.Policy.max_permissions, @sizeOf(access.core.Policy.Key)), @alignOf(access.core.Policy.Key), 1);
    try bound.include(try std.math.mul(usize, access.core.Policy.max_constraints, @sizeOf(access.core.Policy.Bound)), @alignOf(access.core.Policy.Bound), 1);
    // valuesFromCWith allocates the reply root and copies byte leaves once.
    try bound.merge(try hosting.valueAllocationBound(driver.Value, reply));
    return bound;
}

fn valueBounds(raw: c.GlowcapLoamValueBounds) hosting.ValueBounds {
    return .{ .values = raw.values, .struct_entries = raw.struct_entries, .bytes = raw.bytes, .capabilities = raw.capabilities };
}

/// Forwarding owns a fixed Host reply inside the retained Loam call arena.
/// Neither private execution observers nor C projections belong to this path.
pub fn glowcap_loam_forwarding_size_bound(raw: ?*const c.GlowcapLoamValueBounds, out_reply_bytes: ?*usize, out_call_bytes: ?*usize) callconv(.c) i32 {
    shared.lastErrorClear();
    if (out_reply_bytes) |out| out.* = 0;
    if (out_call_bytes) |out| out.* = 0;
    const reply_out = out_reply_bytes orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const call_out = out_call_bytes orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const source = raw orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const reply = hosting.valueAllocationBound(driver.Value, valueBounds(source.*)) catch |err| return refusal.code(err);
    const bytes = @max(1, reply.bytes);
    const call = driver.Host.Call.allocationBound(hosting.references.AllocationBound, bytes) catch |err| return refusal.code(err);
    const physical = call.physicalBytes() catch |err| return refusal.code(err);
    reply_out.* = bytes;
    call_out.* = physical;
    return shared.GLOWCAP_OK;
}
