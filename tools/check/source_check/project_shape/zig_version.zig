//! The public package minimum follows the compiler the project pins and tests.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const pins_path = ".devcontainer/pins.sh";
    const zon_path = "build.zig.zon";
    const pins = root.readFileAlloc(io, pins_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read the Zig version authority ({s})", .{ pins_path, @errorName(err) });
        return;
    };
    defer gpa.free(pins);
    const zon = root.readFileAlloc(io, zon_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read the public package minimum ({s})", .{ zon_path, @errorName(err) });
        return;
    };
    defer gpa.free(zon);

    const pinned = quotedValueAfter(pins, "ZIG_VERSION=\"") orelse {
        try appendViolation(gpa, violations, "{s}: no closed `ZIG_VERSION=\"…\"` declaration", .{pins_path});
        return;
    };
    const minimum = quotedValueAfter(zon, ".minimum_zig_version = \"") orelse {
        try appendViolation(gpa, violations, "{s}: no closed `.minimum_zig_version = \"…\"` declaration", .{zon_path});
        return;
    };
    if (!std.mem.eql(u8, pinned, minimum)) {
        try appendViolation(
            gpa,
            violations,
            "{s}: minimum Zig `{s}` differs from `{s}` pin `{s}`; the tested compiler is the public package minimum",
            .{ zon_path, minimum, pins_path, pinned },
        );
    }
}

fn quotedValueAfter(source: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, prefix) orelse return null;
    const value = source[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    return value[0..end];
}

test "quoted values require their owner and closing quote" {
    try std.testing.expectEqualStrings("0.17.0-dev.1+abc", quotedValueAfter("ZIG_VERSION=\"0.17.0-dev.1+abc\"\n", "ZIG_VERSION=\"").?);
    try std.testing.expect(quotedValueAfter("OTHER=\"0.17\"", "ZIG_VERSION=\"") == null);
    try std.testing.expect(quotedValueAfter("ZIG_VERSION=\"open", "ZIG_VERSION=\"") == null);
}
