//! Discarded errors: a `catch` that empties, bare-exits, or substitutes a
//! value must state its bounded loss in a comment, in first-party Zig and
//! TypeScript.

const std = @import("std");
const source_tree = @import("../source_tree.zig");
const violation_log = @import("../violation_log.zig");
const exemptions = @import("discarded_errors/exemptions.zig");

const appendViolation = violation_log.appendViolation;

/// The first-party trees the check reads. `test` is whole because a test that
/// discards a failed step passes without running the step it claims to check.
pub const scanned_trees = [_][]const u8{ "src", "cli", "apps", "examples", "tools", "interop", "test", "bench", "conformance" };

/// The markers that open a justification comment.
const markers = [_][]const u8{ "best-effort:", "tolerant:" };

/// The TypeScript discard forms: a rejection handler with an empty body, and
/// an empty `catch` block.
const ts_discard_forms = [_][]const u8{
    ".catch(() => " ++ "{})",
    "catch " ++ "{}",
};

pub const Language = enum { zig, typescript };

/// A discarded error: an empty `catch` body, a `catch` that only returns,
/// continues, or breaks, or a `catch` that substitutes a literal (`null`,
/// `false`, `true`, a number, a string, or a tag) erases a failure's cause at
/// the site that saw it. A substituted value is the sharper case when the
/// error set holds allocation or I/O failure, because the caller reads
/// "absent" or "no" where the truth was "could not tell". Project values give
/// every failure an owner, so the discard is legitimate only where the loss is
/// bounded: a diagnostic line that cannot be reported because reporting is
/// what failed, a cosmetic interface update, a step the next wake or maintain
/// call already retries. Such a site says so in a `// best-effort:` or
/// `// tolerant:` comment on its own line or directly above it, with the
/// reason after the colon. Each discard carries its own comment. A call into
/// `pure_callees` or `pause_callees` needs none, and neither does a test's
/// discard under an `errdefer`, where the first error is the report.
///
/// `tools/` is in scope because a checker that discards an error skips work
/// it claims to have done, which is a false green. `test/` is in scope for the
/// same reason: a fixture step that fails and continues leaves the assertions
/// after it judging a state the test never built. A test that expects a
/// refusal of any name, a fake server whose read ends when its peer leaves,
/// and a fuzz step under an induced allocation failure carry the marker or
/// name the error through the budget in `test/support/fuzz_budget.zig`.
/// `interop/`, `bench/`, and `conformance/` are in scope because a peer or
/// bench that swallows a failure stalls until its deadline or reports a number
/// it never measured.
/// Vendored packages, pinned upstream submodules, and generated trees are not
/// first-party and are skipped.
///
/// First-party TypeScript in the same trees is held to the same sentence: a
/// `.catch(() => {})` or an empty `catch {}` marks a promise handled without
/// naming who lost what. Test and proof files are the one named boundary,
/// because their empty handlers sit in teardown after the verdict is in.
pub fn checkDiscardedErrors(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (scanned_trees) |tree| {
        const files = (try source_tree.collectSourceFiles(io, gpa, root, tree, keepDiscardScanned)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for discarded-error check", .{tree});
            continue;
        };
        defer {
            for (files) |path| gpa.free(path);
            gpa.free(files);
        }
        for (files) |path| {
            const language: Language = if (std.mem.endsWith(u8, path, ".zig")) .zig else .typescript;
            const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for discarded-error check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            const lines = try unjustifiedDiscards(gpa, contents, language, exemptions.unwindNeedsNoMarker(path));
            defer gpa.free(lines);
            for (lines) |line| try appendViolation(gpa, violations, "{s}:{d}: a discarded error (an empty `catch` body or rejection handler, a bare return/continue/break, or a substituted literal or tag) needs a `// best-effort:` or `// tolerant:` comment on its line or directly above, naming after the colon what is lost and why the loss is bounded, or the failure needs an owner", .{ path, line });
        }
    }
}

fn keepDiscardScanned(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or firstPartyTypeScript(path);
}

/// A `.ts` or `.tsx` source that is product or tool code rather than a test,
/// proof, or demo-run scenario.
fn firstPartyTypeScript(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".ts") and !std.mem.endsWith(u8, path, ".tsx")) return false;
    if (std.mem.endsWith(u8, path, ".d.ts")) return false;
    if (std.mem.find(u8, path, "/test/") != null) return false;
    if (std.mem.startsWith(u8, path, "test/") and
        !std.mem.startsWith(u8, path, "test/driver/transports/") and
        !std.mem.startsWith(u8, path, "test/support/transport/")) return false;
    if (std.mem.find(u8, path, "/tests/") != null or std.mem.startsWith(u8, path, "tests/")) return false;
    const base = std.Io.Dir.path.basename(path);
    return !std.mem.endsWith(u8, base, "_test.ts") and !std.mem.endsWith(u8, base, "-test.ts") and
        !std.mem.endsWith(u8, base, ".test.ts") and !std.mem.endsWith(u8, base, "_proof.ts");
}

/// One source line split into code (literal contents blanked) and its
/// trailing comment, if any.
const Line = struct {
    text: []const u8,
    /// Offset of the line in the file and in the blanked code.
    start: usize,
    /// Length of the code part. A comment, when present, starts here.
    code_len: usize,

    fn comment(self: Line) ?[]const u8 {
        if (self.code_len == self.text.len) return null;
        return self.text[self.code_len..];
    }

    fn commentOnly(self: Line, code: []const u8) bool {
        if (self.comment() == null) return false;
        const before = code[self.start..][0..self.code_len];
        return std.mem.trim(u8, before, " \t\r").len == 0;
    }
};

/// The 1-based line numbers in `contents` holding a discard with no
/// justification. The caller frees the slice.
pub fn unjustifiedDiscards(gpa: std.mem.Allocator, contents: []const u8, language: Language, unwind_needs_no_marker: bool) ![]usize {
    const code = try gpa.dupe(u8, contents);
    defer gpa.free(code);
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    var start: usize = 0;
    while (start <= contents.len) {
        const end = std.mem.findScalarPos(u8, contents, start, '\n') orelse contents.len;
        const code_len = blankLine(code[start..end], language);
        // Comments are not code: blank them so the scan below sees none.
        @memset(code[start + code_len .. end], ' ');
        try lines.append(gpa, .{ .text = contents[start..end], .start = start, .code_len = code_len });
        start = end + 1;
    }

    var found: std.ArrayList(usize) = .empty;
    errdefer found.deinit(gpa);
    for (lines.items, 0..) |line, index| {
        const line_code = code[line.start..][0..line.code_len];
        const discards = switch (language) {
            .zig => zigLineDiscards(code, line.start, line_code, unwind_needs_no_marker),
            .typescript => typescriptLineDiscards(line_code),
        };
        if (!discards) continue;
        if (justified(lines.items, code, index)) continue;
        try found.append(gpa, index + 1);
    }
    return found.toOwnedSlice(gpa);
}

/// Blank string and character literal contents in `line` in place and return
/// the length of its code part, which ends where a line comment begins.
/// Quotes stay, so a literal cannot splice into a pattern across its edges.
/// A Zig multiline string line is all literal.
fn blankLine(line: []u8, language: Language) usize {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (language == .zig and std.mem.startsWith(u8, trimmed, "\\\\")) {
        @memset(line[line.len - trimmed.len ..], ' ');
        return line.len;
    }
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return i;
        if (c == '"' or c == '\'' or (language == .typescript and c == '`')) {
            i += 1;
            while (i < line.len and line[i] != c) {
                const escaped = line[i] == '\\';
                line[i] = ' ';
                i += 1;
                if (escaped and i < line.len) {
                    line[i] = ' ';
                    i += 1;
                }
            }
            if (i < line.len) i += 1;
            continue;
        }
        i += 1;
    }
    return line.len;
}

fn typescriptLineDiscards(line_code: []const u8) bool {
    for (ts_discard_forms) |form| {
        if (std.mem.find(u8, line_code, form) != null) return true;
    }
    return false;
}

/// True when a `catch` or an `else |_|` on this line discards its error and
/// the call it guards is in neither `pure_callees` nor `pause_callees`. With
/// `unwind_needs_no_marker`, a discard under an `errdefer` does not count.
fn zigLineDiscards(code: []const u8, line_start: usize, line_code: []const u8, unwind_needs_no_marker: bool) bool {
    var at: usize = 0;
    while (at < line_code.len) : (at += 1) {
        const keyword: []const u8 = if (wordAt(line_code, at, "catch"))
            "catch"
        else if (wordAt(line_code, at, "else"))
            "else"
        else
            continue;
        const after = line_start + at + keyword.len;
        const named_capture_required = std.mem.eql(u8, keyword, "else");
        if (!discardFollows(code, after, named_capture_required)) continue;
        if (std.mem.eql(u8, keyword, "catch") and exemptions.exemptCallee(code, line_start + at)) continue;
        if (unwind_needs_no_marker and exemptions.underErrdefer(code, line_start + at)) continue;
        return true;
    }
    return false;
}

/// Classify what follows a `catch` (or an `else` with an error capture). A
/// named capture counts as used, since Zig refuses an unused one, unless the
/// block's first statement assigns it to `_`. That drops it as surely as `|_|`
/// does, so what follows is judged the same way.
fn discardFollows(code: []const u8, from: usize, capture_required: bool) bool {
    var p = skipSpace(code, from);
    var capture: []const u8 = "_";
    if (p < code.len and code[p] == '|') {
        const close = std.mem.findScalarPos(u8, code, p + 1, '|') orelse return false;
        capture = std.mem.trim(u8, code[p + 1 .. close], " ");
        p = skipSpace(code, close + 1);
    } else if (capture_required) return false;
    var braced = false;
    if (p < code.len and code[p] == '{') {
        braced = true;
        p = skipSpace(code, p + 1);
        if (!std.mem.eql(u8, capture, "_")) {
            const after = skipDroppedCapture(code, p, capture);
            if (after == p) return false;
            p = after;
        }
        if (p < code.len and code[p] == '}') return true;
    } else if (!std.mem.eql(u8, capture, "_")) return false;
    if (wordAt(code, p, "return")) return exitDiscards(code, skipSpace(code, p + "return".len));
    if (wordAt(code, p, "continue")) return true;
    if (wordAt(code, p, "break")) {
        p = skipSpace(code, p + "break".len);
        if (p < code.len and code[p] == ':') {
            p += 1;
            while (p < code.len and identChar(code[p])) p += 1;
            p = skipSpace(code, p);
        }
        return exitDiscards(code, p);
    }
    if (braced) return false;
    return literalAt(code, p);
}

/// The position after `_ = capture;` at `p`, or `p` when no such statement
/// starts there.
fn skipDroppedCapture(code: []const u8, p: usize, capture: []const u8) usize {
    if (!wordAt(code, p, "_")) return p;
    var at = skipSpace(code, p + 1);
    if (at >= code.len or code[at] != '=') return p;
    at = skipSpace(code, at + 1);
    if (!wordAt(code, at, capture)) return p;
    at = skipSpace(code, at + capture.len);
    if (at >= code.len or code[at] != ';') return p;
    return skipSpace(code, at + 1);
}

/// A bare exit, or one that carries a literal, after `return` or `break`.
fn exitDiscards(code: []const u8, p: usize) bool {
    if (p >= code.len) return true;
    if (std.mem.findScalar(u8, ";,})", code[p]) != null) return true;
    return literalAt(code, p);
}

fn literalAt(code: []const u8, p: usize) bool {
    if (p >= code.len) return false;
    for ([_][]const u8{ "null", "false", "true", "undefined" }) |word| {
        if (wordAt(code, p, word)) return true;
    }
    const c = code[p];
    if (std.ascii.isDigit(c) or c == '"' or c == '\'') return true;
    if (c == '-' and p + 1 < code.len and std.ascii.isDigit(code[p + 1])) return true;
    if (c == '.' and p + 1 < code.len) return tagOrStructLiteral(code, p + 1);
    return false;
}

/// A `.tag` or a `.{ ... }` built from constants. A decl-literal call
/// (`.fromError(error.OutOfMemory)`) or a struct that calls or names an error
/// constructs its answer from the failure, which is a remap, not a discard.
fn tagOrStructLiteral(code: []const u8, p: usize) bool {
    if (code[p] == '{') {
        var depth: usize = 0;
        var q = p;
        while (q < code.len) : (q += 1) {
            switch (code[q]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        const body = code[p..@min(q, code.len)];
        return std.mem.findScalar(u8, body, '(') == null and std.mem.find(u8, body, "error.") == null;
    }
    if (!std.ascii.isAlphabetic(code[p]) and code[p] != '_') return false;
    var q = p;
    while (q < code.len and identChar(code[q])) q += 1;
    return q >= code.len or code[q] != '(';
}

/// A justification is a `//` comment opening with a marker and a reason,
/// trailing the discard's own line, on a line of the comment block that ends
/// directly above it, or, when the line opens the discarding block, on a
/// line of the comment block that starts that block's body.
fn justified(lines: []const Line, code: []const u8, index: usize) bool {
    const line = lines[index];
    if (line.comment()) |comment| {
        if (markerComment(comment)) return true;
    }
    var j = index;
    while (j > 0) {
        j -= 1;
        if (!lines[j].commentOnly(code)) break;
        if (markerComment(lines[j].comment().?)) return true;
    }
    const line_code = std.mem.trimEnd(u8, code[line.start..][0..line.code_len], " \t\r");
    if (!std.mem.endsWith(u8, line_code, "{")) return false;
    j = index + 1;
    while (j < lines.len and lines[j].commentOnly(code)) : (j += 1) {
        if (markerComment(lines[j].comment().?)) return true;
    }
    return false;
}

fn markerComment(comment: []const u8) bool {
    if (!std.mem.startsWith(u8, comment, "// ")) return false;
    const text = comment["// ".len..];
    for (markers) |marker| {
        if (!std.mem.startsWith(u8, text, marker)) continue;
        for (text[marker.len..]) |c| {
            if (std.ascii.isAlphabetic(c)) return true;
        }
        return false;
    }
    return false;
}

pub fn skipSpace(code: []const u8, from: usize) usize {
    var p = from;
    while (p < code.len and std.ascii.isWhitespace(code[p])) p += 1;
    return p;
}

pub fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn wordAt(code: []const u8, at: usize, word: []const u8) bool {
    if (at > code.len or !std.mem.startsWith(u8, code[at..], word)) return false;
    if (at > 0 and (identChar(code[at - 1]) or code[at - 1] == '@')) return false;
    const end = at + word.len;
    return end >= code.len or !identChar(code[end]);
}

fn expectFlagged(source: []const u8, language: Language, expected: []const usize) !void {
    const found = try unjustifiedDiscards(std.testing.allocator, source, language, true);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualSlices(usize, expected, found);
}

test "discarded errors: every Zig form fails with no marker" {
    const forms = [_][]const u8{
        "f() catch {};",
        "f() catch |_| {};",
        "f() catch return;",
        "g(f() catch return, 1);",
        "f() catch continue;",
        "f() catch break;",
        "f() catch break :blk;",
        "f() catch break :blk false;",
        "const x = f() catch null;",
        "const x = f() catch false;",
        "const x = f() catch true;",
        "const x = f() catch 0;",
        "const x = f() catch -1;",
        "const x = f() catch \"none\";",
        "const x = f() catch .fallback;",
        "const x = f() catch .{};",
        "const x = f() catch return null;",
        "const x = f() catch return false;",
        "const x = f() catch return true;",
        "const x = f() catch return 0;",
        "const x = f() catch return -1;",
        "const x = f() catch return \"unrecorded\";",
        "const x = f() catch return .failed;",
        "const x = f() catch { return null; };",
        "const x = f() catch |_| { return false; };",
        "if (f()) |v| use(v) else |_| {}",
        "const x = f(\n    a,\n) catch null;",
    };
    for (forms) |form| {
        const lines = std.mem.count(u8, form, "\n") + 1;
        try expectFlagged(form, .zig, &.{lines});
    }
    // A discard whose exit sits on the next line is flagged at its `catch`.
    try expectFlagged("const x = f() catch\n    return null;", .zig, &.{1});
    try expectFlagged("const x = f() catch\n    break :blk null;", .zig, &.{1});
}

test "discarded errors: an empty error block needs a marker inside it" {
    try expectFlagged("if (f()) |v| {\n    use(v);\n} else |_| {\n    // tolerant: a failed shrink keeps the larger buffer.\n}", .zig, &.{});
    try expectFlagged("if (f()) |v| {\n    use(v);\n} else |_| {\n    // the buffer stays\n}", .zig, &.{3});
}

test "discarded errors: an answer built from the failure is a remap" {
    const sources = [_][]const u8{
        "const x = f() catch\n    return .fromError(error.OutOfMemory);",
        "const x = f() catch\n    return .{ .failed = .init(error.InvalidAddress) };",
        "const x = f() catch {\n    return .{ .settled = try breakWith(\"bad\") };\n};",
    };
    for (sources) |source| try expectFlagged(source, .zig, &.{});
}

test "discarded errors: these forms are discards too" {
    const forms = [_][]const u8{
        "const x = f() catch return .{ .ready = false };",
        "const x = if (f()) |_| true else |_| false;",
        "f() catch |err| { _ = err; };",
        "f() catch |err| { _ = err; return .{ .ready = false }; };",
        "if (f()) |v| use(v) else |err| { _ = err; }",
    };
    for (forms) |form| {
        const lines = std.mem.count(u8, form, "\n") + 1;
        try expectFlagged(form, .zig, &.{lines});
    }
    try expectFlagged("f() catch |err| {\n    _ = err;\n    return;\n};", .zig, &.{1});
}

test "discarded errors: a used error, a panic, or a remapped error is no discard" {
    const sources = [_][]const u8{
        "f() catch |err| return err;",
        "f() catch |err| switch (err) { else => {} };",
        "f() catch unreachable;",
        "f() catch return error.Refused;",
        "f() catch @panic(\"x\");",
        "const x = f() catch fallback;",
        "const s = \"f() catch null\";",
        "// f() catch null",
        "\\\\ f() catch null",
        "if (f()) |v| use(v) else {}",
        "f() catch |err| { _ = err; log(); };",
        "f() catch |err| { log(err); return; };",
        "f() catch |err| return .{ .failed = err };",
        "const x = if (f()) |v| .{ .ok = v } else |err| .{ .failure = err };",
    };
    for (sources) |source| try expectFlagged(source, .zig, &.{});
}

test "discarded errors: a marker comment on the line or directly above justifies one discard" {
    try expectFlagged("f() catch {}; // best-effort: the next wake retries this flush.", .zig, &.{});
    try expectFlagged("// tolerant: a missing hint is an absent hint.\nconst x = f() catch null;", .zig, &.{});
    try expectFlagged("// tolerant: the cache is refilled on the next read,\n// so only this lookup is lost.\nconst x = f() catch null;", .zig, &.{});
}

test "discarded errors: a marker that is not a real, adjacent, reasoned comment fails" {
    // In a string literal, not a comment.
    try expectFlagged("const x = f(\"tolerant: no\") catch null;", .zig, &.{1});
    // No words after the colon.
    try expectFlagged("const x = f() catch null; // tolerant:", .zig, &.{1});
    // Mid-sentence rather than opening the comment.
    try expectFlagged("const x = f() catch null; // this is tolerant: really", .zig, &.{1});
    // A code line stands between the comment and the discard.
    try expectFlagged("// tolerant: a missing hint is absent.\nconst y = 1;\nconst x = f() catch null;", .zig, &.{3});
    // One marker covers one discard, not the run under it.
    try expectFlagged("// best-effort: the unwind already failed.\na() catch {};\nb() catch {};", .zig, &.{3});
    // A doc comment is not a justification.
    try expectFlagged("/// tolerant: documented.\nconst x = f() catch null;", .zig, &.{2});
}

test "discarded errors: a pure std callee needs no marker, any other callee does" {
    try expectFlagged("const n = std.fmt.parseInt(u64, s, 10) catch null;", .zig, &.{});
    try expectFlagged("const n = std.fmt.parseInt(\n    u64,\n    s,\n    10,\n) catch return null;", .zig, &.{});
    try expectFlagged("const n = std.math.add(usize, std.math.mul(usize, a, 8) catch return null, b) catch return null;", .zig, &.{});
    try expectFlagged("const m = std.mem.print(&buf, \"{d}\", .{n}) catch \"?\";", .zig, &.{});
    try expectFlagged("const n = std.math.divCeil(usize, a, b) catch 1;", .zig, &.{});
    try expectFlagged("const n = parseInt(u64, s, 10) catch null;", .zig, &.{1});
    try expectFlagged("const f = std.fs.cwd().openFile(p, .{}) catch null;", .zig, &.{1});
    // The pure call is inner. The discard guards the outer call.
    try expectFlagged("const n = load(std.fmt.parseInt(u64, s, 10) catch 0) catch null;", .zig, &.{1});
}

test "discarded errors: a std yield needs no marker, a sleep or a pause the code names itself does" {
    try expectFlagged("while (!done.load(.acquire)) std.Thread.yield() catch {};", .zig, &.{});
    try expectFlagged("std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};", .zig, &.{1});
    try expectFlagged("std.Io.sleep(io, pause, .awake) catch return;", .zig, &.{1});
    try expectFlagged("const yield = std.Thread.yield;\nyield() catch {};", .zig, &.{2});
    try expectFlagged("self.sleep(io, 2) catch {};", .zig, &.{1});
    try expectFlagged("worker.join() catch {};", .zig, &.{1});
}

test "discarded errors: a test's cleanup under an errdefer needs no marker, a defer does" {
    try expectFlagged("errdefer _ = serving.cancel(io) catch {};", .zig, &.{});
    try expectFlagged("errdefer if (future) |*f| f.cancel(io) catch {};", .zig, &.{});
    try expectFlagged("errdefer {\n    done.store(true, .release);\n    serving.await(io) catch {};\n}", .zig, &.{});
    try expectFlagged("errdefer {\n    if (open) {\n        store.close(.{ .sync = true }) catch {};\n    }\n}", .zig, &.{});
    try expectFlagged("defer serving.await(io) catch {};", .zig, &.{1});
    try expectFlagged("defer {\n    serving.await(io) catch {};\n}", .zig, &.{2});
    try expectFlagged("errdefer a.deinit();\nb.close() catch {};", .zig, &.{2});
    try expectFlagged("errdefer {\n    a.deinit();\n}\nb.close() catch {};", .zig, &.{4});
    try expectFlagged("fn run() void {\n    errdefer a.deinit();\n    if (x) {\n        b.close() catch {};\n    }\n}", .zig, &.{4});
    // Either arm of an errdefer's `if`, a typed literal in its statement, and a defer inside its block.
    try expectFlagged("errdefer if (a) {\n    b.close() catch {};\n} else {\n    c.close() catch {};\n}", .zig, &.{});
    try expectFlagged("errdefer store.close(Options{ .sync = true }) catch {};", .zig, &.{});
    try expectFlagged("errdefer {\n    defer a.close() catch {};\n}", .zig, &.{});
    try expectFlagged("if (a) {\n    x();\n} else {\n    c.close() catch {};\n}", .zig, &.{4});
    // A brace or the word in a string or a comment opens nothing.
    try expectFlagged("const s = \"errdefer {\";\nb.close() catch {};", .zig, &.{2});
    try expectFlagged("// errdefer {\nb.close() catch {};", .zig, &.{2});
    try expectFlagged("errdefer log(\"}\");\nb.close() catch {};", .zig, &.{2});
}

test "discarded errors: library and application code marks an errdefer discard too" {
    const source = "errdefer lock.release() catch {};";
    const product = try unjustifiedDiscards(std.testing.allocator, source, .zig, false);
    defer std.testing.allocator.free(product);
    try std.testing.expectEqualSlices(usize, &.{1}, product);
    for ([_][]const u8{ "test/driver/a.zig", "apps/tasks/zig/board_test.zig" }) |path| {
        try std.testing.expect(exemptions.unwindNeedsNoMarker(path));
    }
    for ([_][]const u8{ "src/loam/engines/lmdb/mod.zig", "apps/tasks/zig/storage.zig", "cli/mcp/mod.zig", "bench/a.zig", "tools/a.zig", "examples/zig/a.zig" }) |path| {
        try std.testing.expect(!exemptions.unwindNeedsNoMarker(path));
    }
}

test "discarded errors: the whole test tree is scanned, not a subtree of it" {
    for (scanned_trees) |tree| {
        try std.testing.expect(!std.mem.startsWith(u8, tree, "test/"));
    }
    for (scanned_trees) |tree| {
        if (std.mem.eql(u8, tree, "test")) return;
    }
    return error.TestTreeNotScanned;
}

test "discarded errors: the TypeScript forms fail with no marker and pass with one" {
    try expectFlagged("p.catch(() => {});", .typescript, &.{1});
    try expectFlagged("try { f(); } catch {}", .typescript, &.{1});
    try expectFlagged("p.catch(() => {}); // tolerant: the caller awaits the same promise.", .typescript, &.{});
    try expectFlagged("const s = `.catch(() => {})`;", .typescript, &.{});
}
