//! Atomic file replacement and sidecar-lock mechanics for rooms-peer state.

const std = @import("std");
const common = @import("../common.zig");

const Io = common.Io;
const Allocator = common.Allocator;

pub fn pathIn(buf: []u8, dir: []const u8, leaf: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, leaf });
}

/// Read DIR/leaf, or an empty owned slice if it does not exist.
pub fn readFile(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8) ![]u8 {
    var pbuf: [512]u8 = undefined;
    const path = try pathIn(&pbuf, dir, leaf);
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, common.file_cap) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
}

pub fn overwriteFile(io: Io, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
    var pbuf: [512]u8 = undefined;
    const path = try pathIn(&pbuf, dir, leaf);
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

pub fn removeFile(io: Io, dir: []const u8, leaf: []const u8) !void {
    var pbuf: [512]u8 = undefined;
    const path = try pathIn(&pbuf, dir, leaf);
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub const FileLock = struct {
    io: Io,
    file: Io.File,

    pub fn unlock(self: FileLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
    }
};

/// Lock a stable sidecar because replacing the data file changes its inode.
pub fn lockLeaf(io: Io, dir: []const u8, leaf: []const u8) !FileLock {
    return lockLeafMode(io, dir, leaf, false);
}

/// Acquire a sidecar lock without waiting. A busy lock is not a stale PID.
pub fn tryLockLeaf(io: Io, dir: []const u8, leaf: []const u8) !FileLock {
    return lockLeafMode(io, dir, leaf, true);
}

fn lockLeafMode(io: Io, dir: []const u8, leaf: []const u8, nonblocking: bool) !FileLock {
    var lock_leaf_buf: [160]u8 = undefined;
    const lock_leaf = std.fmt.bufPrint(&lock_leaf_buf, "{s}.lock", .{leaf}) catch unreachable;
    var lock_path_buf: [512]u8 = undefined;
    const lock_path = try pathIn(&lock_path_buf, dir, lock_leaf);
    const lock_file = Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = nonblocking,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.Busy,
        else => return err,
    };
    return .{ .io = io, .file = lock_file };
}

/// Append under the same sidecar lock used by compaction rewrites.
pub fn appendLine(io: Io, gpa: Allocator, dir: []const u8, leaf: []const u8, bytes: []const u8) !void {
    const lock = try lockLeaf(io, dir, leaf);
    defer lock.unlock();
    const old = try readFile(io, gpa, dir, leaf);
    defer gpa.free(old);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, old);
    try list.appendSlice(gpa, bytes);
    try list.append(gpa, '\n');
    try overwriteFile(io, dir, leaf, list.items);
}
