//! Shared tools demo check helper.

const std = @import("std");

pub fn check(nick: []const u8, label: []const u8, passed: bool) bool {
    std.debug.print("{s}: {s}, {s}\n", .{ nick, if (passed) "ok" else "FAIL", label });
    return passed;
}
