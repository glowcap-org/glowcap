//! Runtime policy vocabulary shared by Zig and foreign consumers.
//! Stable keys name Boolean permissions and unsigned lower or upper bounds.
//! Applications supply operation requirements and committed facts; this module
//! owns their set and bound algebra. It performs no allocation or callbacks.

const std = @import("std");

pub const Policy = struct {
    id: Id,
    permission_keys: [max_permissions]Key,
    constraint_fields: [max_constraints]Constraint,
    permission_count: usize,
    constraint_count: usize,
    /// Required bits use permission_keys' stable ordering. The 512 inline bytes
    /// keep declaration ownership with the copied policy across cold reads and
    /// foreign calls; no retained borrow, callback or heap allocation is needed.
    prerequisite_masks: [max_permissions]u64 = @splat(0),

    pub const Id = enum(u128) { _ };
    pub const Key = enum(u64) { _ };
    pub const max_permissions = 64;
    pub const max_constraints = 16;
    pub const Operator = enum { lower_bound, upper_bound };
    pub const Constraint = struct { key: Key, operator: Operator };
    pub const Bound = struct { key: Key, value: u64 };
    pub const Dependency = struct { permission: Key, required: Key };
    pub const Descriptor = struct {
        /// A schema identity fixes key meanings, ordering, operators and dependencies.
        id: Id,
        permissions: []const Key,
        constraints: []const Constraint = &.{},
        dependencies: []const Dependency = &.{},
    };
    pub const Value = struct {
        schema: Id,
        /// Bits refer to this schema's sorted permission declarations.
        permissions: u64,
        /// Null means unrestricted; unused schema slots must remain null.
        bounds: [max_constraints]?u64,
    };
    pub const Requirement = struct {
        permissions: []const Key,
        /// Only bounds relevant to this effect are requested. The application
        /// must include all relevant facts from its committed content state.
        facts: []const Bound = &.{},
    };
    pub const Error = error{
        PolicyLimit,
        NonCanonicalSchema,
        DuplicateKey,
        UnknownPermission,
        UnknownConstraint,
        WrongSchema,
        MissingPrerequisite,
        InvalidDependency,
    };

    /// Copies a bounded, strictly key-sorted descriptor into an immutable value.
    /// Reusing an identity for a different vocabulary is not schema evolution.
    pub fn init(descriptor: Descriptor) Error!Policy {
        if (descriptor.permissions.len > max_permissions or descriptor.constraints.len > max_constraints or descriptor.dependencies.len > max_permissions * max_permissions) return error.PolicyLimit;
        for (descriptor.permissions, 0..) |key, i| {
            if (i != 0 and @backingInt(descriptor.permissions[i - 1]) >= @backingInt(key)) return error.NonCanonicalSchema;
        }
        for (descriptor.constraints, 0..) |field, i| {
            if (i != 0 and @backingInt(descriptor.constraints[i - 1].key) >= @backingInt(field.key)) return error.NonCanonicalSchema;
        }
        var self: Policy = .{
            .id = descriptor.id,
            .permission_keys = undefined,
            .constraint_fields = undefined,
            .permission_count = descriptor.permissions.len,
            .constraint_count = descriptor.constraints.len,
        };
        @memcpy(self.permission_keys[0..self.permission_count], descriptor.permissions);
        @memcpy(self.constraint_fields[0..self.constraint_count], descriptor.constraints);
        for (descriptor.dependencies) |dependency| {
            const index = try self.permissionIndex(dependency.permission);
            const required = try self.permissionIndex(dependency.required);
            if (index == required) return error.InvalidDependency;
            const bit = @as(u64, 1) << @intCast(required);
            if (self.prerequisite_masks[index] & bit != 0) return error.DuplicateKey;
            self.prerequisite_masks[index] |= bit;
        }
        return self;
    }

    /// Decode the persisted/ABI matrix after constructing its vocabulary.
    /// This copies no borrowed pointer and validates every matrix position.
    pub fn withPrerequisiteMasks(self: Policy, masks: [max_permissions]u64) Error!Policy {
        const declared = self.declaredMask();
        for (masks, 0..) |required, index| {
            if (index >= self.permission_count) {
                if (required != 0) return error.UnknownPermission;
            } else {
                if (required & ~declared != 0) return error.UnknownPermission;
                if (required & (@as(u64, 1) << @intCast(index)) != 0) return error.InvalidDependency;
            }
        }
        var result = self;
        result.prerequisite_masks = masks;
        return result;
    }

    /// Constructs explicit policy terms from declared keys. Inputs are borrowed
    /// for this call; no pointer into them is retained.
    pub fn value(self: *const Policy, permissions: []const Key, bounds: []const Bound) Error!Value {
        const result = try self.shape(permissions, bounds);
        try self.validate(result);
        return result;
    }

    /// Effects request individual permissions; they are not candidate terms.
    fn shape(self: *const Policy, permissions: []const Key, bounds: []const Bound) Error!Value {
        var result: Value = .{ .schema = self.id, .permissions = try self.permissionMask(permissions), .bounds = undefined };
        @memset(&result.bounds, null);
        if (bounds.len > max_constraints) return error.PolicyLimit;
        for (bounds) |bound| {
            const index = try self.constraintIndex(bound.key);
            if (result.bounds[index] != null) return error.DuplicateKey;
            result.bounds[index] = bound.value;
        }
        return result;
    }

    pub fn validate(self: *const Policy, terms: Value) Error!void {
        if (terms.schema != self.id) return error.WrongSchema;
        const mask = self.declaredMask();
        if (terms.permissions & ~mask != 0) return error.UnknownPermission;
        for (terms.bounds[self.constraint_count..]) |bound| if (bound != null) return error.UnknownConstraint;
        var selected = terms.permissions;
        while (selected != 0) {
            const index = @ctz(selected);
            if (self.prerequisite_masks[index] & ~terms.permissions != 0) return error.MissingPrerequisite;
            selected &= selected - 1;
        }
    }

    pub fn isSubsetOf(self: *const Policy, child: Value, parent: Value) Error!bool {
        try self.validate(child);
        try self.validate(parent);
        if (child.permissions & ~parent.permissions != 0) return false;
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (parent.bounds[i]) |limit| {
                const selected = child.bounds[i] orelse return false;
                if (!satisfies(field.operator, selected, limit)) return false;
            }
        }
        return true;
    }

    /// Computes the stricter permission set and each declared ordered bound.
    pub fn intersect(self: *const Policy, a: Value, b: Value) Error!Value {
        try self.validate(a);
        try self.validate(b);
        var result = a;
        result.permissions &= b.permissions;
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (b.bounds[i]) |limit| {
                result.bounds[i] = if (a.bounds[i]) |other| switch (field.operator) {
                    .lower_bound => @max(other, limit),
                    .upper_bound => @min(other, limit),
                } else limit;
            }
        }
        return result;
    }

    /// Checks one application's declared effect. Unknown keys and duplicate
    /// facts refuse even if an earlier permission or fact already denies it.
    pub fn allows(self: *const Policy, terms: Value, requirement: Requirement) Error!bool {
        try self.validate(terms);
        const requested = try self.shape(requirement.permissions, requirement.facts);
        var allowed = requested.permissions & ~terms.permissions == 0;
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (requested.bounds[i]) |fact| {
                if (terms.bounds[i]) |limit| allowed = satisfies(field.operator, fact, limit) and allowed;
            }
        }
        return allowed;
    }

    fn satisfies(operator: Operator, value_: u64, limit: u64) bool {
        return switch (operator) {
            .lower_bound => value_ >= limit,
            .upper_bound => value_ <= limit,
        };
    }

    fn permissionMask(self: *const Policy, keys: []const Key) Error!u64 {
        if (keys.len > max_permissions) return error.PolicyLimit;
        var mask: u64 = 0;
        for (keys) |key| {
            const index = try self.permissionIndex(key);
            const bit = @as(u64, 1) << @intCast(index);
            if (mask & bit != 0) return error.DuplicateKey;
            mask |= bit;
        }
        return mask;
    }

    fn permissionIndex(self: *const Policy, key: Key) Error!usize {
        for (self.permission_keys[0..self.permission_count], 0..) |declared, index| if (declared == key) return index;
        return error.UnknownPermission;
    }

    fn declaredMask(self: *const Policy) u64 {
        return if (self.permission_count == max_permissions) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(self.permission_count)) - 1;
    }

    fn constraintIndex(self: *const Policy, key: Key) Error!usize {
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (field.key == key) return i;
        }
        return error.UnknownConstraint;
    }
};
