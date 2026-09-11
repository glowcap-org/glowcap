//! The mark's generated files, held to one geometry.
//!
//! The mushroom exists once, as the WebGPU shader in
//! `apps/rooms/web/ui/mark_gpu_field.ts`, and `zig build gen-mark` traces every
//! still picture of it out of one render: the artwork, the favicon cut from it,
//! the square raster, the masks and line drawing in `ui/tokens.css`, and the
//! placement in `ui/mark.css`. That step runs a real browser, so it is a
//! sibling of `check` and cannot answer here.
//!
//! What can answer here is the half that needs no browser. The committed files
//! all carry the same trace, so they can be held against each other: the
//! favicon draws mark.svg's own paths, each mask token carries the same path
//! data, each theme pair's dark arm is the tone mark.svg paints, and the
//! placement is arithmetic on mark.svg's own frame. A hand edit to any one of
//! them breaks one of those, so the drift shows in-tree rather than waiting
//! for the next run of the browser step.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

const mark_svg = "site/assets/mark.svg";
const favicon_svg = "site/assets/favicon.svg";
const lit_svg = "site/assets/mark-lit.svg";
const tokens_css = "ui/tokens.css";
const mark_css = "ui/mark.css";

/// The layers, back to front, and the token each one's tone is named by. The
/// order is the order the generator writes, and both files state it, so the
/// check reads them positionally rather than by search.
const layers = [_]struct { mask: []const u8, tone: []const u8 }{
    .{ .mask = "silhouette", .tone = "rim" },
    .{ .mask = "flesh", .tone = "body" },
    .{ .mask = "shade", .tone = "shadow" },
    .{ .mask = "windows", .tone = "window" },
};

/// How much larger the mushroom stands than the box it is given, matching
/// `GROW` in `apps/rooms/web/ui/mark_gpu_live.ts` and in
/// `tools/gen/mark/emit.ts`.
const grow = 1.2;

const Path = struct { fill: []const u8, d: []const u8 };

/// Every `<path fill="…" d="…"/>` of an SVG, in document order.
fn readPaths(gpa: std.mem.Allocator, svg: []const u8, out: *std.ArrayList(Path)) !void {
    var rest = svg;
    while (std.mem.indexOf(u8, rest, "<path fill=\"")) |at| {
        rest = rest[at + "<path fill=\"".len ..];
        const fill_end = std.mem.indexOfScalar(u8, rest, '"') orelse return;
        const fill = rest[0..fill_end];
        const d_at = std.mem.indexOf(u8, rest, " d=\"") orelse return;
        rest = rest[d_at + " d=\"".len ..];
        const d_end = std.mem.indexOfScalar(u8, rest, '"') orelse return;
        try out.append(gpa, .{ .fill = fill, .d = rest[0..d_end] });
        rest = rest[d_end..];
    }
}

/// The value of one `--name:` declaration, up to its semicolon.
fn declaration(css: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "--{s}: ", .{name}) catch return null;
    const at = std.mem.indexOf(u8, css, needle) orelse return null;
    const from = at + needle.len;
    const end = std.mem.indexOfScalar(u8, css[from..], ';') orelse return null;
    return css[from .. from + end];
}

/// The last `--name:` declaration, which is the themed pair: the plain light
/// arm is written first in `:root`, and the `light-dark()` pair follows in the
/// guarded block.
fn lastDeclaration(css: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "--{s}: ", .{name}) catch return null;
    const at = std.mem.lastIndexOf(u8, css, needle) orelse return null;
    const from = at + needle.len;
    const end = std.mem.indexOfScalar(u8, css[from..], ';') orelse return null;
    return css[from .. from + end];
}

fn viewBox(svg: []const u8) ?[4]f64 {
    const at = std.mem.indexOf(u8, svg, "viewBox=\"") orelse return null;
    const from = at + "viewBox=\"".len;
    const end = std.mem.indexOfScalar(u8, svg[from..], '"') orelse return null;
    var it = std.mem.tokenizeScalar(u8, svg[from .. from + end], ' ');
    var out: [4]f64 = undefined;
    for (&out) |*slot| {
        const word = it.next() orelse return null;
        slot.* = std.fmt.parseFloat(f64, word) catch return null;
    }
    if (it.next() != null) return null;
    return out;
}

/// A percentage written the way the generator writes it: rounded to four
/// decimals, then as short as it can be spelled.
fn percent(gpa: std.mem.Allocator, of_box: f64) ![]u8 {
    const rounded = @round((of_box / 24.0) * 100.0 * 10000.0) / 10000.0;
    return std.fmt.allocPrint(gpa, "{d}%", .{rounded});
}

/// The mark's generated files carry one trace between them.
pub fn checkMarkAssets(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const svg = root.readFileAlloc(io, mark_svg, gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: could not be read; it is the mark's artwork, and every other still picture is cut from it", .{mark_svg});
        return;
    };
    defer gpa.free(svg);

    var drawn: std.ArrayList(Path) = .empty;
    defer drawn.deinit(gpa);
    try readPaths(gpa, svg, &drawn);
    if (drawn.items.len != layers.len) {
        try appendViolation(gpa, violations, "{s}: has {d} paths, not the {d} the trace writes; run `zig build gen-mark`", .{ mark_svg, drawn.items.len, layers.len });
        return;
    }

    // Every generated file says so in its own first lines, naming the step
    // that writes it, so a reader who opens one is told before editing.
    for ([_][]const u8{ mark_svg, favicon_svg, lit_svg }) |path| {
        try util.expectFileContains(io, gpa, root, violations, path, &.{"GENERATED by `zig build gen-mark`"});
    }

    // The favicon is the same drawing in a squarer frame, so it carries
    // mark.svg's own paths, tone for tone.
    const favicon = root.readFileAlloc(io, favicon_svg, gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: could not be read for the mark check", .{favicon_svg});
        return;
    };
    defer gpa.free(favicon);
    var cut: std.ArrayList(Path) = .empty;
    defer cut.deinit(gpa);
    try readPaths(gpa, favicon, &cut);
    if (cut.items.len != drawn.items.len) {
        try appendViolation(gpa, violations, "{s}: has {d} paths where {s} has {d}; both are one trace, so run `zig build gen-mark`", .{ favicon_svg, cut.items.len, mark_svg, drawn.items.len });
    } else for (cut.items, drawn.items, 0..) |a, b, i| {
        if (!std.mem.eql(u8, a.d, b.d) or !std.mem.eql(u8, a.fill, b.fill)) {
            try appendViolation(gpa, violations, "{s}: the {s} path is not {s}'s; the favicon is cut from the artwork, so run `zig build gen-mark`", .{ favicon_svg, layers[i].mask, mark_svg });
        }
    }

    // The lit reading is the same mushroom with its lamps on, so its body is
    // the artwork's own three lower paths in order. Its tones differ, because
    // they are measured with the lamps burning, and its lamps are geometry the
    // unlit drawing does not have, so only the path data is held here.
    const glowing = root.readFileAlloc(io, lit_svg, gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: could not be read for the mark check", .{lit_svg});
        return;
    };
    defer gpa.free(glowing);
    var glow_paths: std.ArrayList(Path) = .empty;
    defer glow_paths.deinit(gpa);
    try readPaths(gpa, glowing, &glow_paths);
    const body = layers.len - 1;
    if (glow_paths.items.len < body) {
        try appendViolation(gpa, violations, "{s}: has {d} paths, too few to carry {s}'s body; run `zig build gen-mark`", .{ lit_svg, glow_paths.items.len, mark_svg });
    } else {
        // The rim is drawn twice, once blurred as its own bloom and once
        // solid, so the body reads as the bloom then the three layers.
        for (glow_paths.items[1 .. body + 1], drawn.items[0..body], 0..) |a, b, i| {
            if (!std.mem.eql(u8, a.d, b.d)) {
                try appendViolation(gpa, violations, "{s}: the {s} path is not {s}'s; the lit mark is the same mushroom, so run `zig build gen-mark`", .{ lit_svg, layers[i].mask, mark_svg });
            }
        }
    }

    const tokens = root.readFileAlloc(io, tokens_css, gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: could not be read for the mark check", .{tokens_css});
        return;
    };
    defer gpa.free(tokens);

    for (layers, drawn.items) |layer, path| {
        // The mask value is the same path data inside a data URI, and the
        // generator's encoding leaves path data alone, so it appears verbatim.
        var name_buf: [64]u8 = undefined;
        const mask_name = try std.fmt.bufPrint(&name_buf, "mark-{s}", .{layer.mask});
        if (declaration(tokens, mask_name)) |value| {
            if (std.mem.indexOf(u8, value, path.d) == null) {
                try appendViolation(gpa, violations, "{s}: `--{s}` does not carry {s}'s {s} path; run `zig build gen-mark`", .{ tokens_css, mask_name, mark_svg, layer.mask });
            }
        } else {
            try appendViolation(gpa, violations, "{s}: `--{s}` is gone; the mark's four masks are one geometry with {s}", .{ tokens_css, mask_name, mark_svg });
        }

        // The tone pair's dark arm is the color mark.svg paints that layer,
        // because the artwork holds the night tones and the pair holds both.
        var tone_buf: [64]u8 = undefined;
        const tone_name = try std.fmt.bufPrint(&tone_buf, "mark-{s}", .{layer.tone});
        const pair = lastDeclaration(tokens, tone_name) orelse {
            try appendViolation(gpa, violations, "{s}: `--{s}` is gone; it is the {s} layer's tone in both themes", .{ tokens_css, tone_name, layer.mask });
            continue;
        };
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, ", {s})", .{path.fill});
        if (!std.mem.startsWith(u8, pair, "light-dark(") or std.mem.indexOf(u8, pair, expected) == null) {
            try appendViolation(gpa, violations, "{s}: `--{s}` does not pair with {s}, the tone {s} paints its {s}; run `zig build gen-mark`", .{ tokens_css, tone_name, path.fill, mark_svg, layer.mask });
        }
    }

    // The pieces are placed by arithmetic on the artwork's own frame, so the
    // still mark and the shader mark stand in the same pixels. A hand-nudged
    // percentage here moves one and not the other.
    const box = viewBox(svg) orelse {
        try appendViolation(gpa, violations, "{s}: its viewBox is unreadable; the placement in {s} is arithmetic on it", .{ mark_svg, mark_css });
        return;
    };
    const css = root.readFileAlloc(io, mark_css, gpa, .limited(1 << 20)) catch {
        try appendViolation(gpa, violations, "{s}: could not be read for the mark check", .{mark_css});
        return;
    };
    defer gpa.free(css);
    const grown = struct {
        fn at(v: f64) f64 {
            return 12.0 + (v - 12.0) * grow;
        }
    };
    const places = [_]struct { name: []const u8, value: f64 }{
        .{ .name = "left", .value = grown.at(box[0]) },
        .{ .name = "top", .value = grown.at(box[1]) },
        .{ .name = "width", .value = box[2] * grow },
        .{ .name = "height", .value = box[3] * grow },
    };
    for (places) |place| {
        const want = try percent(gpa, place.value);
        defer gpa.free(want);
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\t{s}: {s};", .{ place.name, want });
        if (std.mem.indexOf(u8, css, needle) == null) {
            try appendViolation(gpa, violations, "{s}: the mark piece's `{s}` is not `{s}`, the share of a 24-unit box {s}'s frame grows to; run `zig build gen-mark`", .{ mark_css, place.name, want, mark_svg });
        }
    }
}

test "the paths of an SVG are read in document order" {
    const gpa = std.testing.allocator;
    var paths: std.ArrayList(Path) = .empty;
    defer paths.deinit(gpa);
    const svg = "<svg viewBox=\"0 0 1 1\">\n" ++
        "\t<path fill=\"#aabbcc\" fill-rule=\"evenodd\" d=\"M0 0Z\"/>\n" ++
        "\t<path fill=\"#112233\" fill-rule=\"evenodd\" d=\"M1 1Z\"/>\n" ++
        "</svg>\n";
    try readPaths(gpa, svg, &paths);
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("#aabbcc", paths.items[0].fill);
    try std.testing.expectEqualStrings("M1 1Z", paths.items[1].d);
}

test "a view box parses to its four numbers" {
    const box = viewBox("<svg viewBox=\"-1.3 3.6 23.5 19.7\">").?;
    try std.testing.expectApproxEqAbs(@as(f64, -1.3), box[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 19.7), box[3], 1e-9);
    try std.testing.expect(viewBox("<svg viewBox=\"1 2 3\">") == null);
}

test "a placement percentage is spelled the way the generator spells it" {
    const gpa = std.testing.allocator;
    const left = try percent(gpa, 12.0 + (-1.3 - 12.0) * grow);
    defer gpa.free(left);
    try std.testing.expectEqualStrings("-16.5%", left);
    const height = try percent(gpa, 19.7 * grow);
    defer gpa.free(height);
    try std.testing.expectEqualStrings("98.5%", height);
}
