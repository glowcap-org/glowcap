//! The start-session hello both halves of every lifecycle scenario send.

const std = @import("std");
const pancake = @import("pancake");
const model = pancake.ocapn.model;

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
