//! Ban rows for the local Forward chase contract.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Local Forward chase policy is actor/Host turn vocabulary. The C ABI and
/// generated binding constants project it; they do not own the literal cap.
pub const hop_cap_rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/driver/core/vocab.zig" },
        .kind = .require,
        .needles = &.{"pub const max_local_forward_hops: usize = 256;"},
        .check = "local-forward-hop-cap",
        .why = "driver_core owns the shared synchronous local Forward hop cap used by Host turns and binding trampolines",
    },
    .{
        .where = .{ .file = "src/c_abi/host/mod.zig" },
        .kind = .require,
        .needles = &.{"GLOWCAP_MAX_LOCAL_FORWARD_HOPS: usize = driver_core.max_local_forward_hops"},
        .check = "local-forward-hop-cap",
        .why = "the Host C ABI projects the shared local Forward hop cap instead of restating the value",
    },
    .{
        .where = .{ .file = "src/c_abi/host/mod.zig" },
        .kind = .forbid,
        .needles = &.{"GLOWCAP_MAX_LOCAL_FORWARD_HOPS: usize = 256"},
        .check = "local-forward-hop-cap",
        .why = "local Forward chase policy lives in driver_core; the Host C ABI is only the projection seam",
    },
};
