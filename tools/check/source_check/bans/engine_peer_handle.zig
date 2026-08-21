//! Ban rows for the engine's Node-scoped registered-session handle vocabulary.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// `foundation.PeerId` is the protocol peer identifier; `engine.PeerHandle` is
/// the Node-scoped registered-session handle. The engine surface must not
/// expose both as `PeerId`, because handoff routing code routinely carries both
/// facts across the same boundary.
pub const rows: []const Ban = &.{
    .{
        .where = .{ .file = "src/ocapn/engine/peer_handle.zig" },
        .kind = .require,
        .needles = &.{"pub const PeerHandle = enum(u64)"},
        .check = "engine-peer-handle",
        .why = "engine/peer_handle.zig owns the Node-scoped registered-session handle; do not restore engine.PeerId",
    },
    .{
        .where = .{ .file = "src/ocapn/engine/mod.zig" },
        .kind = .require,
        .needles = &.{"pub const PeerHandle = @import(\"peer_handle.zig\").PeerHandle;"},
        .check = "engine-peer-handle",
        .why = "engine re-exports the Node-scoped handle as PeerHandle, distinct from foundation.PeerId",
    },
    .{
        .where = .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "engine.PeerId", "@import(\"engine\").PeerId", "peer_id.zig", "@import(\"peer_handle.zig\").PeerId", "peer_id: PeerHandle", "peer_id: engine.PeerHandle", "peer_id: ?PeerHandle", "peer_id: ?engine.PeerHandle", "next_peer_id", "peerId(" },
        .check = "engine-peer-handle",
        .why = "use engine.PeerHandle for Node-scoped registered-session handles; foundation.PeerId remains the protocol public identifier",
    },
    .{
        .where = .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "engine.PeerId", "@import(\"engine\").PeerId", "peer_id.zig", "@import(\"peer_handle.zig\").PeerId", "peer_id: PeerHandle", "peer_id: engine.PeerHandle", "peer_id: ?PeerHandle", "peer_id: ?engine.PeerHandle", "next_peer_id", "peerId(" },
        .check = "engine-peer-handle",
        .why = "tests should consume the same engine.PeerHandle vocabulary as production code",
    },
    .{
        .where = .{ .tree = .{ .dir = "conformance", .suffixes = &.{".zig"} } },
        .kind = .forbid,
        .needles = &.{ "engine.PeerId", "@import(\"engine\").PeerId", "peer_id.zig", "@import(\"peer_handle.zig\").PeerId", "peer_id: PeerHandle", "peer_id: engine.PeerHandle", "peer_id: ?PeerHandle", "peer_id: ?engine.PeerHandle", "next_peer_id", "peerId(" },
        .check = "engine-peer-handle",
        .why = "conformance harnesses should consume the same engine.PeerHandle vocabulary as production code",
    },
};
