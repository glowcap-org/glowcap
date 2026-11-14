//! Documented commands against the build graph: every `zig build` command a
//! document cites is a real step, and the archive tables match their
//! documentation. `ci/groups_test.py` holds the commands CI runs.

const std = @import("std");
const markdown = @import("../markdown.zig");
const inventory = @import("build_steps_doc");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;
const sectionBody = markdown.sectionBody;
const collectBulletSpans = markdown.collectBulletSpans;

/// Command-citing surfaces that live outside the walked `docs/**` and
/// `.agents/**` trees. Everything inside those trees is discovered by walking,
/// so a new doc or rule is gated the moment it lands, with no hand-maintained
/// list to fall out of sync.
const fixed_command_docs = [_][]const u8{
    "README.md",
    "CONTRIBUTING.md",
    "AGENTS.md",
    "bindings/README.md",
    "bindings/DEVELOPING.md",
    "bindings/PACKAGING.md",
    ".serena/project.yml",
};

/// Appends each command-context region of a Markdown document to `out`: every
/// line inside a fenced code block, and the text of every inline backtick span
/// elsewhere. Regions are slices into `contents`, so they share its lifetime.
/// Text outside both, ordinary prose, is never yielded, so a phrase like
/// "the zig build system" cannot be mistaken for a command citation.
fn collectCommandRegions(gpa: std.mem.Allocator, contents: []const u8, out: *std.ArrayList([]const u8)) !void {
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_line, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) {
            try out.append(gpa, line);
            continue;
        }
        var rest = line;
        while (std.mem.findScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.findScalar(u8, after_open, '`') orelse break;
            try out.append(gpa, after_open[0..close]);
            rest = after_open[close + 1 ..];
        }
    }
}

/// The step the next `zig build <step>` citation in `rest` names, advancing
/// `rest` past that `zig build`. A bare flag such as `zig build --help` names
/// no step.
fn nextStepCitation(rest: *[]const u8) ?[]const u8 {
    while (std.mem.find(u8, rest.*, "zig build")) |start| {
        const after = rest.*[start + "zig build".len ..];
        rest.* = after;

        const span = std.mem.trimStart(u8, after, " \t");
        if (span.len == 0 or isCommandTerminator(span[0])) continue;

        const step = std.mem.trim(u8, span[0..firstCommandTokenEnd(span)], "`'\".,);]");
        if (step.len == 0 or std.mem.startsWith(u8, step, "-")) continue;
        return step;
    }
    return null;
}

/// Scans one command-context region (a fenced line or an inline backtick span)
/// for `zig build <step>` and `bash <script>` citations, flagging any that
/// does not resolve.
const CommandScan = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    steps: *const std.StringHashMap(void),
    path: []const u8,

    fn region(self: CommandScan, text: []const u8) !void {
        var rest = text;
        while (nextStepCitation(&rest)) |documented_step| {
            if (!self.steps.contains(documented_step)) {
                try appendViolation(self.gpa, self.violations, "{s}: documents `zig build {s}`, but {s} and {s} have no row for it: the citation is wrong, or the step is missing from the inventory", .{
                    self.path,
                    documented_step,
                    inventory.doc_paths[0],
                    inventory.doc_paths[1],
                });
            }
        }

        rest = text;
        while (std.mem.find(u8, rest, "bash ")) |start| {
            const after = rest[start + "bash ".len ..];
            rest = after;

            const trimmed = std.mem.trimStart(u8, after, " \t");
            if (trimmed.len == 0 or isCommandTerminator(trimmed[0])) continue;

            const script_path = std.mem.trim(u8, trimmed[0..firstCommandTokenEnd(trimmed)], "`'\",);]");
            if (script_path.len == 0) continue;
            if (std.mem.startsWith(u8, script_path, "-")) continue;
            if (std.mem.findScalar(u8, script_path, '/') == null) continue;

            self.root.access(self.io, script_path, .{}) catch |err| {
                try appendViolation(self.gpa, self.violations, "{s}: documents `bash {s}`, but script `{s}` is not accessible ({s})", .{
                    self.path,
                    script_path,
                    script_path,
                    @errorName(err),
                });
            };
        }
    }
};

pub fn checkDocumentedBuildSteps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var docs_arena = std.heap.ArenaAllocator.init(gpa);
    defer docs_arena.deinit();
    // The step set is the bare rows of the inventories, which
    // `gen-build-steps-check` holds to the build graph.
    var steps = std.StringHashMap(void).init(gpa);
    defer steps.deinit();
    for (inventory.builtin_steps) |name| try steps.put(name, {});
    for (inventory.doc_paths) |path| {
        const text = root.readFileAlloc(io, path, docs_arena.allocator(), .limited(1 << 20)) catch |err|
            return appendViolation(gpa, violations, "{s}: failed to read the step inventory with {s}", .{ path, @errorName(err) });
        var names = inventory.rows(text);
        while (names.next()) |name| try steps.put(name, {});
    }

    // The command-citing corpus: the fixed surfaces outside the walked trees,
    // plus every Markdown file under `docs/**` and `.agents/**`, plus every
    // SuperMD page under `site/content/**` (the site cites the same
    // `zig build` steps and drifts the same way). Paths are duped into an
    // arena so they outlive the directory walkers.
    var command_docs: std.ArrayList([]const u8) = .empty;
    defer command_docs.deinit(gpa);
    for (fixed_command_docs) |path| try command_docs.append(gpa, path);
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, "docs", ".md");
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, ".agents", ".md");
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, "site/content", ".smd");

    for (command_docs.items) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for build-command check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const scan = CommandScan{
            .io = io,
            .gpa = gpa,
            .root = root,
            .violations = violations,
            .steps = &steps,
            .path = path,
        };

        // A `zig build`/`bash` citation is a command claim only inside command
        // context: a fenced code block, or an inline backtick span. Prose like
        // "the zig build system" is neither, so it is never mistaken for a step.
        var regions: std.ArrayList([]const u8) = .empty;
        defer regions.deinit(gpa);
        try collectCommandRegions(gpa, contents, &regions);
        for (regions.items) |text| try scan.region(text);
    }
}

fn collectCommandDocsUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    out: *std.ArrayList([]const u8),
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
    ext: []const u8,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for command check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ext)) continue;
        try out.append(gpa, try arena.print("{s}/{s}", .{ dir_path, entry.path }));
    }
}

fn firstCommandTokenEnd(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (isCommandTerminator(text[i])) return i;
    }
    return text.len;
}

/// A step name never holds `<`, so a citation inside an HTML `<code>` span on
/// a site page ends at its closing tag.
fn isCommandTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', '`', '$', '#', '|', '&', ';', ')', '<' => true,
        else => false,
    };
}

const c_abi_archive_docs = [_][]const u8{
    "docs/consuming-from-c.md",
    "site/content/reference/index.smd",
};

/// Every composable C ABI archive named in the build must appear in the
/// first-read archive tables, so a new archive cannot land without a doc row.
/// The archive set is read from `build.zig`'s `archive_table` rows, not kept
/// as a second list here, so a new `.artifact` row is demanded in the docs the
/// moment it exists.
pub fn checkArchiveTables(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read for archive-table check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var artifacts: std.ArrayList([]const u8) = .empty;
    defer artifacts.deinit(gpa);
    const marker = ".artifact = \"";
    var rest = build_zig;
    while (std.mem.find(u8, rest, marker)) |start| {
        const after = rest[start + marker.len ..];
        const end = std.mem.findScalar(u8, after, '"') orelse break;
        try artifacts.append(gpa, after[0..end]);
        rest = after[end..];
    }
    if (artifacts.items.len == 0) {
        try appendViolation(gpa, violations, "build.zig: no `.artifact = \"...\"` archive rows found (archive-table check)", .{});
        return;
    }

    for (c_abi_archive_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for archive-table check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (artifacts.items) |artifact| {
            var name_buf: [128]u8 = undefined;
            const archive = std.mem.print(&name_buf, "lib{s}", .{artifact}) catch {
                try appendViolation(gpa, violations, "build.zig: artifact name `{s}` too long for archive-table check", .{artifact});
                continue;
            };
            if (std.mem.find(u8, contents, archive) == null) {
                try appendViolation(gpa, violations, "{s}: missing archive name `{s}` (archive-table check)", .{ path, archive });
            }
        }
    }
}

test "collectCommandRegions yields only fenced and inline-code text" {
    const gpa = std.testing.allocator;
    var regions: std.ArrayList([]const u8) = .empty;
    defer regions.deinit(gpa);

    const md =
        "Prose naming the zig build system must be ignored.\n" ++
        "Run `zig build check` and `bash setup.sh` inline.\n" ++
        "```sh\n" ++
        "zig build source-check\n" ++
        "```\n" ++
        "Trailing prose zig build nonsense stays prose.\n";
    try collectCommandRegions(gpa, md, &regions);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (regions.items) |r| {
        try joined.appendSlice(gpa, r);
        try joined.append(gpa, '\n');
    }
    const seen = joined.items;

    // Command context is captured.
    try std.testing.expect(std.mem.find(u8, seen, "zig build check") != null);
    try std.testing.expect(std.mem.find(u8, seen, "bash setup.sh") != null);
    try std.testing.expect(std.mem.find(u8, seen, "zig build source-check") != null);
    // Prose is not, so its trailing tokens can never be read as a step.
    try std.testing.expect(std.mem.find(u8, seen, "system") == null);
    try std.testing.expect(std.mem.find(u8, seen, "nonsense") == null);
}

test "a step cited inside an HTML code span ends at the closing tag" {
    const text = "zig build bench-site-report</code> repeats it.";
    const after = std.mem.trimStart(u8, text["zig build".len..], " ");
    try std.testing.expectEqualStrings("bench-site-report", after[0..firstCommandTokenEnd(after)]);
}

test "each cited step is named and a bare flag names none" {
    var rest: []const u8 = "zig build check, then `zig build nope` and zig build --help";
    try std.testing.expectEqualStrings("check", nextStepCitation(&rest).?);
    try std.testing.expectEqualStrings("nope", nextStepCitation(&rest).?);
    try std.testing.expect(nextStepCitation(&rest) == null);
}
