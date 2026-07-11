//! Shared usage helper for one-shot Zig demo clients.

const std = @import("std");

pub fn usage(comptime usage_line: []const u8, message: []const u8) error{Usage} {
    std.debug.print("{s}\n  ({s})\n", .{ usage_line, message });
    return error.Usage;
}
