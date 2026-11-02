//! The agent skill over the product CLI teaches only the verbs the CLI
//! registry declares.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// CapTP leaf names from `cli/registry.zig`'s `commands` table.
/// Command rows put `.name` / `.help` on consecutive lines, positional structs
/// keep both on one line, that difference is how we avoid collecting `locator`.
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

/// The glowcap-cli skill defers the CapTP catalog to `glowcap help`. Gate the
/// authority pointer and refuse a partial verb-inventory table (second catalog).
pub fn checkGlowcapCliSkillAuthority(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const skill_path = ".agents/skills/glowcap-cli/SKILL.md";
    const skill = root.readFileAlloc(io, skill_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ skill_path, @errorName(err) });
        return;
    };
    defer gpa.free(skill);

    const has_help = std.mem.indexOf(u8, skill, "glowcap help") != null or
        std.mem.indexOf(u8, skill, "help ocapn") != null;
    if (!has_help) {
        try appendViolation(gpa, violations, "{s}: CapTP catalog authority must point at `glowcap help` / `help ocapn` (not a second verb table)", .{skill_path});
    }

    const registry_src = root.readFileAlloc(io, "cli/registry.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "cli/registry.zig: failed to read for glowcap-cli skill check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(registry_src);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try collectCaptpRegistryNames(gpa, registry_src, &names);
    if (names.items.len < 5) {
        try appendViolation(gpa, violations, "cli/registry.zig: expected CapTP leaf `.name = \"…\"` rows for glowcap-cli skill check", .{});
        return;
    }
    if (captpVerbTableIsPartial(skill, names.items)) {
        try appendViolation(gpa, violations, "{s}: CapTP verb table is incomplete — enumerate every registry leaf or defer to `glowcap help` (no second catalog)", .{skill_path});
    }
}
