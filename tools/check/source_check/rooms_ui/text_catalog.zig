//! Rooms reader-facing text belongs to `apps/rooms/lib/text/`.
//! This check scans UI components and their TypeScript helpers for quoted
//! sentences, template literals and visible JSX text, including multiple lines.
//! Reader-facing props also cover short labels without sentence punctuation.
//!
//! The sentence heuristic is narrow to keep false positives
//! from obscuring real prose. Comments, throw/log lines, and a shader's source
//! (a template opened by `/* wgsl */`) are outside the reader-text boundary. Component specimens have explicit exemptions below.
//!
//! Negative probes in `SessionSetup.tsx` cover JSX text, quoted expressions
//! and template literals. A `className` full of words stays admissible.

const std = @import("std");
const util = @import("../util.zig");
const shared = @import("shared.zig");

const appendViolation = util.appendViolation;
const ui_dir = shared.ui_dir;

/// The parts catalog, and nothing else, ever.
///
/// Its own header says what it is: "Not a product surface: nothing here is how
/// a reader does a job." Its labels are specimen captions naming the components
/// it puts on display, "Icon buttons", "With a count", "A question", so
/// moving them to a locale catalog would translate nothing anybody reads and
/// would leave a gallery whose one job is being scannable unreadable in source.
///
/// The exemptions cover component specimens. The catalog's second half,
/// `KitchenAnswers.tsx`, is the same gallery in a
/// second file. A third entry is a deliberate edit and needs its own reason
/// beside these.
const exempt = [_][]const u8{ "KitchenSink.tsx", "KitchenAnswers.tsx" };

fn isExempt(path: []const u8) bool {
    for (exempt) |row| {
        if (std.mem.eql(u8, row, path)) return true;
    }
    return false;
}

/// Whether a run of text is prose rather than a name a machine reads.
///
/// Two or more words, and not one of the shapes that merely look like prose:
/// a URL or locator, a format placeholder, or a run of words that is really a
/// class list. The test is cheap: this check catches the author who
/// reached for a literal out of habit, and adjudicating English is not its job.
fn looksSpoken(value: []const u8) bool {
    if (value.len < 8) return false;
    if (std.mem.indexOf(u8, value, "://") != null) return false;
    if (std.mem.indexOfScalar(u8, value, '{') != null) return false;
    // A selector or an expression, and a list of key names like
    // `ArrowLeft ArrowRight`, where every word carries a capital inside it.
    if (std.mem.indexOfAny(u8, value, "=[") != null) return false;
    if (isPascalList(value)) return false;
    if (isNameList(value)) return false;
    if (isPathData(value)) return false;
    // A call, as in a CSS value like `rgb(0 0 0 / 0.5)`. Prose puts a space
    // before an opening parenthesis.
    for (value[1..], 1..) |c, i| {
        const before = value[i - 1];
        if (c == '(' and (std.ascii.isAlphanumeric(before) or before == '-')) return false;
    }
    // A selector or a media query starts with its own punctuation, and no
    // selector has a space right after its opening mark. A sentence that
    // opens with a rendered mark does: `#${room} is already live here.`
    // reads `# is already live here.` once its holes are cut, and that
    // space is what tells it apart from `#boot .boot-mark`.
    if (value[0] == '.' or value[0] == '#' or value[0] == '(') {
        if (value.len < 2 or value[1] != ' ') return false;
    }
    var spaces: usize = 0;
    var sentence = false;
    for (value, 0..) |c, i| {
        if (c == ' ') spaces += 1;
        if (c == '.' or c == ',' or c == '?' or c == '!' or c == ':') sentence = true;
        // A capital that starts a word. One inside a word is an identifier's,
        // as in a class list of camelCase names.
        if (std.ascii.isUpper(c) and (i == 0 or value[i - 1] == ' ')) sentence = true;
    }
    if (spaces == 0) return false;
    return sentence;
}

/// A short visible label. The sentence arm above ignores these
/// because the same shape is common in program identifiers, JSX text and
/// named reader-facing props provide the context that makes one a product
/// word instead.
fn looksLabel(value: []const u8) bool {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '{') != null) return false;
    for (value) |c| {
        if (std.ascii.isAlphabetic(c)) return true;
    }
    return false;
}

/// Whether every word is a PascalCase identifier: a capital first and another
/// capital after it, which no English word has.
fn isPascalList(value: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, value, ' ');
    while (words.next()) |word| {
        if (word.len < 2 or !std.ascii.isUpper(word[0])) return false;
        var inner_upper = false;
        for (word[1..]) |c| {
            if (std.ascii.isUpper(c)) inner_upper = true;
        }
        if (!inner_upper) return false;
    }
    return true;
}

/// A list of three or more names, `img, svg, video`: lowercase single words
/// between commas. Prose has two words side by side, a capital, or an end
/// mark.
fn isNameList(value: []const u8) bool {
    var items = std.mem.splitSequence(u8, std.mem.trimEnd(u8, value, ", "), ", ");
    var count: usize = 0;
    while (items.next()) |item| {
        if (item.len == 0) return false;
        for (item) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
        }
        count += 1;
    }
    return count >= 3;
}

/// An SVG path: every letter in it is a drawing command standing alone
/// between numbers, which no sentence is.
fn isPathData(value: []const u8) bool {
    var letters: usize = 0;
    for (value, 0..) |c, i| {
        if (!std.ascii.isAlphabetic(c)) continue;
        letters += 1;
        if (std.mem.indexOfScalar(u8, "MmLlHhVvCcSsQqTtAaZz", c) == null) return false;
        if (i + 1 < value.len and std.ascii.isAlphabetic(value[i + 1])) return false;
    }
    return letters > 0;
}

/// A template literal with its `${…}` holes cut out, so `Message #${room}`
/// is judged on the words around the hole rather than skipped for having one.
fn withoutHoles(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, value.len);
    var at: usize = 0;
    while (at < value.len) {
        if (std.mem.startsWith(u8, value[at..], "${")) {
            const close = std.mem.indexOfScalarPos(u8, value, at, '}') orelse value.len;
            at = @min(close + 1, value.len);
            continue;
        }
        out.appendAssumeCapacity(value[at]);
        at += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// JSX text with its `{…}` expressions cut out, so `Message {name} directly`
/// is judged on the words around the expression. Null when a brace is left
/// unpaired or nested, which is code (an opening block, an object) rather
/// than text.
fn withoutJsxHoles(gpa: std.mem.Allocator, value: []const u8) !?[]u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, value.len);
    errdefer out.deinit(gpa);
    var at: usize = 0;
    while (at < value.len) {
        switch (value[at]) {
            '{' => {
                const close = std.mem.indexOfAnyPos(u8, value, at + 1, "{}") orelse {
                    out.deinit(gpa);
                    return null;
                };
                if (value[close] == '{') {
                    out.deinit(gpa);
                    return null;
                }
                at = close + 1;
                continue;
            },
            '}' => {
                out.deinit(gpa);
                return null;
            },
            else => {},
        }
        out.appendAssumeCapacity(value[at]);
        at += 1;
    }
    return try out.toOwnedSlice(gpa);
}

/// Lines the check does not read: comments, imports, what goes to the log or
/// an error carrier rather than to a person, and a selector handed to the
/// DOM.
fn isUnread(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "//") or
        std.mem.startsWith(u8, line, "*") or
        std.mem.startsWith(u8, line, "import ") or
        std.mem.startsWith(u8, line, "throw ") or
        std.mem.indexOf(u8, line, "new Error(") != null or
        std.mem.indexOf(u8, line, "console.") != null or
        std.mem.indexOf(u8, line, "querySelector") != null or
        std.mem.indexOf(u8, line, ".startsWith(") != null or
        std.mem.indexOf(u8, line, ".includes(") != null or
        std.mem.indexOf(u8, line, ".endsWith(") != null or
        std.mem.indexOf(u8, line, ".closest(") != null or
        std.mem.indexOf(u8, line, ".matches(") != null;
}

const Report = struct {
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    line_no: usize,

    fn say(self: *Report, comptime shape: []const u8, text: []const u8) !void {
        try appendViolation(
            self.gpa,
            self.violations,
            "{s}:{d}: " ++ shape ++ " `{s}` is a sentence written at its call site; " ++
                "a reader's words live in apps/rooms/lib/text/ so the product's voice can be read in one place and translated from it",
            .{ self.path, self.line_no, text },
        );
    }
};

/// Every quoted literal on the line that reads as a sentence.
fn quotedArm(report: *Report, line: []const u8, quote: u8) !void {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, at, quote)) |open| {
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, quote) orelse return;
        at = close + 1;
        const value = line[open + 1 .. close];
        if (quote == '`') {
            const words = try withoutHoles(report.gpa, value);
            defer report.gpa.free(words);
            if (looksSpoken(words)) try report.say("template literal", value);
        } else if (looksSpoken(value)) {
            try report.say("literal", value);
        }
    }
}

/// Quoted values on props and object fields whose value a reader sees or
/// hears. Keeping this list about field semantics avoids treating every state
/// tag and route name as copy while still catching one-word labels that
/// sentence heuristics cannot.
fn quotedLabelArm(report: *Report, line: []const u8) !void {
    for ([_][]const u8{ "aria-label", "label", "title", "placeholder", "said", "keep", "commit", "what" }) |prop| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, prop)) |found| {
            var open = found + prop.len;
            if (open >= line.len or (line[open] != '=' and line[open] != ':')) {
                at = open;
                continue;
            }
            open += 1;
            while (open < line.len and (line[open] == ' ' or line[open] == '\t')) open += 1;
            if (open >= line.len or line[open] != '"') {
                at = open;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse break;
            const value = line[open + 1 .. close];
            if (!looksSpoken(value) and looksLabel(value)) try report.say("reader-facing field", value);
            at = close + 1;
        }
    }
}

/// JSX text that opens after a tag on this line: the run from a `>` to the
/// next `<`, or to the end of the line when the text carries on below, with
/// its `{…}` expressions cut out.
fn inlineTextArm(report: *Report, line: []const u8) !void {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, at, '>')) |gt| {
        at = gt + 1;
        // `=>` and `->` are code, and so is a comparison.
        if (gt > 0 and (line[gt - 1] == '=' or line[gt - 1] == '-' or line[gt - 1] == ' ')) continue;
        const rest = line[gt + 1 ..];
        var end = rest.len;
        for (rest, 0..) |c, i| {
            if (c == '<') {
                end = i;
                break;
            }
        }
        at = gt + 1 + end;
        const words = try withoutJsxHoles(report.gpa, rest[0..end]) orelse continue;
        defer report.gpa.free(words);
        const segment = std.mem.trim(u8, words, " \t\r");
        if (std.mem.indexOfAny(u8, segment, "=;()\"`") != null) continue;
        // What follows a generic's closing angle is code: a comma, a colon,
        // a paren, a bar.
        if (segment.len > 0 and std.mem.indexOfScalar(u8, ",:)|&]}", segment[0]) != null) continue;
        if (looksSpoken(segment) or looksLabel(segment)) try report.say("JSX text", segment);
    }
}

/// A line that is nothing but text: JSX text continuing under the tag that
/// opened it. The lines of an object literal, a type, or a ternary wrapped
/// over several lines look like text to a character count and are told
/// apart by their shape: a leading operator or keyword, a key followed by
/// its colon, or a member access with no space around the dot. A `{…}`
/// expression in the text is cut out first, as on the screen it is a value.
fn textLineArm(report: *Report, raw: []const u8) !void {
    const words = try withoutJsxHoles(report.gpa, raw) orelse return;
    defer report.gpa.free(words);
    const line = std.mem.trim(u8, words, " \t\r");
    if (std.mem.indexOfAny(u8, line, "<>=;()\"`|&+[]*") != null) return;
    // Arithmetic in an argument list wrapped over several lines, `x - REACH,`.
    // A sentence here has no dash at all.
    if (std.mem.indexOf(u8, line, " - ") != null) return;
    if (line.len == 0) return;
    if (line[0] == '?' or line[0] == ':' or line[0] == '.') return;
    if (std.mem.indexOf(u8, line, "??") != null or std.mem.indexOf(u8, line, "?.") != null) return;
    // A ternary, `local ? { … } : { … },`, which no sentence spells.
    if (std.mem.indexOf(u8, line, " ? ") != null) return;
    // `name as OTHER_NAME,` inside an import or export list.
    if (std.mem.indexOf(u8, line, " as ") != null and std.mem.count(u8, line, " ") == 2) return;
    for ([_][]const u8{
        "type ", "readonly ", "case ",     "return ", "await ",  "const ",
        "let ",  "export ",   "function ", "class ",  "import ", "interface ",
        "enum ",
    }) |keyword| {
        if (std.mem.startsWith(u8, line, keyword)) return;
    }
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, line[0..colon], ' ') == null) return;
    }
    var at: usize = 1;
    while (at + 1 < line.len) : (at += 1) {
        if (line[at] == '.' and std.ascii.isAlphanumeric(line[at - 1]) and std.ascii.isAlphabetic(line[at + 1])) return;
    }
    if (looksSpoken(line)) try report.say("JSX text", line);
}

fn inspectBody(report: *Report, body: []const u8) !void {
    var in_comment = false;
    // A shader's source, from the backtick after `/* wgsl */` to the line its
    // closing backtick opens. WGSL's `struct Point { … }` and `array<f32>`
    // read as JSX text to the arms below.
    var in_shader = false;
    // A log call whose arguments run onto the lines below it.
    var in_log = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    report.line_no = 0;
    while (lines.next()) |raw| {
        report.line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (in_shader) {
            if (std.mem.startsWith(u8, line, "`")) in_shader = false;
            continue;
        }
        if (std.mem.endsWith(u8, line, "/* wgsl */ `")) {
            in_shader = true;
            continue;
        }
        if (in_comment) {
            if (std.mem.indexOf(u8, line, "*/") != null) in_comment = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, "/*")) |open| {
            if (std.mem.indexOfPos(u8, line, open, "*/") == null) in_comment = true;
            continue;
        }
        if (in_log) {
            if (std.mem.indexOf(u8, line, ");") != null) in_log = false;
            continue;
        }
        if ((std.mem.indexOf(u8, line, "console.") != null or std.mem.indexOf(u8, line, "Error(") != null) and
            std.mem.indexOf(u8, line, ");") == null)
        {
            in_log = true;
            continue;
        }
        if (isUnread(line)) continue;
        try quotedLabelArm(report, line);
        try quotedArm(report, line, '"');
        try quotedArm(report, line, '`');
        try inlineTextArm(report, line);
        try textLineArm(report, line);
    }
}

pub fn checkRoomsTextCatalog(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, ui_dir, .{ .iterate = true }) catch {
        try appendViolation(gpa, violations, "{s}: could not be opened", .{ui_dir});
        return;
    };
    defer dir.close(io);

    var seen_exempt: usize = 0;
    var inspected: usize = 0;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".tsx") and !std.mem.endsWith(u8, entry.basename, ".ts")) continue;
        if (isExempt(entry.path)) {
            seen_exempt += 1;
            continue;
        }
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ui_dir, entry.path });
        defer gpa.free(path);
        const body = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch {
            try appendViolation(gpa, violations, "{s}: could not be read", .{path});
            continue;
        };
        defer gpa.free(body);
        inspected += 1;

        var report = Report{ .gpa = gpa, .violations = violations, .path = path, .line_no = 0 };
        try inspectBody(&report, body);
    }

    // The guard both ways. With nothing inspected the check is watching
    // nothing; with an exempt component missing the list names a ghost.
    if (inspected == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: no component is held to the text catalog, so this check proves nothing",
            .{ui_dir},
        );
    }
    if (seen_exempt != exempt.len) {
        try appendViolation(
            gpa,
            violations,
            "{s}: the text catalog's exemption names a component that is not there; delete the row or fix the path",
            .{ui_dir},
        );
    }
}

test "a sentence that opens with a rendered mark is prose; selector shapes are not" {
    // `#${room} is already live here. …` reads like this once its hole is cut:
    // the mark, then a space, then words. It is prose and must be flagged.
    try std.testing.expect(looksSpoken(
        "# is already live here. Turn off Private to open it, or choose another name for a new private room.",
    ));
    // None of these has a space right after the opening mark, which no real
    // selector or media query does. The first also carries `[`, judged by the
    // expression rule; the others hang on the mark rule above.
    try std.testing.expect(!looksSpoken("#, Btn, [data-menu-in=\"\"]"));
    try std.testing.expect(!looksSpoken("(max-width: 820px)"));
    try std.testing.expect(!looksSpoken("#boot .boot-mark"));
    // The ordinary sentence verdict is unchanged.
    try std.testing.expect(looksSpoken("Something went wrong. Try again later."));
}

test "a CSS value is not prose, and a sentence with an aside is" {
    try std.testing.expect(!looksSpoken("radial-gradient(ellipse 62% 56% at 50% 44%, rgb(0 0 0 / ), "));
    try std.testing.expect(!looksSpoken("rgb(0 0 0 / ) 55%, #000 96%)"));
    try std.testing.expect(looksSpoken("Paste the link (the one it printed) here."));
}

test "a list of names is not prose, and a list in a sentence is" {
    try std.testing.expect(!looksSpoken("img, svg, video, canvas, iframe, audio, object, embed"));
    try std.testing.expect(!looksSpoken("a, button, input, textarea, "));
    try std.testing.expect(looksSpoken("Rooms, members, and messages stay here."));
    try std.testing.expect(looksSpoken("rooms, members and messages"));
}

test "JSX text is judged with its expressions cut out, and a lone brace is code" {
    const gpa = std.testing.allocator;
    const words = (try withoutJsxHoles(gpa, "Message {view.name} directly")).?;
    defer gpa.free(words);
    try std.testing.expectEqualStrings("Message  directly", words);
    try std.testing.expect(looksSpoken(words));
    try std.testing.expect(try withoutJsxHoles(gpa, "} else {") == null);
    try std.testing.expect(try withoutJsxHoles(gpa, "{ a: { b } }") == null);
}

test "a shader's source is code, and text after it is still read" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    var report: Report = .{ .gpa = gpa, .violations = &violations, .path = "probe.ts", .line_no = 0 };
    try inspectBody(&report,
        \\export const SHADER = /* wgsl */ `
        \\struct Point { pos: vec2f, width: f32 }
        \\@group(0) @binding(0) var<storage, read> points: array<Point>;
        \\`;
        \\const label = "Something went wrong. Try again later.";
    );
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "probe.ts:5:") != null);
}
