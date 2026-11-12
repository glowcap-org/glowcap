//! Paths a rename leaves pointing at nothing.
//!
//! `new URL("…", import.meta.url)` names a file with a string. No typechecker
//! follows it and no import graph contains it, so moving the target leaves the
//! string behind and nothing says a word. It surfaces only when that line runs,
//! and the worst shape is a test guarded by such a path: the guard misses, the
//! test skips itself, and a suite that never ran its own case reports green.
//!
//! One reorganization here left three of these, and they stood until a sweep by
//! hand went looking. The [doc-drift rule](../../../.agents/rules/doc-drift.md)
//! asks for that sweep. This asks the build instead, which is the half that
//! runs every time.
//!
//! A path into generated state is not asked to exist. A clean checkout holds
//! none of it, so a machine that has built and one that has not give the same
//! answer. The generated-state table names which paths those are.
//!
//! Scoped to the trees that pass it. A tree joins `roots` in the same
//! change that empties it, the way the sibling doc and scene checks were
//! placed.
//!
//! It reads one form and only one: a literal first argument with
//! `import.meta.url` as the base. A path built by joining, as
//! `` `${ROOT}apps/…` `` does in about two dozen places here, is the same
//! defect and is not read, because resolving it means following `ROOT` to
//! whichever file exported it. `import.meta.resolve` is not read either. So a
//! green run says the `new URL` form is sound, never that every path in these
//! trees is.

const std = @import("std");
const registries = @import("project_shape/registries.zig");
const source_tree = @import("source_tree.zig");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;

/// Where this holds.
const roots = [_][]const u8{ "apps/rooms", "bindings/ts" };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `link` resolved against the directory holding `from_file`, both repository
/// relative, or null when it climbs past the repository root. An empty result
/// is the root itself.
fn resolve(gpa: std.mem.Allocator, from_file: []const u8, link: []const u8) !?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var base = std.mem.splitScalar(u8, std.fs.path.dirname(from_file) orelse "", '/');
    while (base.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        try parts.append(gpa, segment);
    }
    var walk = std.mem.splitScalar(u8, link, '/');
    while (walk.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(gpa, segment);
    }
    return try std.mem.join(gpa, "/", parts.items);
}

/// Whether this literal is a path into the repository at all. An absolute URL
/// names somewhere else entirely.
fn isCheckable(literal: []const u8) bool {
    if (literal.len == 0) return false;
    if (std.mem.indexOf(u8, literal, "://") != null) return false;
    if (std.mem.startsWith(u8, literal, "data:")) return false;
    return true;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    body: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const opener = "new URL(";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, opener)) |found| {
        at = found + opener.len;
        // Whitespace here spans lines, so the argument written on its own line
        // reads the same as the argument written inline. That form is the one
        // that hid a stale path from an earlier hand-written sweep.
        var i = at;
        while (i < body.len and isSpace(body[i])) i += 1;
        // A computed first argument names no literal to check.
        if (i >= body.len or body[i] != '"') continue;
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse continue;
        const literal = body[start..end];
        var after = end + 1;
        while (after < body.len and (isSpace(body[after]) or body[after] == ',')) after += 1;
        // Only the `import.meta.url` base resolves against this file's own
        // directory; any other base is somebody else's arithmetic.
        if (!std.mem.startsWith(u8, body[after..], "import.meta.url")) continue;
        if (!isCheckable(literal)) continue;
        const resolved = (try resolve(gpa, path, literal)) orelse {
            try appendViolation(
                gpa,
                violations,
                "{s}: `{s}` climbs past the repository root",
                .{ path, literal },
            );
            continue;
        };
        defer gpa.free(resolved);
        if (resolved.len == 0) continue;
        if (registries.generatedStateHolding(resolved) != null) continue;
        root.access(io, resolved, .{}) catch {
            try appendViolation(
                gpa,
                violations,
                "{s}: `{s}` resolves to {s}, which does not exist",
                .{ path, literal, resolved },
            );
        };
    }
}

const Sink = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),

    fn visit(self: Sink, path: []const u8, contents: []u8) std.mem.Allocator.Error!void {
        try checkFile(self.io, self.gpa, self.root, path, contents, self.violations);
    }
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (roots) |root_path| {
        try source_tree.visitSourceFiles(io, gpa, root, violations, "runtime-path", root_path, &source_tree.isTypeScriptPath, Sink{ .io = io, .gpa = gpa, .root = root, .violations = violations }, Sink.visit);
    }
}

test "a path into generated state passes built or not, and any other path must exist" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "apps/rooms/node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "apps/rooms/deno.json", .data = "{}" });

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    const body =
        \\const config = new URL("../deno.json", import.meta.url);
        \\const packages = new URL("../node_modules", import.meta.url);
        \\const unbuilt = new URL("../../../zig-out/wasm/rooms.wasm", import.meta.url);
        \\const misplaced = new URL("./zig-out/rooms.wasm", import.meta.url);
        \\const gone = new URL("./moved.ts", import.meta.url);
    ;
    try checkFile(io, gpa, tmp.dir, "apps/rooms/web/vite.config.ts", body, &violations);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try std.testing.expectEqualStrings(
        "apps/rooms/web/vite.config.ts: `./zig-out/rooms.wasm` resolves to apps/rooms/web/zig-out/rooms.wasm, which does not exist",
        violations.items[0],
    );
    try std.testing.expectEqualStrings(
        "apps/rooms/web/vite.config.ts: `./moved.ts` resolves to apps/rooms/web/moved.ts, which does not exist",
        violations.items[1],
    );
}
