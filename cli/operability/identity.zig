//! Host identity seed files for the glowcap CLI.
const std = @import("std");
const glowcap = @import("glowcap");
const exit_codes = @import("../exit_codes.zig");
const log = @import("log.zig");
const path_io = @import("path_io.zig");

const crypto = glowcap.foundation.crypto;
const Io = std.Io;

pub const seed_bytes = 32;

pub fn mint(io: Io, path: []const u8) !crypto.SecretKey {
    var seed: [seed_bytes]u8 = undefined;
    io.randomSecure(&seed) catch return error.EntropyFailed;
    try path_io.ensureParentDir(io, path);
    const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &seed);
    return crypto.SecretKey.fromSeed(seed);
}

pub fn load(io: Io, path: []const u8) !crypto.SecretKey {
    var seed: [seed_bytes]u8 = undefined;
    const got = Io.Dir.cwd().readFile(io, path, &seed) catch |e| switch (e) {
        error.FileNotFound => {
            log.err(io, "identity file not found: {s} (run `glowcap init`)", .{path});
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

/// Refuse a failed load-or-mint, saying which file and why.
///
/// The missing and corrupt cases have already printed something useful by the
/// time they get here. Everything else is a filesystem refusal, usually a state
/// directory nobody can write, and it used to reach the caller as a bare code
/// with no message at all. Worse, callers that reached for the dial mapper
/// reported it as a *dial* failure, which sends the reader looking at the
/// network for a permissions problem.
pub fn refuseSecret(io: Io, err: anyerror, path: []const u8) u8 {
    switch (err) {
        error.IdentityMissing, error.IdentityCorrupt, error.EntropyFailed => {},
        else => log.err(io, "cannot load or create the identity at {s}: {s}", .{ path, @errorName(err) }),
    }
    return mapLoadError(err);
}
