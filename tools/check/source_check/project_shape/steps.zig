//! Documented commands against the build graph: every `zig build` command
//! cited anywhere is a real step, gated-claim markers are earned, and the
//! archive tables match their documentation.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// Command-citing surfaces that live outside the walked `docs/**` and
/// `.agents/**` trees. Everything inside those trees is discovered by walking,
/// so a new doc or rule is gated the moment it lands, no hand-maintained list
/// to fall out of sync (which is exactly how `docs/vision.md` and
/// `docs/ladder.md` once slipped past the command check).
const fixed_command_docs = [_][]const u8{
    "README.md",
    "CONTRIBUTING.md",
    "AGENTS.md",
    "bindings/README.md",
    "bindings/DEVELOPING.md",
    "bindings/PACKAGING.md",
    ".cursor/README.md",
    ".claude/README.md",
    ".codex/README.md",
    ".serena/project.yml",
};

/// Command-invoking CI surfaces. These are workflow YAML and shell, not
/// Markdown, so the whole file is command context, and one invocation may
/// name several steps (`zig build fmt-check arch-check …`). Scanned forward
/// only: a `zig build <step>` here must name a real step and a `bash <script>`
/// must resolve, but a CI invocation is not discoverability documentation, so
/// it never satisfies the reverse every-step-is-documented direction.
const ci_command_dirs = [_][]const u8{".github/workflows"};
const ci_command_files = [_][]const u8{"ci/gates.sh"};

/// Appends each command-context region of a Markdown document to `out`: every
/// line inside a fenced code block, and the text of every inline backtick span
/// elsewhere. Regions are slices into `contents`, so they share its lifetime.
/// Text outside both — ordinary prose — is never yielded, so a phrase like
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
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after_open, '`') orelse break;
            try out.append(gpa, after_open[0..close]);
            rest = after_open[close + 1 ..];
        }
    }
}

/// Scans one command-context region (a fenced line or an inline backtick span)
/// for `zig build <step>` and `bash <script>` citations, recording each step in
/// the documented set and flagging any that does not resolve.
const CommandScan = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    steps: *const std.StringHashMap(void),
    documented: *std.StringHashMap(void),
    documented_arena: std.mem.Allocator,
    path: []const u8,
    /// CI invocations resolve forward only; they are not documentation, so
    /// they never feed the reverse every-step-is-documented direction.
    record_documented: bool = true,
    /// A CI `zig build a b c` names several steps in one invocation; docs
    /// cite one step per span, so token consumption stays single there.
    multi_step: bool = false,

    fn region(self: CommandScan, text: []const u8) !void {
        var rest = text;
        while (std.mem.indexOf(u8, rest, "zig build")) |start| {
            const after = rest[start + "zig build".len ..];
            rest = after;

            var span = std.mem.trimStart(u8, after, " \t");
            if (span.len == 0 or isCommandTerminator(span[0])) continue;

            while (true) {
                const token_end = firstCommandTokenEnd(span);
                const documented_step = std.mem.trim(u8, span[0..token_end], "`'\".,);]");
                if (documented_step.len == 0) break;
                if (std.mem.startsWith(u8, documented_step, "-")) break;

                if (self.record_documented) {
                    try self.documented.put(try self.documented_arena.dupe(u8, documented_step), {});
                }
                if (!self.steps.contains(documented_step)) {
                    try appendViolation(self.gpa, self.violations, "{s}: documents `zig build {s}`, but build.zig has no step named `{s}`", .{
                        self.path,
                        documented_step,
                        documented_step,
                    });
                }
                if (!self.multi_step) break;
                const next = std.mem.trimStart(u8, span[token_end..], " \t");
                if (next.len == 0 or isCommandTerminator(next[0])) break;
                span = next;
            }
        }

        rest = text;
        while (std.mem.indexOf(u8, rest, "bash ")) |start| {
            const after = rest[start + "bash ".len ..];
            rest = after;

            const trimmed = std.mem.trimStart(u8, after, " \t");
            if (trimmed.len == 0 or isCommandTerminator(trimmed[0])) continue;

            const script_path = std.mem.trim(u8, trimmed[0..firstCommandTokenEnd(trimmed)], "`'\",);]");
            if (script_path.len == 0) continue;
            if (std.mem.startsWith(u8, script_path, "-")) continue;
            if (std.mem.indexOfScalar(u8, script_path, '/') == null) continue;

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

/// The run step an inline `b.step("N", …).dependOn(&run.step);` wires, or null.
/// Bounded to that one statement: a search that ran past the `;` could pick up
/// a later, unrelated wiring and report coverage this step does not have.
fn inlineWiredRunStep(build_src: []const u8, decl_at: usize) ?[]const u8 {
    const rest = build_src[decl_at..];
    const stmt_end = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    const stmt = rest[0..stmt_end];
    const marker = ".dependOn(&";
    const rel = std.mem.indexOf(u8, stmt, marker) orelse return null;
    const tail = stmt[rel + marker.len ..];
    const stop = std.mem.indexOfScalar(u8, tail, ')') orelse return null;
    if (stop == 0) return null;
    return tail[0..stop];
}

/// Where a "part of check" claim may be written. `docs/build-steps.md` is the
/// step inventory and carries almost all of them; the cli rule keeps the
/// everyday steps and may mark one too. A claim in either place is checked.
const gated_claim_docs = [_][]const u8{ "docs/build-steps.md", ".agents/rules/cli.md" };

/// A step documented as "part of check" must actually ride the gate in
/// `build.zig`.
///
/// The gate is assembled by 58 scattered `check_step.dependOn(…)` calls, so a
/// step can be written, documented as gated, and never wired — and nothing
/// would say so. The failure is silent in the direction that matters: the
/// tree looks covered. This holds the documented marker against the wiring,
/// both ways, so the marker is a claim the build has to earn.
pub fn checkGatedStepsRideCheck(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_src = util.readBuildStepSources(io, gpa, root) catch |err|
        return appendViolation(gpa, violations, "build.zig + tools/build: failed to read for the gated-step check with {s}", .{@errorName(err)});
    defer gpa.free(build_src);
    for (gated_claim_docs) |path| {
        const doc_src = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for the gated-step check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(doc_src);
        try gatedClaimsIn(gpa, violations, path, doc_src, build_src);
    }
}

fn gatedClaimsIn(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    rule_path: []const u8,
    rule_src: []const u8,
    build_src: []const u8,
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, rule_src, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (!std.mem.startsWith(u8, line, "zig build ")) continue;
        // `part of check-external` is a different gate; only the hermetic one.
        if (std.mem.indexOf(u8, line, "part of check-external") != null) continue;
        if (std.mem.indexOf(u8, line, "part of check") == null and
            std.mem.indexOf(u8, line, "rides check") == null and
            std.mem.indexOf(u8, line, "runs under check") == null) continue;

        const after = line["zig build ".len..];
        var end: usize = 0;
        while (end < after.len and (std.ascii.isAlphanumeric(after[end]) or after[end] == '-')) end += 1;
        const name = after[0..end];
        if (name.len == 0) continue;

        // name -> the `const <var> = b.step("<name>"` that declares it.
        var decl_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&decl_buf, "= b.step(\"{s}\",", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        var table_buf: [220]u8 = undefined;
        const table_row = std.fmt.bufPrint(&table_buf, ".check_step_name = \"{s}\"", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        if (std.mem.indexOf(u8, build_src, table_row) != null) continue;
        var inline_buf: [180]u8 = undefined;
        const inline_decl = std.fmt.bufPrint(&inline_buf, "b.step(\"{s}\",", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        const at = std.mem.indexOf(u8, build_src, needle) orelse {
            if (std.mem.indexOf(u8, build_src, inline_decl)) |inline_at| {
                // Declared inline (no `const x =`); check the run step it wires.
                if (inlineWiredRunStep(build_src, inline_at)) |run_step| {
                    var same_buf: [220]u8 = undefined;
                    const same = std.fmt.bufPrint(&same_buf, "check_step.dependOn(&{s})", .{run_step}) catch {
                        try appendViolation(gpa, violations, "build.zig: run step `{s}` overflows a wiring-check needle buffer; grow the buffer", .{run_step});
                        continue;
                    };
                    if (std.mem.indexOf(u8, build_src, same) != null) continue;
                }
            }
            try appendViolation(gpa, violations, "{s}:{d}: `zig build {s}` is documented as part of check, but the build sources declare no such step", .{ rule_path, line_no, name });
            continue;
        };
        const line_start = if (std.mem.lastIndexOfScalar(u8, build_src[0..at], '\n')) |nl| nl + 1 else 0;
        // Trim the indent, then drop the `const ` keyword by prefix — a
        // character-set trim here would eat the leading c/o/n/s/t of the
        // variable's own name.
        var decl = std.mem.trimStart(u8, build_src[line_start..at], " \t");
        decl = if (std.mem.startsWith(u8, decl, "const ")) decl["const ".len..] else decl;
        decl = std.mem.trimEnd(u8, decl, " \t");
        if (decl.len == 0) continue;

        // Three registration idioms join a named step to the gate, and each
        // is a real pattern in this build rather than an accident:
        //   1. the step variable itself is wired (`check_step.dependOn(x_step)`);
        //   2. the step is declared inline over a run step that check also
        //      wires (`check_step.dependOn(&fmt_check.step)`);
        //   3. the step is minted from a table row naming it
        //      (`.check_step_name = "…"`, the generated-header families).
        // Accepting all three keeps the check precise about the thing that
        // matters — a marker with no wiring at all — without demanding a
        // uniformity the build does not have.
        var buf: [220]u8 = undefined;
        const by_var = std.fmt.bufPrint(&buf, "check_step.dependOn({s})", .{decl}) catch {
            try appendViolation(gpa, violations, "build.zig: step variable `{s}` overflows a wiring-check needle buffer; grow the buffer", .{decl});
            continue;
        };
        if (std.mem.indexOf(u8, build_src, by_var) != null) continue;
        var buf2: [220]u8 = undefined;
        const by_amp = std.fmt.bufPrint(&buf2, "check_step.dependOn(&{s}", .{decl}) catch {
            try appendViolation(gpa, violations, "build.zig: step variable `{s}` overflows a wiring-check needle buffer; grow the buffer", .{decl});
            continue;
        };
        if (std.mem.indexOf(u8, build_src, by_amp) != null) continue;
        var buf3: [220]u8 = undefined;
        const by_table = std.fmt.bufPrint(&buf3, ".check_step_name = \"{s}\"", .{name}) catch {
            try appendViolation(gpa, violations, "build.zig: step \"{s}\" overflows a wiring-check needle buffer; grow the buffer", .{name});
            continue;
        };
        if (std.mem.indexOf(u8, build_src, by_table) != null) continue;
        // Inline declaration: `b.step("N", …).dependOn(&run.step);` — find the
        // run step it wires and ask whether check wires the same one.
        // Bounded to the declaring statement: searching past its `;` would let
        // some *other* step's wiring satisfy this one, which is the check
        // passing for a reason unrelated to what it was asked about.
        if (inlineWiredRunStep(build_src, at)) |run_step| {
            var buf4: [220]u8 = undefined;
            const same = std.fmt.bufPrint(&buf4, "check_step.dependOn(&{s})", .{run_step}) catch {
                try appendViolation(gpa, violations, "build.zig: run step `{s}` overflows a wiring-check needle buffer; grow the buffer", .{run_step});
                continue;
            };
            if (std.mem.indexOf(u8, build_src, same) != null) continue;
        }

        try appendViolation(gpa, violations, "{s}:{d}: `zig build {s}` says it is part of check, but the build sources wire it onto check_step through none of the three registration idioms — the marker has to be earned, or the claim removed", .{ rule_path, line_no, name });
    }
}

pub fn checkDocumentedBuildSteps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = util.readBuildStepSources(io, gpa, root) catch |err|
        return appendViolation(gpa, violations, "build.zig + tools/build: failed to read with {s}", .{@errorName(err)});
    defer gpa.free(build_zig);

    var steps = std.StringHashMap(void).init(gpa);
    defer steps.deinit();
    try steps.put("build", {});
    try collectBuildSteps(gpa, build_zig, &steps);

    // The command-citing corpus: the fixed surfaces outside the walked trees,
    // plus every Markdown file under `docs/**` and `.agents/**`, plus every
    // SuperMD page under `site/content/**` (the site cites the same
    // `zig build` steps and drifts the same way). Paths are duped into an
    // arena so they outlive the directory walkers.
    var docs_arena = std.heap.ArenaAllocator.init(gpa);
    defer docs_arena.deinit();
    var command_docs: std.ArrayList([]const u8) = .empty;
    defer command_docs.deinit(gpa);
    for (fixed_command_docs) |path| try command_docs.append(gpa, path);
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, "docs", ".md");
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, ".agents", ".md");
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, "site/content", ".smd");

    // Every `zig build <token>` token found across the corpus. Used both
    // forward (each documented token must name a real step) and in reverse
    // (each real step must be documented somewhere). Keys are duped into an
    // arena because each doc's `contents` is freed before the next iteration.
    var documented_arena = std.heap.ArenaAllocator.init(gpa);
    defer documented_arena.deinit();
    var documented = std.StringHashMap(void).init(gpa);
    defer documented.deinit();

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
            .documented = &documented,
            .documented_arena = documented_arena.allocator(),
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

    // The CI surfaces: every workflow on either forge plus the gate script,
    // scanned whole-file so a renamed build step or moved install script
    // cannot ship a broken CI run the local gate never sees.
    var ci_files: std.ArrayList([]const u8) = .empty;
    defer ci_files.deinit(gpa);
    for (ci_command_files) |path| try ci_files.append(gpa, path);
    for (ci_command_dirs) |dir_path| {
        try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &ci_files, violations, dir_path, ".yml");
    }
    for (ci_files.items) |path| {
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
            .documented = &documented,
            .documented_arena = documented_arena.allocator(),
            .path = path,
            .record_documented = false,
            .multi_step = true,
        };
        try scan.region(contents);
    }

    // Reverse direction: every build.zig step must be documented as
    // `zig build <name>` in at least one checked doc, so a new step cannot ship
    // undiscoverable. `build` is the implicit default alias and is exempt.
    var it = steps.keyIterator();
    while (it.next()) |name| {
        if (std.mem.eql(u8, name.*, "build")) continue;
        if (!documented.contains(name.*)) {
            try appendViolation(gpa, violations, "build.zig: step `{s}` is not documented as `zig build {s}` in any checked doc", .{ name.*, name.* });
        }
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
        try out.append(gpa, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.path }));
    }
}

fn collectBuildSteps(gpa: std.mem.Allocator, build_zig: []const u8, steps: *std.StringHashMap(void)) !void {
    // Steps are declared as `b.step("name", …)`, table-driven `.step_name = "name"`
    // rows, header-gen `.check_step_name` / `.write_step_name` pairs, and
    // binding-family `.aggregate_name = "name"` rows passed to `addBindingFamily`.
    const patterns = [_][]const u8{
        "b.step(\"",
        ".step_name = \"",
        ".check_step_name = \"",
        ".write_step_name = \"",
        ".aggregate_name = \"",
    };
    for (patterns) |pattern| {
        var rest = build_zig;
        while (std.mem.indexOf(u8, rest, pattern)) |start| {
            const after = rest[start + pattern.len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const name = after[0..end];
            try steps.put(name, {});
            rest = after[end..];
        }
    }
    _ = gpa;
}

fn firstCommandTokenEnd(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (isCommandTerminator(text[i])) return i;
    }
    return text.len;
}

fn isCommandTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', '`', '$', '#', '|', '&', ';', ')' => true,
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
    while (std.mem.indexOf(u8, rest, marker)) |start| {
        const after = rest[start + marker.len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
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
            const archive = std.fmt.bufPrint(&name_buf, "lib{s}", .{artifact}) catch {
                try appendViolation(gpa, violations, "build.zig: artifact name `{s}` too long for archive-table check", .{artifact});
                continue;
            };
            if (std.mem.indexOf(u8, contents, archive) == null) {
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
    try std.testing.expect(std.mem.indexOf(u8, seen, "zig build check") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "bash setup.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "zig build source-check") != null);
    // Prose is not, so its trailing tokens can never be read as a step.
    try std.testing.expect(std.mem.indexOf(u8, seen, "system") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "nonsense") == null);
}
