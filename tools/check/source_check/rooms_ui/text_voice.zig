//! Rooms' visible text reads like the rest of the reader pages: no semicolon,
//! no em dash, and none of glowcap's own working words. Screen readers speak
//! these strings aloud, so a label is held as closely as a sentence.
//!
//! The text catalog check keeps every reader-facing string in
//! `apps/rooms/lib/text/`. This one reads that catalog's string literals and
//! the text parts of its template literals, skipping comments and `${}`
//! holes, and hands each one with a space in it to the reader-prose scanner
//! that the docs voice check uses.

const std = @import("std");
const util = @import("../util.zig");
const reader_voice = @import("../docs/reader_voice.zig");

const appendViolation = util.appendViolation;

const text_dir = "apps/rooms/lib/text";

/// The text part of a string or template literal, and the line it starts on.
const Segment = struct { text: []const u8, line: usize };

/// Walks TypeScript source and yields literal text, never code or comments.
const Literals = struct {
    body: []const u8,
    i: usize = 0,
    line: usize = 1,
    /// Inside a template literal, between its backtick and its close.
    in_template: bool = false,

    fn step(self: *Literals) void {
        if (self.body[self.i] == '\n') self.line += 1;
        self.i += 1;
    }

    fn next(self: *Literals) ?Segment {
        while (self.i < self.body.len) {
            if (self.in_template) return self.templateText();
            const rest = self.body[self.i..];
            if (std.mem.startsWith(u8, rest, "//")) {
                while (self.i < self.body.len and self.body[self.i] != '\n') self.i += 1;
            } else if (std.mem.startsWith(u8, rest, "/*")) {
                self.i += 2;
                while (self.i < self.body.len and !std.mem.startsWith(u8, self.body[self.i..], "*/")) self.step();
                self.i = @min(self.i + 2, self.body.len);
            } else if (rest[0] == '"' or rest[0] == '\'') {
                return self.quoted(rest[0]);
            } else if (rest[0] == '`') {
                self.i += 1;
                self.in_template = true;
            } else {
                self.step();
            }
        }
        return null;
    }

    fn quoted(self: *Literals, quote: u8) Segment {
        self.i += 1;
        const start = self.i;
        const line = self.line;
        while (self.i < self.body.len and self.body[self.i] != quote and self.body[self.i] != '\n') {
            if (self.body[self.i] == '\\') self.i += 1;
            self.i += 1;
        }
        const end = @min(self.i, self.body.len);
        self.i = @min(self.i + 1, self.body.len);
        return .{ .text = self.body[start..end], .line = line };
    }

    /// The text up to the next `${` or closing backtick. A hole is skipped
    /// by brace depth, with any string inside it stepped over whole.
    fn templateText(self: *Literals) Segment {
        const start = self.i;
        const line = self.line;
        while (self.i < self.body.len) {
            const c = self.body[self.i];
            if (c == '\\') {
                self.i += 2;
            } else if (c == '`') {
                const end = self.i;
                self.i += 1;
                self.in_template = false;
                return .{ .text = self.body[start..end], .line = line };
            } else if (std.mem.startsWith(u8, self.body[self.i..], "${")) {
                const end = self.i;
                self.i += 2;
                self.skipHole();
                return .{ .text = self.body[start..end], .line = line };
            } else {
                self.step();
            }
        }
        self.in_template = false;
        return .{ .text = self.body[start..@min(self.i, self.body.len)], .line = line };
    }

    fn skipHole(self: *Literals) void {
        var depth: usize = 1;
        while (self.i < self.body.len and depth > 0) {
            const c = self.body[self.i];
            if (c == '"' or c == '\'') {
                _ = self.quoted(c);
                continue;
            }
            if (c == '`') {
                // A template nested in a hole: step to its close.
                self.i += 1;
                while (self.i < self.body.len and self.body[self.i] != '`') self.step();
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
            }
            self.step();
        }
    }
};

fn inspect(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    body: []const u8,
) !void {
    var literals: Literals = .{ .body = body };
    while (literals.next()) |segment| {
        if (std.mem.indexOfScalar(u8, segment.text, ' ') == null) continue;
        switch (reader_voice.proseFlaw(segment.text, .{ .insiders = true })) {
            .none => {},
            .mark => |mark| try appendViolation(
                gpa,
                violations,
                "{s}:{d}: {s} in Rooms text (doc-voice); split the sentence or use a comma, colon, or parentheses",
                .{ path, segment.line, mark },
            ),
            .insider => |word| try appendViolation(
                gpa,
                violations,
                "{s}:{d}: `{s}` is glowcap's own word, not the reader's (doc-voice); use what a reader would call it",
                .{ path, segment.line, word },
            ),
            .label => |word| try appendViolation(
                gpa,
                violations,
                "{s}:{d}: `{s}` names no language, owner, or environment (project values); say what it is",
                .{ path, segment.line, word },
            ),
        }
    }
}

pub fn checkRoomsTextVoice(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, text_dir, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not be opened", .{text_dir});
        return;
    };
    defer dir.close(io);

    var inspected: usize = 0;
    var entries = dir.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".ts")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ text_dir, entry.name });
        defer gpa.free(path);
        const body = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not be read", .{path});
            continue;
        };
        defer gpa.free(body);
        inspected += 1;
        try inspect(gpa, violations, path, body);
    }
    if (inspected == 0) {
        try appendViolation(gpa, violations, "{s}: no text module was read, so this check proves nothing", .{text_dir});
    }
}

test "literal text is read across holes and lines, and code and comments are not" {
    const source =
        \\// The rail; never read here.
        \\export const a = "Open it from the rail.";
        \\export const b = (n: number) => `Kept ${
        \\    n === 1 ? "one; file" : "files"
        \\} in the sidecar — for now.`;
        \\const c = x; /* a; b */
    ;
    var literals: Literals = .{ .body = source };
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(std.testing.allocator);
    var lines: std.ArrayList(usize) = .empty;
    defer lines.deinit(std.testing.allocator);
    while (literals.next()) |segment| {
        try texts.append(std.testing.allocator, segment.text);
        try lines.append(std.testing.allocator, segment.line);
    }
    // The hole's own strings are code, so they are stepped over, not read.
    try std.testing.expectEqualStrings("Open it from the rail.", texts.items[0]);
    try std.testing.expectEqualStrings("Kept ", texts.items[1]);
    try std.testing.expectEqualStrings(" in the sidecar — for now.", texts.items[2]);
    try std.testing.expectEqual(@as(usize, 3), texts.items.len);
    try std.testing.expectEqual(@as(usize, 5), lines.items[2]);
    try std.testing.expect(reader_voice.proseFlaw(texts.items[0], .{ .insiders = true }) == .insider);
    try std.testing.expect(reader_voice.proseFlaw(texts.items[2], .{ .insiders = true }) == .insider);
}
