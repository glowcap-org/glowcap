//! Read interface declarations copy into the shared recursive custody owner.
const common = @import("common.zig");
const callbacks = @import("callbacks.zig");
const std = @import("std");
const continuations = @import("continuations.zig");
const c = common.c;
const shared = common.shared;
const Scope = common.hosting.ReadScope;

pub fn glowcap_loam_call_disclose_reads_copying(raw: ?*c.GlowcapLoamCall, target: ?*const shared.GlowcapReference, interfaces: ?[*]const c.GlowcapLoamReadInterface, interface_count: usize, role: usize, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    disclose(raw, target, interfaces, interface_count, role, out) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

fn disclose(raw: ?*c.GlowcapLoamCall, target: ?*const shared.GlowcapReference, interfaces: ?[*]const c.GlowcapLoamReadInterface, count: usize, role: usize, out: *shared.GlowcapReference) !void {
    const call: *callbacks.Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active) return error.WrongPhase;
    const ref = target orelse return error.NullPointer;
    const arena = call.content_call.allocator();
    // Temporary POD projection uses the already bounded retained-call arena.
    // Names and role arrays remain borrowed until the shared copying constructor.
    const projected = try project(arena, interfaces, count);
    const value = try call.content_call.discloseReadsCopying(call.host.capabilityFromRaw(ref.id), projected, role);
    // This is a callback borrow. Shared Call custody, then ordinary reply
    // projection, owns the facade; no extra C observer or raw target escapes.
    out.* = .{ .id = value.capability.raw() };
}

fn project(arena: std.mem.Allocator, interfaces: ?[*]const c.GlowcapLoamReadInterface, count: usize) ![]const Scope.Interface {
    const declarations = try common.slice(c.GlowcapLoamReadInterface, interfaces, count);
    const projected = try arena.alloc(Scope.Interface, count);
    for (projected, declarations) |*out_interface, declaration| {
        const input = try common.slice(c.GlowcapLoamReadMethod, declaration.methods, declaration.method_count);
        const methods = try arena.alloc(Scope.Method, input.len);
        for (methods, input) |*out_method, method| out_method.* = .{
            .verb = try common.slice(u8, method.verb, method.verb_len),
            .results = try common.slice(usize, method.results, method.result_count),
        };
        out_interface.* = .{ .methods = methods };
    }
    return projected;
}

pub fn glowcap_loam_continuation_project_reads_copying(raw: ?*c.GlowcapLoamContinuation, index: usize, interfaces: ?[*]const c.GlowcapLoamReadInterface, interface_count: usize, role: usize, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    projectContinuation(raw, index, interfaces, interface_count, role, out) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

fn projectContinuation(raw: ?*c.GlowcapLoamContinuation, index: usize, interfaces: ?[*]const c.GlowcapLoamReadInterface, count: usize, role: usize, out: *shared.GlowcapReference) !void {
    const observer = try continuations.control(raw);
    try observer.owner.value.topLevel();
    const continuation = try observer.active();
    // POD projection has a transient ceiling independent of the retained
    // scope. Payload leaves stay borrowed until the shared declaration copy.
    var scratch: common.hosting.Call.Memory = undefined;
    scratch.init(observer.owner.store.allocator, observer.owner.value.options.continuation_bytes);
    defer scratch.deinit();
    const declarations = try project(scratch.input.allocator(), interfaces, count);
    out.* = .{ .id = (try continuation.projectReadsCopying(index, declarations, role)).raw() };
}

pub fn glowcap_loam_read_scope_size_bound(arguments: ?*const c.GlowcapLoamValueBounds, source_verb_bytes: usize, interfaces: usize, methods: usize, verb_bytes: usize, result_roles: usize, targets: usize, out_bytes: ?*usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_bytes orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const input = arguments orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = Scope.sizeBound(.{ .values = input.values, .struct_entries = input.struct_entries, .bytes = input.bytes, .capabilities = input.capabilities }, source_verb_bytes, .{ .interfaces = interfaces, .methods = methods, .verb_bytes = verb_bytes, .result_roles = result_roles, .targets = targets }) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
