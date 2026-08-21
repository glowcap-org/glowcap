//! Lexical primitives for the build-execution source checks.
//!
//! These retain Zig token offsets while hiding prose and literals, then expose
//! balanced-call arguments to the two semantic owners. They do not decide
//! whether a process or Zig test posture is valid.

const std = @import("std");

/// Retain Zig code tokens at their original offsets while blanking strings,
/// character literals, and documentation comments. Ordinary comments are
/// already skipped by the tokenizer.
pub fn codeOnly(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    const code = try gpa.alloc(u8, source.len);
    errdefer gpa.free(code);
    @memset(code, ' ');
    const terminated = try gpa.dupeSentinel(u8, source, 0);
    defer gpa.free(terminated);
    var tokenizer = std.zig.Tokenizer.init(terminated);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        switch (token.tag) {
            .doc_comment,
            .container_doc_comment,
            .string_literal,
            .multiline_string_literal_line,
            .char_literal,
            => {},
            else => @memcpy(code[token.loc.start..token.loc.end], source[token.loc.start..token.loc.end]),
        }
    }
    return code;
}

pub fn leadingIdentifier(text: []const u8) ?[]const u8 {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return null;
    var end: usize = 1;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) end += 1;
    return text[0..end];
}

pub fn assignedConstName(source: []const u8, call_at: usize) ?[]const u8 {
    const statement_start = if (std.mem.lastIndexOfScalar(u8, source[0..call_at], ';')) |semi| semi + 1 else 0;
    const statement = source[statement_start..call_at];
    const const_at = std.mem.lastIndexOf(u8, statement, "const ") orelse return null;
    const after_const = statement[const_at + "const ".len ..];
    const name = leadingIdentifier(after_const) orelse return null;
    if (std.mem.indexOfScalar(u8, after_const[name.len..], '=') == null) return null;
    return name;
}

pub fn matchingDelimiter(text: []const u8, open: usize, open_byte: u8, close_byte: u8) ?usize {
    if (open >= text.len or text[open] != open_byte) return null;
    var depth: usize = 1;
    var index = open + 1;
    while (index < text.len) : (index += 1) {
        if (text[index] == open_byte) depth += 1;
        if (text[index] == close_byte) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

pub fn nthTopLevelArg(text: []const u8, wanted: usize) ?[]const u8 {
    var parens: usize = 0;
    var braces: usize = 0;
    var brackets: usize = 0;
    var start: usize = 0;
    var arg: usize = 0;
    for (text, 0..) |byte, index| {
        switch (byte) {
            '(' => parens += 1,
            ')' => parens -= 1,
            '{' => braces += 1,
            '}' => braces -= 1,
            '[' => brackets += 1,
            ']' => brackets -= 1,
            ',' => if (parens == 0 and braces == 0 and brackets == 0) {
                if (arg == wanted) return text[start..index];
                arg += 1;
                start = index + 1;
            },
            else => {},
        }
    }
    return if (arg == wanted) text[start..] else null;
}

pub fn splitThreeTopLevel(text: []const u8, out: *[3][]const u8) usize {
    var parens: usize = 0;
    var braces: usize = 0;
    var start: usize = 0;
    var count: usize = 0;
    for (text, 0..) |byte, index| {
        switch (byte) {
            '(' => parens += 1,
            ')' => parens -= 1,
            '{' => braces += 1,
            '}' => braces -= 1,
            ',' => if (parens == 0 and braces == 0) {
                if (count < out.len) out[count] = text[start..index];
                count += 1;
                start = index + 1;
            },
            else => {},
        }
    }
    if (count < out.len) out[count] = text[start..];
    return count + 1;
}
