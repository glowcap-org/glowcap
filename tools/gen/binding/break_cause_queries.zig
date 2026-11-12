//! Render the core's predicate cases in each binding's expression syntax.
const std = @import("std");
const s = @import("break_cause_schema.zig");
const Buffer = s.Buffer;
const Query = s.Cause.Query;
pub const Language = enum { rust, ts, python, racket };

fn enumValue(out: *Buffer, a: std.mem.Allocator, language: Language, kind: []const u8, name: []const u8) !void {
    switch (language) {
        .rust, .ts => {
            try out.print(a, "Break{s}{s}", .{ kind, if (language == .rust) "::" else "." });
            try s.pascal(out, a, name);
        },
        .python => {
            try out.print(a, "Break{s}.", .{kind});
            try s.upper(out, a, name);
        },
        .racket => {
            try out.append(a, '\'');
            try s.kebab(out, a, name);
        },
    }
}

fn compare(out: *Buffer, a: std.mem.Allocator, language: Language, field: []const u8, kind: []const u8, name: []const u8) !void {
    if (language == .racket) {
        try out.print(a, "(eq? (break-cause-{s} value) ", .{field});
    } else try out.print(a, "{s}.{s} {s} ", .{ if (language == .ts) "this" else "self", field, if (language == .ts) "===" else "==" });
    try enumValue(out, a, language, kind, name);
    if (language == .racket) try out.append(a, ')');
}

fn expression(out: *Buffer, a: std.mem.Allocator, language: Language, comptime query: Query, wrap_rust: bool) !void {
    const conjunction = switch (language) {
        .rust => if (wrap_rust and query.cases().len == 1) "\n\t\t\t&& " else " && ",
        .ts => " && ",
        .python => " and ",
        .racket => " ",
    };
    const disjunction = switch (language) {
        .rust, .ts => " || ",
        .python => " or ",
        .racket => " ",
    };
    if (language == .racket) try out.appendSlice(a, "(or ");
    inline for (comptime query.cases(), 0..) |candidate, i| {
        if (i != 0) try out.appendSlice(a, if (wrap_rust) "\n\t\t\t|| " else disjunction);
        if (language == .racket) try out.appendSlice(a, "(and ");
        try compare(out, a, language, "origin", "Origin", @tagName(candidate.origin));
        try out.appendSlice(a, conjunction);
        if (language == .racket or candidate.reasons.len > 1) try out.appendSlice(a, if (language == .racket) "(or " else "(");
        inline for (candidate.reasons, 0..) |reason, j| {
            if (j != 0) try out.appendSlice(a, disjunction);
            try compare(out, a, language, "reason", "Reason", @tagName(reason));
        }
        if (language == .racket or candidate.reasons.len > 1) try out.append(a, ')');
        try out.appendSlice(a, conjunction);
        const entire = candidate.context_mask == s.context_mask;
        if (language == .racket) {
            if (entire) {
                try out.print(a, "(= (break-cause-context value) {d})", .{candidate.context});
            } else try out.print(a, "(= (bitwise-and (break-cause-context value) {d}) {d})", .{ candidate.context_mask, candidate.context });
        } else {
            const field = switch (language) {
                .rust => "self.context.raw()",
                .ts => "this.context",
                .python => "self.context",
                .racket => unreachable,
            };
            if (entire) {
                try out.appendSlice(a, field);
            } else try out.print(a, "({s} & {d})", .{ field, candidate.context_mask });
            try out.print(a, " {s} {d}", .{ if (language == .ts) "===" else "==", candidate.context });
        }
        if (language == .racket) try out.append(a, ')');
    }
    if (language == .racket) try out.append(a, ')');
}

pub fn generate(out: *Buffer, a: std.mem.Allocator, language: Language) !void {
    inline for (std.enums.values(Query)) |query| {
        const name = @tagName(query);
        switch (language) {
            .rust => try out.print(a, "\n\tpub fn is_{s}(self) -> bool {{\n\t\t", .{name}),
            .ts => {
                try out.appendSlice(a, "\n    is");
                try s.pascal(out, a, name);
                try out.appendSlice(a, "(): boolean {\n        return ");
            },
            .python => try out.print(a, "\n    def is_{s}(self) -> bool:\n        return ", .{name}),
            .racket => {
                try out.appendSlice(a, "\n(provide break-cause-");
                try s.kebab(out, a, name);
                try out.appendSlice(a, "?)\n(define (break-cause-");
                try s.kebab(out, a, name);
                try out.appendSlice(a, "? value)\n  (and (break-cause? value) ");
            },
        }
        if (language == .rust) {
            var body: Buffer = .empty;
            defer body.deinit(a);
            // Rust allows 120 columns, with eight columns already indented.
            try expression(&body, a, language, query, false);
            if (body.items.len <= 112) {
                try out.appendSlice(a, body.items);
            } else try expression(out, a, language, query, true);
        } else try expression(out, a, language, query, false);
        try out.appendSlice(a, switch (language) {
            .rust => "\n\t}\n",
            .ts => ";\n    }\n",
            .python => "\n",
            .racket => "))\n",
        });
    }
    try messageQuery(out, a, language);
}

/// Wire text is interpreted only after a core query establishes its provenance.
/// This two-case rule is shared by all bindings. Local misses need no text match.
fn messageQuery(out: *Buffer, a: std.mem.Allocator, language: Language) !void {
    const Case = struct { query: Query, message: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .query = .publication_absent },
        .{ .query = .publication_refusal, .message = "UNKNOWN_SWISSNUM_MESSAGE" },
    };
    try out.appendSlice(a, switch (language) {
        .rust => "\n\tpub fn is_publication_not_found(self, message: Option<&str>) -> bool {\n\t\t",
        .ts => "\n    isPublicationNotFound(message: string): boolean {\n        return ",
        .python => "\n    def is_publication_not_found(self, message: str | None) -> bool:\n        return ",
        .racket => "\n(provide break-cause-publication-not-found?)\n(define (break-cause-publication-not-found? value message)\n  (or ",
    });
    inline for (cases, 0..) |candidate, i| {
        if (i != 0) try out.appendSlice(a, switch (language) {
            .rust, .ts => " || ",
            .python => " or ",
            .racket => " ",
        });
        if (candidate.message != null) try out.appendSlice(a, if (language == .racket) "(and " else "(");
        switch (language) {
            .rust, .python => try out.print(a, "self.is_{s}()", .{@tagName(candidate.query)}),
            .ts => {
                try out.appendSlice(a, "this.is");
                try s.pascal(out, a, @tagName(candidate.query));
                try out.appendSlice(a, "()");
            },
            .racket => {
                try out.appendSlice(a, "(break-cause-");
                try s.kebab(out, a, @tagName(candidate.query));
                try out.appendSlice(a, "? value)");
            },
        }
        if (candidate.message) |constant| {
            try out.appendSlice(a, switch (language) {
                .rust => " && message == Some(",
                .ts => " && message === ",
                .python => " and message == ",
                .racket => " (equal? message ",
            });
            if (language == .racket) {
                // Racket constants retain uppercase and replace underscores.
                for (constant) |c| try out.append(a, if (c == '_') '-' else c);
            } else try out.appendSlice(a, constant);
            if (language == .rust or language == .racket) try out.append(a, ')');
            try out.append(a, ')');
        }
    }
    try out.appendSlice(a, switch (language) {
        .rust => "\n\t}\n",
        .ts => ";\n    }\n",
        .python => "\n",
        .racket => "))\n",
    });
}
