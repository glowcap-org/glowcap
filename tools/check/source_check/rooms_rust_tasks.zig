//! A task the native Rooms peers spawn has an owner, or an argued reason not to.
//!
//! Every worker a peer runs is held in a `JoinSet` or a handle, so shutdown
//! observes its end and a panic inside it is the owner's failure rather than a
//! line on stderr nobody reads. The shape that breaks this is a bare
//! `tokio::task::spawn_local(...)` as a statement: the handle is dropped on
//! the spot, and the task runs until the LocalSet does. Room pumps were spawned
//! that way, and the room worker could neither see one panic nor wait for them
//! at retirement.
//!
//! Some detached tasks are right: a deferred answer that settles the turn it
//! deferred, an acknowledgement wait that drops proxies when the view answers,
//! one snapshot tick at a time. Each of those is bounded by something the peer
//! already counts, and each is named here with that bound, so a new one has to
//! say what bounds it before it lands.
//!
//! Validated by planting a bare spawn in the room worker: caught.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

const tree = "apps/rooms/rust/native/src";

/// Files whose detached spawns are argued, with the bound each rides on.
const allowed = [_]struct { path: []const u8, bound: []const u8 }{
    .{ .path = "session_service/answer.rs", .bound = "one task per deferred CapTP answer, settled when the work ends or the caller's session closes" },
    .{ .path = "session_service/facet.rs", .bound = "one wait per acknowledged event per view, ended by the view's answer or its retirement" },
    .{ .path = "session_service/views.rs", .bound = "one snapshot tick at a time, gated by the scheduled flag" },
    .{ .path = "session_archive/share.rs", .bound = "one task per deferred share read, counted as a lost reply when the caller is gone" },
    .{ .path = "session_runtime/rooms/recording.rs", .bound = "one observer per admitted recording, ended by the archive worker's completion" },
    .{ .path = "session_service/viz/publish.rs", .bound = "one publisher loop per viz target, every wait bounded, stopped by its own flag" },
};

fn isProduction(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".rs")) return false;
    if (std.mem.indexOf(u8, path, "tests") != null) return false;
    if (std.mem.startsWith(u8, path, "bin/")) return false;
    return true;
}

fn isAllowed(path: []const u8) bool {
    for (allowed) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

pub fn checkRoomsRustTasks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, tree, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not open for the task-ownership check", .{tree});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isProduction(entry.path) or isAllowed(entry.path)) continue;
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
