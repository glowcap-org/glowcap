//! The rooms browser proofs' child-process contract.
//!
//! Every rooms proof starts a real server, and several of those servers
//! supervise a child of their own. A proof that spawns one directly owns a
//! teardown it cannot always reach: a deadline that fires from a timer callback
//! throws outside the scenario's `try`, and Deno runs no unload handler after an
//! uncaught error, so the `finally` that was meant to stop the server never
//! runs. The server is then orphaned onto init, still holding its loopback port,
//! and the next run inherits it and fails somewhere unrelated.
//!
//! `apps/rooms/test/support/children.ts` is the one owner of that lifetime. It
//! starts each child in a process group of its own and reaps the whole group
//! from five exits, so no path out of a proof can skip it. This check holds the
//! tree to that one owner, because the failure it prevents is invisible in a
//! green run and only shows up as somebody else's flake.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where the rooms proofs live, and the one file allowed to spawn.
const proof_dir = "apps/rooms/test";
const owner_rel = "support/children.ts";

/// Spawning a child without adopting its process group. An awaited `.output()`
/// is deliberately absent: it cannot outlive the call that made it, so it needs
/// no owner.
const spawn_needle = ".spawn()";

pub fn checkRoomsProofChildren(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The owner has to exist before the ban means anything. Without this, a
    // deleted `children.ts` reads as a tree that simply stopped spawning, and
    // the check reports success over an unowned harness.
    if (!(util.fileContains(io, gpa, root, proof_dir ++ "/" ++ owner_rel, spawn_needle) catch false)) {
        try appendViolation(
            gpa,
            violations,
            "{s}/{s}: the one owner of proof child lifetime does not spawn. Either it is gone or the ban below is checking nothing",
            .{ proof_dir, owner_rel },
        );
        return;
    }
    try walk(io, gpa, root, proof_dir, "", violations);
}

fn walk(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    base: []const u8,
    rel: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const here = if (rel.len == 0)
        try gpa.dupe(u8, base)
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, rel });
    defer gpa.free(here);

    var dir = root.openDir(io, here, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not be opened", .{here});
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const entry = (it.next(io) catch break) orelse break;
        const child_rel = if (rel.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });
        defer gpa.free(child_rel);

        if (entry.kind == .directory) {
            try walk(io, gpa, root, base, child_rel, violations);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".ts")) continue;
        if (std.mem.eql(u8, child_rel, owner_rel)) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, child_rel });
        defer gpa.free(path);
        if (!(util.fileContains(io, gpa, root, path, spawn_needle) catch false)) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: spawns a child directly. Use `spawnOwned` from {s}/{s}, so a proof that dies on an uncaught deadline cannot orphan its server onto a port the next run needs",
            .{ path, proof_dir, owner_rel },
        );
    }
}
