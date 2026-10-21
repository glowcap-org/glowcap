//! Scenes and helpers the rooms proofs never reach.
//!
//! A browser proof is assembled from scenes: named phases kept beside the
//! proofs in `apps/rooms/test/page/`, with the shared fixtures they stand on in
//! `apps/rooms/test/support/`. A scene nobody calls is the one kind of proof
//! failure that looks exactly like success, the suite is green, the file is
//! there, and the thing it was written to watch is unwatched. One landed that
//! way and stood for hours before anybody noticed.
//!
//! The sibling rule in `test_wiring.zig` holds a build step to every
//! `_test.ts`. This holds the next edge along: what those tests import has to
//! be reached from something. An export named in no other file is either a
//! phase that was written and never wired in, or a helper that outlived its
//! caller, and both are dead weight a reader has to rule out by hand. A helper
//! its own file calls and nobody else imports is the third case, and there the
//! `export` keyword is what to delete.
//!
//! Names are matched as text, so two files declaring the same one answer for
//! each other and neither is reported. Resolving imports properly is the fix
//! if that ever hides something real.
//!
//! It says only that: nothing is dead. A scene that *is* called can still prove
//! nothing: waiting on a condition an earlier step already met is the shape status-allow: event or source ordering
//! that bit us the other way, and no static rule sees that. Read the failure
//! as "this is unreachable", never as "the scenes are covered".

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// The trees whose files exist to be used by something else. A `_test.ts` is a
/// root and answers to the build registration rule instead.
const helper_dirs = [_][]const u8{ "apps/rooms/test/page", "apps/rooms/test/support" };

/// Every tree that may reach those helpers. The `interop/` drivers stand a
/// rooms server up the way the proofs do and import the same support, so a
/// helper named only from there is reached and must not be reported.
const consumer_roots = [_][]const u8{ "apps/rooms/test/", "interop/" };

/// What an exported declaration looks like at the start of a line. Re-exports
/// (`export { a } from "./b.ts"`) declare nothing here and are left to the file
/// that does declare them.
const export_forms = [_][]const u8{
    "export function ",
    "export async function ",
    "export const ",
    "export class ",
};

fn isTypeScript(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts");
}

fn isIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// How many times `name` appears as a whole identifier. Substring matches would
/// let `fail` answer for `failure`, which is the difference between a check and
/// a coin toss.
fn identifierOccurrences(haystack: []const u8, name: []const u8) usize {
    if (name.len == 0) return 0;
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, name)) |found| {
        const before_ok = found == 0 or !isIdentifierByte(haystack[found - 1]);
        const after = found + name.len;
        const after_ok = after >= haystack.len or !isIdentifierByte(haystack[after]);
        if (before_ok and after_ok) count += 1;
        at = found + name.len;
    }
    return count;
}

/// The identifier a declaration line names, or null when the line declares
/// something this rule does not read (a destructuring `const`, say).
fn declaredName(line: []const u8) ?[]const u8 {
    for (export_forms) |form| {
        if (!std.mem.startsWith(u8, line, form)) continue;
        const rest = line[form.len..];
        var end: usize = 0;
        while (end < rest.len and isIdentifierByte(rest[end])) end += 1;
        if (end == 0) return null;
        return rest[0..end];
    }
    return null;
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Every consumer source at once, the declaring file included, so
    // subtracting that file's own count leaves the uses that reach it from
    // somewhere else. Reach is what `export` claims, and a helper its own file
    // calls twice has not shown any: that one is internal, and the keyword is
    // the error.
    var tree: std.ArrayList(u8) = .empty;
    defer tree.deinit(gpa);
    for (consumer_roots) |subject_path| {
        const part = (try util.readSourceSubject(io, gpa, root, subject_path)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to read for the scene reachability check", .{subject_path});
            return;
        };
        defer gpa.free(part);
        try tree.appendSlice(gpa, part);
        try tree.append(gpa, '\n');
    }

    for (helper_dirs) |dir_path| {
        const files = (try util.collectSourceFiles(io, gpa, root, dir_path, isTypeScript)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for the scene reachability check", .{dir_path});
            continue;
        };
        defer {
            for (files) |path| gpa.free(path);
            gpa.free(files);
        }
        for (files) |path| {
            const body = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(body);
            var lines = std.mem.splitScalar(u8, body, '\n');
            while (lines.next()) |line| {
                const name = declaredName(line) orelse continue;
                if (identifierOccurrences(tree.items, name) > identifierOccurrences(body, name)) continue;
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: `{s}` is exported and named in no other file, so nothing reaches it",
                    .{ path, name },
                );
            }
        }
    }
}
