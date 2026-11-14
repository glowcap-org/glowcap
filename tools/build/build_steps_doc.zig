//! The build-step inventories, `docs/build-steps.md` and
//! `docs/build-steps-apps.md`, written from the graph.
//!
//! The documents own one fact by hand: which subject each step belongs to,
//! as the document and section a bare `zig build <name>` row sits in. Every other fact on
//! a row comes from the default host build graph at configure time. The
//! description is the one the step declares, and "part of" names the steps
//! that run it, derived from dependencies and reduced to nearest containers.
//! Gate membership can never be asserted by hand. A row with arguments
//! after the name is a usage example and stays as written.
//!
//! `gen-build-steps` rewrites both documents. `gen-build-steps-check`, part
//! of `source-check`, refuses a stale document, a row that names no step, and
//! a step with no row in either. Both register last, after every other registrar, so the
//! graph they read is complete, and each document is a configure input, so an
//! edit to it reruns the configure phase that reads it.
//! Optioned invocations delegate only these documentation steps to an option-free
//! build. Product gates keep their configured graph. The inventory has one
//! reference graph rather than changing membership with its caller's options.
const std = @import("std");
const commands = @import("commands.zig");
const execution = @import("execution.zig");
const listing = @import("listing.zig");
const Step = std.Build.Step;

/// The library inventory first, then the applications, demos, and benchmarks.
pub const doc_paths = [_][]const u8{ "docs/build-steps.md", "docs/build-steps-apps.md" };

/// Zig's own top-level steps: never declared here, never listed.
pub const builtin_steps = [_][]const u8{ "install", "uninstall" };

pub fn register(b: *std.Build, source_check_step: *Step) void {
    const check_step = b.step("gen-build-steps-check", "Verify every bare `zig build` row in docs/build-steps.md and docs/build-steps-apps.md carries its step's description and containing steps, and every step has a row (fails if stale)");
    source_check_step.dependOn(check_step);
    const gen_step = b.step("gen-build-steps", "Rewrite every bare `zig build` row in docs/build-steps.md and docs/build-steps-apps.md from the build graph");
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/build/build_steps_doc.zig"), .target = b.graph.host }) });
    source_check_step.dependOn(&execution.addZigTest(b, tests, .unit_test).step);
    // A cold configure with lazy dependencies still to fetch is run again by
    // the build runner once they are present, with their steps in the graph.
    if (b.graph.needed_lazy_dependencies.count() > 0) return;

    if (b.user_input_options.count() != 0 or b.graph.release_mode != .off) {
        for ([_]*Step{ check_step, gen_step }) |step| {
            const reference = commands.addRootedSystemCommand(b, .build_tool, &.{
                b.graph.zig_exe, "build", step.name, "--cache-dir",
            });
            reference.addDirectoryArg2(std.Build.LazyPath.cache_root, .{ .make_absolute = true });
            // The child owns source/configure inputs, so it must inspect them
            // on every invocation. It receives no -D options or --release:
            // its default graph reaches the in-process renderer below.
            reference.has_side_effects = true;
            step.dependOn(&reference.step);
        }
        return;
    }

    // Configure output is cached; the documents are read here, so their
    // contents are configure inputs or an edit to one would go unseen.
    const gpa = b.allocator;
    const inventory = inventoryOf(b);
    const seen = gpa.alloc(bool, inventory.len) catch @panic("OOM");
    @memset(seen, false);
    var problems: std.ArrayList([]const u8) = .empty;
    var stale: ?[]const u8 = null;
    const update = b.addUpdateSourceFiles();
    for (doc_paths) |doc_path| {
        b.dependOnFileContents(b.path(doc_path));
        const current = b.root.root_dir.handle.readFileAlloc(b.graph.io, doc_path, gpa, .limited(1 << 20)) catch |err| {
            const fail = b.addFail(b.fmt("{s}: cannot read the step inventory ({s})", .{ doc_path, @errorName(err) }));
            check_step.dependOn(&fail.step);
            gen_step.dependOn(&fail.step);
            return;
        };
        const rendered = render(gpa, doc_path, current, inventory, seen) catch @panic("OOM");
        update.addBytesToSource(rendered.text, doc_path);
        problems.appendSlice(gpa, rendered.problems) catch @panic("OOM");
        if (stale == null and !std.mem.eql(u8, rendered.text, current)) stale = doc_path;
    }
    unlisted(gpa, inventory, seen, &problems) catch @panic("OOM");
    gen_step.dependOn(&update.step);

    if (problems.items.len > 0) {
        const joined = std.mem.join(gpa, "\n", problems.items) catch @panic("OOM");
        check_step.dependOn(&b.addFail(joined).step);
    } else if (stale) |doc_path| {
        check_step.dependOn(&b.addFail(b.fmt("{s} is stale against the build graph; run `zig build gen-build-steps`", .{doc_path})).step);
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
        std.mem.sort([]const u8, part_of.items, {}, listing.lessThan);
        entries.append(gpa, .{ .name = top.step.name, .description = top.description, .part_of = part_of.items }) catch @panic("OOM");
    }
    return entries.items;
}

fn isBuiltin(name: []const u8) bool {
    for (builtin_steps) |builtin| if (std.mem.eql(u8, name, builtin)) return true;
    return false;
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
/// Rewrite the rows of one inventory at `doc_path`, marking the steps it
/// lists in `seen`, which the caller shares across every inventory.
pub fn render(gpa: std.mem.Allocator, doc_path: []const u8, current: []const u8, inventory: []const Entry, seen: []bool) !Rendered {
    var by_name = std.StringHashMap(usize).init(gpa);
    for (inventory, 0..) |entry, i| try by_name.put(entry.name, i);

    var text: std.ArrayList(u8) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var fence: Fence = .{};
    var width: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, current, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const was_open = fence.open;
        const name = fence.rowName(line);
        if (fence.open and !was_open) width = blockWidth(lines.rest());
        if (name == null) {
            try text.appendSlice(gpa, line);
            if (lines.peek() != null) try text.append(gpa, '\n');
            continue;
        }
        const index = by_name.get(name.?) orelse {
            try problems.append(gpa, try gpa.print("{s}:{d}: `zig build {s}` names no step; remove the row or declare the step", .{ doc_path, line_no, name.? }));
            try text.appendSlice(gpa, line);
            if (lines.peek() != null) try text.append(gpa, '\n');
            continue;
        };
        if (seen[index]) {
            try problems.append(gpa, try gpa.print("{s}:{d}: `zig build {s}` has a second row; keep the one under its subject", .{ doc_path, line_no, name.? }));
        }
        seen[index] = true;
        try appendRow(gpa, &text, inventory[index], width);
        if (lines.peek() != null) try text.append(gpa, '\n');
    }
    return .{ .text = text.items, .problems = problems.items };
}

/// Report every step no inventory listed.
pub fn unlisted(gpa: std.mem.Allocator, inventory: []const Entry, seen: []const bool, problems: *std.ArrayList([]const u8)) !void {
    for (inventory, 0..) |entry, i| {
        if (seen[i]) continue;
        try problems.append(gpa, try gpa.print("step `{s}` has no row; add `zig build {s}` under its subject in {s} or {s} and run `zig build gen-build-steps`", .{ entry.name, entry.name, doc_paths[0], doc_paths[1] }));
    }
}

/// The step name of a bare row: `zig build <name>` followed by nothing but
/// its comment. A row with arguments after the name is a usage example.
fn bareRowName(line: []const u8) ?[]const u8 {
    const prefix = "zig build ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const after = line[prefix.len..];
    const end = std.mem.findScalar(u8, after, ' ') orelse after.len;
    const name = after[0..end];
    if (name.len == 0 or name[0] == '-') return null;
    const rest = std.mem.trimStart(u8, after[end..], " ");
    if (rest.len != 0 and rest[0] != '#') return null;
    return name;
}

/// Which lines of a document sit inside a fenced block, and the bare rows
/// among them.
const Fence = struct {
    open: bool = false,

    /// The step `line` names when it is a bare row inside a fenced block. A
    /// fence line opens or closes the block and names none.
    fn rowName(self: *Fence, line: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, line, "```")) {
            self.open = !self.open;
            return null;
        }
        return if (self.open) bareRowName(line) else null;
    }
};

/// The bare row names of a document, in order: only rows inside a fenced block.
/// Names are slices of the document.
pub fn rows(text: []const u8) Rows {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

const Rows = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    fence: Fence = .{},

    pub fn next(self: *Rows) ?[]const u8 {
        while (self.lines.next()) |line| {
            if (self.fence.rowName(line)) |name| return name;
        }
        return null;
    }
};

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
    const seen = try arena.allocator().alloc(bool, inventory.len);
    @memset(seen, false);
    const rendered = try render(arena.allocator(), doc_paths[0], current, &inventory, seen);
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
    var problems: std.ArrayList([]const u8) = .empty;
    try problems.appendSlice(arena.allocator(), rendered.problems);
    try unlisted(arena.allocator(), &inventory, seen, &problems);
    try std.testing.expectEqual(@as(usize, 2), problems.items.len);
    try std.testing.expect(std.mem.find(u8, problems.items[0], "`zig build missing` names no step") != null);
    try std.testing.expect(std.mem.find(u8, problems.items[1], "step `orphan` has no row") != null);
}

test "a second row for one step is reported" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const inventory = [_]Entry{.{ .name = "check", .description = "the gate", .part_of = &.{} }};
    const seen = try arena.allocator().alloc(bool, inventory.len);
    @memset(seen, false);
    const rendered = try render(arena.allocator(), doc_paths[0], "```\nzig build check\nzig build check #\n```\n", &inventory, seen);
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

test "only a bare row inside a fence names a step" {
    var names = rows(
        \\zig build outside # prose
        \\```sh
        \\zig build check          # the gate
        \\zig build fmt-check
        \\zig build check -Dx=1    # an example
        \\zig build --help
        \\```
    );
    try std.testing.expectEqualStrings("check", names.next().?);
    try std.testing.expectEqualStrings("fmt-check", names.next().?);
    try std.testing.expect(names.next() == null);
}
