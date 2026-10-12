//! Stable dependent live fields project the shared declaration and comparison.
const common = @import("common.zig");
const callbacks = @import("callbacks.zig");
const c = common.c;
const shared = common.shared;

/// Declare one live facet from an actual source endpoint and exact target.
/// Preparation owns construction and reservation before waiting. No input
/// capability or runtime identity is serialized into its live recipe.
pub fn glowcap_loam_references_save_live_dependent(raw: ?*c.GlowcapLoamReferences, source: ?*const shared.GlowcapReference, target: ?*const shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    @import("reference_callbacks.zig").saveLiveDependent(raw, (source orelse return shared.GLOWCAP_ERR_NULL_POINTER).*, (target orelse return shared.GLOWCAP_ERR_NULL_POINTER).*) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

fn active(raw: ?*c.GlowcapLoamCall) !*callbacks.Call {
    const call: *callbacks.Call = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!call.active) return error.WrongPhase;
    return call;
}

/// Borrow Host-owned exporter metadata for a committed live dependent facet.
/// Null means no exporter. The result discloses no target capability and must
/// not be released. Its lifetime belongs to the existing Host session.
pub fn glowcap_loam_call_live_dependent_exporter(raw: ?*c.GlowcapLoamCall, facet: ?*const shared.GlowcapReference, out_session: ?*?*common.host.GlowcapHostSession) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_session orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = null;
    const call = active(raw) catch |err| return common.code(err);
    const session = call.content_call.liveDependentExporter(
        call.host.capabilityFromRaw((facet orelse return shared.GLOWCAP_ERR_NULL_POINTER).id),
    ) catch |err| return common.code(err);
    out.* = if (session) |value| common.host.embedding.sessionHandle(value) else null;
    return shared.GLOWCAP_OK;
}

/// Borrow the exact facet prepared by this call's matching declaration.
/// The callback may save it. Obtaining it declares no reply disclosure.
pub fn glowcap_loam_call_prepared_live_dependent(raw: ?*c.GlowcapLoamCall, source: ?*const shared.GlowcapReference, target: ?*const shared.GlowcapReference, out_reference: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = .{ .id = 0 };
    const call = active(raw) catch |err| return common.code(err);
    const host = call.host;
    const ref = call.content_call.preparedLiveDependent(
        host.capabilityFromRaw((source orelse return shared.GLOWCAP_ERR_NULL_POINTER).id),
        host.capabilityFromRaw((target orelse return shared.GLOWCAP_ERR_NULL_POINTER).id),
    ) catch |err| return common.code(err);
    out.* = .{ .id = ref.raw() };
    return shared.GLOWCAP_OK;
}

/// Compare the committed facet's actual guarded source and target. A false
/// match is descriptive refusal. This cannot construct or disclose authority.
pub fn glowcap_loam_call_matches_live_dependent(raw: ?*c.GlowcapLoamCall, facet: ?*const shared.GlowcapReference, source: ?*const shared.GlowcapReference, target: ?*const shared.GlowcapReference, out_matches: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const out = out_matches orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = 0;
    const call = active(raw) catch |err| return common.code(err);
    const host = call.host;
    out.* = @intFromBool(call.content_call.matchesLiveDependent(
        host.capabilityFromRaw((facet orelse return shared.GLOWCAP_ERR_NULL_POINTER).id),
        host.capabilityFromRaw((source orelse return shared.GLOWCAP_ERR_NULL_POINTER).id),
        host.capabilityFromRaw((target orelse return shared.GLOWCAP_ERR_NULL_POINTER).id),
    ) catch |err| return common.code(err));
    return shared.GLOWCAP_OK;
}
