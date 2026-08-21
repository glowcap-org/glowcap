//! Rooms signaling policy that follows generated WebRTC ABI caps.

const std = @import("std");
const util = @import("../util.zig");

const expectFileContains = util.expectFileContains;

/// Browser ICE configuration uses the same caps as the WebRTC C ABI/native
/// companion and measures text as UTF-8 bytes, matching the ABI contract.
pub fn checkRoomsWebrtcIceCaps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "apps/rooms/lib/ice.ts", &.{
        "WEBRTC_MAX_ICE_CREDENTIAL_BYTES",
        "WEBRTC_MAX_ICE_SERVERS",
        "WEBRTC_MAX_ICE_URL_BYTES",
        "WEBRTC_MAX_ICE_URLS_PER_SERVER",
        "utf8Fits(url, WEBRTC_MAX_ICE_URL_BYTES)",
        "utf8Fits(value, WEBRTC_MAX_ICE_CREDENTIAL_BYTES)",
    });
    try expectFileContains(io, gpa, root, violations, "apps/rooms/test/ice_test.ts", &.{
        "WEBRTC_MAX_ICE_SERVERS",
        "WEBRTC_MAX_ICE_URL_BYTES",
        "WEBRTC_MAX_ICE_CREDENTIAL_BYTES",
        "Array.from({ length: WEBRTC_MAX_ICE_SERVERS }",
        "Array.from({ length: WEBRTC_MAX_ICE_SERVERS + 1 }",
        "\"a\".repeat(WEBRTC_MAX_ICE_URL_BYTES)",
        "\"\\u{00e9}\".repeat(Math.floor(WEBRTC_MAX_ICE_URL_BYTES / 2) + 1)",
        "\"\\u{00e9}\".repeat(Math.floor(WEBRTC_MAX_ICE_CREDENTIAL_BYTES / 2) + 1)",
    });
}
