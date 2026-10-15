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
    "gates", "seam",  "seams",   "living-state", "journal",    "journals",
};

/// Labels that say nothing about the software they name (project values).
/// Each use names the language, owner, mechanism, or environment instead:
/// Zig, the C library, the driver loop, a browser.
pub const vague_labels = [_][]const u8{"native"};

/// Which word lists a scan applies on top of the punctuation rule.
pub const Words = struct {
    /// Glowcap's working words, refused on pages written for people using it.
    insiders: bool,
    /// Vague labels, refused everywhere except decision records, which keep
    /// the words of their time.
    labels: bool = true,
};

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
    words: Words,
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
        switch (proseFlaw(line, words)) {
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
            .label => |word| {
                try appendViolation(gpa, violations, "{s}:{d}: `{s}` names no language, owner, or environment (project values); say Zig, the C library, the driver loop, or what it is", .{ path, line_no, word });
                return;
            },
        }
    }
}

/// The visible text of a site layout holds to the same rule. Tags, comments,
/// and `<style>`/`<script>` bodies are code, so only text between tags is
/// scanned, one line at a time.
pub fn banLayoutFlaws(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var i: usize = 0;
    while (i < contents.len) {
        const skip: ?[]const u8 = if (std.mem.startsWith(u8, contents[i..], "<!--"))
            "-->"
        else if (std.mem.startsWith(u8, contents[i..], "<style"))
            "</style>"
        else if (std.mem.startsWith(u8, contents[i..], "<script"))
            "</script>"
        else if (contents[i] == '<')
            ">"
        else
            null;
        if (skip) |close| {
            const end = std.mem.indexOfPos(u8, contents, i, close) orelse contents.len;
            // Keep line numbers: a skipped span still ends its lines.
            for (contents[i..end]) |c| if (c == '\n') try text.append(gpa, '\n');
            try text.append(gpa, ' ');
            i = @min(contents.len, end + close.len);
        } else {
            try text.append(gpa, contents[i]);
            i += 1;
        }
    }
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        switch (proseFlaw(line, .{ .insiders = true })) {
            .none => {},
            .mark => |mark| return appendViolation(gpa, violations, "{s}:{d}: {s} in page text (doc-voice); split the sentence or use a comma, colon, or parentheses", .{ path, line_no, mark }),
            .insider => |word| return appendViolation(gpa, violations, "{s}:{d}: `{s}` is glowcap's own word, not the reader's (doc-voice); use what a reader would call it", .{ path, line_no, word }),
            .label => |word| return appendViolation(gpa, violations, "{s}:{d}: `{s}` names no language, owner, or environment (project values); say Zig, the C library, the driver loop, or what it is", .{ path, line_no, word }),
        }
    }
}

test "layout text is scanned and its markup is not" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try banLayoutFlaws(gpa, &violations, "a.shtml", "<style>a { b: c; }</style>\n<!-- the rail; -->\n<p class=\"x;y\">Clean text.</p>\n");
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try banLayoutFlaws(gpa, &violations, "a.shtml", "<p>ok</p>\n<small>the bounded journal</small>\n");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "a.shtml:2:") != null);
}

/// The CLI's messages and help are read by a person, so a one-line string
/// literal in `cli/` holds to the punctuation rule. Shell and fish syntax a
/// completion script prints sits in `\\` lines or opens its literal with the
/// semicolon, so only a semicolon after a word and before a space counts, and a
/// `\\` line is held only to the em dash.
pub fn banCliStringFlaws(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "//")) continue;
        if (std.mem.startsWith(u8, t, "\\\\")) {
            if (std.mem.indexOf(u8, t, "\u{2014}") != null)
                try appendViolation(gpa, violations, "{s}:{d}: an em dash in CLI output (doc-voice); use a comma, colon, or parentheses", .{ path, line_no });
            continue;
        }
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, i, '"')) |open| {
            var end = open + 1;
            while (end < line.len and line[end] != '"') end += if (line[end] == '\\') 2 else 1;
            if (end >= line.len) break;
            if (cliStringFlaw(line[open + 1 .. end])) |mark| {
                try appendViolation(gpa, violations, "{s}:{d}: {s} in a CLI string (doc-voice); split the sentence or use a comma, colon, or parentheses", .{ path, line_no, mark });
                break;
            }
            i = end + 1;
        }
    }
}

fn cliStringFlaw(literal: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, literal, "\u{2014}") != null) return "an em dash";
    var i: usize = 1;
    while (i + 1 < literal.len) : (i += 1) {
        const before = literal[i - 1];
        if (literal[i] == ';' and literal[i + 1] == ' ' and (std.ascii.isAlphanumeric(before) or before == ')' or before == '}')) return "a semicolon";
    }
    return null;
}

test "a CLI string holds to the punctuation rule and shell syntax does not" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try banCliStringFlaws(gpa, &violations, "a.zig", "try w(\"; and not x\");\n    \\\\  if a; then b; fi\n// note; aside\nlog(\"say \\\"x\\\" (ok)\");\n");
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try banCliStringFlaws(gpa, &violations, "a.zig", "ok();\nlog(\"listening; Ctrl-C to stop\");\n");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "a.zig:2:") != null);
    try banCliStringFlaws(gpa, &violations, "a.zig", "    \\\\# x completion \u{2014} eval\n");
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
}

pub const ProseFlaw = union(enum) {
    none,
    /// The punctuation, named for the message.
    mark: []const u8,
    /// The insider word as written.
    insider: []const u8,
    /// The vague label as written.
    label: []const u8,
};

/// The first semicolon, em dash, or word from a list `words` selects, outside
/// code spans, link targets, HTML comments, and HTML entities.
pub fn proseFlaw(line: []const u8, words: Words) ProseFlaw {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            const close = std.mem.indexOfScalarPos(u8, line, i + 1, '`') orelse return .none;
            i = close + 1;
        } else if (std.mem.startsWith(u8, line[i..], "<!--")) {
            const close = std.mem.indexOfPos(u8, line, i + 4, "-->") orelse return .none;
            i = close + 3;
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
            if (words.insiders) for (insider_words) |insider| {
                if (std.ascii.eqlIgnoreCase(word, insider)) return .{ .insider = word };
            };
            if (words.labels) for (vague_labels) |label| {
                if (std.ascii.eqlIgnoreCase(word, label)) return .{ .label = word };
            };
            i = end;
        } else {
            i += 1;
        }
    }
    return .none;
}

test "a vague label is refused in prose and allowed in code and decision records" {
    try std.testing.expect(proseFlaw("Every native binding dials it.", .{ .insiders = false }) == .label);
    try std.testing.expect(proseFlaw("Run `goblins-glowcap-pair-gift` first.", .{ .insiders = false }) == .none);
    try std.testing.expect(proseFlaw("Every native binding dials it.", .{ .insiders = false, .labels = false }) == .none);
    try std.testing.expect(proseFlaw("A browser-native socket.", .{ .insiders = false }) == .none);
    try std.testing.expect(proseFlaw("at most <!-- value ffi_frame.ts max -->16<!-- /value --> writes", .{ .insiders = false }) == .none);
}
