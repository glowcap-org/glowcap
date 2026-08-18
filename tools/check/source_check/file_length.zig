//! First-party source-file length ratchet.
//!
//! A source file has one subject and must fit in one attentive read. New files
//! stop at 650 lines. The exception inventory is closed legacy debt: no new
//! path may enter it. Existing overages are pinned to their present size,
//! growth fails, shrinkage lowers the ceiling, and reaching the project limit
//! retires the exception.
//!
//! The destination is an empty inventory, and who owes it is settled: whoever
//! opens the file. This is inherited work, not its authors' backlog, and a
//! session that edits one of these files and leaves it the same length has
//! declined a turn at it
//! ([project-values](../../../.agents/rules/project-values.md)). The counts
//! below are that debt, and they only ever go down.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

const max_lines: usize = 650;

/// How many files are still over the limit. Exact, and it only ever goes down:
/// retiring one lowers it, and nothing may raise it, because the list is closed.
const exception_count: usize = 40;

/// Every line the exceptions below hold above `max_lines`, added up. Exact, like
/// the ceilings it sums: a split lowers it, and nothing raises it, so a
/// reduction cannot be quietly spent by a later diff.
const exception_debt_lines: usize = 39866;

const Exception = struct {
    path: []const u8,
    ceiling: usize,
};

/// Closed legacy debt, sorted largest first so the next split target is visible.
/// Never add a row. A ceiling is an exact maximum for non-additive corrections,
/// never headroom; any shrink must pin the lower count in this table.
const exceptions = [_]Exception{
    .{ .path = "src/driver/host_runtime.zig", .ceiling = 4528 },
    .{ .path = "src/driver/core/host.zig", .ceiling = 4237 },
    .{ .path = "src/ocapn/engine/node.zig", .ceiling = 4237 },
    .{ .path = "bindings/racket/zig-smoke.rkt", .ceiling = 3453 },
    .{ .path = "src/net/completion/loop.zig", .ceiling = 2511 },
    .{ .path = "bindings/rust/src/session_tests.rs", .ceiling = 2299 },
    .{ .path = "bindings/rust/src/host.rs", .ceiling = 2225 },
    .{ .path = "src/ocapn/engine/mod.zig", .ceiling = 1939 },
    .{ .path = "bindings/rust/src/driver_loop.rs", .ceiling = 1799 },
    .{ .path = "src/c_abi/net_transport/onion/mod.zig", .ceiling = 1766 },
    .{ .path = "bindings/rust/src/lib.rs", .ceiling = 1747 },
    .{ .path = "src/ocapn/codec/syrup/decode.zig", .ceiling = 1746 },
    .{ .path = "src/c_abi/driver/provider_registry.zig", .ceiling = 1727 },
    .{ .path = "src/ocapn/session/mod.zig", .ceiling = 1666 },
    .{ .path = "bindings/python/pancake/_host.py", .ceiling = 1565 },
    .{ .path = "bindings/python/pancake/_loop.py", .ceiling = 1542 },
    .{ .path = "src/actors/vat/mod.zig", .ceiling = 1525 },
    .{ .path = "src/c_abi/shared/mod.zig", .ceiling = 1488 },
    .{ .path = "bindings/ts/runtime/driver_loop.ts", .ceiling = 1450 },
    .{ .path = "src/net/transport/webrtc.zig", .ceiling = 1433 },
    .{ .path = "src/net/transport/iroh.zig", .ceiling = 1410 },
    .{ .path = "src/c_abi/driver/loop.zig", .ceiling = 1302 },
    .{ .path = "bindings/ts/runtime/host.ts", .ceiling = 1300 },
    .{ .path = "bindings/ts/runtime/session.ts", .ceiling = 1285 },
    .{ .path = "src/c_abi/net_transport/iroh/mod.zig", .ceiling = 1283 },
    .{ .path = "bindings/racket/private/loop.rkt", .ceiling = 1136 },
    .{ .path = "src/c_abi/net_transport/tcp/mod.zig", .ceiling = 1116 },
    .{ .path = "bindings/python/pancake/_session.py", .ceiling = 1115 },
    .{ .path = "bindings/racket/private/session.rkt", .ceiling = 1099 },
    .{ .path = "src/ocapn/engine/bootstrap.zig", .ceiling = 1076 },
    .{ .path = "src/ocapn/codec/capnp/decode.zig", .ceiling = 1014 },
    .{ .path = "src/ocapn/session/validate.zig", .ceiling = 979 },
    .{ .path = "bindings/python/smoke/lifecycle.py", .ceiling = 912 },
    .{ .path = "src/oracle/mod.zig", .ceiling = 912 },
    .{ .path = "bindings/rust/src/session.rs", .ceiling = 911 },
    .{ .path = "src/net/transport/onion/completion.zig", .ceiling = 882 },
    .{ .path = "src/net/transport/noise_completion.zig", .ceiling = 865 },
    .{ .path = "bindings/racket/private/host.rkt", .ceiling = 843 },
    .{ .path = "bindings/python/smoke/verbs.py", .ceiling = 817 },
    .{ .path = "bindings/racket/private/iroh.rkt", .ceiling = 726 },
};

const trees = [_][]const u8{
    ".agents",
    ".claude",
    ".codex",
    ".cursor",
    ".devcontainer",
    ".github",
    ".serena",
    "apps",
    "bench",
    "bindings",
    "ci",
    "cli",
    "conformance",
    "docs",
    "examples",
    "include",
    "interop",
    "site",
    "src",
    "test",
    "tools",
    "transports",
    "ui",
};

const root_files = [_][]const u8{
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "SECURITY.md",
    "build.zig",
    "build.zig.zon",
};

fn isSource(path: []const u8) bool {
    for ([_][]const u8{
        ".bash", ".c",  ".css", ".h",    ".html", ".js",  ".jsx",
        ".md",   ".py", ".rkt", ".rs",   ".scm",  ".sh",  ".smd",
        ".toml", ".ts", ".tsx", ".yaml", ".yml",  ".zig", ".zon",
    }) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

fn ignored(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        for ([_][]const u8{
            ".venv",
            ".zig-cache",
            "dist",
            "node_modules",
            "target",
            "upstream",
            "vendor",
            "zig-out",
            "zig-pkg",
        }) |name| {
            if (std.mem.eql(u8, part, name)) return true;
        }
    }
    return false;
}

fn lineCount(contents: []const u8) usize {
    if (contents.len == 0) return 0;
    return std.mem.count(u8, contents, "\n") + @intFromBool(contents[contents.len - 1] != '\n');
}

fn exceptionIndex(path: []const u8) ?usize {
    for (exceptions, 0..) |exception, i| {
        if (std.mem.eql(u8, path, exception.path)) return i;
    }
    return null;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    seen: *[exceptions.len]bool,
) !void {
    if (!isSource(path) or ignored(path)) return;
    const contents = root.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the file-length check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    // Generated files answer to their generator, not to this ratchet: their
    // length is the generation shape's to fix, and a row here would invite
    // hand-edits the GENERATED header forbids. The marker is the first-lines
    // header every generated file in the tree carries.
    const head = contents[0..@min(contents.len, 400)];
    if (std.mem.indexOf(u8, head, "GENERATED by") != null or
        std.mem.indexOf(u8, head, "Generated from") != null) return;

    const lines = lineCount(contents);
    const exception_i = exceptionIndex(path);
    if (exception_i) |i| seen[i] = true;
    if (lines <= max_lines) {
        if (exception_i != null) {
            try appendViolation(gpa, violations, "{s}: now has {d} lines; remove its file-length exception because the project limit is {d}", .{ path, lines, max_lines });
        }
        return;
    }
    const i = exception_i orelse {
        try appendViolation(gpa, violations, "{s}: has {d} lines; the exception inventory is closed, so split it by subject below the {d}-line project limit", .{ path, lines, max_lines });
        return;
    };
    const ceiling = exceptions[i].ceiling;
    if (lines > ceiling) {
        try appendViolation(gpa, violations, "{s}: grew from its explicit {d}-line ceiling to {d}; split it instead of growing the exception", .{ path, ceiling, lines });
    } else if (lines < ceiling) {
        try appendViolation(gpa, violations, "{s}: shrank from {d} to {d} lines; lower its exception ceiling now so those lines cannot return", .{ path, ceiling, lines });
    }
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var seen = [_]bool{false} ** exceptions.len;

    // The per-file ceiling alone lets a diff pay a toll instead of a debt: add
    // three lines, delete three of your own comments, and the file is exactly as
    // long as it was. These two counts are the debt itself, and both move one
    // way, so a reduction is banked where nothing can spend it again.
    if (exceptions.len > exception_count) {
        try appendViolation(gpa, violations, "the exception inventory is closed and now has {d} rows against {d}; split the file instead of giving it a row, however large the split looks next to the change that needed it", .{ exceptions.len, exception_count });
    } else if (exceptions.len < exception_count) {
        try appendViolation(gpa, violations, "{d} files are still over the limit, against {d} recorded; lower `exception_count` to {d} so the retired row cannot come back", .{ exceptions.len, exception_count, exceptions.len });
    }

    var debt: usize = 0;
    for (exceptions) |exception| {
        if (exception.ceiling > max_lines) debt += exception.ceiling - max_lines;
    }
    if (debt > exception_debt_lines) {
        try appendViolation(gpa, violations, "the exceptions now hold {d} lines above the {d}-line limit, over the {d} recorded; a ceiling may hold while a subject is extracted, never rise", .{ debt, max_lines, exception_debt_lines });
    } else if (debt < exception_debt_lines) {
        try appendViolation(gpa, violations, "the exceptions hold {d} lines above the {d}-line limit, under the {d} recorded; lower `exception_debt_lines` to {d} so the reduction cannot be spent again", .{ debt, max_lines, exception_debt_lines, debt });
    }

    for (exceptions, 0..) |exception, i| {
        if (exception.ceiling <= max_lines) {
            try appendViolation(gpa, violations, "{s}: file-length exception ceiling {d} is not above the {d}-line project limit; remove it", .{ exception.path, exception.ceiling, max_lines });
        }
        if (i > 0 and exception.ceiling > exceptions[i - 1].ceiling) {
            try appendViolation(gpa, violations, "{s}: file-length exceptions must stay largest-first so the next split target remains visible", .{exception.path});
        }
        for (exceptions[0..i]) |earlier| {
            if (std.mem.eql(u8, exception.path, earlier.path)) {
                try appendViolation(gpa, violations, "{s}: duplicate file-length exception", .{exception.path});
            }
        }
    }

    for (root_files) |path| try checkFile(io, gpa, root, violations, path, &seen);
    for (trees) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for the file-length check with {s}", .{ tree, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (!ignored(entry.path)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);
            try checkFile(io, gpa, root, violations, path, &seen);
        }
    }

    for (exceptions, seen) |exception, found| {
        if (!found) {
            try appendViolation(gpa, violations, "{s}: file-length exception no longer names a checked source file; remove it", .{exception.path});
        }
    }
}

test "lineCount includes an unterminated final line" {
    try std.testing.expectEqual(@as(usize, 0), lineCount(""));
    try std.testing.expectEqual(@as(usize, 1), lineCount("one"));
    try std.testing.expectEqual(@as(usize, 1), lineCount("one\n"));
    try std.testing.expectEqual(@as(usize, 2), lineCount("one\ntwo"));
}
