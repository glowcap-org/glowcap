//! Shared JSON / stdout / stderr helpers for CLI fronts.
const std = @import("std");
const log = @import("operability/log.zig");

pub fn writeJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    var hex: [6]u8 = undefined;
                    const h = try std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(gpa, h);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
    try buf.append(gpa, '"');
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

pub fn writeStderr(io: std.Io, bytes: []const u8) !void {
    // CapTP lab TUI diverts stderr diagnostics into the transcript.
    if (log.hasDivert()) {
        log.writeMsg(io, bytes);
        return;
    }
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}
