//! Install a complete product as an immutable generation and select it on PATH.
//! Existing generations stay in place for running processes and rollback.
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const types = @import("../cmd/types.zig");
const paths = @import("../operability/path_io.zig");
const installation = @import("../operability/installation.zig");
const manifest = @import("manifest.zig");
const log = @import("../operability/log.zig");
const Io = std.Io;

pub const command: types.Command = .{
    .name = "install",
    .short_help = "Install this complete product into a prefix and keep previous versions",
    .inherit_flags = false,
    .flags = &.{.{ .long = "prefix", .help = "Installation prefix (default $HOME/.local)", .kind = .string_flag }},
    .run = run,
};

fn run(ctx: *Ctx, parsed: *types.Parsed) !u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    const root = try installation.prefix(ctx);
    defer ctx.gpa.free(root);
    const destination = parsed.flagString("prefix") orelse blk: {
        const home = ctx.environ.get("HOME") orelse {
            log.err(ctx.io, "HOME is unset. Provide --prefix", .{});
            return error.Usage;
        };
        if (home.len == 0) return error.Usage;
        break :blk try std.fs.path.join(gpa, &.{ home, ".local" });
    };
    if (destination.len == 0) return error.Usage;
    const selected = @import("../operability/signals.zig").interruptible([]const u8, ctx.io, install, .{ ctx.io, gpa, root, destination }) catch |err| {
        log.err(ctx.io, "installation failed: {s}. Existing installations were not replaced", .{@errorName(err)});
        return 1;
    };
    try @import("../argv.zig").writeStdout(ctx.io, try std.fmt.allocPrint(gpa, "Installed {s}\nAdd {s} to PATH. Previous versions remain under {s}/lib/glowcap.\n", .{ selected, std.fs.path.dirname(selected).?, destination }));
    return 0;
}

pub fn install(io: Io, gpa: std.mem.Allocator, source: []const u8, destination: []const u8) ![]const u8 {
    const cwd = Io.Dir.cwd();
    const current = try std.process.currentPathAlloc(io, gpa);
    const root = try std.fs.path.resolve(gpa, &.{ current, destination });
    const managed = try std.fs.path.join(gpa, &.{ root, "lib/glowcap" });
    const link = try std.fs.path.join(gpa, &.{ root, "bin/glowcap" });
    const input = try cwd.openDir(io, source, .{});
    defer input.close(io);
    const bytes = try input.readFileAlloc(io, manifest.filename, gpa, .limited(4 * 1024 * 1024));
    const entries = try manifest.parse(gpa, bytes);
    const id = manifest.identity(bytes);
    const generation = try std.fs.path.join(gpa, &.{ managed, &id });
    try paths.ensureDirPath(io, managed);
    var lock = try @import("../operability/state_lock.zig").tryAcquire(io, managed);
    defer lock.deinit();
    try refuseForeignLink(io, link);
    if (cwd.openDir(io, generation, .{})) |existing| {
        defer existing.close(io);
        const receipt = try existing.readFileAlloc(io, manifest.filename, gpa, .limited(4 * 1024 * 1024));
        if (!std.mem.eql(u8, receipt, bytes)) return error.ProductChecksumMismatch;
        for (entries) |entry| try manifest.verify(io, existing, entry);
    } else |err| switch (err) {
        error.FileNotFound => {
            var random: [16]u8 = undefined;
            try io.randomSecure(&random);
            const stage = try std.fmt.allocPrint(gpa, "{s}/.install-{s}", .{ managed, std.fmt.bytesToHex(random, .lower) });
            try cwd.createDir(io, stage, .fromMode(0o755));
            defer cwd.deleteTree(io, stage) catch |cleanup_err| {
                log.err(io, "could not remove temporary installation {s}: {s}", .{ stage, @errorName(cleanup_err) });
            };
            const output = try cwd.openDir(io, stage, .{});
            defer output.close(io);
            try copyVerified(io, input, output, bytes, entries);
            try cwd.renamePreserve(stage, cwd, generation, io);
        },
        else => return err,
    }
    try paths.ensureParentDir(io, link);
    try refuseForeignLink(io, link);
    const target = try std.fmt.allocPrint(gpa, "../lib/glowcap/{s}/bin/glowcap", .{id});
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const pending = try std.fmt.allocPrint(gpa, "{s}/bin/.glowcap-{s}", .{ root, std.fmt.bytesToHex(random, .lower) });
    try cwd.symLink(io, target, pending, .{});
    defer cwd.deleteFile(io, pending) catch |err| {
        if (err != error.FileNotFound) log.err(io, "could not remove temporary selection {s}: {s}", .{ pending, @errorName(err) });
    };
    try cwd.rename(pending, cwd, link, io);
    return link;
}

/// Copy only the recorded product files into a caller-owned empty directory.
/// Image construction uses the same verification as host installation, so
/// extra build files never become runtime payload and concurrent rebuilds can
/// only fail verification, never produce a silently mixed image.
pub fn snapshot(io: Io, gpa: std.mem.Allocator, source: []const u8, output: Io.Dir) !void {
    const input = try Io.Dir.cwd().openDir(io, source, .{});
    defer input.close(io);
    const bytes = try input.readFileAlloc(io, manifest.filename, gpa, .limited(4 * 1024 * 1024));
    const entries = try manifest.parse(gpa, bytes);
    try copyVerified(io, input, output, bytes, entries);
}

fn copyVerified(io: Io, input: Io.Dir, output: Io.Dir, bytes: []const u8, entries: []const manifest.Entry) !void {
    for (entries) |entry| {
        const stat = try input.statFile(io, entry.path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidProductMember;
        if (manifest.isExecutable(stat.permissions) != entry.executable) return error.InvalidProductPermissions;
        try input.copyFile(entry.path, output, entry.path, io, .{
            .make_path = true,
            .replace = false,
            .permissions = .fromMode(if (entry.executable) 0o755 else 0o644),
        });
        try manifest.verify(io, output, entry);
    }
    try output.createDirPath(io, "share/glowcap");
    const receipt = try output.createFile(io, manifest.filename, .{ .exclusive = true, .permissions = .fromMode(0o644) });
    defer receipt.close(io);
    try receipt.writeStreamingAll(io, bytes);
}

fn refuseForeignLink(io: Io, path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().readLink(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.UnmanagedExecutable,
    };
    const target = buf[0..n];
    const start = "../lib/glowcap/";
    const end = "/bin/glowcap";
    if (target.len != start.len + 64 + end.len or !std.mem.startsWith(u8, target, start) or
        !std.mem.endsWith(u8, target, end)) return error.UnmanagedExecutable;
    for (target[start.len .. start.len + 64]) |c| if (!std.ascii.isHex(c)) return error.UnmanagedExecutable;
}
