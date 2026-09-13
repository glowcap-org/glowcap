//! A task the host Rooms peers spawn has an owner, or an argued reason not to.
//!
//! Host service workers are held in a `JoinSet` or a handle, so shutdown
//! observes their end and a panic inside one is the owner's failure rather than
//! a line on stderr nobody reads. This lexical tripwire rejects the known bad
//! shape: a bare, fully qualified
//! `tokio::task::spawn_local(...)` as a statement: the handle is dropped on
//! the spot, and the task runs until the LocalSet does. Room pumps were spawned
//! that way, and the room worker could neither see one panic nor wait for them
//! at retirement.
//!
//! Portable runtime owners are outside these host trees: some deliberately
//! drop a handle while observing completion through their own state channel.
//! `spawn_blocking`, aliases, and other spellings require ordinary review; this
//! check does not pretend textual scanning proves their lifetime semantics.
//! The unit test below plants the exact regression this check claims to catch.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

const trees = [_][]const u8{
    "apps/rooms/rust/platform/src",
    "apps/rooms/rust/services/src",
};

fn isProduction(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".rs")) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "tests") or
            std.mem.eql(u8, component, "tests.rs") or
            std.mem.endsWith(u8, component, "_tests.rs")) return false;
    }
    if (std.mem.startsWith(u8, path, "bin/")) return false;
    return true;
}

pub fn checkRoomsRustTasks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (trees) |tree| {
        try checkTree(io, gpa, root, violations, tree);
    }
}

test "bare host spawn is caught without hiding production paths that contain test" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/attestations");
    try tmp.dir.createDirPath(std.testing.io, "src/tests");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/attestations/worker.rs",
        .data = "tokio::task::spawn_local(work());\nlet held = tokio::task::spawn_local(work());\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/tests/worker.rs",
        .data = "tokio::task::spawn_local(test_work());\n",
    });
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try checkTree(std.testing.io, gpa, tmp.dir, &violations, "src");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "attestations/worker.rs:1") != null);
}

fn checkTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    tree: []const u8,
) !void {
    var dir = root.openDir(io, tree, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not open for the task-ownership check", .{tree});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isProduction(entry.path)) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
        defer gpa.free(path);
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not read for the task-ownership check", .{path});
            continue;
        };
        defer gpa.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        var number: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "tokio::task::spawn_local(")) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}:{d} spawns a task nobody owns: hold it in a JoinSet or a handle so shutdown observes it and a panic is its owner's failure, or name its bound in rooms_rust_tasks.zig",
                .{ path, number },
            );
        }
    }
}
