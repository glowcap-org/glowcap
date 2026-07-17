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
    try checkAgentPersonas(io, gpa, root, &violations);
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
    try checkPeerEventSendParity(io, gpa, root, &violations);
    try checkBindingConstants(io, gpa, root, &violations);
    try checkBindingHostActionDrains(io, gpa, root, &violations);
    try checkBindingHostActionSpine(io, gpa, root, &violations);
    try checkBindingEmbedderPump(io, gpa, root, &violations);
    try checkBindingEmbedderTrampoline(io, gpa, root, &violations);
    try checkBindingPromiseSpine(io, gpa, root, &violations);
    try checkBindingRustConnSpine(io, gpa, root, &violations);
    try checkBindingGcSpine(io, gpa, root, &violations);
    try checkBindingDialSpine(io, gpa, root, &violations);
    try checkBindingListenSpine(io, gpa, root, &violations);
    try checkBindingEmbedderSpineDocs(io, gpa, root, &violations);
    try checkBindingMagicErrorCodes(io, gpa, root, &violations);
    try checkIrohSidecarAbi(io, gpa, root, &violations);
    try checkIrohSidecarPins(io, gpa, root, &violations);
    try checkApplicationSurfaceVerbs(io, gpa, root, &violations);
    try checkPancakeCliSkillAuthority(io, gpa, root, &violations);
    try checkPancakeMcpSkillAuthority(io, gpa, root, &violations);
    try checkCaptpAgentDogfoodRouting(io, gpa, root, &violations);
    try checkExampleIndex(io, gpa, root, &violations);
    try checkExampleWiring(io, gpa, root, &violations);
    try checkPlanningDocRoles(io, gpa, root, &violations);
    try checkLivingStateRegistry(io, gpa, root, &violations);
    try checkRoadmapHonesty(io, gpa, root, &violations);
    try checkTransportVocabulary(io, gpa, root, &violations);
    try checkDesignatorSchemeSync(io, gpa, root, &violations);
    try checkCAbiResolve(io, gpa, root, &violations);
    try checkIrohLoopConvergence(io, gpa, root, &violations);
    try checkIrohBindingAggregatesComplete(io, gpa, root, &violations);
    try checkCaptpIoSpine(io, gpa, root, &violations);
    try checkRuleFrontmatter(io, gpa, root, &violations);
    try checkLayerOwnership(io, gpa, root, &violations);
    try checkTestPlacement(io, gpa, root, &violations);
    try checkTestSuiteWiring(io, gpa, root, &violations);
    try checkOracleCorpusRegistry(io, gpa, root, &violations);
    try checkProtocolCheatsheet(io, gpa, root, &violations);
    try checkGeneratedStateIgnores(io, gpa, root, &violations, b.build_root.path orelse ".");
    try checkPrereleaseLanguage(io, gpa, root, &violations);
    try checkHumanDocVoice(io, gpa, root, &violations);
    try checkSiteSvgAscii(io, gpa, root, &violations);
    try checkRemoveDiscards(io, gpa, root, &violations);
    try checkArchiveTables(io, gpa, root, &violations);
    try checkDocCAbiCites(io, gpa, root, &violations);
    try checkDeletedNodeCProjection(io, gpa, root, &violations);
    try checkCaptpVocabulary(io, gpa, root, &violations);
    try checkHostPumpImportGate(io, gpa, root, &violations);
    try checkCAbiServedSurface(io, gpa, root, &violations);
    try checkNoAdrInRuntimeStrings(io, gpa, root, &violations);
    try checkCliCaptpDeadlines(io, gpa, root, &violations);
    try checkCliListenStopWake(io, gpa, root, &violations);
    try checkCaptpLabUxHonesty(io, gpa, root, &violations);
    try checkUnwiredHostPluginApis(io, gpa, root, &violations);
    try checkHostActionArmLockstep(io, gpa, root, &violations);

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
    try expectPancakeMcpServer(io, gpa, root, violations, ".cursor/mcp.json", .cursor);
    try expectPancakeMcpServer(io, gpa, root, violations, ".mcp.json", .claude);
    try expectFileContains(io, gpa, root, violations, "pancake", &.{
        "zig-out/bin/pancake",
    });
    try expectFileContains(io, gpa, root, violations, "cli/operability/xdg.zig", &.{
        "mcp_local",
        ".local/pancake-mcp-state",
    });
    try expectFileContains(io, gpa, root, violations, "cli/mcp/mod.zig", &.{
        "ctx.json = .json",
        "newline-delimited",
        "writeStreamingAll(io, \"\\n\")",
    });
    try expectFileContains(io, gpa, root, violations, ".gitignore", &.{
        ".local/",
    });
    try expectFileContains(io, gpa, root, violations, "docs/examples/pancake-mcp.json", &.{
        "\"mcp\"",
        "--tools",
        "default",
        "PANCAKE_STATE",
    });
    try expectFileContains(io, gpa, root, violations, "docs/cli.md", &.{
        ".local/pancake-mcp-state",
        "no shim",
        "newline-delimited",
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

const PancakeMcpHost = enum { cursor, claude };

/// Project CapTP MCP must launch the repo-root `./pancake` shim (forwards to
/// zig-out/bin/pancake; PATH is not required).
fn expectPancakeMcpServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    host: PancakeMcpHost,
) !void {
    var parsed = try parseJsonFile(io, gpa, root, violations, path) orelse return;
    defer parsed.deinit();

    const servers = getField(parsed.value, "mcpServers") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers` object", .{path});
        return;
    };
    const pancake = getField(servers, "pancake") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.pancake` object — CapTP MCP must be wired", .{path});
        return;
    };
    const command = getField(pancake, "command") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.pancake.command`", .{path});
        return;
    };
    const expected_command: []const u8 = switch (host) {
        .cursor => "${workspaceFolder}/pancake",
        .claude => "./pancake",
    };
    if (!jsonStringEquals(command, expected_command)) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.pancake.command` must be `{s}`", .{ path, expected_command });
    }
    const args = getField(pancake, "args") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.pancake.args`", .{path});
        return;
    };
    if (!jsonStringArrayEquals(args, &.{ "mcp", "--tools", "default" })) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.pancake.args` must be `[\"mcp\", \"--tools\", \"default\"]`", .{path});
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

/// Project personas under `.agents/personas/` are anonymous lenses only: real
/// person names and person-channeling phrasing belong in user XDG
/// (`$XDG_CONFIG_HOME/agent-personas/`), never in committed scaffolding. The
/// smell-annihilation skill is gated the same way so default slug keys stay
/// filesystem names, not proper-name impersonation prompts.
fn checkAgentPersonas(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const banned = [_][]const u8{
        "Andrew Kelley",
        "Fabrice Bellard",
        "channel ",
    };

    try refuseBannedSubstrings(io, gpa, root, violations, ".agents/skills/smell-annihilation/SKILL.md", &banned);

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
                try appendViolation(gpa, violations, "{s}: contains banned `{s}` — named people and channeling language belong in user XDG personas, not committed project lenses", .{ rel, needle });
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
            try appendViolation(gpa, violations, "{s}: contains banned `{s}` — use persona slugs and user XDG files for named taste references", .{ path, needle });
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
        .reason = "`driver.Bridge` shipped under ADR-0076 (`zig build tcp-loop`, `zig build iroh-loop`)",
    },
    .{
        .phrase = "the listener has no durable designator a partner can re-dial",
        .reason = "`net.tcp_keyed` / ADR-0075 already ships the keyed designator; open work is binding/C ABI surfaces",
    },
    .{
        .phrase = "iroh `LoopHost` → `net.Loop` + `LoopBridge` convergence",
        .reason = "`iroh.LoopHost` is deleted; scale is `completion.Loop(iroh.Backend)` + `driver.Bridge` (ADR-0076), gated by `iroh-loop`",
    },
};

/// Apex for ADR-0076 iroh convergence: CapTP fan-out must not re-grow inside
/// the iroh resident. The resident supplies the netlayer + completion
/// `Backend` only; serving is `driver.Bridge` + Host. A reintroduced
/// `LoopHost` / `driver_core` / `actors` import fails the gate instead of
/// shipping a second diverging serve spine.
fn checkIrohLoopConvergence(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "src/net/transport/iroh.zig";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for iroh-loop-convergence check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const forbidden = [_]struct { needle: []const u8, reason: []const u8 }{
        .{ .needle = "LoopHost", .reason = "CapTP scale must stay on `driver.Bridge` + Host, not a resident-local serve loop" },
        .{ .needle = "@import(\"driver_core\")", .reason = "the iroh resident must not import the serve core; Bridge owns CapTP" },
        .{ .needle = "@import(\"actors\")", .reason = "the iroh resident must not mint vats; Bridge + Host own CapTP" },
    };
    for (forbidden) |entry| {
        if (std.mem.indexOf(u8, contents, entry.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, entry.needle, entry.reason });
        }
    }
    if (std.mem.indexOf(u8, contents, "pub const Backend") == null) {
        try appendViolation(gpa, violations, "{s}: missing `pub const Backend` — iroh scale must expose a completion Backend (ADR-0057/0076)", .{path});
    }
}

/// Find the `{ ... }` block opened by the `{`-terminated `marker`, matching
/// braces so a nested struct literal inside the block cannot close it early.
/// Returns the interior (excluding the outer braces), or `null` when the
/// marker is absent or its brace never closes.
fn extractBraceBlock(text: []const u8, marker: []const u8) ?[]const u8 {
    std.debug.assert(std.mem.endsWith(u8, marker, "{"));
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const open = start + marker.len - 1;
    var depth: usize = 1;
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// The iroh `BindingClientRow` tables (`iroh_loop_clients`,
/// `iroh_handoff_clients`, `iroh_reach_clients`) each feed a `bindings-iroh-*`
/// aggregate. A binding silently missing from one of these tables would still
/// build — the aggregate degrades to whichever rows remain — so the gap is
/// invisible to `zig build check` unless something demands every step name
/// explicitly. This holds the closed binding set (deno/python/rust/racket) the
/// sibling `iroh_redeem_clients` and `keyed_tcp_restart_clients` tables already
/// carry.
fn checkIrohBindingAggregatesComplete(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "build.zig";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for iroh-binding-aggregate check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const families = [_]struct {
        marker: []const u8,
        steps: []const []const u8,
    }{
        .{
            .marker = "iroh_loop_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-loop", "python-iroh-loop", "rust-iroh-loop", "racket-iroh-loop" },
        },
        .{
            .marker = "iroh_handoff_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-handoff", "python-iroh-handoff", "rust-iroh-handoff", "racket-iroh-handoff" },
        },
        .{
            .marker = "iroh_reach_clients = [_]BindingClientRow{",
            .steps = &.{ "deno-iroh-reachability", "python-iroh-reachability", "rust-iroh-reachability", "racket-iroh-reachability" },
        },
    };

    for (families) |family| {
        const block = extractBraceBlock(contents, family.marker) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — cannot find the iroh binding-client row table", .{ path, family.marker });
            continue;
        };
        for (family.steps) |step| {
            var buf: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&buf, "\"{s}\"", .{step}) catch continue;
            if (std.mem.indexOf(u8, block, needle) == null) {
                try appendViolation(gpa, violations, "{s}: `{s}` is missing a `{s}` row — every iroh binding aggregate must carry deno, python, rust, and racket", .{ path, family.marker, step });
            }
        }
    }
}

/// Apex for one CapTP I/O spine: forbid reintroducing `BlockingHost`, the
/// `net.Loop` TCP convenience alias, dual `dialTcp`/`dialIroh` Loop APIs,
/// shared `ConnectTarget`, soft `@hasDecl(Backend` dial/shutdown forks,
/// Bridge-owned dial grammar, socket-shaped Loop dial choreography, or OCapN
/// resolve on bare platform Backends.
fn checkCaptpIoSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const checks = [_]struct { path: []const u8, needle: []const u8, reason: []const u8 }{
        .{
            .path = "src/driver/host.zig",
            .needle = "",
            .reason = "`BlockingHost` is deleted; Zig multi-session CapTP is Host + Bridge + completion.Loop",
        },
        .{
            .path = "src/driver/mod.zig",
            .needle = "BlockingHost",
            .reason = "do not re-export `BlockingHost`; use `driver.Bridge` + `completion.Loop`",
        },
        .{
            .path = "src/net/mod.zig",
            .needle = "pub const Loop =",
            .reason = "use `net.TcpLoop` or `completion.Loop(Backend)`, not a second concept named `Loop`",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "pub fn dialTcp",
            .reason = "Bridge-facing dial is `dialLocator`; Backend owns `startDial`",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "pub fn dialIroh",
            .reason = "Bridge-facing dial is `dialLocator`; Backend owns `startDial`",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "pub const ConnectTarget = union",
            .reason = "no shared ConnectTarget union; each Backend declares its own associated type",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "@hasDecl(Backend, \"",
            .reason = "total Backend contract via `validateBackend`; no soft dial/shutdown optionality at call sites",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "openDialFd",
            .reason = "socket-shaped Loop dial choreography is gone; Backend.startDial owns dial start",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "abandonDialFd",
            .reason = "Backend.startDial owns cleanup on failed start; no Loop abandonDialFd",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "submitIrohConnect",
            .reason = "optional `@hasDecl(submitIrohConnect)` is gone; Backends implement `startDial`",
        },
        .{
            .path = "src/net/completion/loop.zig",
            .needle = "pub fn dial(self",
            .reason = "only public dial verb is `dialLocator`; `fn dial` stays private (no ConnectTarget at the Loop boundary)",
        },
        .{
            .path = "src/net/transport/tcp.zig",
            .needle = "pub fn resolveDialAddress",
            .reason = "TCP address grammar lives only in `tcp.DialResolver.resolve`",
        },
        .{
            .path = "src/net/transport/iroh.zig",
            .needle = "submitIrohConnect",
            .reason = "iroh dials through `Locator.resolve` + `startDial`, not a parallel connect verb",
        },
        .{
            .path = "src/net/completion/uring.zig",
            .needle = "resolveConnectTarget",
            .reason = "platform Backend has no OCapN resolve; TCP resolve lives on `tcp.DialResolver`",
        },
        .{
            .path = "src/net/completion/kqueue.zig",
            .needle = "resolveConnectTarget",
            .reason = "platform Backend has no OCapN resolve; TCP resolve lives on `tcp.DialResolver`",
        },
        .{
            .path = "src/net/mod.zig",
            .needle = "tcp_backend",
            .reason = "`TcpLoop` is `Loop(platform, tcp.DialResolver)`; no forwarding `tcp_backend` wrapper",
        },
        .{
            .path = "src/net/transport/iroh.zig",
            .needle = "@import(\"../stream_shim.zig\")",
            .reason = "iroh is its own module root under transport/; reach stream_shim via net.stream_shim (ADR-0040)",
        },
        .{
            .path = "src/net/mod.zig",
            .needle = "@import(\"completion/tcp_keepalive.zig\")",
            .reason = "public Keepalive is net.socket / net.Keepalive — no second door into completion/",
        },
        .{
            .path = "src/net/transport/tcp.zig",
            .needle = "@import(\"../completion/",
            .reason = "tcp netlayer reaches socket ops through net.socket, never completion/ internals",
        },
        .{
            .path = "src/net/transport/tcp_keyed.zig",
            .needle = "@import(\"../completion/",
            .reason = "keyed-tcp netlayer reaches socket ops through net.socket, never completion/ internals",
        },
        .{
            .path = "src/net/transport/iroh.zig",
            .needle = "@import(\"../completion/",
            .reason = "iroh netlayer reaches socket ops through net.socket, never completion/ internals",
        },
        .{
            .path = "src/net/completion/tcp_backend.zig",
            .needle = "",
            .reason = "tcp_backend forwarding wrapper is deleted; resolve is `tcp.DialResolver`, I/O is the platform Backend",
        },
        .{
            .path = "src/driver/core/mod.zig",
            .needle = "pub const gc =",
            .reason = "export emitStatelessAfter only; gc.zig stays Served-private",
        },
        .{
            .path = "src/driver/core/host.zig",
            .needle = "pub const HostAction",
            .reason = "HostAction lives on driver.core barrel, not Host type home",
        },
        .{
            .path = "src/driver/core/host.zig",
            .needle = "pub const CrossedHellos",
            .reason = "CrossedHellos lives on driver.core barrel, not Host type home",
        },
        .{
            .path = "src/ocapn/codec/dispatch.zig",
            .needle = "pub const registry",
            .reason = "codec.registry is the authority; dispatch keeps it private",
        },
        .{
            .path = "src/ocapn/codec/dispatch.zig",
            .needle = "pub const framing",
            .reason = "export Prefix only; framing stays private to dispatch",
        },
        .{
            .path = "src/driver/mod.zig",
            .needle = "LoopBridge",
            .reason = "call sites use `Bridge(net.TcpLoop)`; no `LoopBridge` alias",
        },
        .{
            .path = "src/driver/loop_bridge.zig",
            .needle = "",
            .reason = "`loop_bridge.zig` is renamed; the file is `src/driver/bridge.zig` matching `driver.Bridge`",
        },
        .{
            .path = "src/driver/bridge.zig",
            .needle = "resolveDialAddress",
            .reason = "locator→connect belongs on `Locator.resolve` / `Loop.dialLocator`",
        },
        .{
            .path = "src/driver/bridge.zig",
            .needle = "Backend resolves",
            .reason = "Locator resolves; Backend startDial connects — stale comment re-teaches the deleted design",
        },
        .{
            .path = "src/driver/bridge.zig",
            .needle = "net.tcp",
            .reason = "Bridge speaks OCapN locator parts only; TCP grammar stays in the netlayer Locator",
        },
        .{
            .path = "src/driver/bridge.zig",
            .needle = "ConnectTarget",
            .reason = "Bridge must not name Backend connect targets; use `Loop.dialLocator`",
        },
        .{
            .path = "src/driver/bridge.zig",
            .needle = "IpAddress",
            .reason = "Bridge must not speak net addresses; use OCapN locator parts",
        },
        .{
            .path = "src/driver/bridge.zig",
            .needle = "transport, \"iroh\"",
            .reason = "no Bridge dial-dispatch on transport strings; Locator.resolve owns that",
        },
        .{
            .path = "src/net/transport/iroh.zig",
            .needle = "Backend.Locator",
            .reason = "Locator is module-level `iroh.DialResolver`, not nested on Backend",
        },
    };
    for (checks) |entry| {
        if (entry.needle.len == 0) {
            root.access(io, entry.path, .{}) catch continue;
            try appendViolation(gpa, violations, "{s}: file must not exist — {s}", .{ entry.path, entry.reason });
            continue;
        }
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for captp-io-spine check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ entry.path, entry.needle, entry.reason });
        }
    }

    root.access(io, "src/driver/bridge.zig", .{}) catch {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: file must exist — `driver.Bridge` lives here (not `loop_bridge.zig`)", .{});
    };

    // Every completion Backend must declare the total dial contract.
    // Transport-bound Locators own OCapN resolve; platform Backends are connect-only.
    const backend_paths = [_][]const u8{
        "src/net/transport/iroh.zig",
    };
    const required_dial = [_][]const u8{
        "pub const ConnectTarget",
        "startDial",
        "shutdownFd",
    };
    const platform_paths = [_][]const u8{
        "src/net/completion/uring.zig",
        "src/net/completion/kqueue.zig",
    };
    const required_platform_dial = [_][]const u8{
        "pub const ConnectTarget",
        "startDial",
        "shutdownFd",
    };
    const locator_paths = [_][]const u8{
        "src/net/transport/tcp.zig",
        "src/net/transport/iroh.zig",
    };
    const required_locator = [_][]const u8{
        "pub const DialResolver",
        "pub fn resolve(",
    };
    for (platform_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for platform dial-contract check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (required_platform_dial) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — platform Backend dial contract", .{ path, needle });
            }
        }
    }
    for (backend_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for Backend dial-contract check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (required_dial) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — Backend total dial contract", .{ path, needle });
            }
        }
    }
    for (locator_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for Locator contract check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (required_locator) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — netlayer DialResolver contract", .{ path, needle });
            }
        }
    }

    // kqueue Pending is tagged unions; flaggy `read_is_recv` / `connecting` are deleted.
    // Both readiness backends share `ScratchPool` (no hand-copied pool logic).
    {
        const kq_path = "src/net/completion/kqueue.zig";
        const kq = root.readFileAlloc(io, kq_path, gpa, .limited(2 << 20)) catch |err| blk: {
            try appendViolation(gpa, violations, "{s}: failed to read for Pending/ScratchPool apex check with {s}", .{ kq_path, @errorName(err) });
            break :blk null;
        };
        defer if (kq) |bytes| gpa.free(bytes);
        if (kq) |kq_bytes| {
            for ([_][]const u8{ "read_is_recv", "connecting" }) |needle| {
                if (std.mem.indexOf(u8, kq_bytes, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — kqueue Pending is tagged unions (`read`/`write`), not flaggy fields", .{ kq_path, needle });
                }
            }
        }
        const pool_paths = [_][]const u8{
            "src/net/completion/kqueue.zig",
            "src/net/transport/iroh.zig",
        };
        for (pool_paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for ScratchPool apex check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            const has_pool = std.mem.indexOf(u8, contents, "scratch_pool") != null or
                std.mem.indexOf(u8, contents, "ScratchPool") != null;
            if (!has_pool) {
                try appendViolation(gpa, violations, "{s}: missing ScratchPool — readiness backends share `src/net/completion/scratch_pool.zig`", .{path});
            }
        }
    }

    // Platform TCP socket policy (bind/listen/reuseaddr, openSocket, dial sockaddr)
    // lives in `socket_tcp.zig`. Both backends must call it; neither reimplements.
    // A full readiness mixin (`readiness_backend.zig`) is a rejected shape.
    {
        root.access(io, "src/net/completion/socket_tcp.zig", .{}) catch {
            try appendViolation(gpa, violations, "src/net/completion/socket_tcp.zig: file must exist — shared kqueue/uring TCP socket helpers", .{});
        };
        if (root.access(io, "src/net/completion/readiness_backend.zig", .{})) |_| {
            try appendViolation(gpa, violations, "src/net/completion/readiness_backend.zig: file must not exist — rejected readiness mixin; share ScratchPool + socket_tcp only", .{});
        } else |_| {}
        const sock_paths = [_][]const u8{
            "src/net/completion/kqueue.zig",
            "src/net/completion/uring.zig",
        };
        for (sock_paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for socket_tcp share check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "socket_tcp") == null) {
                try appendViolation(gpa, violations, "{s}: missing `socket_tcp` — platform backends share `src/net/completion/socket_tcp.zig`", .{path});
            }
            for ([_][]const u8{ "SO.REUSEADDR", "SO_REUSEADDR", "0x7f00_0001" }) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — loopback bind/listen/reuseaddr lives in socket_tcp.zig", .{ path, needle });
                }
            }
        }
    }

    // `tcp.connectAddress` is post-admission I/O only. Production `src/` dials
    // must go through `Locator.resolve` (or `tcp.connect` / netlayer dial) first;
    // only the tcp transport modules may call connectAddress.
    {
        var src_dir = try root.openDir(io, "src", .{ .iterate = true });
        defer src_dir.close(io);
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const rel = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
            defer gpa.free(rel);
            if (std.mem.eql(u8, rel, "src/net/transport/tcp.zig")) continue;
            if (std.mem.eql(u8, rel, "src/net/transport/tcp_keyed.zig")) continue;
            const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for connectAddress ban with {s}", .{ rel, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "connectAddress") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `connectAddress` — dial through `Locator.resolve` / `tcp.connect` / netlayer dial; only tcp.zig and tcp_keyed.zig may call the post-admission connect", .{rel});
            }
        }
    }

    // Ghost test/path vocabulary that named the deleted blocking Host tier.
    const ghost_docs = [_][]const u8{
        "docs/shipped.md",
        "docs/boundaries.md",
        "docs/architecture.md",
        "docs/roadmap.md",
        ".agents/rules/architecture.md",
        ".agents/rules/memory.md",
        ".agents/rules/cli.md",
    };
    const ghosts = [_]struct { needle: []const u8, reason: []const u8 }{
        .{
            .needle = "host_three_party_test",
            .reason = "byte-fed three-party is `test/driver/core_host_test.zig`; loop-fed is `test/driver/bridge_test.zig`",
        },
        .{
            .needle = "loop_bridge.zig",
            .reason = "the Bridge file is `src/driver/bridge.zig`",
        },
        .{
            .needle = "loop_bridge_test.zig",
            .reason = "the Bridge test is `test/driver/bridge_test.zig`",
        },
        .{
            .needle = "blocking tier",
            .reason = "`BlockingHost` is deleted; crossed hellos lives in `driver_core.Host`, ridden by `BlockingSession` / `driver.Bridge`",
        },
        .{
            .needle = "three real residents",
            .reason = "four netlayer residents: `tcp`, `keyed-tcp`, `inproc`, and iroh",
        },
    };
    for (ghost_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch continue;
        defer gpa.free(contents);
        for (ghosts) |ghost| {
            if (std.mem.indexOf(u8, contents, ghost.needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, ghost.needle, ghost.reason });
            }
        }
    }

    // Dead Host.pumped must not return (Bridge uses serveEvent).
    {
        const path = "src/driver/core/host.zig";
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for pumped ban with {s}", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "pub fn pumped") != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `pub fn pumped` — use `serveEvent` / `feed` / `feedBytes` only", .{path});
        }
    }

    // Dead BlockingSession.openKeyedSession: connectTcp/connectVia open the
    // session; a tcp-hardcoded parallel hello must not return.
    {
        const path = "src/driver/blocking_session.zig";
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for openKeyedSession ban with {s}", .{ path, @errorName(err) });
            return;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "fn openKeyedSession") != null) {
            try appendViolation(gpa, violations, "{s}: forbidden `openKeyedSession` — session open is `connectVia` / `connectTcp` / `startKeyedSession`", .{path});
        }
        // acceptTcp must stay a thin tcp-named wrapper over acceptVia.
        if (std.mem.indexOf(u8, contents, "pub fn acceptTcp") != null and
            std.mem.indexOf(u8, contents, "acceptVia(") == null)
        {
            try appendViolation(gpa, violations, "{s}: `acceptTcp` must call `acceptVia` — no parallel accept hello path", .{path});
        }
        // connectTcp must stay a thin tcp-named wrapper over connectVia.
        if (std.mem.indexOf(u8, contents, "pub fn connectTcp") != null and
            std.mem.indexOf(u8, contents, "connectVia(") == null)
        {
            try appendViolation(gpa, violations, "{s}: `connectTcp` must call `connectVia` — no parallel dial hello path", .{path});
        }
    }

    // Hint name literal lives only in model.transport; production code aliases.
    {
        var src_dir = try root.openDir(io, "src", .{ .iterate = true });
        defer src_dir.close(io);
        var walker = try src_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const rel = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
            defer gpa.free(rel);
            if (std.mem.eql(u8, rel, "src/ocapn/model/transport.zig")) continue;
            const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for hint-literal ban with {s}", .{ rel, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            // Assignment / compare sites; comments may still name the wire bytes.
            if (std.mem.indexOf(u8, contents, ".name = \"direct-addresses\"") != null or
                std.mem.indexOf(u8, contents, "eql(u8, entry.name, \"direct-addresses\")") != null or
                std.mem.indexOf(u8, contents, "eql(u8, entry.name,\"direct-addresses\")") != null)
            {
                try appendViolation(gpa, violations, "{s}: forbidden `direct-addresses` literal — use `model.transport.hint_direct_addresses` (or vocab/netlayer alias)", .{rel});
            }
        }
    }

    // Binding dial executors resolve `host:port` only in the core: the TS
    // binding delegates the whole dial to the `pancake_host_plan_dial` resolver,
    // the others still split through the `pancake_designator_host_port` grammar
    // wrapper. Either way a local regexp that re-teaches the designator grammar
    // on the dial path is forbidden.
    const dial_host_port = [_]struct {
        path: []const u8,
        required: []const u8,
        banned: []const []const u8,
    }{
        .{
            // The Python dial delegates the whole resolution to the core resolver.
            .path = "bindings/python/pancake/_dial.py",
            .required = "pancake_host_plan_dial",
            .banned = &.{ "re.match(", "rsplit(\":\"", ".rsplit(\":\"" },
        },
        .{
            // The Rust dial delegates the whole resolution to the core resolver.
            .path = "bindings/rust/src/dial.rs",
            .required = "pancake_host_plan_dial",
            .banned = &.{ "rsplit_once(':')", "split_once(':')" },
        },
        .{
            // The TS dial delegates the whole resolution (grammar + hint +
            // posture) to the core, so it requires the resolver, not the split.
            .path = "bindings/ts/stack/dial.ts",
            .required = "pancake_host_plan_dial",
            .banned = &.{ "lastIndexOf(\":\")", "match(/^(.+):([0-9]+)$/)" },
        },
        .{
            // The Racket dial delegates the whole resolution to the core resolver.
            .path = "bindings/racket/private/dial.rkt",
            .required = "pancake_host_plan_dial",
            .banned = &.{"#rx\"^(.+):([0-9]+)$\""},
        },
    };
    for (dial_host_port) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial host:port check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — dials must resolve host:port in the core, not a local splitter", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use `{s}` / pancake_designator_host_port, not a local host:port splitter", .{ entry.path, needle, entry.required });
            }
        }
    }

    // Rooms demos must split host:port through the core grammar, not a local
    // last-colon heuristic (IPv6-unsafe).
    const rooms_host_port = [_]struct {
        path: []const u8,
        required: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "examples/apps/rooms/deno/lib/locator.ts",
            .required = "designatorHostPort",
            .banned = &.{ "lastIndexOf(\":\")", "`127.0.0.1:${token}`", "`127.0.0.1:${port}`" },
        },
        .{
            .path = "examples/apps/rooms/dm_demo.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
        },
        .{
            .path = "examples/apps/rooms/deno/web.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
        },
        .{
            .path = "examples/apps/rooms/demo.ts",
            .required = "loopbackTcpDesignator",
            .banned = &.{"`127.0.0.1:${"},
        },
        .{
            .path = "examples/apps/rooms/deno/server.ts",
            .required = "designatorHostPort",
            .banned = &.{"lastIndexOf(\":\")"},
        },
        .{
            .path = "examples/apps/rooms/python/room_client.py",
            .required = "designator_host_port",
            .banned = &.{"rfind(\":\")"},
        },
        .{
            .path = "examples/apps/rooms/rust/room.rs",
            .required = "designator_host_port",
            .banned = &.{"rsplit_once(':')"},
        },
        .{
            .path = "examples/apps/rooms/racket/room-client.rkt",
            .required = "designator-host-port",
            .banned = &.{"(char=? (string-ref locator i) #\\:)"},
        },
    };
    for (rooms_host_port) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for rooms host:port check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — rooms dials must split host:port through the core grammar", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use core host:port grammar / loopbackTcpDesignator", .{ entry.path, needle });
            }
        }
    }
    // Zig demo clients mint tcp designators through tcp.locator, not bufPrint.
    const zig_demo_locator = [_]struct { path: []const u8, required: []const u8, banned: []const []const u8 }{
        .{
            .path = "examples/apps/tasks/zig/client.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "examples/apps/tools/zig/agent.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "examples/zig/02_introduce_and_redeem.zig",
            .required = "tcp.locator(",
            .banned = &.{ "lastIndexOfScalar(u8, bound, ':')", "127.0.0.1:{d}" },
        },
        .{
            .path = "test/driver/bridge_test.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "test/driver/blocking_session_test.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{f}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "test/driver/pluggability_test.zig",
            .required = "tcp.designatorOnListener(",
            .banned = &.{ "bufPrint(out, \"{f}\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "interop/tcp_loop/driver.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "interop/goblins_interop/handoff_driver.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "interop/goblins_interop/driver.zig",
            .required = "tcp.locator(",
            .banned = &.{ "host ++ \":1\"", "127.0.0.1:{d}" },
        },
        .{
            .path = "bench/peer_scaling_bench.zig",
            .required = "tcp.locator(",
            .banned = &.{"127.0.0.1:{d}"},
        },
        .{
            .path = "conformance/ocapn-conformance/pancake_peer.zig",
            .required = "tcp.locator(",
            .banned = &.{ "bufPrint(&designator_buf, \"{s}:{d}\"", "allocPrint(allocator, \"{s}:{s}\"", "indexOfScalar(u8, exporter_location, ':')" },
        },
    };
    for (zig_demo_locator) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for zig demo locator check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, entry.required) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — Zig demos mint tcp locators through tcp.locator", .{ entry.path, entry.required });
        }
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use tcp.parseHostPort + tcp.locator", .{ entry.path, needle });
            }
        }
    }

    // Byte-fed Host dials through openDialedLocator only; the URI wrapper is gone.
    const open_dialed_ban = [_]struct { path: []const u8, banned: []const []const u8 }{
        .{ .path = "src/driver/core/host.zig", .banned = &.{"pub fn openDialed(self: *Host, locator_uri"} },
        .{ .path = "test/driver/core_host_test.zig", .banned = &.{".openDialed("} },
        .{ .path = "test/driver/core_host_budget_test.zig", .banned = &.{".openDialed("} },
        .{ .path = "test/driver/core_host_adopt_test.zig", .banned = &.{".openDialed("} },
        .{ .path = "examples/apps/rooms/zig/client.zig", .banned = &.{"fn dialTcp("} },
    };
    for (open_dialed_ban) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for openDialed ban with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use openDialedLocator / parts-in-hand dial", .{ entry.path, needle });
            }
        }
    }

    // Host:port dial helpers must not mint a peer URI only to re-parse it.
    // The one C ABI dial mint is open_dialed_locator (parts in hand); URI
    // holders parse first. Ban the deleted URI-string entry and round-trips.
    const dial_uri_mint = [_]struct {
        path: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/python/pancake/_session.py",
            .banned = &.{
                "establish_dialed(node, tcp_locator",
                "establish_dialed(cls, tcp_locator",
                "await cls.establish_dialed(node, tcp_locator",
                "def _mint_dialed(",
                "def _open_dialed(",
                "pancake_host_session_open_dialed(",
            },
        },
        .{
            .path = "bindings/python/zig_smoke.py",
            .banned = &.{
                "_mint_dialed(Node(), tcp_locator",
                "._mint_dialed_locator(",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/python/pancake/_session.py",
            .banned = &.{
                "async def connect(cls, host",
                "Connection.connect(",
            },
        },
        .{
            .path = "bindings/rust/src/session.rs",
            .banned = &.{
                "establish_dialed(node.shared(), &tcp_locator",
                "establish_dialed(node.shared(), &locator",
                "let locator = tcp_locator(",
                "designator_host_port(&loc.designator)",
                "pub async fn connect_with_node<",
                "Connection::connect(addr)",
            },
        },
        .{
            .path = "bindings/ts/stack/session.ts",
            .banned = &.{
                "establishDialed(node, tcpLocator",
                "static async connect(\n\t\thost: string",
                "Connection.connect(",
            },
        },
        .{
            .path = "examples/apps/rooms/dm_demo.ts",
            .banned = &.{"Connection.connect("},
        },
        .{
            .path = "examples/apps/rooms/deno/lib/locator.ts",
            .banned = &.{"Connection.connect("},
        },
        .{
            .path = "interop/goblins_interop/deno_gift_client.ts",
            .banned = &.{"Connection.connect("},
        },
        .{
            .path = "bindings/racket/private/session.rkt",
            .banned = &.{
                "(establish-dialed-connection m (tcp-locator",
                "(define (establish-dialed-connection ",
                "pancake_host_session_open_dialed ",
                "(define (dial-tcp ",
                "(define (connect-tcp ",
            },
        },
        .{
            .path = "bindings/racket/private/ffi-driver.rkt",
            .banned = &.{"(define-driver pancake_host_session_open_dialed\n"},
        },
        .{
            .path = "src/c_abi/driver/mod.zig",
            .banned = &.{"pub export fn pancake_host_session_open_dialed("},
        },
    };
    for (dial_uri_mint) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial URI-mint ban with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — host:port dials use establish_dialed_locator / open_dialed_locator, not tcp_locator→open_dialed", .{ entry.path, needle });
            }
        }
    }

    // Binding hint name literal lives only in each language's constant home
    // (mirrors model.transport.hint_direct_addresses).
    {
        const allowed = [_][]const u8{
            "bindings/python/pancake/_constants.py",
            "bindings/rust/src/abi_constants.rs",
            "bindings/ts/stack/locator.ts",
            "bindings/racket/private/constants.rkt",
        };
        const roots = [_][]const u8{
            "bindings/python",
            "bindings/rust/src",
            "bindings/ts",
            "bindings/racket",
            "examples/apps/rooms",
        };
        const exts = [_][]const u8{ ".py", ".rs", ".ts", ".rkt" };
        for (roots) |bind_root| {
            var dir = root.openDir(io, bind_root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                var ok_ext = false;
                for (exts) |ext| {
                    if (std.mem.endsWith(u8, entry.path, ext)) {
                        ok_ext = true;
                        break;
                    }
                }
                if (!ok_ext) continue;
                if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
                if (std.mem.indexOf(u8, entry.path, "/target/") != null) continue;
                const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bind_root, entry.path });
                defer gpa.free(rel);
                var allow = false;
                for (allowed) |a| {
                    if (std.mem.eql(u8, rel, a)) {
                        allow = true;
                        break;
                    }
                }
                if (allow) continue;
                const contents = root.readFileAlloc(io, rel, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for binding hint-literal ban with {s}", .{ rel, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                if (std.mem.indexOf(u8, contents, "\"direct-addresses\"") != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `direct-addresses` literal — use HINT_DIRECT_ADDRESSES / HINT-DIRECT-ADDRESSES (mirrors model.transport.hint_direct_addresses)", .{rel});
                }
                if (std.mem.indexOf(u8, contents, "\"keyed-tcp\"") != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `keyed-tcp` literal — use TRANSPORT_KEYED_TCP / TRANSPORT-KEYED-TCP (mirrors model.transport.keyed_tcp)", .{rel});
                }
            }
        }
        // Grammar helpers live in locator modules; connection modules import them.
        // Hint→host:port for dial is core `planDial` / `tcpConnectHostPort` (ADR-0078);
        // bindings must not keep a twin `host_port_from_direct_hint`.
        const locator_grammar_home = [_]struct {
            connection: []const u8,
            locator: []const u8,
            banned_in_connection: []const []const u8,
            required_in_locator: []const []const u8,
        }{
            .{
                .connection = "bindings/python/pancake/_session.py",
                .locator = "bindings/python/pancake/_locator.py",
                .banned_in_connection = &.{
                    "def _socket_addr_designator",
                    "def _host_port_from_direct_hint",
                    "def socket_addr_designator",
                    "def host_port_from_direct_hint",
                },
                .required_in_locator = &.{
                    "def socket_addr_designator",
                },
            },
            .{
                .connection = "bindings/ts/stack/session.ts",
                .locator = "bindings/ts/stack/locator.ts",
                .banned_in_connection = &.{
                    "function socketAddrDesignator",
                    "function hostPortFromDirectHint",
                },
                .required_in_locator = &.{
                    "export function socketAddrDesignator",
                },
            },
            .{
                .connection = "bindings/rust/src/session.rs",
                .locator = "bindings/rust/src/uri.rs",
                .banned_in_connection = &.{
                    "fn host_port_from_direct_hint",
                    "fn socket_addr_designator",
                },
                .required_in_locator = &.{
                    "pub fn socket_addr_designator",
                },
            },
            .{
                .connection = "bindings/racket/private/session.rkt",
                .locator = "bindings/racket/private/locator.rkt",
                .banned_in_connection = &.{
                    "(define (socket-addr-designator",
                    "(define (host-port-from-direct-hint",
                },
                .required_in_locator = &.{
                    "(define (socket-addr-designator",
                },
            },
        };
        for (locator_grammar_home) |entry| {
            const conn_contents = root.readFileAlloc(io, entry.connection, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for locator-grammar home check with {s}", .{ entry.connection, @errorName(err) });
                continue;
            };
            defer gpa.free(conn_contents);
            for (entry.banned_in_connection) |needle| {
                if (std.mem.indexOf(u8, conn_contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — define grammar helpers in {s}", .{ entry.connection, needle, entry.locator });
                }
            }
            const loc_contents = root.readFileAlloc(io, entry.locator, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for locator-grammar home check with {s}", .{ entry.locator, @errorName(err) });
                continue;
            };
            defer gpa.free(loc_contents);
            for (entry.required_in_locator) |needle| {
                if (std.mem.indexOf(u8, loc_contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — locator grammar helper home", .{ entry.locator, needle });
                }
            }
        }
        // One unified dial executor owns the transport switch per binding.
        const unified_dial_executor = [_]struct { path: []const u8, symbol: []const u8 }{
            .{ .path = "bindings/python/pancake/_dial.py", .symbol = "dial_parsed_locator" },
            .{ .path = "bindings/ts/stack/dial.ts", .symbol = "dialParsedLocator" },
            .{ .path = "bindings/rust/src/dial.rs", .symbol = "dial_parsed_locator" },
            .{ .path = "bindings/racket/private/dial.rkt", .symbol = "dial-parsed-locator" },
        };
        for (unified_dial_executor) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for unified dial executor check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.symbol) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — connect and redeem share one dial executor", .{ entry.path, entry.symbol });
            }
        }
        // TCP dials always split the designator through the core host:port grammar;
        // connect must not bypass with a parse-time hostPort cache.
        const tcp_dial_one_path = [_]struct {
            path: []const u8,
            banned: []const []const u8,
        }{
            .{ .path = "bindings/ts/stack/dial.ts", .banned = &.{ "opts.hostPort", "hostPort: loc.hostPort" } },
            .{ .path = "bindings/rust/src/dial.rs", .banned = &.{ "tcp_host_port", "loc.host_port" } },
            .{ .path = "bindings/python/pancake/_dial.py", .banned = &.{ "tcp_host", "tcp_port", "loc.host", "loc.port" } },
            .{ .path = "bindings/racket/private/dial.rkt", .banned = &.{ "#:tcp-host", "#:tcp-port", "(locator-host loc)", "(locator-port loc)" } },
        };
        for (tcp_dial_one_path) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for tcp dial one-path check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — tcp dials split designator via designator_host_port only", .{ entry.path, needle });
                }
            }
        }
        // DialPlan open-shape: peer_id (not product iroh); PeerKey refuse before I/O.
        {
            const plan_src = root.readFileAlloc(io, "src/driver/core/dial_plan.zig", gpa, .limited(2 << 20)) catch |err| blk: {
                try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: failed to read for peer_id gate with {s}", .{@errorName(err)});
                break :blk @as(?[]u8, null);
            };
            defer if (plan_src) |c| gpa.free(c);
            if (plan_src) |contents| {
                if (std.mem.indexOf(u8, contents, "peer_id:") == null) {
                    try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: missing `peer_id:` — DialPlan open-shape arm", .{});
                }
                if (std.mem.indexOf(u8, contents, "iroh:") != null) {
                    try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: forbidden `iroh:` — DialPlan arm is peer_id, not the product name", .{});
                }
                if (std.mem.indexOf(u8, contents, "PeerKey.fromDesignator") == null) {
                    try appendViolation(gpa, violations, "src/driver/core/dial_plan.zig: missing `PeerKey.fromDesignator` — keyed-tcp/iroh refuse before I/O", .{});
                }
            }
            const core_import_ban = [_]struct { path: []const u8, needles: []const []const u8 }{
                .{ .path = "src/driver/core/dial_plan.zig", .needles = &.{ "@import(\"iroh\")", "net/transport/iroh", "net_transport_iroh" } },
                .{ .path = "src/driver/core/vocab.zig", .needles = &.{ "@import(\"iroh\")", "net/transport/iroh", "net_transport_iroh" } },
                .{ .path = "src/driver/core/host.zig", .needles = &.{ "@import(\"iroh\")", "net/transport/iroh", "net_transport_iroh" } },
            };
            for (core_import_ban) |entry| {
                const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for iroh-import ban with {s}", .{ entry.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                for (entry.needles) |needle| {
                    if (std.mem.indexOf(u8, contents, needle) != null) {
                        try appendViolation(gpa, violations, "{s}: forbidden `{s}` — driver_core must not import the iroh netlayer", .{ entry.path, needle });
                    }
                }
            }
            const shape_peer = [_]struct { path: []const u8, required: []const u8, banned: []const u8 }{
                .{ .path = "src/c_abi/driver/mod.zig", .required = "PANCAKE_DIAL_SHAPE_PEER_ID", .banned = "PANCAKE_DIAL_SHAPE_IROH" },
                .{ .path = "include/pancake_driver.h", .required = "PANCAKE_DIAL_SHAPE_PEER_ID", .banned = "PANCAKE_DIAL_SHAPE_IROH" },
                .{ .path = "bindings/ts/stack/internal/abi.ts", .required = "DIAL_SHAPE_PEER_ID", .banned = "DIAL_SHAPE_IROH" },
                .{ .path = "bindings/python/pancake/_constants_gen.py", .required = "DIAL_SHAPE_PEER_ID", .banned = "DIAL_SHAPE_IROH" },
                .{ .path = "bindings/rust/src/abi_constants_gen.rs", .required = "DIAL_SHAPE_PEER_ID", .banned = "DIAL_SHAPE_IROH" },
                .{ .path = "bindings/racket/private/constants-gen.rkt", .required = "DIAL-SHAPE-PEER-ID", .banned = "DIAL-SHAPE-IROH" },
            };
            for (shape_peer) |entry| {
                const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for DIAL_SHAPE_PEER_ID gate with {s}", .{ entry.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                if (std.mem.indexOf(u8, contents, entry.required) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — peer-id open shape", .{ entry.path, entry.required });
                }
                if (std.mem.indexOf(u8, contents, entry.banned) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — product name is not the DialPlan shape", .{ entry.path, entry.banned });
                }
            }
        }
        // Binding locator modules must not resurrect hint→host:port twins.
        const retired_hint_split = [_]struct {
            path: []const u8,
            banned: []const []const u8,
        }{
            .{ .path = "bindings/python/pancake/_locator.py", .banned = &.{ "def host_port_from_direct_hint", "def _host_port_from_direct_hint" } },
            .{ .path = "bindings/ts/stack/locator.ts", .banned = &.{ "function hostPortFromDirectHint", "export function hostPortFromDirectHint" } },
            .{ .path = "bindings/rust/src/uri.rs", .banned = &.{ "fn host_port_from_direct_hint", "pub fn host_port_from_direct_hint" } },
            .{ .path = "bindings/racket/private/locator.rkt", .banned = &.{"(define (host-port-from-direct-hint"} },
        };
        for (retired_hint_split) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for retired hint-split ban with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — hint→host:port is planDial policy (ADR-0078), not a binding helper", .{ entry.path, needle });
                }
            }
        }
        // Binding pump borrow-on-empty; Racket one locked feed helper.
        const pump_borrow = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/stack/pump.ts",
                .required = &.{ "ab(chunk)", "chunk.subarray(consumed).slice()" },
                .banned = &.{"h.inbox = bytes.slice()"},
            },
            .{
                .path = "bindings/rust/src/pump.rs",
                .required = &.{"feed_raw(shared, chunk)"},
                .banned = &.{},
            },
            .{
                .path = "bindings/python/pancake/_pump.py",
                .required = &.{"ctypes.c_char_p(chunk)"},
                .banned = &.{},
            },
            .{
                .path = "bindings/racket/private/pump.rkt",
                .required = &.{ "feed-locked!", "pin-immobile buf-bytes", "c got" },
                .banned = &.{},
            },
        };
        for (pump_borrow) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for pump borrow gate with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.required) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — empty-inbox borrow-on-feed posture", .{ entry.path, needle });
                }
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — empty-inbox must not copy before feed", .{ entry.path, needle });
                }
            }
        }
        // Binding RemotePromise: sum state, not nullable vow discriminant.
        const promise_sum = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/stack/promise.ts",
                .required = &.{ "export type PromiseState", "static far(", "static local(" },
                .banned = &.{"readonly vow: bigint | null"},
            },
            .{
                .path = "bindings/python/pancake/_promise.py",
                .required = &.{ "class PromiseState", "class Far", "class Local", "def far(", "def local(", "self._kind" },
                .banned = &.{ "vow: Optional[int]", "vow: Optional[int] = None", "self._state =" },
            },
            .{
                .path = "bindings/rust/src/promise.rs",
                .required = &.{ "enum PromiseState", "Far(", "Local {" },
                .banned = &.{},
            },
        };
        for (promise_sum) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for PromiseState gate with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.required) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — RemotePromise sum state", .{ entry.path, needle });
                }
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — nullable vow is not the discriminant", .{ entry.path, needle });
                }
            }
        }
        // Dial plan alias decode + peer-id shape; language sum; no opaque rematerialize.
        const dial_alias = [_]struct { path: []const u8, required: []const []const u8, banned: []const []const u8 }{
            .{
                .path = "bindings/ts/stack/dial.ts",
                .required = &.{ "decodePlanView", "DIAL_SHAPE_PEER_ID", "DIAL_SHAPE_HOST_PORT", "tag: \"peer_id\"", "tag: \"host_port\"" },
                .banned = &.{ "DIAL_SHAPE_IROH", "beyond the tcp host:port split", "dispatching on the locator", "readBytes(ptr, len)" },
            },
            .{
                .path = "bindings/python/pancake/_dial.py",
                .required = &.{ "def _decode_plan_view", "DIAL_SHAPE_PEER_ID", "DIAL_SHAPE_HOST_PORT", "memoryview(buf)", "class _PeerIdDial", "class _HostPortDial" },
                .banned = &.{ "DIAL_SHAPE_IROH", "bytes(buf)[", "dispatching on the locator", "return ctypes.string_at" },
            },
            .{
                .path = "bindings/rust/src/dial.rs",
                .required = &.{ "fn decode_plan_view", "DIAL_SHAPE_PEER_ID", "DIAL_SHAPE_HOST_PORT", "DialPlan::PeerId", "DialPlan::HostPort" },
                .banned = &.{ "DIAL_SHAPE_IROH", "beyond the tcp host:port split", "dispatching on the locator", "view_string(ptr, len)" },
            },
            .{
                .path = "bindings/racket/private/dial.rkt",
                .required = &.{ "decode-plan-view", "DIAL-SHAPE-PEER-ID", "DIAL-SHAPE-HOST-PORT", "peer-id-dial", "host-port-dial" },
                .banned = &.{ "DIAL-SHAPE-IROH", "dispatching on the locator", "(bytes<-c ptr len)" },
            },
        };
        for (dial_alias) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for dial-alias gate with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.required) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — dial plan alias / peer-id shape", .{ entry.path, needle });
                }
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — stale dial prose or product shape", .{ entry.path, needle });
                }
            }
        }
        {
            const action_src = root.readFileAlloc(io, "bindings/rust/src/action.rs", gpa, .limited(1 << 20)) catch |err| blk: {
                try appendViolation(gpa, violations, "bindings/rust/src/action.rs: failed to read for FAIL→CLOSED gate with {s}", .{@errorName(err)});
                break :blk @as(?[]u8, null);
            };
            defer if (action_src) |c| gpa.free(c);
            if (action_src) |contents| {
                if (std.mem.indexOf(u8, contents, "vow_session_closing") == null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/action.rs: missing `vow_session_closing` — FAIL must classify disconnect as CLOSED", .{});
                }
                if (std.mem.indexOf(u8, contents, "ERR_CLOSED") == null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/action.rs: missing `ERR_CLOSED` on FAIL path", .{});
                }
            }
            const host_src = root.readFileAlloc(io, "bindings/rust/src/host.rs", gpa, .limited(2 << 20)) catch |err| blk: {
                try appendViolation(gpa, violations, "bindings/rust/src/host.rs: failed to read for FAIL→CLOSED gate with {s}", .{@errorName(err)});
                break :blk @as(?[]u8, null);
            };
            defer if (host_src) |c| gpa.free(c);
            if (host_src) |contents| {
                if (std.mem.indexOf(u8, contents, "siblings type it Closed") != null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/host.rs: forbidden papering comment — FAIL classifies CLOSED in-tree", .{});
                }
                if (std.mem.indexOf(u8, contents, "fn vow_session_closing") == null) {
                    try appendViolation(gpa, violations, "bindings/rust/src/host.rs: missing `vow_session_closing`", .{});
                }
            }
        }
        // Peer-id open-shape vocabulary: no product-named shape error / FFI prose.
        {
            const peer_id_vocab = [_]struct { path: []const u8, banned: []const []const u8 }{
                .{ .path = "src/c_abi/driver/host.zig", .banned = &.{"an iroh locator requires a reachability posture"} },
                .{ .path = "bindings/python/pancake/_ffi_driver.py", .banned = &.{"IROH fills"} },
                .{ .path = "bindings/racket/private/ffi-driver.rkt", .banned = &.{"IROH fills"} },
                .{ .path = "bindings/rust/src/sys/driver.rs", .banned = &.{"IROH fills"} },
            };
            for (peer_id_vocab) |entry| {
                const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to read for peer-id vocab gate with {s}", .{ entry.path, @errorName(err) });
                    continue;
                };
                defer gpa.free(contents);
                for (entry.banned) |needle| {
                    if (std.mem.indexOf(u8, contents, needle) != null) {
                        try appendViolation(gpa, violations, "{s}: forbidden `{s}` — open shape is peer_id, not product iroh", .{ entry.path, needle });
                    }
                }
            }
        }
        // Gift interop argv must mint host:port designators through socket_addr_designator.
        const gift_addr_designator = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "interop/goblins_interop/deno_gift_client.ts",
                .required = "socketAddrDesignator",
                .banned = &.{"`${HOST}:${gifterPort}`,"},
            },
            .{
                .path = "interop/goblins_interop/python_gift_client.py",
                .required = "socket_addr_designator",
                .banned = &.{"f\"{HOST}:{gifter_port}\""},
            },
            .{
                .path = "interop/goblins_interop/racket_gift_client.rkt",
                .required = "socket-addr-designator",
                .banned = &.{"(format \"~a:~a\" HOST gifter-port)"},
            },
            .{
                .path = "interop/goblins_interop/rust_gift_client.rs",
                .required = "socket_addr_designator",
                .banned = &.{"format!(\"{HOST}:{gifter_port}\")"},
            },
        };
        for (gift_addr_designator) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for gift addr designator check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — gift interop argv must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator for gift argv", .{ entry.path, needle });
                }
            }
        }
        // Rooms iroh dials parse first; hint→Direct, else discovery — never blanket Direct on `://`.
        const rooms_iroh_dial = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "examples/apps/rooms/deno/lib/locator.ts",
                .required = "connect(\n\t\t\tlocator,",
                .banned = &.{ "connectIroh(", "import { connectIroh" },
            },
            .{
                .path = "examples/apps/rooms/python/room_client.py",
                .required = "await connect(locator, reach)",
                .banned = &.{"connect_iroh("},
            },
            .{
                .path = "examples/apps/rooms/racket/room-client.rkt",
                .required = "(connect locator reach)",
                .banned = &.{"(connect-iroh "},
            },
            .{
                .path = "examples/apps/rooms/rust/room.rs",
                .required = "connect(locator, Some(reachability)",
                .banned = &.{"connect_iroh("},
            },
            .{
                .path = "examples/apps/rooms/zig/client.zig",
                .required = "parsePeer",
                .banned = &.{"init(io, null, .direct)"},
            },
            .{
                .path = "examples/apps/rooms/deno/server_test.ts",
                .required = "await dial(uri)",
                .banned = &.{ "connect(uri, Reachability.Direct)", "Reachability.Direct)" },
            },
        };
        for (rooms_iroh_dial) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for rooms iroh dial check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — rooms iroh dials must parse the locator first", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — rooms iroh posture follows hints, not blanket Direct", .{ entry.path, needle });
                }
            }
        }
        // Dogfood / unit tests mint host:port designators through socket_addr_designator.
        const dogfood_addr_designator = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/racket/zig-smoke.rkt",
                .required = "socket-addr-designator",
                .banned = &.{ "\"127.0.0.1:9\"", "\"127.0.0.1:1\"", "\"127.0.0.1:2\"", "format-peer-uri \"tcp\"" },
            },
            .{
                .path = "bindings/python/zig_smoke.py",
                .required = "socket_addr_designator",
                .banned = &.{"\"127.0.0.1:1\""},
            },
            .{
                .path = "bindings/rust/src/session_tests.rs",
                .required = "socket_addr_designator(&peer.ip().to_string(), peer.port())",
                .banned = &.{ "peer.to_string()", "\"127.0.0.1:0\".to_string()" },
            },
        };
        for (dogfood_addr_designator) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for dogfood addr designator check with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — dogfood designators must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator", .{ entry.path, needle });
                }
            }
        }
        // External dialers use connect(locator); parallel connect_iroh* is binding-internal.
        const no_public_iroh_connect = [_]struct { path: []const u8, banned: []const []const u8 }{
            .{ .path = "interop/iroh_loop/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "interop/iroh_loop/python_client.py", .banned = &.{"connect_iroh("} },
            .{ .path = "interop/iroh_loop/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "interop/iroh_reachability/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "interop/iroh_reachability/python_client.py", .banned = &.{"connect_iroh("} },
            .{ .path = "interop/iroh_reachability/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "interop/iroh_handoff/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "interop/iroh_handoff/python_client.py", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "interop/iroh_handoff/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "interop/iroh_redeem_posture/python_client.py", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "interop/iroh_redeem_posture/racket_client.rkt", .banned = &.{ "(connect-iroh ", "(connect-iroh/node " } },
            .{ .path = "interop/iroh_redeem_posture/deno_client.ts", .banned = &.{ "connectIroh(", "_connectIroh(" } },
            .{ .path = "bindings/rust/examples/iroh_loop.rs", .banned = &.{"connect_iroh("} },
            .{ .path = "bindings/rust/examples/iroh_reachability.rs", .banned = &.{"connect_iroh("} },
            .{ .path = "bindings/rust/examples/iroh_handoff.rs", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "bindings/rust/examples/iroh_redeem_posture.rs", .banned = &.{ "connect_iroh(", "connect_iroh_with_node(" } },
            .{ .path = "bindings/python/pancake/iroh.py", .banned = &.{ "\"connect_iroh\"", "async def connect_iroh(", "async def connect_iroh_with_node(" } },
            .{ .path = "bindings/rust/src/iroh.rs", .banned = &.{ "pub async fn connect_iroh(", "pub async fn connect_iroh_with_node(" } },
            .{ .path = "bindings/ts/iroh/mod.ts", .banned = &.{ "connectIroh", "_connectIroh" } },
            .{ .path = "bindings/racket/pancake-iroh.rkt", .banned = &.{"(provide connect-iroh/node\n         listen-iroh"} },
        };
        for (no_public_iroh_connect) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for iroh-connect ban with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — dial iroh through connect(locator)", .{ entry.path, needle });
                }
            }
        }
        // Public barrel must not export the dial; the dial module loads
        // `@pancake/iroh/internal` from `stack/dial.ts`.
        iroh_public_surface: {
            const mod_contents = root.readFileAlloc(io, "bindings/ts/iroh/mod.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(mod_contents);
            if (std.mem.indexOf(u8, mod_contents, "listenIroh") == null) {
                try appendViolation(gpa, violations, "bindings/ts/iroh/mod.ts: missing listenIroh re-export", .{});
            }
            const internal_contents = root.readFileAlloc(io, "bindings/ts/iroh/internal.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/iroh/internal.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(internal_contents);
            if (std.mem.indexOf(u8, internal_contents, "_connectIroh") == null) {
                try appendViolation(gpa, violations, "bindings/ts/iroh/internal.ts: missing `_connectIroh` export", .{});
            }
            const dial_contents = root.readFileAlloc(io, "bindings/ts/stack/dial.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/stack/dial.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(dial_contents);
            if (std.mem.indexOf(u8, dial_contents, "import(\"@pancake/iroh/internal\")") == null) {
                try appendViolation(gpa, violations, "bindings/ts/stack/dial.ts: iroh dial must lazy-import `@pancake/iroh/internal`", .{});
            }
            if (std.mem.indexOf(u8, dial_contents, "import(\"@pancake/iroh\")") != null) {
                try appendViolation(gpa, violations, "bindings/ts/stack/dial.ts: forbidden public `@pancake/iroh` dial import — use `/internal`", .{});
            }
            const conn_contents = root.readFileAlloc(io, "bindings/ts/stack/session.ts", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/ts/stack/session.ts: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(conn_contents);
            if (std.mem.indexOf(u8, conn_contents, "import(\"@pancake/iroh\")") != null) {
                try appendViolation(gpa, violations, "bindings/ts/stack/session.ts: forbidden public `@pancake/iroh` dial import — use the dial module", .{});
            }
            const rkt_contents = root.readFileAlloc(io, "bindings/racket/pancake-iroh.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/pancake-iroh.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_contents);
            if (std.mem.indexOf(u8, rkt_contents, "(module* dial #f") == null) {
                try appendViolation(gpa, violations, "bindings/racket/pancake-iroh.rkt: missing `(module* dial #f)` for connect-iroh/node", .{});
            }
            const rkt_dial = root.readFileAlloc(io, "bindings/racket/private/dial.rkt", gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "bindings/racket/private/dial.rkt: failed to read with {s}", .{@errorName(err)});
                break :iroh_public_surface;
            };
            defer gpa.free(rkt_dial);
            if (std.mem.indexOf(u8, rkt_dial, "(iroh-dial-mod)") == null) {
                try appendViolation(gpa, violations, "bindings/racket/private/dial.rkt: iroh dial must load `(submod … dial)`", .{});
            }
        }
        // keyed_tcp_locator must assemble direct-addresses through
        // socket_addr_designator so IPv6 hints stay unambiguous.
        const keyed_hint_home = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/python/pancake/_locator.py",
                .required = "socket_addr_designator(host, port)",
                .banned = &.{"{_abi.HINT_DIRECT_ADDRESSES: f\"{host}:{port}\"}"},
            },
            .{
                .path = "bindings/ts/stack/locator.ts",
                .required = "socketAddrDesignator(hostname, port)",
                .banned = &.{"HINT_DIRECT_ADDRESSES, `${hostname}:${port}`"},
            },
            .{
                .path = "bindings/rust/src/uri.rs",
                .required = "socket_addr_designator(host, port)",
                .banned = &.{
                    "HINT_DIRECT_ADDRESSES.to_string(),\n\t\tformat!(\"{host}:{port}\")",
                },
            },
            .{
                .path = "bindings/racket/private/locator.rkt",
                .required = "(socket-addr-designator host port)",
                .banned = &.{"(hash HINT-DIRECT-ADDRESSES (format \"~a:~a\" host port))"},
            },
        };
        for (keyed_hint_home) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-tcp hint grammar with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — keyed-tcp direct-addresses hint must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator for keyed-tcp hints", .{ entry.path, needle });
                }
            }
        }
        // tcp_locator must assemble the designator through socket_addr_designator
        // so IPv6 stays unambiguous (sibling of keyed_tcp_locator hint ring).
        const tcp_locator_home = [_]struct {
            path: []const u8,
            required: []const u8,
            banned: []const []const u8,
        }{
            .{
                .path = "bindings/python/pancake/_locator.py",
                .required = "socket_addr_designator(host, port)",
                .banned = &.{
                    "format_peer_uri(_abi.TRANSPORT_TCP, f\"{host}:{port}\")",
                },
            },
            .{
                .path = "bindings/ts/stack/locator.ts",
                .required = "socketAddrDesignator(hostname, port)",
                .banned = &.{
                    "formatPeerUri(TRANSPORT_TCP, `${hostname}:${port}`)",
                },
            },
            .{
                .path = "bindings/rust/src/uri.rs",
                .required = "socket_addr_designator(host, port)",
                .banned = &.{
                    "TRANSPORT_TCP,\n\t\t&format!(\"{host}:{port}\")",
                },
            },
            .{
                .path = "bindings/racket/private/locator.rkt",
                .required = "(socket-addr-designator host port)",
                .banned = &.{
                    "(format-peer-uri TRANSPORT-TCP (format \"~a:~a\" host port))",
                },
            },
        };
        for (tcp_locator_home) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for tcp locator grammar with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, entry.required) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — tcp locator designator must use socket_addr_designator", .{ entry.path, entry.required });
            }
            for (entry.banned) |needle| {
                if (std.mem.indexOf(u8, contents, needle) != null) {
                    try appendViolation(gpa, violations, "{s}: forbidden `{s}` — use socket_addr_designator for tcp locator designators", .{ entry.path, needle });
                }
            }
        }
        // KeyedTcpServer.uri must not remint from the bind-host string.
        {
            const path = "bindings/ts/stack/listen.ts";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-uri bind-host ban with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "keyedTcpLocator(this.#designator, this.#host") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden keyedTcpLocator(..., this.#host) — use listener.localAddr()", .{path});
            }
        }
        {
            const path = "bindings/racket/private/listen.rkt";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for keyed-uri bind-host ban with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "(keyed-tcp-locator (keyed-tcp-server-designator s) (keyed-tcp-server-host s)") != null) {
                try appendViolation(gpa, violations, "{s}: forbidden CapTP host as keyed-tcp URI bind address — use tcp-addresses bound host", .{path});
            }
        }
        // Rust listen/accept designators go through socket_addr_designator, not
        // SocketAddr::to_string (Display is close but not the shared grammar).
        {
            const path = "bindings/rust/src/listen.rs";
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for rust designator grammar with {s}", .{ path, @errorName(err) });
                return;
            };
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, "socket_addr_designator(&") == null) {
                try appendViolation(gpa, violations, "{s}: missing socket_addr_designator on listen/accept paths", .{path});
            }
            if (std.mem.indexOf(u8, contents, "set_self_designator(&local.to_string())") != null or
                std.mem.indexOf(u8, contents, ".map(|addr| addr.to_string())") != null or
                std.mem.indexOf(u8, contents, ".map(|a| a.to_string())") != null)
            {
                try appendViolation(gpa, violations, "{s}: forbidden SocketAddr::to_string for designators — use socket_addr_designator", .{path});
            }
        }
        // Constant homes must name the full model.transport table.
        const must_have = [_]struct { path: []const u8, needles: []const []const u8 }{
            .{
                .path = "bindings/python/pancake/_constants.py",
                .needles = &.{ "TRANSPORT_TCP", "TRANSPORT_KEYED_TCP", "TRANSPORT_INPROC", "TRANSPORT_IROH", "HINT_DIRECT_ADDRESSES" },
            },
            .{
                .path = "bindings/rust/src/abi_constants.rs",
                .needles = &.{ "TRANSPORT_TCP", "TRANSPORT_KEYED_TCP", "TRANSPORT_INPROC", "TRANSPORT_IROH", "HINT_DIRECT_ADDRESSES" },
            },
            .{
                .path = "bindings/ts/stack/locator.ts",
                .needles = &.{ "TRANSPORT_TCP", "TRANSPORT_KEYED_TCP", "TRANSPORT_INPROC", "TRANSPORT_IROH", "HINT_DIRECT_ADDRESSES" },
            },
            .{
                .path = "bindings/racket/private/constants.rkt",
                .needles = &.{ "TRANSPORT-TCP", "TRANSPORT-KEYED-TCP", "TRANSPORT-INPROC", "TRANSPORT-IROH", "HINT-DIRECT-ADDRESSES" },
            },
        };
        for (must_have) |entry| {
            const contents = root.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for transport-constant presence with {s}", .{ entry.path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            for (entry.needles) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — binding transport vocabulary mirrors model.transport", .{ entry.path, needle });
                }
            }
        }
    }

    // The structural guard against a resident-local serve loop re-growing lives
    // in `checkIrohLoopConvergence`, which bans `LoopHost` as a Zig symbol in the
    // iroh resident source. A prose ban on the dead word across binding docs was
    // a stabilized-rename tombstone and was pruned (see the gate-accretion rule).
}

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

/// CapTP is transport-agnostic; only netlayers name transports. Living-state
/// surfaces that equate pancake/OCapN with TCP, or that enumerate residents
/// without `keyed-tcp`, fail here so the vocabulary cannot rot back.
const transport_vocabulary_forbidden = [_]struct { phrase: []const u8, reason: []const u8 }{
    .{
        .phrase = "binds the TCP socket",
        .reason = "`net` realizes netlayer residents over byte streams; CapTP never names a transport",
    },
    .{
        .phrase = "pancake has two channels",
        .reason = "name netlayer symbols and confidentiality postures; CapTP is identical across them",
    },
    .{
        .phrase = "OCapN/TCP",
        .reason = "say an OCapN session on the `tcp` netlayer — CapTP is not TCP-based",
    },
    .{
        .phrase = "A byte-stream netlayer ships in `net`",
        .reason = "`net` is the adapter + netlayer contract; CapTP stays above it",
    },
    .{
        .phrase = "Sessions above the socket",
        .reason = "sessions live above I/O / the netlayer, not specifically TCP sockets",
    },
    .{
        .phrase = "pure asyncio over TCP",
        .reason = "binding core is the byte-fed host; transport is chosen by locator",
    },
};

const transport_vocabulary_paths = [_][]const u8{
    ".agents/rules/architecture.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "docs/architecture.md",
    "docs/boundaries.md",
    "docs/ladder.md",
    "docs/shipped.md",
    "docs/roadmap.md",
    "docs/capabilities.md",
    "docs/vision.md",
    "bindings/README.md",
    "bindings/python/README.md",
    "bindings/rust/README.md",
    "bindings/racket/README.md",
    "bindings/ts/README.md",
    "examples/README.md",
    "examples/apps/accountability-on-pancake/README.md",
    "site/content/transports.smd",
    "site/content/modules.smd",
    "site/content/examples.smd",
};

fn checkTransportVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (transport_vocabulary_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport-vocabulary check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        for (transport_vocabulary_forbidden) |entry| {
            if (std.mem.indexOf(u8, contents, entry.phrase) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — {s}", .{ path, entry.phrase, entry.reason });
            }
        }

        // Resident enumerations that still say "three" without keyed-tcp.
        if (std.mem.indexOf(u8, contents, "three residents") != null or
            std.mem.indexOf(u8, contents, "Three residents") != null or
            std.mem.indexOf(u8, contents, "All three residents") != null or
            std.mem.indexOf(u8, contents, "three real residents") != null or
            std.mem.indexOf(u8, contents, "Three ship today") != null or
            std.mem.indexOf(u8, contents, "walks all three") != null)
        {
            if (std.mem.indexOf(u8, contents, "keyed-tcp") == null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: netlayer resident count omits `keyed-tcp` — list `tcp`, `keyed-tcp`, `inproc`, and iroh",
                    .{path},
                );
            }
        }
    }
}

/// `driver_core.designatorSchemeForTransport` must agree with each netlayer
/// resident's `designator_scheme` for the four shipped transports. The sans-io
/// host never sees a vtable, so this string table is the byte-fed mirror of
/// the I/O path's authoritative declaration — a transport added to one must
/// land in the other.
fn checkDesignatorSchemeSync(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Transport = struct {
        name: []const u8,
        path: []const u8,
    };
    const transports = [_]Transport{
        .{ .name = "tcp", .path = "src/net/transport/tcp.zig" },
        .{ .name = "keyed-tcp", .path = "src/net/transport/tcp_keyed.zig" },
        .{ .name = "inproc", .path = "src/net/transport/inproc.zig" },
        .{ .name = "iroh", .path = "src/net/transport/iroh.zig" },
    };

    const vocab_path = "src/driver/core/vocab.zig";
    const vocab = root.readFileAlloc(io, vocab_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for designator-scheme sync with {s}", .{ vocab_path, @errorName(err) });
        return;
    };
    defer gpa.free(vocab);

    const fn_start = std.mem.indexOf(u8, vocab, "pub fn designatorSchemeForTransport") orelse {
        try appendViolation(gpa, violations, "{s}: missing `pub fn designatorSchemeForTransport`", .{vocab_path});
        return;
    };
    const after_fn = vocab[fn_start..];
    const body_open = std.mem.indexOfScalar(u8, after_fn, '{') orelse {
        try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport has no body", .{vocab_path});
        return;
    };
    const body = after_fn[body_open..];
    const body_close = std.mem.indexOfScalar(u8, body, '}') orelse {
        try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport body is unclosed", .{vocab_path});
        return;
    };
    const fn_body = body[0 .. body_close + 1];

    for (transports) |t| {
        const vocab_scheme = designatorSchemeFromVocabBody(fn_body, t.name);
        const resident = root.readFileAlloc(io, t.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for designator-scheme sync with {s}", .{ t.path, @errorName(err) });
            continue;
        };
        defer gpa.free(resident);

        const resident_scheme = designatorSchemeFromResident(resident);
        if (!std.mem.eql(u8, vocab_scheme, resident_scheme)) {
            try appendViolation(
                gpa,
                violations,
                "designator-scheme mismatch for `{s}`: vocab.designatorSchemeForTransport → .{s}, but {s} Netlayer.VTable → .{s}",
                .{ t.name, vocab_scheme, t.path, resident_scheme },
            );
        }
    }

    // Every explicit key arm in the vocab table must name a shipped transport
    // (no orphan model.transport.* or string that never matches a resident).
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, fn_body, search, "model.transport.")) |at| {
        const after = fn_body[at + "model.transport.".len ..];
        const end = std.mem.indexOfAny(u8, after, ")., \n\r\t") orelse break;
        const field = after[0..end];
        if (std.mem.eql(u8, field, "hint_direct_addresses")) {
            search = at + 1;
            continue;
        }
        const name = transportNameFromField(field) orelse {
            try appendViolation(gpa, violations, "{s}: designatorSchemeForTransport names unknown model.transport.`{s}`", .{ vocab_path, field });
            search = at + 1;
            continue;
        };
        var known = false;
        for (transports) |t| {
            if (std.mem.eql(u8, t.name, name)) {
                known = true;
                break;
            }
        }
        if (!known) {
            try appendViolation(
                gpa,
                violations,
                "{s}: designatorSchemeForTransport names unknown transport `{s}` — add a netlayer resident or drop the arm",
                .{ vocab_path, name },
            );
        }
        search = at + 1;
    }

    // Residents must alias `transport_name` to `model.transport.*` (one symbol table).
    for (transports) |t| {
        const resident = root.readFileAlloc(io, t.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport_name alias check with {s}", .{ t.path, @errorName(err) });
            continue;
        };
        defer gpa.free(resident);
        const field = transportSymbolField(t.name);
        var alias_buf: [96]u8 = undefined;
        const alias = std.fmt.bufPrint(&alias_buf, "model.transport.{s}", .{field}) catch continue;
        if (std.mem.indexOf(u8, resident, alias) == null) {
            try appendViolation(gpa, violations, "{s}: `transport_name` must alias `{s}` — one model.transport symbol table", .{ t.path, alias });
        }
    }
}

fn transportNameFromField(field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "tcp")) return "tcp";
    if (std.mem.eql(u8, field, "keyed_tcp")) return "keyed-tcp";
    if (std.mem.eql(u8, field, "inproc")) return "inproc";
    if (std.mem.eql(u8, field, "iroh")) return "iroh";
    return null;
}

fn designatorSchemeFromVocabBody(fn_body: []const u8, transport: []const u8) []const u8 {
    // Match `transport, model.transport.NAME)` arms (preferred) or legacy
    // `transport, "NAME")` arms; unmarked names fall through to `.address`.
    var buf: [128]u8 = undefined;
    const model_needle = std.fmt.bufPrint(&buf, "transport, model.transport.{s})", .{transportSymbolField(transport)}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, model_needle)) |scheme| return scheme;
    const lit_needle = std.fmt.bufPrint(&buf, "transport, \"{s}\")", .{transport}) catch return "address";
    if (schemeReturnAfterNeedle(fn_body, lit_needle)) |scheme| return scheme;
    return "address";
}

fn transportSymbolField(transport: []const u8) []const u8 {
    if (std.mem.eql(u8, transport, "tcp")) return "tcp";
    if (std.mem.eql(u8, transport, "keyed-tcp")) return "keyed_tcp";
    if (std.mem.eql(u8, transport, "inproc")) return "inproc";
    if (std.mem.eql(u8, transport, "iroh")) return "iroh";
    return transport;
}

fn schemeReturnAfterNeedle(fn_body: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, fn_body, needle) orelse return null;
    const after = fn_body[at + needle.len ..];
    if (std.mem.indexOf(u8, after, "return .key")) |k| {
        if (std.mem.indexOf(u8, after, "return .address")) |a| {
            if (a < k) return "address";
        }
        if (std.mem.indexOf(u8, after, "\nif ")) |next_if| {
            if (k < next_if) return "key";
        } else return "key";
    }
    if (std.mem.indexOf(u8, after, "return .address")) |_| return "address";
    return null;
}

/// Read the Netlayer resident vtable's `designator_scheme` from source.
/// Absence means the VTable default (`.address`).
fn designatorSchemeFromResident(source: []const u8) []const u8 {
    // Prefer the first Netlayer.VTable literal; keyed-tcp/iroh set `.key`
    // there. Listener vtables may repeat the same field and must not confuse
    // an address-scheme resident.
    const markers = [_][]const u8{
        "const resident_vtable: Netlayer.VTable",
        "const resident_vtable: net.netlayer.Netlayer.VTable",
        "const netlayer_vtable = Netlayer.VTable",
        "const netlayer_vtable: Netlayer.VTable",
    };
    var vtable_region: ?[]const u8 = null;
    for (markers) |marker| {
        if (std.mem.indexOf(u8, source, marker)) |at| {
            const rest = source[at..];
            const open = std.mem.indexOfScalar(u8, rest, '{') orelse continue;
            const close = std.mem.indexOfScalar(u8, rest[open..], '}') orelse continue;
            vtable_region = rest[open .. open + close + 1];
            break;
        }
    }
    const region = vtable_region orelse source;
    if (std.mem.indexOf(u8, region, ".designator_scheme = .key") != null) return "key";
    if (std.mem.indexOf(u8, region, ".designator_scheme = .address") != null) return "address";
    return "address";
}

/// The C-ABI find/download cascade is one contract (`bindings/c-abi-resolve.json`)
/// shipped inside every binding package (ADR-0077). Bindings download with
/// language-native code; `tools/c-abi/fetch-c-abi.sh` is an operator CLI only.
const c_abi_binding_loaders = [_][]const u8{
    "bindings/rust/build.rs",
    "bindings/python/pancake/_lib_resolve.py",
    "bindings/ts/stack/internal/ffi/load.ts",
    "bindings/racket/private/lib-resolve.rkt",
};

fn checkCAbiResolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const contract_path = "bindings/c-abi-resolve.json";
    var parsed = try parseJsonFile(io, gpa, root, violations, contract_path) orelse return;
    defer parsed.deinit();

    const expected_tarball = "pancake-c-v{version}-{target}.tar.gz";
    const expected_operator_script = "tools/c-abi/fetch-c-abi.sh";

    const abi_version = blk: {
        const v = getField(parsed.value, "abi_version") orelse {
            try appendViolation(gpa, violations, "{s}: missing `abi_version`", .{contract_path});
            break :blk null;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                try appendViolation(gpa, violations, "{s}: `abi_version` must be a string", .{contract_path});
                break :blk null;
            },
        };
    };

    if (getField(parsed.value, "tarball_template")) |v| {
        if (!jsonStringEquals(v, expected_tarball)) {
            try appendViolation(gpa, violations, "{s}: `tarball_template` must be `{s}` (matches zig build release-pack)", .{ contract_path, expected_tarball });
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `tarball_template`", .{contract_path});
    }
    if (getField(parsed.value, "operator_fetch_script") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `operator_fetch_script` — delete it; tools/c-abi/fetch-c-abi.sh is hard-coded for operators", .{contract_path});
    }
    if (getField(parsed.value, "contract_path") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `contract_path` — delete it; packages must not ship monorepo paths", .{contract_path});
    }
    if (getField(parsed.value, "require_https")) |v| {
        if (v != .bool or v.bool != true) {
            try appendViolation(gpa, violations, "{s}: `require_https` must be true", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `require_https`", .{contract_path});
    }
    if (getField(parsed.value, "require_checksum")) |v| {
        if (v != .bool or v.bool != true) {
            try appendViolation(gpa, violations, "{s}: `require_checksum` must be true", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `require_checksum`", .{contract_path});
    }
    // Prerelease valve for hosted C archives (may be true after first publish).
    if (getField(parsed.value, "releases_published")) |v| {
        if (v != .bool) {
            try appendViolation(gpa, violations, "{s}: `releases_published` must be a bool", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `releases_published`", .{contract_path});
    }
    if (getField(parsed.value, "extract_prefix")) |v| {
        if (!jsonStringEquals(v, "lib")) {
            try appendViolation(gpa, violations, "{s}: `extract_prefix` must be `lib`", .{contract_path});
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `extract_prefix`", .{contract_path});
    }
    const required_strings = [_][]const u8{
        "default_release_base_url",
        "release_tag_template",
        "cache_layout",
        "version_header",
        "user_agent",
        "fallback_cache_name",
        "marker_static",
        "marker_shared_stem",
    };
    for (required_strings) |key| {
        const v = getField(parsed.value, key) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}`", .{ contract_path, key });
            continue;
        };
        if (v != .string) {
            try appendViolation(gpa, violations, "{s}: `{s}` must be a string", .{ contract_path, key });
        }
    }
    for ([_][]const u8{ "max_tarball_bytes", "max_sums_bytes" }) |key| {
        const v = getField(parsed.value, key) orelse {
            try appendViolation(gpa, violations, "{s}: missing `{s}`", .{ contract_path, key });
            continue;
        };
        if (v != .integer) {
            try appendViolation(gpa, violations, "{s}: `{s}` must be an integer", .{ contract_path, key });
        }
    }
    if (getField(parsed.value, "cache_layout")) |v| {
        if (!jsonStringEquals(v, "{cache_base}/{version}/{target}/lib")) {
            try appendViolation(gpa, violations, "{s}: `cache_layout` must be `{{cache_base}}/{{version}}/{{target}}/lib`", .{contract_path});
        }
    }
    // Frozen env truthy set lives in each loader helper, not the contract.
    if (getField(parsed.value, "truthy") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `truthy` field — delete it; loaders hardcode 1/true/yes", .{contract_path});
    }
    // Env name list is documentation in README; unpaid if shipped as JSON.
    if (getField(parsed.value, "env") != null) {
        try appendViolation(gpa, violations, "{s}: unpaid `env` field — delete it; document env names in bindings/README.md", .{contract_path});
    }

    // Header macros must match the contract pin; user_agent embeds the same version.
    if (abi_version) |want| {
        const header = root.readFileAlloc(io, "include/pancake_ocapn.h", gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "include/pancake_ocapn.h: failed to read for c-abi-resolve check with {s}", .{@errorName(err)});
            return;
        };
        defer gpa.free(header);
        const major = headerMacroU32(header, "PANCAKE_VERSION_MAJOR") orelse 0;
        const minor = headerMacroU32(header, "PANCAKE_VERSION_MINOR") orelse 0;
        const patch = headerMacroU32(header, "PANCAKE_VERSION_PATCH") orelse 0;
        var buf: [32]u8 = undefined;
        const got = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ major, minor, patch }) catch unreachable;
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: `abi_version` `{s}` must match include/pancake_ocapn.h `{s}`", .{ contract_path, want, got });
        }
        if (getField(parsed.value, "user_agent")) |ua| {
            switch (ua) {
                .string => |s| {
                    if (std.mem.indexOf(u8, s, want) == null) {
                        try appendViolation(gpa, violations, "{s}: `user_agent` must embed `abi_version` `{s}`", .{ contract_path, want });
                    }
                },
                else => {},
            }
        }
    }

    // Package copies must be byte-identical to the canonical contract.
    if (getField(parsed.value, "package_copies")) |copies_val| {
        switch (copies_val) {
            .array => |arr| {
                const canonical = root.readFileAlloc(io, contract_path, gpa, .limited(1 << 20)) catch |err| {
                    try appendViolation(gpa, violations, "{s}: failed to re-read for copy check with {s}", .{ contract_path, @errorName(err) });
                    return;
                };
                defer gpa.free(canonical);
                for (arr.items) |item| {
                    const copy_path = switch (item) {
                        .string => |s| s,
                        else => {
                            try appendViolation(gpa, violations, "{s}: `package_copies` entries must be strings", .{contract_path});
                            continue;
                        },
                    };
                    const copy = root.readFileAlloc(io, copy_path, gpa, .limited(1 << 20)) catch |err| {
                        try appendViolation(gpa, violations, "{s}: package copy missing ({s})", .{ copy_path, @errorName(err) });
                        continue;
                    };
                    defer gpa.free(copy);
                    if (!std.mem.eql(u8, copy, canonical)) {
                        try appendViolation(gpa, violations, "{s}: drifts from {s}; copy the canonical contract into the package", .{ copy_path, contract_path });
                    }
                }
            },
            else => try appendViolation(gpa, violations, "{s}: `package_copies` must be an array", .{contract_path}),
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `package_copies`", .{contract_path});
    }

    root.access(io, expected_operator_script, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: missing operator fetch script ({s})", .{ expected_operator_script, @errorName(err) });
    };

    const readme = root.readFileAlloc(io, "bindings/README.md", gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/README.md: failed to read for c-abi-resolve check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(readme);
    if (std.mem.indexOf(u8, readme, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must name `c-abi-resolve.json`", .{});
    }
    if (std.mem.indexOf(u8, readme, "ADR-0077") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must cite ADR-0077", .{});
    }
    if (std.mem.indexOf(u8, readme, "PANCAKE_STRICT") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must document `PANCAKE_STRICT`", .{});
    }
    if (std.mem.indexOf(u8, readme, "releases_published") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must document `releases_published`", .{});
    }
    if (std.mem.indexOf(u8, readme, "PANCAKE_DOWNLOAD") == null) {
        try appendViolation(gpa, violations, "bindings/README.md: Finding the archives must document `PANCAKE_DOWNLOAD`", .{});
    }

    const binding_loaders = c_abi_binding_loaders;
    // Shadow literals that must live only in the contract JSON (not loaders/script).
    const forbidden_shadows = [_][]const u8{
        "536870912",
        "536_870_912",
        "1048576",
        "pancake-c-abi-fetch/",
        "pancake-c-abi-cache",
        "pancake-c-v{version}-{target}.tar.gz",
        "https://github.com/jimisaacs/pancake/releases/download",
    };
    for (binding_loaders) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for c-abi-resolve check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "c-abi-resolve.json") == null) {
            try appendViolation(gpa, violations, "{s}: must load the package-shipped `c-abi-resolve.json` contract", .{path});
        }
        // Bindings must not depend on the monorepo operator script.
        if (std.mem.indexOf(u8, contents, "tools/c-abi/fetch-c-abi.sh") != null or
            std.mem.indexOf(u8, contents, "fetch-c-abi.sh") != null)
        {
            try appendViolation(gpa, violations, "{s}: must not shell out to `fetch-c-abi.sh` (ADR-0077: language-native download)", .{path});
        }
        if (std.mem.indexOf(u8, contents, "abi_version") == null and
            std.mem.indexOf(u8, contents, "PANCAKE_VERSION_MAJOR") == null)
        {
            try appendViolation(gpa, violations, "{s}: must read contract `abi_version` or header macros", .{path});
        }
        if (std.mem.indexOf(u8, contents, "SHA256") == null and std.mem.indexOf(u8, contents, "checksum") == null) {
            try appendViolation(gpa, violations, "{s}: must require checksum verification before extract", .{path});
        }
        if (std.mem.indexOf(u8, contents, "max_sums_bytes") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `max_sums_bytes`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "fallback_cache_name") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `fallback_cache_name`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "cache_layout") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `cache_layout`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "require_https") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `require_https`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "releases_published") == null) {
            try appendViolation(gpa, violations, "{s}: must read contract `releases_published`", .{path});
        }
        if (std.mem.indexOf(u8, contents, "PANCAKE_ALLOW_INSECURE") == null) {
            try appendViolation(gpa, violations, "{s}: must gate downloads with PANCAKE_ALLOW_INSECURE escape (ADR-0077 §5)", .{path});
        }
        // Fixed env truthy set (not a contract field).
        if (std.mem.indexOf(u8, contents, "\"1\"") == null or
            std.mem.indexOf(u8, contents, "\"true\"") == null or
            std.mem.indexOf(u8, contents, "\"yes\"") == null)
        {
            try appendViolation(gpa, violations, "{s}: env truthy helper must accept \"1\", \"true\", and \"yes\"", .{path});
        }
        // Marker roles: Rust static-links `.a`; dynamic loaders open shared libs.
        if (std.mem.eql(u8, path, "bindings/rust/build.rs")) {
            if (std.mem.indexOf(u8, contents, "marker_static") == null) {
                try appendViolation(gpa, violations, "{s}: must read contract `marker_static` for cache hits", .{path});
            }
            if (std.mem.indexOf(u8, contents, "marker_shared_stem") != null) {
                try appendViolation(gpa, violations, "{s}: must not use `marker_shared_stem` (static link uses marker_static)", .{path});
            }
            // Cargo cfg already emits release-pack arch/os names (no host alias map).
            if (std.mem.indexOf(u8, contents, "CARGO_CFG_TARGET_ARCH") == null or
                std.mem.indexOf(u8, contents, "CARGO_CFG_TARGET_OS") == null)
            {
                try appendViolation(gpa, violations, "{s}: host target must come from CARGO_CFG_TARGET_ARCH/OS (matches release-pack)", .{path});
            }
        } else {
            if (std.mem.indexOf(u8, contents, "marker_shared_stem") == null) {
                try appendViolation(gpa, violations, "{s}: must read contract `marker_shared_stem` for cache hits", .{path});
            }
            if (std.mem.indexOf(u8, contents, "marker_static") != null) {
                try appendViolation(gpa, violations, "{s}: must not use `marker_static` for cache hits (dynamic load uses marker_shared_stem)", .{path});
            }
            // Host alias → release-pack triple (see tools/c-abi/c-abi-host-aliases.json).
            if (std.mem.indexOf(u8, contents, "amd64") == null and
                std.mem.indexOf(u8, contents, "x64") == null)
            {
                try appendViolation(gpa, violations, "{s}: must normalize amd64/x64 → x86_64 for release-pack targets", .{path});
            }
            if (std.mem.indexOf(u8, contents, "aarch64") == null and std.mem.indexOf(u8, contents, "arm64") == null) {
                try appendViolation(gpa, violations, "{s}: must normalize arm64/aarch64 for release-pack targets", .{path});
            }
            if (std.mem.indexOf(u8, contents, "darwin") == null and
                std.mem.indexOf(u8, contents, "Darwin") == null and
                std.mem.indexOf(u8, contents, "macosx") == null)
            {
                try appendViolation(gpa, violations, "{s}: must normalize darwin/macosx → macos for release-pack targets", .{path});
            }
            // ADR-0077: refuse bare DLL names on Windows (search-order plant risk).
            if (std.mem.indexOf(u8, contents, "Windows refuses bare DLL") == null) {
                try appendViolation(gpa, violations, "{s}: must refuse bare DLL names on Windows (ADR-0077)", .{path});
            }
        }
        // Extract hygiene (ADR-0077 §5): reject links/traversal before extract.
        if (std.mem.eql(u8, path, "bindings/python/pancake/_lib_resolve.py")) {
            if (std.mem.indexOf(u8, contents, "issym") == null) {
                try appendViolation(gpa, violations, "{s}: must reject symlink/hardlink tar members (ADR-0077 §5)", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/ts/stack/internal/ffi/load.ts")) {
            if (std.mem.indexOf(u8, contents, "--no-same-owner") == null) {
                try appendViolation(gpa, violations, "{s}: tar extract must pass --no-same-owner (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "refusing link") == null and
                std.mem.indexOf(u8, contents, "refusing link tar member") == null)
            {
                try appendViolation(gpa, violations, "{s}: must reject symlink/hardlink tar members before extract (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "isDirectory") == null) {
                try appendViolation(gpa, violations, "{s}: extract success must require extract_prefix is a directory", .{path});
            }
            if (std.mem.indexOf(u8, contents, "corrupt or incomplete contract") == null and
                std.mem.indexOf(u8, contents, "throw err") == null)
            {
                try appendViolation(gpa, violations, "{s}: must not silently swallow a corrupt contract load", .{path});
            }
        } else {
            if (std.mem.indexOf(u8, contents, "--no-same-owner") == null) {
                try appendViolation(gpa, violations, "{s}: tar extract must pass --no-same-owner (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "refusing link") == null and
                std.mem.indexOf(u8, contents, "refusing link tar member") == null)
            {
                try appendViolation(gpa, violations, "{s}: must reject symlink/hardlink tar members before extract (ADR-0077 §5)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "--absolute-names") != null or
                std.mem.indexOf(u8, contents, " -P\n") != null or
                std.mem.indexOf(u8, contents, " -P ") != null)
            {
                try appendViolation(gpa, violations, "{s}: tar extract must not use -P/--absolute-names", .{path});
            }
        }
        if (std.mem.eql(u8, path, "bindings/rust/build.rs")) {
            if (std.mem.indexOf(u8, contents, "require_https must be true") == null) {
                try appendViolation(gpa, violations, "{s}: must hard-fail at load if require_https is not true", .{path});
            }
            if (std.mem.indexOf(u8, contents, "include_str!(\"c-abi-resolve.json\")") == null) {
                try appendViolation(gpa, violations, "{s}: must embed package-shipped c-abi-resolve.json via include_str!", .{path});
            }
            if (std.mem.indexOf(u8, contents, "serde_json") == null) {
                try appendViolation(gpa, violations, "{s}: must parse c-abi-resolve.json with serde_json (no hand-rolled scanner)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "fn json_string_field") != null) {
                try appendViolation(gpa, violations, "{s}: hand-rolled JSON scanner is deleted; use serde_json", .{path});
            }
        }
        if (std.mem.eql(u8, path, "bindings/racket/private/lib-resolve.rkt")) {
            if (std.mem.indexOf(u8, contents, "curl not on PATH") == null) {
                try appendViolation(gpa, violations, "{s}: must soft-fail when curl is missing (not silent skip)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "find-dev-root") == null or
                std.mem.indexOf(u8, contents, "zig-out-lib") == null)
            {
                try appendViolation(gpa, violations, "{s}: must discover zig-out via find-dev-root (no caller-hardcoded zig-out path)", .{path});
            }
            if (std.mem.indexOf(u8, contents, "hard-fail!") == null) {
                try appendViolation(gpa, violations, "{s}: must define hard-fail! for hygiene/checksum/HTTPS (ADR-0077)", .{path});
            }
        }
        if (std.mem.eql(u8, path, "bindings/python/pancake/_lib_resolve.py")) {
            if (std.mem.indexOf(u8, contents, "def _hard_fail") == null) {
                try appendViolation(gpa, violations, "{s}: must define _hard_fail for hygiene/checksum/HTTPS", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/ts/stack/internal/ffi/load.ts")) {
            if (std.mem.indexOf(u8, contents, "function hardFail") == null) {
                try appendViolation(gpa, violations, "{s}: must define hardFail for hygiene/checksum/HTTPS", .{path});
            }
        } else if (std.mem.eql(u8, path, "bindings/rust/build.rs")) {
            if (std.mem.indexOf(u8, contents, "fn hard_fail") == null) {
                try appendViolation(gpa, violations, "{s}: must define hard_fail for hygiene/checksum/HTTPS", .{path});
            }
        }
        for (forbidden_shadows) |lit| {
            if (std.mem.indexOf(u8, contents, lit) != null) {
                try appendViolation(gpa, violations, "{s}: hardcoded `{s}` — read from c-abi-resolve.json only", .{ path, lit });
            }
        }
    }

    // Racket per-archive loaders must not hardcode monorepo zig-out paths.
    const racket_ffi_loaders = [_][]const u8{
        "bindings/racket/private/ffi-ocapn.rkt",
        "bindings/racket/private/ffi-driver.rkt",
        "bindings/racket/private/ffi-tcp.rkt",
        "bindings/racket/private/ffi-inproc.rkt",
        "bindings/racket/private/ffi-iroh.rkt",
    };
    for (racket_ffi_loaders) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for zig-out path check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "define-runtime-path") != null and
            std.mem.indexOf(u8, contents, "zig-out") != null)
        {
            try appendViolation(gpa, violations, "{s}: must not hardcode zig-out via define-runtime-path; open-pancake-archive discovers it", .{path});
        }
        if (std.mem.indexOf(u8, contents, "open-pancake-archive") == null) {
            try appendViolation(gpa, violations, "{s}: must open archives through open-pancake-archive", .{path});
        }
        // Automatic FFI out cells (`(_ptr o …)`) lose values under concurrent
        // Racket green threads. Archive loaders must wrap outs with caller-owned
        // cells; the literal token is banned so the race cannot return.
        if (std.mem.indexOf(u8, contents, "(_ptr o") != null) {
            try appendViolation(gpa, violations, "{s}: automatic FFI out cells banned — wrap outs with call/out or wrap-out1 (caller-owned cells)", .{path});
        }
    }

    const script = root.readFileAlloc(io, expected_operator_script, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ expected_operator_script, @errorName(err) });
        return;
    };
    defer gpa.free(script);
    if (std.mem.indexOf(u8, script, "version_header") == null) {
        try appendViolation(gpa, violations, "{s}: must read abi version header path from contract `version_header`", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "jq -r") == null) {
        try appendViolation(gpa, violations, "{s}: must read fields from c-abi-resolve.json via jq", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, ".marker_static") == null or
        std.mem.indexOf(u8, script, ".marker_shared_stem") == null)
    {
        try appendViolation(gpa, violations, "{s}: cache-hit markers must come from c-abi-resolve.json", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "SHA256SUMS") == null) {
        try appendViolation(gpa, violations, "{s}: must attempt SHA256SUMS verification", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "checksum required") == null) {
        try appendViolation(gpa, violations, "{s}: must require checksum before extract", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "--no-same-owner") == null) {
        try appendViolation(gpa, violations, "{s}: must extract with --no-same-owner", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "refusing link") == null) {
        try appendViolation(gpa, violations, "{s}: must reject symlink/hardlink tar members before extract (ADR-0077 §5)", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "hard_fail") == null) {
        try appendViolation(gpa, violations, "{s}: must define hard_fail for hygiene/checksum/HTTPS (ADR-0077)", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "operator") == null and std.mem.indexOf(u8, script, "Operator") == null) {
        try appendViolation(gpa, violations, "{s}: must document that it is an operator/CI tool, not a binding dependency", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "releases_published") == null) {
        try appendViolation(gpa, violations, "{s}: must honor contract `releases_published`", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, ".require_https") == null or
        std.mem.indexOf(u8, script, ".require_checksum") == null)
    {
        try appendViolation(gpa, violations, "{s}: must jq-enforce require_https and require_checksum", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "1 | true | yes") == null and
        (std.mem.indexOf(u8, script, "\"1\"") == null or
            std.mem.indexOf(u8, script, "true") == null or
            std.mem.indexOf(u8, script, "yes") == null))
    {
        try appendViolation(gpa, violations, "{s}: env truthy helper must accept 1/true/yes", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "amd64") == null) {
        try appendViolation(gpa, violations, "{s}: must normalize amd64 → x86_64 for release-pack targets", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "arm64") == null and std.mem.indexOf(u8, script, "aarch64") == null) {
        try appendViolation(gpa, violations, "{s}: must normalize arm64/aarch64 for release-pack targets", .{expected_operator_script});
    }
    if (std.mem.indexOf(u8, script, "Darwin") == null and std.mem.indexOf(u8, script, "darwin") == null) {
        try appendViolation(gpa, violations, "{s}: must normalize Darwin → macos for release-pack targets", .{expected_operator_script});
    }
    for (forbidden_shadows) |lit| {
        if (std.mem.indexOf(u8, script, lit) != null) {
            try appendViolation(gpa, violations, "{s}: hardcoded `{s}` — read from c-abi-resolve.json only", .{ expected_operator_script, lit });
        }
    }

    // Package-ship surfaces: contract must be reachable from published packages.
    const pyproject = root.readFileAlloc(io, "bindings/python/pyproject.toml", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pyproject);
    if (std.mem.indexOf(u8, pyproject, "c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/python/pyproject.toml: package-data must ship c-abi-resolve.json", .{});
    }
    const deno_json = root.readFileAlloc(io, "bindings/ts/stack/deno.json", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/ts/stack/deno.json: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(deno_json);
    if (std.mem.indexOf(u8, deno_json, "c-abi-resolve.json") == null or
        std.mem.indexOf(u8, deno_json, "\"publish\"") == null)
    {
        try appendViolation(gpa, violations, "bindings/ts/stack/deno.json: publish.include must ship c-abi-resolve.json", .{});
    }
    const racket_info = root.readFileAlloc(io, "bindings/racket/info.rkt", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: failed to read with {s} (package-ship surface)", .{@errorName(err)});
        return;
    };
    defer gpa.free(racket_info);
    if (std.mem.indexOf(u8, racket_info, "private/c-abi-resolve.json") == null) {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: must name private/c-abi-resolve.json as a must-ship package path", .{});
    }
    if (std.mem.indexOf(u8, racket_info, "compile-omit-paths") == null) {
        try appendViolation(gpa, violations, "bindings/racket/info.rkt: must declare compile-omit-paths (and not omit the resolve contract)", .{});
    }

    // Shared resolve-cases oracle: derive URL/cache/want_fetch from the
    // canonical contract templates and pin cases (apex vs five-spine drift).
    try checkCAbiResolveCases(io, gpa, root, violations, parsed.value);

    // Shared host-target alias fixture: every listed alias must appear in
    // EACH non-cargo normalizer (per-port honesty — not a union corpus).
    // Rust uses CARGO_CFG_* and is skipped; operator script is included.
    const host_aliases_fixture = "tools/c-abi/c-abi-host-aliases.json";
    var aliases_parsed = try parseJsonFile(io, gpa, root, violations, host_aliases_fixture) orelse return;
    defer aliases_parsed.deinit();
    const alias_ports = c_abi_binding_loaders[1..] ++ [_][]const u8{expected_operator_script};
    if (getField(aliases_parsed.value, "host_aliases")) |aliases_val| {
        switch (aliases_val) {
            .object => |obj| {
                for (alias_ports) |path| {
                    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                        try appendViolation(gpa, violations, "{s}: failed to read for host-alias check with {s}", .{ path, @errorName(err) });
                        continue;
                    };
                    defer gpa.free(contents);
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        switch (entry.value_ptr.*) {
                            .array => |arr| {
                                for (arr.items) |item| {
                                    const alias = switch (item) {
                                        .string => |s| s,
                                        else => continue,
                                    };
                                    if (std.mem.indexOf(u8, contents, alias) == null) {
                                        try appendViolation(gpa, violations, "{s}: host alias `{s}` missing from {s}", .{ host_aliases_fixture, alias, path });
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => try appendViolation(gpa, violations, "{s}: `host_aliases` must be an object", .{host_aliases_fixture}),
        }
    } else {
        try appendViolation(gpa, violations, "{s}: missing `host_aliases`", .{host_aliases_fixture});
    }
    if (getField(aliases_parsed.value, "release_pack_names")) |rpn| {
        switch (rpn) {
            .object => |obj| {
                if (obj.get("oses")) |oses| {
                    switch (oses) {
                        .array => |arr| {
                            for (arr.items) |item| {
                                const os_name = switch (item) {
                                    .string => |s| s,
                                    else => continue,
                                };
                                if (std.mem.eql(u8, os_name, "windows")) {
                                    try appendViolation(gpa, violations, "{s}: release_pack_names.oses must not list windows until release.yml has a Windows leg", .{host_aliases_fixture});
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    if (std.mem.indexOf(u8, readme, "c-abi-host-aliases") == null and
        std.mem.indexOf(u8, readme, "CARGO_CFG_TARGET") == null)
    {
        try appendViolation(gpa, violations, "bindings/README.md: must document release-pack target triples / cargo cfg posture", .{});
    }

    // release.yml must gate `gh release create` on the contract valve.
    const release_workflow = ".github/workflows/release.yml";
    const workflow = root.readFileAlloc(io, release_workflow, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ release_workflow, @errorName(err) });
        return;
    };
    defer gpa.free(workflow);
    if (std.mem.indexOf(u8, workflow, "releases_published") == null) {
        try appendViolation(gpa, violations, "{s}: must gate publish on contract `releases_published`", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "gh release create") == null) {
        try appendViolation(gpa, violations, "{s}: must still contain `gh release create` for the tag path", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "jq") == null or
        std.mem.indexOf(u8, workflow, ".releases_published == true") == null)
    {
        try appendViolation(gpa, violations, "{s}: must jq-check `.releases_published == true` before publish", .{release_workflow});
    }
    if (std.mem.indexOf(u8, workflow, "workflow_dispatch") == null) {
        try appendViolation(gpa, violations, "{s}: must offer workflow_dispatch for dry-run archive builds", .{release_workflow});
    }

    // Extract matrix apex: hermetic refuse fixtures must stay wired.
    const extract_matrix = "tools/c-abi/c-abi-extract-matrix.sh";
    const matrix = root.readFileAlloc(io, extract_matrix, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ extract_matrix, @errorName(err) });
        return;
    };
    defer gpa.free(matrix);
    for ([_][]const u8{ "refusing unsafe", "refusing link", "python", "deno", "hard_fail", "hard-fail!" }) |needle| {
        if (std.mem.indexOf(u8, matrix, needle) == null) {
            try appendViolation(gpa, violations, "{s}: must exercise `{s}` in the hermetic extract matrix", .{ extract_matrix, needle });
        }
    }
    const boundaries = root.readFileAlloc(io, "docs/boundaries.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "docs/boundaries.md: failed to read for ADR-0077 packaging edge with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(boundaries);
    if (std.mem.indexOf(u8, boundaries, "ADR-0077") == null or
        std.mem.indexOf(u8, boundaries, "c-abi-resolve.json") == null)
    {
        try appendViolation(gpa, violations, "docs/boundaries.md: must name ADR-0077 publishable C-ABI resolve / c-abi-resolve.json", .{});
    }
}

fn applyContractTemplate(allocator: std.mem.Allocator, tmpl: []const u8, version: []const u8, target: []const u8, cache_base: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, tmpl);
    errdefer allocator.free(out);
    // Replace longest placeholders first so nested names cannot collide.
    inline for (.{ "{cache_base}", "{version}", "{target}" }) |needle| {
        const replacement = switch (needle[1]) {
            'c' => cache_base,
            'v' => version,
            't' => target,
            else => unreachable,
        };
        if (std.mem.indexOf(u8, out, needle) != null) {
            const next = try std.mem.replaceOwned(u8, allocator, out, needle, replacement);
            allocator.free(out);
            out = next;
        }
    }
    return out;
}

fn envTruthyFromObject(env_obj: ?std.json.ObjectMap, name: []const u8) bool {
    const obj = env_obj orelse return false;
    const v = obj.get(name) orelse return false;
    const s = switch (v) {
        .string => |str| str,
        else => return false,
    };
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return false;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..s.len];
    return std.mem.eql(u8, lower, "1") or std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "yes");
}

fn checkCAbiResolveCases(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    contract: std.json.Value,
) !void {
    const cases_path = "tools/c-abi/c-abi-resolve-cases.json";
    var cases_doc = try parseJsonFile(io, gpa, root, violations, cases_path) orelse return;
    defer cases_doc.deinit();

    const default_base = blk: {
        const v = getField(contract, "default_release_base_url") orelse {
            try appendViolation(gpa, violations, "{s}: contract missing default_release_base_url for resolve-cases", .{cases_path});
            return;
        };
        break :blk switch (v) {
            .string => |s| s,
            else => {
                try appendViolation(gpa, violations, "{s}: default_release_base_url must be a string", .{cases_path});
                return;
            },
        };
    };
    const tag_tmpl = blk: {
        const v = getField(contract, "release_tag_template") orelse return;
        break :blk switch (v) {
            .string => |s| s,
            else => return,
        };
    };
    const tarball_tmpl = blk: {
        const v = getField(contract, "tarball_template") orelse return;
        break :blk switch (v) {
            .string => |s| s,
            else => return,
        };
    };
    const cache_tmpl = blk: {
        const v = getField(contract, "cache_layout") orelse return;
        break :blk switch (v) {
            .string => |s| s,
            else => return,
        };
    };

    const cases_val = getField(cases_doc.value, "cases") orelse {
        try appendViolation(gpa, violations, "{s}: missing `cases`", .{cases_path});
        return;
    };
    const cases = switch (cases_val) {
        .array => |arr| arr,
        else => {
            try appendViolation(gpa, violations, "{s}: `cases` must be an array", .{cases_path});
            return;
        },
    };

    for (cases.items) |case_val| {
        const case_obj = switch (case_val) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (case_obj.get("id") orelse continue) {
            .string => |s| s,
            else => "?",
        };
        const version = switch (case_obj.get("version") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const target = switch (case_obj.get("target") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const cache_base = switch (case_obj.get("cache_base") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const releases_published = switch (case_obj.get("releases_published") orelse continue) {
            .bool => |b| b,
            else => continue,
        };
        const want_fetch = switch (case_obj.get("want_fetch") orelse continue) {
            .bool => |b| b,
            else => continue,
        };
        const want_url = switch (case_obj.get("url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const want_cache = switch (case_obj.get("cache_lib") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const want_sums = switch (case_obj.get("sums_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const env_obj: ?std.json.ObjectMap = blk: {
            const v = case_obj.get("env") orelse break :blk null;
            break :blk switch (v) {
                .object => |o| o,
                else => null,
            };
        };

        const skip = envTruthyFromObject(env_obj, "PANCAKE_SKIP_DOWNLOAD");
        const download = envTruthyFromObject(env_obj, "PANCAKE_DOWNLOAD");
        const got_fetch = if (releases_published) !skip else download;
        if (got_fetch != want_fetch) {
            try appendViolation(gpa, violations, "{s}: case `{s}` want_fetch mismatch", .{ cases_path, id });
        }

        const base = blk: {
            if (env_obj) |o| {
                if (o.get("PANCAKE_RELEASE_BASE_URL")) |v| {
                    switch (v) {
                        .string => |s| break :blk s,
                        else => {},
                    }
                }
            }
            break :blk default_base;
        };
        const tag = try applyContractTemplate(gpa, tag_tmpl, version, target, cache_base);
        defer gpa.free(tag);
        const tarball = try applyContractTemplate(gpa, tarball_tmpl, version, target, cache_base);
        defer gpa.free(tarball);
        const cache_lib = try applyContractTemplate(gpa, cache_tmpl, version, target, cache_base);
        defer gpa.free(cache_lib);

        const got_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ base, tag, tarball });
        defer gpa.free(got_url);
        if (!std.mem.eql(u8, got_url, want_url)) {
            try appendViolation(gpa, violations, "{s}: case `{s}` url want `{s}` got `{s}`", .{ cases_path, id, want_url, got_url });
        }
        const got_sums = try std.fmt.allocPrint(gpa, "{s}/{s}/SHA256SUMS", .{ base, tag });
        defer gpa.free(got_sums);
        if (!std.mem.eql(u8, got_sums, want_sums)) {
            try appendViolation(gpa, violations, "{s}: case `{s}` sums_url want `{s}` got `{s}`", .{ cases_path, id, want_sums, got_sums });
        }
        if (!std.mem.eql(u8, cache_lib, want_cache)) {
            try appendViolation(gpa, violations, "{s}: case `{s}` cache_lib want `{s}` got `{s}`", .{ cases_path, id, want_cache, cache_lib });
        }
    }

    // Loaders must still implement the same want_fetch / template verbs.
    const resolve_ports = c_abi_binding_loaders ++ [_][]const u8{"tools/c-abi/fetch-c-abi.sh"};
    for (resolve_ports) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "releases_published") == null) {
            try appendViolation(gpa, violations, "{s}: resolve port must honor releases_published", .{path});
        }
    }
}

fn headerMacroU32(text: []const u8, name: []const u8) ?u32 {
    var prefix_buf: [96]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "#define {s} ", .{name}) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const rest = std.mem.trim(u8, trimmed[prefix.len..], " \t\r");
            return std.fmt.parseInt(u32, rest, 10) catch null;
        }
    }
    return null;
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

const HumanDocVoiceBan = struct {
    needle: []const u8,
    why: []const u8,
};

/// Human first-read docs must stay speech for people (doc-voice), not executor
/// scaffolding. CapTP vocabulary cheat-sheets ("sticky notes") belong in
/// `.agents/rules/architecture.md`. ADRs under `docs/decisions/` and `.agents/**`
/// are out of scope on purpose. `CONTRIBUTING.md` may link `.agents/` because it
/// is the contributor router, not a product first-read page.
fn checkHumanDocVoice(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const banned_phrases = [_]HumanDocVoiceBan{
        .{ .needle = "CapTP sticky note", .why = "CapTP vocabulary cheat-sheets live in the architecture agent rule, not human docs (doc-voice)" },
        .{ .needle = "Meta scaffolding", .why = "agent scaffolding vocabulary belongs under `.agents/`, not human inventory (doc-voice)" },
        .{ .needle = "deliberately boring", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "boring on purpose", .why = "self-awarded praise; state the surface plainly (doc-voice)" },
        .{ .needle = "next audit", .why = "executor framing; write for a human re-read (doc-voice)" },
    };

    const fixed_product = [_][]const u8{
        "README.md",
        "SECURITY.md",
        "bindings/README.md",
        "bindings/rust/README.md",
        "bindings/ts/README.md",
        "bindings/python/README.md",
        "bindings/racket/README.md",
        "examples/README.md",
        "apps/README.md",
    };
    for (fixed_product) |path| {
        try banHumanDocVoiceInFile(io, gpa, root, violations, path, &banned_phrases, true, true);
    }
    // Contributor / operator routers: sticky-note and praise bans apply; `.agents/`
    // links are allowed (they point contributors at executor rules and skills).
    try banHumanDocVoiceInFile(io, gpa, root, violations, "CONTRIBUTING.md", &banned_phrases, true, false);
    try banHumanDocVoiceInFile(io, gpa, root, violations, ".devcontainer/README.md", &banned_phrases, true, false);

    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for human-doc-voice check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_it = docs.iterate();
    while (try docs_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fmt.allocPrint(gpa, "docs/{s}", .{entry.name});
        defer gpa.free(path);
        try banHumanDocVoiceInFile(io, gpa, root, violations, path, &banned_phrases, false, true);
    }

    try banHumanDocVoiceUnder(io, gpa, root, violations, "docs/protocol-diagrams", ".md", &banned_phrases, true);
    try banHumanDocVoiceUnder(io, gpa, root, violations, "site/content", ".smd", &banned_phrases, true);
}

fn banHumanDocVoiceUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
    suffix: []const u8,
    banned_phrases: []const HumanDocVoiceBan,
    ban_agents_links: bool,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for human-doc-voice check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, suffix)) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        try banHumanDocVoiceInFile(io, gpa, root, violations, path, banned_phrases, false, ban_agents_links);
    }
}

fn banHumanDocVoiceInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    banned_phrases: []const HumanDocVoiceBan,
    optional: bool,
    ban_agents_links: bool,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        if (optional and err == error.FileNotFound) return;
        try appendViolation(gpa, violations, "{s}: failed to read for human-doc-voice check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    for (banned_phrases) |ban| {
        if (std.ascii.indexOfIgnoreCase(contents, ban.needle) != null) {
            try appendViolation(gpa, violations, "{s}: contains `{s}` — {s}", .{ path, ban.needle, ban.why });
        }
    }
    if (ban_agents_links and std.mem.indexOf(u8, contents, ".agents/") != null) {
        try appendViolation(gpa, violations, "{s}: links into `.agents/` — agent scaffolding stays under `.agents/**`; human docs state the rule in speech (doc-voice)", .{path});
    }
    try banConnectiveArrowOutsideFences(gpa, violations, path, contents);
}

/// Arrow connective tissue in running prose (`miss→break`, `N→1`) is a doc-voice
/// tell. Fenced code and ASCII `->` diagrams may keep arrows; Unicode `→`/`⇒`
/// stay inside fences on human first-read paths.
fn banConnectiveArrowOutsideFences(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var in_fence = false;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= contents.len) : (i += 1) {
        const at_end = i == contents.len;
        const at_nl = !at_end and contents[i] == '\n';
        if (!at_end and !at_nl) continue;
        const line = contents[line_start..i];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
        } else if (!in_fence) {
            if (std.mem.indexOf(u8, line, "→") != null or std.mem.indexOf(u8, line, "⇒") != null) {
                try appendViolation(gpa, violations, "{s}: connective arrow in prose — write a verb (`becomes`, `then`, `to`) instead of `→`/`⇒` (doc-voice)", .{path});
                return;
            }
        }
        line_start = i + 1;
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
/// pass, identifier boundaries), so `pancake_host_session_feed` cannot satisfy
/// `pancake_host_session_feed_bytes`.
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

/// CapTP `PANCAKE_EVENT_*` kinds (except `NONE`) must have a peer send constructor
/// in `pancake_ocapn.h`, or an explicit allowlist reason. Renamed constructors
/// (start_session, handoff deposit/withdraw/resolve-give) count; LISTEN is
/// allowlisted as engine-synthesized / inbound-only. Adding an event without a
/// send or allowlist row fails this check.
fn checkPeerEventSendParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/pancake_ocapn.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for event/send parity with {s}", .{ header_path, @errorName(err) });
        return;
    };
    defer gpa.free(header);

    const Row = struct {
        event: []const u8,
        send: ?[]const u8 = null,
        also: []const []const u8 = &.{},
        allowlist: ?[]const u8 = null,
    };
    const rows = [_]Row{
        .{ .event = "DELIVER", .send = "pancake_peer_send_deliver" },
        .{ .event = "RESOLVE", .send = "pancake_peer_send_resolve" },
        .{ .event = "GC_EXPORT", .send = "pancake_peer_send_gc_export" },
        .{ .event = "GC_ANSWER", .send = "pancake_peer_send_gc_answer" },
        .{ .event = "HANDOFF", .also = &.{
            "pancake_peer_send_deposit_gift",
            "pancake_peer_send_withdraw_gift",
            "pancake_peer_send_resolve_handoff_give",
        } },
        .{ .event = "START_SESSION", .send = "pancake_peer_start_session" },
        .{ .event = "ABORT", .send = "pancake_peer_send_abort" },
        .{ .event = "LISTEN", .allowlist = "engine-synthesized / inbound install; not an app send at the peer ABI" },
        .{ .event = "GET", .send = "pancake_peer_send_get" },
        .{ .event = "INDEX", .send = "pancake_peer_send_index" },
        .{ .event = "UNTAG", .send = "pancake_peer_send_untag" },
    };

    var seen_events = std.StringHashMap(void).init(gpa);
    defer seen_events.deinit();

    var rest = header;
    const event_needle = "#define PANCAKE_EVENT_";
    while (std.mem.indexOf(u8, rest, event_needle)) |start| {
        const after = rest[start + event_needle.len ..];
        const line_end = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
        const line = after[0..line_end];
        rest = after[line_end..];
        const name_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const suffix = line[0..name_end];
        if (std.mem.eql(u8, suffix, "NONE")) continue;
        try seen_events.put(suffix, {});

        var matched_row: ?Row = null;
        for (rows) |row| {
            if (std.mem.eql(u8, row.event, suffix)) {
                matched_row = row;
                break;
            }
        }
        const row = matched_row orelse {
            try appendViolation(gpa, violations, "{s}: PANCAKE_EVENT_{s} has no peer send/allowlist row in checkPeerEventSendParity — add pancake_peer_send_* or an allowlist reason", .{ header_path, suffix });
            continue;
        };
        if (row.allowlist != null) continue;

        var ok = false;
        if (row.send) |send_name| {
            if (std.mem.indexOf(u8, header, send_name) != null) ok = true;
        }
        for (row.also) |alt| {
            if (std.mem.indexOf(u8, header, alt) != null) ok = true;
        }
        if (!ok) {
            if (row.send) |send_name| {
                try appendViolation(gpa, violations, "{s}: PANCAKE_EVENT_{s} needs `{s}` (or a listed alternate) in the header, or an allowlist reason in checkPeerEventSendParity", .{ header_path, suffix, send_name });
            } else {
                try appendViolation(gpa, violations, "{s}: PANCAKE_EVENT_{s} needs one of its alternate send constructors in the header, or an allowlist reason in checkPeerEventSendParity", .{ header_path, suffix });
            }
        }
    }

    for (rows) |row| {
        if (!seen_events.contains(row.event)) {
            try appendViolation(gpa, violations, "{s}: checkPeerEventSendParity lists EVENT_{s} but the header has no PANCAKE_EVENT_{s} — drop the stale row", .{ header_path, row.event, row.event });
        }
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
/// the four language bindings each hand-roll the executor arm set in a named
/// `action` module (decode/types are generated). Grep-level: the header's
/// action name must appear as `HOST_ACTION_<NAME>` (or `HOST-ACTION-<NAME>` in
/// Racket) in the action module. A new kind without a binding arm fails
/// `zig build meta-check`.
///
/// Racket's drain `case` arms use lowercase kebab symbols (`[(close)`, …);
/// those must appear in `action.rkt` (otherwise a decode-only module still
/// passes while the drain silently drops the new kind).
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

    const drains = [_]struct {
        paths: []const []const u8,
        sep: u8,
        /// When set, each action must also appear as `[(kebab-name)` in this file
        /// (Racket's symbol-form drain switch).
        racket_symbol_path: ?[]const u8 = null,
        /// When set, each action must appear as `HostAction::<Pascal>` (Rust) or
        /// `case <Pascal>` (Python) in this file. Gen-only kind tokens do not
        /// satisfy the executor gate.
        variant_path: ?[]const u8 = null,
        /// Prefix before the PascalCase variant (`HostAction::` or `case `).
        variant_prefix: []const u8 = "",
    }{
        // Kind inventory may live in the generated dispatch file; executor I/O
        // stays in action.* (ticket-only dial, flush, …). Union of paths must
        // cover every PANCAKE_HOST_ACTION_*.
        .{
            .paths = &.{
                "bindings/ts/stack/action.ts",
                "bindings/ts/stack/internal/host_action.ts",
            },
            .sep = '_',
        },
        .{
            .paths = &.{
                "bindings/python/pancake/_action.py",
                "bindings/python/pancake/_host_action_gen.py",
            },
            .sep = '_',
            .variant_path = "bindings/python/pancake/_host_action_gen.py",
            .variant_prefix = "case ",
        },
        .{
            .paths = &.{
                "bindings/rust/src/action.rs",
                "bindings/rust/src/host_action_gen.rs",
            },
            .sep = '_',
            .variant_path = "bindings/rust/src/host_action_gen.rs",
            .variant_prefix = "HostAction::",
        },
        .{
            .paths = &.{
                "bindings/racket/private/action.rkt",
                "bindings/racket/private/host-action-gen.rkt",
            },
            .sep = '-',
            .racket_symbol_path = "bindings/racket/private/action.rkt",
        },
    };

    var token_buf: [128]u8 = undefined;
    var symbol_buf: [128]u8 = undefined;
    var variant_buf: [128]u8 = undefined;
    for (drains) |drain| {
        var contents_list: std.ArrayList([]u8) = .empty;
        defer {
            for (contents_list.items) |buf| gpa.free(buf);
            contents_list.deinit(gpa);
        }
        for (drain.paths) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for host-action drain check with {s}", .{ path, @errorName(err) });
                continue;
            };
            try contents_list.append(gpa, contents);
        }
        if (contents_list.items.len == 0) continue;

        const label = drain.paths[0];
        const sym_contents: ?[]u8 = if (drain.racket_symbol_path) |sym_path| blk: {
            break :blk root.readFileAlloc(io, sym_path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for host-action symbol-arm check with {s}", .{ sym_path, @errorName(err) });
                break :blk null;
            };
        } else null;
        defer if (sym_contents) |buf| gpa.free(buf);

        const variant_contents: ?[]u8 = if (drain.variant_path) |vpath| blk: {
            break :blk root.readFileAlloc(io, vpath, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for host-action variant check with {s}", .{ vpath, @errorName(err) });
                break :blk null;
            };
        } else null;
        defer if (variant_contents) |buf| gpa.free(buf);

        for (action_names.items) |name| {
            if (drain.variant_path) |vpath| {
                const contents = variant_contents orelse continue;
                // `HostAction::NeedGiftId` / `case NeedGiftId` from NEED_GIFT_ID.
                const prefix = drain.variant_prefix;
                if (prefix.len + name.len > variant_buf.len) {
                    try appendViolation(gpa, violations, "{s}: host-action name `{s}` too long for variant buffer", .{ header_path, name });
                    continue;
                }
                @memcpy(variant_buf[0..prefix.len], prefix);
                var n: usize = prefix.len;
                var cap = true;
                for (name) |c| {
                    if (c == '_') {
                        cap = true;
                        continue;
                    }
                    variant_buf[n] = if (cap) std.ascii.toUpper(c) else std.ascii.toLower(c);
                    n += 1;
                    cap = false;
                }
                const variant = variant_buf[0..n];
                if (std.mem.indexOf(u8, contents, variant) == null) {
                    try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` arm (from PANCAKE_HOST_ACTION_{s})", .{ vpath, variant, name });
                }
                continue;
            }

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
            var found = false;
            for (contents_list.items) |contents| {
                if (std.mem.indexOf(u8, contents, token) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` (from PANCAKE_HOST_ACTION_{s})", .{ label, token, name });
            }

            if (drain.racket_symbol_path) |sym_path| {
                const contents = sym_contents orelse continue;
                // `'kebab-name` — hash key in `host-dispatch-action!` handlers.
                if (1 + name.len > symbol_buf.len) {
                    try appendViolation(gpa, violations, "{s}: host-action name `{s}` too long for racket-symbol buffer", .{ header_path, name });
                    continue;
                }
                symbol_buf[0] = '\'';
                for (name, 0..) |c, i| {
                    symbol_buf[1 + i] = if (c == '_') '-' else std.ascii.toLower(c);
                }
                const symbol = symbol_buf[0 .. 1 + name.len];
                if (std.mem.indexOf(u8, contents, symbol) == null) {
                    try appendViolation(gpa, violations, "{s}: host-action drain missing `{s}` handler (from PANCAKE_HOST_ACTION_{s})", .{ sym_path, symbol, name });
                }
            }
        }
    }
}

/// Binding spine Pass 2: each binding keeps a named `action` module for
/// decode+execute, imports the generated HostAction decode, and does not
/// hand-roll a kind switch in the Host file. Grep-level — catches silent
/// deletes and decode drift back into host.*.
fn checkBindingHostActionSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const action_mods = [_]struct {
        path: []const u8,
        decode_import: []const u8,
        /// Executor markers that must appear in the action module (I/O arms).
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/action.ts",
            .decode_import = "decodeHostAction",
            .markers = &.{
                "dispatchHostAction",
                "runDialTicket",
                "flushOutbound",
                "pancake_host_provide_gift_id",
                "settleVow",
                "closeTransport",
            },
        },
        .{
            .path = "bindings/python/pancake/_action.py",
            .decode_import = "decode",
            .markers = &.{
                "dispatch",
                "run_dial_ticket",
                "flush_outbound",
                "pancake_host_provide_gift_id",
                "settle_vow",
                "close_transport",
            },
        },
        .{
            .path = "bindings/rust/src/action.rs",
            .decode_import = "host_action_gen",
            .markers = &.{
                "host_action_gen::dispatch",
                "run_dial_ticket",
                "flush_outbound",
                "pancake_host_provide_gift_id",
                "settle_vow",
                "close_transport",
            },
        },
        .{
            .path = "bindings/racket/private/action.rkt",
            .decode_import = "host-decode-action!",
            .markers = &.{
                "host-dispatch-action!",
                "run-dial!",
                "drain-outbound!",
                "host-provide-gift-id!",
                "settle-vow!",
                "session-close!",
            },
        },
    };
    // Generated dispatch inventory must stay live in each language's gen file.
    try expectFileContains(io, gpa, root, violations, "bindings/ts/stack/internal/host_action.ts", &.{
        "dispatchHostAction",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/pancake/_host_action_gen.py", &.{
        "async def dispatch",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/host_action_gen.rs", &.{
        "pub async fn dispatch",
        "trait HostActionHandlers",
    });
    // Generated inventory must stay live — allow(dead_code) on dispatch is a half-land.
    if (try fileContains(io, gpa, root, "bindings/rust/src/host_action_gen.rs", "#[allow(dead_code)]")) {
        try appendViolation(gpa, violations, "bindings/rust/src/host_action_gen.rs: #[allow(dead_code)] must stay deleted — action.rs must call dispatch", .{});
    }
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/host-action-gen.rkt", &.{
        "host-dispatch-action!",
    });
    // Ticket-only DIAL: each dial module borrows the pending view (no URI re-parse).
    try expectFileContains(io, gpa, root, violations, "bindings/ts/stack/dial.ts", &.{
        "pancake_host_pending_dial",
        "runDialTicket",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/python/pancake/_dial.py", &.{
        "pancake_host_pending_dial",
        "run_dial_ticket",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/rust/src/dial.rs", &.{
        "pancake_host_pending_dial",
        "run_dial_ticket",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/racket/private/dial.rkt", &.{
        "pancake_host_pending_dial",
        "run-dial!",
    });
    // Shared codec order spine: both encode paths must import codec_order.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/syrup/encode.zig", &.{
        "@import(\"codec_order\")",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/capnp/encode.zig", &.{
        "@import(\"codec_order\")",
    });
    // Stale ticket-only DIAL contract prose must not return in the C header source.
    for ([_][]const u8{
        "action's transport",
        "the same pieces a DIAL action carries",
        "dial the exporter at locator",
        "at locator, then report",
        "fields stay zeroed for layout stability",
    }) |needle| {
        if (try fileContains(io, gpa, root, "tools/gen/header/driver.zig", needle)) {
            try appendViolation(gpa, violations, "tools/gen/header/driver.zig: stale DIAL prose `{s}` — ticket-only; pendingDial owns the URI", .{needle});
        }
        if (try fileContains(io, gpa, root, "include/pancake_driver.h", needle)) {
            try appendViolation(gpa, violations, "include/pancake_driver.h: stale DIAL prose `{s}` — regenerate from ticket-only contract", .{needle});
        }
        if (try fileContains(io, gpa, root, "src/c_abi/driver/mod.zig", needle)) {
            try appendViolation(gpa, violations, "src/c_abi/driver/mod.zig: stale DIAL prose `{s}` — ticket-only; drop dead locator fields", .{needle});
        }
    }
    // Dead dial-view fields must stay deleted on PancakeHostAction (parts live
    // on PancakePendingDial only — no verbatim locator field).
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/mod.zig", &.{
        \\pub const PancakeHostAction = extern struct {
        \\    kind: u32,
        \\    ticket: u64,
        \\    session: ?*PancakeHostSession,
        \\    value: shared.PancakeArgument,
        \\    message: ?[*]const u8,
        \\    message_len: usize,
        \\};
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/mod.zig", &.{
        \\pub const PancakePendingDial = extern struct {
        \\    transport: ?[*]const u8,
        \\    transport_len: usize,
        \\    designator: ?[*]const u8,
        \\    designator_len: usize,
        \\    hint: ?[*]const u8,
        \\    hint_len: usize,
        \\};
    });
    // Verbatim locator must stay deleted from pending dial views (parts alone).
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "pub const PendingDialView = struct {\n        locator:")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: PendingDialView must not carry locator — transport/designator/hint only", .{});
    }
    if (try fileContains(io, gpa, root, "src/c_abi/driver/host.zig", ".locator = view.locator")) {
        try appendViolation(gpa, violations, "src/c_abi/driver/host.zig: pancake_host_pending_dial must not fill a locator field", .{});
    }
    // One TCP host:port admission; DialResolver / planDial compose it.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/uri.zig", &.{
        "pub fn tcpConnectHostPort",
        "pub fn firstDirectAddress",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/transport/tcp.zig", &.{
        "tcpConnectHostPort",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/dial_plan.zig", &.{
        "tcpConnectHostPort",
        "peer_id:",
    });
    // TS pump-hooks layout comes from gen-ts-abi, not a hand mirror in action.ts.
    try expectFileContains(io, gpa, root, violations, "bindings/ts/stack/internal/abi.ts", &.{
        "HOST_PUMP_HOOKS_SIZE",
        "HOST_PUMP_HOOKS_DIAL_OFF",
    });
    if (try fileContains(io, gpa, root, "bindings/ts/stack/action.ts", "const HOST_PUMP_HOOKS_SIZE")) {
        try appendViolation(gpa, violations, "bindings/ts/stack/action.ts: HOST_PUMP_HOOKS_* must come from abi.ts (gen-ts-abi)", .{});
    }
    for (action_mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — HostAction action module (binding spine Pass 2)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host-action spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, mod.decode_import) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — must use generated HostAction decode", .{ mod.path, mod.decode_import });
        }
        for (mod.markers) |marker| {
            if (std.mem.indexOf(u8, contents, marker) == null) {
                try appendViolation(gpa, violations, "{s}: host-action executor missing `{s}`", .{ mod.path, marker });
            }
        }
    }

    const generated = [_][]const u8{
        "bindings/ts/stack/internal/host_action.ts",
        "bindings/python/pancake/_host_action_gen.py",
        "bindings/rust/src/host_action_gen.rs",
        "bindings/racket/private/host-action-gen.rkt",
    };
    for (generated) |path| {
        root.access(io, path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — generated HostAction decode (run `zig build gen-binding-host-action`)", .{path});
        };
    }

    // Host files must not hand-roll a kind decode switch: no HOST_ACTION_* /
    // HOST-ACTION-* discriminant match outside the action + generated modules.
    const hosts = [_]struct { path: []const u8, banned: []const u8 }{
        .{ .path = "bindings/ts/stack/host.ts", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/python/pancake/_host.py", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/rust/src/host.rs", .banned = "HOST_ACTION_" },
        .{ .path = "bindings/racket/private/host.rkt", .banned = "HOST-ACTION-" },
    };
    for (hosts) |host| {
        const contents = root.readFileAlloc(io, host.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host-action decode-ban check with {s}", .{ host.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, host.banned) != null) {
            try appendViolation(gpa, violations, "{s}: must not hand-decode HostAction (`{s}` belongs in the action module / generated decode)", .{ host.path, host.banned });
        }
    }
}

/// Binding spine Pass 3a: each binding keeps a named `promise` module for the
/// RemotePromise / session-vow handle and pipelined projection. Grep-level —
/// catches silent deletes, not wrong semantics.
fn checkBindingPromiseSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/promise.ts",
            .markers = &.{ "class RemotePromise", "index(", "untag(", "get(", "awaitMinted", "fetchLike", "promiseFor", "sendFar", "pancake_host_vow_index", "pancake_host_vow_untag", "pancake_host_vow_get" },
        },
        .{
            .path = "bindings/python/pancake/_promise.py",
            .markers = &.{ "class RemotePromise", "def index", "def untag", "def get", "_await_minted", "_fetch_like", "def _promise_for", "def _send_far", "pancake_host_vow_get" },
        },
        .{
            .path = "bindings/rust/src/promise.rs",
            .markers = &.{ "struct RemotePromise", "fn index", "fn untag", "fn get", "pancake_host_vow_index", "pancake_host_vow_get", "await_minted", "fetch_like", "fn send_promise" },
        },
        .{
            .path = "bindings/racket/private/promise.rkt",
            .markers = &.{ "session-vow", "settle-vow!", "session-index", "session-untag", "session-get", "pancake_host_vow_index", "pancake_host_vow_get", "await-vow", "blocking-fetch", "session-far-send", "pancake_host_session_send", "pancake_host_session_tell", "pancake_host_vow_send" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — promise veneer module (binding spine Pass 3a)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for promise-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: promise module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    // Fetch/enliven mint→await bodies and far-send promise factories live in
    // promise (Pass 4b / 4d), not session.
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .needle = "async #fetchLike" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#promiseFor(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "async def _fetch_like" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "async def _await_minted" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _promise_for" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn await_minted" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn fetch_like" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn send_promise" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (await-vow" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (blocking-fetch" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-far-send" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_vow_send" },
    };
    for (banned) |b| {
        const contents = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for promise-fetch ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in promise, not session (Pass 4b/4d)", .{ b.path, b.needle });
        }
    }
}

/// Binding spine Pass 5 (Rust): `Ref` / `Caretaker` / `SessionShared` live in
/// `session_shared.rs`, not `session.rs`. Grep-level.
fn checkBindingRustConnSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const path = "bindings/rust/src/session_shared.rs";
    root.access(io, path, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — Rust session_shared module (binding spine Pass 5)", .{path});
        return;
    };
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for rust session_shared check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    for ([_][]const u8{ "pub struct Ref", "pub struct Caretaker", "pub(crate) struct SessionShared", "fn tell(" }) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: session_shared module missing `{s}`", .{ path, needle });
        }
    }
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub struct Ref" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub struct Caretaker" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pub(crate) struct SessionShared" },
    };
    for (banned) |b| {
        const session = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for rust session_shared ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(session);
        if (std.mem.indexOf(u8, session, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in session_shared.rs, not session (Pass 5)", .{ b.path, b.needle });
        }
    }
}

/// Binding spine Pass 3b: each binding keeps a named `gc` module for ADR-0063
/// distributed GC (opt-in track + drain). Grep-level.
fn checkBindingGcSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/gc.ts",
            .markers = &.{ "class ConnGc", "interface GcHandle", "pancake_host_gc_release", "trackImport(", "drainGc(", "bind(" },
        },
        .{
            .path = "bindings/python/pancake/_gc.py",
            .markers = &.{ "class ConnGc", "class GcHandle", "def bind_session", "pancake_host_gc_release", "def track_import", "def drain_gc", "def bind" },
        },
        .{
            .path = "bindings/rust/src/gc.rs",
            .markers = &.{ "struct ImportGuard", "pancake_host_gc_release", "fn drain", "fn track_import" },
        },
        .{
            .path = "bindings/racket/private/gc.rkt",
            .markers = &.{ "session-with-gc!", "track-import!", "drain-gc!", "pancake_host_gc_release" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — GC veneer module (binding spine Pass 3b)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for gc-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: gc module missing `{s}`", .{ mod.path, needle });
            }
        }
    }

    // Track/drain bodies live in gc, not session (Pass 3b).
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#trackImport(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#drainGc(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _track_import" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _drain_gc" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _on_import_dropped" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn track_import" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_gc_release" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (track-import!" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (drain-gc!" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-with-gc!" },
    };
    for (banned) |b| {
        const contents = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for gc-session ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in gc, not session (Pass 3b)", .{ b.path, b.needle });
        }
    }

    // Python ConnGc must not poke Session privates — GcHandle owns the seam.
    const py_gc = "bindings/python/pancake/_gc.py";
    const py_gc_contents = root.readFileAlloc(io, py_gc, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for GcHandle check with {s}", .{ py_gc, @errorName(err) });
        return;
    };
    defer gpa.free(py_gc_contents);
    for ([_][]const u8{ "session._host", "session._loop", "session._released", "getattr(session", "._s._" }) |needle| {
        if (std.mem.indexOf(u8, py_gc_contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` — ConnGc must use GcHandle, not Session privates", .{ py_gc, needle });
        }
    }

    // Python owning modules must use Session/Host binding-internal seams
    // (raw/host/gc/hosted/…), not underscore reach-ins — the same class of
    // smell as the pre-fix ConnGc getattr path.
    const py_seam = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "bindings/python/pancake/_pump.py", .needles = &.{ "session._", "host._" } },
        .{ .path = "bindings/python/pancake/_promise.py", .needles = &.{"session._"} },
        .{ .path = "bindings/python/pancake/_trampoline.py", .needles = &.{"session._"} },
        .{ .path = "bindings/python/pancake/_action.py", .needles = &.{ "host._", "conn._" } },
        .{ .path = "bindings/python/pancake/_host.py", .needles = &.{"conn._"} },
    };
    for (py_seam) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for private-reach ban with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (row.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: `{s}` — use binding-internal Session/Host seams, not privates", .{ row.path, needle });
            }
        }
    }
}

/// Binding spine Pass 3c: each binding keeps a named `dial` module for the
/// unified dial executor (plan_dial + connect + redeem). Grep-level.
fn checkBindingDialSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/dial.ts",
            .markers = &.{ "dialParsedLocator", "pancake_host_plan_dial", "dialExporter", "function connect" },
        },
        .{
            .path = "bindings/python/pancake/_dial.py",
            .markers = &.{ "dial_parsed_locator", "pancake_host_plan_dial", "dial_exporter", "async def connect" },
        },
        .{
            .path = "bindings/rust/src/dial.rs",
            .markers = &.{ "dial_parsed_locator", "pancake_host_plan_dial", "dial_exporter", "pub async fn connect" },
        },
        .{
            .path = "bindings/racket/private/dial.rkt",
            .markers = &.{ "dial-parsed-locator", "pancake_host_plan_dial", "dial-exporter", "(define (connect" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — dial module (binding spine Pass 3c)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: dial module missing `{s}`", .{ mod.path, needle });
            }
        }
    }
}

/// Binding spine Pass 3d: each binding keeps a named `listen` module for
/// Server / listen / keyed-tcp hosting. Grep-level.
fn checkBindingListenSpine(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct {
        path: []const u8,
        markers: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/listen.ts",
            .markers = &.{ "class Server", "class KeyedTcpServer", "function listen", "listenKeyedTcp", "establishAccepted", "socketAddrDesignator" },
        },
        .{
            .path = "bindings/python/pancake/_listen.py",
            .markers = &.{ "class Server", "class KeyedTcpServer", "async def listen", "listen_keyed_tcp", "establish_accepted", "socket_addr_designator" },
        },
        .{
            .path = "bindings/rust/src/listen.rs",
            .markers = &.{ "struct Server", "KeyedTcpServer", "pub async fn listen", "listen_keyed_tcp", "establish_accepted", "socket_addr_designator" },
        },
        .{
            .path = "bindings/racket/private/listen.rkt",
            .markers = &.{ "(struct server", "listen-keyed-tcp", "(define (listen", "(define (accept", "establish-accepted-session", "socket-addr-designator" },
        },
    };
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — listen module (binding spine Pass 3d)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listen-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: listen module missing `{s}`", .{ mod.path, needle });
            }
        }
    }
    // Session must not re-export dial/listen — the barrel owns that graph.
    const reexport_bans = [_]struct {
        path: []const u8,
        banned: []const []const u8,
    }{
        .{
            .path = "bindings/ts/stack/session.ts",
            .banned = &.{ "export { connect }", "from \"./dial.ts\"", "from \"./listen.ts\"", "export { RemotePromise }" },
        },
        .{
            .path = "bindings/racket/private/session.rkt",
            .banned = &.{
                "(all-from-out \"dial.rkt\")",
                "(all-from-out \"listen.rkt\")",
                "(all-from-out \"action.rkt\")",
                "(all-from-out \"pump.rkt\")",
                "(all-from-out \"async.rkt\")",
                "(all-from-out \"host.rkt\")",
                "(all-from-out \"promise.rkt\")",
                "(all-from-out \"gc.rkt\")",
            },
        },
        .{
            .path = "bindings/rust/src/session.rs",
            .banned = &.{ "pub use crate::promise::", "pub use crate::dial::", "pub use crate::listen::" },
        },
        .{
            .path = "bindings/python/pancake/_session.py",
            .banned = &.{ "from ._dial import", "from ._listen import", "async def connect", "class Server", "class KeyedTcpServer" },
        },
    };
    for (reexport_bans) |entry| {
        const contents = root.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for dial/listen re-export ban with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (entry.banned) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: forbidden `{s}` — dial/listen/promise re-exports belong on the barrel, not session", .{ entry.path, needle });
            }
        }
    }
}

/// CapTP embedder pump (ADR-0072 / Pass-1 spine gate): each binding keeps a
/// named `pump` module for the conn byte path, mid-turn conn_release parking
/// in the session close path, and the C reference example that compiles the
/// same choreography. Grep-level — catches silent deletes, not wrong order.
fn checkBindingEmbedderPump(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const pump_paths = [_][]const u8{
        "bindings/ts/stack/pump.ts",
        "bindings/python/pancake/_pump.py",
        "bindings/rust/src/pump.rs",
        "bindings/racket/private/pump.rkt",
    };
    for (pump_paths) |path| {
        root.access(io, path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — EmbedderPump module (binding spine Pass 1)", .{path});
            continue;
        };
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for embedder-pump check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const markers = [_][]const u8{
            "pancake_host_session_feed_bytes",
            "take_outbound",
            "break_far_vows",
        };
        for (markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: pump missing `{s}` — conn byte choreography", .{ path, needle });
            }
        }
        // Feed-refusal / last_abort: the FFI reader lives in pump (Pass 1b).
        if (std.mem.indexOf(u8, contents, "pancake_host_session_last_abort") == null and
            std.mem.indexOf(u8, contents, "last_abort") == null and
            std.mem.indexOf(u8, contents, "last-abort") == null)
        {
            try appendViolation(gpa, violations, "{s}: pump missing last_abort/last-abort — feed-refusal path", .{path});
        }
        // Post-feed action kick / drain (one-loop rule after feed_bytes).
        const kick_ok = std.mem.indexOf(u8, contents, "kickActions") != null or
            std.mem.indexOf(u8, contents, "kick_actions") != null or
            std.mem.indexOf(u8, contents, "drain-host-actions!") != null;
        if (!kick_ok) {
            try appendViolation(gpa, violations, "{s}: pump missing post-feed action kick/drain (kickActions / kick_actions / drain-host-actions!)", .{path});
        }
        // Feed refusal must use the shared drain, not a private take_outbound
        // flush — the same spine as a steady FLUSH (bindings/README checklist).
        const private_refusal_flush = [_][]const u8{
            "await flushOutbound(h)",
            "flush_outbound(shared).await",
            "await flush_outbound(session)",
        };
        for (private_refusal_flush) |needle| {
            if (std.mem.indexOf(u8, contents, needle) != null) {
                try appendViolation(gpa, violations, "{s}: feed-refusal must not private-flush via `{s}` — use kick_actions / kickActions / drain-effects", .{ path, needle });
            }
        }
        // EOF / break_far_vows must drain FAIL completions (shared spine). Match
        // the FFI *call* (`…break_far_vows(`) so module-doc mentions do not fire.
        // Kick may appear just before (Racket `with-breaking-drain`) or after.
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, contents, search_from, "pancake_host_session_break_far_vows(")) |break_at| {
            const lo = if (break_at > 400) break_at - 400 else 0;
            const hi = @min(contents.len, break_at + 800);
            const window = contents[lo..hi];
            const kick_near = std.mem.indexOf(u8, window, "kickActions") != null or
                std.mem.indexOf(u8, window, "kick_actions") != null or
                std.mem.indexOf(u8, window, "drain-host-actions!") != null or
                std.mem.indexOf(u8, window, "with-breaking-drain") != null;
            if (!kick_near) {
                try appendViolation(gpa, violations, "{s}: pancake_host_session_break_far_vows without nearby action kick/drain — EOF must settle FAIL completions", .{path});
            }
            search_from = break_at + 1;
        }
        // Keyed handshake loop lives in pump (Pass 4a), not session.
        const hs_ok = std.mem.indexOf(u8, contents, "runHandshake") != null or
            std.mem.indexOf(u8, contents, "_run_handshake") != null or
            std.mem.indexOf(u8, contents, "run_handshake") != null or
            std.mem.indexOf(u8, contents, "run-handshake!") != null;
        if (!hs_ok) {
            try appendViolation(gpa, violations, "{s}: pump missing handshake runner (runHandshake / _run_handshake / run_handshake / run-handshake!)", .{path});
        }
    }

    // Handshake error string must not live in session files — pump owns the loop.
    const handshake_msg = "connection closed during the OCapN handshake";
    const session_paths = [_][]const u8{
        "bindings/ts/stack/session.ts",
        "bindings/python/pancake/_session.py",
        "bindings/rust/src/session.rs",
        "bindings/racket/private/session.rkt",
    };
    for (session_paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for handshake-spine check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, handshake_msg) != null) {
            try appendViolation(gpa, violations, "{s}: handshake closed-message belongs in pump, not session", .{path});
        }
        // last_abort FFI reader lives in pump (Pass 1b); Session may wrap.
        if (std.mem.indexOf(u8, contents, "pancake_host_session_last_abort") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_session_last_abort belongs in pump, not session", .{path});
        }
        // break_far_vows FFI lives in pump; Session may wrap the drain window.
        if (std.mem.indexOf(u8, contents, "pancake_host_session_break_far_vows") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_session_break_far_vows belongs in pump, not session", .{path});
        }
    }

    const park = [_]struct { path: []const u8, inside: []const u8, park: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .inside = "insideTurn", .park = "parkRelease" },
        .{ .path = "bindings/python/pancake/_session.py", .inside = "_inside_turn", .park = "park_release" },
        .{ .path = "bindings/rust/src/session_shared.rs", .inside = "inside_turn", .park = "park_session_release" },
        .{ .path = "bindings/racket/private/session.rkt", .inside = "inside-turn?", .park = "host-park-release!" },
    };
    for (park) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for mid-turn park check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.inside) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — mid-turn park gate", .{ row.path, row.inside });
        }
        if (std.mem.indexOf(u8, contents, row.park) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — mid-turn park gate", .{ row.path, row.park });
        }
        if (std.mem.indexOf(u8, contents, "pancake_host_session_release") == null) {
            try appendViolation(gpa, violations, "{s}: missing pancake_host_session_release — close path", .{row.path});
        }
    }

    const cref = "examples/c/host_embedder_pump.c";
    root.access(io, cref, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — C reference embedder pump", .{cref});
        return;
    };
    const cref_contents = root.readFileAlloc(io, cref, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for C reference pump check with {s}", .{ cref, @errorName(err) });
        return;
    };
    defer gpa.free(cref_contents);
    for ([_][]const u8{
        "pancake_host_session_feed_bytes",
        "pancake_host_next_action",
        "pancake_host_session_take_outbound",
        "pancake_host_session_last_abort",
        "pancake_host_session_break_far_vows",
    }) |needle| {
        if (std.mem.indexOf(u8, cref_contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — normative embedder choreography", .{ cref, needle });
        }
    }

    // Zig-facing shared drain (ADR-0072 fifth amendment) — authority for the
    // one-loop switch tests rewire onto; must not silently disappear.
    const zig_pump = "src/c_abi/driver/embedder_pump.zig";
    root.access(io, zig_pump, .{}) catch {
        try appendViolation(gpa, violations, "{s}: file must exist — Zig embedder_pump (ADR-0072 fifth)", .{zig_pump});
        return;
    };
    const zig_pump_contents = root.readFileAlloc(io, zig_pump, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Zig embedder_pump check with {s}", .{ zig_pump, @errorName(err) });
        return;
    };
    defer gpa.free(zig_pump_contents);
    for ([_][]const u8{ "drainHost", "drainHosts", "pancake_host_next_action" }) |needle| {
        if (std.mem.indexOf(u8, zig_pump_contents, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — shared C-ABI drain helper", .{ zig_pump, needle });
        }
    }

    // Binding action modules drain via pancake_host_pump_drain (ADR-0072 sixth).
    // Ban hand-rolled pancake_host_next_action pop loops in those modules — the
    // C symbol may still appear in FFI loaders and comments outside action/.
    const action_mods = [_][]const u8{
        "bindings/ts/stack/action.ts",
        "bindings/python/pancake/_action.py",
        "bindings/rust/src/action.rs",
        "bindings/racket/private/action.rkt",
    };
    for (action_mods) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for pump_drain adoption check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "pancake_host_pump_drain") == null) {
            try appendViolation(gpa, violations, "{s}: missing pancake_host_pump_drain — action module must use the shared C drain", .{path});
        }
        if (std.mem.indexOf(u8, contents, "pancake_host_next_action") != null) {
            try appendViolation(gpa, violations, "{s}: pancake_host_next_action in action module — use pancake_host_pump_drain (no hand-rolled pop loop)", .{path});
        }
    }
}

/// Behavior trampoline spine (Pass 5): each binding keeps a named trampoline
/// module, mid-turn latch, reply keep, and turn verbs; hop cap lives in the
/// constant homes (mirrored against PANCAKE_MAX_LOCAL_FORWARD_HOPS).
fn checkBindingEmbedderTrampoline(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const mods = [_]struct { path: []const u8, markers: []const []const u8 }{
        .{
            .path = "bindings/ts/stack/trampoline.ts",
            .markers = &.{ "chaseLocalForwards", "runHosted", "sendLocal", "tellLocal", "tellFar", "dispatchSend", "dispatchTell", "caretakerProxy", "attenuateProxy", "spawnHosted", "publishHosted", "function registerActor", "currentTurn", "lastReplyKeep", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/python/pancake/_trampoline.py",
            .markers = &.{ "_chase_local_forwards", "_run_hosted", "_send_local", "_tell_local", "_tell_far", "_dispatch_send", "_dispatch_tell", "_caretaker_proxy", "_attenuate_proxy", "_spawn_hosted", "_publish_hosted", "def _register_actor", "_current_turn", "_last_reply_keep", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/rust/src/trampoline.rs",
            .markers = &.{ "chase_local_forwards", "run_hosted", "run_local_send", "caretaker_proxy", "attenuate_proxy", "CURRENT_TURN", "LAST_REPLY_KEEP", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "MAX_LOCAL_FORWARD_HOPS", "FORWARD_CYCLE_MESSAGE" },
        },
        .{
            .path = "bindings/racket/private/trampoline.rkt",
            .markers = &.{ "settle-turn-reply", "chase-local-actor-forwards", "session-send-local", "await-local-vow", "dispatch-send", "dispatch-send-promise", "dispatch-tell", "caretaker-behavior", "attenuate-behavior", "caretaker-proxy", "attenuate-proxy", "revoke-caretaker!", "register-hosted-actor!", "pancake_host_session_spawn", "pancake_host_session_publish", "current-turn", "last-reply-keep", "pancake_host_turn_break", "pancake_host_turn_forward", "pancake_host_turn_spawn", "FORWARD-CYCLE-MESSAGE" },
        },
    };
    // Racket's chase lives in vat.rkt (shared by $, drive, and the trampoline).
    {
        const vat_path = "bindings/racket/private/vat.rkt";
        if (root.readFileAlloc(io, vat_path, gpa, .limited(2 << 20))) |contents| {
            defer gpa.free(contents);
            for ([_][]const u8{ "chase-local-actor-forwards", "forward-cycle", "hop-broke", "MAX-LOCAL-FORWARD-HOPS", "FORWARD-CYCLE-MESSAGE" }) |needle| {
                if (std.mem.indexOf(u8, contents, needle) == null) {
                    try appendViolation(gpa, violations, "{s}: missing `{s}` — shared local-forward chase", .{ vat_path, needle });
                }
            }
        } else |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for shared-chase check with {s}", .{ vat_path, @errorName(err) });
        }
    }
    for (mods) |mod| {
        root.access(io, mod.path, .{}) catch {
            try appendViolation(gpa, violations, "{s}: file must exist — trampoline module (binding spine Pass 5)", .{mod.path});
            continue;
        };
        const contents = root.readFileAlloc(io, mod.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline-spine check with {s}", .{ mod.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (mod.markers) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: trampoline missing `{s}`", .{ mod.path, needle });
            }
        }
        // Hop cap must come from the constant home, not a raw 256 literal.
        if (std.mem.indexOf(u8, contents, "= 256") != null or
            std.mem.indexOf(u8, contents, "=256") != null or
            std.mem.indexOf(u8, contents, " 256)") != null)
        {
            try appendViolation(gpa, violations, "{s}: raw hop-cap literal — use MAX_LOCAL_FORWARD_HOPS / MAX-LOCAL-FORWARD-HOPS", .{mod.path});
        }
    }

    // Local send/tell arms and ADR-0064 proxy factories live in trampoline
    // (Pass 4c / 4e), not session.
    const banned = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#sendLocal" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "throw new Error(\"Revoked\")" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "throw new Error(\"Attenuated\")" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _send_local" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "raise ValueError(\"Revoked\")" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "raise ValueError(\"Attenuated\")" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "async fn run_local_send" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "fn run_hosted(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "Break(\"Revoked\"" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "Break(\"Attenuated\"" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (session-send-local" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (await-local-vow" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(error \"Revoked\")" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(error \"Attenuated\")" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(spawn (caretaker-behavior" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(spawn (attenuate-behavior" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(hash-set! (vat-revocables" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_vow_send" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_send" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_vow_send" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_spawn" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_publish" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_spawn" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_publish" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_spawn" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "pancake_host_session_publish" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(define (register-hosted-actor!" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "#registerActor" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "def _register_actor" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "class _SessionGcHandle" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "pancake_host_session_tell" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_vow_index" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "pancake_host_vow_untag" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "return sendLocal(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "await tellLocal(" },
        .{ .path = "bindings/ts/stack/session.ts", .needle = "return sendFar(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "return _send_local(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "await _tell_local(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "return _send_far(" },
        .{ .path = "bindings/python/pancake/_session.py", .needle = "await _tell_far(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "tell_local(" },
        .{ .path = "bindings/rust/src/session.rs", .needle = "tell_wire(" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(session-send-local c" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(apply <-np resolved" },
        .{ .path = "bindings/racket/private/session.rkt", .needle = "(await-vow c (session-far-send" },
    };
    for (banned) |b| {
        const contents = root.readFileAlloc(io, b.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline-factory ban with {s}", .{ b.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, b.needle) != null) {
            try appendViolation(gpa, violations, "{s}: `{s}` belongs in promise/trampoline, not session (Pass 4c/4e/4f)", .{ b.path, b.needle });
        }
    }

    // Constant homes must carry the hop cap. The reflected value lives in each
    // binding's generated constant module (`zig build gen-binding-constants`),
    // re-exported through the hand-kept home; the presence check names the
    // generated module that reflects it.
    const const_homes = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "bindings/python/pancake/_constants_gen.py", .needle = "MAX_LOCAL_FORWARD_HOPS" },
        .{ .path = "bindings/rust/src/abi_constants_gen.rs", .needle = "MAX_LOCAL_FORWARD_HOPS" },
        .{ .path = "bindings/racket/private/constants-gen.rkt", .needle = "MAX-LOCAL-FORWARD-HOPS" },
        .{ .path = "bindings/ts/stack/internal/abi.ts", .needle = "MAX_LOCAL_FORWARD_HOPS" },
    };
    for (const_homes) |home| {
        const contents = root.readFileAlloc(io, home.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for trampoline hop-cap check with {s}", .{ home.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, home.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — trampoline hop-cap mirror", .{ home.path, home.needle });
        }
    }

    // C example must exercise the opt-in pump drain.
    const cref = "examples/c/host_embedder_pump.c";
    const cref_contents = root.readFileAlloc(io, cref, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for pump_drain check with {s}", .{ cref, @errorName(err) });
        return;
    };
    defer gpa.free(cref_contents);
    if (std.mem.indexOf(u8, cref_contents, "pancake_host_pump_drain") == null) {
        try appendViolation(gpa, violations, "{s}: missing pancake_host_pump_drain — C checklist must use the opt-in wrapper", .{cref});
    }
}

/// Living-state honesty for the embedder-spine inventory: shipped.md and
/// bindings/README.md must name every Pass-1..5 module, declare the split
/// complete, and name the handshake pump + trampoline / opt-in callback pump.
/// Also refuse the retired Racket API name `set-node-redeem-reachability`
/// anywhere under bindings/ (the live export is `set-host-redeem-reachability!`).
fn checkBindingEmbedderSpineDocs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const docs = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{
            .path = "docs/shipped.md",
            .needles = &.{
                "named `pump`",
                "named `action`",
                "named `promise`",
                "promiseFor",
                "sendFar",
                "named `gc`",
                "named `dial`",
                "named `listen`",
                "embedder-spine module split is complete",
                "trampoline",
                "caretaker",
                "named `session_shared`",
                "embedder_pump",
                "pancake_host_pump_drain",
                "handshake",
            },
        },
        .{
            .path = "bindings/README.md",
            .needles = &.{
                "**pump module**",
                "**action module**",
                "named **promise**",
                "promiseFor",
                "sendFar",
                "**gc** module",
                "named **dial**",
                "named **listen**",
                "**trampoline** module",
                "embedder-spine module split is complete",
                "trampoline",
                "caretaker/attenuate",
                "spawn/publish",
                "**session_shared** module",
                "embedder_pump",
                "pancake_host_pump_drain",
                "handshake",
            },
        },
    };
    for (docs) |doc| {
        const contents = root.readFileAlloc(io, doc.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for embedder-spine doc check with {s}", .{ doc.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (doc.needles) |needle| {
            if (std.mem.indexOf(u8, contents, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing `{s}` — embedder-spine living-state inventory", .{ doc.path, needle });
            }
        }
    }

    const banned = "set-node-redeem-reachability";
    const bind_roots = [_][]const u8{
        "bindings/python",
        "bindings/rust/src",
        "bindings/ts",
        "bindings/racket",
        "bindings/README.md",
    };
    const exts = [_][]const u8{ ".py", ".rs", ".ts", ".rkt", ".md" };
    for (bind_roots) |bind_root| {
        if (std.mem.endsWith(u8, bind_root, ".md")) {
            const contents = root.readFileAlloc(io, bind_root, gpa, .limited(2 << 20)) catch continue;
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, banned) != null) {
                try appendViolation(gpa, violations, "{s}: retired API `{s}` — use set-host-redeem-reachability!", .{ bind_root, banned });
            }
            continue;
        }
        var dir = root.openDir(io, bind_root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            var ok_ext = false;
            for (exts) |ext| {
                if (std.mem.endsWith(u8, entry.path, ext)) {
                    ok_ext = true;
                    break;
                }
            }
            if (!ok_ext) continue;
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ bind_root, entry.path });
            defer gpa.free(full);
            const contents = root.readFileAlloc(io, full, gpa, .limited(2 << 20)) catch continue;
            defer gpa.free(contents);
            if (std.mem.indexOf(u8, contents, banned) != null) {
                try appendViolation(gpa, violations, "{s}: retired API `{s}` — use set-host-redeem-reachability!", .{ full, banned });
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

/// CapTP leaf names from `cli/registry.zig`'s `commands` table.
/// Command rows put `.name` / `.help` on consecutive lines; positional structs
/// keep both on one line — that difference is how we avoid collecting `locator`.
fn collectCaptpRegistryNames(
    gpa: std.mem.Allocator,
    registry_src: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const start = std.mem.indexOf(u8, registry_src, "pub const commands") orelse return;
    const end_marker = std.mem.indexOfPos(u8, registry_src, start, "\n};") orelse registry_src.len;
    const block = registry_src[start..end_marker];
    var line_start: usize = 0;
    while (line_start < block.len) {
        const nl = std.mem.indexOfScalarPos(u8, block, line_start, '\n') orelse block.len;
        const line = std.mem.trim(u8, block[line_start..nl], " \t");
        if (std.mem.startsWith(u8, line, ".name = \"")) {
            const after = ".name = \"".len;
            if (std.mem.indexOfScalarPos(u8, line, after, '"')) |q| {
                const name = line[after..q];
                var next = if (nl < block.len) nl + 1 else block.len;
                while (next < block.len) {
                    const nnl = std.mem.indexOfScalarPos(u8, block, next, '\n') orelse block.len;
                    const next_line = std.mem.trim(u8, block[next..nnl], " \t");
                    if (next_line.len == 0) {
                        next = if (nnl < block.len) nnl + 1 else block.len;
                        continue;
                    }
                    if (std.mem.startsWith(u8, next_line, ".help =")) {
                        try out.append(gpa, name);
                    }
                    break;
                }
            }
        }
        line_start = if (nl < block.len) nl + 1 else block.len;
    }
}

/// True when a markdown table is a CapTP verb inventory (header names Verb or
/// Command) and lists some registry leaves (≥3) but not all. Session-model
/// tables that mention `` `call` `` inline are not inventories.
fn captpVerbTableIsPartial(skill: []const u8, names: []const []const u8) bool {
    var line_start: usize = 0;
    var in_inventory = false;
    var hit: usize = 0;
    var seen: [64]bool = .{false} ** 64;
    while (line_start < skill.len) {
        const nl = std.mem.indexOfScalarPos(u8, skill, line_start, '\n') orelse skill.len;
        const line = skill[line_start..nl];
        const is_row = line.len > 0 and line[0] == '|';
        if (is_row) {
            const lower_buf_len = @min(line.len, 256);
            var lower_buf: [256]u8 = undefined;
            for (line[0..lower_buf_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
            const lower = lower_buf[0..lower_buf_len];
            if (!in_inventory) {
                if (std.mem.indexOf(u8, lower, "verb") != null or std.mem.indexOf(u8, lower, "command") != null) {
                    in_inventory = true;
                }
            } else {
                var cell_start: usize = 0;
                while (cell_start < line.len) {
                    if (line[cell_start] != '|') {
                        cell_start += 1;
                        continue;
                    }
                    const after_bar = cell_start + 1;
                    const next_bar = std.mem.indexOfScalarPos(u8, line, after_bar, '|') orelse line.len;
                    const cell = std.mem.trim(u8, line[after_bar..next_bar], " \t");
                    if (cell.len >= 3 and cell[0] == '`' and cell[cell.len - 1] == '`') {
                        const span = cell[1 .. cell.len - 1];
                        for (names, 0..) |name, ni| {
                            if (ni >= seen.len) break;
                            if (std.mem.eql(u8, span, name) and !seen[ni]) {
                                seen[ni] = true;
                                hit += 1;
                            }
                        }
                    }
                    cell_start = next_bar;
                }
            }
        } else if (in_inventory) {
            if (hit >= 3 and hit < names.len) return true;
            in_inventory = false;
            hit = 0;
            seen = .{false} ** 64;
        }
        line_start = if (nl < skill.len) nl + 1 else skill.len;
    }
    if (in_inventory and hit >= 3 and hit < names.len) return true;
    return false;
}

/// The pancake-mcp skill defers the tool catalog to MCP `tools/list` / registry.
/// Refuse a partial default-catalog inventory and unimplemented env overrides.
fn checkPancakeMcpSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/pancake-mcp/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    if (std.mem.indexOf(u8, skill, "tools/list") == null) {
        try appendViolation(gpa, violations, "{s}: CapTP MCP catalog authority must point at `tools/list`", .{skill_path});
    }
    if (std.mem.indexOf(u8, skill, "Use pancake to write pancake") == null) {
        try appendViolation(gpa, violations, "{s}: must state dogfood destination `Use pancake to write pancake`", .{skill_path});
    }
    if (std.mem.indexOf(u8, skill, "PANCAKE_MCP_TOOLS") != null) {
        try appendViolation(gpa, violations, "{s}: forbids unimplemented `PANCAKE_MCP_TOOLS` — catalog is `--tools` only", .{skill_path});
    }
    // Hand-maintained default inventory (second catalog).
    if (std.mem.indexOf(u8, skill, "everyday CapTP (dial, probe") != null or
        std.mem.indexOf(u8, skill, "dial, probe, call, tell, fetch, publish, info") != null)
    {
        try appendViolation(gpa, violations, "{s}: do not enumerate default MCP tools — discover via `tools/list` / registry", .{skill_path});
    }
}

/// Work / smell-annihilation / skill indexes must not funnel MCP through pancake-cli.
fn checkCaptpAgentDogfoodRouting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const must_name_mcp = [_][]const u8{
        ".agents/skills/work/SKILL.md",
        ".agents/skills/smell-annihilation/SKILL.md",
        ".agents/skills/rooms-peer/SKILL.md",
    };
    for (must_name_mcp) |path| {
        const text = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP dogfood routing with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "pancake-mcp") == null) {
            try appendViolation(gpa, violations, "{s}: CapTP dogfood routing must name `pancake-mcp` (MCP is not under pancake-cli)", .{path});
        }
    }

    const indexes = [_][]const u8{
        ".agents/README.md",
        ".agents/skills/README.md",
    };
    for (indexes) |path| {
        const text = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP dogfood routing with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "argv, REPL, MCP") != null) {
            try appendViolation(gpa, violations, "{s}: pancake-cli blurb must not claim MCP — MCP lives on pancake-mcp", .{path});
        }
    }
}

/// The pancake-cli skill defers the CapTP catalog to `pancake help`. Gate the
/// authority pointer and refuse a partial verb-inventory table (second catalog).
fn checkPancakeCliSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/pancake-cli/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    const has_help = std.mem.indexOf(u8, skill, "pancake help") != null or
        std.mem.indexOf(u8, skill, "help ocapn") != null;
    if (!has_help) {
        try appendViolation(gpa, violations, "{s}: CapTP catalog authority must point at `pancake help` / `help ocapn` (not a second verb table)", .{skill_path});
    }

    const registry_src = root.readFileAlloc(io, "cli/registry.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "cli/registry.zig: failed to read for pancake-cli skill check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(registry_src);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try collectCaptpRegistryNames(gpa, registry_src, &names);
    if (names.items.len < 5) {
        try appendViolation(gpa, violations, "cli/registry.zig: expected CapTP leaf `.name = \"…\"` rows for pancake-cli skill check", .{});
        return;
    }
    if (captpVerbTableIsPartial(skill, names.items)) {
        try appendViolation(gpa, violations, "{s}: CapTP verb table is incomplete — enumerate every registry leaf or defer to `pancake help` (no second catalog)", .{skill_path});
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

/// CapTP C product is `pancake_host_*` only: the demoted `pancake_node_*`
/// projection must not return in generated headers or binding FFI maps.
fn checkDeletedNodeCProjection(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const banned = "pancake_node_";
    const paths = [_][]const u8{
        "include/pancake_ocapn.h",
        "include/pancake_driver.h",
        "bindings/ts/stack/internal/ffi/ocapn.ts",
        "bindings/python/pancake/_ffi_ocapn.py",
        "bindings/racket/private/ffi-ocapn.rkt",
        "bindings/rust/src/sys/ocapn.rs",
    };
    for (paths) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for deleted-node C projection check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, banned) != null) {
            try appendViolation(gpa, violations, "{s}: contains `{s}` — CapTP C product is pancake_host_* only; the demoted node waist must not return", .{ path, banned });
        }
    }
    // The companion header itself must stay deleted.
    if (root.access(io, "include/pancake_ocapn_node.h", .{})) |_| {
        try appendViolation(gpa, violations, "include/pancake_ocapn_node.h: file must stay deleted (demoted node waist)", .{});
    } else |_| {}
}

/// CapTP vocabulary (ADR-0079): structural resurrection guards only.
/// Deleted file paths, deleted `pub` symbols, and binding export maps that a
/// compiler would not catch. Prose tombstones for the rename ("multi-connection
/// node", "native-Zig Connection", …) were pruned once the rename shipped —
/// see the gate-accretion rule in `.agents/rules/agent-scaffolding.md`.
fn checkCaptpVocabulary(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // Deleted file names must stay deleted (renamed in ADR-0079).
    const deleted_paths = [_]struct { path: []const u8, reason: []const u8 }{
        .{ .path = "src/driver/connected_vat.zig", .reason = "BlockingSession lives in blocking_session.zig (ADR-0079)" },
        .{ .path = "test/driver/connected_vat_test.zig", .reason = "blocking_session_test.zig (ADR-0079)" },
        .{ .path = "bindings/ts/stack/connection.ts", .reason = "Session lives in session.ts (ADR-0079)" },
        .{ .path = "bindings/python/pancake/_connection.py", .reason = "Session lives in _session.py (ADR-0079)" },
        .{ .path = "bindings/rust/src/connection.rs", .reason = "Session lives in session.rs (ADR-0079)" },
        .{ .path = "bindings/racket/private/connection.rkt", .reason = "Session lives in session.rkt (ADR-0079)" },
    };
    for (deleted_paths) |entry| {
        if (root.access(io, entry.path, .{})) |_| {
            try appendViolation(gpa, violations, "{s}: file must stay deleted — {s}", .{ entry.path, entry.reason });
        } else |_| {}
    }

    // Resurrected symbols / exports — not prose.
    const SymbolBan = struct { path: []const u8, needle: []const u8, reason: []const u8 };
    const symbol_bans = [_]SymbolBan{
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn hasSelfDesignator", .reason = "unused; callers use setSelfDesignator + selfDesignator" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn vowConn", .reason = "unused; C ABI / bindings use vowConnClosing path, not ConnId lookup" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn execNodeAction", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn dialActionFields", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "fn queueFlushAction", .reason = "collapsed into queueUniqueConnAction" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "fn queueCloseAction", .reason = "collapsed into queueUniqueConnAction" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn queueUniqueConnAction", .reason = "host_pump-private; only called inside host_pump" },
        .{ .path = "src/driver/core/host_pump.zig", .needle = "pub fn drainWork", .reason = "host_pump-private; only called from finishVerb" },
        .{ .path = "src/net/mod.zig", .needle = "pub const FrameError = frame_stream.FrameError", .reason = "frame_stream-internal; not a net barrel export" },
        .{ .path = "src/net/mod.zig", .needle = "pub const drainWholeFrames = frame_stream.drainWholeFrames", .reason = "frame_stream-internal; not a net barrel export" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const requiresDirectAddressesHint = vocab.requiresDirectAddressesHint", .reason = "use vocab.requiresDirectAddressesHint; not a driver_core barrel export" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const DialPlanError = dial_plan.Error", .reason = "unused barrel export; dial_plan.Error stays module-local" },
        .{ .path = "src/driver/core/mod.zig", .needle = "pub const DialReach = dial_plan.Reach", .reason = "unused barrel export; dial_plan.Reach stays module-local" },
        .{ .path = "test/support/wait.zig", .needle = "pub const Signal = struct", .reason = "unused; use untilFlag" },
        .{ .path = "test/support/wait.zig", .needle = "pub const PublishedAddr = struct", .reason = "unused; no adopters" },
        .{ .path = "src/driver/mod.zig", .needle = "pub const Node = engine.Node", .reason = "driver.Node re-export deleted (ADR-0079)" },
        .{ .path = "src/driver/core/served.zig", .needle = "fn bindForeign", .reason = "use bindExport; bindForeign deleted (ADR-0079)" },
        .{ .path = "src/driver/core/served.zig", .needle = "fn spawnForeign", .reason = "spawnHosted (ADR-0079)" },
        .{ .path = "src/net/transport/tcp.zig", .needle = "pub const Locator = struct", .reason = "tcp.DialResolver (ADR-0079)" },
        .{ .path = "src/net/transport/iroh.zig", .needle = "pub const Locator = struct", .reason = "iroh.DialResolver (ADR-0079)" },
        .{ .path = "src/c_abi/shared/mod.zig", .needle = "pub const HostAllocator", .reason = "ContextAllocator (ADR-0079)" },
        .{ .path = "src/driver/blocking_session.zig", .needle = "pub const ConnectedVat", .reason = "BlockingSession (ADR-0079)" },
        .{ .path = "src/actors/vat.zig", .needle = "pub const ForeignActor", .reason = "HostedActor (ADR-0079)" },
        .{ .path = "src/actors/vat.zig", .needle = "fn spawnForeign", .reason = "spawnHosted (ADR-0079)" },
        .{ .path = "src/actors/vat.zig", .needle = "const ForeignBlock", .reason = "HostedBlock (ADR-0079)" },
        .{ .path = "src/ocapn/engine/pairing.zig", .needle = "pub fn pairedWithOffers", .reason = "use pairedNegotiated + negotiate" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub fn offerForTarget", .reason = "test-local interop offer helper" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub const InteropTarget", .reason = "test-local interop offer helper" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub const CodecId = model.CodecId", .reason = "use model.CodecId" },
        .{ .path = "src/ocapn/engine/negotiation.zig", .needle = "pub fn sharesProfile", .reason = "removed; tests map negotiate null locally" },
        .{ .path = "bindings/ts/stack/mod.ts", .needle = "export { Node }", .reason = "export Host (ADR-0079)" },
        .{ .path = "bindings/ts/stack/mod.ts", .needle = "export { Connection }", .reason = "export Session (ADR-0079)" },
        .{ .path = "bindings/rust/src/lib.rs", .needle = "pub use host::Node", .reason = "pub use host::Host (ADR-0079)" },
        .{ .path = "bindings/rust/src/lib.rs", .needle = "pub use session::Connection", .reason = "pub use session::Session (ADR-0079)" },
        .{ .path = "bindings/python/pancake/__init__.py", .needle = "\"Node\"", .reason = "__all__ exports Host (ADR-0079)" },
        .{ .path = "bindings/python/pancake/__init__.py", .needle = "\"Connection\"", .reason = "__all__ exports Session (ADR-0079)" },
        .{ .path = "bindings/racket/pancake.rkt", .needle = "make-fresh-node", .reason = "make-fresh-host (ADR-0079)" },
        .{ .path = "bindings/racket/private/host.rkt", .needle = "(define (make-fresh-node", .reason = "make-fresh-host (ADR-0079)" },
        // Internal-vocabulary rule: a CapTP session is a `Session`, never a
        // `Conn`. conn/connection names only a byte stream, so the byte-fed
        // host tier must not respell its per-partner session as the byte-stream
        // `Conn` it once collided with in the same C ABI (ADR-0079 amendment).
        .{ .path = "include/pancake_driver.h", .needle = "PancakeHostConn", .reason = "PancakeHostSession — a CapTP session is not a byte-stream Conn (ADR-0079)" },
        .{ .path = "include/pancake_driver.h", .needle = "pancake_host_conn_", .reason = "pancake_host_session_* — a CapTP session is not a byte-stream conn (ADR-0079)" },
        .{ .path = "src/c_abi/driver/mod.zig", .needle = "PancakeHostConn", .reason = "PancakeHostSession (ADR-0079)" },
        .{ .path = "src/c_abi/driver/mod.zig", .needle = "pancake_host_conn_", .reason = "pancake_host_session_* (ADR-0079)" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub const Conn ", .reason = "driver_core.Session — the byte-fed CapTP session is a Session (ADR-0079)" },
        // A public host-verb / PancakeHostAction field must not name a session
        // pointer `conn` — the exact conn-means-session residue review caught.
        .{ .path = "include/pancake_driver.h", .needle = "PancakeHostSession *conn", .reason = "name the session-pointer param/field `session`, not `conn` (ADR-0079)" },
        .{ .path = "include/pancake_driver.h", .needle = "out_conn", .reason = "name the out-session param `out_session`, not `out_conn` (ADR-0079)" },
        // Item-2 part 3: the byte-fed session type is `HostSession`, its id is
        // `PeerId` (the engine routes to Peers), and the Host releases sessions.
        .{ .path = "src/driver/core/host.zig", .needle = "pub const Session = struct", .reason = "the byte-fed CapTP session type is HostSession, never Session/Conn (ADR-0079)" },
        .{ .path = "src/driver/core/host.zig", .needle = "pub fn releaseConn", .reason = "releaseSession — the Host releases a HostSession, not a conn (ADR-0079)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const ConnId", .reason = "PeerId — the engine's routing id keys Peers, not byte-stream conns (ADR-0079)" },
        // Item-2 part 4: the Node registers/routes Peers, not conns — it returns
        // a PeerId and installs an engine.Peer.
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub fn registerConn", .reason = "registerPeer — the Node registers a Peer, not a byte-stream conn (ADR-0079)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "conns:", .reason = "the Node's Peer table is `peers`, not `conns` (ADR-0079)" },
    };
    for (symbol_bans) |ban| {
        const contents = root.readFileAlloc(io, ban.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary check with {s}", .{ ban.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, ban.needle) != null) {
            try appendViolation(gpa, violations, "{s}: contains `{s}` — {s}", .{ ban.path, ban.needle, ban.reason });
        }
    }

    // The driver family must carry the renamed session type / symbol — the
    // positive half of the internal-vocabulary rule (ADR-0079 amendment).
    const driver_header = root.readFileAlloc(io, "include/pancake_driver.h", gpa, .limited(4 << 20)) catch return;
    defer gpa.free(driver_header);
    for ([_][]const u8{ "PancakeHostSession", "pancake_host_session_" }) |needle| {
        if (std.mem.indexOf(u8, driver_header, needle) == null) {
            try appendViolation(gpa, violations, "include/pancake_driver.h: missing `{s}` — the byte-fed CapTP session family (ADR-0079)", .{needle});
        }
    }

    // Item-2 part 3 positive half: the Zig type / id renames landed.
    const positive = [_]struct { path: []const u8, needle: []const u8, what: []const u8 }{
        .{ .path = "src/driver/core/host.zig", .needle = "pub const HostSession", .what = "the byte-fed CapTP session Zig type (aligns with PancakeHostSession)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub const PeerId", .what = "the engine's Peer routing id (was ConnId)" },
        .{ .path = "src/ocapn/engine/node.zig", .needle = "pub fn registerPeer", .what = "the Node registers Peers (was registerConn)" },
    };
    for (positive) |p| {
        const contents = root.readFileAlloc(io, p.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP vocabulary positive check with {s}", .{ p.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, p.needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` — {s} (ADR-0079)", .{ p.path, p.needle, p.what });
        }
    }
}

/// `host_pump.zig` is Host-private pump mechanics: only `src/driver/core/host.zig`
/// may import it. Cross-file `pub fn` stays for Zig module visibility; this gate
/// is what keeps the boundary from rotting into a second public API.
fn checkHostPumpImportGate(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const allowed = "src/driver/core/host.zig";
    const needle = "@import(\"host_pump.zig\")";
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for host_pump import gate with {s}", .{@errorName(err)});
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
        if (std.mem.eql(u8, path, allowed)) continue;
        if (std.mem.eql(u8, path, "src/driver/core/host_pump.zig")) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for host_pump import gate with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, needle) != null) {
            try appendViolation(gpa, violations, "{s}: imports host_pump.zig — only {s} may (Host private pump)", .{ path, allowed });
        }
    }
}

/// The C ABI consumes `Served` through its surface verbs (`spawnHosted`,
/// `bindExport`, `refForExport`, …), never by reaching through the embedded
/// vat: `.served.vat` under `src/c_abi/` is a boundary violation.
fn checkCAbiServedSurface(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src/c_abi", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi: failed to open for Served-surface check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const contents = dir.readFileAlloc(io, entry.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "src/c_abi/{s}: failed to read for Served-surface check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, ".served.vat") != null) {
            try appendViolation(gpa, violations, "src/c_abi/{s}: reaches `.served.vat` — the C ABI talks to Served through its surface verbs only", .{entry.path});
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

/// Product CLI CapTP waits must be finite (ADR-0081). Empty `SessionOptions`
/// (`handshake_timeout_ms` / `settle_timeout_ms` default 0) parks forever on a
/// silent peer — the hang that wedged `cli-test` and left zombie test binaries.
fn checkCliCaptpDeadlines(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "pub fn sessionOpts()",
        "default_handshake_timeout_ms",
        "default_settle_timeout_ms",
        "HandshakeTimedOut",
        "sessionOpts()",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/session_cases.zig", &.{
        "sessionOpts()",
        "HandshakeTimedOut",
        "handshake_timeout_ms = 200",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "cmdListen",
        "cmdCall",
        "publish",
        "greeter",
        "requestStop while accepting",
        "requestStop while serving",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/all.zig", &.{
        "captp_cases.zig",
    });

    var dir = root.openDir(io, "cli", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "cli/: failed to open for CapTP-deadline check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "cli/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP-deadline check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, "handshake_timeout_ms: 0") != null or
                std.mem.indexOf(u8, line, "handshake_timeout_ms = 0") != null or
                std.mem.indexOf(u8, line, "settle_timeout_ms: 0") != null or
                std.mem.indexOf(u8, line, "settle_timeout_ms = 0") != null)
            {
                try appendViolation(gpa, violations, "{s}:{d}: CapTP wait budget must be finite in cli/ (0 parks forever on a silent peer; use sessionOpts() or a positive ms)", .{ path, line_no });
            }
            // Empty SessionOptions on connect/listen — the default opts are unbounded.
            if (std.mem.indexOf(u8, line, "connectUriOwned(") != null and std.mem.indexOf(u8, line, ", .{})") != null) {
                try appendViolation(gpa, violations, "{s}:{d}: connectUriOwned with empty SessionOptions `.{{}}` is unbounded; pass sessionOpts() or an explicit positive handshake budget", .{ path, line_no });
            }
            if (std.mem.indexOf(u8, line, "driver.listen(") != null and std.mem.indexOf(u8, line, ", .{})") != null) {
                try appendViolation(gpa, violations, "{s}:{d}: driver.listen with empty SessionOptions `.{{}}` is unbounded; pass sessionOpts()", .{ path, line_no });
            }
        }
    }
}

/// Ctrl+C on `ocapn listen` must poll `waitAcceptable` rather than close the
/// listen FD from another thread (Zig Threaded Io panics on that BADF).
fn checkCliListenStopWake(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try expectFileContains(io, gpa, root, violations, "cli/operability/signals.zig", &.{
        "accept-after-close",
        "must not close a listen FD",
        "pub const poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "cli/ocapn/mod.zig", &.{
        "waitAcceptable",
        "serveUntilStop",
        "signals.poll_ms",
    });
    try expectFileContains(io, gpa, root, violations, "src/net/netlayer.zig", &.{
        "waitAcceptable",
    });
    try expectFileContains(io, gpa, root, violations, "test/cli/captp_cases.zig", &.{
        "requestStop while accepting",
        "requestStop while serving",
    });
    try expectFileContains(io, gpa, root, violations, "docs/boundaries.md", &.{
        "waitAcceptable",
        "Zig threaded Io panics on that BADF",
    });

    // Tombstones: close-from-watcher and CapTP self-dial wake both regress BADF
    // or invent stop-path CapTP cost the poll seat already forbids.
    const tombstones = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/ocapn/mod.zig", .needle = "Closable", .why = "Closable closed the listen FD from the stop watcher (BADF panic); use waitAcceptable" },
        .{ .path = "cli/ocapn/mod.zig", .needle = "parked_in_accept", .why = "CapTP self-dial wake retired; poll Listener.waitAcceptable against the stop latch" },
        .{ .path = "cli/operability/signals.zig", .needle = "Closable", .why = "Closable name retired; StopWatch is MCP's stdin closer, not listen wake" },
        .{ .path = "docs/boundaries.md", .needle = "shared Io closer", .why = "listen and mcp share only the stop latch, not an Io closer" },
        .{ .path = "docs/boundaries.md", .needle = "dialing its own URI", .why = "listen stop polls waitAcceptable; CapTP self-dial wake is retired" },
    };
    for (tombstones) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for listen-stop check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
}

/// CapTP lab chrome/docs must match live keys: listen is argv-only; F1 (not
/// prompt `?`) opens the help modal; no stub search theater; no product-taste
/// names in `cli/repl` module headers.
fn checkCaptpLabUxHonesty(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tombstones = [_]struct { path: []const u8, needle: []const u8, why: []const u8 }{
        .{ .path = "cli/repl/panes.zig", .needle = "dial or listen", .why = "empty-session chrome must invite dial only (listen is argv-only)" },
        .{ .path = "cli/repl/panes.zig", .needle = "F1 / ?", .why = "help modal must not claim prompt ? opens it (F1 does; ? is tip at prompt)" },
        .{ .path = "docs/cli.md", .needle = "dial` / `listen` inside", .why = "lab starts with dial inside; listen stays argv-only" },
        .{ .path = ".agents/skills/pancake-cli/SKILL.md", .needle = "dial/listen inside", .why = "skill session table: dial inside; listen argv-only" },
        .{ .path = "cli/repl/tui.zig", .needle = "Claude Code", .why = "taste as structure, not product names in committed headers" },
        .{ .path = "cli/repl/tui.zig", .needle = "stub — use Ctrl-O", .why = "search stub theater deleted; do not reintroduce" },
        .{ .path = "cli/repl/ecs/intent.zig", .needle = "search_start", .why = "search stub intents deleted until a real search mode exists" },
        .{ .path = "cli/repl/ecs/intent.zig", .needle = "hover_at", .why = "dead hover intent deleted; mouse handles hits inline" },
        .{ .path = "cli/argv.zig", .needle = "ocapn_flags", .why = "pre-tree CapTP argv helpers deleted; tree/registry own parse" },
        .{ .path = "cli/argv.zig", .needle = "peelGlobals", .why = "pre-tree CapTP argv helpers deleted; cmd/mod owns globals" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"version\":\"0.1.0\"", .why = "MCP serverInfo.version must come from build_options, not a hard-coded literal" },
        .{ .path = "cli/mcp/mod.zig", .needle = "Content-Length", .why = "MCP stdio is NDJSON per the MCP transport spec; LSP Content-Length framing breaks Cursor/Claude" },
        .{ .path = "cli/mcp/mod.zig", .needle = "\"]}}}\"", .why = "tools/list closes with ]}} (array+result+root); an extra brace makes Cursor drop the catalog" },
        .{ .path = "cli/registry.zig", .needle = "if (std.mem.eql(u8, cmd.name, \"listen\")) continue", .why = "use leafVisible; no ad-hoc listen skip lists" },
        .{ .path = "cli/cmd/tree.zig", .needle = "held; not yet on the wire", .why = "rooms-peer --dm ships via directory introduce; help must not claim held" },
        .{ .path = "cli/cmd/tree.zig", .needle = ".name = \"bot\"", .why = "rooms presence leaf is rooms-peer, not bot" },
        .{ .path = "cli/cmd/tree.zig", .needle = "Application fronts (bot)", .why = "app short_help names rooms-peer, not bot" },
        .{ .path = "build.zig", .needle = "rooms-bot", .why = "install/run step is rooms-peer" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "remaining milestone", .why = "DM introduce/tell shipped; do not reintroduce a silent skip" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "not-implemented", .why = "reply --dm writes outbox; not a not-implemented stub" },
        .{ .path = "cli/app/rooms_peer/verbs.zig", .needle = "BotFailed", .why = "rooms-peer soft fail is PeerFailed/UsageFailed" },
        .{ .path = "cli/app/rooms_peer/supervise.zig", .needle = "botCliPrefix", .why = "prefix helper is peerCliPrefix" },
        .{ .path = "cli/app/rooms_peer/peer.zig", .needle = "BotState", .why = "daemon state type is PeerState" },
        .{ .path = ".agents/skills/rooms-peer/SKILL.md", .needle = "rooms-bot", .why = "skill vocabulary is rooms-peer" },
        .{ .path = ".agents/skills/rooms-peer/SKILL.md", .needle = "One bot per nick", .why = "skill rules say one peer per nick" },
    };
    for (tombstones) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for CapTP lab UX check with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, row.needle) != null) {
            try appendViolation(gpa, violations, "{s}: forbidden needle `{s}` — {s}", .{ row.path, row.needle, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "cli/repl/panes.zig", &.{
        "F1       this help",
        "dial an ocapn:// locator",
    });
    try expectFileContains(io, gpa, root, violations, "cli/registry.zig", &.{
        "leafVisible",
        "flagVisibleMcp",
        "argv_only",
        "mcp_hide",
    });
    try expectFileContains(io, gpa, root, violations, "cli/app/rooms_peer/peer.zig", &.{
        "registerWithDirectory",
        "startIntroduce",
        "publishDm",
    });
}

/// ADR-0009 introducing-session promise proxy: production callers must stay
/// wired on Node/Host, and the retired unfinished Host needle must not return.
/// One settlement spine: `applyRelayedResolution`. The deleted Peer queue
/// (`relayResolution` / `drainRelayedResolutions`) must not return under src/.
fn checkUnwiredHostPluginApis(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const retired_needle = "Host does not yet call `Peer.relayResolution`";
    const boundaries = root.readFileAlloc(io, "docs/boundaries.md", gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "docs/boundaries.md: failed to read for host-plugin check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(boundaries);
    if (std.mem.indexOf(u8, boundaries, retired_needle) != null) {
        try appendViolation(gpa, violations, "docs/boundaries.md: unfinished needle `{s}` must stay retired — introducing-session promise proxy is live on Node/Host", .{retired_needle});
    }

    const rows = [_]struct { call_needle: []const u8, def_path: []const u8 }{
        .{ .call_needle = ".applyRelayedResolution(", .def_path = "src/ocapn/engine/mod.zig" },
        .{ .call_needle = ".installThirdPartyImport(", .def_path = "src/ocapn/session/imported_promise.zig" },
    };
    for (rows) |row| {
        if (!try srcHasCallOutsideDef(io, gpa, root, row.call_needle, row.def_path)) {
            try appendViolation(gpa, violations, "host-plugin API `{s}` lost its production caller under src/ — Node promise proxy must keep calling it", .{row.call_needle});
        }
    }

    // Deleted queue spine must not reappear under production src/.
    if (try srcHasCallOutsideDef(io, gpa, root, ".relayResolution(", "src/ocapn/engine/mod.zig")) {
        try appendViolation(gpa, violations, "deleted Peer.relayResolution reappeared under src/ — settle via applyRelayedResolution only", .{});
    }
    if (try srcHasCallOutsideDef(io, gpa, root, "drainRelayedResolutions(", "src/ocapn/engine/cross_peer.zig")) {
        try appendViolation(gpa, violations, "deleted drainRelayedResolutions reappeared under src/ — settle via applyRelayedResolution only", .{});
    }
    // Relayed path moves; a public/production resolution deep-clone must not return.
    const clone_ban_paths = [_]struct { path: []const u8, why: []const u8 }{
        .{ .path = "src/ocapn/model/owned.zig", .why = "cloneResolution must stay deleted — relayed settlement moves (memory.md)" },
        .{ .path = "src/ocapn/model/mod.zig", .why = "cloneResolution export must stay deleted — relayed settlement moves (memory.md)" },
        .{ .path = "src/ocapn/engine/node.zig", .why = "public cloneResolution must stay deleted — proxy uses materializeResolutionForStore (memory.md)" },
    };
    for (clone_ban_paths) |row| {
        const contents = root.readFileAlloc(io, row.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for cloneResolution ban with {s}", .{ row.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "cloneResolution") != null) {
            try appendViolation(gpa, violations, "{s}: `{s}`", .{ row.path, row.why });
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/model/owned.zig", &.{
        "materializeResolutionForStore",
    });
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "proxyForeignPromiseFulfill",
        "consumeProxyListenerFire",
        "claimProxyListenerFire",
        "isProxyHomeListener",
        "materializeResolutionForStore",
        "proxy_by_listener",
        "PendingDialView",
        "pub fn pendingDial",
        "pending_dial_by_identity",
        "stagePendingDial",
        "freePendingDialShell",
        "freeDialParts",
        "freeDialPart",
        "unparseable exporter locator",
        "dial: struct { pending: PendingId }",
        "applyRelayedResolution",
        "installThirdPartyImport",
        "session_not_open",
    });
    // Ticket-only dial action: dial parts live on the pending row alone.
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "action_locator")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: action_locator must stay deleted — pending row owns dial parts", .{});
    }
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "allocator.dupe(u8, exporter_locator)")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: acceptGive must not dupe the verbatim exporter URI — pending row owns parts only", .{});
    }
    if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", "dial: struct { pending: PendingId, locator:")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: Action.dial must not carry locator — use pendingDial", .{});
    }
    // Zig dual borrow API must stay deleted — one pendingDial view.
    for ([_][]const u8{ "pub fn pendingDialLocator", "pub fn pendingDialParts", "PendingDialParts" }) |needle| {
        if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", needle)) {
            try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: `{s}` must stay deleted — use pendingDial / PendingDialView", .{needle});
        }
    }
    // Named materialize is for the proxy fire owner only — not a free fan-out API.
    if (try srcHasCallOutsideAllowlist(io, gpa, root, "materializeResolutionForStore(", &.{
        "src/ocapn/engine/node.zig",
        "src/ocapn/model/owned.zig",
    })) {
        try appendViolation(gpa, violations, "materializeResolutionForStore called outside node.zig — proxy fire path only (memory.md)", .{});
    }
    // Withdraw moves; pre-row clone must not return on the settle path.
    if (try fileContains(io, gpa, root, "src/ocapn/engine/bootstrap.zig", "cloneReference")) {
        try appendViolation(gpa, violations, "src/ocapn/engine/bootstrap.zig: cloneReference must stay deleted — applyWithdraw moves verbatim caps", .{});
    }
    // Enliven: session owns swissnum; Host bridge keys on answer only.
    for ([_][]const u8{
        "mintEnlivenVow(session, swissnum,",
        "mintEnlivenVow(self, session, swissnum,",
        ".swissnum = owned",
        "swissnum: []const u8,\n    vow_id",
        "swissnum: []u8,\n    vow_id",
    }) |needle| {
        if (try fileContains(io, gpa, root, "src/driver/core/host.zig", needle)) {
            try appendViolation(gpa, violations, "src/driver/core/host.zig: EnlivenListener/mintEnlivenVow must not own swissnum — session pending row owns it", .{});
            break;
        }
    }
    // Cap'n Proto set encode-once: deleted 2N helpers must not return.
    for ([_][]const u8{ "canonicalSetOrder", "encodeArgumentKey" }) |needle| {
        if (try fileContains(io, gpa, root, "src/ocapn/codec/capnp/encode.zig", needle)) {
            try appendViolation(gpa, violations, "src/ocapn/codec/capnp/encode.zig: `{s}` must stay deleted — use encodeArgumentSetList", .{needle});
        }
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/codec/capnp/encode.zig", &.{
        "encodeArgumentSetList",
    });
    try expectFileContains(io, gpa, root, violations, "src/driver/core/host.zig", &.{
        "isProxyHomeListener",
        "claimProxyListenerFire",
        "pendingEnlivenSwissnum",
    });
    try expectFileContains(io, gpa, root, violations, "test/engine/relay_resolution_test.zig", &.{
        "applyRelayedResolution",
        "installThirdPartyImport",
        "desc:export",
    });
    try expectFileContains(io, gpa, root, violations, "test/all_test.zig", &.{
        "relay_resolution_test.zig",
        "equality_test.zig",
    });
    try expectFileContains(io, gpa, root, violations, "test/model/equality_test.zig", &.{
        "view equality and hash agree with the owned spine",
    });
    try expectFileContains(io, gpa, root, violations, "test/engine/node_test.zig", &.{
        "proxyForeignPromiseFulfill",
        "consumeProxyListenerFire",
        "session_not_open",
        "multi-introduce",
    });
    // Ticket-only HostAction.dial: dialActionFields / action-carried locator
    // must stay deleted (pending row owns dial parts; memory.md).
    if (try fileContains(io, gpa, root, "src/driver/core/host_pump.zig", "fn dialActionFields")) {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: dialActionFields must stay deleted — ticket-only HostAction.dial", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/core/host_action.zig", "locator: []const u8")) {
        try appendViolation(gpa, violations, "src/driver/core/host_action.zig: HostAction.dial must not carry locator — use pendingDial", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/core/host_action.zig", "pancake_host_pending_dial_*")) {
        try appendViolation(gpa, violations, "src/driver/core/host_action.zig: stale pending_dial_* plural — use pancake_host_pending_dial", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/core/host.zig", &.{
        "pub fn pendingDial",
        "PendingDialView",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/host.zig", &.{
        "pancake_host_pending_dial",
        "PancakePendingDial",
        "inst.core.pendingDial",
    });
    try expectFileContains(io, gpa, root, violations, "src/c_abi/driver/mod.zig", &.{
        "pub const PancakePendingDial",
    });
    // Dual C pending-dial exports must stay deleted — one struct view.
    for ([_][]const u8{ "pancake_host_pending_dial_locator", "pancake_host_pending_dial_parts" }) |needle| {
        if (try fileContains(io, gpa, root, "src/c_abi/driver/host.zig", needle)) {
            try appendViolation(gpa, violations, "src/c_abi/driver/host.zig: `{s}` must stay deleted — use pancake_host_pending_dial", .{needle});
        }
        if (try fileContains(io, gpa, root, "include/pancake_driver.h", needle)) {
            try appendViolation(gpa, violations, "include/pancake_driver.h: `{s}` must stay deleted — use pancake_host_pending_dial", .{needle});
        }
    }
    // Redeem dial must not re-parse the pending URI on Host/Bridge.
    if (try fileContains(io, gpa, root, "src/driver/core/host_pump.zig", "dialDesignatorForReuse")) {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: dialDesignatorForReuse must stay deleted — pendingDial owns the designator", .{});
    }
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "parsePeer(bridge.allocator")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: Exec.dial must not parsePeer — use pendingDial", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/driver/bridge.zig", &.{
        "OutboundConnect",
        "pending_connects",
        "connectOutbound",
        ".{ .redeem = d.ticket }",
        // Ticket-only redeem arm — app_dial alone owns connect-window string copies.
        "redeem: engine.Node.PendingId",
        "app_dial: struct { transport: []u8, designator: []u8 }",
    });
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "const PendingDial = struct")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: PendingDial must stay deleted — use OutboundConnect", .{});
    }
    for ([_][]const u8{ "DialKind", "submitPendingDial", "submitRedeemDial", "pending_dials:", "pending dial parts missing" }) |needle| {
        if (try fileContains(io, gpa, root, "src/driver/bridge.zig", needle)) {
            try appendViolation(gpa, violations, "src/driver/bridge.zig: `{s}` must stay deleted — OutboundConnect + acceptGive own the invariant", .{needle});
        }
    }
    // makeConnCtx must open dialed peers in one OutboundConnect switch (no
    // parallel pieces/leg/refuse switches on the same pending value).
    if (try fileContains(io, gpa, root, "src/driver/bridge.zig", "const pieces: struct { transport: []const u8, designator: []const u8 } = switch (pending)")) {
        try appendViolation(gpa, violations, "src/driver/bridge.zig: makeConnCtx must not split OutboundConnect into a pieces switch — one adopt switch", .{});
    }
    if (try fileContains(io, gpa, root, "tools/gen/header/driver.zig", "Empty transport/designator means")) {
        try appendViolation(gpa, violations, "tools/gen/header/driver.zig: empty-parts-as-unparseable prose must stay deleted — acceptGive fails unparseable closed", .{});
    }
    try expectFileContains(io, gpa, root, violations, "src/ocapn/engine/node.zig", &.{
        "UnparseableExporterLocator",
    });
    // exporterDialed must free dial parts through freeDialPart (empty hint sentinel).
    for ([_][]const u8{
        "allocator.free(entry.transport)",
        "allocator.free(entry.designator)",
        "allocator.free(entry.direct_addresses_hint)",
    }) |raw_free| {
        if (try fileContains(io, gpa, root, "src/ocapn/engine/node.zig", raw_free)) {
            try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: exporterDialed must not raw-free dial parts ({s}) — use freePendingDialShell", .{raw_free});
        }
    }
    // Host dial harness must borrow the dial view, not re-parse the locator.
    if (try fileContains(io, gpa, root, "test/driver/core_host_test.zig", "parsePeer(allocator, pending)")) {
        try appendViolation(gpa, violations, "test/driver/core_host_test.zig: dial arm must use pendingDial, not parsePeer", .{});
    }
    // Session inspect walks live in inspect.zig; Session method forwards stay deleted.
    try expectFileContains(io, gpa, root, violations, "src/ocapn/session/inspect.zig", &.{
        "forEachExport",
        "ExportView",
    });
    if (try fileContains(io, gpa, root, "src/ocapn/session/mod.zig", "pub fn forEachExport")) {
        try appendViolation(gpa, violations, "src/ocapn/session/mod.zig: Session.forEachExport must stay deleted — use inspect.forEachExport", .{});
    }
    try expectFileContains(io, gpa, root, violations, "test/all_test.zig", &.{
        "inspect_test.zig",
    });
    try expectFileContains(io, gpa, root, violations, "test/session/inspect_test.zig", &.{
        "session inspect walks export and import rows",
        "inspect.forEachExport",
    });
    // Redeem path must open from pendingDial parts, not re-parse parked.locator.
    if (try fileContains(io, gpa, root, "test/driver/core_host_test.zig", "parsePeer(allocator, parked.locator)")) {
        try appendViolation(gpa, violations, "test/driver/core_host_test.zig: redeem must use pendingDial parts, not parsePeer(parked.locator)", .{});
    }
    // O(1) crossed-hellos tiebreak: must use dialed_by_designator, not a full
    // sessions scan (smell-annihilation / ADR-0012 scale).
    const host_src = root.readFileAlloc(io, "src/driver/core/host.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host.zig: failed to read for tiebreak index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(host_src);
    if (std.mem.indexOf(u8, host_src, "fn tiebreakInbound")) |fn_start| {
        const body = host_src[fn_start..];
        const body_end = std.mem.indexOf(u8, body, "\n};") orelse body.len;
        const tiebreak = body[0..body_end];
        if (std.mem.indexOf(u8, tiebreak, "valueIterator") != null) {
            try appendViolation(gpa, violations, "src/driver/core/host.zig: tiebreakInbound must not scan sessions.valueIterator — use dialed_by_designator", .{});
        }
        if (std.mem.indexOf(u8, tiebreak, "dialed_by_designator") == null) {
            try appendViolation(gpa, violations, "src/driver/core/host.zig: tiebreakInbound must consult dialed_by_designator", .{});
        }
    } else {
        try appendViolation(gpa, violations, "src/driver/core/host.zig: tiebreakInbound missing", .{});
    }
}

/// HostAction / Node.Action / C embedder_pump arm parity: a seventh action kind
/// must fail the build rather than silently drop in one of three switch spines.
fn checkHostActionArmLockstep(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const header_path = "include/pancake_driver.h";
    const header = root.readFileAlloc(io, header_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for HostAction arm lockstep with {s}", .{ header_path, @errorName(err) });
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
        try appendViolation(gpa, violations, "{s}: no PANCAKE_HOST_ACTION_* for HostAction arm lockstep", .{header_path});
        return;
    }

    const zig_action = root.readFileAlloc(io, "src/driver/core/host_action.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host_action.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(zig_action);
    // Zig HostAction tags (snake) must match header constants (SCREAMING).
    const zig_tags = [_][]const u8{ "dial", "flush", "close", "need_gift_id", "settled", "failed" };
    if (action_names.items.len != zig_tags.len) {
        try appendViolation(gpa, violations, "HostAction arm lockstep: header has {d} PANCAKE_HOST_ACTION_* but Zig HostAction expects {d} tags", .{ action_names.items.len, zig_tags.len });
    }
    for (zig_tags) |tag| {
        if (std.mem.indexOf(u8, zig_action, tag) == null) {
            try appendViolation(gpa, violations, "src/driver/core/host_action.zig: missing HostAction tag `{s}`", .{tag});
        }
    }

    const embedder = root.readFileAlloc(io, "src/c_abi/driver/embedder_pump.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/c_abi/driver/embedder_pump.zig: failed to read for HostAction arm lockstep with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(embedder);
    for (action_names.items) |name| {
        var token_buf: [96]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buf, "PANCAKE_HOST_ACTION_{s}", .{name}) catch {
            try appendViolation(gpa, violations, "HostAction arm lockstep: action name `{s}` too long", .{name});
            continue;
        };
        if (std.mem.indexOf(u8, embedder, token) == null) {
            // SETTLE and FAIL share the complete arm in embedder_pump.
            if (std.mem.eql(u8, name, "SETTLE") or std.mem.eql(u8, name, "FAIL")) {
                if (std.mem.indexOf(u8, embedder, "PANCAKE_HOST_ACTION_SETTLE") != null and
                    std.mem.indexOf(u8, embedder, "PANCAKE_HOST_ACTION_FAIL") != null) continue;
            }
            try appendViolation(gpa, violations, "src/c_abi/driver/embedder_pump.zig: missing drain arm for `{s}`", .{token});
        }
    }

    // Node.Action tags must each have an execNodeAction arm (settle/fail stay
    // in-process on the vat; they are not HostAction variants).
    const node_src = root.readFileAlloc(io, "src/ocapn/engine/node.zig", gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: failed to read for Node.Action parity with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(node_src);
    const pump_src = root.readFileAlloc(io, "src/driver/core/host_pump.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: failed to read for Node.Action parity with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pump_src);
    const node_tags = [_][]const u8{ "dial", "flush", "settle", "fail", "need_gift_id" };
    const action_union = "pub const Action = union(enum)";
    const action_at = std.mem.indexOf(u8, node_src, action_union) orelse {
        try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: Node.Action union missing", .{});
        return;
    };
    const action_body = node_src[action_at..];
    const exec_at = std.mem.indexOf(u8, pump_src, "fn execNodeAction") orelse {
        try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: execNodeAction missing", .{});
        return;
    };
    const exec_body = pump_src[exec_at..];
    const exec_end = std.mem.indexOf(u8, exec_body, "\n}") orelse exec_body.len;
    const exec = exec_body[0..exec_end];
    for (node_tags) |tag| {
        var arm_buf: [64]u8 = undefined;
        const arm = std.fmt.bufPrint(&arm_buf, ".{s} =>", .{tag}) catch unreachable;
        if (std.mem.indexOf(u8, action_body, tag) == null) {
            try appendViolation(gpa, violations, "src/ocapn/engine/node.zig: Node.Action missing tag `{s}`", .{tag});
        }
        if (std.mem.indexOf(u8, exec, arm) == null) {
            try appendViolation(gpa, violations, "src/driver/core/host_pump.zig: execNodeAction missing arm for Node.Action.{s}", .{tag});
        }
    }
}

fn fileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    needle: []const u8,
) !bool {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return false;
    defer gpa.free(contents);
    return std.mem.indexOf(u8, contents, needle) != null;
}

/// Like `srcHasCallOutsideDef`, but allows a small set of definition/call sites.
fn srcHasCallOutsideAllowlist(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    call_needle: []const u8,
    allow: []const []const u8,
) !bool {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        var allowed = false;
        for (allow) |a| {
            if (std.mem.eql(u8, path, a)) {
                allowed = true;
                break;
            }
        }
        if (allowed) continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

fn srcHasCallOutsideDef(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    call_needle: []const u8,
    def_path: []const u8,
) !bool {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        if (std.mem.eql(u8, path, def_path)) continue;
        if (std.mem.eql(u8, path, "src/ocapn/session/mod.zig") and
            std.mem.eql(u8, call_needle, ".installThirdPartyImport("))
            continue;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.indexOf(u8, line, call_needle) != null) return true;
        }
    }
    return false;
}

/// ADR names belong in docs and comments, never in strings that can reach a
/// panic message, CapTP abort text, log line, or other runtime surface.
fn checkNoAdrInRuntimeStrings(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const roots = [_][]const u8{ "src", "interop" };
    for (roots) |rel| {
        var dir = root.openDir(io, rel, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for ADR-runtime-string check with {s}", .{ rel, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.path });
            defer gpa.free(path);
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for ADR-runtime-string check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            var line_no: usize = 1;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                if (zigLineHasAdrInStringLiteral(line)) {
                    try appendViolation(gpa, violations, "{s}:{d}: ADR citation in a string literal — keep ADR names in comments/docs, not panic/abort/log text", .{ path, line_no });
                }
            }
        }
    }
}

/// True when a double-quoted Zig string literal on `line` contains `ADR-`.
/// Line comments (`//`) outside strings are ignored. Multiline strings and
/// character literals are out of scope (ADR citations do not live there).
fn zigLineHasAdrInStringLiteral(line: []const u8) bool {
    var i: usize = 0;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!in_string) {
            if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return false;
            if (c == '"') {
                in_string = true;
            }
            continue;
        }
        if (c == '\\') {
            i += 1; // skip escaped byte
            continue;
        }
        if (c == '"') {
            in_string = false;
            continue;
        }
        if (c == 'A' and i + 4 <= line.len and std.mem.eql(u8, line[i..][0..4], "ADR-")) {
            return true;
        }
    }
    return false;
}

test "zigLineHasAdrInStringLiteral ignores comments and flags string literals" {
    try std.testing.expect(!zigLineHasAdrInStringLiteral("// (ADR-0082) comment only"));
    try std.testing.expect(!zigLineHasAdrInStringLiteral("const x = 1; // (ADR-0001)"));
    try std.testing.expect(zigLineHasAdrInStringLiteral("@panic(\"needs store (ADR-0082)\");"));
    try std.testing.expect(zigLineHasAdrInStringLiteral(".message = \"cap (ADR-0025)\","));
    try std.testing.expect(!zigLineHasAdrInStringLiteral(".message = \"cap exceeded\","));
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

test "collectCaptpRegistryNames takes Command rows only" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    const src =
        \\pub const commands = [_]Command{
        \\    .{
        \\        .name = "listen",
        \\        .help = "Bind",
        \\        .positionals = &[_]Positional{.{ .name = "locator", .help = "uri" }},
        \\    },
        \\    .{
        \\        .name = "dial",
        \\        .help = "Dial",
        \\    },
        \\};
    ;
    try collectCaptpRegistryNames(gpa, src, &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("listen", names.items[0]);
    try std.testing.expectEqualStrings("dial", names.items[1]);
}

test "captpVerbTableIsPartial catches incomplete inventory tables" {
    const names = [_][]const u8{ "listen", "dial", "probe", "call" };
    try std.testing.expect(captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial(
        "| Verb | Role |\n| --- | --- |\n| `listen` | host |\n| `dial` | dial |\n| `probe` | poke |\n| `call` | act |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial(
        "| Front | Shape |\n| --- | --- |\n| argv | `call` / `tell` / `fetch` / `probe` |\n",
        &names,
    ));
    try std.testing.expect(!captpVerbTableIsPartial("defer to `pancake help`", &names));
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
