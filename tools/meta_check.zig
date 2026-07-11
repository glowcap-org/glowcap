//! Meta gate, checks that agent scaffolding and documented build commands stay
//! aligned with the canonical project shape.
//! Wired as `zig build meta-check` and into `zig build check`.

const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

/// Create the `meta-check` build step.
pub fn create(b: *Build) *Step {
    const wrapper = b.allocator.create(MetaCheck) catch @panic("OOM");
    wrapper.* = .{ .step = Step.init(.{
        .id = .custom,
        .name = "meta-check",
        .owner = b,
        .makeFn = make,
    }) };
    return &wrapper.step;
}

const MetaCheck = struct {
    step: Step,
};

const expected_hook_command = "bash .agents/hooks/format-edited-file.sh";

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
    ".cursor/README.md",
    ".claude/README.md",
    ".serena/project.yml",
};

fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const io = b.graph.io;
    const gpa = options.gpa;

    var violations: std.ArrayList([]const u8) = .empty;
    defer violations.deinit(gpa);

    const root = b.build_root.handle;

    try expectSymlink(io, gpa, root, &violations, "CLAUDE.md", "AGENTS.md");
    try expectSymlink(io, gpa, root, &violations, ".claude/rules", "../.agents/rules");
    try expectSymlink(io, gpa, root, &violations, ".claude/skills", "../.agents/skills");
    try expectSymlink(io, gpa, root, &violations, ".cursor/skills", "../.agents/skills");

    try checkCursorRuleOverlay(io, gpa, root, &violations);
    try checkRequiredSubstrings(io, gpa, root, &violations);
    try checkRuleIndexAgreement(io, gpa, root, &violations);
    try checkSkillCatalog(io, gpa, root, &violations);
    try checkAgentsRouting(io, gpa, root, &violations);
    try checkMarkdownLinks(io, gpa, root, &violations);
    try checkSiteContentLinks(io, gpa, root, &violations);
    try checkQuickStartSnippet(io, gpa, root, &violations);
    try checkDanglingReferenceLinks(io, gpa, root, &violations);
    try checkMermaidBlocks(io, gpa, root, &violations);
    try checkDocumentedBuildSteps(io, gpa, root, &violations);
    try checkAbiVersionLockstep(io, gpa, root, &violations);
    try checkAbiFreeingVerb(io, gpa, root, &violations);
    try checkCAbiSurfaceShape(io, gpa, root, &violations);
    try checkAbiExportsConsumed(io, gpa, root, &violations);
    try checkBindingConstants(io, gpa, root, &violations);
    try checkBindingHostActionDrains(io, gpa, root, &violations);
    try checkBindingMagicErrorCodes(io, gpa, root, &violations);
    try checkIrohSidecarAbi(io, gpa, root, &violations);
    try checkIrohSidecarPins(io, gpa, root, &violations);
    try checkApplicationSurfaceVerbs(io, gpa, root, &violations);
    try checkExampleIndex(io, gpa, root, &violations);
    try checkExampleWiring(io, gpa, root, &violations);
    try checkPlanningDocRoles(io, gpa, root, &violations);
    try checkLivingStateRegistry(io, gpa, root, &violations);
    try checkRoadmapHonesty(io, gpa, root, &violations);
    try checkRuleFrontmatter(io, gpa, root, &violations);
    try checkLayerOwnership(io, gpa, root, &violations);
    try checkTestPlacement(io, gpa, root, &violations);
    try checkTestSuiteWiring(io, gpa, root, &violations);
    try checkOracleCorpusRegistry(io, gpa, root, &violations);
    try checkProtocolCheatsheet(io, gpa, root, &violations);
    try checkGeneratedStateIgnores(io, gpa, root, &violations, b.build_root.path orelse ".");
    try checkPrereleaseLanguage(io, gpa, root, &violations);
    try checkSiteSvgAscii(io, gpa, root, &violations);
    try checkRemoveDiscards(io, gpa, root, &violations);
    try checkArchiveTables(io, gpa, root, &violations);
    try checkDocCAbiCites(io, gpa, root, &violations);

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("meta-check: {s}\n", .{msg});
        return step.fail("meta-check found {d} scaffolding violation(s)", .{violations.items.len});
    }
}

fn expectSymlink(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected_target: []const u8,
) !void {
    const stat = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        try appendViolation(gpa, violations, "{s}: expected symlink to {s}, stat failed with {s}", .{
            path,
            expected_target,
            @errorName(err),
        });
        return;
    };
    if (stat.kind != .sym_link) {
        try appendViolation(gpa, violations, "{s}: expected symlink to {s}, found {s}", .{
            path,
            expected_target,
            @tagName(stat.kind),
        });
        return;
    }

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = root.readLink(io, path, &buffer) catch |err| {
        try appendViolation(gpa, violations, "{s}: expected symlink to {s}, readLink failed with {s}", .{
            path,
            expected_target,
            @errorName(err),
        });
        return;
    };
    const target = buffer[0..len];
    if (!std.mem.eql(u8, target, expected_target)) {
        try appendViolation(gpa, violations, "{s}: expected symlink target {s}, found {s}", .{
            path,
            expected_target,
            target,
        });
    }
}

fn checkCursorRuleOverlay(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var agents_rules = root.openDir(io, ".agents/rules", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, ".agents/rules: failed to open canonical rules with {s}", .{@errorName(err)});
        return;
    };
    defer agents_rules.close(io);

    var canonical_count: usize = 0;
    var walker = try agents_rules.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        canonical_count += 1;
        const stem = entry.path[0 .. entry.path.len - ".md".len];
        const cursor_path = try std.fmt.allocPrint(gpa, ".cursor/rules/{s}.mdc", .{stem});
        const expected_target = try std.fmt.allocPrint(gpa, "../../.agents/rules/{s}", .{entry.path});

        try expectSymlink(io, gpa, root, violations, cursor_path, expected_target);
    }

    var cursor_rules = root.openDir(io, ".cursor/rules", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, ".cursor/rules: failed to open Cursor rules with {s}", .{@errorName(err)});
        return;
    };
    defer cursor_rules.close(io);

    var cursor_count: usize = 0;
    var cursor_walker = try cursor_rules.walk(gpa);
    defer cursor_walker.deinit();
    while (try cursor_walker.next(io)) |entry| {
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        if (!std.mem.endsWith(u8, entry.path, ".mdc")) {
            try appendViolation(gpa, violations, ".cursor/rules/{s}: Cursor rule overlay must contain only .mdc symlinks", .{entry.path});
            continue;
        }
        cursor_count += 1;
        if (entry.kind != .sym_link) {
            try appendViolation(gpa, violations, ".cursor/rules/{s}: expected symlink to .agents/rules, found {s}", .{
                entry.path,
                @tagName(entry.kind),
            });
            continue;
        }

        const stem = entry.path[0 .. entry.path.len - ".mdc".len];
        const expected_target = try std.fmt.allocPrint(gpa, "../../.agents/rules/{s}.md", .{stem});
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = cursor_rules.readLink(io, entry.path, &buffer) catch |err| {
            try appendViolation(gpa, violations, ".cursor/rules/{s}: readLink failed with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        const target = buffer[0..target_len];
        if (!std.mem.eql(u8, target, expected_target)) {
            try appendViolation(gpa, violations, ".cursor/rules/{s}: expected target {s}, found {s}", .{
                entry.path,
                expected_target,
                target,
            });
        }

        const canonical_path = try std.fmt.allocPrint(gpa, ".agents/rules/{s}.md", .{stem});
        root.access(io, canonical_path, .{}) catch |err| {
            try appendViolation(gpa, violations, ".cursor/rules/{s}: canonical rule {s} is not accessible ({s})", .{
                entry.path,
                canonical_path,
                @errorName(err),
            });
        };
    }

    if (cursor_count != canonical_count) {
        try appendViolation(gpa, violations, ".cursor/rules: expected {d} rule symlink(s) for {d} canonical rule(s), found {d}", .{
            canonical_count,
            canonical_count,
            cursor_count,
        });
    }
}

fn checkRequiredSubstrings(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectCursorHook(io, gpa, root, violations);
    try expectClaudeHook(io, gpa, root, violations);
    try expectMcpServer(io, gpa, root, violations, ".mcp.json", &.{
        "start-mcp-server",
        "--context",
        "claude-code",
        "--project-from-cwd",
    });
    try expectMcpServer(io, gpa, root, violations, ".cursor/mcp.json", &.{
        "start-mcp-server",
        "--context",
        "ide",
        "--project",
        "${workspaceFolder}",
    });
    try expectFileContains(io, gpa, root, violations, ".serena/project.yml", &.{
        "Read AGENTS.md first",
        "docs/vision.md",
        ".agents/skills/work/SKILL.md",
        ".agents/rules/project-values.md",
        ".agents/rules/agent-scaffolding.md",
        ".agents/rules/serena-mcp.md",
        "zig build check",
        "zig build meta-check",
    });
    try expectFileContains(io, gpa, root, violations, ".serena/.gitignore", &.{
        "/cache",
        "/logs",
        "/memories",
        "/project.local.yml",
        "/mcp-server.pid",
        "/mcp-server.lock",
        "/index.lock",
        "/.index-complete",
    });
}

fn expectCursorHook(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var parsed = try parseJsonFile(io, gpa, root, violations, ".cursor/hooks.json") orelse return;
    defer parsed.deinit();

    const hooks = getField(parsed.value, "hooks") orelse {
        try appendViolation(gpa, violations, ".cursor/hooks.json: missing `hooks` object", .{});
        return;
    };
    const after_file_edit = getField(hooks, "afterFileEdit") orelse {
        try appendViolation(gpa, violations, ".cursor/hooks.json: missing `hooks.afterFileEdit` array", .{});
        return;
    };
    if (!arrayHasCommand(after_file_edit, expected_hook_command)) {
        try appendViolation(gpa, violations, ".cursor/hooks.json: `hooks.afterFileEdit` must invoke `{s}`", .{expected_hook_command});
    }
}

fn expectClaudeHook(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var parsed = try parseJsonFile(io, gpa, root, violations, ".claude/settings.json") orelse return;
    defer parsed.deinit();

    const hooks = getField(parsed.value, "hooks") orelse {
        try appendViolation(gpa, violations, ".claude/settings.json: missing `hooks` object", .{});
        return;
    };
    const post_tool_use = getField(hooks, "PostToolUse") orelse {
        try appendViolation(gpa, violations, ".claude/settings.json: missing `hooks.PostToolUse` array", .{});
        return;
    };
    switch (post_tool_use) {
        .array => |entries| {
            for (entries.items) |entry| {
                if (getField(entry, "hooks")) |nested_hooks| {
                    if (arrayHasCommand(nested_hooks, expected_hook_command)) return;
                }
            }
        },
        else => {},
    }
    try appendViolation(gpa, violations, ".claude/settings.json: `hooks.PostToolUse[*].hooks` must invoke `{s}`", .{expected_hook_command});
}

fn expectMcpServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected_args: []const []const u8,
) !void {
    var parsed = try parseJsonFile(io, gpa, root, violations, path) orelse return;
    defer parsed.deinit();

    const servers = getField(parsed.value, "mcpServers") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers` object", .{path});
        return;
    };
    const serena = getField(servers, "serena") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.serena` object", .{path});
        return;
    };
    const command = getField(serena, "command") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.serena.command`", .{path});
        return;
    };
    if (!jsonStringEquals(command, "serena")) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.serena.command` must be `serena`", .{path});
    }

    const args = getField(serena, "args") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.serena.args`", .{path});
        return;
    };
    if (!jsonStringArrayEquals(args, expected_args)) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.serena.args` must match the canonical Serena invocation", .{path});
    }
}

fn parseJsonFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !?std.json.Parsed(std.json.Value) {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read JSON with {s}", .{ path, @errorName(err) });
        return null;
    };
    defer gpa.free(contents);

    return std.json.parseFromSlice(std.json.Value, gpa, contents, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSON ({s})", .{ path, @errorName(err) });
        return null;
    };
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn arrayHasCommand(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .array => |items| {
            for (items.items) |item| {
                if (getField(item, "command")) |command| {
                    if (jsonStringEquals(command, expected)) return true;
                }
            }
            return false;
        },
        else => false,
    };
}

fn jsonStringEquals(value: std.json.Value, expected: []const u8) bool {
    return switch (value) {
        .string => |actual| std.mem.eql(u8, actual, expected),
        else => false,
    };
}

fn jsonStringArrayEquals(value: std.json.Value, expected: []const []const u8) bool {
    return switch (value) {
        .array => |actual| {
            if (actual.items.len != expected.len) return false;
            for (expected, 0..) |expected_item, i| {
                if (!jsonStringEquals(actual.items[i], expected_item)) return false;
            }
            return true;
        },
        else => false,
    };
}

fn expectFileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    needles: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    for (needles) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing required text `{s}`", .{ path, needle });
        }
    }
}

fn checkAgentsRouting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "AGENTS.md", &.{
        "## Start Here",
        "docs/vision.md",
        ".agents/skills/work/SKILL.md",
        "Context map",
    });
}

fn checkRuleIndexAgreement(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const readme = root.readFileAlloc(io, ".agents/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/README.md: failed to read for rule-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(readme);

    var rules = root.openDir(io, ".agents/rules", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, ".agents/rules: failed to open for rule-index check with {s}", .{@errorName(err)});
        return;
    };
    defer rules.close(io);

    var walker = try rules.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const needle = try std.fmt.allocPrint(gpa, "(rules/{s})", .{entry.path});
        defer gpa.free(needle);
        if (std.mem.indexOf(u8, readme, needle) == null) {
            try appendViolation(gpa, violations, ".agents/README.md: missing rules table entry for `{s}`", .{entry.path});
        }
    }

    var rest = readme;
    while (std.mem.indexOf(u8, rest, "(rules/")) |start| {
        const after = rest[start + 1 ..];
        const end = std.mem.indexOfScalar(u8, after, ')') orelse break;
        var link = after[0..end];
        rest = after[end + 1 ..];
        if (std.mem.indexOfScalar(u8, link, '#')) |anchor| link = link[0..anchor];
        if (!std.mem.endsWith(u8, link, ".md")) continue;

        const canonical_path = try std.fmt.allocPrint(gpa, ".agents/{s}", .{link});
        defer gpa.free(canonical_path);
        root.access(io, canonical_path, .{}) catch |err| {
            try appendViolation(gpa, violations, ".agents/README.md: rules table links to missing `{s}` ({s})", .{
                canonical_path,
                @errorName(err),
            });
        };
    }
}

fn checkSkillCatalog(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const readme = root.readFileAlloc(io, ".agents/skills/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/skills/README.md: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(readme);

    const agents_readme = root.readFileAlloc(io, ".agents/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/README.md: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(agents_readme);

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
            if (err == error.FileNotFound) continue;
            try appendViolation(gpa, violations, ".agents/skills/{s}/SKILL.md: access failed with {s}", .{ entry.path, @errorName(err) });
            continue;
        };

        // A skill is discovered through its frontmatter, and its invocation
        // name is the directory name — a mismatched `name:` advertises a skill
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

        var catalog_buf: [64]u8 = undefined;
        const catalog_needle = std.fmt.bufPrint(&catalog_buf, "[{s}]", .{entry.path}) catch continue;
        if (std.mem.indexOf(u8, readme, catalog_needle) == null) {
            try appendViolation(gpa, violations, ".agents/skills/README.md: missing catalog entry for skill `{s}`", .{entry.path});
        }
        var agents_buf: [128]u8 = undefined;
        const agents_needle = std.fmt.bufPrint(&agents_buf, "skills/{s}/SKILL.md", .{entry.path}) catch continue;
        if (std.mem.indexOf(u8, agents_readme, agents_needle) == null) {
            try appendViolation(gpa, violations, ".agents/README.md: missing skills table entry for `{s}`", .{entry.path});
        }
    }
}

fn checkMarkdownLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The first-read living-state surfaces that carry relative links: the root
    // contracts, the bindings READMEs (every language), and the examples index.
    // `site/content` is `.smd`, whose link syntax this `.md` walker does not
    // parse; `checkSiteContentLinks` gates those references instead.
    const files = [_][]const u8{
        "AGENTS.md",
        "README.md",
        "CONTRIBUTING.md",
        "bindings/README.md",
        "bindings/rust/README.md",
        "bindings/ts/README.md",
        "bindings/python/README.md",
        "bindings/racket/README.md",
        "examples/README.md",
    };
    for (files) |path| {
        try checkMarkdownLinksInFile(io, gpa, root, violations, path);
    }
    try checkMarkdownLinksUnder(io, gpa, root, violations, ".agents");
    try checkMarkdownLinksUnder(io, gpa, root, violations, "docs");
}

fn checkMarkdownLinksUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for Markdown link check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        try checkMarkdownLinksInFile(io, gpa, root, violations, path);
    }
}

fn checkMarkdownLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Markdown link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        var rest = line;
        while (std.mem.indexOf(u8, rest, "](")) |start| {
            const after = rest[start + "](".len ..];
            const end = std.mem.indexOfScalar(u8, after, ')') orelse break;
            const raw_target = after[0..end];
            rest = after[end + 1 ..];

            const resolved = (try resolveMarkdownTarget(gpa, path, raw_target)) orelse continue;
            defer gpa.free(resolved);
            root.access(io, resolved, .{}) catch |err| {
                try appendViolation(gpa, violations, "{s}:{d}: Markdown link `{s}` resolves to missing `{s}` ({s})", .{
                    path,
                    line_no,
                    raw_target,
                    resolved,
                    @errorName(err),
                });
            };
        }
    }
}

/// The site content pages are `.smd` (Zine), whose intra-site links use
/// `$link.page('id')` and asset references use `$image.siteAsset('name')` rather
/// than Markdown `](path)`. Zine resolves them when `zig build site` runs, but
/// that is a sibling step; this gate holds the same references in the hermetic
/// `check`. A `$link.page('id')` resolves to `site/content/id.smd` or
/// `site/content/id/index.smd`; a `$image.siteAsset('name')` resolves to
/// `site/assets/name`. (Absolute `https://` links carry their own Markdown
/// `](url)` form and are not this gate's concern.)
fn checkSiteContentLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for site link check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;
        const path = try std.fmt.allocPrint(gpa, "site/content/{s}", .{entry.path});
        defer gpa.free(path);
        try checkSiteContentLinksInFile(io, gpa, root, violations, path);
    }
}

fn checkSiteContentLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for site link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var rest = contents;
    while (std.mem.indexOf(u8, rest, "$link.page('")) |start| {
        const after = rest[start + "$link.page('".len ..];
        const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const id = after[0..end];
        rest = after[end + 1 ..];
        if (id.len == 0) continue;

        const as_page = try std.fmt.allocPrint(gpa, "site/content/{s}.smd", .{id});
        defer gpa.free(as_page);
        const as_index = try std.fmt.allocPrint(gpa, "site/content/{s}/index.smd", .{id});
        defer gpa.free(as_index);
        if (!fileExists(io, root, as_page) and !fileExists(io, root, as_index)) {
            try appendViolation(gpa, violations, "{s}: $link.page('{s}') resolves to neither `{s}` nor `{s}`", .{ path, id, as_page, as_index });
        }
    }

    rest = contents;
    while (std.mem.indexOf(u8, rest, "$image.siteAsset('")) |start| {
        const after = rest[start + "$image.siteAsset('".len ..];
        const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const name = after[0..end];
        rest = after[end + 1 ..];
        if (name.len == 0) continue;

        const asset = try std.fmt.allocPrint(gpa, "site/assets/{s}", .{name});
        defer gpa.free(asset);
        if (!fileExists(io, root, asset)) {
            try appendViolation(gpa, violations, "{s}: $image.siteAsset('{s}') resolves to missing `{s}`", .{ path, name, asset });
        }
    }
}

/// The README and the start page both quote the tcp quick-start snippet and
/// claim `examples/zig/readme_quick_start.zig` carries it verbatim. This makes
/// the claim mechanical: each doc's fenced block must equal the example's
/// import pair plus the dedented `client` fn body, line for line.
fn checkQuickStartSnippet(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const example_path = "examples/zig/readme_quick_start.zig";
    const example = root.readFileAlloc(io, example_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ example_path, @errorName(err) });
        return;
    };
    defer gpa.free(example);

    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(gpa);
    const import_lines = [_][]const u8{
        "const std = @import(\"std\");",
        "const pancake = @import(\"pancake\");",
    };
    for (import_lines) |import_line| {
        if (std.mem.indexOf(u8, example, import_line) == null) {
            try appendViolation(gpa, violations, "{s}: missing quick-start import `{s}`", .{ example_path, import_line });
            return;
        }
        try expected.append(gpa, import_line);
    }
    try expected.append(gpa, "");

    var in_body = false;
    var found_client = false;
    var lines = std.mem.splitScalar(u8, example, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!in_body) {
            if (std.mem.startsWith(u8, line, "fn client(")) {
                in_body = true;
                found_client = true;
            }
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            in_body = false;
            break;
        }
        if (line.len == 0) {
            try expected.append(gpa, line);
            continue;
        }
        if (!std.mem.startsWith(u8, line, "    ")) {
            try appendViolation(gpa, violations, "{s}: `fn client` body line not indented one level: `{s}`", .{ example_path, line });
            return;
        }
        try expected.append(gpa, line[4..]);
    }
    if (!found_client or in_body) {
        try appendViolation(gpa, violations, "{s}: could not extract the `fn client` body for the quick-start check", .{example_path});
        return;
    }

    try compareQuickStartDoc(io, gpa, root, violations, "README.md", expected.items, false);
    try compareQuickStartDoc(io, gpa, root, violations, "site/content/start.smd", expected.items, true);
}

/// Find the doc's tcp quick-start fence (the one ```zig block carrying the
/// tcp marker comment) and hold it identical to the expected lines.
fn compareQuickStartDoc(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const []const u8,
    blockquoted: bool,
) !void {
    const marker = "// tcp: the peer is a place";
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the quick-start check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var fence: std.ArrayList([]const u8) = .empty;
    defer fence.deinit(gpa);

    var capturing = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, " \t\r");
        if (blockquoted) {
            if (std.mem.startsWith(u8, line, "> ")) {
                line = line[2..];
            } else if (std.mem.eql(u8, line, ">")) {
                line = "";
            }
        }
        if (!capturing) {
            if (std.mem.eql(u8, line, "```zig")) {
                capturing = true;
                fence.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.eql(u8, line, "```")) {
            capturing = false;
            var has_marker = false;
            for (fence.items) |l| {
                if (std.mem.indexOf(u8, l, marker) != null) has_marker = true;
            }
            if (has_marker) {
                found = true;
                break;
            }
            continue;
        }
        try fence.append(gpa, line);
    }
    if (!found) {
        try appendViolation(gpa, violations, "{s}: no ```zig fence carries the tcp quick-start marker `{s}`", .{ path, marker });
        return;
    }
    if (fence.items.len != expected.len) {
        try appendViolation(gpa, violations, "{s}: tcp quick-start snippet is {d} lines but examples/zig/readme_quick_start.zig carries {d}; the two must match line for line", .{ path, fence.items.len, expected.len });
        return;
    }
    for (fence.items, expected, 0..) |got, want, i| {
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: tcp quick-start drifts from examples/zig/readme_quick_start.zig at snippet line {d}: `{s}` vs `{s}`", .{ path, i + 1, got, want });
            return;
        }
    }
}

fn fileExists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

fn resolveMarkdownTarget(gpa: std.mem.Allocator, source_path: []const u8, raw_target: []const u8) !?[]u8 {
    var target = std.mem.trim(u8, raw_target, " \t\r\n");
    if (target.len == 0) return null;
    if (target[0] == '<' and target[target.len - 1] == '>') target = target[1 .. target.len - 1];
    if (target.len == 0 or target[0] == '#') return null;
    if (std.mem.indexOf(u8, target, "://") != null) return null;
    inline for (&.{ "mailto:", "tel:", "data:" }) |scheme| {
        if (std.mem.startsWith(u8, target, scheme)) return null;
    }
    if (std.mem.startsWith(u8, target, "/")) return null;

    const path_end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const target_path = target[0..path_end];
    if (target_path.len == 0) return null;

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ source_dir, target_path });
    defer gpa.free(joined);
    return try normalizeRelativePath(gpa, joined);
}

fn normalizeRelativePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                parts.items.len -= 1;
            } else {
                try parts.append(gpa, part);
            }
            continue;
        }
        try parts.append(gpa, part);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

/// Owned site SVGs must be ASCII-only. A non-ASCII byte in one of these files is
/// almost always a literal typographic glyph — an em-dash, a middot — that
/// should have been a numeric entity (`&#8212;`, `&#183;`); saved raw it
/// corrupts the XML and the diagram silently stops rendering, which bit this
/// project more than once. Enforcing ASCII (entities for any non-ASCII glyph)
/// makes that failure mode unrepresentable. Only `.svg` is checked: PNGs and
/// other binaries under `site/assets` are not text we own.
fn checkSiteSvgAscii(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "site/assets";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for SVG ASCII check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".svg")) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);

        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for SVG ASCII check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var line_no: usize = 1;
        var col: usize = 1;
        for (contents) |byte| {
            if (byte == '\n') {
                line_no += 1;
                col = 1;
                continue;
            }
            if (byte > 0x7f) {
                try appendViolation(gpa, violations, "{s}:{d}:{d}: non-ASCII byte 0x{x:0>2} in SVG; use a numeric entity (e.g. &#8212; em-dash, &#183; middot) so the XML stays valid", .{ path, line_no, col, byte });
                break;
            }
            col += 1;
        }
    }
}

/// Returns the column of the first dangling bracketed code span on `line`, or
/// null. The shape — a square bracket opening directly onto a backtick span and
/// closing right after it, with no link target, reference definition, or
/// reference label following — is rustdoc's intra-doc link syntax, which
/// nothing in this repository resolves: GitHub renders it as literal brackets
/// and Zig doc comments render it as dead text. A backtick directly before the
/// opening bracket means the bracket is itself inside a code span (a literal
/// bracket character), not a reference, so it is skipped.
fn danglingReferenceColumn(line: []const u8) ?usize {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_from, "[`")) |start| {
        search_from = start + 1;
        if (start != 0 and line[start - 1] == '`') continue;
        const inner_start = start + 2;
        const close = std.mem.indexOfPos(u8, line, inner_start, "`]") orelse return null;
        const inner = line[inner_start..close];
        if (inner.len == 0) continue;
        if (std.mem.indexOfAny(u8, inner, "`]") != null) continue;
        const after = close + 2;
        if (after < line.len and (line[after] == '(' or line[after] == ':' or line[after] == '[')) continue;
        return start;
    }
    return null;
}

/// The Markdown surfaces and Zig comment lines this repository owns must not
/// carry dangling bracketed code spans (see `danglingReferenceColumn`).
/// `bindings/rust` is deliberately exempt: rustdoc resolves the form there, so
/// in Rust doc comments it is a real link. Vendored trees under `upstream/`
/// are not ours to fix and are skipped.
fn checkDanglingReferenceLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // `bindings/rust/README.md` is excluded: rustdoc resolves the bracketed
    // code-span form, so it is a real link there (see the doc-voice rule).
    const markdown_files = [_][]const u8{ "AGENTS.md", "README.md", "CONTRIBUTING.md", "bindings/README.md", "bindings/ts/README.md", "bindings/python/README.md", "bindings/racket/README.md" };
    for (markdown_files) |path| {
        try checkDanglingRefsInMarkdownFile(io, gpa, root, violations, path);
    }

    const markdown_trees = [_][]const u8{ ".agents", "docs", "examples" };
    for (markdown_trees) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for dangling-reference check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            try checkDanglingRefsInMarkdownFile(io, gpa, root, violations, path);
        }
    }

    const zig_trees = [_][]const u8{ "src", "test", "bench", "examples", "tools", "conformance", "interop" };
    for (zig_trees) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for dangling-reference check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (std.mem.indexOf(u8, entry.path, "upstream/") != null) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            try checkDanglingRefsInZigFile(io, gpa, root, violations, path);
        }
    }
}

fn checkDanglingRefsInMarkdownFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for dangling-reference check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (danglingReferenceColumn(line) != null) {
            try appendViolation(gpa, violations, "{s}:{d}: bracketed code span links nowhere, write a plain code span, or a real Markdown link with a target", .{ path, line_no });
        }
    }
}

fn checkDanglingRefsInZigFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for dangling-reference check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) continue;
        if (danglingReferenceColumn(line) != null) {
            try appendViolation(gpa, violations, "{s}:{d}: bracketed code span in a comment is rustdoc link syntax that Zig docs do not resolve, write a plain code span", .{ path, line_no });
        }
    }
}

/// A map removal that discards its presence bool — `_ = map.remove(k)` and the
/// `.fetchRemove(` / `.swapRemove(` shapes — throws away a checkable fact: a
/// logic bug that removed a key the code believed present passes unnoticed. In
/// `src/`, every such discard must either assert the removal
/// (`std.debug.assert(map.remove(k))`, which still runs the remove in release,
/// only adding the check in safe builds) when presence is an established
/// invariant, or carry an inline `// idempotent:` / `// tolerant:` justification
/// when presence is genuinely not guaranteed. This holds the distinction
/// mechanically for every future removal (see the allocator-discipline section
/// of `.agents/rules/memory.md`). `orderedRemove` returns the element, not a
/// presence bool, so it is deliberately not flagged.
fn checkRemoveDiscards(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for remove-discard check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        try checkRemoveDiscardsInFile(io, gpa, root, violations, path);
    }
}

/// True when `line` is a code (non-comment) line that discards a presence-bool
/// removal with `_ =`.
fn removeDiscardLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return false;
    if (std.mem.indexOf(u8, line, "_ = ") == null) return false;
    return std.mem.indexOf(u8, line, ".remove(") != null or
        std.mem.indexOf(u8, line, ".fetchRemove(") != null or
        std.mem.indexOf(u8, line, ".swapRemove(") != null;
}

fn hasRemoveJustification(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "idempotent:") != null or
        std.mem.indexOf(u8, line, "tolerant:") != null;
}

/// A discard is justified by a marker on its own line or anywhere in the
/// contiguous `//` comment block directly above it.
fn removeDiscardJustified(lines: []const []const u8, i: usize) bool {
    if (hasRemoveJustification(lines[i])) return true;
    var j = i;
    while (j > 0) {
        j -= 1;
        const trimmed = std.mem.trimStart(u8, lines[j], " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) return false;
        if (hasRemoveJustification(lines[j])) return true;
    }
    return false;
}

fn checkRemoveDiscardsInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for remove-discard check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    for (lines.items, 0..) |line, i| {
        if (!removeDiscardLine(line)) continue;
        if (removeDiscardJustified(lines.items, i)) continue;
        try appendViolation(gpa, violations, "{s}:{d}: `_ =` discards a map removal's presence bool — assert it (`std.debug.assert(map.remove(k))`, which still runs in release) when presence is an invariant, or add an inline `// idempotent:` / `// tolerant:` justification", .{ path, i + 1 });
    }
}

const MermaidKind = enum { flowchart, sequence, state };

fn checkMermaidBlocks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for Mermaid check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);

    var walker = try docs.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "docs/{s}", .{entry.path});
        defer gpa.free(path);
        try checkMermaidBlocksInFile(io, gpa, root, violations, path);
    }
}

fn checkMermaidBlocksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Mermaid check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var block_start: usize = 0;
    var in_mermaid = false;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!in_mermaid) {
            if (std.mem.startsWith(u8, trimmed, "```mermaid")) {
                in_mermaid = true;
                block_start = line_no;
                block.clearRetainingCapacity();
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if ((try mermaidBlockKind(block.items)) == null) {
                try appendViolation(gpa, violations, "{s}:{d}: Mermaid block must start with flowchart, sequenceDiagram, or stateDiagram-v2", .{ path, block_start });
            }
            in_mermaid = false;
            continue;
        }

        try block.appendSlice(gpa, line);
        try block.append(gpa, '\n');
    }

    if (in_mermaid) {
        try appendViolation(gpa, violations, "{s}:{d}: Mermaid block is not closed", .{ path, block_start });
    }
}

fn mermaidBlockKind(block: []const u8) !?MermaidKind {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const first = std.mem.trim(u8, line, " \t\r");
        if (first.len == 0) continue;
        if (std.mem.startsWith(u8, first, "flowchart ")) {
            const direction = std.mem.trim(u8, first["flowchart ".len..], " \t\r");
            inline for (&.{ "TB", "TD", "BT", "RL", "LR" }) |allowed| {
                if (std.mem.eql(u8, direction, allowed)) return .flowchart;
            }
            return null;
        }
        if (std.mem.eql(u8, first, "sequenceDiagram")) return .sequence;
        if (std.mem.eql(u8, first, "stateDiagram-v2")) return .state;
        return null;
    }
    return null;
}

fn checkPlanningDocRoles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // No planning docs is a valid state: the directory exists only while a
    // plan note is alive, and git does not track empty directories.
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "docs/planning: failed to open planning docs with {s}", .{@errorName(err)});
            return;
        },
    };
    defer planning.close(io);

    var walker = try planning.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const contents = planning.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "docs/planning/{s}: failed to read with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        if (std.mem.indexOf(u8, contents, "Status: active plan") == null and
            std.mem.indexOf(u8, contents, "Status: historical") == null and
            std.mem.indexOf(u8, contents, "Status: living-state") == null)
        {
            try appendViolation(gpa, violations, "docs/planning/{s}: must declare `Status: active plan`, `Status: historical ...`, or `Status: living-state ...`", .{entry.path});
        }
    }
}

/// Collects every backtick span on the bullet lines of doc-drift's
/// "Living-State Surfaces" section, the living-state registry. Spans are
/// slices into `rule`, so they share its lifetime.
fn collectLivingStateRegistry(rule: []const u8, out: *std.StringHashMap(void)) !?void {
    const heading = "## Living-State Surfaces";
    const section_start = std.mem.indexOf(u8, rule, heading) orelse return null;
    const after_heading = rule[section_start + heading.len ..];
    const section_end = std.mem.indexOf(u8, after_heading, "\n## ") orelse after_heading.len;
    const section = after_heading[0..section_end];

    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
        var rest = trimmed;
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after_open, '`') orelse break;
            try out.put(after_open[0..close], {});
            rest = after_open[close + 1 ..];
        }
    }
}

/// The doc-drift living-state registry is itself a living-state surface, so it
/// is held honest in both directions. Forward: a registered non-glob path must
/// exist — an entry naming a deleted file is a broken promise. Reverse: every
/// top-level `docs/*.md` file, and every `docs/planning/*.md` that declares
/// `Status: living-state`, must appear in the registry — a doc that claims
/// living-state but is registered nowhere is ungoverned, which is exactly how
/// `docs/roadmap.md` once shipped outside the table.
fn checkLivingStateRegistry(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/doc-drift.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for living-state registry check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();
    _ = (try collectLivingStateRegistry(rule, &registry)) orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Living-State Surfaces` section", .{rule_path});
        return;
    };

    // Forward: every registered non-glob path resolves.
    var entries = registry.keyIterator();
    while (entries.next()) |entry| {
        if (std.mem.indexOfScalar(u8, entry.*, '*') != null) continue;
        root.access(io, entry.*, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: living-state registry names missing `{s}` ({s})", .{ rule_path, entry.*, @errorName(err) });
        };
    }

    // Reverse: every top-level docs/*.md is registered.
    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for living-state registry check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_it = docs.iterate();
    while (try docs_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/{s}", .{entry.name}) catch continue;
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: top-level doc `{s}` is not in the living-state registry", .{ rule_path, needle });
        }
    }

    // Reverse: every doc under a docs/ subdirectory that declares itself a
    // living-state surface is registered, by exact path or by a covering glob
    // (`docs/protocol-diagrams/**`). Top-level docs and planning docs are held
    // by the checks around this one; this one keeps a subdirectory corpus from
    // promising a maintenance discipline no gate holds.
    var docs_walker = try docs.walk(gpa);
    defer docs_walker.deinit();
    while (try docs_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') == null) continue;
        if (std.mem.startsWith(u8, entry.path, "planning/")) continue;
        const contents = docs.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Living-state surface") == null) continue;
        var covered_buf: [256]u8 = undefined;
        const covered_path = std.fmt.bufPrint(&covered_buf, "docs/{s}", .{entry.path}) catch continue;
        if (!registryCovers(&registry, covered_path)) {
            try appendViolation(gpa, violations, "{s}: `{s}` declares itself a living-state surface but no registry entry covers it", .{ rule_path, covered_path });
        }
    }

    // Reverse: every planning doc that declares itself living-state is registered.
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "docs/planning: failed to open for living-state registry check with {s}", .{@errorName(err)});
            return;
        },
    };
    defer planning.close(io);
    var planning_it = planning.iterate();
    while (try planning_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const contents = planning.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Status: living-state") == null) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/planning/{s}", .{entry.name}) catch continue;
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: planning doc `{s}` declares living-state but is not in the registry", .{ rule_path, needle });
        }
    }
}

/// Returns true when the registry names `path` exactly or carries a glob
/// entry whose fixed prefix (the text before the first `*`) covers it.
fn registryCovers(registry: *const std.StringHashMap(void), path: []const u8) bool {
    if (registry.contains(path)) return true;
    var entries = registry.keyIterator();
    while (entries.next()) |entry| {
        const star = std.mem.indexOfScalar(u8, entry.*, '*') orelse continue;
        if (star == 0) continue;
        if (std.mem.startsWith(u8, path, entry.*[0..star])) return true;
    }
    return false;
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

/// Returns the body of the `## <heading>` section of a Markdown document,
/// ending at the next `## ` heading or end of file. The slice points into
/// `contents`, so it shares its lifetime.
fn sectionBody(contents: []const u8, heading: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, contents, heading) orelse return null;
    const after = contents[start + heading.len ..];
    const end = std.mem.indexOf(u8, after, "\n## ") orelse after.len;
    return after[0..end];
}

/// Collects the first backtick span of every `- \`...\`` bullet line in
/// `section`. Spans are slices into `section`, so they share its lifetime.
fn collectBulletSpans(gpa: std.mem.Allocator, section: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- `")) continue;
        const after_tick = trimmed["- `".len..];
        const close = std.mem.indexOfScalar(u8, after_tick, '`') orelse continue;
        try out.append(gpa, after_tick[0..close]);
    }
}

/// Phrases that once described open work in `docs/roadmap.md` and are now
/// lies against the gated tree. A regression that reintroduces them fails
/// `meta-check` instead of shipping as a silent living-state drift.
const roadmap_forbidden_phrases = [_]struct { phrase: []const u8, reason: []const u8 }{
    .{
        .phrase = "Wall-clock time is only printed",
        .reason = "`zig build perf-check` already gates ReleaseFast wall-clock tripwires (ADR-0073)",
    },
    .{
        .phrase = "What remains is the bridge that feeds the byte-fed host",
        .reason = "`driver.LoopBridge` shipped under ADR-0076 (`zig build tcp-loop`)",
    },
    .{
        .phrase = "the listener has no durable designator a partner can re-dial",
        .reason = "`net.tcp_keyed` / ADR-0075 already ships the keyed designator; open work is binding/C ABI surfaces",
    },
};

fn checkRoadmapHonesty(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "docs/roadmap.md";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for roadmap-honesty check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    for (roadmap_forbidden_phrases) |entry| {
        if (std.mem.indexOf(u8, contents, entry.phrase) != null) {
            try appendViolation(gpa, violations, "{s}: stale remaining-work claim `{s}` — {s}", .{ path, entry.phrase, entry.reason });
        }
    }
}

/// A Cursor rule loads through its frontmatter: `globs` routes it to the files
/// it governs and `alwaysApply: true` keeps it resident. A rule without
/// frontmatter is never auto-attached, silently unloaded at exactly the moment
/// it governs, which is how doc-voice once shipped unrouted. Every canonical
/// rule must open with a frontmatter block carrying `description:` and either
/// `globs:` or `alwaysApply: true`.
fn checkRuleFrontmatter(
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
        if (frontmatterValue(frontmatter, "globs:") == null and !std.mem.eql(u8, always, "true")) {
            try appendViolation(gpa, violations, ".agents/rules/{s}: frontmatter needs `globs:` or `alwaysApply: true` to route the rule", .{entry.path});
        }
    }
}

/// The architecture rule's Layer Ownership list is the map a cold agent uses to
/// place code, so it is held to `src/` in both directions. Forward: every
/// bulleted layer resolves to a real `src/` directory. Reverse: every top-level
/// directory under `src/`, and every immediate child of a grouping directory
/// (`src/ocapn`, `src/c_abi` — see `checkGroupingChildren`), has a bullet — a
/// layer that ships unnamed is unplaceable, which is how `src/oracle` once
/// went missing from the map.
fn checkLayerOwnership(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/architecture.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for layer-ownership check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Layer Ownership") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Layer Ownership` section", .{rule_path});
        return;
    };

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    var named = std.StringHashMap(void).init(gpa);
    defer named.deinit();
    for (spans.items) |span| {
        const name = std.mem.trimEnd(u8, span, "/");
        try named.put(name, {});
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "src/{s}", .{name}) catch continue;
        root.access(io, path, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: Layer Ownership names `{s}` but `{s}` is not accessible ({s})", .{ rule_path, span, path, @errorName(err) });
        };
    }

    var src = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for layer-ownership check with {s}", .{@errorName(err)});
        return;
    };
    defer src.close(io);
    var src_it = src.iterate();
    while (try src_it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!named.contains(entry.name)) {
            try appendViolation(gpa, violations, "{s}: `src/{s}` has no Layer Ownership bullet", .{ rule_path, entry.name });
        }
        // A grouping directory (`src/ocapn`, `src/c_abi`) holds a family of
        // layers rather than being one; hold each immediate child too.
        try checkGroupingChildren(io, gpa, root, entry.name, &named, violations, rule_path);
    }
}

/// A grouping directory under `src/` — one with no direct `.zig` file, only
/// subdirectories (`src/ocapn`, `src/c_abi`) — is a family of layers, not a
/// layer itself. Each immediate child is its own layer, so it must carry a
/// `<group>/<child>` Layer Ownership bullet; an unnamed sub-layer is
/// unplaceable, exactly how `src/oracle` once went missing from the map.
/// A directory with its own `.zig` files is a layer (its files belong to it),
/// so it is skipped here. Recursion is one level: a child that is itself a
/// grouping dir (e.g. `ocapn/codec` over `syrup`/`capnp`) keeps its sub-layers
/// in `layer_table`, not in the placement map.
fn checkGroupingChildren(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    group: []const u8,
    named: *const std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
    rule_path: []const u8,
) !void {
    var path_buf: [160]u8 = undefined;
    const group_path = std.fmt.bufPrint(&path_buf, "src/{s}", .{group}) catch return;
    var dir = root.openDir(io, group_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var subdirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (subdirs.items) |s| gpa.free(s);
        subdirs.deinit(gpa);
    }
    var has_zig = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            has_zig = true;
        } else if (entry.kind == .directory) {
            try subdirs.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    if (has_zig) return;

    for (subdirs.items) |sub| {
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "{s}/{s}", .{ group, sub }) catch continue;
        if (!named.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: `src/{s}/{s}` has no Layer Ownership bullet", .{ rule_path, group, sub });
        }
    }
}

/// The tests rule's Placement list routes a new test to its directory, so it is
/// held to `test/` in both directions. Forward: every `test/...` bullet
/// resolves to a real path. Reverse: every top-level directory under `test/`
/// has a bullet, so a new suite cannot land without placement guidance.
fn checkTestPlacement(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/tests.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for test-placement check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Placement") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Placement` section", .{rule_path});
        return;
    };

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    var named = std.StringHashMap(void).init(gpa);
    defer named.deinit();
    for (spans.items) |span| {
        if (!std.mem.startsWith(u8, span, "test/")) continue;
        try named.put(span, {});
        root.access(io, span, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: Placement names `{s}` but it is not accessible ({s})", .{ rule_path, span, @errorName(err) });
        };
    }

    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test: failed to open for test-placement check with {s}", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);
    var it = test_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "test/{s}", .{entry.name}) catch continue;
        if (!named.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: `test/{s}` has no Placement bullet", .{ rule_path, entry.name });
        }
    }
}

/// The test-suite roots that `zig build test` and `zig build oracle-check`
/// compile. Both are hand-maintained comptime import lists.
const test_suite_roots = [_][]const u8{ "test/all_test.zig", "test/oracle_check.zig" };

/// `zig build test` compiles the single root `test/all_test.zig`, and
/// `zig build oracle-check` compiles `test/oracle_check.zig`. A `*_test.zig`
/// file that neither root imports compiles nowhere and runs zero tests while
/// the gate stays green, the same silently-unloaded failure mode the rule
/// overlay check kills. Forward: every `test/**/*_test.zig` appears as an
/// `@import` in one of the roots. Reverse: every `*_test.zig` import in the
/// roots resolves to a real file, so a stale import line fails here with a
/// named path.
fn checkTestSuiteWiring(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var root_contents: [test_suite_roots.len][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (root_contents[0..loaded]) |contents| gpa.free(contents);
    for (test_suite_roots, 0..) |path, i| {
        root_contents[i] = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for test-suite wiring check with {s}", .{ path, @errorName(err) });
            return;
        };
        loaded = i + 1;
    }

    // Forward: every test file under test/ is imported by a suite root.
    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test: failed to open for test-suite wiring check with {s}", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);
    var walker = try test_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        // The suite roots themselves are compile roots, not imports.
        if (std.mem.eql(u8, entry.path, "all_test.zig")) continue;

        var needle_buf: [192]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "@import(\"{s}\")", .{entry.path}) catch {
            try appendViolation(gpa, violations, "test/{s}: path too long for test-suite wiring check", .{entry.path});
            continue;
        };
        var imported = false;
        for (root_contents) |contents| {
            if (std.mem.indexOf(u8, contents, needle) != null) imported = true;
        }
        if (!imported) {
            try appendViolation(gpa, violations, "test/{s}: not imported by test/all_test.zig or test/oracle_check.zig, its tests silently never run", .{entry.path});
        }
    }

    // Reverse: every `*_test.zig` import in a suite root resolves on disk.
    for (test_suite_roots, root_contents) |path, contents| {
        var rest = contents;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
            const after = rest[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const target = after[0..end];
            rest = after[end..];
            if (!std.mem.endsWith(u8, target, "_test.zig")) continue;

            var target_buf: [192]u8 = undefined;
            const target_path = std.fmt.bufPrint(&target_buf, "test/{s}", .{target}) catch continue;
            root.access(io, target_path, .{}) catch |err| {
                try appendViolation(gpa, violations, "{s}: imports `{s}` but `{s}` is not accessible ({s})", .{ path, target, target_path, @errorName(err) });
            };
        }
    }
}

/// The Syrup byte corpus is the oracle the codec is checked against, and
/// `test/oracle/protocol_oracle.zig` is its registry. A `.bin` dropped into
/// `test/oracle/corpus/` without a `fixture("…")` row is embedded
/// nowhere and pressures nothing, silently. Forward: every registered name
/// has its file on disk (a clearer failure than the `@embedFile` compile
/// error). Reverse: every `.bin` on disk has a registry row.
fn checkOracleCorpusRegistry(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const registry_path = "test/oracle/protocol_oracle.zig";
    const corpus_path = "test/oracle/corpus";

    const registry_src = root.readFileAlloc(io, registry_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for fixture-registry check with {s}", .{ registry_path, @errorName(err) });
        return;
    };
    defer gpa.free(registry_src);

    // Registered names: every `fixture("<name>")` call in the registry array.
    var registered = std.StringHashMap(void).init(gpa);
    defer registered.deinit();
    var rest = registry_src;
    while (std.mem.indexOf(u8, rest, "fixture(\"")) |start| {
        const after = rest[start + "fixture(\"".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        try registered.put(after[0..end], {});
        rest = after[end..];
    }

    var corpus = root.openDir(io, corpus_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for fixture-registry check with {s}", .{ corpus_path, @errorName(err) });
        return;
    };
    defer corpus.close(io);

    // Reverse: every fixture on disk is registered.
    var on_disk = std.StringHashMap(void).init(gpa);
    defer on_disk.deinit();
    var names_arena = std.heap.ArenaAllocator.init(gpa);
    defer names_arena.deinit();
    var it = corpus.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
        try on_disk.put(try names_arena.allocator().dupe(u8, entry.name), {});
        if (!registered.contains(entry.name)) {
            try appendViolation(gpa, violations, "{s}/{s}: fixture is not registered in {s}; it is embedded nowhere and pressures nothing", .{ corpus_path, entry.name, registry_path });
        }
    }

    // Forward: every registered name resolves to a fixture on disk.
    var names = registered.keyIterator();
    while (names.next()) |name| {
        if (!on_disk.contains(name.*)) {
            try appendViolation(gpa, violations, "{s}: registers fixture `{s}` but {s}/{s} does not exist", .{ registry_path, name.*, corpus_path, name.* });
        }
    }
}

/// The site's protocol cheatsheet (`site/content/protocol.smd`) is a living-state
/// surface: it names every wire label pancake speaks — the `op:` messages, the
/// `desc:` reference descriptors, and the `ocapn-` locator records that address a
/// peer. The Syrup codec is the authority for that vocabulary — OCapN settles the
/// wire as Syrup, so every such record label appears there as a string literal.
/// This check pins the page to the codec both ways: a label documented on the page
/// that the codec does not speak is a stale or invented claim, and a label the
/// codec speaks that the page omits is an undocumented part of the surface. Either
/// fails the gate, so the cheatsheet cannot drift from the protocol it describes.
fn checkProtocolCheatsheet(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const page_path = "site/content/protocol.smd";
    const codec_dir_path = "src/ocapn/codec/syrup";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Authority: every quoted `op:`/`desc:` literal the Syrup codec reads or writes.
    var known = std.StringHashMap(void).init(gpa);
    defer known.deinit();

    var codec_dir = root.openDir(io, codec_dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for protocol-cheatsheet check with {s}", .{ codec_dir_path, @errorName(err) });
        return;
    };
    defer codec_dir.close(io);

    var walker = try codec_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const src = codec_dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for protocol-cheatsheet check with {s}", .{ codec_dir_path, entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(src);
        try collectWireTokens(arena, &known, src, true);
    }

    if (known.count() == 0) {
        try appendViolation(gpa, violations, "{s}: found no wire tokens; protocol-cheatsheet check cannot anchor to the codec", .{codec_dir_path});
        return;
    }

    // The page must present exactly that set: no invented token, none missing.
    const page = root.readFileAlloc(io, page_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for protocol-cheatsheet check with {s}", .{ page_path, @errorName(err) });
        return;
    };
    defer gpa.free(page);

    var on_page = std.StringHashMap(void).init(gpa);
    defer on_page.deinit();
    try collectWireTokens(arena, &on_page, page, false);

    var page_it = on_page.keyIterator();
    while (page_it.next()) |tok| {
        if (!known.contains(tok.*)) {
            try appendViolation(gpa, violations, "{s}: documents wire token `{s}` that the Syrup codec ({s}) does not speak", .{ page_path, tok.*, codec_dir_path });
        }
    }
    var known_it = known.keyIterator();
    while (known_it.next()) |tok| {
        if (!on_page.contains(tok.*)) {
            try appendViolation(gpa, violations, "{s}: Syrup codec speaks `{s}` but the cheatsheet does not list it", .{ page_path, tok.* });
        }
    }
}

/// Collect `op:<body>` / `desc:<body>` / `ocapn-<body>` tokens from `text` into
/// `out` (deduped, arena-owned). When `quoted_only` is set, the token must be a
/// string literal — wrapped in double quotes — so codec source counts only real
/// wire labels, not tokens mentioned in comments; the cheatsheet carries its
/// tokens in Markdown backticks, so it scans unquoted. The `ocapn-` prefix matches
/// the location records (`ocapn-peer`, `ocapn-sturdyref`) and never the `ocapn://`
/// URI scheme, whose `:` is not a wire-token char.
fn collectWireTokens(
    arena: std.mem.Allocator,
    out: *std.StringHashMap(void),
    text: []const u8,
    quoted_only: bool,
) !void {
    const prefixes = [_][]const u8{ "op:", "desc:", "ocapn-" };
    for (prefixes) |prefix| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, prefix)) |pos| {
            var end = pos + prefix.len;
            while (end < text.len and isWireTokenChar(text[end])) end += 1;
            const has_body = end > pos + prefix.len;
            const quoted = pos > 0 and text[pos - 1] == '"' and end < text.len and text[end] == '"';
            if (has_body and (!quoted_only or quoted)) {
                try out.put(try arena.dupe(u8, text[pos..end]), {});
            }
            i = pos + prefix.len;
        }
    }
}

fn isWireTokenChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c == '-';
}

/// The cli rule's Generated State list registers paths that must never be
/// committed. Each registered path must be matched by a committed ignore rule —
/// `.serena/...` entries by `.serena/.gitignore`, everything else by the root
/// `.gitignore` — so "fix .gitignore rather than manual cleanup" is enforced
/// instead of remembered. The git index is held to the same registry: a
/// registered path that `git ls-files` reports as tracked is committed
/// generated state, which an ignore rule alone cannot fix.
fn checkGeneratedStateIgnores(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    root_path: []const u8,
) !void {
    const rule_path = ".agents/rules/cli.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for generated-state check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Generated State") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Generated State` section", .{rule_path});
        return;
    };

    const root_ignore = root.readFileAlloc(io, ".gitignore", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".gitignore: failed to read for generated-state check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(root_ignore);
    const serena_ignore = root.readFileAlloc(io, ".serena/.gitignore", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".serena/.gitignore: failed to read for generated-state check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(serena_ignore);

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    for (spans.items) |span| {
        if (std.mem.startsWith(u8, span, ".serena/")) {
            var needle_buf: [160]u8 = undefined;
            const stem = std.mem.trimEnd(u8, span[".serena/".len..], "/");
            const needle = std.fmt.bufPrint(&needle_buf, "/{s}", .{stem}) catch continue;
            if (std.mem.indexOf(u8, serena_ignore, needle) == null) {
                try appendViolation(gpa, violations, "{s}: generated-state entry `{s}` has no matching rule in .serena/.gitignore", .{ rule_path, span });
            }
        } else if (std.mem.indexOf(u8, root_ignore, span) == null) {
            try appendViolation(gpa, violations, "{s}: generated-state entry `{s}` has no matching rule in .gitignore", .{ rule_path, span });
        }
    }

    // The index itself: no registered generated-state path may be tracked.
    // Read-only git is sanctioned by the cli rule; one `ls-files` call covers
    // every entry. A failure to run git is a violation, not a silent skip —
    // the check either holds or says it cannot.
    const ls_files = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-C", root_path, "ls-files", "-z" },
        .stdout_limit = .limited(64 << 20),
    }) catch |err| {
        try appendViolation(gpa, violations, "git ls-files: failed to run for generated-state check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(ls_files.stdout);
    defer gpa.free(ls_files.stderr);
    switch (ls_files.term) {
        .exited => |code| if (code != 0) {
            try appendViolation(gpa, violations, "git ls-files: exited with code {d} during generated-state check", .{code});
            return;
        },
        else => {
            try appendViolation(gpa, violations, "git ls-files: terminated abnormally during generated-state check", .{});
            return;
        },
    }
    for (spans.items) |span| {
        const is_dir = std.mem.endsWith(u8, span, "/");
        var tracked_it = std.mem.splitScalar(u8, ls_files.stdout, 0);
        while (tracked_it.next()) |tracked| {
            if (tracked.len == 0) continue;
            const hit = if (is_dir)
                std.mem.startsWith(u8, tracked, span)
            else
                std.mem.eql(u8, tracked, span);
            if (hit) {
                try appendViolation(gpa, violations, "{s}: generated-state entry `{s}` is tracked by git (`{s}`) — untrack it; an ignore rule alone cannot fix a committed path", .{ rule_path, span, tracked });
                break;
            }
        }
    }
}

/// The high-precision transition phrases the prerelease-language rule bans from
/// first-read surfaces. Softer tells ("previously", "originally") have honest
/// uses, so they stay governed by the prose rule alone.
const prerelease_phrases = [_][]const u8{ "formerly", "renamed from", "pre-1.0", "pre-publication" };

/// First-read surfaces describe the current shape, never the transition that
/// produced it. This scans the first-read corpus — README.md, AGENTS.md,
/// CONTRIBUTING.md, and every top-level docs/*.md — for the banned phrases the
/// prerelease-language rule names, case-insensitively.
fn checkPrereleaseLanguage(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    inline for (&.{ "README.md", "AGENTS.md", "CONTRIBUTING.md" }) |path| {
        try files.append(gpa, path);
    }

    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for prerelease-language check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_it = docs.iterate();
    while (try docs_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        try files.append(gpa, try std.fmt.allocPrint(arena, "docs/{s}", .{entry.name}));
    }

    for (files.items) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for prerelease-language check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (prerelease_phrases) |phrase| {
            if (std.ascii.indexOfIgnoreCase(contents, phrase) != null) {
                try appendViolation(gpa, violations, "{s}: contains prerelease phrase `{s}` — first-read surfaces describe the current shape (prerelease-language rule)", .{ path, phrase });
            }
        }
    }
}

const ConstantsFile = struct {
    path: []const u8,
    /// Racket states constants as `(define NAME INT)`; the other three as a
    /// `NAME … = … INT` assignment per line.
    racket: bool = false,
};

const binding_constants_files = [_]ConstantsFile{
    .{ .path = "bindings/rust/src/abi_constants.rs" },
    .{ .path = "bindings/python/pancake/_constants.py" },
    .{ .path = "bindings/ts/stack/internal/constants.ts" },
    .{ .path = "bindings/racket/private/constants.rkt", .racket = true },
    // The per-binding iroh FFI mirrors of the `PANCAKE_IROH_*` transport
    // constants, held against include/pancake_net_transport_iroh.h.
    .{ .path = "bindings/rust/src/sys/iroh.rs" },
    .{ .path = "bindings/python/pancake/_ffi_iroh.py" },
    .{ .path = "bindings/racket/private/ffi-iroh.rkt", .racket = true },
};

fn parseLeadingInt(s: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == start) return null;
    const mag = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
    return if (neg) -mag else mag;
}

fn firstIntIn(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '-' or (s[i] >= '0' and s[i] <= '9')) return parseLeadingInt(s[i..]);
    }
    return null;
}

/// The ABI version triple is stated four times: `abi_version` in `build.zig`,
/// `.version` in `build.zig.zon`, `PANCAKE_VERSION_*` in `src/c_abi/ocapn/mod.zig`,
/// and the generated `#define PANCAKE_VERSION_*` macros in `include/pancake_ocapn.h`.
/// This parses all four and holds them in lockstep, so bumping one surface
/// without the others fails the gate instead of shipping a package whose zon
/// version disagrees with the soname it installs.
fn checkAbiVersionLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Triple = struct { major: i64, minor: i64, patch: i64 };
    const sources = [_]struct {
        path: []const u8,
        keys: [3][]const u8,
        // The triple's declaration site, when the keys alone are ambiguous in
        // the file (build.zig has many `.major =` struct literals).
        anchor: ?[]const u8 = null,
    }{
        .{ .path = "build.zig", .keys = .{ ".major =", ".minor =", ".patch =" }, .anchor = "const abi_version" },
        .{ .path = "src/c_abi/ocapn/mod.zig", .keys = .{
            "PANCAKE_VERSION_MAJOR: u32 =",
            "PANCAKE_VERSION_MINOR: u32 =",
            "PANCAKE_VERSION_PATCH: u32 =",
        } },
        .{ .path = "include/pancake_ocapn.h", .keys = .{
            "#define PANCAKE_VERSION_MAJOR",
            "#define PANCAKE_VERSION_MINOR",
            "#define PANCAKE_VERSION_PATCH",
        } },
    };

    var triples: [sources.len]?Triple = @splat(null);
    for (sources, 0..) |source, i| {
        const contents = root.readFileAlloc(io, source.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI version lockstep check with {s}", .{ source.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const search_from = if (source.anchor) |anchor|
            (if (std.mem.indexOf(u8, contents, anchor)) |at| contents[at..] else contents)
        else
            contents;
        var parts: [3]i64 = undefined;
        var ok = true;
        for (source.keys, 0..) |key, k| {
            const at = std.mem.indexOf(u8, search_from, key) orelse {
                try appendViolation(gpa, violations, "{s}: ABI version component '{s}' not found", .{ source.path, key });
                ok = false;
                continue;
            };
            parts[k] = firstIntIn(search_from[at + key.len ..]) orelse {
                try appendViolation(gpa, violations, "{s}: ABI version component '{s}' has no integer value", .{ source.path, key });
                ok = false;
                continue;
            };
        }
        if (ok) triples[i] = .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    var zon_triple: ?Triple = null;
    const zon = root.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig.zon: failed to read for ABI version lockstep check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zon);
    if (std.mem.indexOf(u8, zon, ".version = \"")) |at| {
        const rest = zon[at + ".version = \"".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        var it = std.mem.splitScalar(u8, rest[0..end], '.');
        const major = firstIntIn(it.next() orelse "");
        const minor = firstIntIn(it.next() orelse "");
        const patch = firstIntIn(it.next() orelse "");
        if (major != null and minor != null and patch != null) {
            zon_triple = .{ .major = major.?, .minor = minor.?, .patch = patch.? };
        } else {
            try appendViolation(gpa, violations, "build.zig.zon: .version \"{s}\" is not a semantic version triple", .{rest[0..end]});
        }
    } else {
        try appendViolation(gpa, violations, "build.zig.zon: no .version field found for ABI version lockstep check", .{});
    }

    const anchor = triples[0] orelse return;
    for (sources[1..], triples[1..]) |source, maybe_triple| {
        const triple = maybe_triple orelse continue;
        if (!std.meta.eql(triple, anchor)) {
            try appendViolation(gpa, violations, "{s}: ABI version {d}.{d}.{d} drifts from build.zig abi_version {d}.{d}.{d}", .{
                source.path, triple.major, triple.minor, triple.patch, anchor.major, anchor.minor, anchor.patch,
            });
        }
    }
    if (zon_triple) |triple| {
        if (!std.meta.eql(triple, anchor)) {
            try appendViolation(gpa, violations, "build.zig.zon: .version {d}.{d}.{d} drifts from build.zig abi_version {d}.{d}.{d}", .{
                triple.major, triple.minor, triple.patch, anchor.major, anchor.minor, anchor.patch,
            });
        }
    }
}

/// `_release` is the only C ABI verb that frees a handle: a `*_free` export
/// is rejected outright, and a `*_close` must document that it does not free.
/// The endpoint
/// surfaces converged on that law — every handle frees through exactly one
/// `pancake_*_release`, and a `pancake_*_close` is a shutdown lever that
/// leaves the handle alive — so this holds it in the generated headers:
/// every `*_close` declaration must carry a doc comment that says
/// "without releasing" and never claims to free. A future netlayer that
/// reintroduces a freeing close fails the gate instead of shipping the
/// ambiguity to a C consumer.
/// The generated headers the C-ABI vocabulary checks below hold — every
/// exporting archive, one list, so a new archive cannot join some checks and
/// silently miss others.
const abi_vocabulary_headers = [_][]const u8{
    "include/pancake_ocapn.h",
    "include/pancake_driver.h",
    "include/pancake_net_transport_tcp.h",
    "include/pancake_net_transport_inproc.h",
    "include/pancake_net_transport_iroh.h",
};

fn checkAbiFreeingVerb(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI freeing-verb check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var line_it = std.mem.splitScalar(u8, contents, '\n');
        while (line_it.next()) |line| try lines.append(gpa, line);

        var decls: std.ArrayList(HeaderDecl) = .empty;
        defer decls.deinit(gpa);
        try collectHeaderDeclarations(gpa, contents, &decls);
        if (decls.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_ declarations; the ABI freeing-verb scanner no longer matches this header", .{path});
            continue;
        }

        for (decls.items) |decl| {
            const name = decl.name;
            // `*_free` is not an allowed freeing spelling: a handle that frees
            // is `*_release`, so a `pancake_*_free` export is the inconsistency
            // this rule exists to prevent, not merely a `*_close` to document.
            if (std.mem.endsWith(u8, name, "_free")) {
                try appendViolation(gpa, violations, "{s}: {s} frees a handle but is not spelled *_release; the one freeing verb is *_release", .{ path, name });
                continue;
            }
            if (!std.mem.endsWith(u8, name, "_close")) continue;
            const i = lineIndexOfOffset(contents, decl.offset);

            if (i == 0 or !std.mem.endsWith(u8, std.mem.trimEnd(u8, lines.items[i - 1], " \t"), "*/")) {
                try appendViolation(gpa, violations, "{s}: {s} has no doc comment; a *_close must state it closes \"without releasing\" the handle", .{ path, name });
                continue;
            }
            var states_no_release = false;
            var claims_free = false;
            var j: usize = i - 1;
            while (true) {
                const doc_line = lines.items[j];
                if (std.mem.indexOf(u8, doc_line, "without releasing") != null) states_no_release = true;
                if (std.mem.indexOf(u8, doc_line, "free") != null) claims_free = true;
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, doc_line, " \t"), "/*")) break;
                if (j == 0) break;
                j -= 1;
            }
            if (!states_no_release) {
                try appendViolation(gpa, violations, "{s}: {s} must state it closes \"without releasing\" the handle; release is the only freeing verb", .{ path, name });
            }
            if (claims_free) {
                try appendViolation(gpa, violations, "{s}: {s} claims to free in its doc; a freeing handle verb is spelled *_release", .{ path, name });
            }
        }
    }
}

/// The minimality bar from ADR-0059: a clean C ABI is not only correctly
/// represented (ADR-0059) but minimally shaped — one spelling per concept, no
/// accidental variation. This holds the two structural invariants a careless
/// addition would break (the close/release verb is held separately by
/// `checkAbiFreeingVerb`):
///   - constructor-twin completeness: every `*_new` that uses the library
///     allocator has exactly one allocator-aware twin (`*_new_in`, or
///     `*_new_with_allocator` for the context root), and every twin has its base;
///   - one error channel per archive: exactly one `last_error`/`clear_last_error`
///     pair per family — the ocapn root, `tcp`, `inproc`, `iroh` — and no other
///     error-reporting spelling.
fn checkCAbiSurfaceShape(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Collect every exported function name. The name slices reference the header
    // contents, so keep the buffers alive for the whole check.
    var contents_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (contents_buffers.items) |buf| gpa.free(buf);
        contents_buffers.deinit(gpa);
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var name_set = std.StringHashMap(void).init(gpa);
    defer name_set.deinit();

    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI surface-shape check with {s}", .{ path, @errorName(err) });
            continue;
        };
        try contents_buffers.append(gpa, contents);

        var decls: std.ArrayList(HeaderDecl) = .empty;
        defer decls.deinit(gpa);
        try collectHeaderDeclarations(gpa, contents, &decls);
        if (decls.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_ declarations; the ABI surface-shape scanner no longer matches this header", .{path});
            continue;
        }
        for (decls.items) |decl| {
            if (name_set.contains(decl.name)) continue;
            try name_set.put(decl.name, {});
            try names.append(gpa, decl.name);
        }
    }

    // Invariant 1, constructor-twin completeness.
    for (names.items) |name| {
        if (std.mem.endsWith(u8, name, "_in")) {
            const base = name[0 .. name.len - "_in".len];
            if (!name_set.contains(base)) {
                try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no base constructor {s}; an `_in` twin must pair a library-allocator base", .{ name, base });
            }
        } else if (std.mem.endsWith(u8, name, "_new_with_allocator")) {
            const base = name[0 .. name.len - "_with_allocator".len];
            if (!name_set.contains(base)) {
                try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no base constructor {s}", .{ name, base });
            }
        } else if (std.mem.indexOf(u8, name, "_new") != null) {
            const twin_in = try std.fmt.allocPrint(gpa, "{s}_in", .{name});
            defer gpa.free(twin_in);
            const twin_alloc = try std.fmt.allocPrint(gpa, "{s}_with_allocator", .{name});
            defer gpa.free(twin_alloc);
            if (!name_set.contains(twin_in) and !name_set.contains(twin_alloc)) {
                try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no allocator-aware twin ({s}_in or {s}_with_allocator); allocation policy is one axis spelled one way", .{ name, name, name });
            }
        }
    }

    // Invariant 2, one error channel per archive, no extra spelling.
    const allowed_error_families = [_][]const u8{ "", "host", "tcp", "inproc", "iroh" };
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, "_last_error")) continue;
        if (std.mem.endsWith(u8, name, "_clear_last_error")) continue;
        const head = name[0 .. name.len - "_last_error".len];
        var family: []const u8 = undefined;
        if (std.mem.eql(u8, head, "pancake")) {
            family = "";
        } else if (std.mem.startsWith(u8, head, "pancake_")) {
            family = head["pancake_".len..];
        } else continue;

        var family_ok = false;
        for (allowed_error_families) |f| {
            if (std.mem.eql(u8, f, family)) family_ok = true;
        }
        if (!family_ok) {
            try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} introduces an error channel for unexpected family `{s}`; the error channels are the ocapn root, host, tcp, inproc, iroh", .{ name, family });
            continue;
        }
        const clear = if (family.len == 0)
            try std.fmt.allocPrint(gpa, "pancake_clear_last_error", .{})
        else
            try std.fmt.allocPrint(gpa, "pancake_{s}_clear_last_error", .{family});
        defer gpa.free(clear);
        if (!name_set.contains(clear)) {
            try appendViolation(gpa, violations, "C ABI surface (ADR-0059): {s} has no matching {s}; an error channel is a last_error/clear_last_error pair", .{ name, clear });
        }
    }
}

/// Every function the C headers export must have a consumer: a reference
/// somewhere under `bindings/`, `examples/`, `interop/`, or `test/`. An export
/// nobody consumes or exercises is dead surface — the drift mode is a verb the
/// waist has superseded that keeps shipping because nothing points at it. The
/// scan collects every `pancake_*` identifier the consumer trees mention (one
/// pass, identifier boundaries), so `pancake_host_conn_feed` cannot satisfy
/// `pancake_host_conn_feed_bytes`.
fn checkAbiExportsConsumed(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exported names, parsed from function declarations only.
    var exports: std.ArrayList(struct { name: []const u8, header: []const u8 }) = .empty;
    defer exports.deinit(gpa);
    for (abi_vocabulary_headers) |path| {
        const contents = root.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for ABI consumer check with {s}", .{ path, @errorName(err) });
            continue;
        };
        var decls: std.ArrayList(HeaderDecl) = .empty;
        defer decls.deinit(gpa);
        try collectHeaderDeclarations(gpa, contents, &decls);
        if (decls.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_ declarations; the ABI consumer scanner no longer matches this header", .{path});
            continue;
        }
        for (decls.items) |decl| try exports.append(gpa, .{ .name = decl.name, .header = path });
    }

    // Every pancake_* identifier the consumer trees mention, one walk.
    var consumed = std.StringHashMap(void).init(gpa);
    defer consumed.deinit();
    const consumer_roots = [_][]const u8{ "bindings", "examples", "interop", "test" };
    const consumer_exts = [_][]const u8{ ".rs", ".ts", ".py", ".rkt", ".c", ".h", ".zig", ".scm" };
    const skip_dirs = [_][]const u8{ "target", "node_modules", "__pycache__", "compiled", ".zig-cache", "zig-out" };
    for (consumer_roots) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for ABI consumer check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                var skip = false;
                for (skip_dirs) |sd| {
                    if (std.mem.eql(u8, entry.basename, sd)) skip = true;
                }
                if (!skip) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            var ext_ok = false;
            for (consumer_exts) |ext| {
                if (std.mem.endsWith(u8, entry.basename, ext)) ext_ok = true;
            }
            if (!ext_ok) continue;
            const contents = dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 24)) catch |err| {
                try appendViolation(gpa, violations, "{s}/{s}: failed to read for ABI consumer check with {s}", .{ dir_path, entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, contents, search, "pancake_")) |start| {
                var end = start;
                while (end < contents.len and isIdentChar(contents[end])) end += 1;
                search = end;
                if (start > 0 and isIdentChar(contents[start - 1])) continue;
                const ident = contents[start..end];
                if (consumed.contains(ident)) continue;
                try consumed.put(try arena.dupe(u8, ident), {});
            }
        }
    }

    var export_names = std.StringHashMap(void).init(gpa);
    defer export_names.deinit();
    for (exports.items) |exported| try export_names.put(exported.name, {});

    for (exports.items) |exported| {
        if (consumed.contains(exported.name)) continue;
        // An allocator twin of an exported base constructor is structurally
        // required by ADR-0059 (checkCAbiSurfaceShape holds the pairing), so
        // its existence does not need a consumer of its own; everything else
        // must earn its slot.
        if (std.mem.endsWith(u8, exported.name, "_in")) {
            const base = exported.name[0 .. exported.name.len - "_in".len];
            if (export_names.contains(base)) continue;
        }
        if (std.mem.endsWith(u8, exported.name, "_with_allocator")) {
            const base = exported.name[0 .. exported.name.len - "_with_allocator".len];
            if (export_names.contains(base)) continue;
        }
        try appendViolation(gpa, violations, "{s}: exported `{s}` has no consumer under bindings/, examples/, interop/, or test/ — dead surface; retire it or give it the consumer that justifies it", .{ exported.header, exported.name });
    }
}

fn isIdentChar(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

/// One exported function declaration found in a generated header: its name and
/// the byte offset of that name in the header text (so a caller can locate the
/// declaration's line for its doc comment).
const HeaderDecl = struct { name: []const u8, offset: usize };

/// Collect every C ABI function declaration in a generated header: a `pancake_`
/// identifier at an identifier boundary directly followed by `(`, found after
/// blanking `/* */` comments so a prose mention of a name is never mistaken for
/// a prototype. Matching on that call shape rather than on a set of allowed
/// return-type spellings keeps a new export visible whatever its return type is,
/// whether `uint64_t`, a `double`, or a pointer. Each appended `name` slice
/// references `contents`, so the caller must keep it alive; callers also read
/// the declaration count, and a zero there means the scanner has stopped
/// matching the header.
fn collectHeaderDeclarations(
    gpa: std.mem.Allocator,
    contents: []const u8,
    out: *std.ArrayList(HeaderDecl),
) !void {
    const text = try gpa.dupe(u8, contents);
    defer gpa.free(text);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "/*")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "*/") orelse break;
        @memset(text[open .. close + 2], ' ');
        i = close + 2;
    }
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "pancake_")) |start| {
        var end = start;
        while (end < text.len and isIdentChar(text[end])) end += 1;
        search = end;
        if (start > 0 and isIdentChar(text[start - 1])) continue;
        if (end >= text.len or text[end] != '(') continue;
        // Blanking preserves byte length, so offsets index the original.
        try out.append(gpa, .{ .name = contents[start..end], .offset = start });
    }
}

/// The 0-based line index of `offset` within `contents` (the newline count
/// before it), so a declaration found by offset can be tied to its doc comment.
fn lineIndexOfOffset(contents: []const u8, offset: usize) usize {
    return std.mem.count(u8, contents[0..offset], "\n");
}

/// Every per-binding ABI constant mirror restates discriminants and return codes
/// from the generated headers by hand. The headers themselves cannot drift (the
/// parity tests reflect them from the Zig c_abi source), but the mirror files
/// can. This parses each mirror's numeric values and asserts they match the
/// matching `#define PANCAKE_…` value, so a hand-edit that desyncs a constant
/// fails the gate instead of waiting for a live conversation to touch it.
///
/// The header values come from every generated header, not just the ocapn
/// base, so the driver archive's `PANCAKE_HOST_*` and the iroh archive's
/// `PANCAKE_IROH_*` mirrors are held too. The mirror
/// files span both the ocapn constant files and the per-binding iroh FFI files
/// (`binding_constants_files`), and `lookupHeaderConst` tolerates the `PANCAKE_`
/// or leading-`_` prefix a private FFI mirror spells its names with.
fn checkBindingConstants(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const headers = [_][]const u8{
        "include/pancake_ocapn.h",
        "include/pancake_driver.h",
        "include/pancake_net_transport_tcp.h",
        "include/pancake_net_transport_inproc.h",
        "include/pancake_net_transport_iroh.h",
    };
    // The header buffers back the `header_vals` key slices, so keep them alive
    // for the whole check.
    var header_buffers: std.ArrayList([]u8) = .empty;
    defer {
        for (header_buffers.items) |buf| gpa.free(buf);
        header_buffers.deinit(gpa);
    }

    // Map every header's `#define PANCAKE_<NAME> <int>` value, keyed by the name
    // after the `PANCAKE_` prefix. Mirrors drop `ERR_` from `WOULD_BLOCK`, so
    // each `ERR_<X>` also registers a bare `<X>` alias.
    var header_vals = std.StringHashMap(i64).init(gpa);
    defer header_vals.deinit();
    for (headers) |header_path| {
        const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for constant-mirror check with {s}", .{ header_path, @errorName(err) });
            continue;
        };
        try header_buffers.append(gpa, header);
        var rest = header;
        const needle = "#define PANCAKE_";
        while (std.mem.indexOf(u8, rest, needle)) |start| {
            const after = rest[start + needle.len ..];
            const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
            const line = after[0..line_end];
            rest = after[line_end..];

            const name_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
            const name = line[0..name_end];
            const value = firstIntIn(line[name_end..]) orelse continue;
            try header_vals.put(name, value);
            if (std.mem.startsWith(u8, name, "ERR_")) try header_vals.put(name["ERR_".len..], value);
        }
    }

    var norm_buf: [128]u8 = undefined;
    for (binding_constants_files) |file| {
        const contents = root.readFileAlloc(io, file.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for constant-mirror check with {s}", .{ file.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        if (file.racket) {
            var rest = contents;
            while (std.mem.indexOf(u8, rest, "(define ")) |start| {
                const after = rest[start + "(define ".len ..];
                rest = after;
                const name_end = std.mem.indexOfAny(u8, after, " \t") orelse continue;
                const raw_name = after[0..name_end];
                const value = firstIntIn(after[name_end..]) orelse continue;
                try compareConstant(gpa, violations, file.path, &header_vals, raw_name, value, &norm_buf);
            }
        } else {
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |raw_line| {
                const trimmed = std.mem.trim(u8, raw_line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#")) continue;
                const eq = std.mem.indexOfScalar(u8, raw_line, '=') orelse continue;
                var lhs = raw_line[0..eq];
                if (std.mem.indexOfScalar(u8, lhs, ':')) |colon| lhs = lhs[0..colon];
                const lhs_trimmed = std.mem.trim(u8, lhs, " \t");
                const name_start = if (std.mem.lastIndexOfAny(u8, lhs_trimmed, " \t")) |sp| sp + 1 else 0;
                const raw_name = lhs_trimmed[name_start..];
                if (raw_name.len == 0) continue;
                // The value is the first integer up to a `;` or `//` comment.
                var rhs = raw_line[eq + 1 ..];
                if (std.mem.indexOfScalar(u8, rhs, ';')) |semi| rhs = rhs[0..semi];
                if (std.mem.indexOf(u8, rhs, "//")) |c| rhs = rhs[0..c];
                const value = firstIntIn(rhs) orelse continue;
                try compareConstant(gpa, violations, file.path, &header_vals, raw_name, value, &norm_buf);
            }
        }
    }
}

fn compareConstant(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    header_vals: *std.StringHashMap(i64),
    raw_name: []const u8,
    value: i64,
    norm_buf: *[128]u8,
) !void {
    if (raw_name.len > norm_buf.len) return;
    var name = norm_buf[0..raw_name.len];
    for (raw_name, 0..) |c, i| name[i] = if (c == '-') '_' else std.ascii.toUpper(c);
    const expected = lookupHeaderConst(header_vals, name) orelse return; // no header counterpart (e.g. struct sizes)
    if (expected != value) {
        try appendViolation(gpa, violations, "{s}: constant {s} = {d} drifts from header PANCAKE_… = {d}", .{ path, raw_name, value, expected });
    }
}

/// Look up a mirror constant's expected header value, tolerating the two prefix
/// conventions a private FFI mirror uses: an iroh Rust mirror spells the full
/// `PANCAKE_IROH_EV_*`, a Python one spells `_IROH_EV_*`, while the header keys
/// are stripped of `PANCAKE_`. The direct hit is tried first; a prefix strip
/// only ever turns a would-be silent skip into a match, never an existing match
/// into a miss.
fn lookupHeaderConst(header_vals: *std.StringHashMap(i64), name: []const u8) ?i64 {
    if (header_vals.get(name)) |v| return v;
    if (std.mem.startsWith(u8, name, "PANCAKE_")) {
        if (header_vals.get(name["PANCAKE_".len..])) |v| return v;
    }
    if (std.mem.startsWith(u8, name, "_")) {
        if (header_vals.get(name[1..])) |v| return v;
    }
    return null;
}

/// Every `PANCAKE_HOST_ACTION_*` kind must appear in each binding's host-action
/// drain. The Zig embedders share one skeleton (`driver_core.drainActions`);
/// the four language bindings each hand-roll the arm set, and a forgotten arm
/// used to be a silent production miss (the `.close` hand-add). Grep-level:
/// the header's action name must appear as `HOST_ACTION_<NAME>` (or
/// `HOST-ACTION-<NAME>` in Racket) in the drain file. A new kind without a
/// binding arm fails `zig build meta-check`.
fn checkBindingHostActionDrains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/pancake_driver.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for host-action drain check with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    var action_names: std.ArrayList([]const u8) = .empty;
    defer action_names.deinit(gpa);
    const needle = "#define PANCAKE_HOST_ACTION_";
    var rest = header;
    while (std.mem.indexOf(u8, rest, needle)) |start| {
        const after = rest[start + needle.len ..];
        const name_end = std.mem.indexOfAny(u8, after, " \t\r\n") orelse after.len;
        const name = after[0..name_end];
        if (name.len != 0) try action_names.append(gpa, name);
        rest = after[name_end..];
    }
    if (action_names.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no PANCAKE_HOST_ACTION_* constants found for drain check", .{header_path});
        return;
    }

    const drains = [_]struct { path: []const u8, sep: u8 }{
        .{ .path = "bindings/ts/stack/host.ts", .sep = '_' },
        .{ .path = "bindings/python/pancake/_host.py", .sep = '_' },
        .{ .path = "bindings/rust/src/host.rs", .sep = '_' },
        .{ .path = "bindings/racket/private/host.rkt", .sep = '-' },
    };

    var token_buf: [128]u8 = undefined;
    for (drains) |drain| {
        const contents = root.readFileAlloc(io, drain.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host-action drain check with {s}", .{ drain.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        for (action_names.items) |name| {
            // `HOST{sep}ACTION{sep}` + name with `_` rewritten to `sep`.
            const prefix = "HOST";
            const mid = "ACTION";
            var n: usize = 0;
            const need = prefix.len + 1 + mid.len + 1 + name.len;
            if (need > token_buf.len) {
                try appendViolation(gpa, violations, "{s}: host-action name `{s}` too long for drain-token buffer", .{ header_path, name });
                continue;
            }
            @memcpy(token_buf[n..][0..prefix.len], prefix);
            n += prefix.len;
            token_buf[n] = drain.sep;
            n += 1;
            @memcpy(token_buf[n..][0..mid.len], mid);
            n += mid.len;
            token_buf[n] = drain.sep;
            n += 1;
            for (name) |c| {
                token_buf[n] = if (c == '_') drain.sep else c;
                n += 1;
            }
            const token = token_buf[0..n];
            if (std.mem.indexOf(u8, contents, token) == null) {
                try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` (from PANCAKE_HOST_ACTION_{s})", .{ drain.path, token, name });
            }
        }
    }
}

/// The per-binding spellings of "raise this ABI error code". A numeric literal
/// at one of these sites bypasses the constant mirror that
/// `checkBindingConstants` keeps honest, so the code can drift from
/// `pancake_ocapn.h` without any gate noticing. Error sites must name the mirrored
/// constant; the literal lives in the constants file alone.
const binding_error_raise_patterns = [_][]const u8{
    "from_code(-", // Rust: Error::from_code(sys::ERR_…)
    "PancakeError(-", // Python / Deno: PancakeError(_ERR_… / ERR-less mirror name)
    "(check -", // Racket: (check ERR-…)
};

/// Reject numeric error-code literals at binding raise sites. Scans every
/// binding source file (skipping generated trees) for a raise pattern followed
/// by a digit — `from_code(-9)` fails, `from_code(sys::ERR_IO)` passes.
fn checkBindingMagicErrorCodes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "bindings", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "bindings: failed to open for magic-error-code check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "target/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "__pycache__/") != null) continue;
        const is_source = std.mem.endsWith(u8, entry.path, ".rs") or
            std.mem.endsWith(u8, entry.path, ".py") or
            std.mem.endsWith(u8, entry.path, ".ts") or
            std.mem.endsWith(u8, entry.path, ".rkt");
        if (!is_source) continue;
        const path = try std.fmt.allocPrint(gpa, "bindings/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for magic-error-code check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (binding_error_raise_patterns) |pattern| {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, contents, search, pattern)) |start| {
                search = start + pattern.len;
                if (search >= contents.len) break;
                const c = contents[search];
                if (c < '0' or c > '9') continue;
                const line = 1 + std.mem.count(u8, contents[0..start], "\n");
                try appendViolation(gpa, violations, "{s}:{d}: numeric error code at a raise site (`{s}{c}…`) — name the mirrored ABI constant instead", .{ path, line, pattern, c });
            }
        }
    }
}

/// The iroh sidecar C ABI is spelled three times by hand — the Rust
/// definitions (`transports/iroh/src/lib.rs`), the C header
/// (`transports/iroh/include/pancake_iroh_sidecar.h`), and the Zig resident's
/// externs (`src/net/transport/iroh.zig`) — and the hermetic gate never links
/// them, so a
/// drifted spelling would surface only as a crash in the cargo-equipped
/// `iroh-interop` run, or not at all for a silent width change. The coarse
/// shape below is the strongest contract three syntaxes share.
const CoarseAbiType = enum {
    ptr,
    word,
    iword,
    int32,
    uint32,
    none,
    unknown,

    fn label(self: CoarseAbiType) []const u8 {
        return switch (self) {
            .ptr => "ptr",
            .word => "usize",
            .iword => "isize",
            .int32 => "i32",
            .uint32 => "u32",
            .none => "void",
            .unknown => "?",
        };
    }
};

/// Map one parameter or return spelling onto the coarse ABI shape. Works on
/// the whole parameter text in all three syntaxes ("size_t out_cap",
/// "out_cap: usize", "node_id: [*]const u8"): any pointer marker wins, then
/// the scalar width tokens. An unmapped spelling classifies `unknown`, which
/// never equals itself across surfaces, new types must be added here
/// consciously, not slip through.
fn classifyAbiType(text: []const u8) CoarseAbiType {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or std.mem.eql(u8, t, "void")) return .none;
    if (std.mem.indexOfScalar(u8, t, '*') != null) return .ptr;
    if (std.mem.indexOf(u8, t, "intptr_t") != null) return .iword;
    if (std.mem.indexOf(u8, t, "isize") != null) return .iword;
    if (std.mem.indexOf(u8, t, "size_t") != null) return .word;
    if (std.mem.indexOf(u8, t, "usize") != null) return .word;
    // `uint32_t` contains `int32_t` as a substring, so the unsigned width must
    // be classified before the signed one.
    if (std.mem.indexOf(u8, t, "uint32_t") != null) return .uint32;
    if (std.mem.indexOf(u8, t, "u32") != null) return .uint32;
    if (std.mem.indexOf(u8, t, "int32_t") != null) return .int32;
    if (std.mem.indexOf(u8, t, "i32") != null) return .int32;
    if (std.mem.indexOf(u8, t, "void") != null) return .none;
    return .unknown;
}

/// Render a parameter list and return type as the canonical coarse signature,
/// e.g. `ptr,usize->isize`. Parameter lists in this ABI carry no nested
/// parentheses, so a top-level comma split is exact.
fn renderAbiSig(arena: std.mem.Allocator, params_text: []const u8, ret_text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const trimmed_params = std.mem.trim(u8, params_text, " \t\r\n");
    if (trimmed_params.len != 0 and !std.mem.eql(u8, trimmed_params, "void")) {
        var it = std.mem.splitScalar(u8, trimmed_params, ',');
        var first = true;
        while (it.next()) |param| {
            // Rust's multi-line declarations end with a trailing comma; an
            // empty segment is that comma, not a parameter.
            if (std.mem.trim(u8, param, " \t\r\n").len == 0) continue;
            if (!first) try out.append(arena, ',');
            first = false;
            try out.appendSlice(arena, classifyAbiType(param).label());
        }
    }
    try out.appendSlice(arena, "->");
    try out.appendSlice(arena, classifyAbiType(ret_text).label());
    return out.items;
}

fn isAbiIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Extract `pancake_iroh_sidecar_*` declarations behind a fixed anchor —
/// Rust's `pub extern "C" fn ` or Zig's `extern fn ` — into `out` as name ->
/// coarse signature. The return type runs from the closing parenthesis to `{`
/// (Rust, where a leading `->` is stripped) or `;` (Zig).
fn extractAnchoredAbi(
    arena: std.mem.Allocator,
    text: []const u8,
    anchor: []const u8,
    ret_end: u8,
    out: *std.StringHashMap([]const u8),
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, anchor)) |start| {
        const name_start = start + anchor.len;
        var name_end = name_start;
        while (name_end < text.len and isAbiIdentChar(text[name_end])) name_end += 1;
        search = name_end;
        const name = text[name_start..name_end];
        if (!std.mem.startsWith(u8, name, "pancake_iroh_sidecar_")) continue;
        if (name_end >= text.len or text[name_end] != '(') continue;
        const params_end = std.mem.indexOfScalarPos(u8, text, name_end + 1, ')') orelse continue;
        const ret_stop = std.mem.indexOfScalarPos(u8, text, params_end + 1, ret_end) orelse continue;
        var ret_text = std.mem.trim(u8, text[params_end + 1 .. ret_stop], " \t\r\n");
        if (std.mem.startsWith(u8, ret_text, "->")) ret_text = ret_text[2..];
        const sig = try renderAbiSig(arena, text[name_end + 1 .. params_end], ret_text);
        try out.put(name, sig);
    }
}

/// Extract `pancake_iroh_sidecar_*` declarations from the C header into `out`
/// as name -> coarse signature. Block comments are blanked first so prose
/// mentions of the function names cannot match; a declaration is a
/// `pancake_iroh_sidecar_` identifier directly followed by `(`, with its return
/// type read backward to the previous `;`.
fn extractCHeaderAbi(
    arena: std.mem.Allocator,
    contents: []const u8,
    out: *std.StringHashMap([]const u8),
) !void {
    const text = try arena.dupe(u8, contents);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "/*")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "*/") orelse break;
        @memset(text[open .. close + 2], ' ');
        i = close + 2;
    }
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "pancake_iroh_sidecar_")) |start| {
        var name_end = start;
        while (name_end < text.len and isAbiIdentChar(text[name_end])) name_end += 1;
        search = name_end;
        if (start > 0 and isAbiIdentChar(text[start - 1])) continue;
        if (name_end >= text.len or text[name_end] != '(') continue;
        const params_end = std.mem.indexOfScalarPos(u8, text, name_end + 1, ')') orelse continue;
        const ret_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], ';')) |semi| semi + 1 else 0;
        const sig = try renderAbiSig(arena, text[name_end + 1 .. params_end], text[ret_start..start]);
        try out.put(text[start..name_end], sig);
    }
}

/// Hold the three hand-spelled surfaces of the iroh sidecar C ABI (ADR-0055)
/// to the same function set, arity, and coarse type shape.
fn checkIrohSidecarAbi(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const surfaces = [_]struct { path: []const u8, anchor: ?[]const u8, ret_end: u8 }{
        .{ .path = "transports/iroh/src/lib.rs", .anchor = "pub extern \"C\" fn ", .ret_end = '{' },
        .{ .path = "transports/iroh/include/pancake_iroh_sidecar.h", .anchor = null, .ret_end = ';' },
        .{ .path = "src/net/transport/iroh.zig", .anchor = "extern fn ", .ret_end = ';' },
    };
    var maps: [surfaces.len]std.StringHashMap([]const u8) = undefined;
    for (surfaces, 0..) |surface, idx| {
        maps[idx] = std.StringHashMap([]const u8).init(arena);
        const contents = root.readFileAlloc(io, surface.path, arena, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for iroh ABI parity with {s}", .{ surface.path, @errorName(err) });
            return;
        };
        if (surface.anchor) |anchor| {
            try extractAnchoredAbi(arena, contents, anchor, surface.ret_end, &maps[idx]);
        } else {
            try extractCHeaderAbi(arena, contents, &maps[idx]);
        }
        if (maps[idx].count() == 0) {
            try appendViolation(gpa, violations, "{s}: found no pancake_iroh_sidecar_ declarations, the ABI parity scanner no longer matches this surface", .{surface.path});
            return;
        }
    }

    var names = std.StringHashMap(void).init(arena);
    for (&maps) |*map| {
        var it = map.keyIterator();
        while (it.next()) |key| try names.put(key.*, {});
    }
    var name_it = names.keyIterator();
    while (name_it.next()) |key| {
        const name = key.*;
        var sigs: [surfaces.len]?[]const u8 = undefined;
        for (&maps, 0..) |*map, idx| sigs[idx] = map.get(name);
        for (surfaces, sigs) |surface, sig| {
            if (sig == null) {
                try appendViolation(gpa, violations, "{s}: iroh sidecar ABI function `{s}` is missing from this surface", .{ surface.path, name });
            }
        }
        const reference = sigs[0] orelse continue;
        for (surfaces[1..], sigs[1..]) |surface, sig| {
            const other = sig orelse continue;
            if (!std.mem.eql(u8, reference, other)) {
                try appendViolation(gpa, violations, "{s}: `{s}` is `{s}` here but `{s}` in {s}", .{ surface.path, name, other, reference, surfaces[0].path });
            }
        }
    }
}

/// The first quoted string in `text` starting at `from`, or null when none
/// remains. Returns the bytes between the quotes.
fn nextQuotedString(text: []const u8, from: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, text, from, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

/// ADR-0055 commits the sidecar to reproducible dependency resolution: the
/// crate wraps an external network stack, so `transports/iroh/Cargo.lock` is
/// checked in and every direct dependency in its `Cargo.toml` is pinned to an
/// exact `=x.y.z` version, making an intentional bump visible in the manifest
/// rather than only in the lockfile. This check holds both halves so the
/// discipline cannot drift off silently when a dependency is added or edited.
fn checkIrohSidecarPins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    root.access(io, "transports/iroh/Cargo.lock", .{}) catch {
        try appendViolation(gpa, violations, "transports/iroh/Cargo.lock: missing, the sidecar lockfile is deliberately committed (ADR-0055) so iroh gates resolve the same dependency tree on every machine", .{});
    };

    const manifest_path = "transports/iroh/Cargo.toml";
    const contents = root.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for sidecar pin check with {s}", .{ manifest_path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var pins_seen: usize = 0;
    var in_dep_section = false;
    var in_dotted_dep_table = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            // Every dependency table carries the word: `[dependencies]`,
            // `[dev-dependencies]`, `[build-dependencies]`, dotted and
            // target-specific forms alike.
            in_dep_section = std.mem.indexOf(u8, line, "dependencies") != null;
            // In a dotted table like `[dependencies.iroh]` the dependency is
            // the table itself, so only its `version` key carries the pin.
            in_dotted_dep_table = in_dep_section and std.mem.indexOf(u8, line, "dependencies.") != null;
            continue;
        }
        if (!in_dep_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (in_dotted_dep_table and !std.mem.eql(u8, key, "version")) continue;
        // An inline table names its version explicitly; a plain string dep is
        // the version itself. Anything else (git, path, no version) escapes
        // the registry pin and fails the same way.
        const version = if (std.mem.indexOf(u8, line, "version")) |v|
            nextQuotedString(line, v)
        else
            nextQuotedString(line, eq);
        const pinned = if (version) |spec| spec.len > 1 and spec[0] == '=' else false;
        if (!pinned) {
            try appendViolation(gpa, violations, "{s}: dependency `{s}` is not pinned to an exact `=x.y.z` version — the sidecar's direct dependencies are pinned exactly (ADR-0055)", .{ manifest_path, key });
            continue;
        }
        pins_seen += 1;
    }
    if (pins_seen == 0) {
        try appendViolation(gpa, violations, "{s}: found no pinned dependencies — the sidecar pin scanner no longer matches this manifest", .{manifest_path});
    }
}

/// The application-surface verbs the vision promises in every binding and on the
/// native driver. Each surface that introduces the vocabulary must list all of
/// them; a dropped verb is a silently second-class surface.
const application_surface_verbs = [_][]const u8{
    "connect", "listen", "fetch", "publish", "spawn", "send", "tell", "serve", "close",
};

/// The living-state surfaces that enumerate the application-surface vocabulary.
/// `bindings/README.md` is the authoritative enumeration; `examples/README.md`
/// repeats it as the tutorial index. Every other surface (README, vision)
/// cites "nine verbs" with a link instead of enumerating, so a partial copy
/// cannot exist there.
const application_surface_files = [_][]const u8{
    "bindings/README.md", "examples/README.md",
};

/// Whether `verb` appears as an inline-code token in `contents`, tolerating the
/// three ways the surfaces write it: bare (`connect`), as a call
/// (`connect(locator)`), or as a method on a receiver (`conn.tell(ref, …)`).
/// A trailing `(…)` and a leading `recv.` are stripped before comparison.
fn mentionsVerbInCode(contents: []const u8, verb: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, contents, i, '`')) |open| {
        const after = open + 1;
        const close = std.mem.indexOfScalarPos(u8, contents, after, '`') orelse return false;
        var span = contents[after..close];
        if (std.mem.indexOfScalar(u8, span, '(')) |paren| span = span[0..paren];
        if (std.mem.lastIndexOfScalar(u8, span, '.')) |dot| span = span[dot + 1 ..];
        if (std.mem.eql(u8, span, verb)) return true;
        i = close + 1;
    }
    return false;
}

/// Gate that every living-state surface listing the application vocabulary names
/// all nine verbs. This is the check the prose restatements collapse toward: when
/// a verb is added or renamed, this fails until every surface is updated, so the
/// list cannot silently drift on one surface (as it did when `listen` and `tell`
/// went missing from the examples index).
fn checkApplicationSurfaceVerbs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (application_surface_files) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for application-surface verb check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (application_surface_verbs) |verb| {
            if (!mentionsVerbInCode(contents, verb)) {
                try appendViolation(gpa, violations, "{s}: application-surface verb `{s}` is missing, the nine-verb vocabulary (connect, listen, fetch, publish, spawn, send, tell, serve, close) must be complete on every surface that lists it", .{ path, verb });
            }
        }
    }
}

/// Gate that every numbered Zig example chapter (`examples/zig/NN_*.zig`) and
/// every C example source (`examples/c/*.c`) the build compiles has an index row
/// in `examples/README.md`, and every numbered chapter also appears on the site
/// examples page. A new chapter or C program can otherwise ship undiscoverable;
/// the index, the site, and the directories must agree. (The C arm is what would
/// have caught `compose_transports.c` shipping unindexed.)
fn checkExampleIndex(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const index = root.readFileAlloc(io, "examples/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "examples/README.md: failed to read for example-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(index);

    const site = root.readFileAlloc(io, "site/content/examples.smd", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "site/content/examples.smd: failed to read for example-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(site);

    var dir = root.openDir(io, "examples/zig", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/zig: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Numbered chapters only: a leading digit. Helpers like `frame_view.zig`
        // are linked from the lower-level section, not the chapter table.
        if (entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "zig/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, index, needle) == null) {
            try appendViolation(gpa, violations, "examples/README.md: missing index row for example chapter `{s}`", .{entry.name});
        }

        var site_needle_buf: [160]u8 = undefined;
        const site_needle = std.fmt.bufPrint(&site_needle_buf, "examples/zig/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, site, site_needle) == null) {
            try appendViolation(gpa, violations, "site/content/examples.smd: missing row for example chapter `{s}`", .{entry.name});
        }
    }

    // Every C example source is a first-class built program (`build.zig` compiles
    // and runs each under `zig build examples`), so each must be discoverable from
    // the index too.
    var c_dir = root.openDir(io, "examples/c", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/c: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer c_dir.close(io);

    var c_it = c_dir.iterate();
    while (try c_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "c/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, index, needle) == null) {
            try appendViolation(gpa, violations, "examples/README.md: missing index row for C example `{s}`", .{entry.name});
        }
    }
}

/// `zig build examples` compiles every row of the hand-maintained `zig_examples`
/// and `c_examples` tables in `build.zig`. An example dropped from a table still
/// on disk never runs under `check`; a stale table row points at a missing file
/// and fails at compile time with a less actionable error. Forward: every
/// `examples/zig/*.zig` and `examples/c/*.c` basename appears as a `.path` in
/// the matching table. Reverse: every table `.path` resolves on disk.
fn checkExampleWiring(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read for example-wiring check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var table_paths = std.StringHashMap(void).init(gpa);
    defer table_paths.deinit();
    try collectBuildExamplePaths(build_zig, &table_paths);

    // Forward: every on-disk example source is listed in build.zig's tables.
    for (example_source_dirs) |spec| {
        var dir = root.openDir(io, spec.dir, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for example-wiring check with {s}", .{ spec.dir, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, spec.ext)) continue;

            var path_buf: [192]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ spec.dir, entry.name }) catch {
                try appendViolation(gpa, violations, "{s}/{s}: path too long for example-wiring check", .{ spec.dir, entry.name });
                continue;
            };
            if (!table_paths.contains(path)) {
                try appendViolation(gpa, violations, "{s}: not listed in build.zig's {s} table, it silently never runs under `zig build examples`", .{ path, spec.table_name });
            }
        }
    }

    // Reverse: every table path resolves on disk.
    var it = table_paths.keyIterator();
    while (it.next()) |path| {
        root.access(io, path.*, .{}) catch |err| {
            try appendViolation(gpa, violations, "build.zig: {s} table lists `{s}` but it is not accessible ({s})", .{
                if (std.mem.startsWith(u8, path.*, "examples/zig/")) "zig_examples" else "c_examples",
                path.*,
                @errorName(err),
            });
        };
    }
}

const example_source_dirs = [_]struct { dir: []const u8, ext: []const u8, table_name: []const u8 }{
    .{ .dir = "examples/zig", .ext = ".zig", .table_name = "zig_examples" },
    .{ .dir = "examples/c", .ext = ".c", .table_name = "c_examples" },
};

fn collectBuildExamplePaths(build_zig: []const u8, out: *std.StringHashMap(void)) !void {
    var rest = build_zig;
    while (std.mem.indexOf(u8, rest, ".path = \"")) |start| {
        const after = rest[start + ".path = \"".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const path = after[0..end];
        rest = after[end..];
        if (!std.mem.startsWith(u8, path, "examples/zig/") and !std.mem.startsWith(u8, path, "examples/c/")) continue;
        try out.put(path, {});
    }
}

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

    fn region(self: CommandScan, text: []const u8) !void {
        var rest = text;
        while (std.mem.indexOf(u8, rest, "zig build")) |start| {
            const after = rest[start + "zig build".len ..];
            rest = after;

            const trimmed = std.mem.trimStart(u8, after, " \t");
            if (trimmed.len == 0 or isCommandTerminator(trimmed[0])) continue;

            const documented_step = std.mem.trim(u8, trimmed[0..firstCommandTokenEnd(trimmed)], "`'\".,);]");
            if (documented_step.len == 0) continue;
            if (std.mem.startsWith(u8, documented_step, "-")) continue;

            try self.documented.put(try self.documented_arena.dupe(u8, documented_step), {});
            if (!self.steps.contains(documented_step)) {
                try appendViolation(self.gpa, self.violations, "{s}: documents `zig build {s}`, but build.zig has no step named `{s}`", .{
                    self.path,
                    documented_step,
                    documented_step,
                });
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

fn checkDocumentedBuildSteps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read with {s}", .{@errorName(err)});
        return;
    };
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
    // Steps are declared three ways: directly as `b.step("name", …)`,
    // table-driven as `.step_name = "name"` rows later passed to `b.step`, and
    // header-gen rows that carry a check/write pair as `.check_step_name` /
    // `.write_step_name`, each also passed to `b.step`.
    const patterns = [_][]const u8{ "b.step(\"", ".step_name = \"", ".check_step_name = \"", ".write_step_name = \"" };
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
    "docs/architecture.md",
    "docs/consuming-from-c.md",
    "site/content/reference/index.smd",
};

/// Every composable C ABI archive named in the build must appear in the
/// first-read archive tables, so a new archive cannot land without a doc row.
/// The archive set is read from `build.zig`'s `archive_table` rows, not kept
/// as a second list here, so a new `.artifact` row is demanded in the docs the
/// moment it exists.
fn checkArchiveTables(
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

const doc_c_abi_header_paths = [_][]const u8{
    "include/pancake_ocapn.h",
    "include/pancake_driver.h",
    "include/pancake_net_transport_tcp.h",
    "include/pancake_net_transport_inproc.h",
    "include/pancake_net_transport_iroh.h",
    "transports/iroh/include/pancake_iroh_sidecar.h",
};

fn isPancakeIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

fn collectPancakeSymbols(
    contents: []const u8,
    out: *std.StringHashMap(void),
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, contents, search, "pancake_")) |start| {
        var end = start + "pancake_".len;
        while (end < contents.len and isPancakeIdentChar(contents[end])) end += 1;
        search = end;
        if (start > 0 and isIdentChar(contents[start - 1])) continue;
        const name = contents[start..end];
        if (!out.contains(name)) try out.put(name, {});
    }
}

fn pancakeSymbolFamilyExists(prefix: []const u8, symbols: *const std.StringHashMap(void)) bool {
    var it = symbols.keyIterator();
    while (it.next()) |key| {
        if (std.mem.startsWith(u8, key.*, prefix)) return true;
    }
    return false;
}

fn docCAbiTokenValid(token: []const u8, symbols: *const std.StringHashMap(void)) bool {
    if (token.len < "pancake_".len) return false;

    if (std.mem.eql(u8, token, "pancake_*_release")) {
        var it = symbols.keyIterator();
        while (it.next()) |key| {
            if (!std.mem.startsWith(u8, key.*, "pancake_")) continue;
            if (!std.mem.endsWith(u8, key.*, "_release")) continue;
            return true;
        }
        return false;
    }

    if (std.mem.endsWith(u8, token, "*")) {
        const prefix = token[0 .. token.len - 1];
        if (std.mem.endsWith(u8, prefix, "_")) {
            return pancakeSymbolFamilyExists(prefix, symbols);
        }
        var it = symbols.keyIterator();
        while (it.next()) |key| {
            if (std.mem.startsWith(u8, key.*, prefix)) return true;
        }
        return false;
    }

    if (std.mem.endsWith(u8, token, "_")) {
        return pancakeSymbolFamilyExists(token, symbols);
    }

    if (symbols.contains(token)) return true;

    return false;
}

fn extractPancakeCiteToken(span: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, span, "pancake_")) return null;
    if (std.mem.indexOfAny(u8, span, "<>") != null) return null;
    if (std.mem.endsWith(u8, span, ".h") or std.mem.endsWith(u8, span, ".wasm")) return null;
    var end: usize = "pancake_".len;
    while (end < span.len and isPancakeIdentChar(span[end])) end += 1;
    if (end < span.len and span[end] == '*') end += 1;
    if (end == "pancake_".len) return null;
    return span[0..end];
}

fn scanDocCAbiCitesInContents(
    gpa: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    symbols: *const std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
) !void {
    var rest = contents;
    while (std.mem.indexOf(u8, rest, "`pancake_")) |start| {
        const after_tick = rest[start + 1 ..];
        const close = std.mem.indexOfScalar(u8, after_tick, '`') orelse break;
        const span = after_tick[0..close];
        rest = after_tick[close + 1 ..];
        const token = extractPancakeCiteToken(span) orelse continue;
        if (!docCAbiTokenValid(token, symbols)) {
            try appendViolation(gpa, violations, "{s}: backtick cite `{s}` has no matching symbol in include/*.h (doc C-ABI cite check)", .{ path, token });
        }
    }
}

/// Every `pancake_[a-z0-9_]+` token inside backticks in docs and site content
/// must exist in the generated headers (or name a wildcard family that does).
fn checkDocCAbiCites(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var symbols = std.StringHashMap(void).init(arena);
    for (doc_c_abi_header_paths) |header_path| {
        const contents = root.readFileAlloc(io, header_path, arena, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for doc C-ABI cite check with {s}", .{ header_path, @errorName(err) });
            continue;
        };
        try collectPancakeSymbols(contents, &symbols);
    }

    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for doc C-ABI cite check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_walker = try docs.walk(gpa);
    defer docs_walker.deinit();
    while (try docs_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        const path = try std.fmt.allocPrint(arena, "docs/{s}", .{entry.path});
        const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for doc C-ABI cite check with {s}", .{ path, @errorName(err) });
            continue;
        };
        try scanDocCAbiCitesInContents(gpa, path, contents, &symbols, violations);
    }

    var site = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for doc C-ABI cite check with {s}", .{@errorName(err)});
        return;
    };
    defer site.close(io);
    var site_walker = try site.walk(gpa);
    defer site_walker.deinit();
    while (try site_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;
        const path = try std.fmt.allocPrint(arena, "site/content/{s}", .{entry.path});
        const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for doc C-ABI cite check with {s}", .{ path, @errorName(err) });
            continue;
        };
        try scanDocCAbiCitesInContents(gpa, path, contents, &symbols, violations);
    }
}

fn appendViolation(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}

test "resolveMarkdownTarget normalizes local relative links" {
    const allocator = std.testing.allocator;

    const resolved = (try resolveMarkdownTarget(allocator, ".agents/rules/cli.md", "../../.devcontainer/pins.sh#versions")).?;
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(".devcontainer/pins.sh", resolved);

    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "https://example.invalid/docs") == null);
    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "#first-principles") == null);
}

test "mentionsVerbInCode matches bare, call, and receiver-method phrasings" {
    // Bare token, as the README and vision write it.
    try std.testing.expect(mentionsVerbInCode("the `connect` verb dials", "connect"));
    // As a call with arguments, as bindings/README's table writes it.
    try std.testing.expect(mentionsVerbInCode("| `listen(host, port)` | accept |", "listen"));
    // As a method on a receiver, the other bindings/README phrasing.
    try std.testing.expect(mentionsVerbInCode("call `conn.tell(ref, verb, args)`", "tell"));
    try std.testing.expect(mentionsVerbInCode("`conn.serve()` runs the loop", "serve"));
    // Absent: prose mention outside code is not enough, and a different verb
    // inside code does not satisfy the missing one.
    try std.testing.expect(!mentionsVerbInCode("you can tell it to stop", "tell"));
    try std.testing.expect(!mentionsVerbInCode("only `conn.close()` here", "serve"));
}

test "collectCommandRegions yields only fenced and inline-code text" {
    const gpa = std.testing.allocator;
    var regions: std.ArrayList([]const u8) = .empty;
    defer regions.deinit(gpa);

    const md =
        "Prose naming the zig build system must be ignored.\n" ++
        "Run `zig build check` and `bash setup.sh` inline.\n" ++
        "```sh\n" ++
        "zig build meta-check\n" ++
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
    try std.testing.expect(std.mem.indexOf(u8, seen, "zig build meta-check") != null);
    // Prose is not, so its trailing tokens can never be read as a step.
    try std.testing.expect(std.mem.indexOf(u8, seen, "system") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "nonsense") == null);
}

test "collectLivingStateRegistry reads bullet spans only, prose spans never" {
    const gpa = std.testing.allocator;
    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();

    const rule =
        "## Living-State Surfaces\n\n" ++
        "- `README.md`\n" ++
        "- `.cursor/README.md`, `.cursor/*.json`\n" ++
        "- living-state when they are a first-read contract;\n\n" ++
        "`zig build meta-check` holds this registry honest.\n\n" ++
        "## Discipline\n\n" ++
        "- `not-in-the-registry.md`\n";
    _ = (try collectLivingStateRegistry(rule, &registry)).?;

    // Bullet spans inside the section are the registry.
    try std.testing.expect(registry.contains("README.md"));
    try std.testing.expect(registry.contains(".cursor/README.md"));
    try std.testing.expect(registry.contains(".cursor/*.json"));
    // A span in prose is a sentence, not a registration; a span in another
    // section is out of scope.
    try std.testing.expect(!registry.contains("zig build meta-check"));
    try std.testing.expect(!registry.contains("not-in-the-registry.md"));

    // A rule with no registry section reports null rather than an empty set.
    var empty = std.StringHashMap(void).init(gpa);
    defer empty.deinit();
    try std.testing.expect((try collectLivingStateRegistry("# no section here\n", &empty)) == null);
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

test "danglingReferenceColumn flags rustdoc-style references, never resolvable links or literal brackets" {
    // A bracketed code span with nothing after it resolves nowhere.
    try std.testing.expectEqual(@as(?usize, 4), danglingReferenceColumn("see [`Peer.step`] for the drain"));
    try std.testing.expectEqual(@as(?usize, 0), danglingReferenceColumn("[`core`] holds the shared types"));
    // A real inline link, a reference definition, and a reference label all resolve.
    try std.testing.expect(danglingReferenceColumn("see [`Peer`](../engine/mod.zig)") == null);
    try std.testing.expect(danglingReferenceColumn("[`Peer`]: ../engine/mod.zig") == null);
    try std.testing.expect(danglingReferenceColumn("see [`Peer`][engine-peer]") == null);
    // A bracket character inside a code span is a literal, not a reference.
    try std.testing.expect(danglingReferenceColumn("a byte equal to `<`, `>`, `[`, `]`, or a digit") == null);
    // An unclosed or backtick-laden candidate is not a reference shape.
    try std.testing.expect(danglingReferenceColumn("an open [`span with no close") == null);
}

test "mermaidBlockKind recognizes supported diagram heads" {
    try std.testing.expectEqual(MermaidKind.flowchart, (try mermaidBlockKind("flowchart TD\n    A --> B\n")).?);
    try std.testing.expectEqual(MermaidKind.sequence, (try mermaidBlockKind("\nsequenceDiagram\n    A->>B: hello\n")).?);
    try std.testing.expectEqual(MermaidKind.state, (try mermaidBlockKind("stateDiagram-v2\n    [*] --> Open\n")).?);
    try std.testing.expect(try mermaidBlockKind("notMermaid\n    A\n") == null);
}
