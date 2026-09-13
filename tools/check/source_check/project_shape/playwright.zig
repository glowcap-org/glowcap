//! The Playwright pin: one version, from pins.sh, in every scope that
//! drives a browser.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// Trees the Playwright pin check walks. Everything that drives a browser lives
/// in one of these, and the walk skips vendored and generated paths by name.
const playwright_scan_trees = [_][]const u8{ "apps", "bindings", "bench", "conformance", "interop", "tools", "transports", "test", "src", "cli", "examples", "site" };

/// The Playwright version is written once, in `.devcontainer/pins.sh`, and
/// everything that needs it derives from there: `image/playwright.sh` reads
/// the pin to install the browser into the image, and each Deno scope's import
/// map resolves the `playwright` its scripts import. Those are the same program
/// in two halves — a browser binary and the library that drives it — and a
/// version skew between them makes Playwright hunt for a browser build number
/// the image never installed.
///
/// Two directions, because the pin can be re-opened from either side. Every
/// `deno.json` that maps `playwright` must map it to the pinned version, and no
/// source file may name a version inline: `import … from "npm:playwright@1.60.0"`
/// is a second pin wearing an import's clothes, which is how twenty-four
/// ocapnviz probe scripts once drifted a minor version behind the browser on
/// disk. Import maps are where a version belongs, so they are the only place a
/// literal is allowed.
///
/// `deno.lock` is deliberately not read, and the omission is a decision. A lock
/// is derived from the two surfaces above and from nothing else, so once both
/// are clean, a version still named in a lock is residue that regenerating it
/// removes. It is also allowed to hold several versions at once, because a
/// transitive dependency may pull its own copy, and refusing that would refuse
/// a correct tree. The remedy for a stale lock is `deno install`, not a red
/// build.
pub fn checkPlaywrightPin(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const pins_path = ".devcontainer/pins.sh";
    const pins = root.readFileAlloc(io, pins_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read it to derive the Playwright pin ({s})", .{ pins_path, @errorName(err) });
        return;
    };
    defer gpa.free(pins);

    const decl = "PLAYWRIGHT_VERSION=\"";
    const at = std.mem.indexOf(u8, pins, decl) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}…` is gone, so nothing declares the Playwright version the browser proofs and the image share", .{ pins_path, decl });
        return;
    };
    const rest = pins[at + decl.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` is not a closed quoted string", .{ pins_path, decl });
        return;
    };
    const version = rest[0..end];

    const expected = try std.fmt.allocPrint(gpa, "\"playwright\": \"npm:playwright@{s}\"", .{version});
    defer gpa.free(expected);

    // The root scope is named because it is where the shipped browser proofs
    // resolve; the walk below finds every other scope on its own.
    var mapped_scopes: usize = 0;
    if (try checkPlaywrightImportMap(io, gpa, root, violations, "deno.json", expected, version, pins_path)) mapped_scopes += 1;

    for (playwright_scan_trees) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be opened for the Playwright pin check ({s})", .{ tree, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                try util.enterSourceDirectory(io, gpa, &walker, tree, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            // Vendored and generated trees carry no glowcap rule, and a lock
            // file records a resolution rather than declaring one.
            if (std.mem.indexOf(u8, entry.path, "node_modules/") != null) continue;
            if (std.mem.indexOf(u8, entry.path, "upstream/") != null) continue;
            if (std.mem.indexOf(u8, entry.path, "dist/") != null) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);

            if (std.mem.endsWith(u8, entry.path, "deno.json")) {
                if (try checkPlaywrightImportMap(io, gpa, root, violations, path, expected, version, pins_path)) mapped_scopes += 1;
                continue;
            }
            if (!std.mem.endsWith(u8, entry.path, ".ts") and !std.mem.endsWith(u8, entry.path, ".tsx") and
                !std.mem.endsWith(u8, entry.path, ".js") and !std.mem.endsWith(u8, entry.path, ".mjs")) continue;

            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot be read for the Playwright pin check ({s})", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            const inline_pin = "npm:playwright@";
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, contents, from, inline_pin)) |hit| {
                from = hit + inline_pin.len;
                if (from >= contents.len or !std.ascii.isDigit(contents[from])) continue;
                var stop = from;
                while (stop < contents.len and contents[stop] != '"' and contents[stop] != '\'') stop += 1;
                try appendViolation(gpa, violations, "{s}: imports `npm:playwright@{s}` inline. A version belongs in the scope's deno.json import map, so every script in the scope moves with one edit; import the bare `playwright` specifier here.", .{ path, contents[from..stop] });
            }
        }
    }

    if (mapped_scopes == 0) {
        try appendViolation(gpa, violations, "no deno.json maps `playwright`, so nothing anchors the browser proofs to the {s} pin any more", .{pins_path});
    }
}

/// One import map checked against the pin. Returns whether this file maps
/// `playwright` at all, so the caller can tell a wrong pin from a check that
/// has quietly stopped covering anything.
fn checkPlaywrightImportMap(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const u8,
    version: []const u8,
    pins_path: []const u8,
) !bool {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read it to check the Playwright pin ({s})", .{ path, @errorName(err) });
        return false;
    };
    defer gpa.free(contents);
    if (std.mem.indexOf(u8, contents, "\"playwright\":") == null) return false;
    if (std.mem.indexOf(u8, contents, expected) == null) {
        try appendViolation(gpa, violations, "{s}: does not map `playwright` to `npm:playwright@{s}`, the version {s} pins for the image's browser", .{ path, version, pins_path });
    }
    return true;
}
