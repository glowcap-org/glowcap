//! Verified product files shared by released and source-built installations.
const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const filename = "share/glowcap/installation.manifest";
pub const max_path_len = 4096;
pub const max_line_len = 64 + 3 + max_path_len + 1;
pub const Entry = struct { path: []const u8, digest: [32]u8, executable: bool };

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var previous: []const u8 = "";
    while (lines.next()) |line| {
        if (line.len == 0 and lines.rest().len == 0) break;
        if (line.len < 68 or line[64] != ' ' or line[66] != ' ' or
            (line[65] != 'x' and line[65] != '-')) return error.InvalidManifest;
        const path = line[67..];
        if (!safePath(path) or std.mem.order(u8, previous, path) != .lt or
            std.mem.eql(u8, path, filename)) return error.InvalidManifest;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, line[0..64]) catch return error.InvalidManifest;
        try entries.append(gpa, .{ .path = path, .digest = digest, .executable = line[65] == 'x' });
        previous = path;
    }
    // The build owns the product inventory. Installation only requires that
    // its selected entry point exists and can execute; every listed component
    // is then verified before activation, without repeating the build manifest.
    for (entries.items) |entry| if (std.mem.eql(u8, entry.path, "bin/glowcap") and entry.executable) {
        return entries.toOwnedSlice(gpa);
    };
    return error.IncompleteProduct;
}

/// Product members are relative, lexical paths. The generator and installer
/// share this rule so the installer never accepts a member the build would not
/// have sealed.
pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_len) return false;
    for (path) |byte| if (byte < 32 or byte == '\\') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// Encode one canonical manifest row. `buffer` must hold `max_line_len` bytes.
pub fn formatEntry(buffer: []u8, entry: Entry) ![]u8 {
    if (!safePath(entry.path) or std.mem.eql(u8, entry.path, filename)) return error.InvalidManifest;
    const digest = std.fmt.bytesToHex(entry.digest, .lower);
    const marker: u8 = if (entry.executable) 'x' else '-';
    return std.fmt.bufPrint(buffer, "{s} {c} {s}\n", .{ digest, marker, entry.path });
}

pub fn isExecutable(permissions: std.Io.File.Permissions) bool {
    return permissions.toMode() & 0o111 != 0;
}

/// Hash one verified regular product file without loading it into memory.
pub fn digestFile(io: Io, dir: Io.Dir, path: []const u8) ![32]u8 {
    if (!safePath(path)) return error.InvalidManifest;
    const file = try dir.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidProductMember;
    var hash = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io, &.{&buffer}, offset);
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset += n;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn verify(io: Io, dir: Io.Dir, entry: Entry) !void {
    const stat = try dir.statFile(io, entry.path, .{ .follow_symlinks = false });
    if (stat.kind != .file) return error.InvalidProductMember;
    const executable = isExecutable(stat.permissions);
    if (executable != entry.executable) return error.InvalidProductPermissions;
    const digest = try digestFile(io, dir, entry.path);
    if (!std.mem.eql(u8, &digest, &entry.digest)) return error.ProductChecksumMismatch;
}

pub fn identity(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "manifest rows reject unsafe paths and require sorted complete products" {
    const digest = std.mem.zeroes([32]u8);
    var row: [max_line_len]u8 = undefined;
    const encoded = try formatEntry(&row, .{ .path = "bin/glowcap", .digest = digest, .executable = true });
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000 x bin/glowcap\n", encoded);
    const entries = try parse(std.testing.allocator, encoded);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(true, entries[0].executable);

    try std.testing.expectError(error.InvalidManifest, formatEntry(&row, .{ .path = "../escape", .digest = digest, .executable = false }));
    try std.testing.expectError(error.InvalidManifest, parse(std.testing.allocator, "0000000000000000000000000000000000000000000000000000000000000000 x bin/glowcap\n" ++
        "0000000000000000000000000000000000000000000000000000000000000000 - README.md\n"));
}
