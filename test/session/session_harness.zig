//! Fixtures the session scenarios share: the start-session hello both halves
//! send, and the `op:resolve` fulfill that carries one reference.

const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const syrup = glowcap.ocapn.codec.syrup;

pub fn startSessionMessage(version: model.CaptpVersion) model.Message {
    return startSessionMessageWithKey(version, &.{ 0xaa, 0xbb });
}

pub fn startSessionMessageWithKey(version: model.CaptpVersion, key: []const u8) model.Message {
    return .{
        .start_session = .{
            .captp_version = version,
            .session_pubkey = .{ .bytes = key },
            .acceptable_location = .{
                .transport = "memory",
                .designator = "peer",
                .hints = model.Hints.emptyMap(),
            },
            .acceptable_location_sig = .{ .bytes = &.{0xcc} },
        },
    };
}

/// Encode a payload reference the way CapTP does: as the fulfill of an
/// `op:resolve`. Bytes come only from `syrup.encodeMessage`.
pub fn encodeFulfillRef(allocator: std.mem.Allocator, reference: model.Reference) ![]u8 {
    var frame = try syrup.encodeMessage(allocator, .{
        .resolve = .{
            .answer = .from(7),
            .resolution = .{ .fulfill = .{ .reference = reference } },
        },
    });
    defer frame.deinit();
    return try allocator.dupe(u8, frame.bytes());
}
