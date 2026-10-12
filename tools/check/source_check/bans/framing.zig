//! Ban row: the one stream scan gate in `codec/dispatch.zig`.

const bans = @import("../bans.zig");
const Ban = bans.Ban;

/// The stream scan gate (ask the cheap scan, decode only once it says a frame
/// may be whole, reset on completion, restate the cap on an open prefix at
/// the cap) lives once, in `codec/dispatch.zig`'s `withScan`. A second copy
/// of that gate is how the two engine entry points once came to differ by a
/// single byte on the cap check.
pub const frame_scan_gate: []const Ban = &.{
    .{
        .where = .{
            .tree = .{
                .dir = "src",
                .suffixes = &.{".zig"},
                .exclude = &.{
                    "src/ocapn/codec/dispatch.zig",
                    // The codec that implements the scan, and the registry page that
                    // documents its signature.
                    "src/ocapn/codec/syrup/decode.zig",
                    "src/ocapn/codec/registry.zig",
                },
            },
        },
        .kind = .forbid,
        .needles = &.{"scanStream("},
        .check = "frame-scan-gate",
        .why = "the stream scan is asked in exactly one place, codec/dispatch.zig's withScan; call framePrefix / framePrefixForProfile instead of re-walking the gate",
    },
};
