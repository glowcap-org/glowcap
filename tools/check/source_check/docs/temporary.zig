//! Temporary docs (`kinds.zig`) are linked one way: a living page owns
//! each one, and no static doc names one. Every roadmap item links a plan: its
//! own under `docs/planning/`, or the plan to plan, which says how to write one.

const std = @import("std");
const util = @import("../util.zig");
const kinds = @import("kinds.zig");
const corpus = @import("corpus.zig");
const paths = @import("paths.zig");

const appendViolation = util.appendViolation;

const roadmap_path = "docs/roadmap.md";
const plan_link = "](planning/";

/// An item is a bullet or numbered entry that opens with bold text, or a data
/// row of a roadmap table.
pub fn checkRoadmapItems(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const roadmap = root.readFileAlloc(io, roadmap_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read it to check its plan links ({s})", .{ roadmap_path, @errorName(err) });
        return;
    };
    defer gpa.free(roadmap);
    var items = Items{ .lines = std.mem.splitScalar(u8, roadmap, '\n') };
    while (items.next()) |item| {
        if (std.mem.indexOf(u8, item.text, plan_link) != null) continue;
        try appendViolation(gpa, violations, "{s}:{d}: roadmap item links no plan; link its plan under docs/planning/ or planning/plan-to-plan.md", .{ roadmap_path, item.line });
    }
}

/// Static docs never link a temporary doc, so deleting it edits nothing else.
/// A doc in a temporary home is found by name even unlinked; one declared
/// elsewhere is found by its links.
pub fn checkLinkDirection(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const docs = try corpus.load(io, arena, root, violations, gpa);
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    for (docs) |entry| {
        if (entry.doc.kind == .temporary and kinds.placeOf(entry.path) != .decides) try declared.put(arena, entry.path, {});
    }
    for (docs) |entry| {
        if (entry.doc.kind != .static) continue;
        for (kinds.temporary_homes) |home| {
            var refs = TempRefs{ .text = entry.text, .home = home, .bare = std.mem.startsWith(u8, entry.path, home.dir) };
            while (refs.next()) |name| {
                try appendViolation(gpa, violations, "{s}: names the temporary doc `{s}{s}`; it is deleted when its job is done, so link the living page that owns it or state the fact", .{ entry.path, home.dir, name });
            }
        }
        if (declared.count() == 0) continue;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, entry.text, at, "](")) |open| {
            const start = open + 2;
            const close = std.mem.indexOfScalarPos(u8, entry.text, start, ')') orelse break;
            at = close;
            const target = try paths.resolveMarkdownTarget(arena, entry.path, entry.text[start..close]) orelse continue;
            if (declared.contains(target)) {
                try appendViolation(gpa, violations, "{s}: links the temporary doc `{s}`; it is deleted when its job is done, so link the living page that owns it or state the fact", .{ entry.path, target });
            }
        }
    }
}

/// Each temporary doc is linked from a living page, which owns it and
/// deletes the link when the doc goes.
pub fn checkOwners(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const docs = try corpus.load(io, arena_state.allocator(), root, violations, gpa);
    for (docs) |entry| {
        if (entry.doc.kind != .temporary) continue;
        const target = parentAndName(entry.path);
        const owned = for (docs) |owner| {
            if (owner.doc.kind == .living and std.mem.indexOf(u8, owner.text, target) != null) break true;
        } else false;
        if (!owned) try appendViolation(gpa, violations, "{s}: temporary doc with no owner; link it from the living page that will delete it", .{entry.path});
    }
}

/// The last directory and file name of a path, as a link to it ends:
/// `planning/rooms.md`.
fn parentAndName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    const parent = std.mem.lastIndexOfScalar(u8, path[0..slash], '/') orelse return path;
    return path[parent + 1 ..];
}

/// The last directory of a home, with its slash: `planning/`.
fn homeName(home: kinds.Home) []const u8 {
    const trimmed = home.dir[0 .. home.dir.len - 1];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return home.dir;
    return home.dir[slash + 1 ..];
}

/// Names of temporary docs a text refers to, as `<home>/<name>.md`, or as a
/// bare `](<name>.md` link when the text itself lives in the home.
const TempRefs = struct {
    text: []const u8,
    home: kinds.Home,
    bare: bool,
    at: usize = 0,

    fn next(self: *TempRefs) ?[]const u8 {
        while (self.at < self.text.len) {
            const dir = homeName(self.home);
            const via_dir = std.mem.indexOfPos(u8, self.text, self.at, dir);
            const via_bare = if (self.bare) std.mem.indexOfPos(u8, self.text, self.at, "](") else null;
            const hit, const skip = pick: {
                if (via_dir) |d| if (via_bare == null or d <= via_bare.?) break :pick .{ d, dir.len };
                if (via_bare) |b| break :pick .{ b, "](".len };
                return null;
            };
            const start = hit + skip;
            var end = start;
            while (end < self.text.len and (std.ascii.isAlphanumeric(self.text[end]) or self.text[end] == '-' or self.text[end] == '_')) end += 1;
            self.at = end;
            if (end == start or !std.mem.startsWith(u8, self.text[end..], ".md")) continue;
            const name = self.text[start .. end + ".md".len];
            if (isKept(self.home, name)) continue;
            return name;
        }
        return null;
    }
};

fn isKept(home: kinds.Home, name: []const u8) bool {
    for (home.keep) |keep| if (std.mem.eql(u8, name, keep)) return true;
    return false;
}

test "temporary references skip kept pages and other links" {
    const text = "See [x](../planning/rooms.md#a), [y](planning/plan-to-plan.md), [z](other.md) and `docs/planning/README.md`.";
    var dir_refs = TempRefs{ .text = text, .home = kinds.temporary_homes[0], .bare = false };
    try std.testing.expectEqualStrings("rooms.md", dir_refs.next().?);
    try std.testing.expect(dir_refs.next() == null);
    var bare_refs = TempRefs{ .text = text, .home = kinds.temporary_homes[0], .bare = true };
    try std.testing.expectEqualStrings("rooms.md", bare_refs.next().?);
    try std.testing.expectEqualStrings("other.md", bare_refs.next().?);
    try std.testing.expect(bare_refs.next() == null);
}

const Item = struct { line: usize, text: []const u8 };

/// Roadmap items in order. A bullet or numbered item runs through its indented
/// continuation lines. A table row is one line, and the header row (the one
/// above the `| ---` separator) is not an item.
const Items = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line: usize = 0,
    pending: ?[]const u8 = null,

    fn take(self: *Items) ?[]const u8 {
        if (self.pending) |held| {
            self.pending = null;
            self.line += 1;
            return held;
        }
        const line = self.lines.next() orelse return null;
        self.line += 1;
        return line;
    }

    fn next(self: *Items) ?Item {
        while (self.take()) |text| {
            const start = self.line;
            if (std.mem.startsWith(u8, text, "| ")) {
                if (std.mem.startsWith(u8, text, "| ---")) continue;
                const after = self.take();
                if (after) |line| {
                    if (std.mem.startsWith(u8, line, "| ---")) continue;
                    self.pending = line;
                    self.line -= 1;
                }
                return .{ .line = start, .text = text };
            }
            if (!opensItem(text)) continue;
            const begin = @intFromPtr(text.ptr) - @intFromPtr(self.lines.buffer.ptr);
            var end = begin + text.len;
            while (self.take()) |line| {
                if (line.len == 0 or line[0] != ' ') {
                    self.pending = line;
                    self.line -= 1;
                    break;
                }
                end = @intFromPtr(line.ptr) - @intFromPtr(self.lines.buffer.ptr) + line.len;
            }
            return .{ .line = start, .text = self.lines.buffer[begin..end] };
        }
        return null;
    }
};

fn opensItem(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "- **")) return true;
    var digits: usize = 0;
    while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
    return digits > 0 and std.mem.startsWith(u8, line[digits..], ". **");
}

test "items span their continuation lines and skip table headers" {
    const text =
        \\# Remaining work
        \\
        \\- **Planned.** First line
        \\  and [plan](planning/a.md).
        \\- **Unplanned.** Nothing here.
        \\1. **Numbered.** See the
        \\   [plan to plan](planning/plan-to-plan.md).
        \\
        \\| Area | Obligation |
        \\| --- | --- |
        \\| Loam | Linked ([plan](planning/b.md)). |
        \\| Site | Not linked. |
    ;
    var items = Items{ .lines = std.mem.splitScalar(u8, text, '\n') };
    const expected = [_]struct { line: usize, linked: bool }{
        .{ .line = 3, .linked = true },
        .{ .line = 5, .linked = false },
        .{ .line = 6, .linked = true },
        .{ .line = 11, .linked = true },
        .{ .line = 12, .linked = false },
    };
    for (expected) |want| {
        const item = items.next().?;
        try std.testing.expectEqual(want.line, item.line);
        try std.testing.expectEqual(want.linked, std.mem.indexOf(u8, item.text, plan_link) != null);
    }
    try std.testing.expect(items.next() == null);
}
