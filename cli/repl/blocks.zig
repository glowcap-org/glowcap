//! Expandable transcript blocks for the CapTP lab.
const std = @import("std");
const layout = @import("layout.zig");

pub const Kind = enum { user, result, error_line, tip, gloss, coach, system, pending };

pub const Block = struct {
    kind: Kind,
    summary: []u8,
    body: []u8,
    expanded: bool,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Block) void {
        self.gpa.free(self.summary);
        if (self.body.ptr != self.summary.ptr) self.gpa.free(self.body);
    }

    pub fn hasMore(self: *const Block) bool {
        return !std.mem.eql(u8, self.summary, self.body);
    }

    pub fn visibleLines(self: *const Block, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
        const text = if (self.expanded) self.body else self.summary;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try out.append(gpa, line);
        }
        if (!self.expanded and self.hasMore()) {
            // Affordance line is drawn by renderer from hasMore; no extra here.
        }
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Block) = .empty,
    scroll_off: usize = 0,
    /// Lines appended while scrolled away from live (for jump chip).
    new_while_paused: usize = 0,
    const cap: usize = 500;
    const collapse_lines: usize = 6;

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.items.items) |*b| b.deinit();
        self.items.deinit(self.gpa);
    }

    pub fn pinLive(self: *Store) void {
        self.scroll_off = 0;
        self.new_while_paused = 0;
    }

    fn noteAppend(self: *Store) void {
        if (self.scroll_off > 0) self.new_while_paused += 1;
    }

    pub fn appendLine(self: *Store, kind: Kind, line: []const u8) !void {
        const owned = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(owned);
        try self.items.append(self.gpa, .{
            .kind = kind,
            .summary = owned,
            .body = owned,
            .expanded = true,
            .gpa = self.gpa,
        });
        self.noteAppend();
        self.trim();
    }

    /// Rewrite an existing block in place (pending → result/error). No-op if
    /// `idx` is stale after trim; CapTP lab pending rows stay near the live end.
    pub fn setLine(self: *Store, idx: usize, kind: Kind, line: []const u8) !void {
        if (idx >= self.items.items.len) return;
        const owned = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(owned);
        var b = &self.items.items[idx];
        b.deinit();
        b.* = .{
            .kind = kind,
            .summary = owned,
            .body = owned,
            .expanded = true,
            .gpa = self.gpa,
        };
    }

    pub fn appendMultiline(self: *Store, kind: Kind, text: []const u8) !void {
        var line_n: usize = 1;
        for (text) |c| {
            if (c == '\n') line_n += 1;
        }
        const body = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(body);
        const collapse = line_n > collapse_lines or text.len > 400;
        var summary: []u8 = undefined;
        if (collapse) {
            var first_end: usize = text.len;
            if (std.mem.indexOfScalar(u8, text, '\n')) |nl| first_end = nl;
            const prefix = text[0..@min(first_end, 80)];
            summary = try std.fmt.allocPrint(self.gpa, "{s} … ({d} lines, click to expand)", .{ prefix, line_n });
        } else {
            summary = body;
        }
        try self.items.append(self.gpa, .{
            .kind = kind,
            .summary = summary,
            .body = body,
            .expanded = !collapse,
            .gpa = self.gpa,
        });
        self.noteAppend();
        self.trim();
    }

    pub fn toggle(self: *Store, index: usize) void {
        if (index >= self.items.items.len) return;
        const b = &self.items.items[index];
        if (!b.hasMore()) return;
        b.expanded = !b.expanded;
    }

    pub fn scroll(self: *Store, view_h: usize, delta: i32) void {
        const lines = self.flatLineCount();
        self.scroll_off = layout.scrollBy(self.scroll_off, lines, view_h, delta);
    }

    pub fn clampView(self: *Store, view_h: usize) void {
        self.scroll_off = layout.clampScroll(self.scroll_off, self.flatLineCount(), view_h);
    }

    pub fn flatLineCount(self: *const Store) usize {
        var n: usize = 0;
        for (self.items.items) |b| {
            const text = if (b.expanded) b.body else b.summary;
            n += 1;
            for (text) |c| {
                if (c == '\n') n += 1;
            }
        }
        return n;
    }

    /// Map a visible transcript row (0 = top of viewport) to a block index, or null.
    pub fn blockAtViewRow(self: *const Store, view_h: usize, row_in_view: usize) ?usize {
        const lines = self.flatLineCount();
        const start = layout.transcriptStart(self.scroll_off, lines, view_h);
        var flat: usize = 0;
        for (self.items.items, 0..) |b, bi| {
            const text = if (b.expanded) b.body else b.summary;
            var line_n: usize = 1;
            for (text) |c| {
                if (c == '\n') line_n += 1;
            }
            const block_start = flat;
            const block_end = flat + line_n;
            flat = block_end;
            if (start >= block_end) continue;
            const view_flat = start + row_in_view;
            if (view_flat >= block_start and view_flat < block_end) return bi;
            if (block_start > start + view_h) break;
        }
        return null;
    }

    pub fn jumpUserTurn(self: *Store, view_h: usize, dir: i32) void {
        if (self.items.items.len == 0) return;
        const lines = self.flatLineCount();
        const start = layout.transcriptStart(self.scroll_off, lines, view_h);
        var flat: usize = 0;
        var targets: std.ArrayList(usize) = .empty;
        defer targets.deinit(self.gpa);
        for (self.items.items) |b| {
            const text = if (b.expanded) b.body else b.summary;
            var line_n: usize = 1;
            for (text) |c| {
                if (c == '\n') line_n += 1;
            }
            if (b.kind == .user) targets.append(self.gpa, flat) catch {};
            flat += line_n;
        }
        if (targets.items.len == 0) return;
        const setStart = struct {
            fn go(store: *Store, line_count: usize, vh: usize, t: usize) void {
                store.scroll_off = if (line_count > vh + t) line_count - vh - t else 0;
            }
        }.go;
        if (dir < 0) {
            var i: isize = @intCast(targets.items.len);
            while (i > 0) {
                i -= 1;
                const t = targets.items[@intCast(i)];
                if (t < start) {
                    setStart(self, lines, view_h, t);
                    return;
                }
            }
            self.scroll_off = if (lines > view_h) lines - view_h else 0;
        } else {
            for (targets.items) |t| {
                if (t > start) {
                    setStart(self, lines, view_h, t);
                    return;
                }
            }
            self.pinLive();
        }
    }

    fn trim(self: *Store) void {
        while (self.items.items.len > cap) {
            var old = self.items.orderedRemove(0);
            old.deinit();
        }
    }
};

pub fn kindFromLabLine(line: []const u8) Kind {
    if (std.mem.startsWith(u8, line, "› ")) return .user;
    if (std.mem.startsWith(u8, line, "! ")) return .error_line;
    if (std.mem.startsWith(u8, line, "tip: ")) return .tip;
    if (std.mem.startsWith(u8, line, "↳ ")) return .gloss;
    return .result;
}

test "collapse long body" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try big.appendSlice(std.testing.allocator, "line\n");
    }
    try s.appendMultiline(.result, big.items);
    try std.testing.expect(s.items.items.len == 1);
    try std.testing.expect(!s.items.items[0].expanded);
    try std.testing.expect(s.items.items[0].hasMore());
    s.toggle(0);
    try std.testing.expect(s.items.items[0].expanded);
}
