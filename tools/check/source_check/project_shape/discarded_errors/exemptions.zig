//! The discards that need no marker: a call whose whole error set is a
//! bounded refusal, and a test's cleanup that runs under an `errdefer`.

const std = @import("std");
const scan = @import("../discarded_errors.zig");

/// Standard-library callees whose whole error set is a parse refusal, an
/// arithmetic refusal (overflow or division by zero), or a full buffer. A
/// value substituted at their call answers "not a number" or "does not fit"
/// and loses no allocation or I/O cause, so it needs no marker. A callee joins
/// this table only when that holds for every error it can return.
pub const pure_callees = [_][]const u8{
    "std.fmt.parseInt",
    "std.fmt.parseFloat",
    "std.fmt.charToDigit",
    "std.fmt.bufPrint",
    "std.math.add",
    "std.math.sub",
    "std.math.mul",
    "std.math.divCeil",
    "std.unicode.utf8ByteSequenceLength",
    "std.unicode.utf8Decode",
};

/// Standard-library pauses whose refusal loses nothing. A refused yield
/// returns sooner and the loop around it spins once more. `std.Io.sleep` is
/// absent on purpose: its error is the task's one cancel request, and a loop
/// that discards it keeps running after its owner asked it to stop.
pub const pause_callees = [_][]const u8{
    "std.Thread.yield",
};

/// True when `path` is test code. A test that is already failing reports its
/// first error, so a cleanup failure on that unwind has no second channel.
/// Library, application and example code has one (the diagnostic journal, or
/// a refusal the caller acts on), so an `errdefer` discard there keeps its
/// marker.
pub fn unwindNeedsNoMarker(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "test/") or
        std.mem.endsWith(u8, path, "_test.zig");
}

/// True when the code at `at` runs inside an `errdefer`, as its statement or
/// anywhere in its block, either arm of an `if` included.
pub fn underErrdefer(code: []const u8, at: usize) bool {
    var pos = at;
    while (true) {
        // Walk back to where this statement starts: after a `;`, after a
        // sibling block's `}`, or after the `{` that encloses it.
        var depth: usize = 0;
        var enclosing: ?usize = null;
        var closed: ?usize = null;
        var start: usize = 0;
        var i = pos;
        while (i > 0) {
            i -= 1;
            switch (code[i]) {
                ')', ']', '}' => depth += 1,
                '(', '[' => depth -|= 1,
                '{' => {
                    if (depth == 0) {
                        enclosing = i;
                        start = i + 1;
                        break;
                    }
                    depth -= 1;
                    // A `.{ ... }` or `Type{ ... }` literal is part of the
                    // statement. Any other closed block ends the statement
                    // before this one.
                    if (depth == 0 and (i == 0 or (code[i - 1] != '.' and !scan.identChar(code[i - 1])))) {
                        start = closingBrace(code, i) + 1;
                        closed = i;
                        break;
                    }
                },
                ';' => if (depth == 0) {
                    start = i + 1;
                    break;
                },
                else => {},
            }
        }
        const first = scan.skipSpace(code, start);
        if (scan.wordAt(code, first, "errdefer")) return true;
        // An `else` continues the statement that owns the block before it.
        if (closed) |open| if (scan.wordAt(code, first, "else")) {
            pos = open;
            continue;
        };
        pos = enclosing orelse (enclosingBrace(code, start) orelse return false);
    }
}

/// The index of the `}` that closes the `{` at `open`.
fn closingBrace(code: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < code.len) : (i += 1) switch (code[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return code.len - 1;
}

/// The nearest `{` before `from` whose block is still open there.
fn enclosingBrace(code: []const u8, from: usize) ?usize {
    var depth: usize = 0;
    var i = from;
    while (i > 0) {
        i -= 1;
        switch (code[i]) {
            '}' => depth += 1,
            '{' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// True when the expression right before the `catch` at `at` is a call to
/// one of `pure_callees` or `pause_callees`, even when its arguments span
/// lines.
pub fn exemptCallee(code: []const u8, at: usize) bool {
    var j = at;
    while (j > 0 and std.ascii.isWhitespace(code[j - 1])) j -= 1;
    if (j == 0 or code[j - 1] != ')') return false;
    var depth: usize = 0;
    while (j > 0) {
        j -= 1;
        switch (code[j]) {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    } else return false;
    const end = j;
    while (j > 0 and (scan.identChar(code[j - 1]) or code[j - 1] == '.')) j -= 1;
    const callee = code[j..end];
    for (pure_callees ++ pause_callees) |exempt| {
        if (std.mem.eql(u8, callee, exempt)) return true;
    }
    return false;
}
