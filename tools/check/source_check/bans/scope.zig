//! File-scope resolution for the source-check ban engine.

const std = @import("std");
const util = @import("../util.zig");

/// The files a ban row scans.
pub const Where = union(enum) {
    file: []const u8,
    files: []const []const u8,
    tree: Tree,

    pub const Tree = struct {
        dir: []const u8,
        suffixes: []const []const u8 = &.{},
        recursive: bool = true,
        exclude: []const []const u8 = &.{},
        skip_dirs: []const []const u8 = &.{},
    };
};

/// Filter one shared per-directory inventory through a ban row's own policy.
pub fn collectRowFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    tree: Where.Tree,
    inventories: *std.StringHashMapUnmanaged([]const []const u8),
    out: *std.ArrayList([]const u8),
) !void {
    if (!tree.recursive) return collectFiles(io, arena, root, .{ .tree = tree }, out);
    for (try util.cachedSourceTreeFiles(io, arena, root, tree.dir, inventories)) |path| {
        const sub_path = path[tree.dir.len + 1 ..];
        if (!treeAdmits(tree, sub_path) or treeExcludes(tree, path)) continue;
        try out.append(arena, path);
    }
}

/// Append every repository-relative file path a scope names.
pub fn collectFiles(
    io: std.Io,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    where: Where,
    out: *std.ArrayList([]const u8),
) !void {
    switch (where) {
        .file => |path| try out.append(arena, path),
        .files => |paths| try out.appendSlice(arena, paths),
        .tree => |tree| {
            var dir = try root.openDir(io, tree.dir, .{ .iterate = true });
            defer dir.close(io);
            if (tree.recursive) {
                var walker = try dir.walkSelectively(arena);
                defer walker.deinit();
                while (try walker.next(io)) |entry| {
                    if (entry.kind == .directory) {
                        const repo_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree.dir, entry.path });
                        if (util.sourceTreeDirectory(repo_path) and treeAdmitsDirectory(tree, entry.path)) {
                            try walker.enter(io, entry);
                        }
                        continue;
                    }
                    if (entry.kind != .file or !treeAdmits(tree, entry.path)) continue;
                    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree.dir, entry.path });
                    if (!treeExcludes(tree, path)) try out.append(arena, path);
                }
            } else {
                var it = dir.iterate();
                while (try it.next(io)) |entry| {
                    if (entry.kind != .file or !treeAdmits(tree, entry.name)) continue;
                    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree.dir, entry.name });
                    if (!treeExcludes(tree, path)) try out.append(arena, path);
                }
            }
        },
    }
}

fn treeAdmitsDirectory(tree: Where.Tree, sub_path: []const u8) bool {
    for (tree.skip_dirs) |skip| {
        if (std.mem.indexOf(u8, sub_path, skip) != null) return false;
    }
    return true;
}

fn treeAdmits(tree: Where.Tree, sub_path: []const u8) bool {
    if (!treeAdmitsDirectory(tree, sub_path)) return false;
    if (tree.suffixes.len == 0) return true;
    for (tree.suffixes) |suffix| {
        if (std.mem.endsWith(u8, sub_path, suffix)) return true;
    }
    return false;
}

fn treeExcludes(tree: Where.Tree, repo_path: []const u8) bool {
    for (tree.exclude) |excluded| {
        if (std.mem.eql(u8, repo_path, excluded)) return true;
    }
    return false;
}
