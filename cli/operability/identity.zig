//! Host identity seed files for the pancake CLI.
const std = @import("std");
const pancake = @import("pancake");
const exit_codes = @import("../exit_codes.zig");
const log = @import("log.zig");
const xdg = @import("xdg.zig");

const crypto = pancake.foundation.crypto;
const Io = std.Io;

pub const seed_bytes = 32;

/// Resolve the identity path for load/ensure (may return legacy config path).
pub fn defaultIdentityPath(io: Io, buf: []u8, environ: *const std.process.Environ.Map, posture: xdg.StatePosture) ![]const u8 {
    return xdg.defaultIdentityPath(io, buf, environ, posture);
}

/// Resolve the path `init` should mint (XDG state; never legacy config).
pub fn mintIdentityPath(buf: []u8, environ: *const std.process.Environ.Map, posture: xdg.StatePosture) ![]const u8 {
    return xdg.mintIdentityPath(buf, environ, posture);
}

pub fn ensureParentDir(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
}

pub fn mint(io: Io, path: []const u8) !crypto.SecretKey {
    var seed: [seed_bytes]u8 = undefined;
    io.randomSecure(&seed) catch return error.EntropyFailed;
    try ensureParentDir(io, path);
    const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &seed);
    return crypto.SecretKey.fromSeed(seed);
}

pub fn load(io: Io, path: []const u8) !crypto.SecretKey {
    var seed: [seed_bytes]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, path, &seed) catch |e| switch (e) {
        error.FileNotFound => {
            log.err(io, "identity file not found: {s} (run `pancake init`)", .{path});
            return error.IdentityMissing;
        },
        else => return e,
    };
    if (got.len != seed_bytes) {
        log.err(io, "identity file {s} is not {d} bytes", .{ path, seed_bytes });
        return error.IdentityCorrupt;
    }
    return crypto.SecretKey.fromSeed(seed);
}

pub fn loadOrMint(io: Io, path: []const u8) !crypto.SecretKey {
    return load(io, path) catch |e| switch (e) {
        error.IdentityMissing => {
            log.info(io, "minting new identity at {s}", .{path});
            return mint(io, path);
        },
        else => e,
    };
}

pub fn mapLoadError(err: anyerror) u8 {
    return switch (err) {
        error.IdentityMissing, error.IdentityCorrupt, error.EntropyFailed => exit_codes.identity,
        else => exit_codes.internal,
    };
}
