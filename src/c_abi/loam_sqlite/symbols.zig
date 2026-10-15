//! Annotated exported inventory of the optional loam_sqlite archive.
const shared = @import("c_abi_shared");
pub const symbols = [_]shared.symbols.Symbol{
    .{ .name = "glowcap_loam_sqlite_recover" },
    .{ .name = "glowcap_loam_sqlite_open", .out_params = &.{ 8, 9 } },
    .{ .name = "glowcap_loam_sqlite_release" },
    .{ .name = "glowcap_loam_sqlite_work_run" },
    .{ .name = "glowcap_loam_sqlite_restore", .out_params = &.{3} },
    .{ .name = "glowcap_loam_sqlite_commit" },
    .{ .name = "glowcap_loam_sqlite_collect" },
    .{ .name = "glowcap_loam_sqlite_last_error" },
    .{ .name = "glowcap_loam_sqlite_clear_last_error" },
    .{ .name = "glowcap_loam_sqlite_archive_fingerprint" },
};
