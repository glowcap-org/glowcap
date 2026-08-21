//! Own the rendered site directory between Zine runs.
//!
//! Zine's force flag suppresses its confirmation prompt but does not replace
//! existing files. This tool clears only output that is known to be generated:
//! the canonical `zig-out/site` directory or a directory carrying the marker
//! written after a previous successful render.

const std = @import("std");

const marker_name = ".pancake-site";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return usage();
    const install_prefix = args.next() orelse return usage();
    const source_root = args.next() orelse return usage();
    if (args.next() != null) return usage();

    if (std.mem.eql(u8, mode, "clear")) {
        try clearOutput(gpa, init.environ_map, io, install_prefix, source_root);
    } else if (std.mem.eql(u8, mode, "mark")) {
        try markOutput(io, install_prefix);
    } else {
        return usage();
    }
}

fn usage() noreturn {
    std.debug.print("usage: site-output-owner <clear|mark> <install-prefix> <site-source-root>\n", .{});
    std.process.exit(2);
}

fn markOutput(io: std.Io, install_prefix: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, install_prefix, .{}) catch |err| {
        std.debug.print("site-output-owner: unable to open site install prefix `{s}`: {t}\n", .{ install_prefix, err });
        std.process.exit(1);
    };
    defer dir.close(io);

    var out = dir.openDir(io, "site", .{}) catch |err| {
        std.debug.print("site-output-owner: site output missing after render: {t}\n", .{err});
        std.process.exit(1);
    };
    defer out.close(io);

    const file = out.createFile(io, marker_name, .{}) catch |err| {
        std.debug.print("site-output-owner: unable to write the `{s}` marker: {t}\n", .{ marker_name, err });
        std.process.exit(1);
    };
    file.close(io);
}

fn clearOutput(
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    io: std.Io,
    install_prefix: []const u8,
    source_root: []const u8,
) !void {
    const prefix_dir: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, install_prefix, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            std.debug.print("site-output-owner: unable to open site install prefix `{s}`: {t}\n", .{ install_prefix, err });
            std.process.exit(1);
        },
    };
    defer if (prefix_dir) |dir| dir.close(io);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buffer) catch |err| {
        std.debug.print("site-output-owner: unable to resolve current directory: {t}\n", .{err});
        std.process.exit(1);
    };
    const cwd_path = cwd_buffer[0..cwd_len];

    var prefix_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_path = if (prefix_dir) |dir| prefix: {
        const prefix_len = dir.realPath(io, &prefix_buffer) catch |err| {
            std.debug.print("site-output-owner: unable to resolve site install prefix `{s}`: {t}\n", .{ install_prefix, err });
            std.process.exit(1);
        };
        break :prefix prefix_buffer[0..prefix_len];
    } else resolveProspectiveDirectory(gpa, environ_map, io, cwd_path, install_prefix) catch |err| {
        std.debug.print("site-output-owner: unable to resolve prospective site install prefix `{s}`: {t}\n", .{ install_prefix, err });
        std.process.exit(1);
    };

    const output_path = try std.fs.path.resolve(gpa, &.{ prefix_path, "site" });

    var source_dir = std.Io.Dir.cwd().openDir(io, source_root, .{}) catch |err| {
        std.debug.print("site-output-owner: unable to open checked-in site source `{s}`: {t}\n", .{ source_root, err });
        std.process.exit(1);
    };
    defer source_dir.close(io);
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source_len = source_dir.realPath(io, &source_buffer) catch |err| {
        std.debug.print("site-output-owner: unable to resolve checked-in site source `{s}`: {t}\n", .{ source_root, err });
        std.process.exit(1);
    };
    const source_path = source_buffer[0..source_len];

    if (try pathsOverlap(gpa, environ_map, cwd_path, output_path, source_path)) {
        std.debug.print(
            "site-output-owner: refusing to clear generated site output `{s}` because it overlaps checked-in source `{s}`\n",
            .{ output_path, source_path },
        );
        std.process.exit(1);
    }

    const dir = prefix_dir orelse return;
    var out = dir.openDir(io, "site", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.debug.print("site-output-owner: unable to open `{s}`: {t}\n", .{ output_path, err });
            std.process.exit(1);
        },
    };
    const marked = blk: {
        defer out.close(io);
        break :blk if (out.access(io, marker_name, .{})) |_| true else |_| false;
    };

    const repo_root = std.fs.path.dirname(source_path) orelse source_path;
    const canonical = try std.fs.path.resolve(gpa, &.{ repo_root, "zig-out", "site" });
    if (!marked and !std.mem.eql(u8, output_path, canonical)) {
        std.debug.print(
            "site-output-owner: refusing to clear `{s}`: it is neither the canonical `zig-out/site` nor a directory carrying this build's `{s}` marker. Remove it yourself, or choose another --prefix.\n",
            .{ output_path, marker_name },
        );
        std.process.exit(1);
    }

    dir.deleteTree(io, "site") catch |err| {
        std.debug.print("site-output-owner: unable to clear generated site output `{s}`: {t}\n", .{ output_path, err });
        std.process.exit(1);
    };
}

fn resolveProspectiveDirectory(
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    io: std.Io,
    cwd_path: []const u8,
    path: []const u8,
) ![]u8 {
    const absolute = try std.fs.path.resolve(gpa, &.{ cwd_path, path });

    var probe: []const u8 = absolute;
    while (true) {
        var ancestor = std.Io.Dir.cwd().openDir(io, probe, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(probe) orelse return err;
                if (std.mem.eql(u8, parent, probe)) return err;
                probe = parent;
                continue;
            },
            else => return err,
        };
        defer ancestor.close(io);

        var ancestor_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const ancestor_len = try ancestor.realPath(io, &ancestor_buffer);
        const suffix = try std.fs.path.relative(gpa, cwd_path, environ_map, probe, absolute);
        return std.fs.path.resolve(gpa, &.{ ancestor_buffer[0..ancestor_len], suffix });
    }
}

fn pathsOverlap(
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    cwd_path: []const u8,
    a: []const u8,
    b: []const u8,
) !bool {
    return try pathContains(gpa, environ_map, cwd_path, a, b) or try pathContains(gpa, environ_map, cwd_path, b, a);
}

fn pathContains(
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    cwd_path: []const u8,
    parent: []const u8,
    child: []const u8,
) !bool {
    const relative = try std.fs.path.relative(gpa, cwd_path, environ_map, parent, child);
    if (relative.len == 0) return true;
    if (std.fs.path.isAbsolute(relative)) return false;

    var components = std.mem.tokenizeAny(u8, relative, "/\\");
    const first = components.next() orelse return true;
    return !std.mem.eql(u8, first, "..");
}
