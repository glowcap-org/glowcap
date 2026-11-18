//! Managed access permissions and ordered bounds. The policy fixtures link
//! the Zig operations to the pointwise set laws in policy_laws/LAWS.bend.

const std = @import("std");
const Policy = @import("glowcap").loam.access.core.Policy;
const read: Policy.Key = @fromBackingInt(10);
const post: Policy.Key = @fromBackingInt(20);
const history: Policy.Key = @fromBackingInt(100);
const upload: Policy.Key = @fromBackingInt(200);
const descriptor: Policy.Descriptor = .{
    .id = @fromBackingInt(11),
    .permissions = &.{ read, post },
    .constraints = &.{ .{ .key = history, .operator = .lower_bound }, .{ .key = upload, .operator = .upper_bound } },
};

test "access policy dependencies distinguish configured terms from effect demands" {
    var dependencies = [_]Policy.Dependency{ .{ .permission = post, .required = read }, .{ .permission = upload, .required = post } };
    const policy = try Policy.init(.{ .id = descriptor.id, .permissions = &.{ read, post, upload }, .dependencies = &dependencies });
    dependencies[0].required = upload; // The descriptor retains no borrowed declaration.
    try std.testing.expectError(error.MissingPrerequisite, policy.value(&.{post}, &.{}));
    try std.testing.expectError(error.MissingPrerequisite, policy.value(&.{ read, upload }, &.{}));
    const full = try policy.value(&.{ read, post, upload }, &.{});
    try std.testing.expect(try policy.allows(full, .{ .permissions = &.{upload} }));
    const reader = try policy.value(&.{read}, &.{});
    try std.testing.expect(!try policy.allows(reader, .{ .permissions = &.{post} }));
    var forged = full;
    forged.permissions = 2;
    try std.testing.expectError(error.MissingPrerequisite, policy.validate(forged));
    try std.testing.expectError(error.MissingPrerequisite, policy.isSubsetOf(forged, full));
    try std.testing.expectError(error.MissingPrerequisite, policy.intersect(full, forged));
    try std.testing.expectError(error.MissingPrerequisite, policy.allows(forged, .{ .permissions = &.{post} }));
    // Each prefix of read, post, upload satisfies the prerequisite chain.
    const values = [_]Policy.Value{ try policy.value(&.{}, &.{}), reader, try policy.value(&.{ read, post }, &.{}), full };
    try expectIntersectionModel(&policy, &values);
}

test "access policy dependency declarations reject malformed matrices and support mutual implications" {
    var dependent = descriptor;
    dependent.dependencies = &.{.{ .permission = post, .required = read }};
    const policy = try Policy.init(dependent);
    dependent.dependencies = &.{ .{ .permission = post, .required = read }, .{ .permission = post, .required = read } };
    try std.testing.expectError(error.DuplicateKey, Policy.init(dependent));
    dependent.dependencies = &.{.{ .permission = post, .required = post }};
    try std.testing.expectError(error.InvalidDependency, Policy.init(dependent));
    dependent.dependencies = &.{.{ .permission = upload, .required = read }};
    try std.testing.expectError(error.UnknownPermission, Policy.init(dependent));
    var mutual = policy;
    var masks = policy.prerequisite_masks;
    masks[2] = 1;
    try std.testing.expectError(error.UnknownPermission, mutual.setPrerequisiteMasks(&masks));
    masks = policy.prerequisite_masks;
    masks[0] = 4;
    try std.testing.expectError(error.UnknownPermission, mutual.setPrerequisiteMasks(&masks));
    masks[0] = 1;
    try std.testing.expectError(error.InvalidDependency, mutual.setPrerequisiteMasks(&masks));
    // A refused matrix left the policy as it was.
    try std.testing.expectEqual(policy.prerequisite_masks, mutual.prerequisite_masks);
    masks[0] = 2;
    try mutual.setPrerequisiteMasks(&masks);
    try std.testing.expectError(error.MissingPrerequisite, mutual.value(&.{read}, &.{}));
    _ = try mutual.value(&.{ read, post }, &.{});
    _ = try mutual.value(&.{}, &.{});
    var keys: [64]Policy.Key = undefined;
    for (&keys, 0..) |*key, i| key.* = @fromBackingInt(@intCast(i));
    const wide = try Policy.init(.{ .id = descriptor.id, .permissions = &keys, .dependencies = &.{.{ .permission = keys[63], .required = keys[0] }} });
    try std.testing.expectError(error.MissingPrerequisite, wide.value(&.{keys[63]}, &.{}));
    const both = try wide.value(&.{ keys[0], keys[63] }, &.{});
    try std.testing.expect(try wide.allows(both, .{ .permissions = &.{keys[63]} }));
}

test "access policy validates runtime schemas values and requirements" {
    const policy = try Policy.init(descriptor);
    const terms = try policy.value(&.{read}, &.{ .{ .key = history, .value = 50 }, .{ .key = upload, .value = 100 } });
    try std.testing.expect(try policy.allows(terms, .{ .permissions = &.{read}, .facts = &.{.{ .key = history, .value = 50 }} }));
    try std.testing.expect(!try policy.allows(terms, .{ .permissions = &.{read}, .facts = &.{.{ .key = history, .value = 49 }} }));
    try std.testing.expect(try policy.allows(terms, .{ .permissions = &.{read}, .facts = &.{.{ .key = upload, .value = 100 }} }));
    try std.testing.expect(!try policy.allows(terms, .{ .permissions = &.{read}, .facts = &.{.{ .key = upload, .value = 101 }} }));
    try std.testing.expect(!try policy.allows(terms, .{ .permissions = &.{post} }));
    try std.testing.expectError(error.UnknownPermission, policy.value(&.{@fromBackingInt(99)}, &.{}));
    try std.testing.expectError(error.UnknownConstraint, policy.value(&.{}, &.{.{ .key = @fromBackingInt(99), .value = 0 }}));
    try std.testing.expectError(error.DuplicateKey, policy.value(&.{ read, read }, &.{}));
    try std.testing.expectError(error.DuplicateKey, policy.value(&.{}, &.{ .{ .key = history, .value = 0 }, .{ .key = history, .value = 1 } }));
    // A known denial must not mask a malformed later fact.
    try std.testing.expectError(error.UnknownConstraint, policy.allows(terms, .{ .permissions = &.{post}, .facts = &.{.{ .key = @fromBackingInt(99), .value = 0 }} }));
    var invalid = terms;
    invalid.schema = @fromBackingInt(12);
    try std.testing.expectError(error.WrongSchema, policy.intersect(terms, invalid));
    invalid = terms;
    invalid.permissions = 4;
    try std.testing.expectError(error.UnknownPermission, policy.validate(invalid));
    invalid = terms;
    invalid.setBound(2, 0);
    try std.testing.expectError(error.UnknownConstraint, policy.validate(invalid));
    // A clear mask bit over a nonzero slot is not a canonical value.
    invalid = terms;
    invalid.bounds[3] = 7;
    try std.testing.expectError(error.UnknownConstraint, policy.validate(invalid));
    var bad = descriptor;
    bad.permissions = &.{ post, read };
    try std.testing.expectError(error.NonCanonicalSchema, Policy.init(bad));
    bad = descriptor;
    bad.constraints = &.{ .{ .key = history, .operator = .lower_bound }, .{ .key = history, .operator = .upper_bound } };
    try std.testing.expectError(error.NonCanonicalSchema, Policy.init(bad));
}

test "access policy copies descriptors and handles full width limits" {
    var keys: [Policy.max_permissions + 1]Policy.Key = undefined;
    for (&keys, 0..) |*key, i| key.* = @fromBackingInt(@intCast(i));
    const policy = try Policy.init(.{ .id = @fromBackingInt(1), .permissions = keys[0..Policy.max_permissions] });
    const all = try policy.value(keys[0..Policy.max_permissions], &.{});
    try std.testing.expectEqual(std.math.maxInt(u64), all.permissions);
    try policy.validate(all);
    keys[0] = @fromBackingInt(1000);
    _ = try policy.value(&.{@fromBackingInt(0)}, &.{});
    try std.testing.expectError(error.UnknownPermission, policy.value(keys[0..1], &.{}));
    try std.testing.expectError(error.PolicyLimit, policy.value(&keys, &.{}));
    try std.testing.expectError(error.PolicyLimit, Policy.init(.{ .id = @fromBackingInt(1), .permissions = &keys }));
    var fields: [Policy.max_constraints + 1]Policy.Constraint = undefined;
    for (&fields, 0..) |*field, i| field.* = .{ .key = @fromBackingInt(@intCast(i)), .operator = .upper_bound };
    try std.testing.expectError(error.PolicyLimit, Policy.init(.{ .id = @fromBackingInt(1), .permissions = &.{}, .constraints = &fields }));
    const empty = try Policy.init(.{ .id = @fromBackingInt(2), .permissions = &.{} });
    try empty.validate(try empty.value(&.{}, &.{}));
}

test "policy intersection and subset agree with the sets used in the attenuation proof" {
    const policy = try Policy.init(descriptor);
    const unrestricted = try policy.value(&.{}, &.{});
    const lower = [_]?u64{ null, 0, 5, std.math.maxInt(u64) };
    const upper = [_]?u64{ null, std.math.maxInt(u64), 10, 0 };
    const permissions = 1 << descriptor.permissions.len;
    var values: [permissions * lower.len * upper.len]Policy.Value = undefined;
    var count: usize = 0;
    for (0..permissions) |bits| {
        for (lower) |floor| {
            for (upper) |ceiling| {
                var value = unrestricted;
                value.permissions = @intCast(bits);
                value.setBound(0, floor);
                value.setBound(1, ceiling);
                values[count] = value;
                count += 1;
            }
        }
    }

    try expectIntersectionModel(&policy, &values);
}

fn expectIntersectionModel(policy: *const Policy, values: anytype) !void {
    // Represent each policy by the set of fixture policies it can delegate.
    // Distinct values need distinct sets for equality in the proof to carry back to Zig.
    const Set = @Int(.unsigned, values.len);
    var sets: [values.len]Set = @splat(0);
    for (values, 0..) |parent, j| {
        try policy.validate(parent);
        for (values, 0..) |child, i| {
            if (fixtureAllows(parent, child)) sets[j] |= @as(Set, 1) << @intCast(i);
        }
        try std.testing.expect(std.mem.findScalar(Set, sets[0..j], sets[j]) == null);
    }

    // Closure makes the same correspondence hold at every step of a chain.
    for (values, sets) |a, left| {
        for (values, sets) |b, right| {
            const common = left & right;
            const index = std.mem.findScalar(Set, &sets, common) orelse return error.MissingIntersection;
            try std.testing.expectEqualDeep(values[index], try policy.intersect(a, b));
            try std.testing.expectEqual(common == left, try policy.isSubsetOf(a, b));
        }
    }
}

// The bounds fixture puts the floor in slot zero and the ceiling in slot one.
// Both slots are empty in the prerequisite fixture.
fn fixtureAllows(parent: Policy.Value, child: Policy.Value) bool {
    if (parent.bound(0)) |floor| if ((child.bound(0) orelse return false) < floor) return false;
    if (parent.bound(1)) |ceiling| if ((child.bound(1) orelse return false) > ceiling) return false;
    return child.permissions & ~parent.permissions == 0;
}
