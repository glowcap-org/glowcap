//! Pure managed-content demand projection. Invocation and admission stay owned.
const std = @import("std");
const common = @import("common.zig");

pub fn glowcap_loam_invocation_call_size_bound(raw: ?*const common.c.GlowcapLoamInvocationBounds, out_bytes: ?*usize) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const out = out_bytes orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const source = raw orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = (allocationBound(source.*) catch |err| return common.code(err)).physicalBytes() catch |err| return common.code(err);
    return common.shared.GLOWCAP_OK;
}

/// Reference and graph contributions are separate. Application callbacks,
/// single-record content/reference edits, resource/control edits, sharing,
/// observation and external forwarding need their own demand. Store staging,
/// Capabilities operations, registration,
/// settlement arenas, Rust buffers and Host network state have separate owners.
pub fn allocationBound(raw: common.c.GlowcapLoamInvocationBounds) !common.hosting.references.AllocationBound {
    if (raw.receipt > 1 or raw.dependent > 1) return error.InvalidArgument;
    const arguments = valueBounds(raw.arguments);
    const reply = valueBounds(raw.reply);
    var bound = try common.access.hosting.invocationAllocationBound(.{ .arguments = arguments, .reply = reply, .verb_bytes = raw.verb_bytes, .held_occurrences = raw.held_occurrences, .receipt = raw.receipt != 0, .dependent = raw.dependent != 0 });
    const projection = try common.host.embedding.valueProjectionBound(common.hosting.references.AllocationBound, arguments.values, arguments.struct_entries);
    // One cached requirement, one reference declaration, one invocation.
    for (0..3) |_| try bound.merge(projection);
    try bound.include(try std.math.mul(usize, common.access.core.Policy.max_permissions, @sizeOf(common.access.core.Policy.Key)), @alignOf(common.access.core.Policy.Key), 1);
    try bound.include(try std.math.mul(usize, common.access.core.Policy.max_constraints, @sizeOf(common.access.core.Policy.Bound)), @alignOf(common.access.core.Policy.Bound), 1);
    // valuesFromCWith allocates the reply root and copies byte leaves once.
    try bound.merge(try common.hosting.valueAllocationBound(common.driver.Value, reply));
    return bound;
}

fn valueBounds(raw: common.c.GlowcapLoamValueBounds) common.hosting.ValueBounds {
    return .{ .values = raw.values, .struct_entries = raw.struct_entries, .bytes = raw.bytes, .capabilities = raw.capabilities };
}

/// Forwarding owns a fixed Host reply inside the retained Loam call arena.
/// Neither private execution observers nor C projections belong to this path.
pub fn glowcap_loam_forwarding_size_bound(raw: ?*const common.c.GlowcapLoamValueBounds, out_reply_bytes: ?*usize, out_call_bytes: ?*usize) callconv(.c) i32 {
    common.shared.lastErrorClear();
    if (out_reply_bytes) |out| out.* = 0;
    if (out_call_bytes) |out| out.* = 0;
    const reply_out = out_reply_bytes orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    const call_out = out_call_bytes orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    const source = raw orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    const reply = common.hosting.valueAllocationBound(common.driver.Value, valueBounds(source.*)) catch |err| return common.code(err);
    const bytes = @max(1, reply.bytes);
    const call = common.driver.Host.Call.allocationBound(common.hosting.references.AllocationBound, bytes) catch |err| return common.code(err);
    const physical = call.physicalBytes() catch |err| return common.code(err);
    reply_out.* = bytes;
    call_out.* = physical;
    return common.shared.GLOWCAP_OK;
}
