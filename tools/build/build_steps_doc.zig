//! The build-step inventory in `docs/build-steps.md`, written from the graph.
//!
//! The document owns one fact by hand: which subject each step belongs to,
//! as the section a bare `zig build <name>` row sits in. Every other fact on
//! a row comes from the build graph at configure time. The description is the
//! one the step declares, and "part of" names the steps that run it, derived
//! from step dependencies and reduced to the nearest containers, so a claim
//! of gate membership can never be asserted by hand. A row with arguments
//! after the name is a usage example and stays as written.
//!
//! `gen-build-steps` rewrites the document. `gen-build-steps-check`, part of
//! `source-check`, refuses a stale document, a row that names no step, and a
//! step with no row. Both register last, after every other registrar, so the
//! graph they read is complete, and the document is a configure input, so an
//! edit to it reruns the configure phase that reads it.
const std = @import("std");
const execution = @import("execution.zig");
const Step = std.Build.Step;

pub const doc_path = "docs/build-steps.md";

/// Zig's own top-level steps: never declared here, never listed.
const builtin_steps = [_][]const u8{ "install", "uninstall" };

pub fn register(b: *std.Build, source_check_step: *Step) void {
    const check_step = b.step("gen-build-steps-check", "Verify every bare `zig build` row in docs/build-steps.md carries its step's description and containing steps, and every step has a row (fails if stale)");
    source_check_step.dependOn(check_step);
    const gen_step = b.step("gen-build-steps", "Rewrite every bare `zig build` row in docs/build-steps.md from the build graph");
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/build/build_steps_doc.zig"), .target = b.graph.host }) });
    source_check_step.dependOn(&execution.addZigTest(b, tests, .unit_test).step);
    // A cold configure with lazy dependencies still to fetch is run again by
    // the build runner once they are present, with their steps in the graph.
    if (b.graph.needed_lazy_dependencies.count() > 0) return;

    // Configure output is cached; the document is read here, so its
    // contents are a configure input or an edit to it would go unseen.
    b.dependOnFileContents(b.path(doc_path));
    const gpa = b.allocator;
    const current = b.root.root_dir.handle.readFileAlloc(b.graph.io, doc_path, gpa, .limited(1 << 20)) catch |err| {
        const fail = b.addFail(b.fmt("{s}: cannot read the step inventory ({s})", .{ doc_path, @errorName(err) }));
        check_step.dependOn(&fail.step);
        gen_step.dependOn(&fail.step);
        return;
    };
    const inventory = inventoryOf(b);
    const rendered = render(gpa, current, inventory) catch @panic("OOM");

    const update = b.addUpdateSourceFiles();
    update.addBytesToSource(rendered.text, doc_path);
    gen_step.dependOn(&update.step);

    if (rendered.problems.len > 0) {
        const joined = std.mem.join(gpa, "\n", rendered.problems) catch @panic("OOM");
        check_step.dependOn(&b.addFail(joined).step);
    } else if (!std.mem.eql(u8, rendered.text, current)) {
        check_step.dependOn(&b.addFail(doc_path ++ " is stale against the build graph; run `zig build gen-build-steps`").step);
    }
}

/// One top-level step as the document shows it.
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    /// The nearest steps that run this one, sorted by name.
    part_of: []const []const u8,
};

/// Every declared top-level step with its nearest containers, in declaration
/// order.
fn inventoryOf(b: *std.Build) []const Entry {
    const gpa = b.allocator;
    const all = b.top_level_steps.values();
    var reach = gpa.alloc(std.AutoHashMap(*Step, void), all.len) catch @panic("OOM");
    for (all, 0..) |top, i| {
        reach[i] = std.AutoHashMap(*Step, void).init(gpa);
        collectReach(gpa, &reach[i], &top.step);
    }
    // contains[g * n + s]: running g runs everything s runs.
    const n = all.len;
    const contains = gpa.alloc(bool, n * n) catch @panic("OOM");
    for (0..n) |gi| {
        for (all, 0..) |s, si| {
            contains[gi * n + si] = gi != si and runs(&reach[gi], &s.step);
        }
    }
    var entries: std.ArrayList(Entry) = .empty;
    for (all, 0..) |top, si| {
        if (isBuiltin(top.step.name)) continue;
        var part_of: std.ArrayList([]const u8) = .empty;
        for (all, 0..) |g, gi| {
            if (!immediate(contains, n, gi, si)) continue;
            part_of.append(gpa, g.step.name) catch @panic("OOM");
        }
        std.mem.sort([]const u8, part_of.items, {}, lessThan);
        entries.append(gpa, .{ .name = top.step.name, .description = top.description, .part_of = part_of.items }) catch @panic("OOM");
    }
    return entries.items;
}

fn isBuiltin(name: []const u8) bool {
    for (builtin_steps) |builtin| if (std.mem.eql(u8, name, builtin)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every step reachable from `root` through dependencies, `root` included.
fn collectReach(gpa: std.mem.Allocator, out: *std.AutoHashMap(*Step, void), root: *Step) void {
    var stack: std.ArrayList(*Step) = .empty;
    stack.append(gpa, root) catch @panic("OOM");
    while (stack.pop()) |step| {
        const slot = out.getOrPut(step) catch @panic("OOM");
        if (slot.found_existing) continue;
        for (step.dependencies.items) |dep| stack.append(gpa, dep) catch @panic("OOM");
    }
}

/// Whether a gate whose reach is `reach` runs everything `step` runs: the
/// step itself, or, when the gate wires the step's work directly, each of
/// its dependencies.
fn runs(reach: *const std.AutoHashMap(*Step, void), step: *Step) bool {
    if (reach.contains(step)) return true;
    if (step.dependencies.items.len == 0) return false;
    for (step.dependencies.items) |dep| if (!reach.contains(dep)) return false;
    return true;
}

/// Whether `g` is a nearest container of `s`: it contains `s`, `s` does not
/// contain it back (an alias is no container), and no other container of `s`
/// sits strictly between them.
fn immediate(contains: []const bool, n: usize, g: usize, s: usize) bool {
    if (!contains[g * n + s] or contains[s * n + g]) return false;
    for (0..n) |m| {
        if (m == g or m == s) continue;
        if (contains[m * n + s] and contains[g * n + m] and !contains[m * n + g] and !contains[s * n + m]) return false;
    }
    return true;
}

pub const Rendered = struct {
    text: []const u8,
    /// Each a complete sentence naming the file and the fix. Empty when the
    /// rows and the graph agree.
    problems: []const []const u8,
};

/// The document with every bare row inside a fenced block rewritten from
/// `inventory`, and the problems the rows and the inventory have with each
/// other.
pub fn render(gpa: std.mem.Allocator, current: []const u8, inventory: []const Entry) !Rendered {
    var by_name = std.StringHashMap(usize).init(gpa);
    for (inventory, 0..) |entry, i| try by_name.put(entry.name, i);
    const seen = try gpa.alloc(bool, inventory.len);
    @memset(seen, false);

    var text: std.ArrayList(u8) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var fenced = false;
    var width: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, current, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, line, "```")) {
            fenced = !fenced;
            if (fenced) width = blockWidth(lines.rest());
        }
        const name = if (fenced) bareRowName(line) else null;
        if (name == null) {
            try text.appendSlice(gpa, line);
            if (lines.peek() != null) try text.append(gpa, '\n');
            continue;
        }
        const index = by_name.get(name.?) orelse {
            try problems.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{d}: `zig build {s}` names no step; remove the row or declare the step", .{ doc_path, line_no, name.? }));
            try text.appendSlice(gpa, line);
            if (lines.peek() != null) try text.append(gpa, '\n');
            continue;
        };
        if (seen[index]) {
            try problems.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{d}: `zig build {s}` has a second row; keep the one under its subject", .{ doc_path, line_no, name.? }));
        }
        seen[index] = true;
        try appendRow(gpa, &text, inventory[index], width);
        if (lines.peek() != null) try text.append(gpa, '\n');
    }
    for (inventory, 0..) |entry, i| {
        if (seen[i]) continue;
        try problems.append(gpa, try std.fmt.allocPrint(gpa, "{s}: step `{s}` has no row; add `zig build {s}` under its subject and run `zig build gen-build-steps`", .{ doc_path, entry.name, entry.name }));
    }
    return .{ .text = text.items, .problems = problems.items };
}

/// The step name of a bare row: `zig build <name>` followed by nothing but
/// its comment. A row with arguments after the name is a usage example.
fn bareRowName(line: []const u8) ?[]const u8 {
    const prefix = "zig build ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const after = line[prefix.len..];
    const end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const name = after[0..end];
    if (name.len == 0 or name[0] == '-') return null;
    const rest = std.mem.trimStart(u8, after[end..], " ");
    if (rest.len != 0 and rest[0] != '#') return null;
    return name;
}

/// The longest bare name in the fenced block that starts at `rest`, so every
/// comment in the block starts in one column.
fn blockWidth(rest: []const u8) usize {
    var width: usize = 0;
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) break;
        const name = bareRowName(line) orelse continue;
        width = @max(width, name.len);
    }
    return width;
}

fn appendRow(gpa: std.mem.Allocator, text: *std.ArrayList(u8), entry: Entry, width: usize) !void {
    try text.appendSlice(gpa, "zig build ");
    try text.appendSlice(gpa, entry.name);
    try text.appendNTimes(gpa, ' ', width - entry.name.len + 1);
    try text.appendSlice(gpa, "# ");
    try text.appendSlice(gpa, entry.description);
    if (entry.part_of.len == 0) return;
    try text.appendSlice(gpa, "; part of ");
    for (entry.part_of, 0..) |name, i| {
        if (i > 0) try text.appendSlice(gpa, ", ");
        try text.appendSlice(gpa, name);
    }
}

test "bare rows are rewritten, examples and prose stay, and the rest is reported" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const inventory = [_]Entry{
        .{ .name = "check", .description = "the gate", .part_of = &.{} },
        .{ .name = "fmt-check", .description = "formatting", .part_of = &.{"check"} },
        .{ .name = "orphan", .description = "unlisted", .part_of = &.{} },
    };
    const current =
        \\Prose with `zig build check` inline.
        \\
        \\```sh
        \\zig build check # stale words
        \\zig build fmt-check   # also stale; part of nothing
        \\zig build check -Dtest-filter=x # an example, kept
        \\zig build missing # names nothing
        \\```
        \\zig build check # outside a fence, prose
    ;
    const rendered = try render(arena.allocator(), current, &inventory);
    try std.testing.expectEqualStrings(
        \\Prose with `zig build check` inline.
        \\
        \\```sh
        \\zig build check     # the gate
        \\zig build fmt-check # formatting; part of check
        \\zig build check -Dtest-filter=x # an example, kept
        \\zig build missing # names nothing
        \\```
        \\zig build check # outside a fence, prose
    , rendered.text);
    try std.testing.expectEqual(@as(usize, 2), rendered.problems.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered.problems[0], "`zig build missing` names no step") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.problems[1], "step `orphan` has no row") != null);
}

test "a second row for one step is reported" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const inventory = [_]Entry{.{ .name = "check", .description = "the gate", .part_of = &.{} }};
    const rendered = try render(arena.allocator(), "```\nzig build check\nzig build check #\n```\n", &inventory);
    try std.testing.expectEqualStrings("```\nzig build check # the gate\nzig build check # the gate\n```\n", rendered.text);
    try std.testing.expectEqual(@as(usize, 1), rendered.problems.len);
}

test "nearest containers skip aliases and anything a smaller container already covers" {
    // 0 runs 1 runs 2; 3 is an alias of 2 (each runs the other).
    const n = 4;
    var contains: [n * n]bool = @splat(false);
    contains[0 * n + 1] = true;
    contains[0 * n + 2] = true;
    contains[1 * n + 2] = true;
    contains[0 * n + 3] = true;
    contains[1 * n + 3] = true;
    contains[2 * n + 3] = true;
    contains[3 * n + 2] = true;
    try std.testing.expect(immediate(&contains, n, 1, 2));
    try std.testing.expect(!immediate(&contains, n, 0, 2));
    try std.testing.expect(!immediate(&contains, n, 3, 2));
    try std.testing.expect(!immediate(&contains, n, 2, 3));
    try std.testing.expect(immediate(&contains, n, 1, 3));
    try std.testing.expect(immediate(&contains, n, 0, 1));
}
