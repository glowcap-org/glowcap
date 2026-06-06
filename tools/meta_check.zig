//! Meta gate — checks that agent scaffolding and documented build commands stay
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

const checked_command_docs = [_][]const u8{
    "README.md",
    "CONTRIBUTING.md",
    "AGENTS.md",
    "docs/architecture.md",
    "bindings/README.md",
    ".agents/README.md",
    ".agents/hooks/README.md",
    ".agents/rules/cli.md",
    ".agents/rules/tests.md",
    ".agents/rules/project-values.md",
    ".agents/rules/agent-scaffolding.md",
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

    try expectSymlink(step, io, gpa, root, &violations, "CLAUDE.md", "AGENTS.md");
    try expectSymlink(step, io, gpa, root, &violations, ".claude/rules", "../.agents/rules");
    try expectSymlink(step, io, gpa, root, &violations, ".claude/skills", "../.agents/skills");
    try expectSymlink(step, io, gpa, root, &violations, ".cursor/skills", "../.agents/skills");

    try checkCursorRuleOverlay(step, io, gpa, root, &violations);
    try checkRequiredSubstrings(step, io, gpa, root, &violations);
    try checkDocumentedBuildSteps(step, io, gpa, root, &violations);
    try checkPlanningDocRoles(io, gpa, root, &violations);

    if (violations.items.len != 0) {
        for (violations.items) |msg| std.debug.print("meta-check: {s}\n", .{msg});
        return step.fail("meta-check found {d} scaffolding violation(s)", .{violations.items.len});
    }
}

fn expectSymlink(
    step: *Step,
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

    _ = step;
}

fn checkCursorRuleOverlay(
    step: *Step,
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

        try expectSymlink(step, io, gpa, root, violations, cursor_path, expected_target);
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
    step: *Step,
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    _ = step;

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
        "Read AGENTS.md first.",
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

fn checkPlanningDocRoles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs/planning: failed to open planning docs with {s}", .{@errorName(err)});
        return;
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

fn checkDocumentedBuildSteps(
    step: *Step,
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    _ = step;

    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var steps = std.StringHashMap(void).init(gpa);
    defer steps.deinit();
    try steps.put("build", {});
    try collectBuildSteps(gpa, build_zig, &steps);

    for (checked_command_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for build-command check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var rest = contents;
        while (std.mem.indexOf(u8, rest, "zig build")) |start| {
            const after = rest[start + "zig build".len ..];
            rest = after;

            const trimmed = std.mem.trimStart(u8, after, " \t");
            if (trimmed.len == 0 or isCommandTerminator(trimmed[0])) continue;

            const token_end = firstCommandTokenEnd(trimmed);
            const raw_step = trimmed[0..token_end];
            const documented_step = std.mem.trim(u8, raw_step, "`'\".,);]");
            if (documented_step.len == 0) continue;
            if (std.mem.startsWith(u8, documented_step, "-")) continue;

            if (!steps.contains(documented_step)) {
                try appendViolation(gpa, violations, "{s}: documents `zig build {s}`, but build.zig has no step named `{s}`", .{
                    path,
                    documented_step,
                    documented_step,
                });
            }
        }
    }
}

fn collectBuildSteps(gpa: std.mem.Allocator, build_zig: []const u8, steps: *std.StringHashMap(void)) !void {
    var rest = build_zig;
    while (std.mem.indexOf(u8, rest, "b.step(\"")) |start| {
        const after = rest[start + "b.step(\"".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const name = after[0..end];
        try steps.put(name, {});
        rest = after[end..];
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

fn appendViolation(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try violations.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}
