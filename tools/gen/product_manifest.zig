//! Seal a complete staged product for `glowcap install`.
//!
//! `tools/build/release/stage.zig` invokes this host tool inside its staging
//! transaction, immediately before publishing the directory. The installation
//! manifest module owns the row format, path policy, permission rule, and
//! streaming digest; this tool owns only filesystem enumeration.

const std = @import("std");
const manifest = @import("installation_manifest");

const GeneratedEntry = struct {
    path: []const u8,
    digest: [32]u8,
    executable: bool,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const root_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.debug.print("product-manifest: cannot open `{s}`: {t}\n", .{ root_path, err });
        std.process.exit(1);
    };
    defer root.close(io);
    generate(io, gpa, root) catch |err| {
        std.debug.print("product-manifest: cannot seal `{s}`: {t}\n", .{ root_path, err });
        std.process.exit(1);
    };
}

pub fn generate(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir) !void {
    var entries: std.ArrayList(GeneratedEntry) = .empty;
    defer {
        for (entries.items) |entry| gpa.free(entry.path);
        entries.deinit(gpa);
    }

    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.InvalidProductMember;
        if (!manifest.safePath(entry.path)) return error.InvalidManifest;
        if (std.mem.eql(u8, entry.path, manifest.filename)) return error.ManifestAlreadyPresent;
        const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidProductMember;
        try entries.append(gpa, .{
            .path = try gpa.dupe(u8, entry.path),
            .digest = try manifest.digestFile(io, root, entry.path),
            .executable = manifest.isExecutable(stat.permissions),
        });
    }

    std.mem.sort(GeneratedEntry, entries.items, {}, lessThan);
    var output = try root.createFile(io, manifest.filename, .{
        .exclusive = true,
        .permissions = .fromMode(0o644),
        .resolve_beneath = true,
    });
    defer output.close(io);
    var row: [manifest.max_line_len]u8 = undefined;
    for (entries.items) |entry| {
        const encoded = try manifest.formatEntry(&row, .{
            .path = entry.path,
            .digest = entry.digest,
            .executable = entry.executable,
        });
        try output.writeStreamingAll(io, encoded);
    }
}

fn lessThan(_: void, lhs: GeneratedEntry, rhs: GeneratedEntry) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn usage() noreturn {
    std.debug.print("usage: product-manifest <staged-product-directory>\n", .{});
    std.process.exit(2);
}

test "generation seals sorted regular files with executable bits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "share/glowcap");
    {
        var executable = try tmp.dir.createFile(io, "bin/glowcap", .{ .permissions = .fromMode(0o755) });
        defer executable.close(io);
        try executable.writeStreamingAll(io, "glowcap executable\n");
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "product readme\n" });

    try generate(io, std.testing.allocator, tmp.dir);
    const bytes = try tmp.dir.readFileAlloc(io, manifest.filename, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(bytes);
    const readme_offset = std.mem.indexOf(u8, bytes, " README.md\n") orelse return error.TestExpectedEqual;
    const executable_offset = std.mem.indexOf(u8, bytes, " x bin/glowcap\n") orelse return error.TestExpectedEqual;
    try std.testing.expect(readme_offset < executable_offset);
    const entries = try manifest.parse(std.testing.allocator, bytes);
    defer std.testing.allocator.free(entries);
    for (entries) |entry| try manifest.verify(io, tmp.dir, entry);
}

test "generation rejects symlink product members" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "share/glowcap");
    try tmp.dir.writeFile(io, .{ .sub_path = "regular", .data = "data" });
    try tmp.dir.symLink(io, "regular", "linked", .{});
    try std.testing.expectError(error.InvalidProductMember, generate(io, std.testing.allocator, tmp.dir));
}
