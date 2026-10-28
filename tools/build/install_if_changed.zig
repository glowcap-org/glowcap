//! Install one build output so a consumer sees a new file only when its bytes
//! change. `common.installIfChanged` runs it for every archive a foreign build
//! links by path. Cargo decides freshness by mtime, and Zig 0.17 rewrites a
//! byte-identical output whenever an input's metadata changes: a fresh
//! checkout or a cache restore gives every C source a new inode. The stock
//! install step copies on any mtime difference, so each such rewrite would
//! rerun every Rust build script that watches the archive.
//!
//! Arguments: the source file, the destination directory, then the symlink
//! chain a shared library carries, where the first link names the installed
//! file and each later link names the one before it. The build graph passes
//! every path, so the working directory is never read. A failure exits
//! nonzero with its cause on stderr and leaves the previous installation in
//! place, because the copy replaces the destination atomically.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const source = args.next() orelse return error.InvalidArguments;
    const dest_path = args.next() orelse return error.InvalidArguments;
    const cwd = Io.Dir.cwd();
    var dest_dir = try cwd.createDirPathOpen(init.io, dest_path, .{});
    defer dest_dir.close(init.io);
    const name = Io.Dir.path.basename(source);
    try install(init.io, cwd, source, dest_dir, name);
    var target = name;
    while (args.next()) |link_name| {
        try link(init.io, dest_dir, target, link_name);
        target = link_name;
    }
}

/// Copy `source` to `name` in `dest_dir` unless the destination already holds
/// the same bytes and permissions, in which case it keeps its inode and mtime.
fn install(io: Io, source_dir: Io.Dir, source: []const u8, dest_dir: Io.Dir, name: []const u8) !void {
    const from = try source_dir.openFile(io, source, .{});
    defer from.close(io);
    const from_stat = try from.stat(io);
    if (try holds(io, dest_dir, name, from, from_stat)) return;
    var atomic = try dest_dir.createFileAtomic(io, name, .{ .permissions = from_stat.permissions, .replace = true });
    defer atomic.deinit(io);
    // Creation applies the umask. The source's exact mode is what the next
    // comparison reads, so a mode the umask would narrow still settles.
    try atomic.file.setPermissions(io, from_stat.permissions);
    var reader: Io.File.Reader = .init(from, io, &.{});
    reader.size = from_stat.size;
    var buffer: [64 * 1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return writer.err.?,
    };
    try writer.flush();
    try atomic.replace(io);
}

/// Whether `name` in `dir` is a regular file with `from`'s permissions and bytes.
fn holds(io: Io, dir: Io.Dir, name: []const u8, from: Io.File, from_stat: Io.File.Stat) !bool {
    const to = dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer to.close(io);
    const to_stat = try to.stat(io);
    if (to_stat.kind != .file or to_stat.size != from_stat.size) return false;
    if (to_stat.permissions != from_stat.permissions) return false;
    var from_buffer: [64 * 1024]u8 = undefined;
    var to_buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < from_stat.size) {
        const read = try from.readPositionalAll(io, &from_buffer, offset);
        if (read == 0) return error.SourceTruncated;
        if (try to.readPositionalAll(io, to_buffer[0..read], offset) != read) return false;
        if (!std.mem.eql(u8, from_buffer[0..read], to_buffer[0..read])) return false;
        offset += read;
    }
    return true;
}

/// Point `link_name` at `target`, leaving a link that already does untouched.
fn link(io: Io, dir: Io.Dir, target: []const u8, link_name: []const u8) !void {
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const current_len = dir.readLink(io, link_name, &buffer) catch |err| switch (err) {
        // Absent, or a plain file in the link's place: the atomic link
        // below replaces either.
        error.FileNotFound, error.NotLink => null,
        else => |e| return e,
    };
    if (current_len) |len| if (std.mem.eql(u8, buffer[0..len], target)) return;
    try dir.symLinkAtomic(io, target, link_name, .{});
}

const testing = std.testing;

fn writeSource(dir: Io.Dir, bytes: []const u8) !void {
    // A fresh inode, as a recompile or checkout produces.
    dir.deleteFile(testing.io, "lib.a") catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try dir.writeFile(testing.io, .{ .sub_path = "lib.a", .data = bytes });
}

test "identical bytes keep the installed file's inode and mtime" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.createDirPathOpen(testing.io, "out", .{});
    defer out.close(testing.io);
    try writeSource(tmp.dir, "archive");
    try install(testing.io, tmp.dir, "lib.a", out, "lib.a");
    const before = try out.statFile(testing.io, "lib.a", .{});
    try writeSource(tmp.dir, "archive");
    try install(testing.io, tmp.dir, "lib.a", out, "lib.a");
    const after = try out.statFile(testing.io, "lib.a", .{});
    try testing.expectEqual(before.inode, after.inode);
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

test "changed bytes or permissions replace the installed file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.createDirPathOpen(testing.io, "out", .{});
    defer out.close(testing.io);
    try writeSource(tmp.dir, "archive one");
    try install(testing.io, tmp.dir, "lib.a", out, "lib.a");
    // Same length, so only the byte comparison can see the change.
    try writeSource(tmp.dir, "archive two");
    try install(testing.io, tmp.dir, "lib.a", out, "lib.a");
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("archive two", try out.readFile(testing.io, "lib.a", &buffer));
    if (!Io.File.Permissions.has_executable_bit) return;
    const before = try out.statFile(testing.io, "lib.a", .{});
    try tmp.dir.setFilePermissions(testing.io, "lib.a", .executable_file, .{});
    try install(testing.io, tmp.dir, "lib.a", out, "lib.a");
    const after = try out.statFile(testing.io, "lib.a", .{});
    try testing.expect(before.inode != after.inode);
    try testing.expectEqual((try tmp.dir.statFile(testing.io, "lib.a", .{})).permissions, after.permissions);
    try testing.expect(before.permissions != after.permissions);
}

test "a missing destination is installed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.createDirPathOpen(testing.io, "out", .{});
    defer out.close(testing.io);
    try writeSource(tmp.dir, "archive");
    try install(testing.io, tmp.dir, "lib.a", out, "lib.a");
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("archive", try out.readFile(testing.io, "lib.a", &buffer));
}

test "a link is created, kept when right, and repointed when wrong" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [64]u8 = undefined;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.so", .data = "plain file in the link's place" });
    try link(testing.io, tmp.dir, "lib.so.0", "lib.so");
    try testing.expectEqualStrings("lib.so.0", buffer[0..try tmp.dir.readLink(testing.io, "lib.so", &buffer)]);
    const kept = try tmp.dir.statFile(testing.io, "lib.so", .{ .follow_symlinks = false });
    try link(testing.io, tmp.dir, "lib.so.0", "lib.so");
    try testing.expectEqual(kept.inode, (try tmp.dir.statFile(testing.io, "lib.so", .{ .follow_symlinks = false })).inode);
    try link(testing.io, tmp.dir, "lib.so.1", "lib.so");
    try testing.expectEqualStrings("lib.so.1", buffer[0..try tmp.dir.readLink(testing.io, "lib.so", &buffer)]);
}
