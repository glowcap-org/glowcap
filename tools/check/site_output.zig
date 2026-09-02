//! Validate the rendered documentation artifact before it is published.
//!
//! Source checks know whether a Zine page id or site asset exists. This check
//! runs after rendering and autodoc installation, where it can catch unresolved
//! template expressions and links whose final URL has no file in the artifact.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const output_path = args.next() orelse {
        std.debug.print("usage: site-output-check <rendered-site-directory>\n", .{});
        std.process.exit(2);
    };
    if (args.next() != null) {
        std.debug.print("usage: site-output-check <rendered-site-directory>\n", .{});
        std.process.exit(2);
    }

    var site = std.Io.Dir.cwd().openDir(io, output_path, .{ .iterate = true }) catch |err| {
        std.debug.print("site-output-check: cannot open `{s}`: {t}\n", .{ output_path, err });
        std.process.exit(1);
    };
    defer site.close(io);

    const home = site.readFileAlloc(io, "index.html", gpa, .limited(4 << 20)) catch |err| {
        std.debug.print("site-output-check: cannot read `index.html`: {t}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(home);
    const prefix = deploymentPrefix(home) orelse {
        std.debug.print("site-output-check: `index.html` has no absolute brand link from which to read the deployment prefix\n", .{});
        std.process.exit(1);
    };

    var failures: usize = 0;
    var walker = try site.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".html")) continue;
        const html = site.readFileAlloc(io, entry.path, gpa, .limited(16 << 20)) catch |err| {
            std.debug.print("site-output-check: cannot read `{s}`: {t}\n", .{ entry.path, err });
            failures += 1;
            continue;
        };
        defer gpa.free(html);

        inline for (.{ "href=\"", "src=\"" }) |marker| {
            var rest = html;
            while (std.mem.indexOf(u8, rest, marker)) |at| {
                const value = rest[at + marker.len ..];
                const end = std.mem.indexOfScalar(u8, value, '"') orelse {
                    std.debug.print("site-output-check: `{s}` has an unterminated `{s}` attribute\n", .{ entry.path, marker[0 .. marker.len - 2] });
                    failures += 1;
                    break;
                };
                const raw = value[0..end];
                rest = value[end + 1 ..];

                if (std.mem.indexOfScalar(u8, raw, '$') != null) {
                    std.debug.print("site-output-check: `{s}` contains unresolved {s}`{s}`\n", .{ entry.path, marker, raw });
                    failures += 1;
                    continue;
                }

                const target = targetPath(gpa, prefix, entry.path, raw) catch |err| {
                    std.debug.print("site-output-check: `{s}` has invalid local target `{s}`: {t}\n", .{ entry.path, raw, err });
                    failures += 1;
                    continue;
                } orelse continue;
                defer gpa.free(target);
                site.access(io, target, .{}) catch {
                    std.debug.print("site-output-check: `{s}` links `{s}`, which resolves to missing `{s}`\n", .{ entry.path, raw, target });
                    failures += 1;
                };
            }
        }
    }

    if (failures != 0) {
        std.debug.print("site-output-check: {d} invalid rendered reference{s}\n", .{ failures, if (failures == 1) "" else "s" });
        std.process.exit(1);
    }
}

fn deploymentPrefix(home: []const u8) ?[]const u8 {
    const marker = "class=\"brand\" href=\"";
    const at = std.mem.indexOf(u8, home, marker) orelse return null;
    const value = home[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    const href = value[0..end];
    if (href.len == 0 or href[0] != '/' or href[href.len - 1] != '/') return null;
    return href;
}

fn targetPath(
    gpa: std.mem.Allocator,
    prefix: []const u8,
    source_path: []const u8,
    raw: []const u8,
) !?[]u8 {
    if (raw.len == 0 or raw[0] == '#') return null;
    if (isExternal(raw)) return null;

    const query_at = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const path = raw[0..query_at];
    if (path.len == 0) return null;

    var normalized: []u8 = undefined;
    if (path[0] == '/') {
        if (!std.mem.startsWith(u8, path, prefix)) return error.OutsideDeploymentPrefix;
        normalized = try gpa.dupe(u8, path[prefix.len..]);
    } else {
        const source_dir = std.fs.path.dirname(source_path) orelse "";
        const absolute = try std.fs.path.resolve(gpa, &.{ "/", source_dir, path });
        defer gpa.free(absolute);
        std.debug.assert(absolute.len != 0 and absolute[0] == '/');
        normalized = try gpa.dupe(u8, absolute[1..]);
    }
    errdefer gpa.free(normalized);

    if (normalized.len == 0 or normalized[normalized.len - 1] == '/') {
        const target = try std.fmt.allocPrint(gpa, "{s}index.html", .{normalized});
        gpa.free(normalized);
        return target;
    }
    return normalized;
}

fn isExternal(raw: []const u8) bool {
    if (std.mem.startsWith(u8, raw, "//")) return true;
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return false;
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse raw.len;
    return colon < slash;
}

test "rendered URL paths resolve against their page and deployment prefix" {
    const gpa = std.testing.allocator;

    const home = (try targetPath(gpa, "/glowcap/", "start/index.html", "/glowcap/")).?;
    defer gpa.free(home);
    try std.testing.expectEqualStrings("index.html", home);

    const page = (try targetPath(gpa, "/glowcap/", "start/index.html", "/glowcap/transports/noise/#dialing")).?;
    defer gpa.free(page);
    try std.testing.expectEqualStrings("transports/noise/index.html", page);

    const asset = (try targetPath(gpa, "/glowcap/", "reference/api/index.html", "main.js")).?;
    defer gpa.free(asset);
    try std.testing.expectEqualStrings("reference/api/main.js", asset);

    try std.testing.expect((try targetPath(gpa, "/glowcap/", "index.html", "https://ziglang.org/")) == null);
    try std.testing.expectError(
        error.OutsideDeploymentPrefix,
        targetPath(gpa, "/glowcap/", "index.html", "/another-site/page/"),
    );
}
