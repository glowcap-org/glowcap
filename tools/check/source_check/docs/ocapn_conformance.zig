//! `docs/ocapn-conformance.md` lists, per OCapN CapTP draft section, the wire
//! adoption state and the evidence or decision that owns it. The draft has
//! no tagged releases, so the submodule pin is the reference. Each row carries
//! a fingerprint of its section's text at the pin, which lets a pin bump fail
//! exactly the rows whose text moved and name them for re-review. The check
//! also holds the table complete in both directions and holds every evidence
//! step against `docs/build-steps.md`, and fingerprints upstream suite setup
//! alongside test modules so a shared hello change always forces review.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

const manifest_path = "docs/ocapn-conformance.md";
const draft_path = "conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md";
const steps_path = "docs/build-steps.md";
const header = "| Section | Profile | State | Evidence | Decision | Text |";
const suite_header = "| Suite source | Profile | State | Evidence | Decision | Text |";
const suite_root = "conformance/ocapn-conformance/upstream";
const step_prefix = "zig build ";
const fingerprint_len = 12;

/// Non-protocol framing is excluded explicitly. Every other top-level section,
/// including any section upstream adds, and its second-level sections need rows.
const framing = [_][]const u8{
    "Warning: This is a draft specification likely to undergo significant change",
    "Introduction",
    "Additional Documents",
    "History of OCapN",
    "Funding",
};
const profiles = [_][]const u8{ "1.0", "next", "both" };

/// CommonMark fenced examples may contain heading and table syntax. Keep
/// their bytes in fingerprints without treating those examples as structure.
const Fence = struct {
    marker: u8 = 0,
    width: usize = 0,

    fn consumes(self: *Fence, line: []const u8) bool {
        const content = headingLine(line);
        var count: usize = 0;
        if (content.len != 0 and (content[0] == '`' or content[0] == '~')) {
            while (count < content.len and content[count] == content[0]) : (count += 1) {}
        }
        if (self.width != 0) {
            if (count >= self.width and content[0] == self.marker and std.mem.trim(u8, content[count..], " \t\r\n").len == 0) {
                self.width = 0;
            }
            return true;
        }
        if (count < 3) return false;
        if (content[0] == '`' and std.mem.indexOfScalar(u8, content[count..], '`') != null) return false;
        self.marker = content[0];
        self.width = count;
        return true;
    }
};

/// ATX headings and fences may be indented by up to three spaces.
fn headingLine(line: []const u8) []const u8 {
    var start: usize = 0;
    while (start < line.len and start < 3 and line[start] == ' ') : (start += 1) {}
    return line[start..];
}

const Section = struct {
    name: []const u8,
    fingerprint: [fingerprint_len]u8,
};

const Row = struct {
    name: []const u8,
    profile: []const u8,
    state: []const u8,
    evidence: []const u8,
    decision: []const u8,
    fingerprint: []const u8,
};

pub fn checkManifest(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = root.readFileAlloc(io, manifest_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "ocapn conformance: failed to read {s} with {s}", .{ manifest_path, @errorName(err) });
        return;
    };
    const draft = root.readFileAlloc(io, draft_path, arena, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            try appendViolation(gpa, violations, "ocapn conformance: the OCapN spec submodule is not checked out, so {s} cannot be held to {s}", .{ manifest_path, draft_path });
            return;
        },
        else => {
            try appendViolation(gpa, violations, "ocapn conformance: failed to read {s} with {s}", .{ draft_path, @errorName(err) });
            return;
        },
    };
    const steps = root.readFileAlloc(io, steps_path, arena, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "ocapn conformance: failed to read {s} with {s}", .{ steps_path, @errorName(err) });
        return;
    };

    const rows = try parseRows(arena, gpa, violations, manifest, header);
    const sections = try scanDraft(arena, draft);

    for (sections) |section| {
        if (findRow(rows, section.name) == null) {
            try appendViolation(gpa, violations, "ocapn conformance: the draft has `{s}` and the manifest has no row", .{section.name});
        }
    }
    for (rows, 0..) |row, index| {
        if (duplicateOf(rows, index)) {
            try appendViolation(gpa, violations, "ocapn conformance: manifest row `{s}` appears more than once", .{row.name});
            continue;
        }
        try checkDisposition(io, gpa, root, violations, row);
        if (std.mem.eql(u8, row.fingerprint, "removed")) {
            if (findSection(sections, row.name) != null) {
                try appendViolation(gpa, violations, "ocapn conformance: `{s}` is marked removed but exists in the draft", .{row.name});
            }
            try checkEvidence(io, gpa, root, violations, row, steps);
            continue;
        }
        const section = findSection(sections, row.name) orelse {
            try appendViolation(gpa, violations, "ocapn conformance: manifest row `{s}` names no draft section", .{row.name});
            continue;
        };
        if (!std.mem.eql(u8, row.fingerprint, &section.fingerprint)) {
            try appendViolation(gpa, violations, "ocapn conformance: `{s}` text moved: manifest {s}, draft {s}, re-read the section and update the row", .{ row.name, row.fingerprint, section.fingerprint });
        }
        try checkEvidence(io, gpa, root, violations, row, steps);
    }
    try checkSuite(io, arena, gpa, root, violations, manifest, steps);
}

/// A pending item lacks implementation or proof. A deferral is a deliberate
/// boundary. Neither may borrow passing baseline checks as adoption evidence.
fn checkDisposition(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    row: Row,
) !void {
    if (std.mem.eql(u8, row.state, "adopted")) {
        if (std.mem.indexOf(u8, row.evidence, "`zig build ") == null) {
            try appendViolation(gpa, violations, "ocapn conformance: adopted `{s}` needs executable evidence", .{row.name});
        }
        if (!std.mem.eql(u8, row.decision, "none")) {
            try appendViolation(gpa, violations, "ocapn conformance: adopted `{s}` must retire its follow-up decision", .{row.name});
        }
        return;
    }
    if (!std.mem.eql(u8, row.state, "deferred") and !std.mem.eql(u8, row.state, "pending")) {
        try appendViolation(gpa, violations, "ocapn conformance: `{s}` state `{s}` must be adopted, deferred, or pending", .{ row.name, row.state });
        return;
    }
    if (!std.mem.eql(u8, row.evidence, "none")) {
        try appendViolation(gpa, violations, "ocapn conformance: {s} `{s}` cannot claim adoption evidence", .{ row.state, row.name });
    }
    const decision = row.decision;
    if (decision.len < 3 or decision[0] != '`' or decision[decision.len - 1] != '`') {
        try appendViolation(gpa, violations, "ocapn conformance: {s} `{s}` needs a repository decision path in a code span", .{ row.state, row.name });
        return;
    }
    const path = decision[1 .. decision.len - 1];
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOf(u8, path, "..") != null or !std.mem.endsWith(u8, path, ".md")) {
        try appendViolation(gpa, violations, "ocapn conformance: `{s}` decision must name a repository Markdown file", .{row.name});
        return;
    }
    root.access(io, path, .{}) catch {
        try appendViolation(gpa, violations, "ocapn conformance: `{s}` decision `{s}` does not exist", .{ row.name, path });
    };
}

/// Test modules and their shared Python setup/types move independently of the
/// spec. Review every Python source, including initializers and transport setup,
/// so excluding a hello module cannot conceal a changed common opening grammar.
fn checkSuite(
    io: std.Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    manifest: []const u8,
    steps: []const u8,
) !void {
    const rows = try parseRows(arena, gpa, violations, manifest, suite_header);
    var dir = root.openDir(io, suite_root, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "ocapn conformance: failed to open suite with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".py")) continue;
        count += 1;
        const bytes = try dir.readFileAlloc(io, entry.path, arena, .limited(4 << 20));
        const actual = fingerprint(bytes);
        for ([_][]const u8{ "1.0", "next" }) |profile| {
            const row = suiteRow(rows, entry.path, profile) orelse {
                try appendViolation(gpa, violations, "ocapn conformance: suite source `{s}` has no reviewed row for {s}", .{ entry.path, profile });
                continue;
            };
            if (!std.mem.eql(u8, row.fingerprint, &actual)) {
                try appendViolation(gpa, violations, "ocapn conformance: suite source `{s}` ({s}) text moved: manifest {s}, suite {s}, review setup and assertions", .{ entry.path, profile, row.fingerprint, actual });
            }
        }
    }
    if (count == 0) try appendViolation(gpa, violations, "ocapn conformance: suite Python inventory is empty", .{});
    for (rows, 0..) |row, index| {
        for (rows[0..index]) |earlier| {
            if (std.mem.eql(u8, row.name, earlier.name) and
                (std.mem.eql(u8, row.profile, earlier.profile) or std.mem.eql(u8, row.profile, "both") or std.mem.eql(u8, earlier.profile, "both")))
                try appendViolation(gpa, violations, "ocapn conformance: suite row `{s}` appears more than once for {s}", .{ row.name, row.profile });
        }
        if (!std.mem.endsWith(u8, row.name, ".py") or std.fs.path.isAbsolute(row.name) or std.mem.indexOf(u8, row.name, "..") != null) {
            try appendViolation(gpa, violations, "ocapn conformance: invalid suite path `{s}`", .{row.name});
            continue;
        }
        dir.access(io, row.name, .{}) catch {
            try appendViolation(gpa, violations, "ocapn conformance: suite row `{s}` names no source", .{row.name});
        };
        try checkDisposition(io, gpa, root, violations, row);
        try checkEvidence(io, gpa, root, violations, row, steps);
    }
}

pub const SuitePlanEntry = struct { name: []const u8, state: []const u8, decision: []const u8 };

/// Execution consumes the same reviewed rows as the accounting gate. The
/// caller validates the manifest first. Returned strings belong to `arena`.
pub fn nextSuitePlan(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir) ![]const SuitePlanEntry {
    const manifest = try root.readFileAlloc(io, manifest_path, arena, .limited(1 << 20));
    var violations: std.ArrayList([]const u8) = .empty;
    const rows = try parseRows(arena, arena, &violations, manifest, suite_header);
    if (violations.items.len != 0) return error.InvalidManifest;
    var entries: std.ArrayList(SuitePlanEntry) = .empty;
    for (rows) |row| {
        if (std.mem.eql(u8, row.profile, "1.0")) continue;
        try entries.append(arena, .{ .name = row.name, .state = row.state, .decision = row.decision });
    }
    return entries.items;
}

fn suiteRow(rows: []const Row, name: []const u8, profile: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.name, name) and (std.mem.eql(u8, row.profile, profile) or std.mem.eql(u8, row.profile, "both"))) return row;
    }
    return null;
}

fn findRow(rows: []const Row, name: []const u8) ?Row {
    for (rows) |row| if (std.mem.eql(u8, row.name, name)) return row;
    return null;
}

fn findSection(sections: []const Section, name: []const u8) ?*const Section {
    for (sections) |*section| if (std.mem.eql(u8, section.name, name)) return section;
    return null;
}

fn duplicateOf(rows: []const Row, index: usize) bool {
    for (rows[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, rows[index].name)) return true;
    return false;
}

/// Reads the single table that starts at `table_header`. Malformed rows are
/// reported and skipped.
fn parseRows(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    manifest: []const u8,
    table_header: []const u8,
) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    var in_table = false;
    var seen_header = false;
    var fence: Fence = .{};
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, headingLine(raw), " \t\r");
        if (fence.consumes(raw)) {
            if (in_table) break;
            continue;
        }
        if (!in_table) {
            if (!std.mem.eql(u8, line, table_header)) continue;
            in_table = true;
            seen_header = true;
            _ = lines.next(); // the separator line
            continue;
        }
        if (!std.mem.startsWith(u8, line, "|")) break;
        const row = parseRow(arena, line) orelse {
            try appendViolation(gpa, violations, "ocapn conformance: malformed manifest row `{s}`, expected six cells", .{line});
            continue;
        };
        if (!oneOf(&profiles, row.profile)) {
            try appendViolation(gpa, violations, "ocapn conformance: row `{s}` has profile `{s}`, expected 1.0, next, or both", .{ row.name, row.profile });
        }
        if (!isFingerprint(row.fingerprint) and !std.mem.eql(u8, row.fingerprint, "removed")) {
            try appendViolation(gpa, violations, "ocapn conformance: row `{s}` fingerprint `{s}` is not {d} lowercase hex characters", .{ row.name, row.fingerprint, fingerprint_len });
        }
        try rows.append(arena, row);
    }
    if (!seen_header) {
        try appendViolation(gpa, violations, "ocapn conformance: {s} has no table with the header `{s}`", .{ manifest_path, table_header });
    }
    return rows.items;
}

fn parseRow(arena: std.mem.Allocator, line: []const u8) ?Row {
    const inner = std.mem.trim(u8, line, "|");
    var cells = std.mem.splitScalar(u8, inner, '|');
    var parsed: [6][]const u8 = undefined;
    for (&parsed) |*cell| cell.* = std.mem.trim(u8, cells.next() orelse return null, " ");
    if (cells.next() != null) return null;
    const name = stripMarkup(arena, parsed[0]) catch return null;
    if (name.len == 0) return null;
    return .{ .name = name, .profile = parsed[1], .state = parsed[2], .evidence = parsed[3], .decision = parsed[4], .fingerprint = parsed[5] };
}

fn oneOf(set: []const []const u8, value: []const u8) bool {
    for (set) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn isFingerprint(text: []const u8) bool {
    if (text.len != fingerprint_len) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// Evidence is `none`, or comma-separated code spans that are either a
/// `zig build <step>` listed in `docs/build-steps.md` or an existing path.
fn checkEvidence(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    row: Row,
    steps: []const u8,
) !void {
    if (std.mem.eql(u8, row.evidence, "none")) return;
    var tokens = std.mem.splitScalar(u8, row.evidence, ',');
    while (tokens.next()) |raw| {
        const token = std.mem.trim(u8, raw, " ");
        if (token.len < 3 or token[0] != '`' or token[token.len - 1] != '`') {
            try appendViolation(gpa, violations, "ocapn conformance: `{s}` evidence `{s}` is neither `none` nor a code span", .{ row.name, token });
            continue;
        }
        const code = token[1 .. token.len - 1];
        if (std.mem.startsWith(u8, code, step_prefix)) {
            if (!listsStep(steps, code[step_prefix.len..])) {
                try appendViolation(gpa, violations, "ocapn conformance: `{s}` evidence names a step docs/build-steps.md does not list: {s}", .{ row.name, code });
            }
        } else if (std.fs.path.isAbsolute(code) or std.mem.indexOf(u8, code, "..") != null) {
            try appendViolation(gpa, violations, "ocapn conformance: `{s}` evidence path `{s}` must be inside the repository", .{ row.name, code });
        } else {
            root.access(io, code, .{}) catch {
                try appendViolation(gpa, violations, "ocapn conformance: `{s}` evidence path `{s}` does not exist", .{ row.name, code });
            };
        }
    }
}

/// Whether `zig build <step>` appears in the build-steps page as a whole word.
fn listsStep(steps: []const u8, step: []const u8) bool {
    if (step.len == 0) return false;
    var rest = steps;
    while (std.mem.indexOf(u8, rest, step_prefix)) |at| {
        const after = rest[at + step_prefix.len ..];
        if (std.mem.startsWith(u8, after, step)) {
            const tail = after[step.len..];
            if (tail.len == 0 or std.ascii.isWhitespace(tail[0]) or tail[0] == '`') return true;
        }
        rest = after;
    }
    return false;
}

/// Display text of a heading or section cell: the `[text](#anchor)` link
/// wrapper, backticks, and a trailing ` Method` are removed.
fn stripMarkup(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var text = std.mem.trim(u8, raw, " ");
    if (text.len > 0 and text[0] == '[') {
        if (std.mem.lastIndexOf(u8, text, "](#")) |close| {
            if (text[text.len - 1] == ')') text = text[1..close];
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| if (c != '`') try out.append(arena, c);
    var result: []const u8 = out.items;
    if (std.mem.endsWith(u8, result, " Method")) result = result[0 .. result.len - " Method".len];
    return result;
}

/// First twelve lowercase hex characters of the SHA-256 of `body` without its
/// trailing newlines.
fn fingerprint(body: []const u8) [fingerprint_len]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(std.mem.trimEnd(u8, body, "\n"), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..fingerprint_len].*;
}

/// Protocol prose and examples at both heading levels are normative review
/// inputs. A section ends at the next first- or second-level heading.
fn scanDraft(arena: std.mem.Allocator, draft: []const u8) ![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    var in_scope = false;
    var fence: Fence = .{};
    var open: ?struct { name: []const u8, start: usize } = null;
    var offset: usize = 0;
    while (offset < draft.len) {
        const end = if (std.mem.indexOfScalarPos(u8, draft, offset, '\n')) |nl| nl + 1 else draft.len;
        const raw = draft[offset..end];
        if (fence.consumes(raw)) {
            offset = end;
            continue;
        }
        const line = headingLine(raw);
        const first = std.mem.startsWith(u8, line, "# ");
        const second = std.mem.startsWith(u8, line, "## ");
        if (first or second) {
            if (open) |section| {
                try sections.append(arena, .{ .name = section.name, .fingerprint = fingerprint(draft[section.start..offset]) });
                open = null;
            }
            const text = try stripMarkup(arena, std.mem.trim(u8, line[if (first) 2 else 3..], "\r\n"));
            if (first) {
                in_scope = !oneOf(&framing, text);
            }
            if (in_scope) open = .{ .name = text, .start = offset };
        }
        offset = end;
    }
    if (open) |section| {
        try sections.append(arena, .{ .name = section.name, .fingerprint = fingerprint(draft[section.start..]) });
    }
    return sections.items;
}

test "stripMarkup removes the link wrapper, backticks, and Method suffix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("op:deliver", try stripMarkup(arena, "[`op:deliver`](#opdeliver)"));
    try std.testing.expectEqualStrings("Public Key", try stripMarkup(arena, "[Public Key](#public-key)"));
    try std.testing.expectEqualStrings("fetch", try stripMarkup(arena, "`fetch` Method"));
    try std.testing.expectEqualStrings("Operations", try stripMarkup(arena, "Operations"));
}

test "fingerprint hashes the section without trailing newlines" {
    // SHA-256 of "abc" begins ba7816bf8f01.
    try std.testing.expectEqualStrings("ba7816bf8f01", &fingerprint("abc"));
    try std.testing.expectEqualStrings("ba7816bf8f01", &fingerprint("abc\n\n"));
}

test "scanDraft bounds a section at the next first- or second-level heading" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const draft = "# Introduction\n## Skipped\n# Operations\n## [`op:a`](#opa)\nabc\n### Sub\nx\n\n## `b` Method\nabc\n# Additional Documents\n## Out\n";
    const sections = try scanDraft(arena_state.allocator(), draft);
    try std.testing.expectEqual(@as(usize, 3), sections.len);
    try std.testing.expectEqualStrings("Operations", sections[0].name);
    try std.testing.expectEqualStrings("op:a", sections[1].name);
    try std.testing.expectEqualStrings("b", sections[2].name);
    try std.testing.expectEqualStrings(&fingerprint("## [`op:a`](#opa)\nabc\n### Sub\nx\n"), &sections[1].fingerprint);
}

test "listsStep matches whole step names" {
    const steps = "zig build oracle-check   # corpus\nzig build goblins-gc\n";
    try std.testing.expect(listsStep(steps, "oracle-check"));
    try std.testing.expect(listsStep(steps, "goblins-gc"));
    try std.testing.expect(!listsStep(steps, "oracle"));
    try std.testing.expect(!listsStep(steps, "goblins-gc-extra"));
}

test "scanDraft ignores fenced example headings without losing their bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const examples = [_][]const u8{
        "```text\n# Funding\n## example heading\n```\n",
        "~~~text\n# Funding\n## example heading\n~~~\n",
        "~~~text\n```\n# Funding\n~~~\n",
        "````text\n```\n# Funding\n## example heading\n````\n",
        "   ```text\n# Funding\n## example heading\n   ```\n",
        "````text\n```\n~~~\n# Funding\n````\n",
        "```text\n```not-a-closer\n# Funding\n```\n",
    };
    for (examples) |example| {
        const body = try std.mem.concat(arena_state.allocator(), u8, &.{ "## op:deliver\n", example, "Requirement after example.\n" });
        const draft = try std.mem.concat(arena_state.allocator(), u8, &.{ "# Operations\n", body, "## op:abort\nClose.\n" });
        const sections = try scanDraft(arena_state.allocator(), draft);
        try std.testing.expectEqual(@as(usize, 3), sections.len);
        try std.testing.expectEqualStrings("op:deliver", sections[1].name);
        try std.testing.expectEqualStrings(&fingerprint(body), &sections[1].fingerprint);
        try std.testing.expectEqualStrings("op:abort", sections[2].name);
    }
    const indented = try scanDraft(arena_state.allocator(), "   # Operations\n  ## op:abort\nClose.\n");
    try std.testing.expectEqual(@as(usize, 2), indented.len);
    try std.testing.expectEqualStrings("op:abort", indented[1].name);
}
