//! Path resolution for markdown link targets, shared by the link and site
//! checks: existence, relative-target resolution, and normalization.

const std = @import("std");

pub fn fileExists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

pub fn resolveMarkdownTarget(gpa: std.mem.Allocator, source_path: []const u8, raw_target: []const u8) !?[]u8 {
    var target = std.mem.trim(u8, raw_target, " \t\r\n");
    if (target.len == 0) return null;
    if (target[0] == '<' and target[target.len - 1] == '>') target = target[1 .. target.len - 1];
    if (target.len == 0 or target[0] == '#') return null;
    if (std.mem.indexOf(u8, target, "://") != null) return null;
    inline for (&.{ "mailto:", "tel:", "data:" }) |scheme| {
        if (std.mem.startsWith(u8, target, scheme)) return null;
    }
    if (std.mem.startsWith(u8, target, "/")) return null;

    const path_end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const target_path = target[0..path_end];
    if (target_path.len == 0) return null;

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ source_dir, target_path });
    defer gpa.free(joined);
    return try normalizeRelativePath(gpa, joined);
}

pub fn normalizeRelativePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                parts.items.len -= 1;
            } else {
                try parts.append(gpa, part);
            }
            continue;
        }
        try parts.append(gpa, part);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

test "resolveMarkdownTarget normalizes local relative links" {
    const allocator = std.testing.allocator;

    const resolved = (try resolveMarkdownTarget(allocator, ".agents/rules/cli.md", "../../.devcontainer/pins.sh#versions")).?;
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(".devcontainer/pins.sh", resolved);

    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "https://example.invalid/docs") == null);
    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "#first-principles") == null);
}
