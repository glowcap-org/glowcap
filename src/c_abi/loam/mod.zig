//! Optional portable Loam projection. Storage execution belongs to companions.
pub const std_options = @import("c_abi_shared").library_options;
const std = @import("std");
const common = @import("common.zig");
const attached = @import("attachment.zig");
const callbacks = @import("callbacks.zig");
const works = @import("work.zig");
const shared = common.shared;
const host = common.host;
const t = @import("types.zig");
pub const GlowcapLoamStore = t.GlowcapLoamStore;
pub const GlowcapLoamAttachment = t.GlowcapLoamAttachment;
pub const GlowcapLoamCall = t.GlowcapLoamCall;
pub const GlowcapLoamReadMethod = t.GlowcapLoamReadMethod;
pub const GlowcapLoamReadInterface = t.GlowcapLoamReadInterface;
pub const glowcap_loam_call_disclose_reads_copying = @import("read_callbacks.zig").glowcap_loam_call_disclose_reads_copying;
pub const glowcap_loam_read_scope_size_bound = @import("read_callbacks.zig").glowcap_loam_read_scope_size_bound;
pub const GlowcapLoamContinuationReservation = t.GlowcapLoamContinuationReservation;
pub const GlowcapLoamPendingContinuation = t.GlowcapLoamPendingContinuation;
pub const GlowcapLoamContinuation = t.GlowcapLoamContinuation;
pub const GlowcapLoamEffectExecution = t.GlowcapLoamEffectExecution;
pub const GlowcapLoamEffectResult = t.GlowcapLoamEffectResult;
pub const GlowcapLoamContinuationBounds = t.GlowcapLoamContinuationBounds;
pub const GlowcapLoamEffectExecutionBounds = t.GlowcapLoamEffectExecutionBounds;
pub const glowcap_loam_call_reserve_continuation_copying = @import("continuations.zig").glowcap_loam_call_reserve_continuation_copying;
pub const glowcap_loam_continuation_reservation_source = @import("continuations.zig").glowcap_loam_continuation_reservation_source;
pub const glowcap_loam_continuation_reservation_target = @import("continuations.zig").glowcap_loam_continuation_reservation_target;
pub const glowcap_loam_pending_continuation_take = @import("continuations.zig").glowcap_loam_pending_continuation_take;
pub const glowcap_loam_pending_continuation_release = @import("continuations.zig").glowcap_loam_pending_continuation_release;
pub const glowcap_loam_continuation_release = @import("continuations.zig").glowcap_loam_continuation_release;
pub const glowcap_loam_continuation_project = @import("continuations.zig").glowcap_loam_continuation_project;
pub const glowcap_loam_continuation_project_reads_copying = @import("read_callbacks.zig").glowcap_loam_continuation_project_reads_copying;
pub const glowcap_loam_continuation_execute_copying = @import("effect_execution.zig").glowcap_loam_continuation_execute_copying;
pub const glowcap_loam_effect_execution_result = @import("effect_execution.zig").glowcap_loam_effect_execution_result;
pub const glowcap_loam_effect_execution_release = @import("effect_execution.zig").glowcap_loam_effect_execution_release;
pub const glowcap_loam_continuation_size_bound = @import("continuation_sizing.zig").glowcap_loam_continuation_size_bound;
pub const glowcap_loam_effect_execution_result_size_bound = @import("continuation_sizing.zig").glowcap_loam_effect_execution_result_size_bound;
pub const GlowcapLoamReferences = t.GlowcapLoamReferences;
pub const GlowcapLoamPageHandle = t.GlowcapLoamPageHandle;
pub const GlowcapLoamGraphSchema = t.GlowcapLoamGraphSchema;
pub const GlowcapLoamGraphVerb = t.GlowcapLoamGraphVerb;
pub const GlowcapLoamGraph = t.GlowcapLoamGraph;
pub const GlowcapLoamPage = t.GlowcapLoamPage;
pub const GlowcapLoamGraphField = t.GlowcapLoamGraphField;
pub const GlowcapLoamPageReplacement = t.GlowcapLoamPageReplacement;
pub const glowcap_loam_call_replace_graph_copying = @import("graph_abi.zig").glowcap_loam_call_replace_graph_copying;
pub const glowcap_loam_call_page_reference = @import("graph_abi.zig").glowcap_loam_call_page_reference;
pub const glowcap_loam_references_save_live_dependent = @import("live_dependent.zig").glowcap_loam_references_save_live_dependent;
pub const glowcap_loam_call_prepared_live_dependent = @import("live_dependent.zig").glowcap_loam_call_prepared_live_dependent;
pub const glowcap_loam_call_matches_live_dependent = @import("live_dependent.zig").glowcap_loam_call_matches_live_dependent;
pub const glowcap_loam_call_live_dependent_exporter = @import("live_dependent.zig").glowcap_loam_call_live_dependent_exporter;
pub const glowcap_loam_call_source = @import("graph_abi.zig").glowcap_loam_call_source;
pub const glowcap_loam_call_retain_prepared_reference = @import("graph_abi.zig").glowcap_loam_call_retain_prepared_reference;
pub const glowcap_loam_call_disclose_page = @import("graph_abi.zig").glowcap_loam_call_disclose_page;
pub const glowcap_loam_references_restore_page = @import("graph_abi.zig").glowcap_loam_references_restore_page;
pub const glowcap_loam_references_restore_page_with_uri = @import("graph_abi.zig").glowcap_loam_references_restore_page_with_uri;
pub const glowcap_loam_references_inspect_page_uri = @import("graph_abi.zig").glowcap_loam_references_inspect_page_uri;
pub const glowcap_loam_call_page_saved_uri = @import("graph_abi.zig").glowcap_loam_call_page_saved_uri;
pub const GlowcapLoamWork = t.GlowcapLoamWork;
pub const GlowcapLoamObject = t.GlowcapLoamObject;
pub const GlowcapLoamSchema = t.GlowcapLoamSchema;
pub const GlowcapLoamStagingBounds = t.GlowcapLoamStagingBounds;
pub const GlowcapLoamValueBounds = t.GlowcapLoamValueBounds;
pub const GlowcapLoamInvocationBounds = t.GlowcapLoamInvocationBounds;
pub const GlowcapLoamLimits = t.GlowcapLoamLimits;
pub const GlowcapLoamBound = t.GlowcapLoamBound;
pub const GlowcapLoamConstraint = t.GlowcapLoamConstraint;
pub const GlowcapLoamKindRule = t.GlowcapLoamKindRule;
pub const GlowcapLoamPolicy = t.GlowcapLoamPolicy;
pub const GlowcapLoamPolicyValue = t.GlowcapLoamPolicyValue;
pub const GlowcapLoamRequirement = t.GlowcapLoamRequirement;
pub const GlowcapLoamResourceId = t.GlowcapLoamResourceId;
pub const GlowcapLoamBoundResource = t.GlowcapLoamBoundResource;
pub const GlowcapLoamInvocation = t.GlowcapLoamInvocation;
pub const GlowcapLoamRequirementFn = t.GlowcapLoamRequirementFn;
pub const GlowcapLoamInvokeFn = t.GlowcapLoamInvokeFn;
pub const GlowcapLoamReferencesFn = t.GlowcapLoamReferencesFn;
pub const GlowcapLoamEntropyFn = t.GlowcapLoamEntropyFn;
pub const GlowcapLoamMethod = t.GlowcapLoamMethod;
pub const GlowcapLoamContent = t.GlowcapLoamContent;
pub const GlowcapLoamResource = t.GlowcapLoamResource;
pub const glowcap_loam_validate_configuration = @import("execution_abi.zig").glowcap_loam_validate_configuration;
pub const glowcap_loam_schema_size_bound = @import("execution_abi.zig").glowcap_loam_schema_size_bound;
pub const glowcap_loam_content_staging_size_bound = @import("staging_sizing.zig").glowcap_loam_content_staging_size_bound;
pub const glowcap_loam_reference_staging_size_bound = @import("staging_sizing.zig").glowcap_loam_reference_staging_size_bound;
pub const glowcap_loam_reference_call_size_bound = @import("reference_callbacks.zig").glowcap_loam_reference_call_size_bound;
pub const glowcap_loam_reference_uri_call_size_bound = @import("reference_callbacks.zig").glowcap_loam_reference_uri_call_size_bound;
pub const glowcap_loam_live_start = @import("live.zig").glowcap_loam_live_start;
pub const glowcap_loam_live_generation = @import("live.zig").glowcap_loam_live_generation;
pub const glowcap_loam_live_marker = @import("live.zig").glowcap_loam_live_marker;
pub const glowcap_loam_graph_call_size_bound = @import("graph_callbacks.zig").glowcap_loam_graph_call_size_bound;
pub const glowcap_loam_invocation_call_size_bound = @import("invocation_sizing.zig").glowcap_loam_invocation_call_size_bound;
pub const glowcap_loam_forwarding_size_bound = @import("invocation_sizing.zig").glowcap_loam_forwarding_size_bound;
pub const GlowcapLoamBytes = @import("execution.zig").GlowcapLoamBytes;
pub const GlowcapLoamKvFn = @import("execution.zig").GlowcapLoamKvFn;
pub const glowcap_loam_metadata_claim = @import("execution_abi.zig").glowcap_loam_metadata_claim;
pub const glowcap_loam_store_plan = @import("execution_abi.zig").glowcap_loam_store_plan;
pub const glowcap_loam_store_finish = @import("execution_abi.zig").glowcap_loam_store_finish;
pub const glowcap_loam_work_kind = @import("execution_abi.zig").glowcap_loam_work_kind;
pub const glowcap_loam_work_plan = @import("execution_abi.zig").glowcap_loam_work_plan;
pub const glowcap_loam_work_finish = @import("execution_abi.zig").glowcap_loam_work_finish;
pub const glowcap_loam_restore_plan = @import("execution_abi.zig").glowcap_loam_restore_plan;
pub const symbols = @import("symbols.zig");
/// Zig-only bridge for a companion. Importing it does not root these exports.
pub const embedding = struct {
    pub const effect_execution = @import("effect_execution.zig");
    pub const graph_projection = @import("graph_callbacks.zig");
    pub const Store = common.Store;
    pub const Attachment = attached.Attachment;
    pub const Work = works.Work;
    pub const store = common.store;
    pub const attachment = attached.attachment;
    pub const work = works.from;
    pub const object = common.object;
    pub const objectToC = common.objectToC;
    pub const policy = common.policy;
    pub const code = common.code;
    pub const slice = common.slice;
};
pub fn glowcap_loam_store_new(metadata: ?[*]const u8, metadata_len: usize, schemas: ?[*]const GlowcapLoamSchema, schema_count: usize, limits: ?*const GlowcapLoamLimits, out_store: ?*?*GlowcapLoamStore) callconv(.c) i32 {
    shared.lastErrorClear();
    return storeNew(common.allocator, metadata, metadata_len, schemas, schema_count, limits, out_store);
}
pub fn glowcap_loam_store_new_in(context: ?*shared.GlowcapContext, metadata: ?[*]const u8, metadata_len: usize, schemas: ?[*]const GlowcapLoamSchema, schema_count: usize, limits: ?*const GlowcapLoamLimits, out_store: ?*?*GlowcapLoamStore) callconv(.c) i32 {
    shared.lastErrorClear();
    const slot = out_store orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    const ctx = shared.ctxFromOpaque(context) orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    return storeNew(ctx.allocator(), metadata, metadata_len, schemas, schema_count, limits, out_store);
}
fn storeNew(gpa: std.mem.Allocator, metadata: ?[*]const u8, metadata_len: usize, schemas: ?[*]const GlowcapLoamSchema, schema_count: usize, limits: ?*const GlowcapLoamLimits, out_store: ?*?*GlowcapLoamStore) i32 {
    const slot = out_store orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    const bounds = limits orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(metadata, metadata_len) catch |err| return common.code(err);
    const declarations = common.slice(GlowcapLoamSchema, schemas, schema_count) catch |err| return common.code(err);
    const meta = common.core.Metadata.decode(bytes) catch |err| return common.code(err);
    const store = common.Store.init(gpa, meta, declarations, bounds.*) catch |err| return common.code(err);
    slot.* = @ptrCast(store);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_store_release(raw: ?*GlowcapLoamStore) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const owner = common.store(raw) catch |err| return common.code(err);
    if (owner.backend_owned) return common.code(error.BackendOwned);
    owner.destroy() catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_attach(raw: ?*GlowcapLoamStore, host_handle: ?*host.GlowcapHost, contents: ?[*]const GlowcapLoamContent, content_count: usize, entropy: ?GlowcapLoamEntropyFn, ctx: ?*anyopaque, out_attachment: ?*?*GlowcapLoamAttachment) callconv(.c) i32 {
    shared.lastErrorClear();
    const slot = out_attachment orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    const store = common.store(raw) catch |err| return common.code(err);
    const declarations = common.slice(GlowcapLoamContent, contents, content_count) catch |err| return common.code(err);
    const entropy_fn = entropy orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const owner = attached.Attachment.create(store, host_handle, declarations, entropy_fn, ctx) catch |err| return common.code(err);
    slot.* = @ptrCast(owner);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_attachment_release(raw: ?*GlowcapLoamAttachment) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const owner = attached.attachment(raw) catch |err| return common.code(err);
    owner.destroy() catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_advance(raw: ?*GlowcapLoamAttachment, out_progress: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = attached.attachment(raw) catch |err| return common.code(err);
    const target = out_progress orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    target.* = if (owner.value.advanceProgress() catch |err| return common.code(err)) 1 else 0;
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_next_work(raw: ?*GlowcapLoamAttachment, recovery: u32, out_work: ?*?*GlowcapLoamWork) callconv(.c) i32 {
    shared.lastErrorClear();
    const slot = out_work orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    if (recovery > 1) return common.code(error.InvalidArgument);
    const owner = attached.attachment(raw) catch |err| return common.code(err);
    const next = works.Work.next(owner, recovery == 1) catch |err| return common.code(err);
    slot.* = if (next) |value| @ptrCast(value) else null;
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_work_complete(raw: ?*GlowcapLoamWork, out_completed: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const target = out_completed orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    target.* = 0;
    const work = works.from(raw) catch |err| return common.code(err);
    defer target.* = @intFromBool(work.completed);
    work.complete() catch |err| return common.code(err);
    if (work.owner.store.value.phase == .uncertain) return GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED;
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_work_release(raw: ?*GlowcapLoamWork) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const work = works.from(raw) catch |err| return common.code(err);
    work.destroy() catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_call_reply(call: ?*GlowcapLoamCall, value: ?*const shared.GlowcapArgument) callconv(.c) i32 {
    shared.lastErrorClear();
    callbacks.reply(call, value) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_call_replace_copying(call: ?*GlowcapLoamCall, bytes: ?[*]const u8, len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    callbacks.replace(call, bytes, len) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_call_disclose(call: ?*GlowcapLoamCall, index: usize, dependent: u32, out_value: ?*shared.GlowcapArgument) callconv(.c) i32 {
    shared.lastErrorClear();
    if (dependent > 1) return common.code(error.InvalidArgument);
    callbacks.disclose(call, index, dependent == 1, out_value) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Declare a saved field to restore before invoking this admitted method.
/// The declaration token borrows only through the references callback.
pub fn glowcap_loam_references_restore(raw: ?*GlowcapLoamReferences, index: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    @import("reference_callbacks.zig").restore(raw, index) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Prepare the exact held capability. A foreign target needs its established
/// sturdy URI; a null URI supports local capture. Copies URI bytes before return.
pub fn glowcap_loam_references_save_copying(raw: ?*GlowcapLoamReferences, reference: ?*const shared.GlowcapReference, uri: ?[*]const u8, uri_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const ref = reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    @import("reference_callbacks.zig").save(raw, ref.*, uri, uri_len) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

/// Declare exact held authority for Host-lifetime storage. Live startup must
/// confirm first; the shared scope reserves custody before preparation waits.
pub fn glowcap_loam_references_save_live(raw: ?*GlowcapLoamReferences, reference: ?*const shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const ref = reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    @import("reference_callbacks.zig").saveLive(raw, ref.*) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Append an exact held reference after the surviving committed fields.
/// Foreign replacements must have been declared during preparation.
pub fn glowcap_loam_call_append_reference(call: ?*GlowcapLoamCall, reference: ?*const shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const ref = reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    callbacks.editReference(call, null, ref.*) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Replace a committed strong field in the payload's transaction. The field
/// index addresses the committed list, independently of other edits.
pub fn glowcap_loam_call_replace_reference(call: ?*GlowcapLoamCall, index: usize, reference: ?*const shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const ref = reference orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    callbacks.editReference(call, index, ref.*) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
/// Release local field custody without revoking its target or publication.
pub fn glowcap_loam_call_remove_reference(call: ?*GlowcapLoamCall, index: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    callbacks.editReference(call, index, null) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_last_error(buf: ?[*]u8, len: usize) callconv(.c) usize {
    return shared.lastErrorRead(buf, len);
}
/// Privileged staging opens one fresh transaction. Names remain provisional
/// until commit; failures discard its staged graph and expose no capability.
pub fn glowcap_loam_resource_stage(raw: ?*GlowcapLoamStore, policy: ?*const GlowcapLoamPolicy, owner_id: ?[*]const u8, kind: u64, schema: u64, version: u32, payload: ?[*]const u8, payload_len: usize, delegation_depth: u16, out_resource: ?*GlowcapLoamResource) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = common.store(raw) catch |err| return common.code(err);
    const declaration = policy orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const identity = owner_id orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const target = out_resource orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const evaluated_policy = common.policy(declaration.*) catch |err| return common.code(err);
    const bytes = shared.sliceFromC(payload, payload_len) catch |err| return common.code(err);
    target.* = @import("creation.zig").stage(owner, evaluated_policy, @fromBackingInt(std.mem.readInt(u128, identity[0..16], .big)), @fromBackingInt(kind), schema, version, bytes, delegation_depth) catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_store_abort(raw: ?*GlowcapLoamStore) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = common.store(raw) catch |err| return common.code(err);
    if (owner.attachments != 0) return common.code(error.Busy);
    owner.value.abort() catch |err| return common.code(err);
    return shared.GLOWCAP_OK;
}

pub const contract_layouts = [_]shared.archive_contract.Layout{
    shared.archive_contract.layout("GLOWCAPLOAMEFFECTRESULT", GlowcapLoamEffectResult),
    shared.archive_contract.layout("GLOWCAPLOAMCONTINUATIONBOUNDS", GlowcapLoamContinuationBounds),
    shared.archive_contract.layout("GLOWCAPLOAMEFFECTEXECUTIONBOUNDS", GlowcapLoamEffectExecutionBounds),
    shared.archive_contract.layout("GLOWCAPLOAMBYTES", GlowcapLoamBytes),
    shared.archive_contract.layout("GLOWCAP_LOAM_POLICY_VALUE", GlowcapLoamPolicyValue),
    shared.archive_contract.layout("GLOWCAPLOAMOBJECT", GlowcapLoamObject),
    shared.archive_contract.layout("GLOWCAPLOAMSCHEMA", GlowcapLoamSchema),
    shared.archive_contract.layout("GLOWCAPLOAMSTAGINGBOUNDS", GlowcapLoamStagingBounds),
    shared.archive_contract.layout("GLOWCAPLOAMVALUEBOUNDS", GlowcapLoamValueBounds),
    shared.archive_contract.layout("GLOWCAPLOAMINVOCATIONBOUNDS", GlowcapLoamInvocationBounds),
    shared.archive_contract.layout("GLOWCAPLOAMLIMITS", GlowcapLoamLimits),
    shared.archive_contract.layout("GLOWCAPLOAMBOUND", GlowcapLoamBound),
    shared.archive_contract.layout("GLOWCAPLOAMCONSTRAINT", GlowcapLoamConstraint),
    shared.archive_contract.layout("GLOWCAPLOAMKINDRULE", GlowcapLoamKindRule),
    shared.archive_contract.layout("GLOWCAPLOAMPOLICY", GlowcapLoamPolicy),
    shared.archive_contract.layout("GLOWCAPLOAMREQUIREMENT", GlowcapLoamRequirement),
    shared.archive_contract.layout("GLOWCAPLOAMRESOURCEID", GlowcapLoamResourceId),
    shared.archive_contract.layout("GLOWCAPLOAMBOUNDRESOURCE", GlowcapLoamBoundResource),
    shared.archive_contract.layout("GLOWCAPLOAMINVOCATION", GlowcapLoamInvocation),
    shared.archive_contract.layout("GLOWCAPLOAMMETHOD", GlowcapLoamMethod),
    shared.archive_contract.layout("GLOWCAPLOAMREADMETHOD", GlowcapLoamReadMethod),
    shared.archive_contract.layout("GLOWCAPLOAMREADINTERFACE", GlowcapLoamReadInterface),
    shared.archive_contract.layout("GLOWCAPLOAMCONTENT", GlowcapLoamContent),
    shared.archive_contract.layout("GLOWCAPLOAMGRAPHSCHEMA", GlowcapLoamGraphSchema),
    shared.archive_contract.layout("GLOWCAPLOAMGRAPHVERB", GlowcapLoamGraphVerb),
    shared.archive_contract.layout("GLOWCAPLOAMGRAPH", GlowcapLoamGraph),
    shared.archive_contract.layout("GLOWCAPLOAMPAGE", GlowcapLoamPage),
    shared.archive_contract.layout("GLOWCAPLOAMGRAPHFIELD", GlowcapLoamGraphField),
    shared.archive_contract.layout("GLOWCAPLOAMPAGEREPLACEMENT", GlowcapLoamPageReplacement),
    shared.archive_contract.layout("GLOWCAPLOAMRESOURCE", GlowcapLoamResource),
};
pub const GLOWCAP_LOAM_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint("glowcap_loam", @This(), .{ &shared.contract_layouts, &contract_layouts });
pub fn glowcap_loam_archive_fingerprint() callconv(.c) u64 {
    return GLOWCAP_LOAM_ARCHIVE_FINGERPRINT;
}

pub const GLOWCAP_LOAM_METADATA_SIZE: usize = common.core.Metadata.encoded_size;
pub const GLOWCAP_LOAM_MAX_URI_BYTES: usize = common.hosting.references.max_uri_bytes;
pub const GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED: i32 = -40;
pub const GLOWCAP_LOAM_ERR_STALE_COMPLETION: i32 = -41;
pub const GLOWCAP_LOAM_ERR_DENIED: i32 = -42;
pub const GLOWCAP_LOAM_ERR_UNCHANGED: i32 = -43;
pub const GLOWCAP_LOAM_ERR_APPLICATION: i32 = -44;
/// Report an indeterminate write only after the original worker has terminated.
/// No other effect can be relabeled as an unknown commit.
pub fn glowcap_loam_work_report_unknown(raw: ?*GlowcapLoamWork) callconv(.c) i32 {
    shared.lastErrorClear();
    const work = works.from(raw) catch |err| return common.code(err);
    if (work.completed or work.request != .write) return common.code(error.StaleCompletion);
    work.result = .{ .write = .unknown };
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_has_pending_work(raw: ?*GlowcapLoamAttachment, out_pending: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = attached.attachment(raw) catch |err| return common.code(err);
    const target = out_pending orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    owner.host_borrow.core().assertOwner();
    target.* = if (owner.value.hasPendingWork()) 1 else 0;
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_policy_value(policy: ?*const GlowcapLoamPolicy, requirement: ?*const GlowcapLoamRequirement, out_value: ?*GlowcapLoamPolicyValue) callconv(.c) i32 {
    return policyValue(policy, requirement, out_value, null);
}
/// Construct terms supported by one declared exact interface. Kind is schema
/// data; this check supplies no authority or reusable admission for an effect.
pub fn glowcap_loam_policy_value_for_kind(policy: ?*const GlowcapLoamPolicy, kind: u64, requirement: ?*const GlowcapLoamRequirement, out_value: ?*GlowcapLoamPolicyValue) callconv(.c) i32 {
    return policyValue(policy, requirement, out_value, kind);
}
fn policyValue(policy: ?*const GlowcapLoamPolicy, requirement: ?*const GlowcapLoamRequirement, out_value: ?*GlowcapLoamPolicyValue, kind: ?u64) i32 {
    shared.lastErrorClear();
    const schema = policy orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const input = requirement orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const target = out_value orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (input.permission_count > 64 or input.fact_count > 16) return common.code(error.PolicyLimit);
    const evaluated_policy = common.policy(schema.*) catch |err| return common.code(err);
    var keys: [64]common.access.core.Policy.Key = undefined;
    var bounds: [16]common.access.core.Policy.Bound = undefined;
    for (input.permissions[0..input.permission_count], 0..) |key, i| keys[i] = @fromBackingInt(key);
    for (input.facts[0..input.fact_count], 0..) |bound, i| bounds[i] = .{ .key = @fromBackingInt(bound.key), .value = bound.value };
    const value = (if (kind) |id| evaluated_policy.valueForKind(@fromBackingInt(id), keys[0..input.permission_count], bounds[0..input.fact_count]) else evaluated_policy.value(keys[0..input.permission_count], bounds[0..input.fact_count])) catch |err| return common.code(err);
    var result: GlowcapLoamPolicyValue = std.mem.zeroes(GlowcapLoamPolicyValue);
    result.identity = schema.identity;
    result.permissions = value.permissions;
    for (value.bounds, 0..) |bound, i| if (bound) |limit| {
        result.bounds[i] = limit;
        result.bound_mask |= @as(u16, 1) << @intCast(i);
    };
    target.* = result;
    return shared.GLOWCAP_OK;
}

/// Only an executor that proved the worker never ran may report this outcome.
pub fn glowcap_loam_work_report_unstarted(raw: ?*GlowcapLoamWork) callconv(.c) i32 {
    shared.lastErrorClear();
    const work = works.from(raw) catch |err| return common.code(err);
    if (work.completed or work.result != null) return common.code(error.StaleCompletion);
    work.result = switch (work.request) {
        .read => .{ .read = .{ .failed = error.StorageFailure } },
        .write => .{ .write = .{ .unchanged = error.WriteNotCommitted } },
        .lookup => .{ .lookup = .{ .failed = error.StorageFailure } },
        .recover => .{ .failed = error.RecoveryRequired },
    };
    return shared.GLOWCAP_OK;
}

pub fn glowcap_loam_clear_last_error() callconv(.c) void {
    shared.lastErrorClear();
}
