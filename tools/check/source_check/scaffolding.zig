//! The agent-scaffolding checks: the Cursor and Claude overlays complete and
//! unbroken, the hook configurations, the Serena and glowcap MCP entries for
//! Claude, Pi, Codex, and Cursor, and the ignored Serena state.

const std = @import("std");
const json_files = @import("json_files.zig");
const markdown = @import("markdown.zig");
const text_match = @import("text_match.zig");
const violation_log = @import("violation_log.zig");

const appendViolation = violation_log.appendViolation;
const expectFileContains = text_match.expectFileContains;
const getField = json_files.getField;
const jsonStringEquals = json_files.jsonStringEquals;
const parseJsonFile = json_files.parseJsonFile;
const sectionBody = markdown.sectionBody;
const collectBulletSpans = markdown.collectBulletSpans;

// Cursor and Claude Code do not share a cwd guarantee for a hook command:
// Cursor runs `afterFileEdit` from the workspace root, but a Claude Code
// session's cwd tracks wherever the session last moved (a worktree switch, a
// `cd` inside a tool call), so a plain relative path resolves against the
// wrong directory and the hook fails with "no such file or directory" the
// moment the session is elsewhere. `${CLAUDE_PROJECT_DIR}` is the project's
// own env var for this, so only the Claude-side commands use it;
// forcing both hosts to the identical string would check the wrong invariant.
const expected_cursor_format_hook_command = "bash .agents/hooks/format-edited-file.sh";
const expected_claude_format_hook_command = "bash \"${CLAUDE_PROJECT_DIR}/.agents/hooks/format-edited-file.sh\"";

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

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
        if (std.mem.findScalar(u8, entry.path, '/') != null) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        canonical_count += 1;
        const stem = entry.path[0 .. entry.path.len - ".md".len];
        const cursor_path = try gpa.print(".cursor/rules/{s}.mdc", .{stem});
        const expected_target = try gpa.print("../../.agents/rules/{s}", .{entry.path});

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
        if (std.mem.findScalar(u8, entry.path, '/') != null) continue;
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
        const expected_target = try gpa.print("../../.agents/rules/{s}.md", .{stem});
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

        const canonical_path = try gpa.print(".agents/rules/{s}.md", .{stem});
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
    // Claude Code sessions start on the host, where Serena and zls are not
    // installed, so the server runs through the devcontainer front.
    try expectMcpServer(io, gpa, root, violations, ".mcp.json", ".agents/skills/work/bin/glowcap-dev", &.{
        "serena",
        "start-mcp-server",
        "--context",
        "claude-code",
        "--project-from-cwd",
    });
    // Pi reads a project MCP file of the same shape, through the same front.
    try expectMcpServer(io, gpa, root, violations, ".pi/mcp.json", ".agents/skills/work/bin/glowcap-dev", &.{
        "serena",
        "start-mcp-server",
        "--context",
        "claude-code",
        "--project-from-cwd",
    });
    try expectMcpServer(io, gpa, root, violations, ".cursor/mcp.json", "serena", &.{
        "start-mcp-server",
        "--context",
        "ide",
        "--project",
        "${workspaceFolder}",
    });
    try expectGlowcapMcpServer(io, gpa, root, violations, ".cursor/mcp.json", .cursor);
    try expectGlowcapMcpServer(io, gpa, root, violations, ".mcp.json", .claude);
    try expectFileContains(io, gpa, root, violations, ".gitignore", &.{
        ".local/",
        "site/assets/rooms/",
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
    // Codex has no JSON MCP file: its TOML entry is held to the same
    // devcontainer-front command as `.mcp.json`, in Serena's `codex` context.
    try expectFileContains(io, gpa, root, violations, ".codex/config.toml", &.{
        "[mcp_servers.serena]",
        "command = \".agents/skills/work/bin/glowcap-dev\"",
        "args = [\"serena\", \"start-mcp-server\", \"--context\", \"codex\", \"--project-from-cwd\"]",
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
    if (!arrayHasCommand(after_file_edit, expected_cursor_format_hook_command)) {
        try appendViolation(gpa, violations, ".cursor/hooks.json: `hooks.afterFileEdit` must invoke `{s}`", .{expected_cursor_format_hook_command});
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
    try expectClaudeHookEntry(gpa, violations, hooks, "PostToolUse", expected_claude_format_hook_command);
}

fn expectClaudeHookEntry(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    hooks: std.json.Value,
    event: []const u8,
    expected_command: []const u8,
) !void {
    const entries_field = getField(hooks, event) orelse {
        try appendViolation(gpa, violations, ".claude/settings.json: missing `hooks.{s}` array", .{event});
        return;
    };
    switch (entries_field) {
        .array => |entries| {
            for (entries.items) |entry| {
                if (getField(entry, "hooks")) |nested_hooks| {
                    if (arrayHasCommand(nested_hooks, expected_command)) return;
                }
            }
        },
        else => {},
    }
    try appendViolation(gpa, violations, ".claude/settings.json: `hooks.{s}[*].hooks` must invoke `{s}`", .{ event, expected_command });
}

fn expectMcpServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected_command: []const u8,
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
    if (!jsonStringEquals(command, expected_command)) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.serena.command` must be `{s}`", .{ path, expected_command });
    }

    const args = getField(serena, "args") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.serena.args`", .{path});
        return;
    };
    if (!jsonStringArrayEquals(args, expected_args)) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.serena.args` must match the canonical Serena invocation", .{path});
    }
}

const GlowcapMcpHost = enum { cursor, claude };

/// Project CapTP MCP must launch the repo-root `./glowcap` shim (forwards to
/// zig-out/bin/glowcap, PATH is not required).
fn expectGlowcapMcpServer(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    host: GlowcapMcpHost,
) !void {
    var parsed = try parseJsonFile(io, gpa, root, violations, path) orelse return;
    defer parsed.deinit();

    const servers = getField(parsed.value, "mcpServers") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers` object", .{path});
        return;
    };
    const glowcap = getField(servers, "glowcap") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.glowcap` object — CapTP MCP must be wired", .{path});
        return;
    };
    const command = getField(glowcap, "command") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.glowcap.command`", .{path});
        return;
    };
    const expected_command: []const u8 = switch (host) {
        .cursor => "${workspaceFolder}/glowcap",
        .claude => "./glowcap",
    };
    if (!jsonStringEquals(command, expected_command)) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.glowcap.command` must be `{s}`", .{ path, expected_command });
    }
    const args = getField(glowcap, "args") orelse {
        try appendViolation(gpa, violations, "{s}: missing `mcpServers.glowcap.args`", .{path});
        return;
    };
    if (!jsonStringArrayEquals(args, &.{ "mcp", "--tools", "default" })) {
        try appendViolation(gpa, violations, "{s}: `mcpServers.glowcap.args` must be `[\"mcp\", \"--tools\", \"default\"]`", .{path});
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
