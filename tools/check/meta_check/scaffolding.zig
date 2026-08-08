//! The agent-scaffolding checks.
//!
//! Cursor and Claude overlays complete and unbroken, Codex direct-loading kept
//! free of duplicate mirrors, the hook and MCP configurations, rule/skill/persona
//! index parity in both directions (including skill purpose parity across the
//! two catalogs and the ratchet skill's landing map), agent routing, and rule
//! frontmatter. These are the checks that keep the scaffolding a public API
//! whose consumers act on what it says. Wired by the meta-check driver
//! (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;
const getField = util.getField;
const jsonStringEquals = util.jsonStringEquals;
const parseJsonFile = util.parseJsonFile;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

const expected_hook_command = "bash .agents/hooks/format-edited-file.sh";

pub fn expectSymlink(
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

pub fn expectAbsent(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    reason: []const u8,
) !void {
    _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "{s}: absence check failed with {s}", .{ path, @errorName(err) });
            return;
        },
    };
    try appendViolation(gpa, violations, "{s}: must not exist; {s}", .{ path, reason });
}

pub fn checkCursorRuleOverlay(
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

pub fn checkRequiredSubstrings(
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
    try expectFileContains(io, gpa, root, violations, ".codex/README.md", &.{
        "AGENTS.md",
        ".agents/skills",
        "`.codex/skills` mirror",
        "bin/",
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
        "Context map",
    });
}

pub fn checkRuleIndexAgreement(
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

pub fn checkSkillCatalog(
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

        // A skill's purpose is one fact spelled in two tables; hold the
        // spellings identical so neither copy can drift behind the other.
        const catalog_purpose = tableRowThirdCell(readme, catalog_needle);
        const index_purpose = tableRowThirdCell(agents_readme, agents_needle);
        if (catalog_purpose != null and index_purpose != null and
            !std.mem.eql(u8, catalog_purpose.?, index_purpose.?))
        {
            try appendViolation(gpa, violations, "skill `{s}`: purpose text differs between .agents/README.md and .agents/skills/README.md; one fact, one spelling", .{entry.path});
        }
    }
}

/// Returns the trimmed third `|` cell of the first line containing `needle`,
/// or null when no such line or cell exists.
fn tableRowThirdCell(contents: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, contents, needle) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, contents[0..at], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, contents, at, '\n') orelse contents.len;
    var cells = std.mem.splitScalar(u8, contents[line_start..line_end], '|');
    _ = cells.next();
    _ = cells.next();
    const purpose = cells.next() orelse return null;
    return std.mem.trim(u8, purpose, " \t");
}

test "tableRowThirdCell reads the purpose cell of a matching table row" {
    const doc =
        "| Skill | Purpose |\n" ++
        "| ----- | ------- |\n" ++
        "| [ratchet](ratchet/SKILL.md) | Land the lesson |\n";
    try std.testing.expectEqualStrings("Land the lesson", tableRowThirdCell(doc, "[ratchet]").?);
    try std.testing.expect(tableRowThirdCell(doc, "[absent]") == null);
    try std.testing.expect(tableRowThirdCell("no pipes here [ratchet]", "[ratchet]") == null);
}

/// Project personas under `.agents/personas/` are anonymous lenses only.
/// Named taste references and person-channeling phrasing belong in user XDG
/// under `$XDG_CONFIG_HOME/agents/`, never in committed scaffolding. The
/// smell-annihilation skill is gated the same way for channeling language.
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

    const agents_readme = root.readFileAlloc(io, ".agents/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/README.md: failed to read for persona catalog with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(agents_readme);

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

        var catalog_buf: [128]u8 = undefined;
        const catalog_needle = std.fmt.bufPrint(&catalog_buf, "personas/{s}.md", .{stem}) catch continue;
        if (std.mem.indexOf(u8, agents_readme, catalog_needle) == null) {
            try appendViolation(gpa, violations, ".agents/README.md: missing Personas table entry for `{s}`", .{stem});
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

/// The ratchet skill's landing map names the meta-check modules by concern;
/// that list is a prose claim about `tools/check/meta_check/`, so it drifts
/// the moment a module lands unnamed. Both directions: every check module is
/// named in the skill (`util.zig` is shared helpers, not a landing target),
/// and every bare `.zig` span the skill names exists under `tools/check/` or
/// its `meta_check/` subdirectory.
pub fn checkRatchetModuleMap(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/ratchet/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for module-map check with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    var modules = root.openDir(io, "tools/check/meta_check", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "tools/check/meta_check: failed to open for module-map check with {s}", .{@errorName(err)});
        return;
    };
    defer modules.close(io);

    var it = modules.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "util.zig")) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "`{s}`", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, skill, needle) == null) {
            try appendViolation(gpa, violations, "{s}: landing map is missing meta-check module `{s}` (or exclude it deliberately in checkRatchetModuleMap)", .{ skill_path, entry.name });
        }
    }

    var rest = skill;
    while (std.mem.indexOfScalar(u8, rest, '`')) |start| {
        const after = rest[start + 1 ..];
        const end = std.mem.indexOfScalar(u8, after, '`') orelse break;
        const span = after[0..end];
        rest = after[end + 1 ..];
        if (!std.mem.endsWith(u8, span, ".zig")) continue;
        // Path-shaped spans are held by the Markdown link check instead.
        if (std.mem.indexOfScalar(u8, span, '/') != null) continue;

        var meta_buf: [192]u8 = undefined;
        const in_meta = std.fmt.bufPrint(&meta_buf, "tools/check/meta_check/{s}", .{span}) catch continue;
        if (root.access(io, in_meta, .{})) |_| continue else |_| {}
        var driver_buf: [192]u8 = undefined;
        const in_check = std.fmt.bufPrint(&driver_buf, "tools/check/{s}", .{span}) catch continue;
        if (root.access(io, in_check, .{})) |_| continue else |_| {}
        try appendViolation(gpa, violations, "{s}: names `{s}`, which is not a file under tools/check/ or tools/check/meta_check/", .{ skill_path, span });
    }
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
