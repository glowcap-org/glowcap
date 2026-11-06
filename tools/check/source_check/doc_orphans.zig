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
const source_tree = @import("source_tree.zig");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;

/// Where this holds. Widening it is a cleanup first: the rule cannot land on a
/// tree that still has orphans in it, so a new directory joins this list in the
/// same change that empties it.
const roots = [_][]const u8{ "apps/rooms", "bindings/ts" };

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
    var module_doc = false;
    var blank_since = true;
    while (lines.next()) |line| {
        number += 1;
        const text = std.mem.trim(u8, line, " \t\r");
        const tag = std.mem.trimStart(u8, text, "/* \t");
        const is_module_tag = std.mem.startsWith(u8, tag, "@module") and
            (tag.len == 7 or std.ascii.isWhitespace(tag[7]));
        if (inside) {
            module_doc = module_doc or is_module_tag;
            if (std.mem.endsWith(u8, text, "*/")) {
                inside = false;
                // JSDoc's @module describes the file, not a declaration.
                closed_at = if (module_doc) 0 else number;
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
            module_doc = is_module_tag;
            if (std.mem.endsWith(u8, text, "*/")) {
                closed_at = if (module_doc) 0 else number;
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

const Sink = struct {
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),

    fn visit(self: Sink, path: []const u8, contents: []u8) std.mem.Allocator.Error!void {
        try checkFile(self.gpa, path, contents, self.violations);
    }
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (roots) |root_path| {
        try source_tree.visitSourceFiles(io, gpa, root, violations, "doc-orphan", root_path, &source_tree.isTypeScriptPath, Sink{ .gpa = gpa, .violations = violations }, Sink.visit);
    }
}

test "module documentation may precede a declaration's own docs, orphaned prose may not" {
    const cases = .{
        .{ "/** Package overview.\n * @module\n */\n\n/** Measure text. */\nexport function size() {}", 0 },
        .{ "/** @module */\n/** Measure text. */\nexport function size() {}", 0 },
        .{ "/** Stranded description. */\n\n/** Measure text. */\nexport function size() {}", 1 },
        .{ "/** @moduleName is not a module tag. */\n/** Measure text. */\nexport function size() {}", 1 },
    };
    inline for (cases) |case| {
        const gpa = std.testing.allocator;
        var violations: std.ArrayList([]const u8) = .empty;
        defer {
            for (violations.items) |message| gpa.free(message);
            violations.deinit(gpa);
        }
        try checkFile(gpa, "module.ts", case[0], &violations);
        try std.testing.expectEqual(@as(usize, case[1]), violations.items.len);
    }
}
