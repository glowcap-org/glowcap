//! Cross-binding secondary-failure retention policy.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Binding error wrappers share one secondary-failure retention cap.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .file = "tools/gen/binding/policy.zig" },
        .kind = .require,
        .needles = &.{"pub const secondary_failure_cap: usize = 64;"},
        .check = "secondary-failure-cap",
        .why = "the shared exact secondary-failure retention cap lives in binding policy and reaches bindings through generated mirrors",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/errors.ts" },
        .kind = .require,
        .needles = &.{"SECONDARY_FAILURE_CAP = BINDING_SECONDARY_FAILURE_CAP"},
        .check = "secondary-failure-cap",
        .why = "TypeScript's secondary failure list must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/rust/src/failure.rs" },
        .kind = .require,
        .needles = &.{"self.secondary.len() < BINDING_SECONDARY_FAILURE_CAP"},
        .check = "secondary-failure-cap",
        .why = "Rust's secondary failure list must consume the generated binding-policy cap instead of carrying its own literal",
    },
    .{
        .where = .{ .file = "bindings/python/pancake/_errors.py" },
        .kind = .require,
        .needles = &.{"_FAILURE_CHAIN_CAP = _abi.BINDING_SECONDARY_FAILURE_CAP"},
        .check = "secondary-failure-cap",
        .why = "Python's secondary failure tuple must consume the generated binding-policy cap instead of carrying its own literal",
    },
};
