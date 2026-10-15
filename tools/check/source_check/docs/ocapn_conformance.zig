//! `docs/ocapn-conformance.md` lists, per OCapN CapTP draft section, the wire
//! profile that implements it and the evidence that proves it. The draft has
//! no tagged releases, so the submodule pin is the reference. Each row carries
//! a fingerprint of its section's text at the pin, which lets a pin bump fail
//! exactly the rows whose text moved and name them for re-review. The check
//! also holds the table complete in both directions and holds every evidence
//! step against `docs/build-steps.md`.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

const manifest_path = "docs/ocapn-conformance.md";
const draft_path = "conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md";
const steps_path = "docs/build-steps.md";
const header = "| Section | Profile | Evidence | Text |";
const step_prefix = "zig build ";
const fingerprint_len = 12;

/// The draft's top-level sections whose second-level headings need a row.
const scopes = [_][]const u8{ "Cryptography", "The bootstrap Object", "Operations", "Descriptors" };
const profiles = [_][]const u8{ "1.0", "next", "both", "none" };

const Section = struct {
    name: []const u8,
    fingerprint: [fingerprint_len]u8,
};

const Row = struct {
    name: []const u8,
    profile: []const u8,
    evidence: []const u8,
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

    const rows = try parseRows(arena, gpa, violations, manifest);
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
        const section = findSection(sections, row.name) orelse {
            try appendViolation(gpa, violations, "ocapn conformance: manifest row `{s}` names no draft section", .{row.name});
            continue;
        };
        if (!std.mem.eql(u8, row.fingerprint, &section.fingerprint)) {
            try appendViolation(gpa, violations, "ocapn conformance: `{s}` text moved: manifest {s}, draft {s}, re-read the section and update the row", .{ row.name, row.fingerprint, section.fingerprint });
        }
        try checkEvidence(io, gpa, root, violations, row, steps);
    }
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

/// Reads the single table that starts at `header`. Malformed rows are
/// reported and skipped.
fn parseRows(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    manifest: []const u8,
) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    var in_table = false;
    var seen_header = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!in_table) {
            if (!std.mem.eql(u8, line, header)) continue;
            in_table = true;
            seen_header = true;
            _ = lines.next(); // the separator line
            continue;
        }
        if (!std.mem.startsWith(u8, line, "|")) break;
        const row = parseRow(arena, line) orelse {
            try appendViolation(gpa, violations, "ocapn conformance: malformed manifest row `{s}`, expected four cells", .{line});
            continue;
        };
        if (!oneOf(&profiles, row.profile)) {
            try appendViolation(gpa, violations, "ocapn conformance: row `{s}` has profile `{s}`, expected 1.0, next, both, or none", .{ row.name, row.profile });
        }
        if (!isFingerprint(row.fingerprint)) {
            try appendViolation(gpa, violations, "ocapn conformance: row `{s}` fingerprint `{s}` is not {d} lowercase hex characters", .{ row.name, row.fingerprint, fingerprint_len });
        }
        try rows.append(arena, row);
    }
    if (!seen_header) {
        try appendViolation(gpa, violations, "ocapn conformance: {s} has no table with the header `{s}`", .{ manifest_path, header });
    }
    return rows.items;
}

fn parseRow(arena: std.mem.Allocator, line: []const u8) ?Row {
    const inner = std.mem.trim(u8, line, "|");
    var cells = std.mem.splitScalar(u8, inner, '|');
    var parsed: [4][]const u8 = undefined;
    for (&parsed) |*cell| cell.* = std.mem.trim(u8, cells.next() orelse return null, " ");
    if (cells.next() != null) return null;
    const name = stripMarkup(arena, parsed[0]) catch return null;
    if (name.len == 0) return null;
    return .{ .name = name, .profile = parsed[1], .evidence = parsed[2], .fingerprint = parsed[3] };
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

/// Every second-level heading under one of `scopes`, with the fingerprint of
/// the bytes from that heading to the next first- or second-level heading.
fn scanDraft(arena: std.mem.Allocator, draft: []const u8) ![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    var in_scope = false;
    var open: ?struct { name: []const u8, start: usize } = null;
    var offset: usize = 0;
    while (offset < draft.len) {
        const end = if (std.mem.indexOfScalarPos(u8, draft, offset, '\n')) |nl| nl + 1 else draft.len;
        const line = draft[offset..end];
        const first = std.mem.startsWith(u8, line, "# ");
        const second = std.mem.startsWith(u8, line, "## ");
        if (first or second) {
            if (open) |section| {
                try sections.append(arena, .{ .name = section.name, .fingerprint = fingerprint(draft[section.start..offset]) });
                open = null;
            }
            const text = try stripMarkup(arena, std.mem.trim(u8, line[if (first) 2 else 3..], "\r\n"));
            if (first) {
                in_scope = oneOf(&scopes, text);
            } else if (in_scope) {
                open = .{ .name = text, .start = offset };
            }
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
    const draft = "# Intro\n## Skipped\n# Operations\n## [`op:a`](#opa)\nabc\n### Sub\nx\n\n## `b` Method\nabc\n# Other\n## Out\n";
    const sections = try scanDraft(arena_state.allocator(), draft);
    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("op:a", sections[0].name);
    try std.testing.expectEqualStrings("b", sections[1].name);
    try std.testing.expectEqualStrings(&fingerprint("## [`op:a`](#opa)\nabc\n### Sub\nx\n"), &sections[0].fingerprint);
}

test "listsStep matches whole step names" {
    const steps = "zig build oracle-check   # corpus\nzig build goblins-gc\n";
    try std.testing.expect(listsStep(steps, "oracle-check"));
    try std.testing.expect(listsStep(steps, "goblins-gc"));
    try std.testing.expect(!listsStep(steps, "oracle"));
    try std.testing.expect(!listsStep(steps, "goblins-gc-extra"));
}
