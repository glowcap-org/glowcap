//! Parameter names parsed from a generated C header — the name source the
//! binding generators share. Zig reflection strips parameter names; the
//! headers are generated from the same source and gate-held, so their names
//! are canonical.

const std = @import("std");

/// The parameter names of one prototype in `header`, split at top-level
/// commas, each name the last identifier of its declarator. Returns null when
/// the header has no such prototype.
pub fn headerParamNames(gpa: std.mem.Allocator, header: []const u8, name: []const u8) !?[][]const u8 {
    var search: usize = 0;
    const open = while (std.mem.indexOfPos(u8, header, search, name)) |at| {
        const after = at + name.len;
        search = after;
        // The prototype occurrence, not a comment mention: the name abuts
        // `(` on a line that starts at column 0 with the return type
        // (comment lines start with `/*` or indentation).
        if (after >= header.len or header[after] != '(') continue;
        const line_start = if (std.mem.lastIndexOfScalar(u8, header[0..at], '\n')) |nl| nl + 1 else 0;
        const first = header[line_start];
        if (first == ' ' or first == '/' or first == '*') continue;
        break after;
    } else return null;
    const close = std.mem.indexOfScalarPos(u8, header, open, ')') orelse return null;
    const params_text = header[open + 1 .. close];

    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    if (std.mem.eql(u8, std.mem.trim(u8, params_text, " \n"), "void")) {
        return try names.toOwnedSlice(gpa);
    }
    var it = std.mem.splitScalar(u8, params_text, ',');
    while (it.next()) |raw| {
        const param = std.mem.trim(u8, raw, " \n");
        // The name is the trailing identifier run.
        var end = param.len;
        while (end > 0 and !isIdent(param[end - 1])) end -= 1;
        var start = end;
        while (start > 0 and isIdent(param[start - 1])) start -= 1;
        try names.append(gpa, param[start..end]);
    }
    return try names.toOwnedSlice(gpa);
}

pub fn isIdent(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}
