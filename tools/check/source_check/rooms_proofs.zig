//! The rooms test tree's process contract: who spawns, who exits, who fails.
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
//! from five exits, so no path out of a proof can skip it. The same reasoning
//! holds the exits and the failure helpers: `Deno.exit` skips every `finally`,
//! so a test fails by throwing through `support/fail.ts`, asserts through
//! `assert.ts`, and exits only with `Deno.exit(0)` after its cleanup ran.
//! This check holds the tree to those owners, because the failure it prevents
//! is invisible in a green run and only shows up as somebody else's flake.

const std = @import("std");
const text_match = @import("text_match.zig");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;

/// Where the rooms tests live, and the files allowed to own each verb.
const proof_dir = "apps/rooms/test";
const spawn_owner_rel = "support/children.ts";
const fail_owner_rel = "support/fail.ts";
const assert_owner_rel = "assert.ts";

/// Spawning a child without adopting its process group. An awaited `.output()`
/// is absent: it cannot outlive the call that made it, so it needs
/// no owner.
const spawn_needle = ".spawn()";

/// The one exit a test may write itself, after its `finally` has run.
const clean_exit = "Deno.exit(0)";

const exit_needles = [_][]const u8{ "Deno.exit(", "process.exit(" };

/// A helper declaration that belongs to one file.
const Owned = struct { needle: []const u8, owner_rel: []const u8 };
const owned_helpers = [_]Owned{
    .{ .needle = "function fail(", .owner_rel = fail_owner_rel },
    .{ .needle = "function assert(", .owner_rel = assert_owner_rel },
};

pub fn checkRoomsProofChildren(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The owner has to exist before the ban means anything. Without this, a
    // deleted `children.ts` reads as a tree that simply stopped spawning, and
    // the check reports success over an unowned harness.
    const owner_path = proof_dir ++ "/" ++ spawn_owner_rel;
    if (!(try text_match.fileContains(io, gpa, root, owner_path, spawn_needle))) {
        try appendViolation(
            gpa,
            violations,
            "{s}: the one owner of proof child lifetime does not spawn. Either it is gone or the ban below is checking nothing",
            .{owner_path},
        );
        return;
    }
    // Deno overlays `env` onto the parent unless `clearEnv` is set, so a copied
    // map with `GLOWCAP_ROOMS_STATE` deleted still hands the pane's live directory
    // to a hermetic child. The owner is the one place that can hide it.
    if (!(try text_match.fileContains(io, gpa, root, owner_path, "clearEnv: true"))) {
        try appendViolation(
            gpa,
            violations,
            "{s}: hermetic children must replace the parent environment (`clearEnv: true`). Overlaying a map that omitted `GLOWCAP_ROOMS_STATE` still inherits the pane's live state directory",
            .{owner_path},
        );
    }
    for (owned_helpers) |helper| {
        const helper_path = try gpa.print("{s}/{s}", .{ proof_dir, helper.owner_rel });
        defer gpa.free(helper_path);
        if (!(try text_match.fileContains(io, gpa, root, helper_path, helper.needle))) {
            try appendViolation(gpa, violations, "{s}: the one owner of `{s}` no longer declares it", .{ helper_path, helper.needle });
        }
    }
    try walk(io, gpa, root, proof_dir, "", violations);
}

/// Whether a line that mentions an exit is the one clean exit a test may write.
fn exitLineAllowed(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r;");
    return std.mem.eql(u8, trimmed, clean_exit ++ ";") or std.mem.eql(u8, trimmed, clean_exit);
}

/// A comment may name the exit it forbids.
fn isComment(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "*");
}

fn containsAny(line: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.find(u8, line, needle) != null) return true;
    return false;
}

fn inspect(
    gpa: std.mem.Allocator,
    path: []const u8,
    child_rel: []const u8,
    contents: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    if (!std.mem.eql(u8, child_rel, spawn_owner_rel)) {
        if (std.mem.find(u8, contents, spawn_needle) != null) try appendViolation(
            gpa,
            violations,
            "{s}: spawns a child directly. Use `spawnOwned` from {s}/{s}, so a proof that dies on an uncaught deadline cannot orphan its server onto a port the next run needs",
            .{ path, proof_dir, spawn_owner_rel },
        );
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (isComment(line) or !containsAny(line, &exit_needles) or exitLineAllowed(line)) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}: exits from a test. Throw through {s}/{s} so the `finally` that stops the servers runs, and exit only with `{s}` after it",
                .{ path, proof_dir, fail_owner_rel, clean_exit },
            );
            break;
        }
    }
    for (owned_helpers) |helper| {
        if (std.mem.eql(u8, child_rel, helper.owner_rel)) continue;
        if (std.mem.find(u8, contents, helper.needle) != null) try appendViolation(
            gpa,
            violations,
            "{s}: declares its own `{s}`. Import it from {s}/{s}",
            .{ path, helper.needle, proof_dir, helper.owner_rel },
        );
    }
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
        try gpa.print("{s}/{s}", .{ base, rel });
    defer gpa.free(here);

    var dir = root.openDir(io, here, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not be opened", .{here});
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const entry = (try it.next(io)) orelse break;
        const child_rel = if (rel.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try gpa.print("{s}/{s}", .{ rel, entry.name });
        defer gpa.free(child_rel);

        if (entry.kind == .directory) {
            try walk(io, gpa, root, base, child_rel, violations);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".ts")) continue;

        const path = try gpa.print("{s}/{s}", .{ base, child_rel });
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not be read", .{path});
            continue;
        };
        defer gpa.free(contents);
        try inspect(gpa, path, child_rel, contents, violations);
    }
}

test "rooms proofs: only the clean exit after cleanup is a test's own" {
    try std.testing.expect(exitLineAllowed("Deno.exit(0);"));
    try std.testing.expect(exitLineAllowed("\tDeno.exit(0)"));
    try std.testing.expect(!exitLineAllowed("\tDeno.exit(1);"));
    try std.testing.expect(!exitLineAllowed("if (bad) Deno.exit(0);"));
    try std.testing.expect(!exitLineAllowed("process.exit(0);"));
    try std.testing.expect(isComment("\t// never Deno.exit(1) here"));
    try std.testing.expect(!isComment("\tDeno.exit(1); // not here"));
}

test "rooms proofs: a file declaring an owned helper or exiting is refused" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try inspect(gpa, "x/a.ts", "a.ts", "function fail(m: string) {}\nDeno.exit(2);\n", &violations);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try inspect(gpa, "x/support/fail.ts", "support/fail.ts", "export function fail(m: string): never {}\n", &violations);
    try inspect(gpa, "x/b.ts", "b.ts", "try { await main(); } finally { await reapOwned(); }\nDeno.exit(0);\n", &violations);
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
}
