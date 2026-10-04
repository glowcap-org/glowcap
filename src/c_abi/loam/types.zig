//! Layouts shared by the portable Loam archive and its storage companion.
const shared = @import("c_abi_shared");
pub const GlowcapLoamStore = opaque {};
pub const GlowcapLoamAttachment = opaque {};
pub const GlowcapLoamCall = opaque {};
pub const GlowcapLoamReferences = opaque {};
pub const GlowcapLoamWork = opaque {};
pub const GlowcapLoamObject = extern struct { key: [33]u8 };
pub const GlowcapLoamSchema = extern struct { id: u64, version: u32, max_payload: usize, max_edges: usize };
pub const GlowcapLoamLimits = extern struct {
    resident_bytes: usize,
    staging_bytes: usize,
    cache_slots: usize,
    max_leases: usize,
    max_changes: usize,
    max_references: usize,
    max_operations: usize,
};
pub const GlowcapLoamBound = extern struct { key: u64, value: u64 };
pub const GlowcapLoamConstraint = extern struct { key: u64, operator: u32 };
pub const GlowcapLoamPolicy = extern struct {
    identity: [16]u8,
    permissions: [64]u64,
    constraints: [16]GlowcapLoamConstraint,
    permission_count: usize,
    constraint_count: usize,
    prerequisite_masks: [64]u64 = @splat(0),
};
pub const GlowcapLoamRequirement = extern struct {
    permissions: [64]u64,
    facts: [16]GlowcapLoamBound,
    permission_count: usize,
    fact_count: usize,
};
pub const GlowcapLoamInvocation = extern struct {
    payload: ?[*]const u8,
    payload_len: usize,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    field_count: usize,
};
pub const GlowcapLoamRequirementFn = *const fn (?*anyopaque, *const GlowcapLoamInvocation, *GlowcapLoamRequirement) callconv(.c) i32;
pub const GlowcapLoamInvokeFn = *const fn (?*anyopaque, *GlowcapLoamCall, *const GlowcapLoamInvocation) callconv(.c) i32;
pub const GlowcapLoamReferencesFn = *const fn (?*anyopaque, *GlowcapLoamReferences, *const GlowcapLoamInvocation) callconv(.c) i32;
pub const GlowcapLoamEntropyFn = *const fn (?*anyopaque, [*]u8, usize) callconv(.c) i32;
pub const GlowcapLoamMethod = extern struct { verb: ?[*]const u8, verb_len: usize, retry: u32 };
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
};
pub const GlowcapLoamResource = extern struct { owner: GlowcapLoamObject, use: GlowcapLoamObject, control: GlowcapLoamObject };
pub const GlowcapLoamPolicyValue = extern struct { identity: [16]u8, permissions: u64, bounds: [16]u64, bound_mask: u16 };
