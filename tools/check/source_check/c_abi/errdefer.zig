//! An `errdefer` inside a C-convention function never runs. Such a function
//! returns a result code, not an error union, so no error return ever unwinds
//! it, and the cleanup it promises is dead the moment it compiles. Zig
//! accepts the form silently, which is how a provider listen came to leak its
//! listener on every refusal. A refusal inside an `export fn` or a
//! `callconv(.c)` function releases what it owns by hand, before it returns.
//!
//! Validated against the shape that leaked: an `errdefer` after a
//! `catch return` in an `export fn`, and the same in a `callconv(.c)` function.
//! It does not reach an `errdefer` hidden behind a comment marker on the same
//! line, and it trusts brace balance, so a brace inside a string literal in a
//! C-convention body can shift where it thinks the body ends.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

pub fn checkCConventionErrdefer(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const files = (try util.collectSourceFiles(io, gpa, root, "src", &keepZig)) orelse {
        try appendViolation(gpa, violations, "src: unreadable for the C-convention errdefer check", .{});
        return;
    };
    defer {
        for (files) |path| gpa.free(path);
        gpa.free(files);
    }
    for (files) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 22)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the C-convention errdefer check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var found: std.ArrayList(usize) = .empty;
        defer found.deinit(gpa);
        try deadErrdeferLines(gpa, contents, &found);
        for (found.items) |line| {
            try appendViolation(gpa, violations, "{s}:{d}: errdefer inside a C-convention function never runs; release what the refusal owns by hand before returning", .{ path, line });
        }
    }
}

fn keepZig(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

/// One-based line numbers of every `errdefer` that sits in the body of a
/// function declared `export fn` or `callconv(.c)`, outside any nested
/// function that can itself return an error.
fn deadErrdeferLines(gpa: std.mem.Allocator, contents: []const u8, out: *std.ArrayList(usize)) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const header_end = functionHeaderEnd(lines.items, i) orelse continue;
        if (!isCConvention(lines.items[i..header_end])) {
            continue;
        }
        // Walk the body by brace depth. A nested error-returning function's
        // body is skipped whole: its errdefers are live.
        var depth: usize = 0;
        var line = i;
        var opened = false;
        while (line < lines.items.len) : (line += 1) {
            const text = lines.items[line];
            const code = codePart(text);
            if (line >= header_end and depth > 0) {
                if (functionHeaderEnd(lines.items, line)) |nested_end| {
                    if (returnsError(lines.items[line..nested_end])) {
                        line = skipBody(lines.items, line, nested_end);
                        continue;
                    }
                }
                if (std.mem.indexOf(u8, code, "errdefer") != null) try out.append(gpa, line + 1);
            }
            for (code) |ch| switch (ch) {
                '{' => {
                    depth += 1;
                    opened = true;
                },
                '}' => depth -|= 1,
                else => {},
            };
            if (opened and depth == 0) break;
        }
        i = line;
    }
}

/// If `start` opens a function declaration, the index one past the line that
/// ends its header (the line carrying the opening brace). Otherwise null.
fn functionHeaderEnd(lines: []const []const u8, start: usize) ?usize {
    const first = std.mem.trimStart(u8, lines[start], " \t");
    const is_fn = std.mem.startsWith(u8, first, "fn ") or
        std.mem.startsWith(u8, first, "pub fn ") or
        std.mem.startsWith(u8, first, "export fn ") or
        std.mem.startsWith(u8, first, "pub export fn ") or
        std.mem.startsWith(u8, first, "inline fn ") or
        std.mem.startsWith(u8, first, "pub inline fn ");
    if (!is_fn) return null;
    var line = start;
    while (line < lines.len) : (line += 1) {
        const code = codePart(lines[line]);
        if (std.mem.indexOfScalar(u8, code, '{') != null) return line + 1;
        // A prototype or a one-line `fn` type ends without a body.
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, code, " \t"), ";")) return null;
    }
    return null;
}

fn isCConvention(header: []const []const u8) bool {
    for (header) |line| {
        const code = codePart(line);
        if (std.mem.indexOf(u8, code, "export fn ") != null) return true;
        if (std.mem.indexOf(u8, code, "callconv(.c)") != null) return true;
    }
    return false;
}

fn returnsError(header: []const []const u8) bool {
    for (header) |line| {
        const code = codePart(line);
        // The return type sits after the parameter list's `)`; an error
        // union there carries `!`.
        if (std.mem.lastIndexOfScalar(u8, code, ')')) |close| {
            if (std.mem.indexOfScalar(u8, code[close..], '!') != null) return true;
        }
    }
    return false;
}

/// The line index of the closing brace of the body whose header ends at
/// `header_end`, starting from `open` (the header's first line).
fn skipBody(lines: []const []const u8, open: usize, header_end: usize) usize {
    var depth: usize = 0;
    var line = open;
    while (line < lines.len) : (line += 1) {
        for (codePart(lines[line])) |ch| switch (ch) {
            '{' => depth += 1,
            '}' => depth -|= 1,
            else => {},
        };
        if (line + 1 >= header_end and depth == 0) return line;
    }
    return lines.len - 1;
}

/// The part of a line before any `//` comment.
fn codePart(line: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
}

test "an errdefer in an export fn is dead and reported; a nested error-returning fn keeps its own" {
    const source =
        \\pub export fn provider_listen(out: ?*Out) i32 {
        \\    const listener = open() catch return -1;
        \\    errdefer listener.deinit(); // dead
        \\    const Helper = struct {
        \\        fn make(a: std.mem.Allocator) !*Row {
        \\            const row = try a.create(Row);
        \\            errdefer a.destroy(row);
        \\            return row;
        \\        }
        \\    };
        \\    _ = Helper;
        \\    return 0;
        \\}
        \\
        \\fn plain(out: *Out) callconv(.c) i32 {
        \\    errdefer out.reset();
        \\    return 0;
        \\}
        \\
        \\pub fn native(a: std.mem.Allocator) !void {
        \\    const x = try a.create(u8);
        \\    errdefer a.destroy(x);
        \\}
    ;
    var found: std.ArrayList(usize) = .empty;
    defer found.deinit(std.testing.allocator);
    try deadErrdeferLines(std.testing.allocator, source, &found);
    try std.testing.expectEqualSlices(usize, &.{ 3, 16 }, found.items);
}
