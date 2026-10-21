//! Runtime policy vocabulary shared by Zig and foreign consumers.
//! Stable keys name Boolean permissions and unsigned lower or upper bounds.
//! Applications supply operation requirements and committed facts. This module
//! owns their set and bound algebra. It performs no allocation or callbacks.

const std = @import("std");
const KindId = @import("identity.zig").KindId;

pub const Policy = struct {
    id: Id,
    permission_keys: [max_permissions]Key,
    constraint_fields: [max_constraints]Constraint,
    permission_count: usize,
    constraint_count: usize,
    /// Required bits use permission_keys' stable ordering. The 512 inline bytes
    /// keep declaration ownership with the copied policy across cold reads and
    /// foreign calls. No retained borrow, callback or heap allocation is needed.
    prerequisite_masks: [max_permissions]u64 = @splat(0),
    kind_rules: [max_kinds]KindRule = undefined,
    kind_count: usize = 0,

    pub const Id = enum(u128) { _ };
    pub const Key = enum(u64) { _ };
    pub const max_permissions = 64;
    pub const max_constraints = 16;
    pub const max_kinds = 16;
    /// Masks use the complete vocabulary's stable ordering. Subtree support
    /// includes future descendants and must contain exact-object support.
    pub const KindRule = struct { kind: KindId, permissions: u64, subtree_permissions: u64 };
    pub const Operator = enum { lower_bound, upper_bound };
    pub const Constraint = struct { key: Key, operator: Operator };
    pub const Bound = struct { key: Key, value: u64 };
    pub const Dependency = struct { permission: Key, required: Key };
    pub const Descriptor = struct {
        /// A schema identity fixes keys, operators, dependencies and kind support.
        id: Id,
        permissions: []const Key,
        constraints: []const Constraint = &.{},
        dependencies: []const Dependency = &.{},
        /// Empty means kind-independent vocabulary. A nonempty declaration
        /// refuses every kind it does not name.
        kinds: []const KindRule = &.{},
    };
    pub const Value = struct {
        schema: Id,
        /// Bits refer to this schema's sorted permission declarations.
        permissions: u64,
        /// One limit per schema constraint slot. A slot whose `bound_mask` bit
        /// is clear is unrestricted and holds zero, so two equal values are
        /// equal bytes. Unused schema slots stay clear. The C ABI mirrors this
        /// pair as `GlowcapLoamPolicyValue`.
        bounds: [max_constraints]u64 = @splat(0),
        bound_mask: u16 = 0,

        pub fn bound(self: Value, index: usize) ?u64 {
            return if (self.bound_mask & bit(u16, index) != 0) self.bounds[index] else null;
        }

        pub fn setBound(self: *Value, index: usize, limit: ?u64) void {
            self.bounds[index] = limit orelse 0;
            if (limit != null) self.bound_mask |= bit(u16, index) else self.bound_mask &= ~bit(u16, index);
        }
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
        UnknownKind,
        InapplicablePermission,
        InvalidKindRule,
        InvalidPlacement,
    };

    /// Copies a bounded, strictly key-sorted descriptor into a value. The
    /// value is immutable once built: `setPrerequisiteMasks` and `setKinds`
    /// complete a decoded one in place, each validating before it writes.
    /// Reusing an identity for a different vocabulary is not schema evolution.
    pub fn init(descriptor: Descriptor) Error!Policy {
        if (descriptor.dependencies.len > max_permissions * max_permissions) return error.PolicyLimit;
        try checkVocabulary(descriptor.permissions, descriptor.constraints);
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
            const required_bit = bit(u64, required);
            if (self.prerequisite_masks[index] & required_bit != 0) return error.DuplicateKey;
            self.prerequisite_masks[index] |= required_bit;
        }
        try self.setKinds(descriptor.kinds);
        return self;
    }

    /// Copy declarative applicability. No schema callback or borrowed table
    /// survives. Both masks obey the same permission dependencies as terms.
    /// A refused rule set leaves the policy as it was.
    pub fn setKinds(self: *Policy, rules: []const KindRule) Error!void {
        try checkKinds(self.declaredMask(), &self.prerequisite_masks, rules);
        self.kind_count = rules.len;
        @memcpy(self.kind_rules[0..rules.len], rules);
    }

    /// Refuse a value a caller built field by field unless the constructors
    /// would have built it.
    pub fn check(self: *const Policy) Error!void {
        if (self.permission_count > max_permissions or self.constraint_count > max_constraints or self.kind_count > max_kinds) return error.PolicyLimit;
        try checkVocabulary(self.permission_keys[0..self.permission_count], self.constraint_fields[0..self.constraint_count]);
        try checkMasks(self.permission_count, &self.prerequisite_masks);
        try checkKinds(self.declaredMask(), &self.prerequisite_masks, self.kind_rules[0..self.kind_count]);
    }

    fn checkVocabulary(permissions: []const Key, constraints: []const Constraint) Error!void {
        if (permissions.len > max_permissions or constraints.len > max_constraints) return error.PolicyLimit;
        for (permissions, 0..) |key, i| {
            if (i != 0 and @backingInt(permissions[i - 1]) >= @backingInt(key)) return error.NonCanonicalSchema;
        }
        for (constraints, 0..) |field, i| {
            if (i != 0 and @backingInt(constraints[i - 1].key) >= @backingInt(field.key)) return error.NonCanonicalSchema;
        }
    }

    fn checkMasks(permission_count: usize, masks: *const [max_permissions]u64) Error!void {
        const declared = declaredMaskFor(permission_count);
        for (masks, 0..) |required, index| {
            if (index >= permission_count) {
                if (required != 0) return error.UnknownPermission;
            } else {
                if (required & ~declared != 0) return error.UnknownPermission;
                if (required & bit(u64, index) != 0) return error.InvalidDependency;
            }
        }
    }

    fn checkKinds(declared: u64, masks: *const [max_permissions]u64, rules: []const KindRule) Error!void {
        if (rules.len > max_kinds) return error.PolicyLimit;
        for (rules, 0..) |rule, i| {
            if (i != 0 and @backingInt(rules[i - 1].kind) >= @backingInt(rule.kind)) return error.NonCanonicalSchema;
            try checkTerms(declared, masks, rule.permissions);
            try checkTerms(declared, masks, rule.subtree_permissions);
            if (rule.permissions & ~rule.subtree_permissions != 0) return error.InvalidKindRule;
        }
    }

    /// Every selected permission is declared and carries its prerequisites.
    fn checkTerms(declared: u64, masks: *const [max_permissions]u64, permissions: u64) Error!void {
        if (permissions & ~declared != 0) return error.UnknownPermission;
        var selected = permissions;
        while (selected != 0) {
            const index = @ctz(selected);
            if (masks[index] & ~permissions != 0) return error.MissingPrerequisite;
            selected &= selected - 1;
        }
    }

    pub fn supported(self: *const Policy, kind: KindId, subtree: bool) Error!u64 {
        if (self.kind_count == 0) return self.declaredMask();
        for (self.kind_rules[0..self.kind_count]) |rule| if (rule.kind == kind) return if (subtree) rule.subtree_permissions else rule.permissions;
        return error.UnknownKind;
    }

    /// A child's future support must fit its parent's future support. This
    /// composes along containment without loading the current descendants.
    pub fn validatePlacement(self: *const Policy, kind: KindId, parent: ?KindId) Error!void {
        const child = try self.supported(kind, true);
        if (parent) |parent_kind| if (child & ~try self.supported(parent_kind, true) != 0) return error.InvalidPlacement;
    }

    /// Adopt the persisted/ABI matrix after constructing its vocabulary. Every
    /// matrix position is validated, and the kind rules already set are
    /// validated against the new matrix, before the policy changes.
    pub fn setPrerequisiteMasks(self: *Policy, masks: *const [max_permissions]u64) Error!void {
        try checkMasks(self.permission_count, masks);
        try checkKinds(self.declaredMask(), masks, self.kind_rules[0..self.kind_count]);
        self.prerequisite_masks = masks.*;
    }

    /// Constructs explicit policy terms from declared keys. Inputs are borrowed
    /// for this call. No pointer into them is retained.
    pub fn value(self: *const Policy, permissions: []const Key, bounds: []const Bound) Error!Value {
        const result = try self.shape(permissions, bounds);
        try self.validate(result);
        return result;
    }

    /// Construct exact-interface terms. This descriptive check supplies no
    /// capability and cannot replace scoped admission against current resources.
    pub fn valueForKind(self: *const Policy, kind: KindId, permissions: []const Key, bounds: []const Bound) Error!Value {
        const result = try self.value(permissions, bounds);
        if (result.permissions & ~try self.supported(kind, false) != 0) return error.InapplicablePermission;
        return result;
    }

    /// Effects request individual permissions. They are not candidate terms.
    fn shape(self: *const Policy, permissions: []const Key, bounds: []const Bound) Error!Value {
        var result: Value = .{ .schema = self.id, .permissions = try self.permissionMask(permissions) };
        if (bounds.len > max_constraints) return error.PolicyLimit;
        for (bounds) |bound| {
            const index = try self.constraintIndex(bound.key);
            if (result.bound(index) != null) return error.DuplicateKey;
            result.setBound(index, bound.value);
        }
        return result;
    }

    pub fn validate(self: *const Policy, terms: Value) Error!void {
        if (terms.schema != self.id) return error.WrongSchema;
        try checkTerms(self.declaredMask(), &self.prerequisite_masks, terms.permissions);
        if (terms.bound_mask & ~self.constraintMask() != 0) return error.UnknownConstraint;
        for (terms.bounds, 0..) |limit, i| if (limit != 0 and terms.bound(i) == null) return error.UnknownConstraint;
    }

    pub fn isSubsetOf(self: *const Policy, child: Value, parent: Value) Error!bool {
        try self.validate(child);
        try self.validate(parent);
        if (child.permissions & ~parent.permissions != 0) return false;
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (parent.bound(i)) |limit| {
                const selected = child.bound(i) orelse return false;
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
            if (b.bound(i)) |limit| {
                result.setBound(i, if (a.bound(i)) |other| switch (field.operator) {
                    .lower_bound => @max(other, limit),
                    .upper_bound => @min(other, limit),
                } else limit);
            }
        }
        return result;
    }

    /// Checks one application's declared effect. Unknown keys and duplicate
    /// facts refuse even if an earlier permission or fact already denies it. status-allow: event or source ordering
    pub fn allows(self: *const Policy, terms: Value, requirement: Requirement) Error!bool {
        return self.allowsSupported(terms, self.declaredMask(), requirement);
    }

    /// Admission reuses the target's already resolved support. Effects remain
    /// partial demands. Malformed facts still refuse before a negative verdict.
    pub fn allowsSupported(self: *const Policy, terms: Value, support: u64, requirement: Requirement) Error!bool {
        try self.validate(terms);
        const requested = try self.shape(requirement.permissions, requirement.facts);
        if (requested.permissions & ~support != 0) return error.InapplicablePermission;
        var allowed = requested.permissions & ~terms.permissions == 0;
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (requested.bound(i)) |fact| {
                if (terms.bound(i)) |limit| allowed = satisfies(field.operator, fact, limit) and allowed;
            }
        }
        return allowed;
    }

    fn satisfies(operator: Operator, fact: u64, limit: u64) bool {
        return switch (operator) {
            .lower_bound => fact >= limit,
            .upper_bound => fact <= limit,
        };
    }

    fn permissionMask(self: *const Policy, keys: []const Key) Error!u64 {
        if (keys.len > max_permissions) return error.PolicyLimit;
        var mask: u64 = 0;
        for (keys) |key| {
            const index = try self.permissionIndex(key);
            const key_bit = bit(u64, index);
            if (mask & key_bit != 0) return error.DuplicateKey;
            mask |= key_bit;
        }
        return mask;
    }

    fn permissionIndex(self: *const Policy, key: Key) Error!usize {
        for (self.permission_keys[0..self.permission_count], 0..) |declared, index| if (declared == key) return index;
        return error.UnknownPermission;
    }

    fn declaredMask(self: *const Policy) u64 {
        return declaredMaskFor(self.permission_count);
    }

    fn constraintMask(self: *const Policy) u16 {
        return lowMask(u16, self.constraint_count);
    }

    fn declaredMaskFor(permission_count: usize) u64 {
        return lowMask(u64, permission_count);
    }

    fn constraintIndex(self: *const Policy, key: Key) Error!usize {
        for (self.constraint_fields[0..self.constraint_count], 0..) |field, i| {
            if (field.key == key) return i;
        }
        return error.UnknownConstraint;
    }
};

fn bit(comptime T: type, index: usize) T {
    return @as(T, 1) << @intCast(index);
}

/// The low `count` bits of `T`, up to all of them.
fn lowMask(comptime T: type, count: usize) T {
    return if (count >= @bitSizeOf(T)) std.math.maxInt(T) else bit(T, count) - 1;
}
