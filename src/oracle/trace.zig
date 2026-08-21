//! Bounded formatting for canonical oracle trace lines.

const std = @import("std");

pub fn appendLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, format, args);
    try out.appendSlice(allocator, line);
}
