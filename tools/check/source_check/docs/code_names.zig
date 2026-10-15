//! A static doc that names code by a qualified name (`Host.close`,
//! `Failure::parse`, `session.listen()`) names something the code still
//! declares. A rename leaves the old name in prose that no compiler reads, so
//! this check reads it: when part of a name is still in the code and part is
//! gone, the doc is stale. A name wholly from outside the repository passes.

const std = @import("std");
const util = @import("../util.zig");
const corpus = @import("corpus.zig");

const appendViolation = util.appendViolation;

/// The trees whose source the names point into.
const code_trees = [_][]const u8{ "src", "cli", "apps", "bindings", "tools", "bench", "conformance", "examples", "test", "interop", "include", "site/examples" };

const code_suffixes = [_][]const u8{ ".zig", ".rs", ".ts", ".tsx", ".js", ".py", ".rkt", ".scm", ".c", ".h", ".sh", ".json", ".toml", ".zon", ".css" };

/// A last segment that makes the span a file name, not a code name.
const file_extensions = [_][]const u8{ "zig", "zon", "rs", "ts", "tsx", "js", "py", "rkt", "c", "h", "sh", "md", "smd", "json", "jsonl", "toml", "lock", "css", "html", "svg", "txt", "yml", "yaml", "wasm", "so", "a", "dylib", "pem", "key", "mdc" };

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var words: std.StringHashMapUnmanaged(void) = .empty;
    for (code_trees) |tree| {
        const files = try util.collectSourceFiles(io, arena, root, tree, isCode) orelse continue;
        for (files) |path| {
            // tolerant: an unreadable source adds no words, and the doc that
            // names it fails, which points at the file.
            const text = root.readFileAlloc(io, path, arena, .limited(16 << 20)) catch continue;
            try addWords(arena, &words, text);
            // A module is named by its file: `tests.op_gc` is `tests/op_gc.py`.
            try addWords(arena, &words, std.fs.path.stem(path));
        }
    }
    if (root.readFileAlloc(io, "build.zig", arena, .limited(1 << 20))) |text| {
        try addWords(arena, &words, text);
    } else |_| {} // tolerant: a tree with no build script still holds its other words.

    for (try corpus.load(io, arena, root, violations, gpa)) |entry| {
        if (entry.doc.kind != .static) continue;
        var fenced = false;
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, entry.text, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) fenced = !fenced;
            if (fenced) continue;
            var spans = std.mem.splitScalar(u8, line, '`');
            _ = spans.next();
            while (spans.next()) |span| {
                if (missing(span, &words)) |gone| {
                    try appendViolation(gpa, violations, "{s}:{d}: `{s}` names `{s}`, which no code declares; fix the name or drop the claim", .{ entry.path, line_no, span, gone });
                }
                _ = spans.next();
            }
        }
    }
}

fn isCode(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/upstream/") != null and std.mem.endsWith(u8, path, ".md")) return false;
    for (code_suffixes) |suffix| if (std.mem.endsWith(u8, path, suffix)) return true;
    return false;
}

fn addWords(arena: std.mem.Allocator, words: *std.StringHashMapUnmanaged(void), text: []const u8) !void {
    var at: usize = 0;
    while (at < text.len) {
        if (!isIdentStart(text[at])) {
            at += 1;
            continue;
        }
        const start = at;
        while (at < text.len and isIdent(text[at])) at += 1;
        try words.put(arena, text[start..at], {});
    }
}

/// The first segment of a qualified name that the code lacks, when another
/// segment shows the name points into this repository.
fn missing(span: []const u8, words: *const std.StringHashMapUnmanaged(void)) ?[]const u8 {
    const name = if (std.mem.endsWith(u8, span, "()")) span[0 .. span.len - 2] else span;
    var segments: [16][]const u8 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (true) {
        if (at >= name.len or !isIdentStart(name[at]) or count == segments.len) return null;
        const start = at;
        while (at < name.len and isIdent(name[at])) at += 1;
        segments[count] = name[start..at];
        count += 1;
        if (at == name.len) break;
        if (name[at] == '.') {
            at += 1;
        } else if (std.mem.startsWith(u8, name[at..], "::")) {
            at += 2;
        } else return null;
    }
    if (count < 2) return null;
    for (file_extensions) |ext| if (std.mem.eql(u8, segments[count - 1], ext)) return null;
    var known = false;
    var gone: ?[]const u8 = null;
    for (segments[0..count]) |segment| {
        if (words.contains(segment)) known = true else if (gone == null) gone = segment;
    }
    return if (known) gone else null;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "a qualified name is stale when part of it left the code" {
    var words: std.StringHashMapUnmanaged(void) = .empty;
    defer words.deinit(std.testing.allocator);
    for ([_][]const u8{ "Widget", "renamed_to", "Host", "close" }) |word| try words.put(std.testing.allocator, word, {});
    try std.testing.expectEqualStrings("renamed_from", missing("Widget::renamed_from", &words).?);
    try std.testing.expectEqual(@as(?[]const u8, null), missing("Widget::renamed_to", &words));
    try std.testing.expectEqual(@as(?[]const u8, null), missing("Host.close()", &words));
    try std.testing.expectEqual(@as(?[]const u8, null), missing("dotfiles.repository", &words));
    try std.testing.expectEqual(@as(?[]const u8, null), missing("build.zig", &words));
    try std.testing.expectEqual(@as(?[]const u8, null), missing("zig build check", &words));
}
