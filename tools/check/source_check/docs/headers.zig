//! Holds each doc's OKF header to the schema in `kinds.zig`, and each
//! repository path in its `sources` to the tree, so a moved or deleted file
//! fails here instead of leaving the doc pointing nowhere.

const std = @import("std");
const util = @import("../util.zig");
const kinds = @import("kinds.zig");
const corpus = @import("corpus.zig");

const appendViolation = util.appendViolation;

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for (try corpus.load(io, arena_state.allocator(), root, violations, gpa)) |entry| {
        if (kinds.problem(entry.path, entry.text)) |message| {
            try appendViolation(gpa, violations, "{s}: {s}", .{ entry.path, message });
            continue;
        }
        if (kinds.placeOf(entry.path) == .decides) continue;
        const front = kinds.Frontmatter.of(entry.text) orelse continue;
        var sources = front.sources() orelse continue;
        while (sources.next()) |resource| {
            const path = kinds.sourcePath(resource) orelse continue;
            if (exists(io, root, path)) continue;
            try appendViolation(gpa, violations, "{s}: `sources` names `{s}`, which does not exist{s}", .{
                entry.path, resource, if (std.mem.endsWith(u8, path, "/")) " as a directory" else "; a directory ends in `/`",
            });
        }
    }
}

/// A file, or a directory when the path ends in `/`.
fn exists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "/")) {
        var dir = root.openDir(io, path[0 .. path.len - 1], .{}) catch return false;
        dir.close(io);
        return true;
    }
    const stat = root.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}
