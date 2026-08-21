//! Directory creation at product I/O boundaries.
//!
//! A byte-for-byte copy of `cli/operability/path_io.zig` below the header, held
//! identical by `zig build source-check`. It is copied rather than imported
//! because this application's whole claim is that it is an *ordinary consumer*
//! of pancake: it wraps the caller-owned `Peer` and `Vat` and reaches for
//! nothing else in the repository. Importing a module rooted in `cli/` would
//! make that claim false, and the helper works around a Zig standard-library
//! wart rather than anything pancake owns, so it does not belong on pancake's
//! public surface either.
//!
//! `createDirPath` creates missing paths through symlinked parents, but asking
//! it to create an existing symlink to a directory (macOS `/tmp`) returns
//! `NotDir`. Probe with `openDir` first, which follows directory symlinks.

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
