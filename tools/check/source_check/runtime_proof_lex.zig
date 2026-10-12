//! The language toolkit under the runtime-proof check: prose stripping,
//! identifier lexing, and definition-ownership attribution for the Python
//! and Racket sources it walks.

const std = @import("std");

pub const Lang = enum { python, racket };

/// Blank out comments and string bodies. Prose is where a verb's name is most
/// often written without being called: the Python `enroll` this check was built
/// for was named in three neighbouring docstrings and called from nowhere, and a
/// scan that reads prose as code believes them.
pub fn stripProse(arena: std.mem.Allocator, lang: Lang, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len);
    @memset(out, ' ');
    const line_comment: u8 = switch (lang) {
        .python => '#',
        .racket => ';',
    };
    // A Python docstring is the one construct here that spans lines.
    var block: ?[]const u8 = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') {
            out[i] = '\n';
            i += 1;
            continue;
        }
        if (block) |close| {
            if (std.mem.startsWith(u8, text[i..], close)) {
                block = null;
                i += close.len;
            } else i += 1;
            continue;
        }
        if (lang == .python and (std.mem.startsWith(u8, text[i..], "\"\"\"") or std.mem.startsWith(u8, text[i..], "'''"))) {
            block = text[i .. i + 3];
            i += 3;
            continue;
        }
        if (ch == line_comment) {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        // Racket's `'` quotes a datum; only Python spells a string with it.
        if (ch == '"' or (ch == '\'' and lang == .python)) {
            i += 1;
            while (i < text.len and text[i] != '\n') {
                if (text[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (text[i] == ch) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        out[i] = ch;
        i += 1;
    }
    return out;
}

pub const IdentIter = struct {
    lang: Lang,
    rest: []const u8,

    pub fn isStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    pub fn isPart(lang: Lang, ch: u8) bool {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') return true;
        // A Racket name runs through its dashes and its `!?*<>=/+`, so
        // `session-release!` must not lex as `session` plus `release`.
        return lang == .racket and switch (ch) {
            '-', '!', '?', '*', '<', '>', '=', '/', '+' => true,
            else => false,
        };
    }

    pub fn next(self: *IdentIter) ?[]const u8 {
        var i: usize = 0;
        while (i < self.rest.len and !isStart(self.rest[i])) i += 1;
        if (i == self.rest.len) return null;
        var end = i + 1;
        while (end < self.rest.len and isPart(self.lang, self.rest[end])) end += 1;
        const ident = self.rest[i..end];
        self.rest = self.rest[end..];
        return ident;
    }
};

/// What owns a line: a chain of enclosing definitions, module-init code, or a
/// form that names wrappers without running them.
pub const Owner = union(enum) {
    inert,
    module,
    /// Outermost-first chain of enclosing definition names.
    definition: []const []const u8,
};

/// One forward pass giving each line its owner. Python nests by indentation, so
/// a stack of indent-and-name pairs tracks the chain and a multi-line `def`
/// header is held open until its parentheses balance. Racket indents every body,
/// so a column-zero `(` opens the next top-level form and only a `define` form
/// owns the lines beneath it.
pub const Owners = struct {
    lang: Lang,
    stack_indent: [max_depth]usize = undefined,
    stack_name: [max_depth][]const u8 = undefined,
    depth: usize = 0,
    /// Parentheses left open by a `def` header or an `import` clause.
    pending: isize = 0,
    /// Racket: the open top-level form, when it is a `define`.
    current: ?[]const u8 = null,
    /// Racket: the open top-level form is a `provide` or `require` clause.
    inert: bool = false,
    /// Python: an `import` clause spanning lines.
    importing: bool = false,

    /// Deeper nesting than this stops tracking rather than growing. A
    /// twelve-deep wrapper is not a shape either binding writes.
    const max_depth = 12;

    pub fn init(lang: Lang) Owners {
        return .{ .lang = lang };
    }

    pub fn advance(self: *Owners, line: []const u8) Owner {
        return switch (self.lang) {
            .python => self.advancePython(line),
            .racket => self.advanceRacket(line),
        };
    }

    pub fn advancePython(self: *Owners, line: []const u8) Owner {
        if (self.importing) {
            self.pending += parenDelta(line);
            if (self.pending <= 0) {
                self.importing = false;
                self.pending = 0;
            }
            return .inert;
        }
        if (self.pending > 0) {
            self.pending += parenDelta(line);
            if (self.pending < 0) self.pending = 0;
            return self.chain();
        }
        const body = std.mem.trimStart(u8, line, " \t");
        if (body.len == 0) return self.chain();
        const indent = line.len - body.len;
        while (self.depth > 0 and self.stack_indent[self.depth - 1] >= indent) self.depth -= 1;

        if (self.depth == 0 and (std.mem.startsWith(u8, body, "import ") or std.mem.startsWith(u8, body, "from "))) {
            self.pending = parenDelta(line);
            self.importing = self.pending > 0;
            return .inert;
        }
        if (pythonDefName(body)) |name| {
            if (self.depth < max_depth) {
                self.stack_indent[self.depth] = indent;
                self.stack_name[self.depth] = name;
                self.depth += 1;
            }
            self.pending = parenDelta(line);
            if (self.pending < 0) self.pending = 0;
        }
        return self.chain();
    }

    pub fn advanceRacket(self: *Owners, line: []const u8) Owner {
        if (line.len != 0 and line[0] == '(') {
            const head = line[1..];
            self.inert = racketFormIs(head, "provide") or racketFormIs(head, "require");
            self.current = racketDefineName(head);
        }
        if (self.inert) return .inert;
        if (self.current) |name| {
            self.stack_name[0] = name;
            return .{ .definition = self.stack_name[0..1] };
        }
        return .module;
    }

    pub fn chain(self: *Owners) Owner {
        if (self.depth == 0) return .module;
        return .{ .definition = self.stack_name[0..self.depth] };
    }
};

fn racketFormIs(head: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, head, name)) return false;
    return head.len == name.len or !IdentIter.isPart(.racket, head[name.len]);
}

pub fn parenDelta(line: []const u8) isize {
    var delta: isize = 0;
    for (line) |ch| {
        if (ch == '(') delta += 1;
        if (ch == ')') delta -= 1;
    }
    return delta;
}

pub fn pythonDefName(body: []const u8) ?[]const u8 {
    var rest = body;
    if (std.mem.startsWith(u8, rest, "async ")) rest = std.mem.trimStart(u8, rest["async ".len..], " ");
    if (!std.mem.startsWith(u8, rest, "def ")) return null;
    const after = std.mem.trimStart(u8, rest["def ".len..], " ");
    var end: usize = 0;
    while (end < after.len and (std.ascii.isAlphanumeric(after[end]) or after[end] == '_')) end += 1;
    return if (end == 0) null else after[0..end];
}

/// The name bound by a column-zero `(define…)` form: `(define (f x) …)`,
/// `(define f …)`, and the `define-values` / `define-syntax-rule` siblings.
pub fn racketDefineName(head: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, head, "define")) return null;
    var i: usize = "define".len;
    while (i < head.len and head[i] != ' ' and head[i] != '\t') i += 1;
    while (i < head.len and (head[i] == ' ' or head[i] == '\t' or head[i] == '(')) i += 1;
    if (i >= head.len or !IdentIter.isStart(head[i])) return null;
    var end = i;
    while (end < head.len and IdentIter.isPart(.racket, head[end])) end += 1;
    return head[i..end];
}

test "a python def line belongs to itself, not to the sibling above it" {
    var owners = Owners.init(.python);
    const lines = [_][]const u8{
        "class Session:",
        "    def with_gc(self):",
        "        return self",
        "    def enroll(self, ref):",
        "        return call(ref)",
    };
    var last: Owner = .module;
    for (lines) |line| last = owners.advance(line);
    try std.testing.expectEqualStrings("enroll", last.definition[last.definition.len - 1]);
}

test "a multi-line python def header stays open" {
    var owners = Owners.init(.python);
    const lines = [_][]const u8{
        "    def establish_accepted(",
        "        self,",
        "    ) -> Session:",
        "        return plan(self)",
    };
    var last: Owner = .module;
    for (lines) |line| last = owners.advance(line);
    try std.testing.expectEqualStrings("establish_accepted", last.definition[last.definition.len - 1]);
}

test "a racket provide clause owns nothing" {
    var owners = Owners.init(.racket);
    try std.testing.expect(owners.advance("(provide session-release!") == .inert);
    try std.testing.expect(owners.advance("         session-close!)") == .inert);
    const owned = owners.advance("(define (session-release! c ref)");
    try std.testing.expectEqualStrings("session-release!", owned.definition[0]);
    const body = owners.advance("  (glowcap_host_ref_release c ref))");
    try std.testing.expectEqualStrings("session-release!", body.definition[0]);
}

test "a Racket helper whose name starts with require remains executable" {
    var owners = Owners.init(.racket);
    try std.testing.expectEqual(Owner.module, owners.advance("(require-archive-fingerprint!"));
    try std.testing.expectEqual(Owner.module, owners.advance(" 'host read expected)"));
}

test "a racket identifier lexes through its dashes and its bang" {
    var it = IdentIter{ .lang = .racket, .rest = "(session-release! to-exporter offered)" };
    try std.testing.expectEqualStrings("session-release!", it.next().?);
    try std.testing.expectEqualStrings("to-exporter", it.next().?);
    try std.testing.expectEqualStrings("offered", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "prose cannot forge a call" {
    const gpa = std.testing.allocator;
    const python = try stripProse(gpa, .python, "x = 1  # calls enroll\n\"\"\"names enroll\"\"\"\ny = enroll\n");
    defer gpa.free(python);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, python, "enroll"));
    const racket = try stripProse(gpa, .racket, ";; names session-get\n(session-get c)\n");
    defer gpa.free(racket);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, racket, "session-get"));
}
