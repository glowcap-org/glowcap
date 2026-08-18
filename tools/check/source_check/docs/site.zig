//! The site's own contracts: content links and heading fragments, the
//! generated transport tabs, nav parity, ASCII-only SVG, the reduced-motion
//! guard, and per-page metadata.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const paths = @import("paths.zig");

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
        if (!paths.fileExists(io, root, as_page) and !paths.fileExists(io, root, as_index)) {
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
        if (!paths.fileExists(io, root, asset)) {
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
