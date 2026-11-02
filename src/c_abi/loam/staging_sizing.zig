//! Pure row-family projections. Store admission remains the staging authority.
const std = @import("std");
const owners = @import("owners.zig");
const refusal = @import("refusal.zig");

pub fn glowcap_loam_content_staging_size_bound(resource_path: usize, receipt: u32, out_bounds: ?*owners.c.GlowcapLoamStagingBounds) callconv(.c) i32 {
    owners.shared.lastErrorClear();
    const out = out_bounds orelse return owners.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = std.mem.zeroes(owners.c.GlowcapLoamStagingBounds);
    if (receipt > 1) return refusal.code(error.InvalidArgument);
    const bound = owners.access.storage.stage.contentStagingSizeBound(resource_path, receipt != 0) catch |err| return refusal.code(err);
    out.* = .{ .changes = bound.changes, .staging_bytes = bound.staging_bytes, .record_bytes = bound.record_bytes };
    return owners.shared.GLOWCAP_OK;
}

/// Every fresh save may stage one recipe. Reused committed fields need no new
/// row. The canonical recipe schema covers both local and foreign restoration.
pub fn glowcap_loam_reference_staging_size_bound(saves: usize, out_bounds: ?*owners.c.GlowcapLoamStagingBounds) callconv(.c) i32 {
    owners.shared.lastErrorClear();
    const out = out_bounds orelse return owners.shared.GLOWCAP_ERR_NULL_POINTER;
    out.* = std.mem.zeroes(owners.c.GlowcapLoamStagingBounds);
    if (saves == 0) return owners.shared.GLOWCAP_OK;
    const bytes = owners.hosting.references.schema.encodedSizeBound() catch |err| return refusal.code(err);
    const total = std.math.mul(usize, saves, bytes) catch |err| return refusal.code(err);
    out.* = .{ .changes = saves, .staging_bytes = total, .record_bytes = bytes };
    return owners.shared.GLOWCAP_OK;
}
