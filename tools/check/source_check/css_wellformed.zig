//! CSS well-formedness over the owned stylesheets: balanced braces, no
//! comment hiding a declaration, and the faults reported at their line.

const std = @import("std");
const util = @import("util.zig");
const ui = @import("ui.zig");

const appendViolation = util.appendViolation;

/// CSS has no `deno check`. An unclosed `/*` or `{` does not fail a build; the
/// browser drops every declaration after it, which looks like a theme bug
/// (wrong ink, square icon buttons, missing dimmers) rather than a syntax
/// error. Walk every product stylesheet the same way `Scanner` already walks
/// one block: comments and strings skipped whole, braces balanced, an unclosed
/// construct named with its line.
pub fn checkCssWellFormed(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (ui.css_files) |path| {
        try checkCssFile(io, gpa, root, violations, path);
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
            if (std.mem.eql(u8, entry.name, "tokens.css")) continue;
            if (std.mem.eql(u8, entry.name, "mark.css")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
            defer gpa.free(path);
            try checkCssFile(io, gpa, root, violations, path);
        }
    }
}

fn checkCssFile(
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
    if (cssFault(css)) |fault| {
        try appendViolation(gpa, violations, "{s}:{d}: {s}", .{ path, lineAt(css, fault.at), fault.why });
    }
}

const CssFault = struct { at: usize, why: []const u8 };

fn cssFault(css: []const u8) ?CssFault {
    var i: usize = 0;
    var depth: usize = 0;
    var open_at: usize = 0;
    while (i < css.len) {
        const c = css[i];
        if (c == '/' and i + 1 < css.len and css[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, css, i + 2, "*/") orelse
                return .{ .at = i, .why = "unclosed `/*` comment; declarations after it never apply" };
            const body = css[i + 2 .. end];
            if (commentHidesDeclaration(body)) |rel| {
                return .{
                    .at = i + 2 + rel,
                    .why = "comment contains a `--token:` declaration; the browser will not apply it (usually a dropped `*/` that swallowed the next block)",
                };
            }
            i = end + 2;
            continue;
        }
        if (c == '"' or c == '\'') {
            const start = i;
            i += 1;
            while (i < css.len and css[i] != c) {
                i += if (css[i] == '\\') @as(usize, 2) else 1;
            }
            if (i >= css.len) return .{ .at = start, .why = "unclosed quoted string; the rest of the sheet is inside it" };
            i += 1;
            continue;
        }
        if (c == '{') {
            if (depth == 0) open_at = i;
            depth += 1;
        } else if (c == '}') {
            if (depth == 0) return .{ .at = i, .why = "unmatched `}`; a rule closed more braces than it opened" };
            depth -= 1;
        }
        i += 1;
    }
    if (depth != 0) return .{ .at = open_at, .why = "unclosed `{`; declarations after this block never apply" };
    return null;
}

fn commentHidesDeclaration(body: []const u8) ?usize {
    var j: usize = 0;
    while (j + 3 < body.len) : (j += 1) {
        if (body[j] != '-' or body[j + 1] != '-') continue;
        var k = j + 2;
        var n: usize = 0;
        while (k < body.len) : (k += 1) {
            const c = body[k];
            const ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-';
            if (!ident) break;
            n += 1;
        }
        if (n > 0 and k < body.len and body[k] == ':') return j;
    }
    return null;
}

fn lineAt(src: []const u8, at: usize) usize {
    var n: usize = 1;
    const end = @min(at, src.len);
    for (src[0..end]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}
