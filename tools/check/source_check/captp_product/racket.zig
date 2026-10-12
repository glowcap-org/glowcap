//! Racket script hygiene: balanced parens in the scripts no compiler reads
//! before a live run does.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// The public dogfood root is a thin aggregate, while its
/// scenario modules stay outside the package. Hold all three facts together:
/// every scenario is required once, no stale aggregate entry survives, and
/// catalog installation omits the complete test tree.
pub fn checkBindingTestAggregate(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const aggregate_path = "bindings/racket/zig-smoke.rkt";
    const scenarios_path = "bindings/racket/test/zig-smoke";
    const aggregate = root.readFileAlloc(io, aggregate_path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read Racket dogfood aggregate with {s}", .{ aggregate_path, @errorName(err) });
        return;
    };
    defer gpa.free(aggregate);
    const require_form = findRequireForm(aggregate) orelse {
        try appendViolation(gpa, violations, "{s}: missing its scenario `require` form", .{aggregate_path});
        return;
    };

    var dir = root.openDir(io, scenarios_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open Racket dogfood scenarios with {s}", .{ scenarios_path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var scenario_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".rkt")) continue;
        if (std.mem.eql(u8, entry.path, "support.rkt")) continue;
        scenario_count += 1;
        const required = try std.fmt.allocPrint(gpa, "test/zig-smoke/{s}", .{entry.path});
        defer gpa.free(required);
        const count = stringLiteralCount(require_form, required);
        if (count != 1) {
            try appendViolation(gpa, violations, "{s}: scenario `{s}` must appear exactly once in the aggregate require form; found {d}", .{ aggregate_path, required, count });
        }
    }
    const support = "test/zig-smoke/support.rkt";
    const support_count = stringLiteralCount(require_form, support);
    if (support_count != 1) {
        try appendViolation(gpa, violations, "{s}: shared scenario support must appear exactly once in the aggregate require form; found {d}", .{ aggregate_path, support_count });
    }
    const aggregate_count = prefixedStringLiteralCount(require_form, "test/zig-smoke/");
    if (aggregate_count != scenario_count + 1) {
        try appendViolation(gpa, violations, "{s}: aggregate names {d} scenario paths but the directory owns {d} scenarios plus support; remove stale or duplicate entries", .{ aggregate_path, aggregate_count, scenario_count });
    }
    try expectFileContains(io, gpa, root, violations, "bindings/racket/info.rkt", &.{"(define compile-omit-paths '(\"zig-smoke.rkt\" \"test\"))"});
    try expectFileContains(io, gpa, root, violations, "bindings/racket/info.rkt", &.{"(define source-omit-files '(\"zig-smoke.rkt\" \"zig-smoke-fake-tor.rkt\" \"test\"))"});
}

fn findRequireForm(contents: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < contents.len) {
        skipTrivia(contents, &i);
        if (i >= contents.len) break;
        if (std.mem.startsWith(u8, contents[i..], "(require") and
            (i + 8 == contents.len or isDelimiter(contents[i + 8])))
        {
            const start = i;
            var depth: usize = 0;
            while (i < contents.len) : (i += 1) {
                if (contents[i] == ';') {
                    while (i < contents.len and contents[i] != '\n') : (i += 1) {}
                    continue;
                }
                if (contents[i] == '"') {
                    skipString(contents, &i);
                    continue;
                }
                if (contents[i] == '(') depth += 1;
                if (contents[i] == ')') {
                    depth -= 1;
                    if (depth == 0) return contents[start .. i + 1];
                }
            }
            return null;
        }
        i += 1;
    }
    return null;
}

fn stringLiteralCount(contents: []const u8, wanted: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        if (contents[i] == ';') {
            while (i < contents.len and contents[i] != '\n') : (i += 1) {}
        } else if (contents[i] == '"') {
            const start = i + 1;
            skipString(contents, &i);
            if (i <= contents.len and std.mem.eql(u8, contents[start..i], wanted)) count += 1;
        }
    }
    return count;
}

fn prefixedStringLiteralCount(contents: []const u8, prefix: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        if (contents[i] == ';') {
            while (i < contents.len and contents[i] != '\n') : (i += 1) {}
        } else if (contents[i] == '"') {
            const start = i + 1;
            skipString(contents, &i);
            if (i <= contents.len and std.mem.startsWith(u8, contents[start..i], prefix)) count += 1;
        }
    }
    return count;
}

fn skipTrivia(contents: []const u8, i: *usize) void {
    while (i.* < contents.len) {
        if (std.ascii.isWhitespace(contents[i.*])) {
            i.* += 1;
        } else if (contents[i.*] == ';') {
            while (i.* < contents.len and contents[i.*] != '\n') i.* += 1;
        } else break;
    }
}

fn skipString(contents: []const u8, i: *usize) void {
    i.* += 1;
    while (i.* < contents.len) : (i.* += 1) {
        if (contents[i.*] == '\\') {
            i.* += 1;
        } else if (contents[i.*] == '"') return;
    }
}

fn isDelimiter(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '(' or byte == ')' or byte == '[' or byte == ']';
}

test "Racket aggregate parser ignores comments and rejects duplicate scenario literals" {
    const source =
        \\#lang racket/base
        \\; (require "test/zig-smoke/comment.rkt")
        \\(require "test/zig-smoke/support.rkt"
        \\         "test/zig-smoke/one.rkt"
        \\         "test/zig-smoke/one.rkt")
    ;
    const form = findRequireForm(source).?;
    try std.testing.expectEqual(@as(usize, 2), stringLiteralCount(form, "test/zig-smoke/one.rkt"));
    try std.testing.expectEqual(@as(usize, 3), prefixedStringLiteralCount(form, "test/zig-smoke/"));
    try std.testing.expectEqual(@as(usize, 0), stringLiteralCount(form, "test/zig-smoke/comment.rkt"));
}

/// Every Racket script under `conformance/goblins-peer/racket/` must read as
/// balanced s-expressions. The hermetic gate cannot run Goblins, so a script
/// with an unclosed paren ships silently, and every live step that spawns it
/// watches a dialer die at parse. Reader-level only: strings, `;` line
/// comments, and `#\` char literals are skipped. This is not an expander.
pub fn checkRacketScriptBalance(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "conformance/goblins-peer/racket";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for paren-balance check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".rkt")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for paren-balance check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (racketParenImbalance(contents)) |imbalance| {
            try appendViolation(gpa, violations, "{s}: unbalanced s-expressions (net depth {d} at end of file) — a script that cannot read parks every live step that spawns it", .{ path, imbalance });
        }
    }
}

/// Net open-parens at end of file (positive: unclosed openers, negative: an
/// extra closer, reported at first dip), or null when balanced. Treats (),
/// [], {} uniformly and skips strings, `;` comments, and `#\` char literals.
fn racketParenImbalance(contents: []const u8) ?isize {
    var depth: isize = 0;
    var i: usize = 0;
    while (i < contents.len) : (i += 1) {
        switch (contents[i]) {
            ';' => while (i < contents.len and contents[i] != '\n') {
                i += 1;
            },
            '"' => {
                i += 1;
                while (i < contents.len) : (i += 1) {
                    if (contents[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (contents[i] == '"') break;
                }
            },
            '#' => if (i + 1 < contents.len and contents[i + 1] == '\\') {
                i += 2;
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth < 0) return depth;
            },
            else => {},
        }
    }
    return if (depth == 0) null else depth;
}
