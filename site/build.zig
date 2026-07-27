const std = @import("std");
const zine = @import("zine");

/// The pancake documentation site is its own build so the heavyweight Zine
/// generator never enters the root `pancake` build graph. The root build drives
/// these steps with `zig build --build-file site/build.zig …`, redirecting the
/// install prefix so the rendered pages land in the project's `zig-out/site`.
pub fn build(b: *std.Build) void {
    // `-Dport` matches the root build's port flag and pins the development
    // server; the root `docs-serve` step forwards it here.
    const port = b.option(u16, "port", "Port for the Zine development server (docs-serve)");

    const site_step = b.step("site", "Render the documentation site under the install prefix");
    if (b.dest_dir != null) {
        // Zine 0.11 renders under install_prefix instead of Zig's DESTDIR-aware
        // install_path. Refuse the split ownership until Zine accepts the
        // resolved path.
        const fail = b.addFail("the site build does not support DESTDIR: Zine renders under the install prefix and ignores DESTDIR, so the two would disagree about where the pages land. Use --prefix with DESTDIR unset.");
        site_step.dependOn(&fail.step);
    } else {
        const render = zine.website(b, .{
            .output_path = "site",
            .force = true,
        });
        // Zine's force flag suppresses its confirmation prompt but does not
        // replace existing files. Own the generated directory at this boundary
        // so a second `zig build site` is as reliable as the first.
        const clear_output = ClearOutput.create(b, b.install_path);
        render.step.dependOn(&clear_output.step);
        // The marker is what makes the clear safe to repeat: it is written
        // after a successful render, and the clear refuses any `site/` that
        // does not carry it. `--prefix` can name a directory holding somebody
        // else's `site/`, and this build does not get to delete that.
        const mark = MarkOutput.create(b, b.install_path);
        mark.step.dependOn(&render.step);
        site_step.dependOn(&mark.step);
    }

    const serve = zine.serve(b, .{});
    serve.addArgs(&.{ "--host", "127.0.0.1" });
    if (port) |p| serve.addArgs(&.{ "--port", b.fmt("{d}", .{p}) });
    const serve_step = b.step("docs-serve", "Serve the documentation site with Zine's development server");
    serve_step.dependOn(&serve.step);
}

/// Written into the rendered output so the next run can tell its own output
/// from a directory that merely shares the name.
const marker_name = ".pancake-site";

const MarkOutput = struct {
    step: std.Build.Step,
    install_prefix: []const u8,

    fn create(b: *std.Build, install_prefix: []const u8) *MarkOutput {
        const mark = b.allocator.create(MarkOutput) catch @panic("OOM");
        mark.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "mark generated site output",
                .owner = b,
                .makeFn = make,
            }),
            .install_prefix = install_prefix,
        };
        return mark;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const mark: *MarkOutput = @fieldParentPtr("step", step);
        const io = step.owner.graph.io;
        var dir = std.Io.Dir.cwd().openDir(io, mark.install_prefix, .{}) catch |err|
            return step.fail("unable to open site install prefix `{s}`: {t}", .{ mark.install_prefix, err });
        defer dir.close(io);
        var out = dir.openDir(io, "site", .{}) catch |err|
            return step.fail("site output missing after render: {t}", .{err});
        defer out.close(io);
        const file = out.createFile(io, marker_name, .{}) catch |err|
            return step.fail("unable to write the `{s}` marker: {t}", .{ marker_name, err });
        file.close(io);
    }
};

const ClearOutput = struct {
    step: std.Build.Step,
    install_prefix: []const u8,

    fn create(b: *std.Build, install_prefix: []const u8) *ClearOutput {
        const clear = b.allocator.create(ClearOutput) catch @panic("OOM");
        clear.* = .{
            .step = .init(.{
                .id = .custom,
                .name = "clear generated site output",
                .owner = b,
                .makeFn = make,
            }),
            .install_prefix = install_prefix,
        };
        return clear;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const clear: *ClearOutput = @fieldParentPtr("step", step);
        const b = step.owner;
        const graph = b.graph;
        const io = graph.io;
        const gpa = options.gpa;

        // Work through the opened prefix so an ancestor symlink cannot redirect
        // deletion after the overlap check.
        const prefix_dir: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, clear.install_prefix, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return step.fail("unable to open site install prefix `{s}`: {t}", .{ clear.install_prefix, err }),
        };
        defer if (prefix_dir) |dir| dir.close(io);

        var prefix_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var missing_prefix_path: ?[]u8 = null;
        defer if (missing_prefix_path) |path| gpa.free(path);
        const prefix_path = if (prefix_dir) |dir| prefix: {
            const prefix_len = dir.realPath(io, &prefix_buffer) catch |err|
                return step.fail("unable to resolve site install prefix `{s}`: {t}", .{ clear.install_prefix, err });
            break :prefix prefix_buffer[0..prefix_len];
        } else prefix: {
            missing_prefix_path = resolveProspectiveDirectory(gpa, graph, io, clear.install_prefix) catch |err|
                return step.fail("unable to resolve prospective site install prefix `{s}`: {t}", .{ clear.install_prefix, err });
            break :prefix missing_prefix_path.?;
        };

        const output_path = try std.fs.path.resolve(gpa, &.{ prefix_path, "site" });
        defer gpa.free(output_path);

        var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const source_len = b.build_root.handle.realPath(io, &source_buffer) catch |err|
            return step.fail("unable to resolve checked-in site source: {t}", .{err});
        const source_path = source_buffer[0..source_len];

        if (try pathsOverlap(gpa, graph, output_path, source_path)) {
            return step.fail(
                "refusing to clear generated site output `{s}` because it overlaps checked-in source `{s}`",
                .{ output_path, source_path },
            );
        }

        const dir = prefix_dir orelse return;
        var out = dir.openDir(io, "site", .{}) catch |err| switch (err) {
            error.FileNotFound => return, // nothing rendered here yet
            else => return step.fail("unable to open `{s}`: {t}", .{ output_path, err }),
        };
        const marked = blk: {
            defer out.close(io);
            break :blk if (out.access(io, marker_name, .{})) |_| true else |_| false;
        };
        // One directory is exempt from the marker: the canonical output the
        // default prefix names. It is generated, git-ignored, and predates
        // this marker in every existing checkout. Every other prefix must
        // carry the marker, including one inside the repository — `--prefix
        // docs` would otherwise put `docs/site`, checked-in source, in reach
        // of a recursive delete.
        const repo_root = std.fs.path.dirname(source_path) orelse source_path;
        const canonical = try std.fs.path.resolve(gpa, &.{ repo_root, "zig-out", "site" });
        defer gpa.free(canonical);
        if (!marked and !std.mem.eql(u8, output_path, canonical)) return step.fail(
            "refusing to clear `{s}`: it is neither the canonical `zig-out/site` " ++
                "nor a directory carrying this build's `{s}` marker, so this build " ++
                "did not produce it. Remove it yourself, or choose another --prefix.",
            .{ output_path, marker_name },
        );
        dir.deleteTree(io, "site") catch |err|
            return step.fail("unable to clear generated site output `{s}`: {t}", .{ output_path, err });
    }
};

fn resolveProspectiveDirectory(
    gpa: std.mem.Allocator,
    graph: *std.Build.Graph,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    const absolute = try std.fs.path.resolve(gpa, &.{ graph.cache.cwd, path });
    defer gpa.free(absolute);

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
        const suffix = try std.fs.path.relative(gpa, graph.cache.cwd, &graph.environ_map, probe, absolute);
        defer gpa.free(suffix);
        return std.fs.path.resolve(gpa, &.{ ancestor_buffer[0..ancestor_len], suffix });
    }
}

fn pathsOverlap(
    gpa: std.mem.Allocator,
    graph: *std.Build.Graph,
    a: []const u8,
    b: []const u8,
) !bool {
    return try pathContains(gpa, graph, a, b) or try pathContains(gpa, graph, b, a);
}

fn pathContains(
    gpa: std.mem.Allocator,
    graph: *std.Build.Graph,
    parent: []const u8,
    child: []const u8,
) !bool {
    const relative = try std.fs.path.relative(gpa, graph.cache.cwd, &graph.environ_map, parent, child);
    defer gpa.free(relative);
    if (relative.len == 0) return true;
    if (std.fs.path.isAbsolute(relative)) return false;

    var components = std.mem.tokenizeAny(u8, relative, "/\\");
    const first = components.next() orelse return true;
    return !std.mem.eql(u8, first, "..");
}
