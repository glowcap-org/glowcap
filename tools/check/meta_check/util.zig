//! Shared primitives for the meta-check modules.
//!
//! The meta gate is one build step (`tools/check/meta_check.zig` orchestrates)
//! whose check families live in sibling modules under this directory, each
//! owning one named surface. What they all share — today the one violation
//! sink — lives here, so a module never reaches back into the driver.

const std = @import("std");

/// Record one violation. The driver prints the collected list and fails the
/// step when it is non-empty; a check never fails the step directly, so one
/// run reports every violation at once.
pub fn appendViolation(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}

pub fn expectFileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    needles: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    for (needles) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing required text `{s}`", .{ path, needle });
        }
    }
}

pub fn fileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    needle: []const u8,
) !bool {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return false;
    defer gpa.free(contents);
    return std.mem.indexOf(u8, contents, needle) != null;
}

fn parseLeadingInt(s: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == start) return null;
    const mag = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
    return if (neg) -mag else mag;
}

pub fn firstIntIn(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '-' or (s[i] >= '0' and s[i] <= '9')) return parseLeadingInt(s[i..]);
    }
    return null;
}

pub fn parseJsonFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !?std.json.Parsed(std.json.Value) {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read JSON with {s}", .{ path, @errorName(err) });
        return null;
    };
    defer gpa.free(contents);

    return std.json.parseFromSlice(std.json.Value, gpa, contents, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSON ({s})", .{ path, @errorName(err) });
        return null;
    };
}

pub fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

pub fn jsonStringEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .string => |actual| std.mem.eql(u8, actual, expected),
        else => false,
    };
}

/// Returns the body of the `## <heading>` section of a Markdown document,
/// ending at the next `## ` heading or end of file. The slice points into
/// `contents`, so it shares its lifetime.
pub fn sectionBody(contents: []const u8, heading: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, contents, heading) orelse return null;
    const after = contents[start + heading.len ..];
    const end = std.mem.indexOf(u8, after, "\n## ") orelse after.len;
    return after[0..end];
}

/// Collects the first backtick span of every `- \`...\`` bullet line in
/// `section`. Spans are slices into `section`, so they share its lifetime.
pub fn collectBulletSpans(gpa: std.mem.Allocator, section: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- `")) continue;
        const after_tick = trimmed["- `".len..];
        const close = std.mem.indexOfScalar(u8, after_tick, '`') orelse continue;
        try out.append(gpa, after_tick[0..close]);
    }
}
