//! Human pages and site scripts name reproducible paths, never the ignored
//! `.local/` checkout home.
const std = @import("std");
const source_tree = @import("../source_tree.zig");
const violation_log = @import("../violation_log.zig");
const corpus = @import("corpus.zig");

pub fn check(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8)) !void {
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    for (try corpus.load(io, arena, root, violations, gpa)) |entry| {
        if (entry.doc.audience != .human) continue;
        try checkText(gpa, violations, entry.path, entry.text);
    }
    const scripts = try source_tree.collectSourceFiles(io, arena, root, "site/scripts", isScript) orelse return error.FileNotFound;
    for (scripts) |path| {
        const text = try root.readFileAlloc(io, path, arena, .limited(4 << 20));
        try checkText(gpa, violations, path, text);
    }
}

fn isScript(_: []const u8) bool {
    return true;
}
fn checkText(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (localRepoPath(line)) {
            try violation_log.appendViolation(gpa, violations, "{s}:{d}: names an ignored .local/ path; use a reproducible path (doc-drift)", .{ path, number });
        }
    }
}
/// Home installation/state paths are public interfaces, not checkout scratch.
fn localRepoPath(line: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, ".local/")) |start| {
        at = start + ".local/".len;
        const prefix = line[0..start];
        if (std.mem.endsWith(u8, prefix, "~/") or
            std.mem.endsWith(u8, prefix, "$HOME/") or
            std.mem.endsWith(u8, prefix, "${HOME}/")) continue;
        return true;
    }
    return false;
}

test "a checkout .local path is a violation on any checked surface" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkText(gpa, &violations, "page.md", "Use `.local/demo`.\nInstall under ~/.local/bin.");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try checkText(gpa, &violations, "capture.ts", "'.local/demo'");
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
}

test "home paths are distinct from repository scratch" {
    try std.testing.expect(!localRepoPath("$HOME/.local/bin and ~/.local/lib"));
    try std.testing.expect(!localRepoPath("${HOME}/.local/state"));
    try std.testing.expect(localRepoPath("~/.local/bin then .local/notes"));
    try std.testing.expect(localRepoPath("../.local/state"));
}
