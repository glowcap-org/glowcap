//! The generated Rooms vocabulary owns exported wire strings.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const protocol_path = "apps/rooms/lib/protocol.ts";

fn authoredStringConstant(line: []const u8) bool {
    const declaration = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, declaration, "export const ")) return false;
    const equals = std.mem.indexOfScalar(u8, declaration, '=') orelse return false;
    const value = std.mem.trimStart(u8, declaration[equals + 1 ..], " \t");
    return value.len != 0 and (value[0] == '"' or value[0] == '\'' or value[0] == '`');
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const source = root.readFileAlloc(io, protocol_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, protocol_path ++ ": could not inspect protocol vocabulary with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(source);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        if (!authoredStringConstant(line)) continue;
        try appendViolation(
            gpa,
            violations,
            protocol_path ++ ":{d}: exported wire strings come from the generated protocol_data.ts projection",
            .{line_number},
        );
    }
}

test "authored protocol strings are detected without rejecting generated re-exports" {
    try std.testing.expect(authoredStringConstant("export const POST = \"post\";"));
    try std.testing.expect(authoredStringConstant("  export const POST = 'post';"));
    try std.testing.expect(authoredStringConstant("export const POST = `post`;"));
    try std.testing.expect(!authoredStringConstant("export { POST } from \"./protocol_data.ts\";"));
    try std.testing.expect(!authoredStringConstant("export const ROOM_FEATURES = [\"previews\"] as const;"));
}
