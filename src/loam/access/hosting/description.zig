//! Public access snapshots expose stable policy keys, never owner event stamps.
const std = @import("std");
const core = @import("loam_access_core");
const storage = @import("loam_access_storage");
const driver = @import("driver_core");

/// Every slice belongs to the bounded retained-call arena. Inactive access
/// has only a status; fresh ancestor policies cannot leak after revocation.
pub fn encode(arena: std.mem.Allocator, snapshot: storage.Operation.Description) !driver.Value {
    const fields = try arena.alloc(driver.Value, if (snapshot.access == .active) 6 else 1);
    fields[0] = .{ .symbol = @tagName(snapshot.access) };
    if (snapshot.access == .active) {
        const value = snapshot.access.active;
        fields[1] = try unsigned(arena, @backingInt(snapshot.policy.id));
        fields[2] = try policy(arena, &snapshot.policy, value.ceiling);
        fields[3] = try policy(arena, &snapshot.policy, value.configured);
        fields[4] = try policy(arena, &snapshot.policy, value.effective);
        fields[5] = .{ .integer = value.delegation_depth };
    }
    return .{ .tagged = .{ .tag = "access:description", .value = fields } };
}

fn policy(arena: std.mem.Allocator, schema: *const core.Policy, value: core.Policy.Value) !driver.Value {
    try schema.validate(value);
    const permissions = try arena.alloc(driver.Value, @popCount(value.permissions));
    var n: usize = 0;
    for (schema.permission_keys[0..schema.permission_count], 0..) |key, bit| {
        if (value.permissions & (@as(u64, 1) << @intCast(bit)) == 0) continue;
        permissions[n] = try unsigned(arena, @backingInt(key));
        n += 1;
    }
    n = 0;
    for (value.bounds[0..schema.constraint_count]) |bound| if (bound != null) {
        n += 1;
    };
    const bounds = try arena.alloc(driver.Value, n);
    n = 0;
    for (schema.constraint_fields[0..schema.constraint_count], value.bounds[0..schema.constraint_count]) |field, bound| {
        const limit = bound orelse continue;
        const parts = try arena.alloc(driver.Value, 3);
        parts[0] = try unsigned(arena, @backingInt(field.key));
        parts[1] = .{ .symbol = @tagName(field.operator) };
        parts[2] = try unsigned(arena, limit);
        bounds[n] = .{ .tagged = .{ .tag = "access:bound", .value = parts } };
        n += 1;
    }
    const parts = try arena.alloc(driver.Value, 2);
    parts[0] = .{ .list = permissions };
    parts[1] = .{ .list = bounds };
    return .{ .tagged = .{ .tag = "access:policy", .value = parts } };
}

fn unsigned(arena: std.mem.Allocator, value: u128) !driver.Value {
    if (std.math.cast(i64, value)) |n| return .{ .integer = n };
    return .{ .big_integer = .{ .negative = false, .digits = try std.fmt.allocPrint(arena, "{d}", .{value}) } };
}
