//! The threat model's coverage, held to the code. `docs/threat-model.md` has
//! one entry per untrusted input, and each entry names what bounds the input
//! and which test proves the refusal. A limit the code declares with no row,
//! an inbound operation with no entry, or a cited test that does not exist is
//! a hole the page cannot see, so this reads the declarations and holds the
//! page to them.

const std = @import("std");
const util = @import("../util.zig");
const paths = @import("paths.zig");

const appendViolation = util.appendViolation;

const doc_path = "docs/threat-model.md";
const limits_path = "src/ocapn/session/limits.zig";
const body_path = "src/ocapn/model/view_body.zig";
const ops_path = "src/ocapn/codec/syrup/shared.zig";
const limits_marker = "pub const SessionLimits = struct {";
const body_marker = "pub const Body = union(enum) {";
const section_heading = "## Untrusted inputs";

pub fn checkThreatModelCoverage(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc = readOrReport(io, gpa, root, doc_path, violations) orelse return;
    defer gpa.free(doc);
    const limits = readOrReport(io, gpa, root, limits_path, violations) orelse return;
    defer gpa.free(limits);
    const body = readOrReport(io, gpa, root, body_path, violations) orelse return;
    defer gpa.free(body);
    const ops = readOrReport(io, gpa, root, ops_path, violations) orelse return;
    defer gpa.free(ops);

    const section = util.sectionBody(doc, section_heading) orelse {
        try appendViolation(gpa, violations, "{s}: has no `{s}` section for the coverage check to read", .{ doc_path, section_heading });
        return;
    };
    var rows: Rows = .{};
    defer rows.deinit(gpa);
    try rows.collect(gpa, section);

    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(gpa);
    try declaredNames(gpa, limits, limits_marker, &fields);
    if (fields.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: `{s}` declares no fields the coverage check can read", .{ limits_path, limits_marker });
    }
    for (fields.items) |field| {
        if (!util.containsAsSymbol(rows.bounded.items, field)) {
            try appendViolation(gpa, violations, "{s}: `{s}` is a SessionLimits field with no \"Bounded by\" row under {s}", .{ doc_path, field, section_heading });
        }
        if (!util.containsAsSymbol(rows.proved.items, field)) {
            try appendViolation(gpa, violations, "{s}: no \"Refusal proved by\" row under {s} names `{s}`", .{ doc_path, section_heading, field });
        }
    }

    var arms: std.ArrayList([]const u8) = .empty;
    defer arms.deinit(gpa);
    try declaredNames(gpa, body, body_marker, &arms);
    if (arms.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: `{s}` declares no arms the coverage check can read", .{ body_path, body_marker });
    }
    for (arms.items) |arm| {
        const wire = wireName(ops, arm) orelse {
            try appendViolation(gpa, violations, "{s}: `messageOp` names no wire operation for the `Body` arm `{s}`", .{ ops_path, arm });
            continue;
        };
        if (std.mem.indexOf(u8, section, wire) == null) {
            try appendViolation(gpa, violations, "{s}: the inbound operation `{s}` has no entry under {s}", .{ doc_path, wire, section_heading });
        }
    }

    try checkCitedTests(io, gpa, root, section, violations);
}

fn readOrReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    violations: *std.ArrayList([]const u8),
) ?[]u8 {
    return root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        appendViolation(gpa, violations, "{s}: failed to read for the threat-model coverage check with {s}", .{ path, @errorName(err) }) catch {}; // tolerant: the read failure is the finding, and a report that cannot be appended is out of memory the gate reports itself
        return null;
    };
}

/// The field or arm names a `struct {` or `union(enum) {` block declares at
/// its top level: a line of the form `name: Type,` whose name is a lowercase
/// identifier. Lines inside the block's functions begin with `.`, a keyword,
/// or a call, so none of them match.
fn declaredNames(gpa: std.mem.Allocator, text: []const u8, marker: []const u8, out: *std.ArrayList([]const u8)) !void {
    const block = util.extractBraceBlock(text, marker) orelse return;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ',') continue;
        const colon = std.mem.indexOf(u8, trimmed, ": ") orelse continue;
        const name = trimmed[0..colon];
        if (name.len == 0 or !std.ascii.isLower(name[0])) continue;
        var ident = true;
        for (name) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) ident = false;
        }
        if (!ident) continue;
        try out.append(gpa, name);
    }
}

/// The wire form of a `Body` arm, read from the codec's `messageOp` table,
/// because a name such as `op:gc-exports` is not a transform of its arm.
fn wireName(ops: []const u8, arm: []const u8) ?[]const u8 {
    var buffer: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&buffer, ".{s} => \"", .{arm}) catch return null;
    const start = (std.mem.indexOf(u8, ops, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, ops, start, '"') orelse return null;
    return ops[start..end];
}

/// The text of every "Bounded by" and "Refusal proved by" bullet in the
/// section, each with its indented sub-bullets and wrapped lines, so a limit
/// can be looked up by the row kind that must name it.
const Rows = struct {
    bounded: std.ArrayList(u8) = .empty,
    proved: std.ArrayList(u8) = .empty,

    const Kind = enum { none, bounded, proved, other };

    fn deinit(self: *Rows, gpa: std.mem.Allocator) void {
        self.bounded.deinit(gpa);
        self.proved.deinit(gpa);
    }

    fn collect(self: *Rows, gpa: std.mem.Allocator, section: []const u8) !void {
        var kind: Kind = .none;
        var lines = std.mem.splitScalar(u8, section, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            const indented = trimmed.len < line.len;
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "**")) {
                kind = .none;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "- Bounded by:")) {
                kind = .bounded;
            } else if (std.mem.startsWith(u8, trimmed, "- Refusal proved by:")) {
                kind = .proved;
            } else if (std.mem.startsWith(u8, trimmed, "- ") and !indented) {
                kind = .other;
            }
            const target = switch (kind) {
                .bounded => &self.bounded,
                .proved => &self.proved,
                .none, .other => continue,
            };
            try target.appendSlice(gpa, trimmed);
            try target.append(gpa, '\n');
        }
    }
};

/// Every test the section cites exists under `test/`: a code span ending in
/// `_test.zig`, or one under `support/`, read relative to that directory.
fn checkCitedTests(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    section: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, section, from, '`')) |open| {
        const close = std.mem.indexOfScalarPos(u8, section, open + 1, '`') orelse return;
        from = close + 1;
        const span = section[open + 1 .. close];
        if (std.mem.indexOfAny(u8, span, " \n") != null) continue;
        const cited = std.mem.endsWith(u8, span, "_test.zig") or std.mem.startsWith(u8, span, "support/");
        if (!cited) continue;
        const path = try std.fmt.allocPrint(gpa, "test/{s}", .{span});
        defer gpa.free(path);
        if (!paths.fileExists(io, root, path)) {
            try appendViolation(gpa, violations, "{s}: cites `{s}`, and {s} does not exist", .{ doc_path, span, path });
        }
    }
}

test "declared names come from the block's top-level fields and skip its functions" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    const text =
        \\pub const Body = union(enum) {
        \\    deliver: Deliver,
        \\    gc_export: GcExport,
        \\    /// A doc line, with a colon: kept out.
        \\    pub fn fromOwned(owned: *const Message) Body {
        \\        return switch (owned.*) {
        \\            .deliver => |*d| .{ .deliver = .{
        \\                .target = d.target,
        \\            } },
        \\        };
        \\    }
        \\};
    ;
    try declaredNames(gpa, text, body_marker, &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("deliver", names.items[0]);
    try std.testing.expectEqualStrings("gc_export", names.items[1]);
    const ops =
        \\        .deliver => "op:deliver",
        \\        .gc_export => "op:gc-exports",
    ;
    try std.testing.expectEqualStrings("op:gc-exports", wireName(ops, names.items[1]).?);
    try std.testing.expect(wireName(ops, "gc_answer") == null);
}

test "rows gather each kind with its sub-bullets and stop at the next entry" {
    const gpa = std.testing.allocator;
    var rows: Rows = .{};
    defer rows.deinit(gpa);
    const section =
        \\
        \\**An input**
        \\
        \\- Read by: `reader`
        \\- Bounded by: `cap_a`, and
        \\  `cap_b` on the next line
        \\- Searched by: `cap_c` is named here only
        \\- Refusal proved by:
        \\  - `cap_a`: `a_test.zig`
        \\  - `cap_b`: `b_test.zig`
        \\
        \\**Another**
        \\
        \\- Bounded by: `cap_d`
    ;
    try rows.collect(gpa, section);
    try std.testing.expect(util.containsAsSymbol(rows.bounded.items, "cap_a"));
    try std.testing.expect(util.containsAsSymbol(rows.bounded.items, "cap_b"));
    try std.testing.expect(util.containsAsSymbol(rows.bounded.items, "cap_d"));
    try std.testing.expect(!util.containsAsSymbol(rows.bounded.items, "cap_c"));
    try std.testing.expect(util.containsAsSymbol(rows.proved.items, "cap_b"));
    try std.testing.expect(!util.containsAsSymbol(rows.proved.items, "cap_c"));
    try std.testing.expect(!util.containsAsSymbol(rows.proved.items, "cap_d"));
}
