//! Stable owners and refusal projection for the Loam C boundary.
const std = @import("std");
pub const core = @import("loam_core");
pub const access = @import("loam_access");
pub const hosting = @import("loam_hosting");
pub const driver = @import("driver_core");
pub const shared = @import("c_abi_shared");
pub const host = @import("c_abi_host");
pub const c = @import("types.zig");
pub const allocator = shared.library_allocator;
pub const max_content_fields = 514;
pub const max_schemas = 128;

pub const Store = struct {
    allocator: std.mem.Allocator,
    value: core.Store,
    schemas: []core.Schema,
    limits: c.GlowcapLoamLimits,
    attachments: usize = 0,
    backend_owned: bool = false,
    /// The most storage works holding a read transaction at once. An engine
    /// companion sets its engine's `readerCapacity`, and storage the
    /// embedding supplies admits any number.
    readers: usize = std.math.maxInt(usize),
    /// A store-level batch is a startup commit, a recovery, or a collection step.
    store_batch: ?core.Batch = null,
    store_evaluation: ?core.Batch.Evaluation = null,
    store_result: ?core.Resolution = null,
    /// Validate foreign configuration before a storage open has durable effects.
    /// The core checks schema and cache laws. This profile only bounds its ABI.
    pub fn validateConfiguration(schemas: []const c.GlowcapLoamSchema, limits: c.GlowcapLoamLimits) !void {
        if (schemas.len == 0 or schemas.len > max_schemas or limits.max_retentions == 0) return error.InvalidLimits;
        try hostingOptions(limits).validate(0);
        if (limits.record_capacity == 0 or limits.record_capacity > limits.max_leases -| 2 or limits.max_reference_saves == 0) return error.InvalidLimits;
        _ = try std.math.add(usize, limits.cache_slots, 1);
        var declarations: [128 + access.hosting.system_schemas.len]core.Schema = undefined;
        const configured = declarations[0 .. schemas.len + access.hosting.system_schemas.len];
        populateSchemas(schemas, configured);
        try core.Store.validateConfiguration(configured, coreLimits(limits));
    }
    fn populateSchemas(schemas: []const c.GlowcapLoamSchema, declarations: []core.Schema) void {
        @memcpy(declarations[0..access.hosting.system_schemas.len], &access.hosting.system_schemas);
        for (schemas, declarations[access.hosting.system_schemas.len..]) |schema, *target| target.* = .{ .id = schema.id, .version = schema.version, .max_payload = schema.max_payload, .max_edges = schema.max_edges };
    }
    fn coreLimits(limits: c.GlowcapLoamLimits) core.Store.Limits {
        return .{ .records = .{ .max_record_bytes = limits.record_bytes, .max_edges = max_content_fields }, .resident_bytes = limits.resident_bytes, .staging_bytes = limits.staging_bytes, .cache_slots = limits.cache_slots, .read_ahead = limits.read_ahead, .max_leases = limits.max_leases, .max_changes = limits.max_changes, .max_retentions = limits.max_retentions };
    }
    /// One projection owns every portable attachment limit. The same options
    /// validate before storage opens and configure the eventual Host attachment.
    pub fn hostingOptions(limits: c.GlowcapLoamLimits) hosting.Options {
        return .{ .max_endpoints = limits.max_references, .max_calls = limits.max_operations, .call_bytes = limits.call_bytes, .pending_bytes = limits.pending_bytes, .ingress_bytes = limits.ingress_bytes, .max_reference_saves = limits.max_reference_saves, .max_continuations = limits.max_continuations, .continuation_bytes = limits.continuation_bytes, .max_continuation_targets = limits.max_continuation_targets, .forward_reply_bytes = limits.forward_reply_bytes };
    }
    pub fn init(gpa: std.mem.Allocator, metadata: core.Metadata, schemas: []const c.GlowcapLoamSchema, limits: c.GlowcapLoamLimits) !*Store {
        try validateConfiguration(schemas, limits);
        const declarations = try gpa.alloc(core.Schema, schemas.len + access.hosting.system_schemas.len);
        errdefer gpa.free(declarations);
        populateSchemas(schemas, declarations);
        const owner = try gpa.create(Store);
        errdefer gpa.destroy(owner);
        const value = try core.Store.init(gpa, metadata, declarations, coreLimits(limits));
        owner.* = .{ .allocator = gpa, .value = value, .schemas = declarations, .limits = limits };
        return owner;
    }
    pub fn destroy(self: *Store) !void {
        const gpa = self.allocator;
        if (self.attachments != 0) return error.Busy;
        if (self.value.phase == .uncertain) return error.RecoveryRequired;
        try self.value.deinit();
        gpa.free(self.schemas);
        gpa.destroy(self);
    }
};
pub fn store(raw: ?*c.GlowcapLoamStore) !*Store {
    const owner: *Store = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    try EvaluationGuard.check(owner);
    return owner;
}

threadlocal var active_evaluation: ?*EvaluationGuard = null;

/// Only the synchronous callback stack owns reentry state. Independent workers
/// and Host progress share no guard bytes. Each submitted Work still has one
/// executor. Finish, complete and release require that executor to have joined.
/// Stable local frames support nested different-Store calls without allocation.
pub const EvaluationGuard = struct {
    owner: *Store = undefined,
    prior: ?*EvaluationGuard = null,

    pub fn check(owner: *Store) !void {
        var frame = active_evaluation;
        while (frame) |current| : (frame = current.prior) {
            if (current.owner == owner) return error.ReentrantCall;
        }
    }
    pub fn enter(self: *EvaluationGuard, owner: *Store) !void {
        try check(owner);
        self.* = .{ .owner = owner, .prior = active_evaluation };
        active_evaluation = self;
    }
    pub fn leave(self: *EvaluationGuard) void {
        std.debug.assert(active_evaluation == self);
        active_evaluation = self.prior;
    }
};
/// A caller's object handle. A malformed one is the caller's argument, not
/// damaged storage, so it never reports `Corrupt`.
pub fn object(raw: c.GlowcapLoamObject) !core.ObjectId {
    return core.ObjectId.fromKey(&raw.key) catch error.InvalidArgument;
}
pub fn objectToC(id: core.ObjectId) c.GlowcapLoamObject {
    return .{ .key = id.key() };
}
pub fn code(err: anyerror) i32 {
    shared.setLastError("loam: {s}", .{@errorName(err)});
    return switch (err) {
        error.NullPointer => shared.GLOWCAP_ERR_NULL_POINTER,
        error.Busy, error.CustodyUnavailable, error.RecordUnloaded, error.PendingRead, error.ReaderCapacity, error.StartupPending => shared.GLOWCAP_ERR_WOULD_BLOCK,
        error.OutOfMemory => shared.GLOWCAP_ERR_INTERNAL,
        // The engine stopped admitting work, so close and reopen it.
        error.StorageFailure, error.OpenOutcomeUnknown, error.ReopenRequired, error.Closed => shared.GLOWCAP_ERR_IO,
        error.Corrupt => @import("mod.zig").GLOWCAP_LOAM_ERR_CORRUPT,
        error.Gone, error.MissingStore, error.FileNotFound => shared.GLOWCAP_ERR_NOT_FOUND,
        error.RecoveryRequired, error.OutcomeUnknown => @import("mod.zig").GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED,
        error.StaleCompletion, error.WorkerNotRetired => @import("mod.zig").GLOWCAP_LOAM_ERR_STALE_COMPLETION,
        error.Denied, error.Paused, error.Revoked, error.OutOfScope, error.CeilingExceeded, error.DelegationDenied => @import("mod.zig").GLOWCAP_LOAM_ERR_DENIED,
        error.WriteNotCommitted => @import("mod.zig").GLOWCAP_LOAM_ERR_UNCHANGED,
        error.ApplicationRefused, error.MissingReply => @import("mod.zig").GLOWCAP_LOAM_ERR_APPLICATION,
        else => shared.GLOWCAP_ERR_INVALID_ARGUMENT,
    };
}
pub fn policy(raw: c.GlowcapLoamPolicy) !access.core.Policy {
    const P = access.core.Policy;
    if (raw.permission_count > P.max_permissions or raw.constraint_count > P.max_constraints or raw.kind_count > P.max_kinds) return error.PolicyLimit;
    var permissions: [P.max_permissions]P.Key = undefined;
    var constraints: [P.max_constraints]P.Constraint = undefined;
    for (raw.permissions[0..raw.permission_count], 0..) |key, i| permissions[i] = @fromBackingInt(key);
    for (raw.constraints[0..raw.constraint_count], 0..) |item, i| constraints[i] = .{ .key = @fromBackingInt(item.key), .operator = switch (item.operator) {
        0 => .lower_bound,
        1 => .upper_bound,
        else => return error.InvalidArgument,
    } };
    var kinds: [P.max_kinds]P.KindRule = undefined;
    for (raw.kind_rules[0..raw.kind_count], kinds[0..raw.kind_count]) |source, *target| target.* = .{ .kind = @fromBackingInt(source.kind), .permissions = source.permissions, .subtree_permissions = source.subtree_permissions };
    var result = try P.init(.{ .id = @fromBackingInt(std.mem.readInt(u128, &raw.identity, .big)), .permissions = permissions[0..raw.permission_count], .constraints = constraints[0..raw.constraint_count] });
    try result.setPrerequisiteMasks(&raw.prerequisite_masks);
    try result.setKinds(kinds[0..raw.kind_count]);
    return result;
}

pub const slice = shared.itemsFromC;
