//! Identifier ban for the word `native` in first-party code (project values:
//! name the language, owner, mechanism, or environment).
//!
//! `native` names no one thing: it has meant the C library side of a binding,
//! glowcap's own codec, the Zig side, and the Rust process of Rooms, depending
//! on the file. A new identifier under `src/`, `bindings/` and `apps/` takes
//! the name of the thing it points at instead (`ffi`, `zig`, `host`, `own`,
//! `glowcap`, `os`). Comments, strings, and docs are not identifiers, and
//! `reader_voice.vague_labels` already holds them. The word list has that one
//! owner.

const std = @import("std");
const util = @import("../util.zig");
const reader_voice = @import("../docs/reader_voice.zig");

const appendViolation = util.appendViolation;

const trees = [_][]const u8{ "src", "bindings", "apps" };

/// Identifiers that carry the word because something outside the project
/// names them: Zig's byte-order helpers, the `rustls-native-certs` crate and
/// its feature, Deno's `NativeType`, and the DOM's `nativeEvent`.
const allowed = [_][]const u8{
    "nativeTo",
    "toNative",
    "nativeToBig",
    "nativeToLittle",
    "bigToNative",
    "littleToNative",
    "native_endian",
    "NativeEndian",
    "rustls_native_certs",
    "load_native_certs",
    "NativeType",
    "nativeEvent",
};

const Language = enum { slashes, hash, semicolon };

fn language(path: []const u8) ?Language {
    const suffixes = [_]struct { []const u8, Language }{
        .{ ".zig", .slashes },
        .{ ".rs", .slashes },
        .{ ".ts", .slashes },
        .{ ".tsx", .slashes },
        .{ ".mjs", .slashes },
        .{ ".c", .slashes },
        .{ ".h", .slashes },
        .{ ".py", .hash },
        .{ ".rkt", .semicolon },
    };
    for (suffixes) |entry| {
        if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
    }
    return null;
}

fn isCode(path: []const u8) bool {
    return language(path) != null;
}

fn identifierByte(c: u8, language_kind: Language) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or (language_kind == .semicolon and c == '-');
}

/// True when `token` carries `word` as a whole word: the word sits at the
/// token start or after a separator or a lower-to-upper camel boundary, and
/// ends at the token end, a separator, or the next capital. `natively` and
/// `alternative` carry the letters without the word.
fn carriesWord(token: []const u8, word: []const u8) bool {
    if (token.len < word.len) return false;
    for (0..token.len - word.len + 1) |at| {
        if (!std.ascii.eqlIgnoreCase(token[at .. at + word.len], word)) continue;
        const end = at + word.len;
        const starts = at == 0 or !std.ascii.isAlphabetic(token[at - 1]) or
            (std.ascii.isUpper(token[at]) and std.ascii.isLower(token[at - 1]));
        const shouting = std.ascii.isUpper(token[at]) and at + 1 < token.len and std.ascii.isUpper(token[at + 1]);
        const ends = end == token.len or !std.ascii.isAlphabetic(token[end]) or
            (std.ascii.isUpper(token[end]) and !shouting);
        if (starts and ends) return true;
    }
    return false;
}

fn allowedToken(token: []const u8) bool {
    for (allowed) |name| {
        if (std.mem.eql(u8, token, name)) return true;
    }
    return false;
}

/// The first identifier in `code` that carries a vague label and is not on
/// the allowed list. `code` holds no comment and no literal contents.
fn firstVagueIdentifier(code: []const u8, language_kind: Language) ?[]const u8 {
    var i: usize = 0;
    while (i < code.len) {
        if (!identifierByte(code[i], language_kind)) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < code.len and identifierByte(code[i], language_kind)) i += 1;
        const token = code[start..i];
        for (reader_voice.vague_labels) |label| {
            if (carriesWord(token, label) and !allowedToken(token)) return token;
        }
    }
    return null;
}

/// Per-file scanner state for constructs that span lines.
const Scan = struct {
    in_block_comment: bool = false,
    in_docstring: bool = false,
    /// Rust spells a lifetime `'a`, which has no closing quote.
    rust: bool = false,
};

/// `line` reduced to code: comments removed and the contents of string,
/// character, and template literals blanked. Returns null for a line that is
/// wholly comment, docstring, or multi-line string text.
fn codeOf(line: []const u8, language_kind: Language, scan: *Scan, buf: []u8) ?[]const u8 {
    if (line.len > buf.len) return null;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (language_kind == .slashes and std.mem.startsWith(u8, trimmed, "\\\\")) return null;
    const out = buf[0..line.len];
    @memcpy(out, line);
    var i: usize = 0;
    while (i < out.len) {
        if (scan.in_block_comment) {
            if (std.mem.startsWith(u8, out[i..], "*/")) {
                scan.in_block_comment = false;
                out[i] = ' ';
                out[i + 1] = ' ';
                i += 2;
            } else {
                out[i] = ' ';
                i += 1;
            }
            continue;
        }
        if (scan.in_docstring) {
            if (std.mem.startsWith(u8, out[i..], "\"\"\"")) {
                scan.in_docstring = false;
                @memset(out[i .. i + 3], ' ');
                i += 3;
            } else {
                out[i] = ' ';
                i += 1;
            }
            continue;
        }
        const c = out[i];
        switch (language_kind) {
            .slashes => {
                if (std.mem.startsWith(u8, out[i..], "//")) return out[0..i];
                if (std.mem.startsWith(u8, out[i..], "/*")) {
                    scan.in_block_comment = true;
                    @memset(out[i .. i + 2], ' ');
                    i += 2;
                    continue;
                }
            },
            .hash => {
                if (c == '#') return out[0..i];
                if (std.mem.startsWith(u8, out[i..], "\"\"\"")) {
                    scan.in_docstring = true;
                    @memset(out[i .. i + 3], ' ');
                    i += 3;
                    continue;
                }
            },
            .semicolon => if (c == ';') return out[0..i],
        }
        if (c == '"' or c == '\'' or c == '`') {
            const close = std.mem.indexOfScalarPos(u8, out, i + 1, c);
            if (c == '\'' and scan.rust and (close == null or close.? > i + 4)) {
                i += 1;
                continue;
            }
            const end = close orelse out.len - 1;
            var j = i + 1;
            while (j < end) : (j += 1) {
                if (out[j] == '\\' and j + 1 < out.len) {
                    out[j] = ' ';
                    j += 1;
                }
                out[j] = ' ';
            }
            i = end + 1;
            continue;
        }
        i += 1;
    }
    return out;
}

fn scanSource(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    const language_kind = language(path) orelse return;
    var scan: Scan = .{ .rust = std.mem.endsWith(u8, path, ".rs") };
    var buf: [4096]u8 = undefined;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const code = codeOf(line, language_kind, &scan, &buf) orelse continue;
        const hit = firstVagueIdentifier(code, language_kind) orelse continue;
        try appendViolation(gpa, violations, "{s}:{d}: the identifier `{s}` carries the word native, which names no one thing: say ffi, zig, host, own, glowcap, or the owner it points at", .{ path, line_no, hit });
    }
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (trees) |tree| {
        const files = try util.collectSourceFiles(io, gpa, root, tree, isCode) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for the native-identifier check", .{tree});
            continue;
        };
        defer {
            for (files) |path| gpa.free(path);
            gpa.free(files);
        }
        for (files) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for the native-identifier check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            try scanSource(gpa, violations, path, contents);
        }
    }
}

fn expectViolations(path: []const u8, contents: []const u8, expected: usize) !void {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try scanSource(gpa, &violations, path, contents);
    try std.testing.expectEqual(expected, violations.items.len);
}

test "a new identifier carrying native is refused in every language" {
    try expectViolations("src/a.zig", "fn nativeThing() void {}\n", 1);
    try expectViolations("src/a.zig", "const x = is_native;\n", 1);
    try expectViolations("src/a.rs", "let GLOWCAP_NATIVE_CODEC = 1;\n", 1);
    try expectViolations("apps/a.ts", "export function isNative() {}\n", 1);
    try expectViolations("apps/a.py", "def test_native_route(self):\n", 1);
    try expectViolations("apps/a.rkt", "(define native-handle 1)\n", 1);
}

test "comments, literals, and other words are not identifiers" {
    try expectViolations("src/a.zig", "// a native stack\n/// the native word\nconst a = 1; // native\n", 0);
    try expectViolations("src/a.zig", "const s = \"native\"; const alt = alternatives;\n", 0);
    try expectViolations("src/a.rs", "/* native\n still native */ let natively = 1;\n", 0);
    try expectViolations("apps/a.py", "x = 1  # native\n\"\"\"native\nstill native\"\"\"\ny = 2\n", 0);
    try expectViolations("apps/a.rkt", "; the native loop\n(define alternative 1)\n", 0);
    try expectViolations("src/a.zig", "    \\\\ native in a multiline string\n", 0);
}

test "byte-order helpers and outside names stay allowed" {
    try expectViolations("src/a.zig", "const n = std.mem.nativeToBig(u16, p);\nconst e = native_endian;\n", 0);
    try expectViolations("src/a.rs", "let v = rustls_native_certs::load_native_certs();\n", 0);
    try expectViolations("apps/a.ts", "t as Deno.NativeType; e.nativeEvent.isComposing;\n", 0);
    try expectViolations("apps/a.zig", "fn nativeToBigger() void {}\n", 1);
}
