//! The agent skills over the product CLI and MCP fronts: the application
//! surface verbs, the CapTP registry names each skill may teach, and the
//! dogfood routing that keeps live CapTP on the product fronts.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// The application-surface verbs the vision promises in every binding and on the
/// native driver. Each surface that introduces the vocabulary must list all of
/// them; a dropped verb is a silently second-class surface.
const application_surface_verbs = [_][]const u8{
    "connect", "listen", "fetch", "publish", "spawn", "send", "tell", "serve", "close",
};

/// The binding overview is the one human-facing enumeration of the shared
/// application vocabulary. Tutorials can teach a smaller path without
/// pretending to be an API checklist.
const application_surface_files = [_][]const u8{
    "bindings/README.md",
};

/// Whether `verb` appears as an inline-code token in `contents`, tolerating the
/// three ways the surfaces write it: bare (`connect`), as a call
/// (`connect(locator)`), or as a method on a receiver (`conn.tell(ref, …)`).
/// A trailing `(…)` and a leading `recv.` are stripped before comparison.
pub fn mentionsVerbInCode(contents: []const u8, verb: []const u8) bool {
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
pub fn checkApplicationSurfaceVerbs(
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
pub fn collectCaptpRegistryNames(
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
pub fn captpVerbTableIsPartial(skill: []const u8, names: []const []const u8) bool {
    var line_start: usize = 0;
    var in_inventory = false;
    var hit: usize = 0;
    var seen: [64]bool = @splat(false);
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
            seen = @splat(false);
        }
        line_start = if (nl < skill.len) nl + 1 else skill.len;
    }
    if (in_inventory and hit >= 3 and hit < names.len) return true;
    return false;
}

/// The pancake-mcp skill defers the tool catalog to MCP `tools/list` / registry.
/// Refuse a partial default-catalog inventory and unimplemented env overrides.
pub fn checkPancakeMcpSkillAuthority(
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
    // Hand-maintained default inventory (second catalog) — body or description.
    if (std.mem.indexOf(u8, skill, "everyday CapTP (dial, probe") != null or
        std.mem.indexOf(u8, skill, "dial, probe, call, tell, fetch, publish, info") != null or
        std.mem.indexOf(u8, skill, "dial/probe/call/tell/fetch/publish/info/close") != null)
    {
        try appendViolation(gpa, violations, "{s}: do not enumerate default MCP tools — discover via `tools/list` / registry", .{skill_path});
    }
}

/// Work / smell-annihilation / skill indexes must not funnel MCP through pancake-cli.
pub fn checkCaptpAgentDogfoodRouting(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const must_name_mcp = [_][]const u8{
        ".agents/skills/work/SKILL.md",
        ".agents/skills/smell-annihilation/SKILL.md",
        ".agents/skills/rooms-peer/SKILL.md",
        ".agents/skills/rooms-team/SKILL.md",
        ".agents/skills/community-review/SKILL.md",
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

    const rooms_team_script = ".agents/skills/rooms-team/scripts/team.sh";
    root.access(io, rooms_team_script, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: rooms-team skill requires companion script ({s})", .{ rooms_team_script, @errorName(err) });
    };
    const rooms_lead_watch = ".agents/skills/rooms-team/scripts/lead-watch.sh";
    root.access(io, rooms_lead_watch, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: rooms-team skill requires lead wake pager ({s})", .{ rooms_lead_watch, @errorName(err) });
    };
    const rooms_team_skill = root.readFileAlloc(io, ".agents/skills/rooms-team/SKILL.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: failed to read for companion refs with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(rooms_team_skill);
    if (std.mem.indexOf(u8, rooms_team_skill, "ops.md") == null or
        std.mem.indexOf(u8, rooms_team_skill, "gotchas.md") == null or
        std.mem.indexOf(u8, rooms_team_skill, "strategies.md") == null)
    {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must link ops.md, gotchas.md, and strategies.md", .{});
    }
    // Multi-surface / per-peer pending floors — prose that must not vanish when
    // the skill is edited; the hermetic one-wake golden holds the CLI half.
    if (std.mem.indexOf(u8, rooms_team_skill, "Multi-surface wake") == null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must keep Multi-surface wake (DM then room before peers)", .{});
    }
    if (std.mem.indexOf(u8, rooms_team_skill, "Pending is per-peer") == null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must keep Pending is per-peer (member dismisses own copy)", .{});
    }
    if (std.mem.indexOf(u8, rooms_team_skill, "DM-first is order") == null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must keep DM-first is order (not permission to ignore room)", .{});
    }
    // Positive member instruction to park lead-owned room is the wedge mode.
    if (std.mem.indexOf(u8, rooms_team_skill, "leave pending for the lead") != null) {
        try appendViolation(gpa, violations, ".agents/skills/rooms-team/SKILL.md: must not instruct members to leave pending for the lead", .{});
    }
}

/// The pancake-cli skill defers the CapTP catalog to `pancake help`. Gate the
/// authority pointer and refuse a partial verb-inventory table (second catalog).
pub fn checkPancakeCliSkillAuthority(
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
