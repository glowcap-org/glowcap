//! What an outbound `op:gc-exports` reaches the wire with while stored
//! resolutions hold import rows: the entries naming a held row stay behind,
//! and the import table keeps their retains when the release records
//! (`ImportTable.decrement`, `ImportTable.releaseSessionHeld`).
const std = @import("std");
const model = @import("model");
const session = @import("mod.zig");

const Session = session.Session;

/// The part of one release that reaches the wire.
pub const WireRelease = union(enum) {
    /// Every entry: the release goes out as it is.
    all,
    /// No entry: the release records without a frame.
    none,
    /// The entries naming no held row, in arrays the caller frees.
    some: model.GcExport,

    pub fn deinit(self: WireRelease, allocator: std.mem.Allocator) void {
        if (self == .some) {
            allocator.free(self.some.positions);
            allocator.free(self.some.deltas);
        }
    }

    /// How many of a release's `total` entries this decision keeps off the wire.
    pub fn heldCount(self: WireRelease, total: usize) usize {
        return switch (self) {
            .all => 0,
            .none => total,
            .some => |gc_export| total - gc_export.positions.len,
        };
    }
};

/// How many entries of `gc_export` name a row a stored resolution holds.
pub fn heldReleaseEntries(self: *const Session, gc_export: model.GcExport) usize {
    var held: usize = 0;
    for (gc_export.positions) |position| {
        if (self.imports.heldByResolution(.from(position))) held += 1;
    }
    return held;
}

/// Decide what `gc_export` reaches the wire. A release naming no held row,
/// the ordinary case, costs one table read per entry and allocates nothing.
/// Every producer of an outbound release asks this before encoding and
/// records the whole release after, so one rule covers a caller's release,
/// a session's, and the closure either carries.
pub fn wireRelease(self: *const Session, allocator: std.mem.Allocator, gc_export: model.GcExport) !WireRelease {
    const held = heldReleaseEntries(self, gc_export);
    if (held == 0) return .all;
    if (held == gc_export.positions.len) return .none;
    const kept_len = gc_export.positions.len - held;
    const positions = try allocator.alloc(u64, kept_len);
    errdefer allocator.free(positions);
    const deltas = try allocator.alloc(u64, kept_len);
    var kept: usize = 0;
    for (gc_export.positions, gc_export.deltas) |position, delta| {
        if (self.imports.heldByResolution(.from(position))) continue;
        positions[kept] = position;
        deltas[kept] = delta;
        kept += 1;
    }
    std.debug.assert(kept == kept_len);
    return .{ .some = .{ .positions = positions, .deltas = deltas } };
}
