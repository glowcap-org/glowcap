//! A file name written in prose is a claim the compiler cannot see.
//!
//! Comments and app docs cite sources by name — "`lib/room/client.ts` keeps
//! the retry" — and a rename or move leaves every such sentence pointing at
//! nothing. The doc-drift rule already calls a moved file the commonest drift
//! with no prose to read; this holds the apps trees to it mechanically: every
//! backtick-quoted `.ts`, `.tsx`, `.css`, or `.zig` name in an apps source or
//! Markdown file must share its basename with a file that exists in the
//! repository. Basename, not path, because prose legitimately shortens
//! `apps/rooms/test/irc/bridge_test.ts` to a tail its reader can find; what it
//! must not do is name a file nobody can.
//!
//! Validated by putting a retired name back (`room_client.ts`): it is caught.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where cited basenames may live. Wider than the scanned tree, because apps
/// prose reaches into the bindings and the core.
const basename_roots = [_][]const u8{
    "src", "apps", "bindings", "tools", "test", "docs", "examples", "cli", "ui", "bench",
};

const scanned_roots = [_][]const u8{"apps"};

fn isCitable(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx") or
        std.mem.endsWith(u8, path, ".css") or std.mem.endsWith(u8, path, ".zig");
}

fn isScanned(path: []const u8) bool {
    return isCitable(path) or std.mem.endsWith(u8, path, ".md");
}

fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-';
}

fn basenameOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| return name[slash + 1 ..];
    return name;
}

pub fn checkProseFileClaims(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var basenames = std.StringHashMap(void).init(arena);
    for (basename_roots) |tree| {
        const files = try util.collectSourceFiles(io, arena, root, tree, isCitable) orelse continue;
        for (files) |path| try basenames.put(basenameOf(path), {});
    }

    for (scanned_roots) |tree| {
        const files = try util.collectSourceFiles(io, arena, root, tree, isScanned) orelse continue;
        for (files) |path| {
            // The browser bundle is a build artifact that happens to sit in the tree.
            if (std.mem.endsWith(u8, path, "page.js")) continue;
            const source = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch {
                try appendViolation(gpa, violations, "{s}: could not read for the prose file-claim check", .{path});
                continue;
            };
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, source, i, '`')) |open| {
                var end = open + 1;
                while (end < source.len and isPathChar(source[end])) end += 1;
                i = end + 1;
                if (end >= source.len or source[end] != '`') continue;
                const name = source[open + 1 .. end];
                if (name.len == 0 or !isCitable(name) or name[0] == '.') continue;
                const base = basenameOf(name);
                if (basenames.contains(base)) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s} cites `{s}`, and no file in the repository has that name; name the file on disk, or drop the claim",
                    .{ path, name },
                );
            }
        }
    }
}
