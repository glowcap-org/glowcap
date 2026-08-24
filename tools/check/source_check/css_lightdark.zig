//! Every `light-dark()` use and every dark-theme rule in the owned
//! stylesheets stays behind an `@supports` guard on the function, with a
//! plain light-arm declaration outside it.

const std = @import("std");
const util = @import("util.zig");
const ui = @import("ui.zig");

const appendViolation = util.appendViolation;

/// `light-dark()` is unsupported on Safari through 17.4, Firefox through 119,
/// and every iOS 16 browser. A custom property accepts any value at parse
/// time, so on those browsers the failure is not a dropped declaration but a
/// palette that collapses to invalid at use time: unstyled text on unstyled
/// ground. The shape that degrades instead is the one these stylesheets
/// carry: the plain declaration holds the light arm, and `@supports (color:
/// light-dark(#000, #fff))` blocks restore the two-armed pairs and the
/// dark-theme machinery where the function exists, so a browser without it
/// keeps a complete light page. This check holds both halves of that shape:
/// every `light-dark(` outside a comment sits inside such a guard block (or
/// in a guard prelude, including the `@supports not` arm that retires an
/// inert control), and every custom property a guard block pairs with
/// `light-dark()` has a plain declaration outside every guard.
pub fn checkCssLightDarkGuard(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (ui.css_files) |path| {
        try checkFile(io, gpa, root, violations, path);
    }
    for (ui.css_dirs) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch {
            try appendViolation(gpa, violations, "{s}: could not be read", .{dir_path});
            continue;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (true) {
            const entry = (it.next(io) catch |err| {
                try appendViolation(
                    gpa,
                    violations,
                    "{s}: failed while listing stylesheets with {s}",
                    .{ dir_path, @errorName(err) },
                );
                break;
            }) orelse break;
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".css")) continue;
            // The symlinked copies are checked once at their canonical path.
            if (std.mem.eql(u8, entry.name, "tokens.css")) continue;
            if (std.mem.eql(u8, entry.name, "mark.css")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
            defer gpa.free(path);
            try checkFile(io, gpa, root, violations, path);
        }
    }
}

const probe = "(color: light-dark(#000, #fff))";
const call = "light-dark(";

const Span = struct { prelude: usize, body: usize, end: usize };

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const css = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(css);
    const bare = try commentsBlanked(gpa, css);
    defer gpa.free(bare);
    if (std.mem.indexOf(u8, bare, call) == null) return;

    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bare, i, "@supports")) |at| {
        const brace = std.mem.indexOfScalarPos(u8, bare, at, '{') orelse break;
        i = brace + 1;
        if (std.mem.indexOf(u8, bare[at..brace], probe) == null) continue;
        const end = blockEnd(bare, brace + 1) orelse {
            try appendViolation(
                gpa,
                violations,
                "{s}:{d}: light-dark() guard block never closes",
                .{ path, lineAt(bare, at) },
            );
            return;
        };
        try spans.append(gpa, .{ .prelude = at, .body = brace + 1, .end = end });
    }
    if (spans.items.len == 0) {
        try appendViolation(
            gpa,
            violations,
            "{s}: uses light-dark() with no `@supports {s}` fallback guard",
            .{ path, probe },
        );
        return;
    }

    // Every call outside a guard is a use a non-supporting browser resolves
    // to nothing. A guard prelude's own call is the exemption.
    i = 0;
    while (std.mem.indexOfPos(u8, bare, i, call)) |at| {
        i = at + call.len;
        var placed = false;
        for (spans.items) |s| {
            if (at >= s.prelude and at < s.end) {
                placed = true;
                break;
            }
        }
        if (placed) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}:{d}: light-dark() outside the @supports guard; move the pair into a guard block and leave the light arm as the plain declaration",
            .{ path, lineAt(bare, at) },
        );
    }

    // Every custom property a guard pairs with light-dark() needs its plain
    // light-arm twin outside every guard, or a non-supporting browser has no
    // value at all. Dark-only tokens a guard sets without the function are
    // theme state, not pairs, and owe no twin.
    for (spans.items) |s| {
        var j = s.body;
        while (nextCustomProperty(bare[0..s.end], j)) |prop| {
            j = prop.end;
            if (std.mem.indexOf(u8, valueOf(bare, prop.end, s.end), call) == null) continue;
            if (declaredOutside(bare, prop.name, spans.items)) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}:{d}: `{s}` pairs light-dark() only inside the guard; declare its light arm plainly outside it",
                .{ path, lineAt(bare, prop.start), prop.name },
            );
        }
    }
}

/// Comments blanked to spaces, so positions and line numbers survive.
fn commentsBlanked(gpa: std.mem.Allocator, css: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, css);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "/*")) |start| {
        const end = std.mem.indexOfPos(u8, out, start + 2, "*/") orelse out.len;
        const stop = @min(end + 2, out.len);
        for (out[start..stop]) |*c| {
            if (c.* != '\n') c.* = ' ';
        }
        i = stop;
    }
    return out;
}

fn blockEnd(css: []const u8, body_start: usize) ?usize {
    var depth: usize = 1;
    var i = body_start;
    while (i < css.len) : (i += 1) {
        switch (css[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

const CustomProperty = struct { name: []const u8, start: usize, end: usize };

fn nextCustomProperty(css: []const u8, from: usize) ?CustomProperty {
    var i = from;
    while (std.mem.indexOfPos(u8, css, i, "--")) |at| {
        var k = at + 2;
        while (k < css.len and isIdent(css[k])) k += 1;
        i = k;
        if (k == at + 2) continue;
        if (k < css.len and css[k] == ':') {
            return .{ .name = css[at..k], .start = at, .end = k };
        }
    }
    return null;
}

/// The declaration value from just past the `:` to its `;` or block edge.
fn valueOf(css: []const u8, colon_at: usize, limit: usize) []const u8 {
    var k = colon_at + 1;
    while (k < limit and css[k] != ';' and css[k] != '}') k += 1;
    return css[colon_at + 1 .. k];
}

fn declaredOutside(css: []const u8, name: []const u8, spans: []const Span) bool {
    var i: usize = 0;
    scan: while (std.mem.indexOfPos(u8, css, i, name)) |at| {
        i = at + name.len;
        for (spans) |s| {
            if (at >= s.prelude and at < s.end) continue :scan;
        }
        const end = at + name.len;
        if (end < css.len and css[end] == ':' and !(at > 0 and isIdent(css[at - 1]))) return true;
    }
    return false;
}

fn isIdent(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-';
}

fn lineAt(src: []const u8, at: usize) usize {
    var n: usize = 1;
    for (src[0..@min(at, src.len)]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}
