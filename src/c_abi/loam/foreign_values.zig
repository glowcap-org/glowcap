//! Foreign argument decoding for the Loam C boundary: object handles, access
//! policies, and `ptr + len` views.

const std = @import("std");
const owners = @import("owners.zig");

const access = owners.access;
const c = owners.c;
const core = owners.core;
const shared = owners.shared;

/// A caller's object handle. A malformed one is the caller's argument, not
/// damaged storage, so it never reports `Corrupt`.
pub fn object(raw: c.GlowcapLoamObject) !core.ObjectId {
    return core.ObjectId.fromKey(&raw.key) catch error.InvalidArgument;
}
pub fn objectToC(id: core.ObjectId) c.GlowcapLoamObject {
    return .{ .key = id.key() };
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
