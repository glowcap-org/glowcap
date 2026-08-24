//! Prompt command history for the CapTP lab (readline-shaped Up/Down).
const std = @import("std");

pub const History = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    /// null = editing the live draft; else index into entries (0 = oldest).
    cursor: ?usize = null,
    draft: std.ArrayList(u8) = .empty,
    const cap: usize = 200;

    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.gpa.free(e);
        self.entries.deinit(self.gpa);
        self.draft.deinit(self.gpa);
    }

    /// Record a submitted line (skip blanks and consecutive duplicates).
    pub fn push(self: *History, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, trimmed)) {
                self.cursor = null;
                self.draft.clearRetainingCapacity();
                return;
            }
        }
        const owned = try self.gpa.dupe(u8, trimmed);
        errdefer self.gpa.free(owned);
        try self.entries.append(self.gpa, owned);
        while (self.entries.items.len > cap) {
            const old = self.entries.orderedRemove(0);
            self.gpa.free(old);
        }
        self.cursor = null;
        self.draft.clearRetainingCapacity();
    }

    /// Older entry. `current` is the live editor contents when leaving the draft.
    pub fn prev(self: *History, current: []const u8) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        if (self.cursor == null) {
            self.draft.clearRetainingCapacity();
            // best-effort: under allocation failure the unsent draft is not
            // preserved across the history walk.
            self.draft.appendSlice(self.gpa, current) catch {};
            self.cursor = self.entries.items.len - 1;
            return self.entries.items[self.cursor.?];
        }
        if (self.cursor.? == 0) return self.entries.items[0];
        self.cursor.? -= 1;
        return self.entries.items[self.cursor.?];
    }

    /// Newer entry, or the saved draft when walking off the newest.
    pub fn next(self: *History) ?[]const u8 {
        if (self.cursor == null) return null;
        if (self.cursor.? + 1 >= self.entries.items.len) {
            self.cursor = null;
            return self.draft.items;
        }
        self.cursor.? += 1;
        return self.entries.items[self.cursor.?];
    }

    pub fn resetBrowse(self: *History) void {
        self.cursor = null;
        self.draft.clearRetainingCapacity();
    }
};

test "history prev next draft" {
    var h = History.init(std.testing.allocator);
    defer h.deinit();
    try h.push("one");
    try h.push("two");
    try std.testing.expectEqualStrings("two", h.prev("draft").?);
    try std.testing.expectEqualStrings("one", h.prev("").?);
    try std.testing.expectEqualStrings("one", h.prev("").?); // clamp
    try std.testing.expectEqualStrings("two", h.next().?);
    try std.testing.expectEqualStrings("draft", h.next().?);
    try std.testing.expect(h.next() == null);
}
