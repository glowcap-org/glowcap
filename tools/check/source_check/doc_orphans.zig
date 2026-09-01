//! Doc comments that document nothing.
//!
//! A `/** … */` block with nothing but blank lines between it and the next one
//! describes whatever that *second* block introduces, which is never what it
//! was written for. It happens when a declaration is inserted between a
//! paragraph and its subject: the paragraph then introduces a stranger, and the
//! thing it was written for is left bare.
//!
//! Nothing about it is visible at the call site and no compiler minds, so the
//! only thing that catches it is a reader noticing that a paragraph and the
//! line under it are about different subjects. This asks instead.
//!
//! Scoped to the trees it was cleaned in. Three fixes apply: move the block
//! down to what it describes, merge it into the block below, or delete it once
//! its subject moved away and is documented there. A paragraph that is a
//! standing note rather than any declaration's documentation is a plain
//! `/* … */` comment, which this does not read.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where this holds. Widening it is a cleanup first: the rule cannot land on a
/// tree that still has orphans in it, so a new directory joins this list in the
/// same change that empties it.
const roots = [_][]const u8{ "apps/rooms", "bindings/ts" };

fn isSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
}

fn checkFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    body: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var number: usize = 0;
    // Where the last doc block closed, zero once an ordinary line has answered
    // it. Only a block that opened with `/**` sets this: a plain `/* … */` note
    // above a doc comment is two different remarks, not one stranded one.
    var closed_at: usize = 0;
    var inside = false;
    var blank_since = true;
    while (lines.next()) |line| {
        number += 1;
        const text = std.mem.trim(u8, line, " \t\r");
        if (inside) {
            if (std.mem.endsWith(u8, text, "*/")) {
                inside = false;
                closed_at = number;
                blank_since = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, text, "/**")) {
            if (closed_at != 0 and blank_since) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}:{d}: nothing but blank lines since the doc comment that ended at line {d}, so that one documents nothing",
                    .{ path, number, closed_at },
                );
            }
            // A one-line `/** … */` opens and closes on the same line.
            if (std.mem.endsWith(u8, text, "*/")) {
                closed_at = number;
                blank_since = true;
            } else inside = true;
            continue;
        }
        if (text.len != 0) {
            blank_since = false;
            closed_at = 0;
        }
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
            try appendViolation(gpa, violations, "{s}: failed to open for the doc-orphan check", .{root_path});
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
