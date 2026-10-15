//! Human doc voice: the banned scaffold needles, habitual em-dash shapes,
//! semicolons and em dashes in reader prose,
//! the justification tic and its closed `apps/` debt list, connective arrows
//! outside fences, headings that spend contrast before the subject has a
//! name, and the prose sentence and paragraph ceilings.

const std = @import("std");
const util = @import("../util.zig");
const voice_debt = @import("voice_debt.zig");
const reader_voice = @import("reader_voice.zig");
const kinds = @import("kinds.zig");
const paragraphs = @import("paragraphs.zig");

const appendViolation = util.appendViolation;
const bans = @import("../bans.zig");

/// The human-doc-voice phrase and `.agents/` link bans live in
/// `source_check/bans.zig` (`human_doc_voice`), driven by
/// `bans.human_doc_voice_scopes`. This walks those same scopes and holds the
/// doc-voice bans that need line and fence structure: connective arrows and
/// headings that define a subject by what it is not.
pub fn checkHumanDocVoice(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (bans.human_doc_voice_scopes) |scope| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban
        // rows; do not report it a second time here.
        bans.collectFiles(io, arena, root, scope.where, &files) catch continue;
        for (files.items) |path| {
            // tolerant: a read failure is either an optional file or already
            // reported by the ban rows; these line-structure checks stay
            // silent on it.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try banConnectiveArrowOutsideFences(gpa, violations, path, contents);
            if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".smd")) {
                try banNegationHeadings(gpa, violations, path, contents);
            }
        }
    }

    // The em-dash overuse rows apply to prose wherever it lives, including the
    // Zig doc comments the doc-voice audience table counts as human surfaces.
    for (em_dash_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try banHabitualEmDash(gpa, violations, path, contents);
        }
    }
    for (try humanPages(io, arena, root)) |path| {
        // tolerant: a read failure already reports through the ban rows.
        const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
        try banHabitualEmDash(gpa, violations, path, contents);
    }

    for (reader_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try reader_voice.banReaderFlaws(gpa, violations, path, contents, .{ .insiders = true });
        }
    }

    layouts: {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, .{ .tree = .{ .dir = "site/layouts", .suffixes = &.{".shtml"} } }, &files) catch break :layouts;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try reader_voice.banLayoutFlaws(gpa, violations, path, contents);
        }
    }

    cli: {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, .{ .tree = .{ .dir = "cli", .suffixes = &.{".zig"} } }, &files) catch break :cli;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try reader_voice.banCliStringFlaws(gpa, violations, path, contents);
        }
    }

    for (contributor_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try reader_voice.banReaderFlaws(gpa, violations, path, contents, .{
                .insiders = kinds.classify(path, contents).audience == .human,
                .labels = !std.mem.startsWith(u8, path, "docs/decisions/"),
            });
        }
    }

    // The justification tic runs its own, wider walk over every first-party
    // prose tree. `apps/` files still carrying it ride the closed debt list
    // in `voice_debt.zig` until each is rewritten.
    for (justification_tic_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try banHabitualJustification(gpa, violations, path, contents);
        }
    }
    for (voice_debt.justification_tic) |debt| {
        // A deleted or moved file leaves the walk above, so its row is
        // checked directly.
        root.access(io, debt, .{}) catch {
            try appendViolation(
                gpa,
                violations,
                "{s}: no longer exists — retire its row from source_check/docs/voice_debt.zig",
                .{debt},
            );
        };
    }
}

/// Human pages outside the contributor trees. The rest are found by their
/// audience (`kinds.zig`) as `humanPages` walks those trees.
const reader_scopes = [_]bans.Where{
    .{ .tree = .{ .dir = "site/content", .suffixes = &.{".smd"} } },
    .{ .files = &kinds.human_roots },
};

/// The human pages inside the contributor trees.
fn humanPages(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (contributor_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            if (kinds.classify(path, contents).audience == .human) try found.append(arena, path);
        }
    }
    return found.items;
}

/// Markdown written for people building glowcap: design records, plans,
/// guides, and the READMEs beside the code. It keeps the reader pages'
/// punctuation rule but not their word list, because the working words
/// belong here. Vendored upstream checkouts are not ours.
const contributor_scopes = [_]bans.Where{
    .{ .file = "CONTRIBUTING.md" },
    .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "apps", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "bench", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "bindings", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "conformance", .suffixes = &.{".md"}, .skip_dirs = &.{"upstream"} } },
    .{ .tree = .{ .dir = "examples", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "interop", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "site", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "test", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "tools", .suffixes = &.{".md"} } },
    .{ .tree = .{ .dir = "ui", .suffixes = &.{".md"} } },
    .{ .file = ".devcontainer/README.md" },
};

/// First-party prose, wider than the reader pages above, because the habits
/// these checks refuse show up most in source comments. Read by the
/// sentence-length ceiling, and by the em-dash scopes that extend it.
const prose_scopes = reader_scopes ++ [_]bans.Where{
    .{ .files = &.{ "CONTRIBUTING.md", "ui/README.md" } },
    .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "cli", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } },
    .{ .tree = .{ .dir = "conformance/ocapn-findings", .suffixes = &.{".md"} } },
};

/// Where the em-dash overuse check runs: the prose scopes above, and the
/// scaffolding.
///
/// The scaffolding is held to this line for a reason that does not apply to the
/// trees above. An agent writing Rooms' copy has just finished reading these
/// files, and prose it finds here is prose it reads as house style, so a habit
/// indulged in a rule is a habit handed to every surface that rule governs,
/// including the reader-facing ones where the same dash is an AI tell. The
/// build holds this line instead of whoever last noticed.
///
/// Its own list rather than the prose one, because that list feeds the
/// sentence-length check too, and widening it for this would have quietly
/// widened that. One list meaning two things is how a narrow edit gets a wide
/// blast radius.
const em_dash_scopes = prose_scopes ++ [_]bans.Where{
    .{ .tree = .{ .dir = ".agents", .suffixes = &.{ ".md", ".sh" } } },
    .{ .files = &.{"AGENTS.md"} },
    // The Rooms Rust crates carry the largest body of first-party comment
    // prose outside `src/`; their doc comments are human surfaces too.
    .{ .tree = .{ .dir = "apps/rooms/rust", .suffixes = &.{".rs"}, .skip_dirs = &.{"target/"} } },
};

/// The em-dash is a strong occasional tool, and doc-voice allows exactly two
/// uses: a matched pair standing in for parentheses, and a single dash for a
/// turn a comma cannot carry. It bans the rest by name, and these two spellings
/// are the ones a writer reaches for out of habit, a relative clause or a
/// continuation that a comma or a period carries just as well. They are checked
/// rather than merely written down because habit is what a rule sentence is
/// worst at stopping.
fn banHabitualEmDash(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    // The rule that names the forms has to write them down, so it is the one
    // file allowed to. Exempt by name rather than by trying to tell a citation
    // from a use: doc-voice quotes them both ways, inside backticks and inside
    // a quoted example sentence, and a check that guessed at the difference
    // would be a worse thing to trust than a list of one.
    if (std.mem.eql(u8, path, ".agents/rules/doc-voice.md")) return;
    const habits = [_][]const u8{ "— which", "— and then" };
    for (habits) |needle| {
        if (std.mem.indexOf(u8, contents, needle) != null) {
            try appendViolation(
                gpa,
                violations,
                "{s}: `{s}` is em-dash overuse (doc-voice) — a comma, a period, or parentheses carry it",
                .{ path, needle },
            );
            return;
        }
    }
}

/// Where the justification-tic check runs: every first-party prose tree,
/// wider than the em-dash scopes because the tic was measured across all of
/// them. Vendored and generated stores are pruned by directory.
const justification_tic_scopes = [_]bans.Where{
    .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "cli", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "tools", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "test", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "examples", .suffixes = &.{ ".zig", ".c", ".md" } } },
    .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } },
    .{ .tree = .{ .dir = "site/content", .suffixes = &.{".smd"} } },
    .{ .tree = .{ .dir = "include", .suffixes = &.{".h"} } },
    .{ .tree = .{ .dir = "bindings", .suffixes = &.{ ".rs", ".ts", ".tsx", ".py", ".rkt" }, .skip_dirs = &.{ "node_modules", "target/" } } },
    .{ .tree = .{ .dir = "conformance/goblins-peer/racket", .suffixes = &.{".rkt"} } },
    .{ .tree = .{ .dir = "conformance/ocapn-conformance", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "interop", .suffixes = &.{ ".zig", ".rs", ".ts", ".py", ".rkt" } } },
    .{ .tree = .{ .dir = "apps", .suffixes = &.{ ".zig", ".rs", ".ts", ".tsx", ".css", ".md", ".py", ".rkt" }, .skip_dirs = &.{ "node_modules", "target/" } } },
};

/// The which-is-what justification tic is one authorial habit repeated
/// across every language's comments, and each instance rewrites to a plainer
/// joint: a comma apposition, `so`, or a second sentence. `apps/` files
/// still carrying it are listed in `voice_debt.zig`, a closed list a file
/// leaves by being rewritten, so the tic thins as files are touched instead
/// of surviving by habit.
fn banHabitualJustification(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    // Split so this file passes its own walk.
    const needle = "which is" ++ " what";
    const listed = for (voice_debt.justification_tic) |debt| {
        if (std.mem.eql(u8, path, debt)) break true;
    } else false;
    const present = std.mem.indexOf(u8, contents, needle) != null;
    if (present and !listed) {
        try appendViolation(
            gpa,
            violations,
            "{s}: `{s}` is a justification tic (doc-voice) — rewrite as a comma apposition, `so`, or a second sentence",
            .{ path, needle },
        );
    } else if (listed and !present) {
        try appendViolation(
            gpa,
            violations,
            "{s}: its `{s}` instances are gone — retire its row from source_check/docs/voice_debt.zig",
            .{ path, needle },
        );
    }
}

/// Arrow connective tissue in running prose (`miss→break`, `N→1`) is a doc-voice
/// tell. Fenced code and ASCII `->` diagrams may keep arrows, Unicode `→`/`⇒`
/// stay inside fences on human first-read paths.
fn banConnectiveArrowOutsideFences(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var in_fence = false;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= contents.len) : (i += 1) {
        const at_end = i == contents.len;
        const at_nl = !at_end and contents[i] == '\n';
        if (!at_end and !at_nl) continue;
        const line = contents[line_start..i];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
        } else if (!in_fence) {
            if (std.mem.indexOf(u8, line, "→") != null or std.mem.indexOf(u8, line, "⇒") != null) {
                try appendViolation(gpa, violations, "{s}: connective arrow in prose — write a verb (`becomes`, `then`, `to`) instead of `→`/`⇒` (doc-voice)", .{path});
                return;
            }
        }
        line_start = i + 1;
    }
}

/// A heading that spends contrast before the subject has a name (`The relay is
/// a pipe, not a peer name`) is habit, not the tool. Name the subject.
/// Load-bearing distinctions belong in the paragraph.
fn banNegationHeadings(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    const needles = [_][]const u8{
        " is not a ",
        " is not the ",
        ", not a ",
        ", not the ",
        " starts no ",
    };
    var in_fence = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const fence_line = blk: {
            var rest = trimmed;
            while (std.mem.startsWith(u8, rest, ">")) {
                rest = std.mem.trimStart(u8, rest[1..], " \t");
            }
            break :blk std.mem.startsWith(u8, rest, "```");
        };
        if (fence_line) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        const heading = headingSubject(trimmed) orelse continue;
        for (needles) |needle| {
            if (std.mem.indexOf(u8, heading, needle) != null) {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}:{d}: heading defines the subject by what it is not (`{s}`); name the subject (doc-voice)",
                    .{ path, line_no, heading },
                );
                return;
            }
        }
    }
}

fn headingSubject(trimmed: []const u8) ?[]const u8 {
    var rest = trimmed;
    while (std.mem.startsWith(u8, rest, ">")) {
        rest = std.mem.trimStart(u8, rest[1..], " \t");
    }
    const title_prefix = ".title = \"";
    if (std.mem.startsWith(u8, rest, title_prefix)) {
        const inner = rest[title_prefix.len..];
        const close = std.mem.indexOfScalar(u8, inner, '"') orelse return inner;
        return inner[0..close];
    }
    var i: usize = 0;
    while (i < rest.len and rest[i] == '#') i += 1;
    if (i == 0 or i >= rest.len or rest[i] != ' ') return null;
    return std.mem.trim(u8, rest[i + 1 ..], " \t\r");
}

/// The longest a sentence may run on a page written for people.
///
/// The median sentence on these pages is under a hundred characters, so this is
/// not a style preference dressed as a rule: it is the point past which a
/// sentence has stopped being one. Every sentence over it that we looked at was
/// three or four ideas joined by semicolons, usually with a stack of identifiers
/// and a decision-record number wedged in. doc-voice already asks for one idea
/// per sentence. This is the part of that a build can hold.
const max_prose_sentence = 250;

pub fn checkProseSentenceLength(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (prose_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            if (!std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".smd")) continue;
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try checkSentencesIn(gpa, violations, path, contents);
        }
    }
    for (try humanPages(io, arena, root)) |path| {
        // tolerant: a read failure already reports through the ban rows.
        const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
        try checkSentencesIn(gpa, violations, path, contents);
    }
}

/// Every doc a person or agent reads, held to the paragraph ceiling. Decision
/// records stay the memos they were written as.
const paragraph_scopes = reader_scopes ++ contributor_scopes ++ [_]bans.Where{
    .{ .tree = .{ .dir = ".agents", .suffixes = &.{".md"} } },
    .{ .files = &.{"AGENTS.md"} },
};

pub fn checkParagraphLength(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (paragraph_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // tolerant: an unopenable tree already violates through the ban rows.
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            if (std.mem.startsWith(u8, path, "docs/decisions/")) continue;
            // tolerant: a read failure already reports through the ban rows.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            if (std.mem.indexOf(u8, contents[0..@min(contents.len, 400)], "GENERATED") != null) continue;
            try paragraphs.checkIn(gpa, violations, path, contents);
        }
    }
}

fn isListItem(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) return true;
    // An ordered item: digits then `.` or `)` then a space.
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i == 0 or i + 1 >= trimmed.len) return false;
    return (trimmed[i] == '.' or trimmed[i] == ')') and trimmed[i + 1] == ' ';
}

fn checkSentencesIn(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var in_fence = false;
    var line_no: usize = 0;
    var run: usize = 0;
    var run_line: usize = 1;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // SuperMD `code-tabs` nest fences inside blockquotes (`> ```lang`), so a
        // leading `>` must not hide the fence from this scanner, otherwise the
        // tab bodies are read as one enormous prose sentence.
        const fence_line = blk: {
            var rest = trimmed;
            while (std.mem.startsWith(u8, rest, ">")) {
                rest = std.mem.trimStart(u8, rest[1..], " \t");
            }
            break :blk std.mem.startsWith(u8, rest, "```");
        };
        if (fence_line) {
            in_fence = !in_fence;
            run = 0;
            continue;
        }
        // Not prose: fenced code, headings, and blank lines.
        if (in_fence or trimmed.len == 0 or trimmed[0] == '#') {
            run = 0;
            continue;
        }
        // A table row is prose when its cells are sentences. Exempting every
        // row put the densest paragraphs in the tree, the evidence matrix a
        // reviewer opens first: outside the only gate that reads for
        // readability. A row of short labels carries no sentence punctuation
        // and so cannot trip the bar anyway; a row whose cells argue in
        // sentences is exactly what the bar is for. Each cell is measured on
        // its own, because the pipes between them are column boundaries rather
        // than anything a reader speaks.
        if (trimmed[0] == '|') {
            if (std.mem.startsWith(u8, trimmed, "| ---")) {
                run = 0;
                continue;
            }
            var cells = std.mem.splitScalar(u8, trimmed, '|');
            while (cells.next()) |cell| {
                var cell_run: usize = 0;
                for (std.mem.trim(u8, cell, " \t\r")) |c| {
                    cell_run += 1;
                    switch (c) {
                        '.', '!', '?' => {
                            if (cell_run > max_prose_sentence) {
                                try appendViolation(gpa, violations, "{s}:{d}: a {d}-character sentence in a table cell; doc-voice asks for one idea per sentence, and a cell is not exempt from it. Split it.", .{ path, line_no, cell_run });
                            }
                            cell_run = 0;
                        },
                        else => {},
                    }
                }
                if (cell_run > max_prose_sentence) {
                    try appendViolation(gpa, violations, "{s}:{d}: a {d}-character table cell with no sentence break at all; doc-voice asks for one idea per sentence. Split it.", .{ path, line_no, cell_run });
                }
            }
            run = 0;
            continue;
        }
        // A list item is a new thought, so it starts a new sentence. Without
        // this a bulleted list of identifiers, which carries no sentence
        // punctuation at all, reads as one enormous run-on.
        if (isListItem(trimmed)) {
            run = 0;
            run_line = line_no;
        }
        if (run == 0) run_line = line_no;

        for (trimmed) |c| {
            run += 1;
            switch (c) {
                '.', '!', '?' => {
                    if (run > max_prose_sentence) {
                        try appendViolation(gpa, violations, "{s}:{d}: a {d}-character sentence; doc-voice asks for one idea per sentence, and this is several. Split it.", .{ path, run_line, run });
                    }
                    run = 0;
                    run_line = line_no;
                },
                else => {},
            }
        }
        run += 1; // the newline joining wrapped prose lines
    }
}
