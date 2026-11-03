//! Build-time comparison adapter for the retained proposed-text subset.
//! The arena owns token decoding and encoded fragments. Only the final canonical
//! description is copied to the caller. No parser is linked into generated calls.
const std = @import("std");
const description = @import("description.zig");
const Model = @import("model.zig").Model;

pub const Diagnostic = struct {
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "",
};
pub const Error = description.Error || error{ InvalidText, UnsupportedSyntax };

pub fn translate(a: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error![]u8 {
    diagnostic.* = .{};
    if (source.len > description.max_input_bytes) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidText;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var parser: Parser = .{ .a = arena.allocator(), .source = source, .diagnostic = diagnostic };
    const encoded = try parser.module();
    // Serialization is never a route around the checked description boundary.
    _ = Model.init(try description.read(arena.allocator(), encoded)) catch |err| {
        parser.note("description rejected by checked model");
        return err;
    };
    return a.dupe(u8, encoded);
}

const Entry = struct { key: []const u8, value: []const u8 };
const Token = struct { kind: enum { word, string, number, punctuation, end }, text: []const u8, at: usize };
const Parser = struct {
    a: std.mem.Allocator,
    source: []const u8,
    diagnostic: *Diagnostic,
    at: usize = 0,
    start: usize = 0,
    remaining: usize = description.max_nodes,
    prefix: []const u8 = "",

    fn note(self: *Parser, message: []const u8) void {
        self.diagnostic.* = .{ .offset = self.start, .message = message };
        for (self.source[0..self.start]) |c| {
            if (c == '\n') {
                self.diagnostic.line += 1;
                self.diagnostic.column = 1;
            } else self.diagnostic.column += 1;
        }
    }

    fn fail(self: *Parser, message: []const u8) Error {
        self.note(message);
        return error.InvalidText;
    }

    fn unsupported(self: *Parser) Error {
        self.note("construct outside the authoring comparison subset");
        return error.UnsupportedSyntax;
    }

    fn next(self: *Parser) Error!Token {
        while (self.at < self.source.len) {
            if (std.ascii.isWhitespace(self.source[self.at])) {
                self.at += 1;
            } else if (std.mem.startsWith(u8, self.source[self.at..], "//")) {
                while (self.at < self.source.len and self.source[self.at] != '\n') self.at += 1;
            } else break;
        }
        self.start = self.at;
        if (self.remaining == 0) return error.ResourceLimit;
        self.remaining -= 1;
        if (self.at == self.source.len) return .{ .kind = .end, .text = "", .at = self.at };
        const c = self.source[self.at];
        self.at += 1;
        if (c == '"') {
            var escaped = false;
            while (self.at < self.source.len) {
                const byte = self.source[self.at];
                self.at += 1;
                if (byte == '"' and !escaped) {
                    const parsed = std.json.parseFromSlice([]const u8, self.a, self.source[self.start..self.at], .{ .allocate = .alloc_always }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return self.fail("invalid quoted wire name"),
                    };
                    return .{ .kind = .string, .text = parsed.value, .at = self.start };
                }
                escaped = byte == '\\' and !escaped;
            }
            return self.fail("unterminated quoted wire name");
        }
        const is_word = std.ascii.isAlphabetic(c) or c == '_';
        const number = std.ascii.isDigit(c) or (c == '-' and self.at < self.source.len and std.ascii.isDigit(self.source[self.at]));
        if (is_word or number) {
            while (self.at < self.source.len) {
                const byte = self.source[self.at];
                if (if (is_word) std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' else std.ascii.isDigit(byte) or byte == '_') self.at += 1 else break;
            }
        } else if (c == '-' and self.at < self.source.len and self.source[self.at] == '>') self.at += 1;
        return .{ .kind = if (is_word) .word else if (number) .number else .punctuation, .text = self.source[self.start..self.at], .at = self.start };
    }

    fn peek(self: *Parser) Error!Token {
        const saved = self.at;
        const token = try self.next();
        self.at = saved;
        return token;
    }

    fn accept(self: *Parser, text: []const u8) Error!bool {
        const token = try self.peek();
        if (token.kind == .string or !std.mem.eql(u8, token.text, text)) return false;
        _ = try self.next();
        return true;
    }

    fn expect(self: *Parser, text: []const u8) Error!void {
        if (!try self.accept(text)) return self.fail("unexpected token");
    }

    fn word(self: *Parser) Error![]const u8 {
        const token = try self.next();
        if (token.kind != .word) return self.fail("expected identifier");
        return token.text;
    }

    fn atom(self: *Parser, value: []const u8, marker: u8) Error![]const u8 {
        return std.fmt.allocPrint(self.a, "{d}{c}{s}", .{ value.len, marker, value });
    }

    fn record(self: *Parser, label: []const u8, fields: []const []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(self.a, '<');
        try out.appendSlice(self.a, try self.atom(label, '\''));
        for (fields) |field| try out.appendSlice(self.a, field);
        try out.append(self.a, '>');
        return out.toOwnedSlice(self.a);
    }

    fn list(self: *Parser, items: []const []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.append(self.a, '[');
        for (items) |item| try out.appendSlice(self.a, item);
        try out.append(self.a, ']');
        return out.toOwnedSlice(self.a);
    }

    fn dictionary(self: *Parser, entries: []Entry) Error![]const u8 {
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, left: Entry, right: Entry) bool {
                return std.mem.order(u8, left.key, right.key) == .lt;
            }
        }.less);
        var out: std.ArrayList(u8) = .empty;
        try out.append(self.a, '{');
        for (entries, 0..) |entry, i| {
            if (i != 0 and std.mem.eql(u8, entries[i - 1].key, entry.key)) return self.fail("duplicate declaration, method, or bound");
            try out.appendSlice(self.a, entry.key);
            try out.appendSlice(self.a, entry.value);
        }
        try out.append(self.a, '}');
        if (out.items.len > description.max_input_bytes) return error.ResourceLimit;
        return out.toOwnedSlice(self.a);
    }

    fn qualified(self: *Parser, name: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, name, '.') != null) return name;
        return std.fmt.allocPrint(self.a, "{s}.{s}", .{ self.prefix, name });
    }

    fn module(self: *Parser) Error![]const u8 {
        try self.expect("module");
        self.prefix = try self.word();
        var entries: std.ArrayList(Entry) = .empty;
        while ((try self.peek()).kind != .end) {
            const declaration = try self.next();
            const is_type = std.mem.eql(u8, declaration.text, "type");
            if (!is_type and !std.mem.eql(u8, declaration.text, "interface")) return self.unsupported();
            const name = try self.word();
            const body = if (is_type) body: {
                try self.expect("=");
                break :body try self.typeExpression(0);
            } else try self.interface();
            try entries.append(self.a, .{
                .key = try self.atom(try self.qualified(name), '"'),
                .value = try self.record(if (is_type) "type" else "interface", &.{body}),
            });
            if (entries.items.len > @import("model.zig").max_definitions) return error.ResourceLimit;
        }
        return self.record("glowcap:interface", &.{ "1+", "{12\"loam.receipt1+14\"glowcap.values1+}", try self.dictionary(entries.items) });
    }

    fn typeExpression(self: *Parser, depth: usize) Error![]const u8 {
        if (depth > description.max_depth) return error.ResourceLimit;
        const name = try self.word();
        var value: []const u8 = undefined;
        if (std.mem.eql(u8, name, "promise")) {
            try self.expect("<");
            const element = try self.typeExpression(depth + 1);
            try self.expect(">");
            return self.record("promise", &.{element});
        }
        const primitive = for ([_][]const u8{ "undefined", "null", "bool", "integer", "float64", "string", "bytes", "symbol", "target", "value", "error" }) |atom_name| {
            if (std.mem.eql(u8, name, atom_name)) break true;
        } else false;
        value = if (primitive) try self.atom(name, '\'') else try self.record("ref", &.{try self.atom(try self.qualified(name), '"')});
        if (try self.accept("(")) {
            var bounds: std.ArrayList(Entry) = .empty;
            while (true) {
                const key = try self.word();
                try self.expect(":");
                const number = try self.next();
                if (number.kind != .number) return self.fail("expected integer bound");
                var clean: std.ArrayList(u8) = .empty;
                for (number.text) |c| if (c != '_') {
                    try clean.append(self.a, c);
                };
                const integer = std.fmt.parseInt(i64, clean.items, 10) catch return self.fail("bound exceeds signed 64-bit comparison range");
                const encoded = if (integer < 0) try std.fmt.allocPrint(self.a, "{d}-", .{@abs(integer)}) else try std.fmt.allocPrint(self.a, "{d}+", .{integer});
                try bounds.append(self.a, .{ .key = try self.atom(key, '"'), .value = encoded });
                if (try self.accept(")")) break;
                try self.expect(",");
            }
            value = try self.record("bounded", &.{ value, try self.dictionary(bounds.items) });
        }
        return value;
    }

    fn interface(self: *Parser) Error![]const u8 {
        try self.expect("{");
        var methods: std.ArrayList(Entry) = .empty;
        var direct = false;
        var named = false;
        while (!try self.accept("}")) {
            if ((try self.peek()).kind == .end) return self.fail("unterminated interface");
            var effect: []const u8 = "call";
            if (try self.accept("@")) {
                if (!std.mem.eql(u8, try self.word(), "loam.receipt")) return self.unsupported();
                effect = "loam.receipt";
            } else if (try self.accept("tell")) effect = "tell";
            const token = try self.peek();
            const selector = if (token.kind == .punctuation and std.mem.eql(u8, token.text, "(")) selector: {
                direct = true;
                break :selector "f";
            } else selector: {
                const name = try self.next();
                if (name.kind != .word and name.kind != .string) return self.fail("expected method selector");
                named = true;
                break :selector try self.atom(name.text, '"');
            };
            if (direct and named) return self.fail("direct and named methods cannot share an interface");
            try self.expect("(");
            var parameters: std.ArrayList([]const u8) = .empty;
            if (!try self.accept(")")) while (true) {
                const name = try self.word();
                const optional = try self.accept("?");
                try self.expect(":");
                const kind = try self.typeExpression(0);
                try parameters.append(self.a, try self.record("parameter", &.{ try self.atom(name, '"'), kind, if (optional) "t" else "f" }));
                if (parameters.items.len > @import("model.zig").max_parameters) return error.ResourceLimit;
                if (try self.accept(")")) break;
                try self.expect(",");
            };
            const result = if (std.mem.eql(u8, effect, "tell")) try self.atom("undefined", '\'') else result: {
                try self.expect("->");
                break :result try self.typeExpression(0);
            };
            const following = try self.peek();
            if (following.kind == .word and std.mem.eql(u8, following.text, "throws")) return self.unsupported();
            try methods.append(self.a, .{ .key = selector, .value = try self.record("method", &.{ try self.list(parameters.items), result, try self.atom(effect, '\'') }) });
        }
        return self.dictionary(methods.items);
    }
};
