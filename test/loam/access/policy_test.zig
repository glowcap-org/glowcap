//! Runtime managed access permission and ordered-bound algebra. Fixtures pin the meaning
//! of each bound; finite laws exercise intersection independently of grant use.
//! The law test is checked against permission-union and reversed-bound defects.
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
