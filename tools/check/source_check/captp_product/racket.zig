//! Racket script hygiene: balanced parens in the scripts no compiler reads
//! before a live run does.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// Every Racket script under `conformance/goblins-peer/racket/` must read as
/// balanced s-expressions. The hermetic gate cannot run Goblins, so a script
/// with an unclosed paren ships silently, and every live step that spawns it
/// watches a dialer die at parse. Reader-level only: strings, `;` line
/// comments, and `#\` char literals are skipped; this is not an expander.
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

/// Net open-parens at end of file (positive: unclosed openers; negative: an
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
