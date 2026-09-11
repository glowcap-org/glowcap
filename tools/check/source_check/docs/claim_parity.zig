//! Cross-page claims the compiler cannot see: a second sentence that
//! restates an already-owned status fact, and a first-read pointer that
//! presents the testing walk as the complete program.

const std = @import("std");
const util = @import("../util.zig");
const inventories = @import("inventories.zig");

const appendViolation = util.appendViolation;

pub fn checkStabilityAreaTableRecurringClaims(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/stability.md";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = root.readFileAlloc(io, doc_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for area-table recurring check with {s}", .{ doc_path, @errorName(err) });
        return;
    };

    const begin = "<!-- ci-gate-list:begin -->";
    const end = "<!-- ci-gate-list:end -->";
    const from = std.mem.indexOf(u8, doc, begin) orelse {
        try appendViolation(gpa, violations, "{s}: no `{s}` marker; the area table cannot be checked against the gate list", .{ doc_path, begin });
        return;
    };
    const to = std.mem.indexOf(u8, doc, end) orelse {
        try appendViolation(gpa, violations, "{s}: no `{s}` marker; the area table cannot be checked against the gate list", .{ doc_path, end });
        return;
    };
    if (to < from) {
        try appendViolation(gpa, violations, "{s}: gate-list markers are out of order", .{doc_path});
        return;
    }

    var listed: std.ArrayList([]const u8) = .empty;
    try inventories.collectBuildSteps(arena, doc[from + begin.len .. to], "- `zig build ", &listed);

    const header = "| Area | Evidence | What remains |";
    const hit = std.mem.indexOf(u8, doc, header) orelse {
        try appendViolation(gpa, violations, "{s}: missing the area evidence table this check treats as the claim surface", .{doc_path});
        return;
    };

    var rest = doc[hit + header.len ..];
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const row = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!std.mem.startsWith(u8, rest, "| ")) {
            if (row.len == 0 or std.mem.startsWith(u8, row, "| ")) continue;
            break;
        }
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        if (std.mem.startsWith(u8, line, "| ---")) continue;

        const evidence = nthCell(line, 1) orelse continue;
        const remains = nthCell(line, 2) orelse continue;

        const on_demand_at = indexOfInsensitive(evidence, "on-demand") orelse
            indexOfInsensitive(evidence, "on demand");
        if (on_demand_at) |at| {
            try rejectRecurringNames(gpa, violations, doc_path, evidence[at..], listed.items, "Evidence labels `{s}` on-demand, but it is in the recurring gate list");
        }
        if (std.mem.indexOf(u8, remains, "not in the recurring list") != null or
            indexOfInsensitive(remains, "on demand") != null or
            indexOfInsensitive(remains, "on-demand") != null)
        {
            try rejectRecurringNames(gpa, violations, doc_path, remains, listed.items, "What remains names recurring `{s}` as not in the recurring list");
        }
    }
}

pub fn checkSiteStabilitySummary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const site_path = "site/content/stability.smd";
    const ci_path = "ci/gates.sh";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const site = root.readFileAlloc(io, site_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for site stability-summary check with {s}", .{ site_path, @errorName(err) });
        return;
    };
    const ci = root.readFileAlloc(io, ci_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for site stability-summary check with {s}", .{ ci_path, @errorName(err) });
        return;
    };

    if (std.mem.indexOf(u8, site, "pull request") == null) {
        try appendViolation(gpa, violations, "{s}: recurring-check summary must mention pull requests; `.github/workflows/check.yml` runs them", .{site_path});
    }
    if (std.mem.indexOf(u8, site, "`dev`") == null) {
        try appendViolation(gpa, violations, "{s}: recurring-check summary must mention the `dev` branch; `.github/workflows/check.yml` runs there too", .{site_path});
    }
    if (std.mem.indexOf(u8, ci, "web-peer-test") != null and
        std.mem.indexOf(u8, site, "browsers that CI does not install") != null)
    {
        try appendViolation(gpa, violations, "{s}: says CI does not install browsers, but {s} runs `web-peer-test`", .{ site_path, ci_path });
    }
}

pub fn checkPerformanceLiveSocket(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const site_path = "site/content/performance.smd";
    const ladder_path = "docs/ladder.md";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const site = root.readFileAlloc(io, site_path, arena, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for live-socket check with {s}", .{ site_path, @errorName(err) });
        return;
    };
    const ladder = root.readFileAlloc(io, ladder_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for live-socket check with {s}", .{ ladder_path, @errorName(err) });
        return;
    };

    if (std.mem.indexOf(u8, ladder, "--live-max=500000") == null) return;
    if (std.mem.indexOf(u8, site, "not a live-socket") != null or
        std.mem.indexOf(u8, site, "extrapolation, not a live") != null)
    {
        try appendViolation(gpa, violations, "{s}: denies a live-socket 500k run that {s} still records (`--live-max=500000`)", .{ site_path, ladder_path });
    }
}

pub fn checkStartCompleteProgram(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "site/content/start.smd";
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for complete-program check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    if (std.mem.indexOf(u8, contents, "01_connect_and_serve") != null) {
        try appendViolation(gpa, violations, "{s}: cites the TCP chapter as the complete program; point at rooms (first-impression)", .{path});
    }
}

pub fn checkExamplesLeadWithRooms(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "examples/README.md";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for examples-lead check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    const zig_h = std.mem.indexOf(u8, contents, "## Zig chapters");
    const apps_h = std.mem.indexOf(u8, contents, "## Complete applications");
    if (zig_h != null and (apps_h == null or zig_h.? < apps_h.?)) {
        try appendViolation(gpa, violations, "{s}: Complete applications must precede Zig chapters; rooms is the first look (first-impression)", .{path});
    }
}

pub fn checkDeliverOneWay(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "site/content/protocol.smd";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for op:deliver check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    const row_start = std.mem.indexOf(u8, contents, "| `op:deliver` |") orelse {
        try appendViolation(gpa, violations, "{s}: missing the `op:deliver` row", .{path});
        return;
    };
    const rest = contents[row_start..];
    const row_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const row = rest[0..row_end];
    const lower = try gpa.alloc(u8, row.len);
    defer gpa.free(lower);
    _ = std.ascii.lowerString(lower, row);
    if (std.mem.indexOf(u8, row, "#f") == null and std.mem.indexOf(u8, lower, "one-way") == null) {
        try appendViolation(gpa, violations, "{s}: `op:deliver` row must name the answerless `#f` / one-way form; there is no `op:deliver-only`", .{path});
    }
}

pub fn checkSessionIsAView(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "site/content/modules.smd";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Session-ownership check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    const row_start = std.mem.indexOf(u8, contents, "| **Session** |") orelse {
        try appendViolation(gpa, violations, "{s}: missing the Session row", .{path});
        return;
    };
    const rest = contents[row_start..];
    const row_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const row = rest[0..row_end];
    const lower = try gpa.alloc(u8, row.len);
    defer gpa.free(lower);
    _ = std.ascii.lowerString(lower, row);
    if (std.mem.indexOf(u8, lower, "view") == null) {
        try appendViolation(gpa, violations, "{s}: Session row must say it is a view; HostRuntime owns the conversation (docs/architecture.md)", .{path});
    }
}

fn nthCell(line: []const u8, n: usize) ?[]const u8 {
    var rest = std.mem.trim(u8, line, " \t\r");
    if (rest.len == 0 or rest[0] != '|') return null;
    rest = rest[1..];
    var i: usize = 0;
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, '|') orelse return null;
        const cell = std.mem.trim(u8, rest[0..end], " \t");
        if (i == n) return cell;
        rest = rest[end + 1 ..];
        i += 1;
        if (rest.len == 0) return null;
    }
}

fn rejectRecurringNames(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    doc_path: []const u8,
    haystack: []const u8,
    listed: []const []const u8,
    comptime fmt: []const u8,
) !void {
    var scan = haystack;
    while (std.mem.indexOfScalar(u8, scan, '`')) |open| {
        const after = scan[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '`') orelse break;
        const name = after[0..close];
        scan = after[close + 1 ..];
        if (containsStep(listed, name)) {
            try appendViolation(gpa, violations, "{s}: " ++ fmt, .{ doc_path, name });
        }
    }
}

fn indexOfInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn containsStep(steps: []const []const u8, needle: []const u8) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step, needle)) return true;
    }
    return false;
}

test "nthCell reads markdown table columns" {
    const line = "| `keyed-relay` | In-tree `check`. On-demand (`foo`) | still on demand. |";
    try std.testing.expectEqualStrings("`keyed-relay`", nthCell(line, 0).?);
    try std.testing.expectEqualStrings("In-tree `check`. On-demand (`foo`)", nthCell(line, 1).?);
    try std.testing.expectEqualStrings("still on demand.", nthCell(line, 2).?);
    try std.testing.expect(nthCell(line, 3) == null);
}

test "containsStep matches a listed gate name" {
    const listed = [_][]const u8{ "check", "bindings-keyed-relay-rendezvous" };
    try std.testing.expect(containsStep(&listed, "bindings-keyed-relay-rendezvous"));
    try std.testing.expect(!containsStep(&listed, "zig-keyed-relay-register"));
}
