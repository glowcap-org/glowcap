//! Agent-facing flags for `pancake app rooms-peer` verbs.
pub const Flags = struct {
    dir: []const u8 = "",
    nick: []const u8 = "",
    room: []const u8 = "general",
    locator: []const u8 = "",
    text: []const u8 = "",
    /// Peer nick for `reply --dm` (directory introduce target).
    dm: []const u8 = "",
    id: []const u8 = "",
    wait: u64 = 0,
    all: bool = false,
    /// Optional CapTP identity seed path (default: DIR/identity, else product default).
    identity: []const u8 = "",
};
