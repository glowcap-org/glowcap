//! Every doc we write, read once, with the kind and audience `kinds.zig`
//! gives it.

const std = @import("std");
const util = @import("../util.zig");
const kinds = @import("kinds.zig");

pub const Entry = struct { path: []const u8, text: []const u8, doc: kinds.Doc };

/// The root docs and every doc under `kinds.doc_trees`, allocated in `arena`.
pub fn load(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    gpa: std.mem.Allocator,
) ![]const Entry {
    var paths: std.ArrayList([]const u8) = .empty;
    for (kinds.root_docs) |path| try paths.append(arena, path);
    for (kinds.doc_trees) |tree| {
        const files = try util.collectSourceFiles(io, arena, root, tree, kinds.isDoc) orelse continue;
        for (files) |path| try paths.append(arena, path);
    }
    var entries: std.ArrayList(Entry) = .empty;
    for (paths.items) |path| {
        const text = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| switch (err) {
            // tolerant: a root doc this checkout does not carry holds nothing.
            error.FileNotFound => continue,
            else => {
                try util.appendViolation(gpa, violations, "{s}: cannot read it to check it as a doc ({s})", .{ path, @errorName(err) });
                continue;
            },
        };
        try entries.append(arena, .{ .path = path, .text = text, .doc = kinds.classify(path, text) });
    }
    return entries.items;
}
