//! The shared UI core checks.
//!
//! `ui/` holds one palette, one type ramp, and one set of font files, and two
//! independently-built surfaces consume them through symlinks: the Zine
//! documentation site and the Deno rooms app. Nothing about that arrangement
//! fails a build on its own, so these checks hold it: the links stay links, the
//! faces the core declares are the files on disk and the ones each consumer
//! names, the licence travels with them, no surface restates a core colour, the
//! dark theme's two arms agree, and a stylesheet that never closes a comment or
//! brace is refused. Wired by the source-check driver
//! (`tools/check/source_check.zig`).

const std = @import("std");
const util = @import("util.zig");
const scaffolding = @import("scaffolding.zig");

const appendViolation = util.appendViolation;

/// Product stylesheets the browser loads. Symlinked copies of `ui/tokens.css`
/// and `ui/mark.css` are not listed: the canonical file is enough, and a fault
/// there is one fault, not three.
pub const css_files = [_][]const u8{
    "ui/tokens.css",
    "ui/mark.css",
    "apps/ocapnviz/src/styles.css",
    "apps/ocapnviz/src/controls.css",
};

pub const css_dirs = [_][]const u8{
    "apps/rooms/web/ui",
    "site/assets",
};

/// The shared UI core is one directory that two independently-built surfaces
/// consume through symlinks. Four things can silently break that, and none of
/// them fails a build on its own:
///
/// A tool that writes through a symlink turns it into a regular file, and the
/// palette forks into two copies that drift. A face added to `ui/tokens.css`
/// without the file beside it is invisible, because `font-display: swap`
/// substitutes a synthesised oblique rather than reporting the miss. The rooms
/// server serves fonts from an allowlist, so a face the stylesheet names and
/// the allowlist does not is a 404 that only shows as the wrong shapes. And the
/// site's page template names each face in a `<link>` of its own, so a face it
/// misses is fetched late, mid-render, as a flash of fallback type.
///
/// So this reads the faces from the core and holds every consumer to them: the
/// files exist, each consumer's symlink is still a symlink pointing home, and
/// each consumer's own page or server names the face. Adding a face to the
/// palette extends all of it at once.
const UiConsumer = struct {
    /// Where this consumer's symlinks into the shared core live.
    fonts_dir: []const u8,
    /// What each of those symlinks must point at, before the file name.
    fonts_target: []const u8,
    /// The stylesheet or document that declares every shared face for this consumer.
    names_faces_in: []const u8,
    /// What a missing name costs, in the consumer's own terms.
    miss_costs: []const u8,
};

const ui_consumers = [_]UiConsumer{
    .{
        .fonts_dir = "site/assets/fonts",
        .fonts_target = "../../../ui/fonts/",
        .names_faces_in = "site/layouts/templates/base.shtml",
        .miss_costs = "the site would fetch it mid-render, as a flash of fallback type",
    },
    .{
        .fonts_dir = "apps/rooms/web/ui/fonts",
        .fonts_target = "../../../../../ui/fonts/",
        .names_faces_in = "apps/rooms/web/ui/tokens.css",
        .miss_costs = "the Rooms stylesheet would omit its shared face",
    },
};

pub fn checkUiCore(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tokens = root.readFileAlloc(io, "ui/tokens.css", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "ui/tokens.css: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(tokens);

    // Every face the core declares, taken from its `url("fonts/…woff2")` forms.
    var declared: std.ArrayList([]const u8) = .empty;
    defer declared.deinit(gpa);
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, tokens, scan, "url(\"fonts/")) |hit| {
        const start = hit + "url(\"fonts/".len;
        const end = std.mem.indexOfScalarPos(u8, tokens, start, '"') orelse {
            try appendViolation(gpa, violations, "ui/tokens.css: a `url(\"fonts/` is never closed, so the faces after it are invisible here", .{});
            break;
        };
        try declared.append(gpa, tokens[start..end]);
        scan = end;
    }
    if (declared.items.len == 0) {
        try appendViolation(gpa, violations, "ui/tokens.css: declares no font faces; every check below would pass vacuously", .{});
        return;
    }

    for (declared.items) |face| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "ui/fonts/{s}", .{face}) catch {
            try appendViolation(gpa, violations, "ui/tokens.css names `{s}`, whose path does not fit a path buffer", .{face});
            continue;
        };
        root.access(io, path, .{}) catch {
            try appendViolation(gpa, violations, "ui/tokens.css names `{s}` but {s} does not exist; the browser would substitute a synthesised face instead of reporting it", .{ face, path });
        };
    }

    for (ui_consumers) |consumer| {
        const names = root.readFileAlloc(io, consumer.names_faces_in, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ consumer.names_faces_in, @errorName(err) });
            continue;
        };
        defer gpa.free(names);

        for (declared.items) |face| {
            if (std.mem.indexOf(u8, names, face) == null) {
                try appendViolation(gpa, violations, "ui/tokens.css names `{s}` but {s} does not; {s}", .{ face, consumer.names_faces_in, consumer.miss_costs });
            }

            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link = std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ consumer.fonts_dir, face }) catch {
                try appendViolation(gpa, violations, "{s}: the link path for `{s}` does not fit a path buffer", .{ consumer.fonts_dir, face });
                continue;
            };
            const target = std.fmt.bufPrint(&target_buf, "{s}{s}", .{ consumer.fonts_target, face }) catch {
                try appendViolation(gpa, violations, "{s}: the link target for `{s}` does not fit a path buffer", .{ consumer.fonts_dir, face });
                continue;
            };
            try scaffolding.expectSymlink(io, gpa, root, violations, link, target);
        }

        // And nothing extra in the consumer's directory, so a retired face
        // cannot linger as a stale copy the core no longer owns.
        try checkOnlyDeclared(io, gpa, root, violations, consumer.fonts_dir, declared.items, &.{});
    }

    // The OFL requires the licence to travel with the Font Software, so it
    // lives beside the faces rather than only in LICENSE-THIRD-PARTY.
    root.access(io, "ui/fonts/OFL.txt", .{}) catch {
        try appendViolation(gpa, violations, "ui/fonts/OFL.txt is missing; the licence these faces ship under requires each copy of them to carry it", .{});
    };
    try checkOnlyDeclared(io, gpa, root, violations, "ui/fonts", declared.items, &.{"OFL.txt"});

    // OCapNviz carries its own face rather than one from the shared UI core,
    // but the OFL has the same distribution requirement: the complete license
    // stays beside the font. Holding the two-file directory closed also makes a
    // new face bring its notice into the same change.
    root.access(io, "apps/ocapnviz/public/fonts/DepartureMono-OFL.txt", .{}) catch {
        try appendViolation(gpa, violations, "apps/ocapnviz/public/fonts/DepartureMono-OFL.txt is missing; the license must travel with DepartureMono-Regular.woff2", .{});
    };
    try checkOnlyDeclared(
        io,
        gpa,
        root,
        violations,
        "apps/ocapnviz/public/fonts",
        &.{"DepartureMono-Regular.woff2"},
        &.{"DepartureMono-OFL.txt"},
    );
}

/// Every entry in `dir` is one of the faces the core declares, or one of the
/// few files that belong beside them.
fn checkOnlyDeclared(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    declared: []const []const u8,
    also_expected: []const []const u8,
) !void {
    var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open with {s}", .{ path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
            return;
        } orelse break;
        if (entry.kind == .directory) continue;
        var found = false;
        for (declared) |face| {
            if (std.mem.eql(u8, face, entry.name)) found = true;
        }
        for (also_expected) |name| {
            if (std.mem.eql(u8, name, entry.name)) found = true;
        }
        if (!found) {
            try appendViolation(gpa, violations, "{s}/{s} is not named by ui/tokens.css; delete it or declare it", .{ path, entry.name });
        }
    }
}

/// The colour rule the shared core states: a surface may build semantic tokens
/// freely, but it may not restate a core value. Two copies of a colour drift,
/// and the drift shows only in whichever theme the editor was not looking at.
///
/// Both spellings count. `--ink` has been restated as `#3a3027` and, twice, as
/// `rgba(58, 48, 39, …)`, and a scan for hex alone would have missed the shadow
/// that carried the decimal form. Hex is matched case-insensitively, because CSS
/// is. The core values are read from `ui/tokens.css`
/// rather than listed here, so adding a token to the palette extends the check
/// without touching it.
pub fn checkUiPaletteLiterals(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tokens = root.readFileAlloc(io, "ui/tokens.css", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "ui/tokens.css: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(tokens);

    // The core palette: `--name: #rrggbb;` declarations in the shared file.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var hexes: std.ArrayList([]const u8) = .empty;
    defer hexes.deinit(gpa);
    var line_it = std.mem.splitScalar(u8, tokens, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "--")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        // Every colour on the line, not the first. A folded token reads
        // `--ink: light-dark(#3a3027, #f3e6d0);`, so taking one `#` per
        // declaration would leave the whole dark half of the palette unguarded.
        var at = colon;
        while (std.mem.indexOfScalarPos(u8, trimmed, at, '#')) |hash| {
            at = hash + 1;
            if (trimmed.len < hash + 7) break;
            const hex = trimmed[hash .. hash + 7];
            const looks_hex = for (hex[1..]) |c| {
                if (!std.ascii.isHex(c)) break false;
            } else true;
            if (!looks_hex) continue;
            try names.append(gpa, trimmed[0..colon]);
            try hexes.append(gpa, hex);
        }
    }
    if (hexes.items.len == 0) {
        try appendViolation(gpa, violations, "ui/tokens.css: no core palette values found; checkUiPaletteLiterals would pass vacuously", .{});
        return;
    }

    for (ui_surfaces) |surface| {
        // The core owns these values; it is the one file allowed to write them.
        if (std.mem.eql(u8, surface.css, "ui/tokens.css")) continue;
        const path = surface.css;
        const css = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(css);

        // The rooms avatar ramp is the one exemption. Its tints carry white
        // initials, so each has to clear 4.5:1 against them, and three of the
        // ten are the light arm of a core token whose dark arm misses that bar.
        // Following the token would read correctly and then fail on a theme
        // change, so the ramp is written out; page.css records the numbers.
        // Every other line answers to the rule.
        var scannable: std.ArrayList(u8) = .empty;
        defer scannable.deinit(gpa);
        var css_lines = std.mem.splitScalar(u8, css, '\n');
        while (css_lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "--avatar-")) continue;
            try scannable.appendSlice(gpa, line);
            try scannable.append(gpa, '\n');
        }
        const css_scan = scannable.items;

        for (hexes.items, names.items) |hex, name| {
            if (std.ascii.findIgnoreCasePos(css_scan, 0, hex) != null) {
                try appendViolation(gpa, violations, "{s} writes the core colour {s}; use var({s}) — ui/tokens.css owns it", .{ path, hex, name });
            }
            // The same colour spelled as decimal channels, which a hex scan misses.
            const r = std.fmt.parseInt(u8, hex[1..3], 16) catch {
                try appendViolation(gpa, violations, "ui/tokens.css core colour `{s}` is not #rrggbb; the decimal-channel scan cannot run", .{hex});
                continue;
            };
            const g = std.fmt.parseInt(u8, hex[3..5], 16) catch {
                try appendViolation(gpa, violations, "ui/tokens.css core colour `{s}` is not #rrggbb; the decimal-channel scan cannot run", .{hex});
                continue;
            };
            const bl = std.fmt.parseInt(u8, hex[5..7], 16) catch {
                try appendViolation(gpa, violations, "ui/tokens.css core colour `{s}` is not #rrggbb; the decimal-channel scan cannot run", .{hex});
                continue;
            };
            var spaced: [16]u8 = undefined;
            var tight: [16]u8 = undefined;
            for ([_][]const u8{
                std.fmt.bufPrint(&spaced, "{d}, {d}, {d}", .{ r, g, bl }) catch unreachable,
                std.fmt.bufPrint(&tight, "{d},{d},{d}", .{ r, g, bl }) catch unreachable,
            }) |needle| {
                if (std.mem.indexOf(u8, css_scan, needle) != null) {
                    try appendViolation(gpa, violations, "{s} writes the core colour {s} as `{s}`; use color-mix over var({s})", .{ path, hex, needle, name });
                }
            }
        }
    }
}

/// Where a marker sits relative to the declarations it introduces.
const BlockOf = enum {
    /// The marker is part of a selector, so that selector's own block holds the
    /// declarations: `[data-theme="dark"] { … }`.
    rule,
    /// The marker is part of an at-rule's prelude, so the declarations are in
    /// the rule nested inside it: `@media (…) { html { … } }`.
    at_rule,
};

/// The declaration block a marker at `from` introduces, balanced, or null if
/// the stylesheet does not have the shape the caller expects.
///
/// Braces inside comments and quoted strings are skipped, so a `content: "{"`
/// or a commented-out rule cannot shift the count.
fn declarationBlock(css: []const u8, from: usize, of: BlockOf) ?[]const u8 {
    const wanted: usize = switch (of) {
        .rule => 1,
        .at_rule => 2,
    };
    var scan: Scanner = .{ .css = css, .i = from };
    var seen: usize = 0;
    while (scan.next()) |i| {
        if (css[i] != '{') continue;
        seen += 1;
        if (seen < wanted) continue;
        var depth: usize = 1;
        var inner: Scanner = .{ .css = css, .i = i + 1 };
        while (inner.next()) |j| {
            if (css[j] == '{') depth += 1;
            if (css[j] == '}') {
                depth -= 1;
                if (depth == 0) return css[i + 1 .. j];
            }
        }
        return null;
    }
    return null;
}

/// Walks CSS one byte at a time, yielding only the indices that are code:
/// `/* … */` comments and quoted strings are stepped over whole.
const Scanner = struct {
    css: []const u8,
    i: usize,

    fn next(self: *Scanner) ?usize {
        while (self.i < self.css.len) {
            const c = self.css[self.i];
            if (c == '/' and self.i + 1 < self.css.len and self.css[self.i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, self.css, self.i + 2, "*/") orelse {
                    self.i = self.css.len;
                    return null;
                };
                self.i = end + 2;
                continue;
            }
            if (c == '"' or c == '\'') {
                self.i += 1;
                while (self.i < self.css.len and self.css[self.i] != c) {
                    // A backslash escapes the next byte, including the quote.
                    self.i += if (self.css[self.i] == '\\') @as(usize, 2) else 1;
                }
                self.i += 1;
                continue;
            }
            const at = self.i;
            self.i += 1;
            return at;
        }
        return null;
    }
};

/// Syrup is the default face, so the dark theme is reachable by a root nobody
/// has stamped and `data-theme="light"` is the only thing that turns it off.
/// One selector says exactly that, and this holds each surface to it: the dark
/// arm must be `:not([data-theme="light"])`, and no surface may hang theme
/// tokens off `prefers-color-scheme` instead, which would hand the decision
/// back to the desktop the default was chosen over.
///
/// Most of the palette folded onto `light-dark()`, which needs no arm of its
/// own. What remains is the diagram tints: they have no light value at all,
/// because each SVG names them as `var(--dia-…, #literal)` and several distinct
/// pale tints share one token.
///
/// The expectation is per surface and is checked both ways, so a file that
/// folds its last unfolded token fails here rather than quietly becoming a
/// check that cannot fail.
const UiSurface = struct { css: []const u8, two_armed: bool };

const ui_surfaces = [_]UiSurface{
    .{ .css = "ui/tokens.css", .two_armed = false },
    .{ .css = "site/assets/style.css", .two_armed = true },
    .{ .css = "apps/rooms/web/ui/page.css", .two_armed = false },
};

pub fn checkUiThemeParity(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (ui_surfaces) |surface| {
        const path = surface.css;
        const css = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(css);

        const attr_at = std.mem.indexOf(u8, css, ":not([data-theme=\"light\"])") orelse {
            try appendViolation(gpa, violations, "{s}: has no `:not([data-theme=\"light\"])` arm, so a reader who never touches the toggle never gets the default theme", .{path});
            continue;
        };
        const attr_body = declarationBlock(css, attr_at, .rule) orelse {
            try appendViolation(gpa, violations, "{s}: could not read the default dark block", .{path});
            continue;
        };

        var attr_decls = std.StringHashMap([]const u8).init(gpa);
        defer attr_decls.deinit();
        try collectDecls(attr_body, &attr_decls);

        // The expectation, checked both ways.
        const declares = attr_decls.count() != 0;
        if (surface.two_armed and !declares) {
            try appendViolation(gpa, violations, "{s}: is listed as carrying its own dark tokens but declares none in the default arm, so this check cannot fail; fold it or update the surface table", .{path});
            continue;
        }
        if (!surface.two_armed and declares) {
            try appendViolation(gpa, violations, "{s}: folded onto `light-dark()` but still declares a token in the dark arm; fold it too, or mark the surface as carrying its own", .{path});
        }

        // The desktop no longer decides the theme, so nothing about the theme
        // may hang off it. A media query is still fine for anything else.
        var media_at = std.mem.indexOf(u8, css, "prefers-color-scheme: dark");
        while (media_at) |at| {
            const media_body = declarationBlock(css, at, .at_rule) orelse {
                try appendViolation(gpa, violations, "{s}: could not read a dark media-query block", .{path});
                break;
            };
            if (std.mem.indexOf(u8, media_body, "color-scheme:") != null or
                std.mem.indexOf(u8, media_body, "data-theme") != null)
            {
                try appendViolation(gpa, violations, "{s}: sets the theme from `prefers-color-scheme`, which the default face replaced; put it under `:not([data-theme=\"light\"])`", .{path});
            }
            const next = at + "prefers-color-scheme: dark".len;
            media_at = if (next < css.len) blk: {
                const rest = std.mem.indexOf(u8, css[next..], "prefers-color-scheme: dark") orelse break :blk null;
                break :blk next + rest;
            } else null;
        }
    }
}

/// Product tokens (text-safe accent, filled amber, page ground, shared radii,
/// overlay cover) live in `ui/tokens.css` with the palette. A surface that
/// restates `--accent-ink`, `--on-accent`, or `--page-bg` is the same defect
/// as restating `--accent`: two dark arms that drift. A surface that never
/// uses the ink token is not on the product vocabulary.
pub fn checkUiProductTokens(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tokens = root.readFileAlloc(io, "ui/tokens.css", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "ui/tokens.css: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(tokens);
    const live = try cssWithoutComments(gpa, tokens);
    defer gpa.free(live);
    const required = [_][]const u8{ "--accent-ink:", "--teal-ink:", "--accent-fill:", "--on-accent:", "--page-bg:", "--accent-line:", "--radius-control:", "--cover:", "--frost:", "--type-ui:" };
    for (required) |needle| {
        if (std.mem.indexOf(u8, live, needle) == null) {
            try appendViolation(gpa, violations, "ui/tokens.css: missing product token `{s}` (absent, or inside a comment so the browser never sees it)", .{needle[0 .. needle.len - 1]});
        }
    }

    const site = util.concatDirFiles(io, gpa, root, "site/assets", struct {
        fn keep(name: []const u8) bool {
            return std.mem.endsWith(u8, name, ".css") and !std.mem.eql(u8, name, "tokens.css") and !std.mem.eql(u8, name, "mark.css");
        }
    }.keep) catch null;
    if (site) |css| {
        defer gpa.free(css);
        try checkSurfaceInk(gpa, violations, "site/assets", css);
    } else {
        try appendViolation(gpa, violations, "site/assets: could not read the site stylesheets", .{});
    }

    const rooms = util.concatDirFiles(io, gpa, root, "apps/rooms/web/ui", struct {
        fn keep(name: []const u8) bool {
            return std.mem.endsWith(u8, name, ".css") and !std.mem.eql(u8, name, "tokens.css") and !std.mem.eql(u8, name, "mark.css");
        }
    }.keep) catch null;
    if (rooms) |css| {
        defer gpa.free(css);
        try checkSurfaceInk(gpa, violations, "apps/rooms/web/ui", css);
        if (std.mem.indexOf(u8, css, "var(--type-ui)") == null) {
            try appendViolation(gpa, violations, "apps/rooms/web/ui: never uses var(--type-ui); the product type ramp lives in ui/tokens.css", .{});
        }
    } else {
        try appendViolation(gpa, violations, "apps/rooms/web/ui: could not read the rooms stylesheets", .{});
    }
}

fn cssWithoutComments(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse src.len;
            const stop = if (end == src.len) src.len else end + 2;
            try out.appendNTimes(gpa, ' ', stop - i);
            i = stop;
            continue;
        }
        try out.append(gpa, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn checkSurfaceInk(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    css: []const u8,
) !void {
    if (std.mem.indexOf(u8, css, "var(--accent-ink)") == null) {
        try appendViolation(gpa, violations, "{s}: never uses var(--accent-ink); product text-safe accent lives in ui/tokens.css", .{path});
    }
    if (std.mem.indexOf(u8, css, "--accent-ink:") != null) {
        try appendViolation(gpa, violations, "{s}: restates --accent-ink; ui/tokens.css owns it", .{path});
    }
    if (std.mem.indexOf(u8, css, "var(--on-accent)") == null) {
        try appendViolation(gpa, violations, "{s}: never uses var(--on-accent); product ink on filled amber lives in ui/tokens.css", .{path});
    }
    if (std.mem.indexOf(u8, css, "--on-accent:") != null) {
        try appendViolation(gpa, violations, "{s}: restates --on-accent; ui/tokens.css owns it", .{path});
    }
    if (std.mem.indexOf(u8, css, "var(--page-bg)") == null) {
        try appendViolation(gpa, violations, "{s}: never uses var(--page-bg); product page ground lives in ui/tokens.css", .{path});
    }
    if (std.mem.indexOf(u8, css, "--page-bg:") != null) {
        try appendViolation(gpa, violations, "{s}: restates --page-bg; ui/tokens.css owns it", .{path});
    }
    if (std.mem.indexOf(u8, css, "var(--frost)") == null) {
        try appendViolation(gpa, violations, "{s}: never uses var(--frost); product chrome frost lives in ui/tokens.css", .{path});
    }
    if (std.mem.indexOf(u8, css, "var(--radius-card)") == null) {
        try appendViolation(gpa, violations, "{s}: never uses var(--radius-card); product card radius lives in ui/tokens.css", .{path});
    }
}

fn collectDecls(body: []const u8, out: *std.StringHashMap([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "--")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = trimmed[0..colon];
        var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.mem.endsWith(u8, value, ";")) value = value[0 .. value.len - 1];
        try out.put(name, std.mem.trim(u8, value, " \t"));
    }
}
