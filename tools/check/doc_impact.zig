//! List the docs whose code a change touches, so the docs to reread come from
//! the change itself instead of a search.
//!
//! A doc names the code it explains in the `sources` of its header
//! (`source_check/docs/kinds.zig`). A README with no header explains the files
//! beside it, and a static doc whose place decides it (agent docs, site pages,
//! root docs) explains what it links and names. This reads the change from git as every path that differs from
//! where it forked from `base` (default `dev`), committed or not, plus new
//! untracked files, and prints each doc that explains one of them. It reports
//! and never fails on what it finds.
//!
//! Usage: doc-impact [base]

const std = @import("std");
const kinds = @import("doc_kinds");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const base = args.next() orelse "dev";

    var changed: std.ArrayList([]const u8) = .empty;
    try gitLines(io, gpa, &.{ "git", "diff", "--name-only", "--merge-base", base }, &changed);
    try gitLines(io, gpa, &.{ "git", "ls-files", "--others", "--exclude-standard" }, &changed);

    const cwd = std.Io.Dir.cwd();
    var docs: std.ArrayList([]const u8) = .empty;
    for (kinds.root_docs) |path| try docs.append(gpa, path);
    for (kinds.doc_trees) |tree| try collect(io, gpa, cwd, tree, &docs);

    var out: std.ArrayList(u8) = .empty;
    var hits: usize = 0;
    for (docs.items) |doc| {
        const text = cwd.readFileAlloc(io, doc, gpa, .limited(4 << 20)) catch |err| switch (err) {
            // tolerant: a root doc this checkout does not carry explains nothing.
            error.FileNotFound => continue,
            else => return err,
        };
        var touched: std.ArrayList([]const u8) = .empty;
        for (changed.items) |path| {
            if (std.mem.eql(u8, path, doc) or kinds.isDoc(path)) continue;
            if (try explains(gpa, doc, text, path)) try touched.append(gpa, path);
        }
        if (touched.items.len == 0) continue;
        hits += 1;
        const edited = for (changed.items) |path| {
            if (std.mem.eql(u8, path, doc)) break true;
        } else false;
        try out.print(gpa, "  {s}{s}\n", .{ doc, if (edited) " (edited in this change)" else "" });
        for (touched.items[0..@min(touched.items.len, 3)]) |path| try out.print(gpa, "      {s}\n", .{path});
        if (touched.items.len > 3) try out.print(gpa, "      and {d} more\n", .{touched.items.len - 3});
    }
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    if (hits == 0) {
        try stdout.interface.print("doc-impact: no doc explains the {d} files changed since {s}.\n", .{ changed.items.len, base });
    } else {
        try stdout.interface.print("doc-impact: {d} docs explain code changed since {s}. Reread each one and fix what the change made untrue.\n{s}", .{ hits, base, out.items });
    }
    try stdout.interface.flush();
}

/// Whether `doc` explains `path`: through its `sources`, as a README with no
/// header through the files directly beside it, or as a static doc whose
/// place decides it through what it links and names.
fn explains(gpa: std.mem.Allocator, doc: []const u8, text: []const u8, path: []const u8) !bool {
    if (kinds.placeOf(doc) == .decides) return kinds.classify(doc, text).kind == .static and try kinds.names(gpa, doc, text, path);
    if (kinds.Frontmatter.of(text)) |front| {
        var sources = front.sources() orelse return false;
        while (sources.next()) |resource| {
            const source = kinds.sourcePath(resource) orelse continue;
            if (kinds.covers(source, path)) return true;
        }
        return false;
    }
    const dir = kinds.readmeDir(doc) orelse return false;
    return std.mem.startsWith(u8, path, dir) and std.mem.indexOfScalar(u8, path[dir.len..], '/') == null;
}

fn gitLines(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(16 << 20) });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("doc-impact: `{s} {s}` exited {d}: {s}", .{ argv[0], argv[1], code, result.stderr });
            std.process.exit(1);
        },
        else => {
            std.debug.print("doc-impact: `{s} {s}` did not exit cleanly\n", .{ argv[0], argv[1] });
            std.process.exit(1);
        },
    }
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| try out.append(gpa, line);
}

fn collect(io: std.Io, gpa: std.mem.Allocator, cwd: std.Io.Dir, tree: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = cwd.openDir(io, tree, .{ .iterate = true }) catch |err| switch (err) {
        // tolerant: a doc tree this checkout does not carry holds no docs.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!std.mem.eql(u8, entry.basename, "node_modules") and !std.mem.eql(u8, entry.basename, "target")) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        const path = try std.fs.path.join(gpa, &.{ tree, entry.path });
        if (kinds.isDoc(path)) try out.append(gpa, path);
    }
}

test "a doc explains its sources, and a bare README the files beside it" {
    const doc = "---\ntype: static\ndescription: Loam.\nsources:\n  - resource: /src/loam/\n---\n";
    const gpa = std.testing.allocator;
    try std.testing.expect(try explains(gpa, "docs/loam.md", doc, "src/loam/core/mod.zig"));
    try std.testing.expect(!try explains(gpa, "docs/loam.md", doc, "src/net/mod.zig"));
    try std.testing.expect(try explains(gpa, "test/net/fixtures/README.md", "# Fixtures\n", "test/net/fixtures/tls_root.pem"));
    try std.testing.expect(!try explains(gpa, "test/net/README.md", "# Net\n", "test/net/fixtures/tls_root.pem"));
    const rule = "---\ndescription: \"Gates.\"\n---\n\nRun [the front](../skills/work/bin/glowcap-dev).\n";
    try std.testing.expect(try explains(gpa, ".agents/rules/cli.md", rule, ".agents/skills/work/bin/glowcap-dev"));
    try std.testing.expect(!try explains(gpa, "docs/planning/x.md", "`src/loam/`", "src/loam/mod.zig"));
}
