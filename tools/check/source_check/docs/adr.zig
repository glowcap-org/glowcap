//! ADR hygiene: frontmatter shape, relation symmetry between supersedes and
//! amends pairs, and evidence links that still resolve.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

const AdrRecord = struct {
    id: []const u8,
    path: []const u8,
    body: []const u8,
};

/// The one spelling of an ADR's own standing. A record that states its status
/// in prose instead of frontmatter sits outside `checkAdrRelations` entirely,
/// because that walk skips a file with no `id`, so its links to other records
/// are held by nothing. Five records lived in that blind spot for weeks. This
/// check closes it: every record carries frontmatter, its `id` matches its
/// filename, its `status` is one of the three lifecycle values
/// `docs/decisions/README.md` defines, and a superseded record names its
/// replacement so the reciprocity walk can prove the replacement points back.
pub fn checkAdrFrontmatter(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "docs/decisions/adr";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for ADR frontmatter check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "ADR-")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const body = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for ADR frontmatter check with {s}", .{ dir_path, entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(body);

        const id = adrFrontmatterValue(body, "id") orelse {
            try appendViolation(gpa, violations, "{s}/{s}: needs YAML frontmatter with `id`, `status`, and `date`; a prose `**Status:**` header is invisible to the ADR relation graph", .{ dir_path, entry.path });
            continue;
        };
        // `ADR-0033-byte-transparent-relays.md` -> `ADR-0033`. A name with no
        // second dash carries no number to compare against, so that one clause
        // sits out while the status clauses below still run.
        if (std.mem.indexOfScalarPos(u8, entry.path, 4, '-')) |dash| {
            const expected_id = entry.path[0..dash];
            if (!std.mem.eql(u8, id, expected_id)) {
                try appendViolation(gpa, violations, "{s}/{s}: frontmatter `id: {s}` disagrees with the filename's `{s}`", .{ dir_path, entry.path, id, expected_id });
            }
        }
        if (adrFrontmatterValue(body, "date") == null) {
            try appendViolation(gpa, violations, "{s}/{s}: frontmatter needs a `date`", .{ dir_path, entry.path });
        }
        const status = adrFrontmatterValue(body, "status") orelse {
            try appendViolation(gpa, violations, "{s}/{s}: frontmatter needs a `status`", .{ dir_path, entry.path });
            continue;
        };
        const lifecycle = [_][]const u8{ "proposed", "accepted", "superseded" };
        var known = false;
        for (lifecycle) |value| {
            if (std.mem.eql(u8, status, value)) known = true;
        }
        if (!known) {
            try appendViolation(gpa, violations, "{s}/{s}: `status: {s}` is not one of proposed, accepted, or superseded", .{ dir_path, entry.path, status });
            continue;
        }
        if (!std.mem.eql(u8, status, "superseded")) continue;
        const raw = adrFrontmatterValue(body, "superseded_by") orelse "[]";
        const inner = adrListInner(raw) orelse "";
        if (std.mem.trim(u8, inner, " \t").len == 0) {
            try appendViolation(gpa, violations, "{s}/{s}: a superseded record must name its replacement in `superseded_by`", .{ dir_path, entry.path });
        }
    }
}

/// ADR replacement and amendment links are graph edges, not independent prose.
/// A one-sided edge makes the older record lie about whether its substance is
/// still living guidance, and vocabulary-only amendments get mislabeled as full
/// supersessions.
pub fn checkAdrRelations(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "docs/decisions/adr", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs/decisions/adr: failed to open for ADR relation check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var records: std.ArrayList(AdrRecord) = .empty;
    defer {
        for (records.items) |record| {
            gpa.free(record.id);
            gpa.free(record.path);
            gpa.free(record.body);
        }
        records.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.path, "ADR-")) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const body = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "docs/decisions/adr/{s}: failed to read for ADR relation check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        const id = adrFrontmatterValue(body, "id") orelse {
            // Older records without canonical frontmatter have no relation
            // edges. They remain readable history until touched; a relation
            // target must be migrated before it can participate in this graph.
            gpa.free(body);
            continue;
        };
        try records.append(gpa, .{
            .id = try gpa.dupe(u8, id),
            .path = try std.fmt.allocPrint(gpa, "docs/decisions/adr/{s}", .{entry.path}),
            .body = body,
        });
    }

    for (records.items, 0..) |record, i| {
        for (records.items[i + 1 ..]) |other| {
            if (std.mem.eql(u8, record.id, other.id)) {
                try appendViolation(gpa, violations, "{s}: ADR id `{s}` is duplicated by {s}", .{ record.path, record.id, other.path });
            }
        }
    }

    const relations = [_]struct { field: []const u8, reciprocal: []const u8 }{
        .{ .field = "supersedes", .reciprocal = "superseded_by" },
        .{ .field = "superseded_by", .reciprocal = "supersedes" },
        .{ .field = "amends", .reciprocal = "amended_by" },
        .{ .field = "amended_by", .reciprocal = "amends" },
    };
    for (records.items) |record| {
        for (relations) |relation| {
            try checkAdrRelationField(gpa, violations, records.items, record, relation.field, relation.reciprocal);
        }
    }
}

/// An ADR may list aspirational acceptance scenarios without implemented
/// evidence. Once it is accepted, or once a partial migration records its
/// standing, prose alone is no longer enough: cite at least one in-tree test. status-allow: lifecycle transition
/// `checkMarkdownLinks` separately proves that the cited path resolves.
pub fn checkAdrEvidenceLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "docs/decisions/adr";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for ADR evidence check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.path, "ADR-") or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        const body = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for ADR evidence check with {s}", .{ dir_path, entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(body);

        if (std.mem.indexOf(u8, body, "\n## Required evidence\n") == null) continue;
        const accepted = if (adrFrontmatterValue(body, "status")) |status|
            std.mem.eql(u8, status, "accepted")
        else
            false;
        const records_standing = std.mem.indexOf(u8, body, "Migration standing") != null;
        if (!accepted and !records_standing) continue;
        if (std.mem.indexOf(u8, body, "](../../../test/") == null) {
            try appendViolation(gpa, violations, "{s}/{s}: accepted or migration-standing required evidence must cite an in-tree `test/` path with a Markdown link", .{ dir_path, entry.path });
        }
    }
}

fn checkAdrRelationField(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    records: []const AdrRecord,
    source: AdrRecord,
    field: []const u8,
    reciprocal: []const u8,
) !void {
    const raw = adrFrontmatterValue(source.body, field) orelse return;
    const inner = adrListInner(raw) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}` must be a one-line YAML list", .{ source.path, field });
        return;
    };
    var targets = std.mem.splitScalar(u8, inner, ',');
    while (targets.next()) |part| {
        const target_id = std.mem.trim(u8, part, " \t");
        if (target_id.len == 0) continue;
        if (std.mem.eql(u8, target_id, source.id)) {
            try appendViolation(gpa, violations, "{s}: `{s}` contains a self-reference to {s}", .{ source.path, field, source.id });
            continue;
        }
        const target = findAdrRecord(records, target_id) orelse {
            try appendViolation(gpa, violations, "{s}: `{s}` names missing or non-frontmatter ADR `{s}`", .{ source.path, field, target_id });
            continue;
        };
        if (!adrListFieldContains(target.body, reciprocal, source.id)) {
            try appendViolation(gpa, violations, "{s}: `{s}: [{s}]` requires `{s}: [{s}]` in {s}", .{ source.path, field, target_id, reciprocal, source.id, target.path });
        }
    }
}

fn findAdrRecord(records: []const AdrRecord, id: []const u8) ?AdrRecord {
    for (records) |record| {
        if (std.mem.eql(u8, record.id, id)) return record;
    }
    return null;
}

fn adrListFieldContains(body: []const u8, field: []const u8, wanted: []const u8) bool {
    const raw = adrFrontmatterValue(body, field) orelse return false;
    const inner = adrListInner(raw) orelse return false;
    var values = std.mem.splitScalar(u8, inner, ',');
    while (values.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), wanted)) return true;
    }
    return false;
}

fn adrListInner(raw: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return null;
    return value[1 .. value.len - 1];
}

fn adrFrontmatterValue(body: []const u8, field: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, body, "---\n")) return null;
    const end = std.mem.indexOfPos(u8, body, 4, "\n---") orelse return null;
    var lines = std.mem.splitScalar(u8, body[4..end], '\n');
    while (lines.next()) |line| {
        if (line.len <= field.len) continue;
        if (!std.mem.startsWith(u8, line, field)) continue;
        if (line[field.len] != ':') continue;
        return std.mem.trim(u8, line[field.len + 1 ..], " \t");
    }
    return null;
}

/// Every numbered citation in tracked text must name a current ADR, including
/// bare plural lists. Existing-but-unrelated records still require review.
pub fn checkAdrCitations(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8), root_path: []const u8) !void {
    var known: [10000]bool = @splat(false);
    var dir = try root.openDir(io, "docs/decisions/adr", .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "ADR-") or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (citationNumber(entry.name, 4)) |number| known[number] = true;
    }
    const files = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "-C", root_path, "ls-files", "-z" },
        .stdout_limit = .limited(64 << 20),
    });
    defer gpa.free(files.stdout);
    defer gpa.free(files.stderr);
    switch (files.term) {
        .exited => |code| if (code != 0) return error.AdrFileInventoryFailed,
        else => return error.AdrFileInventoryFailed,
    }
    var paths = std.mem.splitScalar(u8, files.stdout, 0);
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        const body = root.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| switch (err) {
            error.IsDir, error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(body);
        if (std.mem.indexOfScalar(u8, body, 0) != null) continue;
        try checkCitationText(gpa, violations, &known, path, body);
    }
}

fn citationNumber(body: []const u8, at: usize) ?usize {
    if (at + 4 > body.len) return null;
    for (body[at .. at + 4]) |c| if (!std.ascii.isDigit(c)) return null;
    if (at + 4 < body.len and std.ascii.isDigit(body[at + 4])) return null;
    return std.fmt.parseInt(usize, body[at .. at + 4], 10) catch unreachable;
}

fn checkCitationText(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), known: *const [10000]bool, path: []const u8, body: []const u8) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, "ADR")) |hit| {
        at = hit + 3;
        if (hit > 0 and (std.ascii.isAlphanumeric(body[hit - 1]) or body[hit - 1] == '_')) continue;
        const plural = std.mem.startsWith(u8, body[at..], "s ");
        const bare = plural or std.mem.startsWith(u8, body[at..], " ");
        if (!bare and !std.mem.startsWith(u8, body[at..], "-")) continue;
        at += if (plural) @as(usize, 2) else 1;
        while (citationNumber(body, at)) |number| {
            if (!known[number]) {
                const line = 1 + std.mem.count(u8, body[0..at], "\n");
                try appendViolation(gpa, violations, "{s}:{d}: ADR citation `{s}` names no record in docs/decisions/adr/", .{ path, line, body[at .. at + 4] });
            }
            at += 4;
            if (!bare) break;
            while (at < body.len and (std.ascii.isWhitespace(body[at]) or body[at] == ',' or body[at] == '/')) : (at += 1) {}
            if (std.mem.startsWith(u8, body[at..], "and ")) at += 4;
        }
    }
}

test "ADR citations validate both spellings and every member of bare lists" {
    const gpa = std.testing.allocator;
    var known: [10000]bool = @splat(false);
    known[1] = true;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkCitationText(gpa, &violations, &known, "fixture", "ADR-0001 ADRs 0001, " ++ "9999/9998 and 9997\nADR-" ++ "9996 ADR " ++ "9995");
    try std.testing.expectEqual(@as(usize, 5), violations.items.len);
}

test "tracked scratch citations fail when corrupted and pass when restored" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    try tmp.dir.createDirPath(io, "docs/decisions/adr");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/decisions/adr/ADR-0001-example.md", .data = "# ADR-0001\n" });
    const valid = "Read ADR-0001 and ADRs 0001.\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = valid });
    for ([_][]const []const u8{
        &.{ "git", "-C", path, "init", "--quiet" },
        &.{ "git", "-C", path, "add", "notes.md", "docs" },
    }) |argv| {
        const result = try std.process.run(gpa, io, .{ .argv = argv });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    }
    // An untracked scratch note is outside the source contract.
    try tmp.dir.writeFile(io, .{ .sub_path = "untracked.md", .data = "ADR-" ++ "9999" });
    for ([_][]const u8{ valid, "ADR-" ++ "9999", "ADRs 0001, " ++ "9999", valid }, 0..) |body, i| {
        try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = body });
        var violations: std.ArrayList([]const u8) = .empty;
        try checkAdrCitations(io, gpa, tmp.dir, &violations, path);
        const bad = i == 1 or i == 2;
        try std.testing.expectEqual(@as(usize, if (bad) 1 else 0), violations.items.len);
        if (bad) try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "notes.md:1: ADR citation `9999`") != null);
    }
}
