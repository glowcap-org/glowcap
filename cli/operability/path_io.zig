//! Directory creation at product I/O boundaries.
//!
//! Zig 0.16's `createDirPath` correctly creates a missing path through a
//! symlinked parent, but asking it to "create" an already-existing symlink to a
//! directory (macOS `/tmp`) returns `NotDir`. Probe with `openDir` first, which
//! follows directory symlinks, and only create when the path is absent.

const std = @import("std");

const Io = std.Io;

pub fn ensureDirPath(io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.openDir(io, path, .{})) |dir| {
        dir.close(io);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    cwd.createDirPath(io, path) catch |err| switch (err) {
        // Another creator may have won between the open and mkdir. Verify the
        // winner is a directory rather than accepting an arbitrary collision.
        error.PathAlreadyExists => {
            const dir = try cwd.openDir(io, path, .{});
            dir.close(io);
        },
        else => return err,
    };
}

pub fn ensureParentDir(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try ensureDirPath(io, dir);
}
