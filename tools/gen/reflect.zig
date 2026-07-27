//! Comptime reflection helpers shared by the `tools/gen/` generators, so a
//! generator names one helper rather than redeclaring it.

const std = @import("std");

/// The unqualified type name: strip the module path that `@typeName` carries,
/// so `foo.bar.Baz` becomes `Baz`.
pub fn baseName(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    return if (dot) |i| name[i + 1 ..] else name;
}
