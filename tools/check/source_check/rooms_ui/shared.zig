//! Shared rooms-UI check vocabulary: the interface directory, concatenated
//! stylesheets, and comment-stripped source. Selector proofs, layer bans, and
//! config checks each import this rather than owning a copy.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

pub const ui_dir = "apps/rooms/web/ui";

pub fn keepRoomsSheet(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".css") and !std.mem.eql(u8, name, "tokens.css");
}

pub fn loadRoomsCss(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !?[]u8 {
    const sheet = util.concatDirFiles(io, gpa, root, ui_dir, keepRoomsSheet) catch {
        try appendViolation(gpa, violations, "{s}: failed to concatenate rooms stylesheets", .{ui_dir});
        return null;
    };
    if (sheet == null) {
        try appendViolation(gpa, violations, "{s}: could not read the rooms stylesheets", .{ui_dir});
    }
    return sheet;
}

/// The source with its comments removed.
///
/// A ban that fires on prose is a ban people learn to write around, and these
/// modules explain themselves at length — the store's own header names
/// `document.hidden` to say which module reads it. Strings are stepped over so a
/// quoted `//` does not start a comment. It errs toward keeping too little
/// rather than too much: an over-strip makes a ban miss, which is a check that
/// under-reports, and a false alarm is the failure that costs a gate its
/// authority.
pub fn codeOnly(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (quote != 0) {
            try out.append(gpa, c);
            if (c == '\\' and i + 1 < source.len) {
                try out.append(gpa, source[i + 1]);
                i += 2;
                continue;
            }
            if (c == quote) quote = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i = @min(i + 2, source.len);
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}
