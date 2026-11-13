//! The stability page's area table calls a gate recurring only when
//! `ci/groups.py` runs it on every push.

const std = @import("std");
const text_match = @import("../text_match.zig");
const violation_log = @import("../violation_log.zig");
const inventories = @import("inventories.zig");

const appendViolation = violation_log.appendViolation;

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

    const ci_path = inventories.ci_inventory_path;
    const ci = root.readFileAlloc(io, ci_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for area-table recurring check with {s}", .{ ci_path, @errorName(err) });
        return;
    };
    var listed: std.ArrayList([]const u8) = .empty;
    try inventories.collectBuildSteps(arena, ci, inventories.ci_gate_prefix, &listed);

    const header = "| Area | Evidence | What remains |";
    const hit = std.mem.find(u8, doc, header) orelse {
        try appendViolation(gpa, violations, "{s}: missing the area evidence table this check treats as the claim surface", .{doc_path});
        return;
    };

    var rest = doc[hit + header.len ..];
    while (std.mem.findScalar(u8, rest, '\n')) |nl| {
        const row = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!std.mem.startsWith(u8, rest, "| ")) {
            if (row.len == 0 or std.mem.startsWith(u8, row, "| ")) continue;
            break;
        }
        const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        if (std.mem.startsWith(u8, line, "| ---")) continue;

        const evidence = nthCell(line, 1) orelse continue;
        const remains = nthCell(line, 2) orelse continue;

        const on_demand_at = indexOfInsensitive(evidence, "on-demand") orelse
            indexOfInsensitive(evidence, "on demand");
        if (on_demand_at) |at| {
            try rejectRecurringNames(gpa, violations, doc_path, evidence[at..], listed.items, "Evidence labels `{s}` on-demand, but it is in the recurring gate list");
        }
        if (std.mem.find(u8, remains, "not in the recurring list") != null or
            indexOfInsensitive(remains, "on demand") != null or
            indexOfInsensitive(remains, "on-demand") != null)
        {
            try rejectRecurringNames(gpa, violations, doc_path, remains, listed.items, "What remains names recurring `{s}` as not in the recurring list");
        }
    }
}

fn nthCell(line: []const u8, n: usize) ?[]const u8 {
    var rest = std.mem.trim(u8, line, " \t\r");
    if (rest.len == 0 or rest[0] != '|') return null;
    rest = rest[1..];
    var i: usize = 0;
    while (true) {
        const end = std.mem.findScalar(u8, rest, '|') orelse return null;
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
    while (std.mem.findScalar(u8, scan, '`')) |open| {
        const after = scan[open + 1 ..];
        const close = std.mem.findScalar(u8, after, '`') orelse break;
        const name = after[0..close];
        scan = after[close + 1 ..];
        if (text_match.inSet(listed, name)) {
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

test "nthCell reads markdown table columns" {
    const line = "| `keyed-relay` | In-tree `check`. On-demand (`foo`) | still on demand. |";
    try std.testing.expectEqualStrings("`keyed-relay`", nthCell(line, 0).?);
    try std.testing.expectEqualStrings("In-tree `check`. On-demand (`foo`)", nthCell(line, 1).?);
    try std.testing.expectEqualStrings("still on demand.", nthCell(line, 2).?);
    try std.testing.expect(nthCell(line, 3) == null);
}
