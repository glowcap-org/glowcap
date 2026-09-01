//! Persisted document schemas stay at version 1.
//!
//! pancake ships under no compatibility promise, so a document shape that is
//! replaced is not a second version of anything: nothing reads the old one and
//! nothing ever will. The [prerelease rule](../../../.agents/rules/prerelease.md)
//! says so directly, and `c_abi/versions.zig` already holds provider ABI
//! constants to it. This is the same rule for the documents an application
//! writes to disk and to browser storage.
//!
//! A number above one is not merely untidy. It is a claim that earlier shapes
//! existed and were supported, which invites the next reader to write the
//! migration that answers for them, against versions no file anywhere has ever
//! carried. One document here had reached four in a single commit, having never
//! had a first, second, or third shape at all.
//!
//! The version *field* is not what this refuses. Keeping it is what makes a
//! real version possible later, on the day pancake intentionally supports a
//! shape it has released. Until that day the honest value is one.
//!
//! Scoped by discovery rather than by a list, so a document added tomorrow is
//! covered without anyone remembering to enrol it: what it looks for is a
//! `version:` field declared as a `z.literal`, which is how every persisted
//! schema in this repository states its own.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where persisted application documents live.
const roots = [_][]const u8{ "apps", "bindings/ts" };

/// How a schema states its version. Everything this rule reads follows it.
const marker = "version: z.literal(";

fn isSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
}

fn isIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// The integer `name` is declared as in `body`, or null when this file does not
/// declare it. Only a plain integer counts: a computed version is not something
/// this rule can read, and saying so is better than guessing.
fn declaredInteger(body: []const u8, name: []const u8) ?i64 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, name)) |found| {
        at = found + name.len;
        const before_ok = found == 0 or !isIdentifierByte(body[found - 1]);
        if (!before_ok or at >= body.len or isIdentifierByte(body[at])) continue;
        // Walk back over `const `/`export const ` to be sure this is the
        // declaration and not a use.
        const line_start = if (std.mem.lastIndexOfScalar(u8, body[0..found], '\n')) |nl| nl + 1 else 0;
        // Trimmed at both ends, so the keyword is compared without its trailing
        // space: `const ` and `export const ` both end in the word itself.
        const head = std.mem.trim(u8, body[line_start..found], " \t");
        if (!std.mem.endsWith(u8, head, "const")) continue;
        if (head.len != "const".len and head[head.len - "const".len - 1] != ' ') continue;
        var rest = body[at..];
        rest = std.mem.trimStart(u8, rest, " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        var end: usize = 0;
        while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
    }
    return null;
}

fn checkFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, marker)) |found| {
        at = found + marker.len;
        const close = std.mem.indexOfScalarPos(u8, body, at, ')') orelse continue;
        const argument = std.mem.trim(u8, body[at..close], " \t");
        if (argument.len == 0) continue;
        const value = if (std.ascii.isDigit(argument[0]))
            std.fmt.parseInt(i64, argument, 10) catch null
        else
            declaredInteger(body, argument);
        const found_value = value orelse {
            try appendViolation(
                gpa,
                violations,
                "{s}: schema version `{s}` is not a plain integer in this file, so the prerelease version rule cannot read it",
                .{ path, argument },
            );
            continue;
        };
        if (found_value == 1) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: persisted schema version is {d}; a replaced prerelease document stays at 1, because no earlier shape was ever supported",
            .{ path, found_value },
        );
    }
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (roots) |root_path| {
        const files = (try util.collectSourceFiles(io, gpa, root, root_path, isSourcePath)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for the prerelease version check", .{root_path});
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
            try checkFile(gpa, path, body, violations);
        }
    }
}
