//! Annotated exported inventory of the optional loam_lmdb archive.
const shared = @import("c_abi_shared");
pub const symbols = [_]shared.symbols.Symbol{
    .{ .name = "glowcap_loam_lmdb_recover" },
    .{ .name = "glowcap_loam_lmdb_open", .out_params = &.{ 8, 9 } },
    .{ .name = "glowcap_loam_lmdb_release" },
    .{ .name = "glowcap_loam_lmdb_work_run" },
    .{ .name = "glowcap_loam_lmdb_restore", .out_params = &.{3} },
    .{ .name = "glowcap_loam_lmdb_commit" },
    .{ .name = "glowcap_loam_lmdb_collect" },
    .{ .name = "glowcap_loam_lmdb_last_error" },
    .{ .name = "glowcap_loam_lmdb_clear_last_error" },
    .{ .name = "glowcap_loam_lmdb_archive_fingerprint" },
};
