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

pub const Store = struct {
    allocator: std.mem.Allocator,
    value: core.Store,
    schemas: []core.Schema,
    limits: c.GlowcapLoamLimits,
    attachments: usize = 0,
    backend_owned: bool = false,
    startup_batch: ?core.Batch = null,
    startup_result: ?core.Resolution = null,
    /// Validate foreign configuration before a storage open has durable effects.
    /// The core checks schema and cache laws; this profile only bounds its ABI.
    pub fn validateConfiguration(schemas: []const c.GlowcapLoamSchema, limits: c.GlowcapLoamLimits) !void {
        if (schemas.len == 0 or schemas.len > 128 or limits.max_references == 0 or limits.max_operations == 0) return error.InvalidLimits;
        _ = try std.math.add(usize, limits.cache_slots, 1);
        var declarations: [128 + access.records.profile.schemas.len + 2]core.Schema = undefined;
        const configured = declarations[0 .. schemas.len + access.records.profile.schemas.len + 2];
        populateSchemas(schemas, configured);
        try core.Store.validateConfiguration(configured, coreLimits(limits));
    }
    fn populateSchemas(schemas: []const c.GlowcapLoamSchema, declarations: []core.Schema) void {
        @memcpy(declarations[0..access.records.profile.schemas.len], &access.records.profile.schemas);
        declarations[access.records.profile.schemas.len] = hosting.publication.schema;
        declarations[access.records.profile.schemas.len + 1] = hosting.references.schema;
        for (schemas, declarations[access.records.profile.schemas.len + 2 ..]) |schema, *target| target.* = .{ .id = schema.id, .version = schema.version, .max_payload = schema.max_payload, .max_edges = schema.max_edges };
    }
    fn coreLimits(limits: c.GlowcapLoamLimits) core.Store.Limits {
        return .{ .records = .{ .max_record_bytes = 64 * 1024, .max_edges = max_content_fields }, .resident_bytes = limits.resident_bytes, .staging_bytes = limits.staging_bytes, .cache_slots = limits.cache_slots, .max_leases = limits.max_leases, .max_changes = limits.max_changes, .max_retentions = limits.max_references };
    }
    pub fn init(gpa: std.mem.Allocator, metadata: core.Metadata, schemas: []const c.GlowcapLoamSchema, limits: c.GlowcapLoamLimits) !*Store {
        try validateConfiguration(schemas, limits);
        const declarations = try gpa.alloc(core.Schema, schemas.len + access.records.profile.schemas.len + 2);
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
    return @ptrCast(@alignCast(raw orelse return error.NullPointer));
}
pub fn object(raw: c.GlowcapLoamObject) !core.ObjectId {
    return core.ObjectId.fromKey(&raw.key);
}
pub fn objectToC(id: core.ObjectId) c.GlowcapLoamObject {
    return .{ .key = id.key() };
}
pub fn code(err: anyerror) i32 {
    shared.setLastError("loam: {s}", .{@errorName(err)});
    return switch (err) {
        error.NullPointer => shared.GLOWCAP_ERR_NULL_POINTER,
        error.Busy, error.RecordUnloaded, error.PendingRead => shared.GLOWCAP_ERR_WOULD_BLOCK,
        error.OutOfMemory => shared.GLOWCAP_ERR_INTERNAL,
        error.StorageFailure => shared.GLOWCAP_ERR_IO,
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
    if (raw.permission_count > P.max_permissions or raw.constraint_count > P.max_constraints) return error.PolicyLimit;
    var permissions: [P.max_permissions]P.Key = undefined;
    var constraints: [P.max_constraints]P.Constraint = undefined;
    for (raw.permissions[0..raw.permission_count], 0..) |key, i| permissions[i] = @fromBackingInt(key);
    for (raw.constraints[0..raw.constraint_count], 0..) |item, i| constraints[i] = .{ .key = @fromBackingInt(item.key), .operator = switch (item.operator) {
        0 => .lower_bound,
        1 => .upper_bound,
        else => return error.InvalidArgument,
    } };
    return (try P.init(.{ .id = @fromBackingInt(std.mem.readInt(u128, &raw.identity, .big)), .permissions = permissions[0..raw.permission_count], .constraints = constraints[0..raw.constraint_count] })).withPrerequisiteMasks(raw.prerequisite_masks);
}

pub fn slice(comptime T: type, ptr: ?[*]const T, len: usize) ![]const T {
    if (len == 0) return &.{};
    return (ptr orelse return error.NullPointer)[0..len];
}
