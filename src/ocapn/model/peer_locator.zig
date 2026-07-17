//! Owned peer locator: transport, designator, and dial hints.
//!
//! Leaf module so `handoff.zig` can name the exporter without importing the
//! model hub (the hub re-exports handoff). Hint spellings live in `hints.zig`.

const hints = @import("hints.zig");

pub const PeerLocator = struct {
    transport: []const u8,
    designator: []const u8,
    hints: hints.Hints = .{},
};
