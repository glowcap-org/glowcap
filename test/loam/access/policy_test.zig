//! Runtime managed access permission and ordered-bound algebra. Fixtures pin the meaning
//! of each bound. Finite laws exercise intersection independently of grant use.
//! The law test is checked against permission-union and reversed-bound defects.
//! Dependency closure is checked against intersection dropping a prerequisite.
//! It covers Boolean sets and unsigned bounds, not application fact mappings.

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
    // Enumerate the closed values and check that every intersection remains closed.
    const values = [_]Policy.Value{ try policy.value(&.{}, &.{}), reader, try policy.value(&.{ read, post }, &.{}), full };
    for (values) |a| for (values) |b| {
        const meet = try policy.intersect(a, b);
        try policy.validate(meet);
        try std.testing.expect(try policy.isSubsetOf(meet, a));
        try std.testing.expect(try policy.isSubsetOf(meet, b));
    };
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
    var masks = policy.prerequisite_masks;
    masks[2] = 1;
    try std.testing.expectError(error.UnknownPermission, policy.withPrerequisiteMasks(masks));
    masks = policy.prerequisite_masks;
    masks[0] = 4;
    try std.testing.expectError(error.UnknownPermission, policy.withPrerequisiteMasks(masks));
    masks[0] = 1;
    try std.testing.expectError(error.InvalidDependency, policy.withPrerequisiteMasks(masks));
    masks[0] = 2;
    const mutual = try policy.withPrerequisiteMasks(masks);
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
    invalid.bounds[2] = 0;
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

test "access policy intersection laws over finite permission and bound values" {
    const policy = try Policy.init(descriptor);
    var values: [16]Policy.Value = undefined;
    for (&values, 0..) |*value, i| {
        value.* = try policy.value(&.{}, &.{});
        value.permissions = @intCast(i % 4);
        switch (i / 4) {
            0 => {},
            1 => {
                value.bounds[0] = 0;
                value.bounds[1] = std.math.maxInt(u64);
            },
            2 => {
                value.bounds[0] = 5;
                value.bounds[1] = 10;
            },
            3 => {
                value.bounds[0] = std.math.maxInt(u64);
                value.bounds[1] = 0;
            },
            else => unreachable,
        }
    }
    for (values) |a| {
        try std.testing.expectEqualDeep(a, try policy.intersect(a, a));
        for (values) |b| {
            const meet = try policy.intersect(a, b);
            try std.testing.expect(try policy.isSubsetOf(meet, a));
            try std.testing.expect(try policy.isSubsetOf(meet, b));
            try std.testing.expectEqualDeep(meet, try policy.intersect(b, a));
            for (values) |c| {
                try std.testing.expectEqualDeep(try policy.intersect(meet, c), try policy.intersect(a, try policy.intersect(b, c)));
                if (try policy.isSubsetOf(c, a) and try policy.isSubsetOf(c, b)) try std.testing.expect(try policy.isSubsetOf(c, meet));
            }
        }
    }
}
