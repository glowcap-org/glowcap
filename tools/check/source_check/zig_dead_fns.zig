//! Private Zig functions with no caller as a checked surface.
//!
//! Zig analyzes a function only when something references it, so a private
//! function that lost its last caller compiles without complaint and stays
//! in the tree as dead weight. A non-`pub` function is visible only in its
//! own file, so the rule is local: every `fn` declared without `pub` in a
//! `src/` file is named by that file's code (not its comments) somewhere
//! other than its declaration.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

pub fn checkZigDeadPrivateFns(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: cannot be opened for the dead-function check ({s})", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the dead-function check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        try checkFile(gpa, violations, path, contents);
    }
}

fn checkFile(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var uses: std.StringHashMap(usize) = .init(gpa);
    defer uses.deinit();
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const code = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        var i: usize = 0;
        while (i < code.len) {
            if (!isIdentStart(code[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < code.len and isIdentChar(code[i])) i += 1;
            const slot = try uses.getOrPut(code[start..i]);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
        }
    }

    var line_no: usize = 0;
    lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const name = privateFnName(line) orelse continue;
        if ((uses.get(name) orelse 0) > 1) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}:{d}: private fn `{s}` has no caller in its file (delete it, or the dead path it served)",
            .{ path, line_no, name },
        );
    }
}

/// The name a line declares with `fn` and no `pub`, including `inline fn`.
/// A `pub`, `extern`, or `export` declaration is visible beyond the file
/// and is not this check's subject.
fn privateFnName(line: []const u8) ?[]const u8 {
    var t = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "inline ")) t = t["inline ".len..];
    if (!std.mem.startsWith(u8, t, "fn ")) return null;
    const rest = t["fn ".len..];
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const name = rest[0..open];
    if (name.len == 0) return null;
    for (name) |c| if (!isIdentChar(c)) return null;
    return name;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "a private fn named only by its declaration or a comment is dead" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |m| gpa.free(m);
        violations.deinit(gpa);
    }
    try checkFile(gpa, &violations, "src/a.zig", "fn used() void {}\npub fn api() void {\n    used();\n}\ninline fn alsoUsed() void {}\nconst x = alsoUsed;\n");
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try checkFile(gpa, &violations, "src/a.zig", "/// Calls `dead`.\nfn dead() void {} // dead\npub fn api() void {}\n");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "src/a.zig:2: private fn `dead`") != null);
}
