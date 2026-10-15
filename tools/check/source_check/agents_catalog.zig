//! The agent scaffolding's shape: AGENTS.md routing, skill frontmatter, and
//! anonymous personas. `gen-agent-index` owns the index in `.agents/README.md`.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

pub fn checkAgentsRouting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "AGENTS.md", &.{
        "## Start Here",
        "docs/vision.md",
        ".agents/skills/work/SKILL.md",
        ".agents/rules/scripts.md",
        "Context map",
    });
}

pub fn checkSkillCatalog(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var skills = root.openDir(io, ".agents/skills", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, ".agents/skills: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer skills.close(io);

    var walker = try skills.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;

        var skill_buf: [128]u8 = undefined;
        const skill_path = std.fmt.bufPrint(&skill_buf, "{s}/SKILL.md", .{entry.path}) catch {
            try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: skill path too long", .{entry.path});
            continue;
        };
        skills.access(io, skill_path, .{}) catch |err| {
            const detail = if (err == error.FileNotFound)
                "top-level skill directories must contain SKILL.md"
            else
                @errorName(err);
            try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: {s}", .{ entry.path, detail });
            continue;
        };

        // A skill is discovered through its frontmatter, and its invocation
        // name is the directory name, a mismatched `name:` advertises a skill
        // that cannot be invoked as written.
        const skill_contents = skills.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: failed to read with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(skill_contents);
        if (frontmatterBlock(skill_contents)) |frontmatter| {
            const name = frontmatterValue(frontmatter, "name:") orelse "";
            if (!std.mem.eql(u8, name, entry.path)) {
                try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: frontmatter `name: {s}` must equal the directory name", .{ entry.path, name });
            }
            if (frontmatterValue(frontmatter, "description:") == null) {
                try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: frontmatter is missing `description:`", .{entry.path});
            }
        } else {
            try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: missing frontmatter — a skill without `name:`/`description:` is not discoverable", .{entry.path});
        }
    }
}

/// Project personas under `.agents/personas/` are anonymous lenses only. A
/// named taste reference and person-channeling phrasing belong in one of the
/// unpublished persona sources `.agents/personas/README.md` names, never in
/// committed scaffolding. The smell-annihilation skill is gated the same way
/// for channeling language.
pub fn checkAgentPersonas(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const banned = [_][]const u8{
        "channel ",
    };

    try refuseBannedSubstrings(io, gpa, root, violations, ".agents/skills/smell-annihilation/SKILL.md", &banned);
    try refuseBannedSubstrings(io, gpa, root, violations, ".agents/skills/rooms-team/SKILL.md", &banned);

    var personas = root.openDir(io, ".agents/personas", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, ".agents/personas: failed to open with {s}", .{@errorName(err)});
            return;
        },
    };
    defer personas.close(io);

    var walker = try personas.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        // README.md owns lookup prose; lenses are slug.md only.
        if (std.mem.eql(u8, entry.path, "README.md")) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;

        var path_buf: [256]u8 = undefined;
        const rel = std.fmt.bufPrint(&path_buf, ".agents/personas/{s}", .{entry.path}) catch {
            try appendViolation(gpa, violations, ".agents/personas/{s}: path too long", .{entry.path});
            continue;
        };

        const contents = root.readFileAlloc(io, rel, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ rel, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const stem = entry.path[0 .. entry.path.len - ".md".len];
        if (frontmatterBlock(contents)) |frontmatter| {
            const slug = frontmatterValue(frontmatter, "slug:") orelse {
                try appendViolation(gpa, violations, "{s}: missing frontmatter `slug:`", .{rel});
                continue;
            };
            if (!std.mem.eql(u8, slug, stem)) {
                try appendViolation(gpa, violations, "{s}: frontmatter `slug: {s}` must equal filename stem `{s}`", .{ rel, slug, stem });
            }
        } else {
            try appendViolation(gpa, violations, "{s}: missing frontmatter — project personas need `slug:` matching the filename", .{rel});
        }

        for (banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: contains banned `{s}` — channeling language belongs in user XDG, not committed project lenses", .{ rel, needle });
            }
        }
    }
}

fn refuseBannedSubstrings(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    banned: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    for (banned) |needle| {
        if (std.mem.indexOf(u8, contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: contains banned `{s}` — channeling language belongs in user XDG, not committed scaffolding", .{ path, needle });
        }
    }
}

/// The resident set (`AGENTS.md` plus every `alwaysApply: true` rule) is
/// injected into every agent session, so its size is a cost every task pays.
/// Procedures, inventories, and reference data belong in skills or check
/// tables. Raise this ceiling only after compressing what is already resident.
const resident_budget_bytes: usize = 18_000;

/// A Cursor rule loads through its frontmatter: `globs` routes it to the files
/// it governs and `alwaysApply: true` keeps it resident. A rule without
/// frontmatter is never auto-attached, silently unloaded at exactly the moment
/// it governs, which is how doc-voice once shipped unrouted. Every canonical
/// rule must open with a frontmatter block carrying `description:` and either
/// `globs:` or `alwaysApply: true`.
pub fn checkRuleFrontmatter(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var rules = root.openDir(io, ".agents/rules", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, ".agents/rules: failed to open for frontmatter check with {s}", .{@errorName(err)});
        return;
    };
    defer rules.close(io);

    const agents_md = root.readFileAlloc(io, "AGENTS.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "AGENTS.md: failed to read for the resident budget with {s}", .{@errorName(err)});
        return;
    };
    var resident_bytes: usize = agents_md.len;
    gpa.free(agents_md);

    var walker = try rules.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const contents = rules.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, ".agents/rules/{s}: failed to read for frontmatter check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const frontmatter = frontmatterBlock(contents) orelse {
            try appendViolation(gpa, violations, ".agents/rules/{s}: missing frontmatter, without `globs` or `alwaysApply`, Cursor never loads this rule", .{entry.path});
            continue;
        };
        if (frontmatterValue(frontmatter, "description:") == null) {
            try appendViolation(gpa, violations, ".agents/rules/{s}: frontmatter is missing `description:`", .{entry.path});
        }
        const always = frontmatterValue(frontmatter, "alwaysApply:") orelse "";
        if (std.mem.eql(u8, always, "true")) resident_bytes += contents.len;
        const globs = frontmatterValue(frontmatter, "globs:");
        if (globs == null and !std.mem.eql(u8, always, "true")) {
            try appendViolation(gpa, violations, ".agents/rules/{s}: frontmatter needs `globs:` or `alwaysApply: true` to route the rule", .{entry.path});
        }
        if (!pathsMatchGlobs(frontmatter, globs orelse "")) {
            try appendViolation(gpa, violations, ".agents/rules/{s}: `paths:` must list exactly the `globs:` entries, in order, each quoted; Claude ignores `globs:` and loads a rule without `paths:` into every session", .{entry.path});
        }
    }
    if (resident_bytes > resident_budget_bytes) {
        try appendViolation(gpa, violations, "AGENTS.md + `alwaysApply` rules: {d} bytes resident in every session, over the {d}-byte budget; scope a rule, move a procedure to a skill, or compress", .{ resident_bytes, resident_budget_bytes });
    }
}

/// Claude Code routes `.claude/rules` by a `paths:` YAML list and ignores
/// Cursor's `globs:`, so a rule scoped only by `globs:` is resident in every
/// Claude session. The two keys are one routing fact in two loaders' forms:
/// `paths:` items are the comma-separated `globs:` entries, in order, each
/// double-quoted because a bare leading `*` is a YAML alias. A rule with no
/// `globs:` carries no `paths:` either.
fn pathsMatchGlobs(frontmatter: []const u8, globs: []const u8) bool {
    var expected = std.mem.tokenizeScalar(u8, globs, ',');
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    var in_paths = false;
    var saw_paths = false;
    while (lines.next()) |line| {
        if (!in_paths) {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), "paths:")) {
                in_paths = true;
                saw_paths = true;
            }
            continue;
        }
        const item = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, item, "- ")) break;
        const quoted = std.mem.trim(u8, item[2..], " \t");
        if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return false;
        const want = expected.next() orelse return false;
        if (!std.mem.eql(u8, quoted[1 .. quoted.len - 1], std.mem.trim(u8, want, " \t"))) return false;
    }
    if (globs.len == 0) return !saw_paths;
    return saw_paths and expected.next() == null;
}

/// Returns the YAML frontmatter body when `contents` opens with a `---` block,
/// or null when there is no frontmatter at all.
fn frontmatterBlock(contents: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, contents, "---\n")) return null;
    const rest = contents["---\n".len..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return null;
    return rest[0..end];
}

/// Returns the trimmed, unquoted value of the first frontmatter line that
/// starts with `key` (the key includes its trailing colon), or null.
fn frontmatterValue(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const raw = std.mem.trim(u8, trimmed[key.len..], " \t\r");
        return std.mem.trim(u8, raw, "\"'");
    }
    return null;
}

test "frontmatterBlock and frontmatterValue parse rule and skill headers" {
    const with_fm = "---\ndescription: \"Voice rule.\"\nglobs: **/*.md, src/**/*.zig\n---\n\n# Body\n";
    const fm = frontmatterBlock(with_fm).?;
    try std.testing.expectEqualStrings("Voice rule.", frontmatterValue(fm, "description:").?);
    try std.testing.expectEqualStrings("**/*.md, src/**/*.zig", frontmatterValue(fm, "globs:").?);
    try std.testing.expect(frontmatterValue(fm, "alwaysApply:") == null);

    // No frontmatter at all, and an unterminated block, both report null.
    try std.testing.expect(frontmatterBlock("# Body only\n") == null);
    try std.testing.expect(frontmatterBlock("---\ndescription: x\n") == null);
}

test "pathsMatchGlobs holds Claude paths to Cursor globs" {
    const globs = "**/*.md, src/**/*.zig";
    try std.testing.expect(pathsMatchGlobs("globs: x\npaths:\n  - \"**/*.md\"\n  - \"src/**/*.zig\"\n", globs));
    // Missing, short, long, reordered, and unquoted lists all fail.
    try std.testing.expect(!pathsMatchGlobs("globs: x\n", globs));
    try std.testing.expect(!pathsMatchGlobs("paths:\n  - \"**/*.md\"\n", globs));
    try std.testing.expect(!pathsMatchGlobs("paths:\n  - \"**/*.md\"\n  - \"src/**/*.zig\"\n  - \"x\"\n", globs));
    try std.testing.expect(!pathsMatchGlobs("paths:\n  - \"src/**/*.zig\"\n  - \"**/*.md\"\n", globs));
    try std.testing.expect(!pathsMatchGlobs("paths:\n  - **/*.md\n  - src/**/*.zig\n", globs));
    // An always-resident rule carries neither key.
    try std.testing.expect(pathsMatchGlobs("alwaysApply: true\n", ""));
    try std.testing.expect(!pathsMatchGlobs("alwaysApply: true\npaths:\n  - \"x\"\n", ""));
}

test "sectionBody and collectBulletSpans read one registry section" {
    const gpa = std.testing.allocator;
    const doc =
        "# Title\n\n## Layer Ownership\n\n" ++
        "- `foundation`: bytes.\n" ++
        "- `ocapn/`: the protocol:\n" ++
        "  - `ocapn/model`: types.\n" ++
        "  prose continuation with `inline` span.\n\n" ++
        "## Next Section\n\n- `not-here`\n";
    const section = sectionBody(doc, "## Layer Ownership").?;

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    try std.testing.expectEqual(@as(usize, 3), spans.items.len);
    try std.testing.expectEqualStrings("foundation", spans.items[0]);
    try std.testing.expectEqualStrings("ocapn/", spans.items[1]);
    try std.testing.expectEqualStrings("ocapn/model", spans.items[2]);

    try std.testing.expect(sectionBody(doc, "## Absent") == null);
}
