//! Inclusive policy bounds. An absent parent bound admits any child.
const std = @import("std");

pub const Operator = enum { lower_bound, upper_bound };

pub const Comparison = union(enum) {
    unrestricted_parent,
    unrestricted_child,
    ordered: std.math.Order,

    fn of(child: ?u64, parent: ?u64) Comparison {
        const limit = parent orelse return .unrestricted_parent;
        const value = child orelse return .unrestricted_child;
        return .{ .ordered = std.math.order(value, limit) };
    }
};

pub fn accepts(operator: Operator, comparison: Comparison) bool {
    return switch (comparison) {
        .unrestricted_parent => true,
        .unrestricted_child => false,
        .ordered => |order| switch (operator) {
            .lower_bound => order != .lt,
            .upper_bound => order != .gt,
        },
    };
}

pub fn fits(operator: Operator, child: ?u64, parent: ?u64) bool {
    return accepts(operator, Comparison.of(child, parent));
}

pub fn intersect(operator: Operator, a: ?u64, b: ?u64) ?u64 {
    return if (fits(operator, a, b)) a else b;
}
