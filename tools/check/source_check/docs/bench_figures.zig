//! Benchmark prose links generated reports instead of copying their figures.
const std = @import("std");
const util = @import("../util.zig");
pub fn check(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8)) !void {
    const path = "bench/README.md";
    const text = try root.readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try checkText(gpa, violations, text);
}
fn checkText(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), text: []const u8) !void {
    const path = "bench/README.md";
    var lines = std.mem.splitScalar(u8, text, '\n');
    var fence = false;
    var number: usize = 0;
    var value = false;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            fence = !fence;
            continue;
        }
        var visible: std.ArrayList(u8) = .empty;
        defer visible.deinit(gpa);
        var at: usize = 0;
        while (at < line.len) {
            const marker = if (value) "<!-- /value -->" else "<!-- value ";
            if (std.mem.indexOfPos(u8, line, at, marker)) |hit| {
                if (!value) try visible.appendSlice(gpa, line[at..hit]);
                at = hit + marker.len;
                value = !value;
            } else {
                if (!value) try visible.appendSlice(gpa, line[at..]);
                break;
            }
        }
        if (!fence and measurement(visible.items)) try util.appendViolation(gpa, violations, "{s}:{d}: hand-copied measurement; link its generated report instead", .{ path, number });
    }
}
fn measurement(line: []const u8) bool {
    var code = false;
    for (line, 0..) |c, i| {
        if (c == '`') code = !code;
        if (code or !std.ascii.isDigit(c)) continue;
        var end = i + 1;
        while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '.' or line[end] == ',')) : (end += 1) {}
        const rest = std.mem.trimStart(u8, line[end..], " \t");
        for ([_][]const u8{ "ns", "µs", "ms", "seconds", "KiB", "MiB", "GiB", "instructions", "sessions", "%", "bytes", "B", "KB", "MB", "GB", "TB", "ops/s", "calls/s", "messages/s", "round trips/s" }) |unit| {
            if (std.mem.startsWith(u8, rest, unit) and (rest.len == unit.len or !std.ascii.isAlphabetic(rest[unit.len]))) return true;
        }
        if (std.mem.startsWith(u8, line, "|") and (rest.len == 0 or rest[0] == '|')) return true;
    }
    return false;
}
test "benchmark measurements stay in generated reports, commands stay runnable" {
    try std.testing.expect(measurement("costs 31.0 µs"));
    try std.testing.expect(measurement("uses 31 bytes"));
    try std.testing.expect(measurement("runs at 10 ops/s"));
    try std.testing.expect(measurement("moves 3 GB/s"));
    try std.testing.expect(measurement("| p50 | 9.71 |"));
    try std.testing.expect(!measurement("use `--live-max=500000`"));
    try std.testing.expect(!measurement("Zig 0.17.0 measures the path"));
}

test "value markers are checked by their owner rather than treated as copied figures" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkText(gpa, &violations, "Limit <!-- value ../src/limit.zig limit bytes -->64 MiB<!-- /value -->.");
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try checkText(gpa, &violations, "Limit 64 MiB.");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
