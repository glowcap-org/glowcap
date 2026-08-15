//! The documentation checks.
//!
//! What keeps the doc corpus honest and readable as a surface: markdown and
//! site link resolution, the README quick-start snippet parity, dangling
//! rustdoc-style references, Mermaid block hygiene, planning-doc role
//! declarations, the doc-drift living-state registry, the human doc-voice
//! regressions, and the site SVG ASCII guard. Wired by the source-check driver
//! (`tools/check/source_check.zig`).

const std = @import("std");
const bans = @import("bans.zig");
const util = @import("util.zig");

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
        // `ADR-0086-byte-transparent-relay.md` -> `ADR-0086`. A name with no
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
/// still living guidance, which is how vocabulary-only amendments were
/// previously mislabeled as full supersessions.
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
/// standing, prose alone is no longer enough: cite at least one in-tree test.
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

pub fn checkMarkdownLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The first-read living-state surfaces that carry relative links: the root
    // contracts, the bindings READMEs (every language), and the examples index.
    // `site/content` is `.smd`, whose link syntax this `.md` walker does not
    // parse; `checkSiteContentLinks` gates those references instead.
    const files = [_][]const u8{
        "AGENTS.md",
        "README.md",
        "CONTRIBUTING.md",
        // The two first-read pages a reviewer opens before any code. They are
        // registered living-state; they should be the best-gated, not the least.
        "PROVENANCE.md",
        "SECURITY.md",
        "bindings/README.md",
        "bindings/DEVELOPING.md",
        "bindings/PACKAGING.md",
        "bindings/rust/README.md",
        "bindings/ts/README.md",
        "bindings/python/README.md",
        "bindings/racket/README.md",
        "examples/README.md",
    };
    for (files) |path| {
        try checkMarkdownLinksInFile(io, gpa, root, violations, path);
    }
    try checkMarkdownLinksUnder(io, gpa, root, violations, ".agents");
    try checkMarkdownLinksUnder(io, gpa, root, violations, ".devcontainer");
    try checkMarkdownLinksUnder(io, gpa, root, violations, "docs");
}

fn checkMarkdownLinksUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for Markdown link check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        try checkMarkdownLinksInFile(io, gpa, root, violations, path);
    }
}

fn checkMarkdownLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Markdown link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        var rest = line;
        while (std.mem.indexOf(u8, rest, "](")) |start| {
            const after = rest[start + "](".len ..];
            const end = std.mem.indexOfScalar(u8, after, ')') orelse break;
            const raw_target = after[0..end];
            rest = after[end + 1 ..];

            const resolved = (try resolveMarkdownTarget(gpa, path, raw_target)) orelse continue;
            defer gpa.free(resolved);
            root.access(io, resolved, .{}) catch |err| {
                try appendViolation(gpa, violations, "{s}:{d}: Markdown link `{s}` resolves to missing `{s}` ({s})", .{
                    path,
                    line_no,
                    raw_target,
                    resolved,
                    @errorName(err),
                });
            };
        }
    }
}

/// The site content pages are `.smd` (Zine), whose intra-site links use
/// `$link.page('id')` and asset references use `$image.siteAsset('name')` rather
/// than Markdown `](path)`. Zine resolves them when `zig build site` runs, but
/// that is a sibling step; this gate holds the same references in the hermetic
/// `check`. A `$link.page('id')` resolves to `site/content/id.smd` or
/// `site/content/id/index.smd`; a `$image.siteAsset('name')` resolves to
/// `site/assets/name`. (Absolute `https://` links carry their own Markdown
/// `](url)` form and are not this gate's concern.)
pub fn checkSiteContentLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for site link check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;
        const path = try std.fmt.allocPrint(gpa, "site/content/{s}", .{entry.path});
        defer gpa.free(path);
        try checkSiteContentLinksInFile(io, gpa, root, violations, path);
    }
}

/// Each binding direction tabs only the transport-specific setup and renders
/// the transport-independent CapTP workflow once. Keep both halves intact when
/// tightening site prose. The generator remains the sole transport inventory;
/// freshness is `zig build gen-site-examples-check`.
pub fn checkSiteTransportTabs(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const pages = [_]struct {
        path: []const u8,
        groups: usize,
    }{
        .{ .path = "site/content/start.smd", .groups = 2 },
        .{ .path = "site/content/bindings/browser.smd", .groups = 1 },
        .{ .path = "site/content/bindings/python.smd", .groups = 2 },
        .{ .path = "site/content/bindings/racket.smd", .groups = 2 },
        .{ .path = "site/content/bindings/rust.smd", .groups = 2 },
        .{ .path = "site/content/bindings/ts.smd", .groups = 2 },
    };
    const tab_marker = "> []($block.attrs('code-tabs'))";
    const common_marker = "From here, the CapTP workflow is the same for every transport:";

    for (pages) |page| {
        const contents = root.readFileAlloc(io, page.path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for transport-tab check with {s}", .{ page.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const tab_count = std.mem.count(u8, contents, tab_marker);
        if (tab_count != page.groups) {
            try appendViolation(gpa, violations, "{s}: expected {d} `{s}` markers, found {d}; keep the Dial and Listen example groups", .{ page.path, page.groups, tab_marker, tab_count });
        }
        const common_count = std.mem.count(u8, contents, common_marker);
        if (common_count != page.groups) {
            try appendViolation(gpa, violations, "{s}: expected {d} shared CapTP continuation{s}, found {d}; tab transport setup and render the common workflow once", .{
                page.path,
                page.groups,
                if (page.groups == 1) "" else "s",
                common_count,
            });
        }
    }
}

fn checkSiteContentLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for site link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    // `$site.page` is a layout expression. SuperMD leaves it literal inside
    // page content, producing an href that looks plausible in source and is
    // broken in the rendered artifact. Content links use `$link.page`.
    if (std.mem.indexOf(u8, contents, "$site.page(")) |_| {
        try appendViolation(gpa, violations, "{s}: page content contains `$site.page(...)`; use `$link.page(...)` so SuperMD resolves the link", .{path});
    }

    var rest = contents;
    while (std.mem.indexOf(u8, rest, "href=\"#")) |start| {
        const after = rest[start + "href=\"#".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const fragment = after[0..end];
        rest = after[end + 1 ..];
        if (fragment.len != 0 and !siteHeadingHasFragment(contents, fragment)) {
            try appendViolation(gpa, violations, "{s}: local fragment `#{s}` matches no h2 or h3 generated by the site table of contents", .{ path, fragment });
        }
    }

    rest = contents;
    while (std.mem.indexOf(u8, rest, "$link.page('")) |start| {
        const after = rest[start + "$link.page('".len ..];
        const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const id = after[0..end];
        rest = after[end + 1 ..];
        if (id.len == 0) continue;

        const as_page = try std.fmt.allocPrint(gpa, "site/content/{s}.smd", .{id});
        defer gpa.free(as_page);
        const as_index = try std.fmt.allocPrint(gpa, "site/content/{s}/index.smd", .{id});
        defer gpa.free(as_index);
        if (!fileExists(io, root, as_page) and !fileExists(io, root, as_index)) {
            try appendViolation(gpa, violations, "{s}: $link.page('{s}') resolves to neither `{s}` nor `{s}`", .{ path, id, as_page, as_index });
        }
    }

    rest = contents;
    while (std.mem.indexOf(u8, rest, "$image.siteAsset('")) |start| {
        const after = rest[start + "$image.siteAsset('".len ..];
        const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const name = after[0..end];
        rest = after[end + 1 ..];
        if (name.len == 0) continue;

        const asset = try std.fmt.allocPrint(gpa, "site/assets/{s}", .{name});
        defer gpa.free(asset);
        if (!fileExists(io, root, asset)) {
            try appendViolation(gpa, violations, "{s}: $image.siteAsset('{s}') resolves to missing `{s}`", .{ path, name, asset });
        }
    }
}

/// Match the heading ids minted by `base.shtml`'s table-of-contents script:
/// lowercase ASCII word characters and hyphens, punctuation removed,
/// whitespace collapsed to one hyphen, then limited to sixty bytes.
fn siteHeadingHasFragment(contents: []const u8, fragment: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const title = if (std.mem.startsWith(u8, line, "## "))
            line[3..]
        else if (std.mem.startsWith(u8, line, "### "))
            line[4..]
        else
            continue;

        var slug: [60]u8 = undefined;
        var len: usize = 0;
        var pending_space = false;
        for (std.mem.trim(u8, title, " \t")) |c| {
            if (std.ascii.isWhitespace(c)) {
                pending_space = true;
                continue;
            }
            const keep = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
            if (!keep) continue;
            if (pending_space and len != 0 and len < slug.len) {
                slug[len] = '-';
                len += 1;
            }
            pending_space = false;
            if (len == slug.len) break;
            slug[len] = std.ascii.toLower(c);
            len += 1;
        }
        if (std.mem.eql(u8, slug[0..len], fragment)) return true;
    }
    return false;
}

test "site heading fragments follow the browser slug rule" {
    const page =
        \\## In Zig
        \\## Time-travel: snapshot and restore
        \\### The `Host` API
    ;
    try std.testing.expect(siteHeadingHasFragment(page, "in-zig"));
    try std.testing.expect(siteHeadingHasFragment(page, "time-travel-snapshot-and-restore"));
    try std.testing.expect(siteHeadingHasFragment(page, "the-host-api"));
    try std.testing.expect(!siteHeadingHasFragment(page, "old-name"));
}

/// Every SuperMD page under `site/content/**` must be reachable from the site
/// navigation, so a new page cannot ship orphaned: built and URL-reachable, but
/// absent from the sidebar every reader browses by. The nav lives in one
/// template, `site/layouts/templates/base.shtml`, and links a page as
/// `$site.page('<id>')`, where `<id>` is the content path without `.smd` (a
/// trailing `/index.smd` collapses to its directory, and the root `index.smd` is
/// the home page, id `''`, linked as the brand). Adding a page and forgetting its
/// nav entry was a real hazard the relay page had to sidestep by hand; this makes
/// the reachability an invariant instead of a convention.
pub fn checkSiteNavParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const nav_path = "site/layouts/templates/base.shtml";
    const nav = root.readFileAlloc(io, nav_path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for site nav parity check with {s}", .{ nav_path, @errorName(err) });
        return;
    };
    defer gpa.free(nav);

    var dir = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for site nav parity check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;

        // Page id: the content path minus `.smd`, with a bare `index` (the home
        // page) or a trailing `/index` collapsed to its directory.
        var id = entry.path[0 .. entry.path.len - ".smd".len];
        if (std.mem.eql(u8, id, "index")) {
            id = "";
        } else if (std.mem.endsWith(u8, id, "/index")) {
            id = id[0 .. id.len - "/index".len];
        }

        const needle = try std.fmt.allocPrint(gpa, "site.page('{s}')", .{id});
        defer gpa.free(needle);
        if (std.mem.indexOf(u8, nav, needle) == null) {
            try appendViolation(gpa, violations, "site/content/{s}: orphaned page, {s} has no `{s}` nav entry, so the page ships invisible in the sidebar", .{ entry.path, nav_path, needle });
        }
    }
}

/// The netlayer resident roster is recited in prose across several inventory
/// docs, and the count and list have drifted before: a page hardcoded "four"
/// after a fifth resident landed, and one dropped a resident entirely. The
/// transport symbols are declared once in `src/ocapn/model/transport.zig`; the
/// residents are the subset that carry a `src/net/transport/<name>.zig` netlayer
/// (all but `keyed_relay`, a resident-less browser rendezvous symbol, and
/// `noise_relay`, realized as a sealing completion-backend adapter over the
/// keyed-relay pipe rather than a blocking resident). This pins
/// every roster doc to name every resident, so adding one forces each inventory
/// to mention it rather than silently falling behind. It replaces a fragile
/// negative phrase-ban with a positive set check.
pub fn checkResidentRoster(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const Resident = struct { name: []const u8, alts: []const []const u8 };
    // The spellings a doc may use for each resident, lowercased. Update this set
    // in the same change as a new `src/net/transport/*.zig` resident; the gate
    // then makes every roster doc name it.
    const residents = [_]Resident{
        .{ .name = "tcp", .alts = &.{"tcp"} },
        .{ .name = "keyed-tcp", .alts = &.{ "keyed-tcp", "keyed tcp", "tcp_keyed" } },
        .{ .name = "noise-tcp", .alts = &.{ "noise-tcp", "noise tcp" } },
        .{ .name = "inproc", .alts = &.{ "inproc", "in-process", "in process" } },
        .{ .name = "iroh", .alts = &.{"iroh"} },
        .{ .name = "webrtc", .alts = &.{"webrtc"} },
    };
    const roster_docs = [_][]const u8{
        "docs/ladder.md",
        "docs/shipped.md",
        // The page whose stated job is "the edges of what ships today". A
        // transport that ships without its edge written down fails here.
        "docs/boundaries.md",
        // The site inventory of every netlayer: choosing owns the roster now
        // that the parent Transports page is the concept overview.
        "site/content/transports/choosing.smd",
        "site/content/modules.smd",
        "site/content/relay.smd",
    };
    for (roster_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for resident-roster check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const lower = try gpa.alloc(u8, contents.len);
        defer gpa.free(lower);
        _ = std.ascii.lowerString(lower, contents);
        for (residents) |r| {
            var found = false;
            for (r.alts) |alt| {
                if (std.mem.indexOf(u8, lower, alt) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try appendViolation(gpa, violations, "{s}: the netlayer resident roster omits `{s}`; every roster doc must name all residents (src/ocapn/model/transport.zig is the source), so a resident cannot silently fall behind", .{ path, r.name });
            }
        }
    }
}

/// The README quotes the compiled quick-start example verbatim. The start page
/// has its own generated multi-transport tabs, held by gen-site-examples-check.
pub fn checkQuickStartSnippet(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const example_path = "examples/zig/readme_quick_start.zig";
    const example = root.readFileAlloc(io, example_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ example_path, @errorName(err) });
        return;
    };
    defer gpa.free(example);

    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(gpa);
    const import_lines = [_][]const u8{
        "const std = @import(\"std\");",
        "const pancake = @import(\"pancake\");",
    };
    for (import_lines) |import_line| {
        if (std.mem.indexOf(u8, example, import_line) == null) {
            try appendViolation(gpa, violations, "{s}: missing quick-start import `{s}`", .{ example_path, import_line });
            return;
        }
        try expected.append(gpa, import_line);
    }
    try expected.append(gpa, "");

    var in_body = false;
    var found_client = false;
    var lines = std.mem.splitScalar(u8, example, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!in_body) {
            if (std.mem.startsWith(u8, line, "fn client(")) {
                in_body = true;
                found_client = true;
            }
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            in_body = false;
            break;
        }
        if (line.len == 0) {
            try expected.append(gpa, line);
            continue;
        }
        if (!std.mem.startsWith(u8, line, "    ")) {
            try appendViolation(gpa, violations, "{s}: `fn client` body line not indented one level: `{s}`", .{ example_path, line });
            return;
        }
        try expected.append(gpa, line[4..]);
    }
    if (!found_client or in_body) {
        try appendViolation(gpa, violations, "{s}: could not extract the `fn client` body for the quick-start check", .{example_path});
        return;
    }

    try compareQuickStartDoc(io, gpa, root, violations, "README.md", expected.items, false);
    try compareAbridgedQuickStart(io, gpa, root, violations, "site/content/index.smd", expected.items);
}

/// The front page abridges the same quick start: it drops lines the teaser does
/// not need, so it cannot be held identical the way the two full copies are.
/// Hold it to the weaker claim it actually makes instead. Every line it keeps
/// must be a line the example carries, in the example's own order. Dropping a
/// line stays legal and rewording one does not, which is the drift a shortened
/// copy invites, because there is no verbatim twin to catch it.
fn compareAbridgedQuickStart(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the abridged quick-start check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var fence: std.ArrayList([]const u8) = .empty;
    defer fence.deinit(gpa);

    var capturing = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!capturing) {
            if (std.mem.eql(u8, line, "```zig")) capturing = true;
            continue;
        }
        if (std.mem.eql(u8, line, "```")) {
            found = true;
            break;
        }
        try fence.append(gpa, line);
    }
    if (!found) {
        try appendViolation(gpa, violations, "{s}: no ```zig fence to hold against examples/zig/readme_quick_start.zig", .{path});
        return;
    }

    var cursor: usize = 0;
    for (fence.items) |got| {
        if (got.len == 0) continue;
        var matched = false;
        while (cursor < expected.len) : (cursor += 1) {
            if (std.mem.eql(u8, got, expected[cursor])) {
                matched = true;
                cursor += 1;
                break;
            }
        }
        if (!matched) {
            try appendViolation(gpa, violations, "{s}: abridged quick-start line `{s}` is not one examples/zig/readme_quick_start.zig carries from here on; the front page may drop lines but never reword them", .{ path, got });
            return;
        }
    }
}

/// Find the doc's tcp quick-start fence (the one ```zig block carrying the
/// tcp marker comment) and hold it identical to the expected lines.
fn compareQuickStartDoc(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const []const u8,
    blockquoted: bool,
) !void {
    const marker = "// Plain TCP uses a cleartext `host:port` locator.";
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the quick-start check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var fence: std.ArrayList([]const u8) = .empty;
    defer fence.deinit(gpa);

    var capturing = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, " \t\r");
        if (blockquoted) {
            if (std.mem.startsWith(u8, line, "> ")) {
                line = line[2..];
            } else if (std.mem.eql(u8, line, ">")) {
                line = "";
            }
        }
        if (!capturing) {
            if (std.mem.eql(u8, line, "```zig")) {
                capturing = true;
                fence.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.eql(u8, line, "```")) {
            capturing = false;
            var has_marker = false;
            for (fence.items) |l| {
                if (std.mem.indexOf(u8, l, marker) != null) has_marker = true;
            }
            if (has_marker) {
                found = true;
                break;
            }
            continue;
        }
        try fence.append(gpa, line);
    }
    if (!found) {
        try appendViolation(gpa, violations, "{s}: no ```zig fence carries the tcp quick-start marker `{s}`", .{ path, marker });
        return;
    }
    if (fence.items.len != expected.len) {
        try appendViolation(gpa, violations, "{s}: tcp quick-start snippet is {d} lines but examples/zig/readme_quick_start.zig carries {d}; the two must match line for line", .{ path, fence.items.len, expected.len });
        return;
    }
    for (fence.items, expected, 0..) |got, want, i| {
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: tcp quick-start drifts from examples/zig/readme_quick_start.zig at snippet line {d}: `{s}` vs `{s}`", .{ path, i + 1, got, want });
            return;
        }
    }
}

/// The Markdown surfaces and Zig comment lines this repository owns must not
/// carry dangling bracketed code spans (see `danglingReferenceColumn`).
/// `bindings/rust` is deliberately exempt: rustdoc resolves the form there, so
/// in Rust doc comments it is a real link. Vendored trees under `upstream/`
/// are not ours to fix and are skipped.
pub fn checkDanglingReferenceLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // `bindings/rust/README.md` is excluded: rustdoc resolves the bracketed
    // code-span form, so it is a real link there (see the doc-voice rule).
    const markdown_files = [_][]const u8{ "AGENTS.md", "README.md", "CONTRIBUTING.md", "bindings/README.md", "bindings/DEVELOPING.md", "bindings/PACKAGING.md", "bindings/ts/README.md", "bindings/python/README.md", "bindings/racket/README.md" };
    for (markdown_files) |path| {
        try checkDanglingRefsInMarkdownFile(io, gpa, root, violations, path);
    }

    const markdown_trees = [_][]const u8{ ".agents", "docs", "examples" };
    for (markdown_trees) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for dangling-reference check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            try checkDanglingRefsInMarkdownFile(io, gpa, root, violations, path);
        }
    }

    const zig_trees = [_][]const u8{ "src", "test", "bench", "examples", "tools", "conformance", "interop" };
    for (zig_trees) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for dangling-reference check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (std.mem.indexOf(u8, entry.path, "upstream/") != null) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            try checkDanglingRefsInZigFile(io, gpa, root, violations, path);
        }
    }
}

fn checkDanglingRefsInMarkdownFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for dangling-reference check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (danglingReferenceColumn(line) != null) {
            try appendViolation(gpa, violations, "{s}:{d}: bracketed code span links nowhere, write a plain code span, or a real Markdown link with a target", .{ path, line_no });
        }
    }
}

fn checkDanglingRefsInZigFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for dangling-reference check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) continue;
        if (danglingReferenceColumn(line) != null) {
            try appendViolation(gpa, violations, "{s}:{d}: bracketed code span in a comment is rustdoc link syntax that Zig docs do not resolve, write a plain code span", .{ path, line_no });
        }
    }
}

/// Returns the column of the first dangling bracketed code span on `line`, or
/// null. The shape — a square bracket opening directly onto a backtick span and
/// closing right after it, with no link target, reference definition, or
/// reference label following — is rustdoc's intra-doc link syntax, which
/// nothing in this repository resolves: GitHub renders it as literal brackets
/// and Zig doc comments render it as dead text. A backtick directly before the
/// opening bracket means the bracket is itself inside a code span (a literal
/// bracket character), not a reference, so it is skipped.
fn danglingReferenceColumn(line: []const u8) ?usize {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_from, "[`")) |start| {
        search_from = start + 1;
        if (start != 0 and line[start - 1] == '`') continue;
        const inner_start = start + 2;
        const close = std.mem.indexOfPos(u8, line, inner_start, "`]") orelse return null;
        const inner = line[inner_start..close];
        if (inner.len == 0) continue;
        if (std.mem.indexOfAny(u8, inner, "`]") != null) continue;
        const after = close + 2;
        if (after < line.len and (line[after] == '(' or line[after] == ':' or line[after] == '[')) continue;
        return start;
    }
    return null;
}

const MermaidKind = enum { flowchart, sequence, state };

pub fn checkMermaidBlocks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for Mermaid check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);

    var walker = try docs.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "docs/{s}", .{entry.path});
        defer gpa.free(path);
        try checkMermaidBlocksInFile(io, gpa, root, violations, path);
    }
}

fn checkMermaidBlocksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Mermaid check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var block_start: usize = 0;
    var in_mermaid = false;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!in_mermaid) {
            if (std.mem.startsWith(u8, trimmed, "```mermaid")) {
                in_mermaid = true;
                block_start = line_no;
                block.clearRetainingCapacity();
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if ((try mermaidBlockKind(block.items)) == null) {
                try appendViolation(gpa, violations, "{s}:{d}: Mermaid block must start with flowchart, sequenceDiagram, or stateDiagram-v2", .{ path, block_start });
            }
            in_mermaid = false;
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, ';') != null) {
            try appendViolation(gpa, violations, "{s}:{d}: Mermaid reads ';' as a statement separator even inside note and label text, so the rest of the line becomes a broken statement at render time. Reword without the semicolon.", .{ path, line_no });
        }

        try block.appendSlice(gpa, line);
        try block.append(gpa, '\n');
    }

    if (in_mermaid) {
        try appendViolation(gpa, violations, "{s}:{d}: Mermaid block is not closed", .{ path, block_start });
    }
}

fn mermaidBlockKind(block: []const u8) !?MermaidKind {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const first = std.mem.trim(u8, line, " \t\r");
        if (first.len == 0) continue;
        if (std.mem.startsWith(u8, first, "flowchart ")) {
            const direction = std.mem.trim(u8, first["flowchart ".len..], " \t\r");
            inline for (&.{ "TB", "TD", "BT", "RL", "LR" }) |allowed| {
                if (std.mem.eql(u8, direction, allowed)) return .flowchart;
            }
            return null;
        }
        if (std.mem.eql(u8, first, "sequenceDiagram")) return .sequence;
        if (std.mem.eql(u8, first, "stateDiagram-v2")) return .state;
        return null;
    }
    return null;
}

pub fn checkPlanningDocRoles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // No planning docs is a valid state: the directory exists only while a
    // plan note is alive, and git does not track empty directories.
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "docs/planning: failed to open planning docs with {s}", .{@errorName(err)});
            return;
        },
    };
    defer planning.close(io);

    var walker = try planning.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const contents = planning.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "docs/planning/{s}: failed to read with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        if (std.mem.indexOf(u8, contents, "Status: active plan") == null and
            std.mem.indexOf(u8, contents, "Status: historical") == null and
            std.mem.indexOf(u8, contents, "Status: living-state") == null)
        {
            try appendViolation(gpa, violations, "docs/planning/{s}: must declare `Status: active plan`, `Status: historical ...`, or `Status: living-state ...`", .{entry.path});
        }
    }
}

/// The doc-drift living-state registry is itself a living-state surface, so it
/// is held honest in both directions. Forward: a registered non-glob path must
/// exist — an entry naming a deleted file is a broken promise. Reverse: every
/// top-level `docs/*.md` file, and every `docs/planning/*.md` that declares
/// `Status: living-state`, must appear in the registry — a doc that claims
/// living-state but is registered nowhere is ungoverned, which is exactly how
/// `docs/roadmap.md` once shipped outside the table.
pub fn checkLivingStateRegistry(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/doc-drift.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for living-state registry check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();
    _ = (try collectLivingStateRegistry(rule, &registry)) orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Living-State Surfaces` section", .{rule_path});
        return;
    };

    // Forward: every registered non-glob path resolves.
    var entries = registry.keyIterator();
    while (entries.next()) |entry| {
        if (std.mem.indexOfScalar(u8, entry.*, '*') != null) continue;
        root.access(io, entry.*, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: living-state registry names missing `{s}` ({s})", .{ rule_path, entry.*, @errorName(err) });
        };
    }

    // Reverse: every top-level docs/*.md is registered.
    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for living-state registry check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_it = docs.iterate();
    while (try docs_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/{s}", .{entry.name}) catch continue;
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: top-level doc `{s}` is not in the living-state registry", .{ rule_path, needle });
        }
    }

    // Reverse: every doc under a docs/ subdirectory that declares itself a
    // living-state surface is registered, by exact path or by a covering glob
    // (`docs/protocol-diagrams/**`). Top-level docs and planning docs are held
    // by the checks around this one; this one keeps a subdirectory corpus from
    // promising a maintenance discipline no gate holds.
    var docs_walker = try docs.walk(gpa);
    defer docs_walker.deinit();
    while (try docs_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') == null) continue;
        if (std.mem.startsWith(u8, entry.path, "planning/")) continue;
        const contents = docs.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Living-state surface") == null) continue;
        var covered_buf: [256]u8 = undefined;
        const covered_path = std.fmt.bufPrint(&covered_buf, "docs/{s}", .{entry.path}) catch continue;
        if (!registryCovers(&registry, covered_path)) {
            try appendViolation(gpa, violations, "{s}: `{s}` declares itself a living-state surface but no registry entry covers it", .{ rule_path, covered_path });
        }
    }

    // Reverse: every planning doc that declares itself living-state is registered.
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "docs/planning: failed to open for living-state registry check with {s}", .{@errorName(err)});
            return;
        },
    };
    defer planning.close(io);
    var planning_it = planning.iterate();
    while (try planning_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const contents = planning.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Status: living-state") == null) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/planning/{s}", .{entry.name}) catch continue;
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: planning doc `{s}` declares living-state but is not in the registry", .{ rule_path, needle });
        }
    }
}

/// Collects every backtick span on the bullet lines of doc-drift's
/// "Living-State Surfaces" section, the living-state registry. Spans are
/// slices into `rule`, so they share its lifetime.
fn collectLivingStateRegistry(rule: []const u8, out: *std.StringHashMap(void)) !?void {
    const heading = "## Living-State Surfaces";
    const section_start = std.mem.indexOf(u8, rule, heading) orelse return null;
    const after_heading = rule[section_start + heading.len ..];
    const section_end = std.mem.indexOf(u8, after_heading, "\n## ") orelse after_heading.len;
    const section = after_heading[0..section_end];

    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
        var rest = trimmed;
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after_open, '`') orelse break;
            try out.put(after_open[0..close], {});
            rest = after_open[close + 1 ..];
        }
    }
}

/// Returns true when the registry names `path` exactly or carries a glob
/// entry whose fixed prefix (the text before the first `*`) covers it.
fn registryCovers(registry: *const std.StringHashMap(void), path: []const u8) bool {
    if (registry.contains(path)) return true;
    var entries = registry.keyIterator();
    while (entries.next()) |entry| {
        const star = std.mem.indexOfScalar(u8, entry.*, '*') orelse continue;
        if (star == 0) continue;
        if (std.mem.startsWith(u8, path, entry.*[0..star])) return true;
    }
    return false;
}

/// The human-doc-voice phrase and `.agents/` link bans live in
/// `source_check/bans.zig` (`human_doc_voice`), driven by
/// `bans.human_doc_voice_scopes`. This walks those same scopes and holds the
/// one doc-voice ban that needs line and fence structure: the
/// connective-arrow check.
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
        // An unopenable tree already violates through the ban rows; do not
        // report it a second time here.
        bans.collectFiles(io, arena, root, scope.where, &files) catch continue;
        for (files.items) |path| {
            // A read failure is either an optional file or already reported
            // by the ban rows; the arrow check stays silent on it.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try banConnectiveArrowOutsideFences(gpa, violations, path, contents);
        }
    }

    // The em-dash overuse rows apply to prose wherever it lives, including the
    // Zig doc comments the doc-voice audience table counts as human surfaces.
    for (em_dash_overuse_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try banHabitualEmDash(gpa, violations, path, contents);
        }
    }
}

/// Where the em-dash overuse check runs. Wider than the human first-read scopes
/// above, because the habit shows up most in source comments.
const em_dash_overuse_scopes = [_]bans.Where{
    .{ .tree = .{ .dir = "src", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "cli", .suffixes = &.{".zig"} } },
    .{ .tree = .{ .dir = "docs", .suffixes = &.{".md"}, .recursive = false } },
    .{ .tree = .{ .dir = "site/content", .suffixes = &.{".smd"} } },
    // The registered living-state pages a reviewer opens before any code.
    // They carried the least-checked prose on the branch that added most of
    // it, which is the wrong way round for the first thing anyone reads.
    .{ .files = &.{ "README.md", "SECURITY.md", "PROVENANCE.md", "CONTRIBUTING.md" } },
    .{ .tree = .{ .dir = "conformance/ocapn-findings", .suffixes = &.{".md"} } },
};

/// The em-dash is a strong occasional tool, and doc-voice allows exactly two
/// uses: a matched pair standing in for parentheses, and a single dash for a
/// turn a comma cannot carry. It bans the rest by name, and these two spellings
/// are the ones a writer reaches for out of habit — a relative clause or a
/// continuation that a comma or a period carries just as well. They are checked
/// rather than merely written down because habit is what a rule sentence is
/// worst at stopping.
fn banHabitualEmDash(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
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

/// Arrow connective tissue in running prose (`miss→break`, `N→1`) is a doc-voice
/// tell. Fenced code and ASCII `->` diagrams may keep arrows; Unicode `→`/`⇒`
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

/// Owned site SVGs must be ASCII-only. A non-ASCII byte in one of these files is
/// almost always a literal typographic glyph — an em-dash, a middot — that
/// should have been a numeric entity (`&#8212;`, `&#183;`); saved raw it
/// corrupts the XML and the diagram silently stops rendering, which bit this
/// project more than once. Enforcing ASCII (entities for any non-ASCII glyph)
/// makes that failure mode unrepresentable. Only `.svg` is checked: PNGs and
/// other binaries under `site/assets` are not text we own.
pub fn checkSiteSvgAscii(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "site/assets";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for SVG ASCII check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".svg")) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);

        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for SVG ASCII check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var line_no: usize = 1;
        var col: usize = 1;
        for (contents) |byte| {
            if (byte == '\n') {
                line_no += 1;
                col = 1;
                continue;
            }
            if (byte > 0x7f) {
                try appendViolation(gpa, violations, "{s}:{d}:{d}: non-ASCII byte 0x{x:0>2} in SVG; use a numeric entity (e.g. &#8212; em-dash, &#183; middot) so the XML stays valid", .{ path, line_no, col, byte });
                break;
            }
            col += 1;
        }
    }
}

/// A site surface that declares an animation must also carry the
/// `prefers-reduced-motion` guard that turns it off. The animated diagrams
/// and the why-page walkthrough all pair `@keyframes` with a reduced-motion
/// rule whose base styles are the finished static picture; a future animation
/// added without that pair strips the accessibility fallback from a page
/// nobody re-tests by hand. Checked wherever site-owned styles live:
/// `site/assets`, `site/layouts`, and `site/content`.
pub fn checkSiteMotionReducedGuard(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dirs = [_][]const u8{ "site/assets", "site/layouts", "site/content" };
    const exts = [_][]const u8{ ".svg", ".css", ".shtml", ".smd" };
    for (dirs) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for motion-guard check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const matches_ext = for (exts) |ext| {
                if (std.mem.endsWith(u8, entry.path, ext)) break true;
            } else false;
            if (!matches_ext) continue;

            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);

            const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for motion-guard check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);

            if (std.mem.indexOf(u8, contents, "@keyframes") == null) continue;
            if (std.mem.indexOf(u8, contents, "prefers-reduced-motion") != null) continue;
            try appendViolation(gpa, violations, "{s}: declares @keyframes with no prefers-reduced-motion guard; animated site styles must keep a static fallback (base styles = the finished picture)", .{path});
        }
    }
}

/// A displayed code example is indented the way the project's formatter for
/// that language indents, so a reader who copies it gets the house style:
/// TypeScript and JavaScript use tabs (deno fmt, `useTabs`), and the
/// space-governed languages (zig fmt, ruff, shell) never start a line with a
/// tab. One tab-indented example beside space-indented siblings reads as an
/// accident, and no formatter runs inside a Markdown fence to catch it.
pub fn checkExampleFenceIndent(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tab_langs = [_][]const u8{ "ts", "typescript", "js", "javascript" };
    const space_langs = [_][]const u8{ "zig", "python", "py", "sh", "bash", "json", "c", "rust", "rkt", "racket" };
    const dirs = [_][]const u8{ "site/content", "docs", "bindings", "examples", "apps", "tools", "bench", "interop", "conformance", "transports", ".devcontainer" };
    const top_files = [_][]const u8{ "README.md", "CONTRIBUTING.md", "SECURITY.md", "PROVENANCE.md", "AGENTS.md" };
    // `apps/ocapnviz/` is the maintainer's own viewer, carried over from the
    // pre-Zig pancake tree and possibly headed for its own repository; its
    // docs keep their source style until that decision lands.
    const skip_fragments = [_][]const u8{ "target/", "node_modules/", "upstream/", "zig-out/", ".zig-cache/", "apps/ocapnviz/" };

    for (top_files) |path| {
        try checkFenceIndentFile(io, gpa, root, path, &tab_langs, &space_langs, violations);
    }
    for (dirs) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for fence-indent check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        walk: while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const is_doc = std.mem.endsWith(u8, entry.path, ".md") or std.mem.endsWith(u8, entry.path, ".smd");
            if (!is_doc) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            // Match on the repo-relative path: a walked entry's own path is
            // relative to the directory being walked, which would never carry
            // a fragment that names the top-level directory.
            for (skip_fragments) |frag| {
                if (std.mem.indexOf(u8, path, frag) != null) {
                    continue :walk;
                }
            }
            try checkFenceIndentFile(io, gpa, root, path, &tab_langs, &space_langs, violations);
        }
    }
}

fn checkFenceIndentFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    tab_langs: []const []const u8,
    space_langs: []const []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for fence-indent check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 0;
    var fence_lang: ?[]const u8 = null;
    var fence_flagged = false;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (fence_lang == null) {
                const info = std.mem.trim(u8, trimmed[3..], " \t\r");
                const end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
                fence_lang = info[0..end];
                fence_flagged = false;
            } else {
                fence_lang = null;
            }
            continue;
        }
        const lang = fence_lang orelse continue;
        if (fence_flagged or line.len == 0) continue;
        const wants_tabs = for (tab_langs) |l| {
            if (std.mem.eql(u8, lang, l)) break true;
        } else false;
        const wants_spaces = for (space_langs) |l| {
            if (std.mem.eql(u8, lang, l)) break true;
        } else false;
        if (wants_tabs and line[0] == ' ') {
            try appendViolation(gpa, violations, "{s}:{d}: space-indented line in a `{s}` example; this project's TypeScript/JavaScript style is tabs (deno fmt useTabs)", .{ path, line_no, lang });
            fence_flagged = true;
        } else if (wants_spaces and line[0] == '\t') {
            try appendViolation(gpa, violations, "{s}:{d}: tab-indented line in a `{s}` example; that language's formatter here uses spaces", .{ path, line_no, lang });
            fence_flagged = true;
        }
    }
}

fn fileExists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

fn resolveMarkdownTarget(gpa: std.mem.Allocator, source_path: []const u8, raw_target: []const u8) !?[]u8 {
    var target = std.mem.trim(u8, raw_target, " \t\r\n");
    if (target.len == 0) return null;
    if (target[0] == '<' and target[target.len - 1] == '>') target = target[1 .. target.len - 1];
    if (target.len == 0 or target[0] == '#') return null;
    if (std.mem.indexOf(u8, target, "://") != null) return null;
    inline for (&.{ "mailto:", "tel:", "data:" }) |scheme| {
        if (std.mem.startsWith(u8, target, scheme)) return null;
    }
    if (std.mem.startsWith(u8, target, "/")) return null;

    const path_end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const target_path = target[0..path_end];
    if (target_path.len == 0) return null;

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ source_dir, target_path });
    defer gpa.free(joined);
    return try normalizeRelativePath(gpa, joined);
}

fn normalizeRelativePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                parts.items.len -= 1;
            } else {
                try parts.append(gpa, part);
            }
            continue;
        }
        try parts.append(gpa, part);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

test "resolveMarkdownTarget normalizes local relative links" {
    const allocator = std.testing.allocator;

    const resolved = (try resolveMarkdownTarget(allocator, ".agents/rules/cli.md", "../../.devcontainer/pins.sh#versions")).?;
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(".devcontainer/pins.sh", resolved);

    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "https://example.invalid/docs") == null);
    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "#first-principles") == null);
}

test "collectLivingStateRegistry reads bullet spans only, prose spans never" {
    const gpa = std.testing.allocator;
    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();

    const rule =
        "## Living-State Surfaces\n\n" ++
        "- `README.md`\n" ++
        "- `.cursor/README.md`, `.cursor/*.json`\n" ++
        "- living-state when they are a first-read contract;\n\n" ++
        "`zig build source-check` holds this registry honest.\n\n" ++
        "## Discipline\n\n" ++
        "- `not-in-the-registry.md`\n";
    _ = (try collectLivingStateRegistry(rule, &registry)).?;

    // Bullet spans inside the section are the registry.
    try std.testing.expect(registry.contains("README.md"));
    try std.testing.expect(registry.contains(".cursor/README.md"));
    try std.testing.expect(registry.contains(".cursor/*.json"));
    // A span in prose is a sentence, not a registration; a span in another
    // section is out of scope.
    try std.testing.expect(!registry.contains("zig build source-check"));
    try std.testing.expect(!registry.contains("not-in-the-registry.md"));

    // A rule with no registry section reports null rather than an empty set.
    var empty = std.StringHashMap(void).init(gpa);
    defer empty.deinit();
    try std.testing.expect((try collectLivingStateRegistry("# no section here\n", &empty)) == null);
}

test "danglingReferenceColumn flags rustdoc-style references, never resolvable links or literal brackets" {
    // A bracketed code span with nothing after it resolves nowhere.
    try std.testing.expectEqual(@as(?usize, 4), danglingReferenceColumn("see [`Peer.step`] for the drain"));
    try std.testing.expectEqual(@as(?usize, 0), danglingReferenceColumn("[`core`] holds the shared types"));
    // A real inline link, a reference definition, and a reference label all resolve.
    try std.testing.expect(danglingReferenceColumn("see [`Peer`](../engine/mod.zig)") == null);
    try std.testing.expect(danglingReferenceColumn("[`Peer`]: ../engine/mod.zig") == null);
    try std.testing.expect(danglingReferenceColumn("see [`Peer`][engine-peer]") == null);
    // A bracket character inside a code span is a literal, not a reference.
    try std.testing.expect(danglingReferenceColumn("a byte equal to `<`, `>`, `[`, `]`, or a digit") == null);
    // An unclosed or backtick-laden candidate is not a reference shape.
    try std.testing.expect(danglingReferenceColumn("an open [`span with no close") == null);
}

test "mermaidBlockKind recognizes supported diagram heads" {
    try std.testing.expectEqual(MermaidKind.flowchart, (try mermaidBlockKind("flowchart TD\n    A --> B\n")).?);
    try std.testing.expectEqual(MermaidKind.sequence, (try mermaidBlockKind("\nsequenceDiagram\n    A->>B: hello\n")).?);
    try std.testing.expectEqual(MermaidKind.state, (try mermaidBlockKind("stateDiagram-v2\n    [*] --> Open\n")).?);
    try std.testing.expect(try mermaidBlockKind("notMermaid\n    A\n") == null);
}

/// The stability page says which evidence runs on every push. That claim is
/// only true while its build-step list matches `ci/gates.sh`, so compare the
/// two in both directions. A removed CI step must not remain documented as
/// recurring evidence.
pub fn checkStabilityGateList(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/stability.md";
    const ci_path = "ci/gates.sh";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = root.readFileAlloc(io, doc_path, arena, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: missing, but recurring evidence is documented there", .{doc_path});
        return;
    };
    const ci = root.readFileAlloc(io, ci_path, arena, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: missing, so the stability gate list cannot be checked", .{ci_path});
        return;
    };

    const begin = "<!-- ci-gate-list:begin -->";
    const end = "<!-- ci-gate-list:end -->";
    const from = std.mem.indexOf(u8, doc, begin) orelse {
        try appendViolation(gpa, violations, "{s}: no `{s}` marker; the gate list cannot be checked", .{ doc_path, begin });
        return;
    };
    const to = std.mem.indexOf(u8, doc, end) orelse {
        try appendViolation(gpa, violations, "{s}: no `{s}` marker; the gate list cannot be checked", .{ doc_path, end });
        return;
    };
    if (to < from) {
        try appendViolation(gpa, violations, "{s}: gate-list markers are out of order", .{doc_path});
        return;
    }

    var listed: std.ArrayList([]const u8) = .empty;
    try collectBuildSteps(arena, doc[from + begin.len .. to], "- `zig build ", &listed);
    var running: std.ArrayList([]const u8) = .empty;
    try collectBuildSteps(arena, ci, "\ngate zig build ", &running);

    for (running.items) |step| {
        if (!containsStep(listed.items, step)) {
            try appendViolation(gpa, violations, "{s}: `{s}` runs in {s} but is not listed as recurring evidence", .{ doc_path, step, ci_path });
        }
    }
    for (listed.items) |step| {
        if (!containsStep(running.items, step)) {
            try appendViolation(gpa, violations, "{s}: lists `{s}`, which {s} no longer runs; the evidence claim is stale", .{ doc_path, step, ci_path });
        }
    }
}

/// The community-review matrix makes direct claims about which live evidence
/// runs in CI. Derive those cells from the executable gate sequence so adding
/// or removing a gate cannot leave a stale "yes" or "no" for reviewers.
pub fn checkCommunityReviewCiMatrix(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/community-review.md";
    const ci_path = "ci/gates.sh";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = root.readFileAlloc(io, doc_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for CI matrix check with {s}", .{ doc_path, @errorName(err) });
        return;
    };
    const ci = root.readFileAlloc(io, ci_path, arena, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for community-review CI matrix check with {s}", .{ ci_path, @errorName(err) });
        return;
    };

    // One parser of `ci/gates.sh`, shared with `checkStabilityGateList`: two
    // would be two definitions of "runs in CI".
    var running: std.ArrayList([]const u8) = .empty;
    try collectBuildSteps(arena, ci, "\ngate zig build ", &running);

    const header = "| Evidence | CI | Proves | Does not prove |";
    const hit = std.mem.indexOf(u8, doc, header) orelse {
        try appendViolation(gpa, violations, "{s}: the evidence matrix header is gone, so nothing derives the CI column", .{doc_path});
        return;
    };

    var rest = doc[hit + header.len ..];
    var rows: usize = 0;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const row = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!std.mem.startsWith(u8, rest, "| ")) {
            if (row.len == 0 or std.mem.startsWith(u8, row, "| ")) continue;
            break;
        }
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        if (std.mem.startsWith(u8, line, "| ---")) continue;

        const evidence_end = std.mem.indexOfPos(u8, line, 2, " | ") orelse continue;
        const evidence = line[2..evidence_end];
        const cell_start = evidence_end + 3;
        const cell_end = std.mem.indexOfPos(u8, line, cell_start, " |") orelse continue;
        const cell = std.mem.trim(u8, line[cell_start..cell_end], " \t\r");
        // A cell that is neither is a violation, not a row to skip. Skipping
        // let any row opt out of the derivation by writing `Yes`, `partial`, or
        // `yes*` — and because the skip also stepped over the row count, the
        // empty-table backstop did not notice either.
        if (!std.mem.eql(u8, cell, "yes") and !std.mem.eql(u8, cell, "no")) {
            try appendViolation(gpa, violations, "{s}: evidence row `{s}` has CI cell `{s}`; the column is derived, so it must read exactly `yes` or `no`", .{ doc_path, evidence, cell });
            continue;
        }
        rows += 1;

        // The gates this row stands for: the first `zig build X` its Evidence
        // mentions, or an inline annotation for a row that cannot say it in the
        // cell — one whose step rides inside `check`, one that names a family
        // with a glob.
        //
        // A row that names its own step may only annotate `check`, which is the
        // one aggregate the sequence runs: that is the honest case of "my step
        // is real but rides inside another." Left free, the annotation was a
        // standing opt-out — any row could point at some unrelated step that
        // does run and mint itself a `yes`.
        //
        // What this still cannot know is whether an annotated step is really
        // the one that produces that row's evidence. That is the author's word,
        // and it is taken only where the cell has no word of its own.
        var gates: std.ArrayList([]const u8) = .empty;
        const names_step = std.mem.indexOf(u8, evidence, "`zig build ") != null;
        if (std.mem.indexOf(u8, line, "<!-- ci-gate:")) |ann| blk: {
            const body = line[ann + "<!-- ci-gate:".len ..];
            const body_end = std.mem.indexOf(u8, body, "-->") orelse body.len;
            if (names_step and !std.mem.eql(u8, std.mem.trim(u8, body[0..body_end], " \t\r"), "check")) {
                try appendViolation(gpa, violations, "{s}: evidence row `{s}` names its own `zig build` step and annotates a different one. Only `check` may override, for a step that rides inside it.", .{ doc_path, evidence });
                break :blk;
            }
            const ann_start = ann + "<!-- ci-gate:".len;
            const ann_end = std.mem.indexOfPos(u8, line, ann_start, "-->") orelse line.len;
            var it = std.mem.splitScalar(u8, line[ann_start..ann_end], ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t\r");
                if (trimmed.len != 0) try gates.append(arena, trimmed);
            }
        }
        if (gates.items.len == 0 and names_step) {
            // No usable annotation: derive from the step the cell names.
            const span = std.mem.indexOf(u8, evidence, "`zig build ").?;
            const name_start = span + "`zig build ".len;
            var stop = name_start;
            while (stop < evidence.len and evidence[stop] != '`') stop += 1;
            try gates.append(arena, std.mem.trim(u8, evidence[name_start..stop], " \t\r"));
        }
        if (gates.items.len == 0) {
            try appendViolation(gpa, violations, "{s}: evidence row `{s}` names no `zig build` step and carries no `<!-- ci-gate: … -->`, so its CI cell derives from nothing", .{ doc_path, evidence });
            continue;
        }

        var expected = true;
        for (gates.items) |gate| {
            if (!containsStep(running.items, gate)) {
                expected = false;
                break;
            }
        }
        const expected_cell = if (expected) "yes" else "no";
        if (!std.mem.eql(u8, cell, expected_cell)) {
            try appendViolation(gpa, violations, "{s}: `{s}` says CI `{s}`, but {s} derives `{s}`", .{ doc_path, evidence, cell, ci_path, expected_cell });
        }
    }

    // A table that stopped having rows would otherwise pass in silence.
    if (rows == 0) {
        try appendViolation(gpa, violations, "{s}: the evidence matrix has no derivable rows", .{doc_path});
    }
}

/// Collect the build-step names that follow each occurrence of `prefix`, up to
/// the next backtick or end of line.
fn collectBuildSteps(
    arena: std.mem.Allocator,
    haystack: []const u8,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, prefix)) |hit| {
        const start = hit + prefix.len;
        var stop = start;
        // A space ends the name as surely as a backtick or a newline does: a
        // build step never contains one, so anything past it is arguments. A
        // gate that passes an option (`zig build fuzz -Dfuzz-runs=25K`) is
        // still running that step, and a doc row saying CI runs `fuzz` is
        // still true — without this the option becomes part of the name and
        // every such row reads as stale.
        while (stop < haystack.len and
            haystack[stop] != '`' and
            haystack[stop] != '\n' and
            haystack[stop] != ' ') stop += 1;
        const name = std.mem.trim(u8, haystack[start..stop], " \t\r");
        if (name.len > 0) try out.append(arena, name);
        at = stop;
    }
}

fn containsStep(steps: []const []const u8, needle: []const u8) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step, needle)) return true;
    }
    return false;
}

/// Every checked-in fuzz corpus entry must be wired as a seed.
///
/// The seeds were hand-picked once and the corpus kept growing, so most entries
/// were shapes the fuzzer would never start from. A corpus file that is not a
/// seed is invisible: nothing fails, the harness just covers less than it looks
/// like it does. This is the kind of drift a rule cannot hold and a build check
/// can.
pub fn checkFuzzCorpusSeeds(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The seed list moved out of the codec target when every fuzz target began
    // sharing it. The check follows it: pointed at the old path it would read a
    // file with no seeds in it and pass, which is the quiet way a parity check
    // stops being one.
    const harness_path = "test/support/corpus_seeds.zig";
    const corpus_dir = "test/oracle/corpus";

    const harness = root.readFileAlloc(io, harness_path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for fuzz seed check with {s}", .{ harness_path, @errorName(err) });
        return;
    };
    defer gpa.free(harness);

    var dir = root.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for fuzz seed check with {s}", .{ corpus_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;

        const needle = try std.fmt.allocPrint(gpa, "corpus/{s}\")", .{entry.name});
        defer gpa.free(needle);
        if (std.mem.indexOf(u8, harness, needle) == null) {
            try appendViolation(gpa, violations, "{s}: corpus entry `{s}` is not wired as a seed in {s}", .{ corpus_dir, entry.name, harness_path });
        }
    }
}

/// The longest a sentence may run on a page written for people.
///
/// The median sentence on these pages is under a hundred characters, so this is
/// not a style preference dressed as a rule: it is the point past which a
/// sentence has stopped being one. Every sentence over it that we looked at was
/// three or four ideas joined by semicolons, usually with a stack of identifiers
/// and a decision-record number wedged in. doc-voice already asks for one idea
/// per sentence; this is the part of that a build can hold.
const max_prose_sentence = 250;

/// Refuse a sentence too long to read aloud, on the pages a person reads.
///
/// Fenced code, tables, and link-heavy lines are skipped: a table row is not
/// prose, and a long URL is not a long sentence.
/// The site's stability page repeats docs/stability.md's evidence table.
/// Hold the two tables identical so the public copy cannot drift from the
/// canonical one.
pub fn checkStabilityEvidenceParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc_path = "docs/stability.md";
    const site_path = "site/content/stability.smd";
    const doc = root.readFileAlloc(io, doc_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ doc_path, @errorName(err) });
        return;
    };
    defer gpa.free(doc);
    const site = root.readFileAlloc(io, site_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ site_path, @errorName(err) });
        return;
    };
    defer gpa.free(site);

    var doc_rows: std.ArrayList([]const u8) = .empty;
    defer doc_rows.deinit(gpa);
    try collectEvidenceRows(gpa, doc, &doc_rows);
    var site_rows: std.ArrayList([]const u8) = .empty;
    defer site_rows.deinit(gpa);
    try collectEvidenceRows(gpa, site, &site_rows);

    if (doc_rows.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no stability evidence table found for the parity check", .{doc_path});
        return;
    }
    if (site_rows.items.len == 0) {
        try appendViolation(gpa, violations, "{s}: no stability evidence table found for the parity check", .{site_path});
        return;
    }
    const shared = @min(doc_rows.items.len, site_rows.items.len);
    var i: usize = 0;
    while (i < shared) : (i += 1) {
        if (!std.mem.eql(u8, doc_rows.items[i], site_rows.items[i])) {
            try appendViolation(gpa, violations, "stability evidence tables differ at row {d}: docs has `{s}`, site has `{s}`", .{ i + 1, doc_rows.items[i], site_rows.items[i] });
            return;
        }
    }
    if (doc_rows.items.len != site_rows.items.len) {
        try appendViolation(gpa, violations, "stability evidence tables differ in length: {s} has {d} rows, {s} has {d}", .{ doc_path, doc_rows.items.len, site_path, site_rows.items.len });
    }
}

/// Collect the rows of the first stability evidence table in `contents`,
/// excluding the header and its separator line.
fn collectEvidenceRows(
    gpa: std.mem.Allocator,
    contents: []const u8,
    rows: *std.ArrayList([]const u8),
) !void {
    var in_table = false;
    var past_separator = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!in_table) {
            if (std.mem.eql(u8, line, "| Area | Evidence | What remains |")) in_table = true;
            continue;
        }
        if (!past_separator) {
            past_separator = true;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "|")) return;
        try rows.append(gpa, line);
    }
}

pub fn checkProseSentenceLength(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (em_dash_overuse_scopes) |where| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        bans.collectFiles(io, arena, root, where, &files) catch continue;
        for (files.items) |path| {
            if (!std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".smd")) continue;
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try checkSentencesIn(gpa, violations, path, contents);
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
        // leading `>` must not hide the fence from this scanner — otherwise the
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
        // row put the densest paragraphs in the tree — the evidence matrix a
        // reviewer opens first — outside the only gate that reads for
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

/// Every page needs its own `<title>` and `<meta name="description">`. The base
/// template builds both from the page's frontmatter, so a page that omits
/// `.description` ships an empty description tag, and one that reuses another
/// page's `.title` is indistinguishable from it in a browser tab, a bookmark, or
/// a search result. This holds every `.smd` page to a non-empty description and
/// a title unique across the site.
pub fn checkSitePageMetadata(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for page metadata check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var titles: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = titles.iterator();
        while (it.next()) |row| {
            gpa.free(row.key_ptr.*);
            gpa.free(row.value_ptr.*);
        }
        titles.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;

        const body = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "site/content/{s}: failed to read for page metadata check with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(body);

        const title = frontmatterField(body, ".title = \"");
        const description = frontmatterField(body, ".description = \"");

        if (description == null or description.?.len == 0) {
            try appendViolation(gpa, violations, "site/content/{s}: no `.description` in the frontmatter, so the page ships an empty <meta name=\"description\">", .{entry.path});
        }
        const seen_title = title orelse {
            try appendViolation(gpa, violations, "site/content/{s}: no `.title` in the frontmatter, so the page has no <title>", .{entry.path});
            continue;
        };
        if (titles.get(seen_title)) |other| {
            try appendViolation(gpa, violations, "site/content/{s}: `.title` \"{s}\" is already used by site/content/{s}, so the two pages are one name in a browser tab", .{ entry.path, seen_title, other });
            continue;
        }
        try titles.put(gpa, try gpa.dupe(u8, seen_title), try gpa.dupe(u8, entry.path));
    }
}

/// The value of one `.field = "…"` line in an `.smd` frontmatter block, or null
/// when the field is absent. Frontmatter is the leading `---`-delimited section,
/// so the search stops at the closing fence rather than matching body prose.
fn frontmatterField(body: []const u8, needle: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, body, "---\n")) return null;
    const end = std.mem.indexOfPos(u8, body, 4, "\n---") orelse return null;
    const front = body[4..end];
    const at = std.mem.indexOf(u8, front, needle) orelse return null;
    const rest = front[at + needle.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..close];
}
