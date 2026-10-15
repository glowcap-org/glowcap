//! Annotated exported inventory of the optional loam_volatile archive.
const shared = @import("c_abi_shared");
pub const symbols = [_]shared.symbols.Symbol{
    .{ .name = "glowcap_loam_volatile_recover" },
    .{ .name = "glowcap_loam_volatile_open", .out_params = &.{ 6, 7 } },
    .{ .name = "glowcap_loam_volatile_release" },
    .{ .name = "glowcap_loam_volatile_work_run" },
    .{ .name = "glowcap_loam_volatile_restore", .out_params = &.{3} },
    .{ .name = "glowcap_loam_volatile_commit" },
    .{ .name = "glowcap_loam_volatile_collect" },
    .{ .name = "glowcap_loam_volatile_last_error" },
    .{ .name = "glowcap_loam_volatile_clear_last_error" },
    .{ .name = "glowcap_loam_volatile_archive_fingerprint" },
};
