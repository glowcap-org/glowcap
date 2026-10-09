//! Callback-borrowed page tokens project shared graph selection and staging.
const common = @import("common.zig");
const graph = @import("graph_callbacks.zig");
const c = common.c;
const shared = common.shared;

/// Own one occurrence of exact prepared reference custody beyond callback
/// return. Preparation validates its recipe; this grants no disclosure.
/// Release the returned occurrence through glowcap_host_ref_release.
pub fn glowcap_loam_call_retain_prepared_reference(raw: ?*c.GlowcapLoamCall, reference: ?*const shared.GlowcapReference, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    const target = reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const call: *@import("callbacks.zig").Call = @ptrCast(@alignCast(raw orelse return shared.GLOWCAP_ERR_NULL_POINTER));
    if (!call.active) return common.code(error.WrongPhase);
    const retained = call.content_call.retainPreparedReference(call.host.capabilityFromRaw(target.id)) catch |err| return common.code(err);
    out.* = .{ .id = retained.raw() };
    return shared.GLOWCAP_OK;
}

/// Return one owned occurrence of the actual invoking endpoint. Content may
/// compare it with saved receipt custody. It grants no reply disclosure.
pub fn glowcap_loam_call_source(raw: ?*c.GlowcapLoamCall, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const call: *@import("callbacks.zig").Call = @ptrCast(@alignCast(raw orelse return shared.GLOWCAP_ERR_NULL_POINTER));
    if (!call.active) return common.code(error.WrongPhase);
    const source = call.content_call.retainSource() catch |err| return common.code(err);
    out.* = .{ .id = source.raw() };
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_call_replace_graph_copying(call: ?*c.GlowcapLoamCall, payload: ?[*]const u8, payload_len: usize, pages: ?[*]const c.GlowcapLoamPageReplacement, count: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    graph.replaceCopying(call, payload, payload_len, pages, count) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_call_page_reference(call: ?*c.GlowcapLoamCall, page: ?*const c.GlowcapLoamPageHandle, index: usize, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    graph.reference(call, page, index, out_reference) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_call_disclose_page(call: ?*c.GlowcapLoamCall, page: ?*const c.GlowcapLoamPageHandle, index: usize, dependent: u32, out_value: ?*shared.GlowcapArgument) callconv(.c) i32 {
    shared.lastErrorClear();
    if (dependent > 1) return common.code(error.InvalidArgument);
    graph.disclose(call, page, index, dependent == 1, out_value) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_references_restore_page(references: ?*c.GlowcapLoamReferences, page: ?*const c.GlowcapLoamPageHandle, index: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    @import("reference_callbacks.zig").restorePage(references, page, index) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

/// Declare exact page restoration and retain its canonical foreign URI
/// through callback return. Local and live metadata remain null.
pub fn glowcap_loam_references_restore_page_with_uri(references: ?*c.GlowcapLoamReferences, page: ?*const c.GlowcapLoamPageHandle, index: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    @import("reference_callbacks.zig").restorePageWithUri(references, page, index, true) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

/// Inspect a selected field's canonical recipe without restoring authority.
/// The URI borrows the bounded retained Call; local and live recipes return null.
pub fn glowcap_loam_references_inspect_page_uri(references: ?*c.GlowcapLoamReferences, page: ?*const c.GlowcapLoamPageHandle, index: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    @import("reference_callbacks.zig").inspectPageUri(references, page, index) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

/// Borrow the exact restored field's canonical foreign URI through callback
/// return. A local recipe returns null/zero. This does not disclose authority.
pub fn glowcap_loam_call_page_saved_uri(call: ?*c.GlowcapLoamCall, page: ?*const c.GlowcapLoamPageHandle, index: usize, out_uri: ?*?[*]const u8, out_len: ?*usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const uri = out_uri orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const len = out_len orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    uri.* = null;
    len.* = 0;
    if (graph.savedUri(call, page, index) catch |err| return common.code(err)) |bytes| {
        uri.* = bytes.ptr;
        len.* = bytes.len;
    }
    return shared.GLOWCAP_OK;
}
