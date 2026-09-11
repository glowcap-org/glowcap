//! Failure retention ownership and cross-binding capacity policy.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Failure values carry ownership structurally, and binding error wrappers
/// share one secondary-failure retention cap.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/core/host/action.zig" },
        .kind = .require,
        .needles = &.{ "pub const RetainedFailureMessage = union(enum)", "message: RetainedFailureMessage" },
        .check = "host-failure-message-ownership",
        .why = "Host failure-message ownership is represented by a union tag, never by a slice correlated with an ownership boolean",
    },
    .{
        .where = .{ .tree = .{ .dir = "src/driver/core", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{"message_owned"},
        .check = "host-failure-message-ownership",
        .why = "Host failure-message ownership is represented by RetainedFailureMessage's union tag",
    },
    .{
        .where = .{ .file = "tools/gen/binding/policy.zig" },
        .kind = .require,
        .needles = &.{"pub const secondary_failure_cap: usize = 64;"},
        .check = "secondary-failure-cap",
        .why = "the shared exact secondary-failure retention cap lives in binding policy and reaches bindings through generated mirrors",
    },
    .{
        .where = .{ .file = "bindings/ts/runtime/cleanup.ts" },
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
        .where = .{ .file = "bindings/python/glowcap/_errors.py" },
        .kind = .require,
        .needles = &.{"_FAILURE_CHAIN_CAP = _abi.BINDING_SECONDARY_FAILURE_CAP"},
        .check = "secondary-failure-cap",
        .why = "Python's secondary failure tuple must consume the generated binding-policy cap instead of carrying its own literal",
    },
};
