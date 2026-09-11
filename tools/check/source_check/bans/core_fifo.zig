//! Head-indexed FIFO ownership and shared-compaction checks.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// Head-indexed FIFO compaction lives in `engine/fifo.zig`. Node export-range
/// recycling and Host dirty-session scheduling ride `ActionFifo` so their
/// cursor thresholds, drain rewinds, and append compaction cannot diverge.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/ocapn/engine/fifo.zig" },
        .kind = .require,
        .needles = &.{ "pub fn compactHead", "compactHead(T, &self.list, &self.head)" },
        .check = "core-fifo-spine",
        .why = "head-indexed queues share append compaction through engine/fifo.zig instead of repeating its control-flow spine",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/fifo.zig" },
        .kind = .forbid,
        .needles = &.{"compactForAppend"},
        .check = "core-fifo-spine",
        .why = "ActionFifo calls the shared compactHead spine rather than restoring a private append compactor",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/peer/queue.zig" },
        .kind = .require,
        .needles = &.{"fifo.compactHead(T, &self.items, &self.head)"},
        .check = "core-fifo-spine",
        .why = "Peer queues reuse engine/fifo.zig's append compaction rather than carrying a sibling implementation",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/peer/queue.zig" },
        .kind = .forbid,
        .needles = &.{ "compactForAppend", "std.mem.copyForwards" },
        .check = "core-fifo-spine",
        .why = "Peer queues reuse engine/fifo.zig's append compaction rather than carrying a sibling implementation",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/node.zig" },
        .kind = .forbid,
        .needles = &.{ "freed_export_head", "std.ArrayListUnmanaged(u64) = .empty" },
        .check = "core-fifo-spine",
        .why = "released export ranges use engine/fifo.zig's ActionFifo; do not restore a private ArrayList+head queue",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/export_ranges.zig" },
        .kind = .forbid,
        .needles = &.{ "self.freed_export_head", "self.freed_export_bases.items", "std.mem.copyForwards(u64" },
        .check = "core-fifo-spine",
        .why = "released export ranges use engine/fifo.zig's ActionFifo; do not hand-roll cursor compaction",
    },
    .{
        .where = .{ .file = "src/driver/core/host.zig" },
        .kind = .forbid,
        .needles = &.{ "pending_flush_head", "pending_flush: std.ArrayListUnmanaged(engine.PeerHandle)" },
        .check = "core-fifo-spine",
        .why = "dirty-session scheduling uses engine/fifo.zig's ActionFifo; do not restore a private ArrayList+head queue",
    },
    .{
        .where = .{ .file = "src/driver/core/host/pump/schedule.zig" },
        .kind = .forbid,
        .needles = &.{ "compactDirtyPrefix", "self.pending_flush_head", "std.mem.copyForwards(\n            engine.PeerHandle" },
        .check = "core-fifo-spine",
        .why = "dirty-session scheduling uses engine/fifo.zig's ActionFifo; do not hand-roll cursor compaction",
    },
};
