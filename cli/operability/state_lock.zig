//! Single-writer flock for CapTP product identity/state (ADR-0084).
//!
//! Product layout locks `$PANCAKE_STATE/lock` (beside `…/identity`) for the
//! process lifetime so two fronts cannot mint/rotate identity or clobber
//! session sidecar state concurrently. A loose `--identity` seed locks
//! `<path>.lock` beside the file instead. Released on process exit (and
//! explicitly on `Guard.deinit`).
const std = @import("std");
const exit_codes = @import("../exit_codes.zig");
const log = @import("log.zig");
const path_io = @import("path_io.zig");

const Io = std.Io;

pub const Guard = struct {
    io: Io,
    file: Io.File,

    pub fn deinit(self: *Guard) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

/// Directory that owns the identity file (parent of `…/identity`).
pub fn stateDirOfIdentity(identity_path: []const u8) []const u8 {
    return std.fs.path.dirname(identity_path) orelse ".";
}

/// Lock path for an identity seed.
///
/// Product layout (`$PANCAKE_STATE/identity`) locks `$PANCAKE_STATE/lock` so the
/// whole state dir is single-writer. A loose `--identity` file (not named
/// `identity`) locks `<path>.lock` beside the seed so two seeds under `/tmp`
/// do not contend on `/tmp/lock`.
pub fn lockPathForIdentity(buf: []u8, identity_path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(identity_path);
    if (std.mem.eql(u8, base, "identity")) {
        const dir = stateDirOfIdentity(identity_path);
        return try std.fmt.bufPrint(buf, "{s}/lock", .{dir});
    }
    return try std.fmt.bufPrint(buf, "{s}.lock", .{identity_path});
}

fn lockPath(buf: []u8, state_dir: []const u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}/lock", .{state_dir});
}

/// Non-blocking exclusive acquire on `state_dir/lock`. Prefer
/// `tryAcquireForIdentity` when the caller holds an identity path.
pub fn tryAcquire(io: Io, state_dir: []const u8) !Guard {
    try path_io.ensureDirPath(io, state_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try lockPath(&path_buf, state_dir);
    return tryAcquirePath(io, path);
}

/// Non-blocking exclusive acquire for the identity at `identity_path`.
pub fn tryAcquireForIdentity(io: Io, identity_path: []const u8) !Guard {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try lockPathForIdentity(&path_buf, identity_path);
    try path_io.ensureParentDir(io, path);
    return tryAcquirePath(io, path);
}

fn tryAcquirePath(io: Io, path: []const u8) !Guard {
    const file = Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.Busy,
        else => return err,
    };
    return .{ .io = io, .file = file };
}

pub fn mapError(err: anyerror) u8 {
    return switch (err) {
        error.Busy => exit_codes.busy,
        else => exit_codes.internal,
    };
}

/// Refuse a failed state-lock acquire, saying what went wrong.
///
/// Another pancake holding the lock is the expected case and reads as such.
/// Anything else is almost always the state directory being unwritable, and
/// that used to exit silently: `init` is the first command in the quickstart,
/// so a bare exit code and no output leaves a new user with nothing to go on.
pub fn refuseLockFailure(io: Io, err: anyerror, identity_path: []const u8) u8 {
    if (err == error.Busy) {
        log.err(io, "identity is locked by another pancake process", .{});
        return exit_codes.busy;
    }
    log.err(io, "cannot lock the state directory for identity {s}: {s}", .{ identity_path, @errorName(err) });
    return exit_codes.internal;
}
