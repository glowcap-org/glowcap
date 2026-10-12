//! Layouts shared by the portable Loam archive and its storage companion.
const shared = @import("c_abi_shared");
pub const GlowcapLoamStore = opaque {};
pub const GlowcapLoamAttachment = opaque {};
pub const GlowcapLoamCall = opaque {};
pub const GlowcapLoamReferences = opaque {};
pub const GlowcapLoamPageHandle = opaque {};
pub const GlowcapLoamWork = opaque {};
pub const GlowcapLoamContinuationReservation = opaque {};
pub const GlowcapLoamPendingContinuation = opaque {};
pub const GlowcapLoamContinuation = opaque {};
pub const GlowcapLoamEffectExecution = opaque {};
/// State zero waits, one owns a projected result, two proves no target
/// admission, three leaves application outcome unresolved. Projection failure
/// is an ordinary return-code refusal and does not change this outcome.
pub const GlowcapLoamEffectResult = extern struct {
    state: u32,
    result: i32,
    value: shared.GlowcapArgument,
    message: ?[*]const u8,
    message_len: usize,
};
pub const GlowcapLoamObject = extern struct { key: [33]u8 };
pub const GlowcapLoamSchema = extern struct { id: u64, version: u32, max_payload: usize, max_edges: usize };
/// Retained encoded proposals. Temporary encoding and backend metadata are
/// separate. record_bytes is the largest contributing complete record.
pub const GlowcapLoamStagingBounds = extern struct { changes: usize, staging_bytes: usize, record_bytes: usize };
/// Scalar topology, with roots and every descendant counted in values. Keys
/// count separately. Bytes includes all copied leaf occurrences. Capabilities
/// counts occurrences rather than distinct identities.
pub const GlowcapLoamValueBounds = extern struct { values: usize, struct_entries: usize, bytes: usize, capabilities: usize };
pub const GlowcapLoamContinuationBounds = extern struct { custody_bytes: usize, observer_bytes: usize, call_bytes: usize };
pub const GlowcapLoamEffectExecutionBounds = extern struct { caller_bytes: usize, host_dispatch_bytes: usize };
pub const GlowcapLoamInvocationBounds = extern struct {
    arguments: GlowcapLoamValueBounds,
    reply: GlowcapLoamValueBounds,
    verb_bytes: usize,
    held_occurrences: usize,
    receipt: u32,
    dependent: u32,
};
pub const GlowcapLoamLimits = extern struct {
    resident_bytes: usize,
    staging_bytes: usize,
    cache_slots: usize,
    max_leases: usize,
    max_changes: usize,
    /// Live attachment endpoints. Independent of Store retention tokens.
    max_references: usize,
    max_operations: usize,
    call_bytes: usize = 64 * 1024,
    pending_bytes: usize = 4 * 1024 * 1024,
    ingress_bytes: usize = 1024 * 1024,
    /// Pinned managed records per operation. Directory faults borrow another
    /// lease, and the capability descriptor borrows one more.
    record_capacity: usize = 8,
    /// Live save proofs in this attachment, including completed call-owned
    /// proofs retained through transaction outcome.
    max_reference_saves: usize = 64,
    /// Maximum encoded physical record, including its envelope and checksum.
    record_bytes: usize = 64 * 1024,
    /// Live Store roots, including restored recipes held through settlement.
    max_retentions: usize = 128,
    /// Live receipt continuations, independent of pending call admission.
    max_continuations: usize = 64,
    /// Complete immutable intent and exact-target custody per continuation.
    continuation_bytes: usize = 64 * 1024,
    max_continuation_targets: usize = 32,
    /// Fixed owning reply allowance for each forwarded target execution.
    forward_reply_bytes: usize = 16 * 1024,
};
pub const GlowcapLoamBound = extern struct { key: u64, value: u64 };
pub const GlowcapLoamConstraint = extern struct { key: u64, operator: u32 };
pub const GlowcapLoamKindRule = extern struct { kind: u64, permissions: u64, subtree_permissions: u64 };
pub const GlowcapLoamPolicy = extern struct {
    identity: [16]u8,
    permissions: [64]u64,
    constraints: [16]GlowcapLoamConstraint,
    permission_count: usize,
    constraint_count: usize,
    prerequisite_masks: [64]u64 = @splat(0),
    kind_rules: [16]GlowcapLoamKindRule = undefined,
    kind_count: usize = 0,
};
pub const GlowcapLoamRequirement = extern struct {
    permissions: [64]u64,
    facts: [16]GlowcapLoamBound,
    permission_count: usize,
    fact_count: usize,
};
pub const GlowcapLoamResourceId = extern struct { owner: [16]u8, slot: u32, generation: u64 };
/// Descriptive current resource data. The revision covers the owner's resource
/// graph. None of these names supplies a capability or reusable admission.
pub const GlowcapLoamBoundResource = extern struct { id: GlowcapLoamResourceId, kind: u64, object: GlowcapLoamObject, revision: u64 };
pub const GlowcapLoamGraphSchema = extern struct { id: u64, version: u32 };
/// One registered source method whose forwarded requirement reads current
/// scalar graph pages. Attachment creation copies at most 128 nonempty names,
/// each at most 256 bytes. Callbacks borrow pages and restore no fields.
pub const GlowcapLoamGraphVerb = extern struct { verb: ?[*]const u8, verb_len: usize };
pub const GlowcapLoamGraph = extern struct {
    schemas: ?[*]const GlowcapLoamGraphSchema,
    schema_count: usize,
    max_pages: usize,
    max_payload_bytes: usize,
    max_edges: usize,
    requirement_verbs: ?[*]const GlowcapLoamGraphVerb = null,
    requirement_verb_count: usize = 0,
};
pub const GlowcapLoamPage = extern struct {
    handle: *const GlowcapLoamPageHandle,
    schema: u64,
    version: u32,
    payload: ?[*]const u8,
    payload_len: usize,
    field_count: usize,
};
/// Null page selects a held reference and requires index zero. Non-null page
/// selects its exact committed field and requires reference zero. Field zero
/// excludes the reserved resource binding. Tokens borrow the active callback.
pub const GlowcapLoamGraphField = extern struct {
    page: ?*const GlowcapLoamPageHandle,
    index: usize,
    reference: shared.GlowcapReference,
};
pub const GlowcapLoamPageReplacement = extern struct {
    /// Non-null selects this preparation's exact page. A non-null payload
    /// replaces only its bytes. Null preserves them. The schema and fields stay zero.
    keep: ?*const GlowcapLoamPageHandle,
    schema: u64,
    version: u32,
    payload: ?[*]const u8,
    payload_len: usize,
    fields: ?[*]const GlowcapLoamGraphField,
    field_count: usize,
};
pub const GlowcapLoamInvocation = extern struct {
    bound_resource: GlowcapLoamBoundResource,
    /// Zero executes the selected local target. One mediates forwarding and
    /// describes only its source. Forwarded target metadata is not asserted.
    delivery: u32,
    content: GlowcapLoamObject,
    content_revision: u64,
    payload: ?[*]const u8,
    payload_len: usize,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    field_count: usize,
    /// Root links are owned pages, never application capability fields.
    /// Pages are available only after admission and complete preparation.
    graph_prepared: u32 = 0,
    pages: ?[*]const GlowcapLoamPage = null,
    page_count: usize = 0,
};
pub const GlowcapLoamRequirementFn = *const fn (?*anyopaque, *const GlowcapLoamInvocation, *GlowcapLoamRequirement) callconv(.c) i32;
pub const GlowcapLoamInvokeFn = *const fn (?*anyopaque, *GlowcapLoamCall, *const GlowcapLoamInvocation) callconv(.c) i32;
pub const GlowcapLoamForwardFn = *const fn (?*anyopaque, *GlowcapLoamCall, [*]const u8, usize, [*]const u8, usize, usize) callconv(.c) i32;
pub const GlowcapLoamReferencesFn = *const fn (?*anyopaque, *GlowcapLoamReferences, *const GlowcapLoamInvocation) callconv(.c) i32;
pub const GlowcapLoamEntropyFn = *const fn (?*anyopaque, [*]u8, usize) callconv(.c) i32;
pub const GlowcapLoamMethod = extern struct { verb: ?[*]const u8, verb_len: usize, retry: u32 };
pub const GlowcapLoamReadMethod = extern struct { verb: ?[*]const u8, verb_len: usize, results: ?[*]const usize, result_count: usize };
pub const GlowcapLoamReadInterface = extern struct { methods: ?[*]const GlowcapLoamReadMethod, method_count: usize };
pub const GlowcapLoamContent = extern struct {
    schema: u64,
    version: u32,
    context: ?*anyopaque,
    methods: ?[*]const GlowcapLoamMethod,
    method_count: usize,
    requirement: ?GlowcapLoamRequirementFn,
    invoke: ?GlowcapLoamInvokeFn,
    references: ?GlowcapLoamReferencesFn = null,
    dependent_requirement: ?GlowcapLoamRequirementFn = null,
    graph: ?*const GlowcapLoamGraph = null,
    admit_forward: ?GlowcapLoamForwardFn = null,
};
pub const GlowcapLoamResource = extern struct { owner: GlowcapLoamObject, use: GlowcapLoamObject, control: GlowcapLoamObject };
pub const GlowcapLoamPolicyValue = extern struct { identity: [16]u8, permissions: u64, bounds: [16]u64, bound_mask: u16 };
