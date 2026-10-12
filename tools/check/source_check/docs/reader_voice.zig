//! Reader prose: no semicolon, no em dash, and none of the words glowcap's
//! own development uses (doc-voice). The docs voice check runs it over the
//! reader pages, and the Rooms text check runs the same scanner over the
//! app's visible strings, so the word list has one owner.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

/// Words glowcap's own development uses that a reader of the product pages
/// has no way to know. Each one has an everyday name: the sidebar, a Rust
/// library, storage, the steps toward 1.0, reference fixtures, a check.
const insider_words = [_][]const u8{
    "rail",  "rails", "sidecar", "sidecars",     "custody",    "ladder",
    "rung",  "rungs", "oracle",  "dogfood",      "dogfooding", "gate",
    "gates", "seam",  "seams",   "living-state",
};

/// Pages about developing glowcap itself, where its working words belong.
pub fn speaksToContributors(path: []const u8) bool {
    return std.mem.eql(u8, path, "CONTRIBUTING.md") or std.mem.eql(u8, path, "ui/README.md");
}

/// Reader prose carries no semicolon, no em dash, and no insider word
/// (doc-voice). The marks read as generated text on a page a person meant to
/// write, and each one splits into two sentences or takes a comma, colon, or
/// parentheses. An insider word is ours, not the reader's. Code is exempt:
/// fenced and `>`-quoted blocks, indented blocks, inline code spans, link
/// targets, HTML entities, and lines that open `<code>` or `<pre>`. Front
/// matter is exempt except the title and description a reader sees.
pub fn banReaderFlaws(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
    insiders: bool,
) !void {
    const smd = std.mem.endsWith(u8, path, ".smd");
    var front_matter_marks: usize = if (smd) 0 else 2;
    var in_fence = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (front_matter_marks < 2) {
            if (std.mem.eql(u8, trimmed, "---")) {
                front_matter_marks += 1;
                continue;
            }
            const shown = std.mem.startsWith(u8, trimmed, ".title") or
                std.mem.startsWith(u8, trimmed, ".description");
            if (!shown) continue;
        } else {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                in_fence = !in_fence;
                continue;
            }
            if (in_fence or std.mem.startsWith(u8, trimmed, ">") or std.mem.startsWith(u8, line, "    ")) continue;
            if (std.mem.indexOf(u8, line, "<code") != null or std.mem.indexOf(u8, line, "<pre") != null) continue;
        }
        switch (proseFlaw(line, insiders)) {
            .none => {},
            .mark => |mark| {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}:{d}: {s} in prose (doc-voice); split the sentence or use a comma, colon, or parentheses",
                    .{ path, line_no, mark },
                );
                return;
            },
            .insider => |word| {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}:{d}: `{s}` is glowcap's own word, not the reader's (doc-voice); use what a reader would call it",
                    .{ path, line_no, word },
                );
                return;
            },
        }
    }
}

pub const ProseFlaw = union(enum) {
    none,
    /// The punctuation, named for the message.
    mark: []const u8,
    /// The insider word as written.
    insider: []const u8,
};

/// The first semicolon, em dash, or (when `insiders` is set) insider word
/// outside code spans, link targets, and HTML entities.
pub fn proseFlaw(line: []const u8, insiders: bool) ProseFlaw {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 1, '`') orelse return .none;
            i = close + 1;
        } else if (c == ']' and i + 1 < line.len and line[i + 1] == '(') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 2, ')') orelse return .none;
            i = close + 1;
        } else if (c == '&') {
            var j = i + 1;
            while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '#')) j += 1;
            i = if (j < line.len and line[j] == ';' and j > i + 1) j + 1 else i + 1;
        } else if (c == ';') {
            return .{ .mark = "a semicolon" };
        } else if (std.mem.startsWith(u8, line[i..], "\u{2014}")) {
            return .{ .mark = "an em dash" };
        } else if (std.ascii.isAlphabetic(c)) {
            var end = i;
            while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '-')) end += 1;
            const word = line[i..end];
            if (insiders) for (insider_words) |insider| {
                if (std.ascii.eqlIgnoreCase(word, insider)) return .{ .insider = word };
            };
            i = end;
        } else {
            i += 1;
        }
    }
    return .none;
}
