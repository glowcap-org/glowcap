//! Example wiring: the index agrees with the tables, and every on-disk
//! example is built by them.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// Gate that every Zig example (`examples/zig/*.zig`) and every C example
/// (`examples/c/*.c`) the build compiles has an index entry in
/// `examples/README.md`. That README owns the complete inventory; the public
/// site can recommend a shorter reader path without repeating it.
pub fn checkExampleIndex(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const index = root.readFileAlloc(io, "examples/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "examples/README.md: failed to read for example-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(index);

    const site = root.readFileAlloc(io, "site/content/examples.smd", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "site/content/examples.smd: failed to read for example-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(site);
    if (std.mem.indexOf(u8, site, "examples/README.md") == null) {
        try appendViolation(gpa, violations, "site/content/examples.smd: must link the complete inventory in examples/README.md", .{});
    }

    var dir = root.openDir(io, "examples/zig", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/zig: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        // Every compiled Zig example belongs in the inventory: numbered
        // chapter or helper.

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "zig/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, index, needle) == null) {
            try appendViolation(gpa, violations, "examples/README.md: missing index for `{s}`", .{entry.name});
        }
    }

    // Every C example source is a first-class built program (the examples module compiles
    // and runs each under `zig build examples`), so each must be discoverable from
    // the index too.
    var c_dir = root.openDir(io, "examples/c", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/c: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer c_dir.close(io);

    var c_it = c_dir.iterate();
    while (try c_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "c/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, index, needle) == null) {
            try appendViolation(gpa, violations, "examples/README.md: missing index for `{s}`", .{entry.name});
        }
    }
}

/// `zig build examples` compiles every row of the hand-maintained `zig_examples`
/// and `c_examples` tables in `tools/build/examples.zig`. An example dropped from a table still
/// on disk never runs under `check`; a stale table row points at a missing file
/// and fails at compile time with a less actionable error. Forward: every
/// `examples/zig/*.zig` and `examples/c/*.c` basename appears as a `.path` in
/// the matching table. Reverse: every table `.path` resolves on disk.
pub fn checkExampleWiring(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "tools/build/examples.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "tools/build/examples.zig: failed to read for example-wiring check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var table_paths = std.StringHashMap(void).init(gpa);
    defer table_paths.deinit();
    try collectBuildExamplePaths(build_zig, &table_paths);

    // Forward: every on-disk example source is listed in tools/build/examples.zig's tables.
    for (example_source_dirs) |spec| {
        var dir = root.openDir(io, spec.dir, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for example-wiring check with {s}", .{ spec.dir, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, spec.ext)) continue;

            var path_buf: [192]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ spec.dir, entry.name }) catch {
                try appendViolation(gpa, violations, "{s}/{s}: path too long for example-wiring check", .{ spec.dir, entry.name });
                continue;
            };
            if (!table_paths.contains(path)) {
                try appendViolation(gpa, violations, "{s}: not listed in tools/build/examples.zig's {s} table, it silently never runs under `zig build examples`", .{ path, spec.table_name });
            }
        }
    }

    // Reverse: every table path resolves on disk.
    var it = table_paths.keyIterator();
    while (it.next()) |path| {
        root.access(io, path.*, .{}) catch |err| {
            try appendViolation(gpa, violations, "build.zig: {s} table lists `{s}` but it is not accessible ({s})", .{
                if (std.mem.startsWith(u8, path.*, "examples/zig/")) "zig_examples" else "c_examples",
                path.*,
                @errorName(err),
            });
        };
    }
}

const example_source_dirs = [_]struct { dir: []const u8, ext: []const u8, table_name: []const u8 }{
    .{ .dir = "examples/zig", .ext = ".zig", .table_name = "zig_examples" },
    .{ .dir = "examples/c", .ext = ".c", .table_name = "c_examples" },
};

fn collectBuildExamplePaths(build_zig: []const u8, out: *std.StringHashMap(void)) !void {
    var rest = build_zig;
    while (std.mem.indexOf(u8, rest, ".path = \"")) |start| {
        const after = rest[start + ".path = \"".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const path = after[0..end];
        rest = after[end..];
        if (!std.mem.startsWith(u8, path, "examples/zig/") and !std.mem.startsWith(u8, path, "examples/c/")) continue;
        try out.put(path, {});
    }
}
