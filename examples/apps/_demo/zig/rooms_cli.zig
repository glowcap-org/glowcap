const std = @import("std");

/// Typed room error codes mirrored from `deno/lib/errors.ts`.
pub const no_such_room = "no-such-room";
pub const room_exists = "room-exists";

/// The typed code at the front of a room error reason, `<code>: <detail>`.
pub fn errorCode(reason: []const u8) []const u8 {
    const colon = std.mem.indexOf(u8, reason, ": ") orelse return "";
    return reason[0..colon];
}
