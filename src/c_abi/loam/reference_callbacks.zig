//! Reference declarations copy into the retained call before callback return.
const std = @import("std");
const common = @import("common.zig");
const callbacks = @import("callbacks.zig");
const c = common.c;
const refs = common.hosting.references;

/// Conservative reference contribution to call_bytes, including this seam's
/// copied requests and supplied URI bytes. The complete call adds other owners.
/// No allocation, capability lookup, storage access or admission occurs here.
pub fn glowcap_loam_reference_call_size_bound(restores: usize, saves: usize, uri_bytes: usize, out_bytes: ?*usize) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const out = out_bytes orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    out.* = callSizeBound(restores, saves, uri_bytes) catch |err| return common.code(err);
    return common.shared.GLOWCAP_OK;
}

fn callSizeBound(restores: usize, saves: usize, uri_bytes: usize) !usize {
    var bound = try refs.allocationBound(restores, saves, uri_bytes);
    try bound.include(uri_bytes, 1, saves);
    const requests = try std.math.add(usize, restores, saves);
    // Append borrows the final slice; it has no toOwnedSlice allocation. Count
    // every intermediate spine in case in-place growth is unavailable.
    try bound.includeArrayGrowth(refs.Request, requests);
    return bound.physicalBytes();
}

/// Extra retained-call bytes for opt-in restoration URI copies. No I/O or
/// allocation occurs here. Normal reference preparation is counted separately.
pub fn glowcap_loam_reference_uri_call_size_bound(count: usize, uri_bytes: usize, out_bytes: ?*usize) callconv(.c) i32 {
    common.shared.lastErrorClear();
    const out = out_bytes orelse return common.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const bound = refs.retainedUriAllocationBound(count, uri_bytes) catch |err| return common.code(err);
    out.* = bound.physicalBytes() catch |err| return common.code(err);
    return common.shared.GLOWCAP_OK;
}

const Declaration = struct {
    arena: std.mem.Allocator,
    host: *common.driver.Host,
    field_count: usize,
    graph: ?common.access.hosting.graph.Snapshot = null,
    capacity: usize,
    requests: std.ArrayList(refs.Request) = .empty,
};

pub fn declare(ctx: ?*anyopaque, arena: std.mem.Allocator, invocation: common.access.hosting.ContentInvocation) ![]const refs.Request {
    const registration: *callbacks.Content = @ptrCast(@alignCast(ctx.?));
    const input = try callbacks.input(arena, invocation, registration.graph != null);
    // A complete replacement may restore every old field and save every new
    // field in the same preparation. Graph edges bound each population, not
    // their combined request inventory; the call arena still owns admission.
    const fields = if (registration.graph) |spec| spec.max_edges else common.max_content_fields;
    var declaration: Declaration = .{ .arena = arena, .host = registration.host, .field_count = input.field_count, .graph = invocation.graph, .capacity = try std.math.mul(usize, fields, 2) };
    const prior = registration.host.in_callback;
    registration.host.in_callback = true;
    defer registration.host.in_callback = prior;
    if (registration.declaration.references.?(registration.declaration.context, @ptrCast(&declaration), &input) != common.shared.GLOWCAP_OK) return error.ApplicationRefused;
    return declaration.requests.items;
}

/// The synchronous declaration borrows C buffers. The retained preparation
/// owns its bounded request spine and URI copies of at most GLOWCAP_LOAM_MAX_URI_BYTES.
/// Host save quotas bound active enlivenment. No callback borrow survives.
pub fn save(raw: ?*c.GlowcapLoamReferences, reference: common.shared.GlowcapReference, uri: ?[*]const u8, uri_len: usize) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (declaration.requests.items.len >= declaration.capacity or uri_len > refs.max_uri_bytes) return error.ReferenceCapacity;
    const capability = declaration.host.capabilityFromRaw(reference.id);
    const copied = if (uri != null) try declaration.arena.dupe(u8, try common.shared.sliceFromC(uri, uri_len)) else if (uri_len == 0) null else return error.NullPointer;
    try declaration.requests.append(declaration.arena, .{ .save = .{ .capability = capability, .uri = copied } });
}

/// Explicit live declaration copies only the request spine. Shared preparation
/// reserves exact capability custody before waits. No runtime ID is persisted.
pub fn saveLive(raw: ?*c.GlowcapLoamReferences, reference: common.shared.GlowcapReference) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (declaration.requests.items.len >= declaration.capacity) return error.ReferenceCapacity;
    try declaration.requests.append(declaration.arena, .{ .save_live = declaration.host.capabilityFromRaw(reference.id) });
}

pub fn saveLiveDependent(raw: ?*c.GlowcapLoamReferences, source: common.shared.GlowcapReference, target: common.shared.GlowcapReference) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (declaration.requests.items.len >= declaration.capacity) return error.ReferenceCapacity;
    try declaration.requests.append(declaration.arena, .{ .save_live_dependent = .{
        .source = declaration.host.capabilityFromRaw(source.id),
        .target = declaration.host.capabilityFromRaw(target.id),
    } });
}

pub fn restore(raw: ?*c.GlowcapLoamReferences, index: usize) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (index >= declaration.field_count) return error.NoSuchEdge;
    if (declaration.requests.items.len >= declaration.capacity) return error.ReferenceCapacity;
    const field = index + 1;
    for (declaration.requests.items) |request| if (request == .restore and request.restore == field) return error.DuplicateReferenceEdit;
    try declaration.requests.append(declaration.arena, .{ .restore = field });
}

pub fn restorePage(raw: ?*c.GlowcapLoamReferences, handle: ?*const c.GlowcapLoamPageHandle, index: usize) !void {
    return restorePageWithUri(raw, handle, index, false);
}

pub fn restorePageWithUri(raw: ?*c.GlowcapLoamReferences, handle: ?*const c.GlowcapLoamPageHandle, index: usize, retain_uri: bool) !void {
    return declarePage(raw, handle, index, retain_uri, false);
}

pub fn inspectPageUri(raw: ?*c.GlowcapLoamReferences, handle: ?*const c.GlowcapLoamPageHandle, index: usize) !void {
    return declarePage(raw, handle, index, true, true);
}

fn declarePage(raw: ?*c.GlowcapLoamReferences, handle: ?*const c.GlowcapLoamPageHandle, index: usize, retain_uri: bool, metadata_only: bool) !void {
    const declaration: *Declaration = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    const snapshot = declaration.graph orelse return error.NotContentGraph;
    const page_handle: *const common.access.hosting.graph.PageHandle = @ptrCast(handle orelse return error.NullPointer);
    const view = try snapshot.page(page_handle);
    const field = try std.math.add(usize, index, 1);
    if (field >= view.edge_count) return error.NoSuchEdge;
    if (declaration.requests.items.len >= declaration.capacity) return error.ReferenceCapacity;
    const page_index = for (snapshot.pages, 0..) |*page, i| {
        if (page.handle() == page_handle) break i;
    } else unreachable;
    const selection: @FieldType(refs.Request, "restore_record") = .{ .record = page_index + 1, .index = field, .retain_uri = retain_uri, .metadata_only = metadata_only };
    for (declaration.requests.items) |request| if (request == .restore_record and request.restore_record.record == selection.record and request.restore_record.index == selection.index) return error.DuplicateReferenceEdit;
    try declaration.requests.append(declaration.arena, .{ .restore_record = selection });
}
