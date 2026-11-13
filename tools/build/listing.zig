//! Directory listings a registrar reads at configure time.
//!
//! Entry order is the file system's own, and compile-shard ownership walks the
//! graph in registration order, so a registrar that discovers files sorts
//! them. The listing is also a configure input: an entry added or removed
//! reruns the walk that read it.

const std = @import("std");

/// Byte order, the order `sortedFiles` returns.
pub fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// The names of the regular files directly under `dir_path`, a build-root
/// relative path, in byte order. A directory that cannot be read stops
/// configuration.
pub fn sortedFiles(b: *std.Build, dir_path: []const u8) []const []const u8 {
    b.dependOnDirectoryContents(b.path(dir_path));
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err|
        std.debug.panic("{s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (entries.next(io) catch |err|
        std.debug.panic("{s}: {s}", .{ dir_path, @errorName(err) })) |entry|
    {
        if (entry.kind != .file) continue;
        names.append(b.allocator, b.graph.dupeString(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}
