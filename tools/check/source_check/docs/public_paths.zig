//! Human pages expose reproducible paths and reader names. Persona names
//! belong to agent instructions; `kinds.zig` owns the audience boundary.
const std = @import("std");
const util = @import("../util.zig");
const corpus = @import("corpus.zig");

pub fn check(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8)) !void {
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const files = try util.collectSourceFiles(io, arena, root, ".agents/personas", isPersona) orelse return error.FileNotFound;
    var slugs: std.ArrayList([]const u8) = .empty;
    for (files) |path| {
        const base = std.fs.path.basename(path);
        try slugs.append(arena, base[0 .. base.len - 3]);
    }
    for (try corpus.load(io, arena, root, violations, gpa)) |entry| {
        if (entry.doc.audience != .human) continue;
        try checkText(gpa, violations, entry.path, entry.text, slugs.items, true);
    }
    const scripts = try util.collectSourceFiles(io, arena, root, "site/scripts", isScript) orelse return error.FileNotFound;
    for (scripts) |path| {
        const text = try root.readFileAlloc(io, path, arena, .limited(4 << 20));
        try checkText(gpa, violations, path, text, slugs.items, false);
    }
}

fn isPersona(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") and !std.mem.eql(u8, std.fs.path.basename(path), "README.md");
}
fn isScript(_: []const u8) bool {
    return true;
}
fn checkText(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, text: []const u8, slugs: []const []const u8, human: bool) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (human and localRepoPath(line)) {
            try util.appendViolation(gpa, violations, "{s}:{d}: human page names an ignored .local/ path; use a reproducible path (doc-drift)", .{ path, number });
        }
        for (slugs) |slug| {
            if (containsSlug(line, slug)) try util.appendViolation(gpa, violations, "{s}:{d}: agent persona `{s}` appears on a human surface; use a reader name (project-values)", .{ path, number, slug });
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

fn containsSlug(line: []const u8, slug: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, slug)) |start| {
        at = start + slug.len;
        if ((start == 0 or !nameByte(line[start - 1])) and (at == line.len or !nameByte(line[at]))) return true;
    }
    return false;
}
fn nameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

test "human paths and persona slugs follow audience and word edges" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkText(gpa, &violations, "page.md", "Use `.local/demo`.\nHello review-lens.", &.{"review-lens"}, true);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try checkText(gpa, &violations, "capture.ts", "'.local/demo'\n'other-review-lens'", &.{"review-lens"}, false);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try checkText(gpa, &violations, "capture.ts", "nick: 'review-lens'", &.{"review-lens"}, false);
    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
}

test "home paths are distinct from repository scratch" {
    try std.testing.expect(!localRepoPath("$HOME/.local/bin and ~/.local/lib"));
    try std.testing.expect(!localRepoPath("${HOME}/.local/state"));
    try std.testing.expect(localRepoPath("~/.local/bin then .local/notes"));
    try std.testing.expect(localRepoPath("../.local/state"));
}
