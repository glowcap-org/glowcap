//! Pure authoring parser. Headers are cached before declarations resolve imports.
const std = @import("std");
const description = @import("description.zig");
const Node = description.Node;
pub const Error = description.Error || error{ InvalidText, UnsupportedSyntax, MissingImport };
pub const Source = struct { path: []const u8, bytes: []const u8 };
pub const Diagnostic = struct {
    path: []const u8 = "",
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "",

    pub fn set(self: *Diagnostic, source: Source, offset: usize, message: []const u8) void {
        self.* = .{ .path = source.path, .offset = offset, .message = message };
        for (source.bytes[0..offset]) |c| {
            if (c == '\n') {
                self.line += 1;
                self.column = 1;
            } else self.column += 1;
        }
    }

    /// Locate a borrowed node's source span without parsing or checking again.
    pub fn setOrigin(self: *Diagnostic, source: Source, origin: []const u8, message: []const u8) bool {
        const begin = @intFromPtr(source.bytes.ptr);
        const location = @intFromPtr(origin.ptr);
        if (origin.len == 0 or location < begin or location - begin >= source.bytes.len) return false;
        self.set(source, location - begin, message);
        return true;
    }
};
pub const Budget = struct {
    tokens: usize = description.max_nodes,
    expanded_names: usize = 0,
    work: usize = 1 << 20,

    fn spend(self: *Budget, amount: usize) Error!void {
        if (amount > self.work) return error.ResourceLimit;
        self.work -= amount;
    }
};
pub const Import = struct { path: []const u8, alias: []const u8, offset: usize, target: ?usize = null };
pub const Header = struct { name: []const u8, imports: []Import, body: usize };
pub const Alias = struct { name: []const u8, module: []const u8 };
pub const Entry = struct { key: Node, value: Node };
const Token = struct { kind: enum { word, string, number, punctuation, end }, text: []const u8, offset: usize };

pub const Parser = struct {
    a: std.mem.Allocator,
    source: Source,
    diagnostic: *Diagnostic,
    budget: *Budget,
    at: usize = 0,
    start: usize = 0,
    prefix: []const u8 = "",
    aliases: []const Alias = &.{},
    receipt: bool = false,

    fn fail(self: *Parser, message: []const u8) Error {
        self.diagnostic.set(self.source, self.start, message);
        return error.InvalidText;
    }
    fn unsupported(self: *Parser) Error {
        self.diagnostic.set(self.source, self.start, "construct outside the authoring comparison subset");
        return error.UnsupportedSyntax;
    }
    fn next(self: *Parser) Error!Token {
        while (self.at < self.source.bytes.len) {
            if (std.ascii.isWhitespace(self.source.bytes[self.at])) self.at += 1 else if (std.mem.startsWith(u8, self.source.bytes[self.at..], "//")) {
                while (self.at < self.source.bytes.len and self.source.bytes[self.at] != '\n') self.at += 1;
            } else break;
        }
        self.start = self.at;
        if (self.budget.tokens == 0) return error.ResourceLimit;
        self.budget.tokens -= 1;
        if (self.at == self.source.bytes.len) return .{ .kind = .end, .text = "", .offset = self.start };
        const c = self.source.bytes[self.at];
        self.at += 1;
        if (c == '"') {
            var escaped = false;
            while (self.at < self.source.bytes.len) {
                const byte = self.source.bytes[self.at];
                self.at += 1;
                if (byte == '"' and !escaped) {
                    const parsed = std.json.parseFromSlice([]const u8, self.a, self.source.bytes[self.start..self.at], .{ .allocate = .alloc_always }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return self.fail("invalid quoted wire name"),
                    };
                    return .{ .kind = .string, .text = parsed.value, .offset = self.start };
                }
                escaped = byte == '\\' and !escaped;
            }
            return self.fail("unterminated quoted wire name");
        }
        const word_token = std.ascii.isAlphabetic(c) or c == '_';
        const number = std.ascii.isDigit(c) or (c == '-' and self.at < self.source.bytes.len and std.ascii.isDigit(self.source.bytes[self.at]));
        if (word_token or number) {
            while (self.at < self.source.bytes.len) {
                const byte = self.source.bytes[self.at];
                if (if (word_token) std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' else std.ascii.isDigit(byte) or byte == '_') self.at += 1 else break;
            }
        } else if (c == '-' and self.at < self.source.bytes.len and self.source.bytes[self.at] == '>') self.at += 1;
        return .{ .kind = if (word_token) .word else if (number) .number else .punctuation, .text = self.source.bytes[self.start..self.at], .offset = self.start };
    }
    fn peek(self: *Parser) Error!Token {
        const at = self.at;
        const start = self.start;
        const token = try self.next();
        self.at = at;
        self.start = start;
        return token;
    }
    fn accept(self: *Parser, value: []const u8) Error!bool {
        const token = try self.peek();
        if (token.kind == .string or !std.mem.eql(u8, token.text, value)) return false;
        _ = try self.next();
        return true;
    }
    fn expect(self: *Parser, value: []const u8) Error!void {
        if (!try self.accept(value)) {
            self.start = (try self.peek()).offset;
            return self.fail("unexpected token");
        }
    }
    fn word(self: *Parser) Error![]const u8 {
        const token = try self.next();
        if (token.kind != .word) return self.fail("expected identifier");
        return token.text;
    }
    fn span(self: *Parser, start: usize) []const u8 {
        return self.source.bytes[start..self.at];
    }
    fn atom(self: *Parser, value: []const u8, kind: @FieldType(Node, "kind")) Node {
        return .{ .kind = kind, .bytes = value, .source = self.span(self.start) };
    }
    fn record(self: *Parser, label: []const u8, fields: []const Node) Error!Node {
        return .{ .kind = .record, .bytes = label, .children = try self.a.dupe(Node, fields), .source = self.span(self.start) };
    }
    fn list(self: *Parser, items: []const Node) Error!Node {
        return .{ .kind = .list, .children = try self.a.dupe(Node, items), .source = self.span(self.start) };
    }
    pub fn dictionary(self: *Parser, entries: []Entry) Error!Node {
        const children = try self.a.alloc(Node, entries.len * 2);
        for (entries, 0..) |entry, i| {
            children[i * 2] = entry.key;
            children[i * 2 + 1] = entry.value;
        }
        return .{ .kind = .dictionary, .children = children, .source = self.span(self.start) };
    }
    fn qualified(self: *Parser, name: []const u8, declaration: bool) Error![]const u8 {
        var prefix = self.prefix;
        var suffix = name;
        if (!declaration) if (std.mem.findScalar(u8, name, '.')) |dot| {
            try self.budget.spend(self.aliases.len);
            for (self.aliases) |alias| {
                if (std.mem.eql(u8, alias.name, name[0..dot])) {
                    prefix = alias.module;
                    suffix = name[dot + 1 ..];
                    break;
                }
            }
            if (suffix.ptr == name.ptr) prefix = "";
        };
        const length = suffix.len + if (prefix.len == 0) @as(usize, 0) else prefix.len + 1;
        if (length > description.max_input_bytes - self.budget.expanded_names) return error.ResourceLimit;
        self.budget.expanded_names += length;
        return if (prefix.len == 0) suffix else self.a.print("{s}.{s}", .{ prefix, suffix });
    }
    pub fn header(self: *Parser) Error!Header {
        try self.expect("module");
        const name = try self.word();
        var parts = std.mem.splitScalar(u8, name, '.');
        while (parts.next()) |part| {
            if (part.len == 0 or (!std.ascii.isAlphabetic(part[0]) and part[0] != '_')) return self.fail("invalid module name");
        }
        var imports: std.ArrayList(Import) = .empty;
        while (try self.accept("import")) {
            const token = try self.next();
            if (token.kind != .string) return self.fail("expected quoted import path");
            try self.expect("as");
            const alias = try self.word();
            if (std.mem.findScalar(u8, alias, '.') != null) return self.fail("import alias must be a simple identifier");
            try self.budget.spend(imports.items.len);
            for (imports.items) |previous| if (std.mem.eql(u8, previous.alias, alias)) return self.fail("duplicate import alias");
            try imports.append(self.a, .{ .path = token.text, .alias = alias, .offset = token.offset });
        }
        return .{ .name = name, .imports = try imports.toOwnedSlice(self.a), .body = self.at };
    }
    pub fn declarations(self: *Parser, entries: *std.ArrayList(Entry)) Error!void {
        while ((try self.peek()).kind != .end) {
            const declaration = try self.next();
            const is_type = std.mem.eql(u8, declaration.text, "type");
            if (!is_type and !std.mem.eql(u8, declaration.text, "interface")) return self.unsupported();
            const name = try self.word();
            const key = self.atom(try self.qualified(name, true), .string);
            const body = if (is_type) body: {
                try self.expect("=");
                break :body try self.typeExpression(0);
            } else try self.interface();
            try entries.append(self.a, .{ .key = key, .value = try self.record(if (is_type) "type" else "interface", &.{body}) });
            if (entries.items.len > @import("model.zig").max_definitions) return error.ResourceLimit;
        }
    }
    fn typeExpression(self: *Parser, depth: usize) Error!Node {
        if (depth > description.max_depth) return error.ResourceLimit;
        const name = try self.word();
        const start = self.start;
        var value: Node = undefined;
        if (std.mem.eql(u8, name, "promise") or std.mem.eql(u8, name, "list") or std.mem.eql(u8, name, "tuple") or std.mem.eql(u8, name, "record") or std.mem.eql(u8, name, "tagged")) {
            value = try self.constructor(name, depth);
        } else {
            const primitive = for ([_][]const u8{ "undefined", "null", "bool", "integer", "float64", "string", "bytes", "symbol", "target", "value", "error" }) |candidate| {
                if (std.mem.eql(u8, name, candidate)) break true;
            } else false;
            value = if (primitive) self.atom(name, .symbol) else try self.record("ref", &.{self.atom(try self.qualified(name, false), .string)});
        }
        if (try self.accept("(")) {
            var bounds: std.ArrayList(Entry) = .empty;
            while (true) {
                const key = self.atom(try self.word(), .string);
                try self.expect(":");
                const number = try self.next();
                if (number.kind != .number) return self.fail("expected integer bound");
                var clean: std.ArrayList(u8) = .empty;
                for (number.text) |c| if (c != '_') {
                    try clean.append(self.a, c);
                };
                const integer = std.fmt.parseInt(i64, clean.items, 10) catch return self.fail("bound exceeds signed 64-bit comparison range");
                try bounds.append(self.a, .{ .key = key, .value = .{ .kind = .integer, .integer = integer, .source = self.span(number.offset) } });
                if (try self.accept(")")) break;
                try self.expect(",");
            }
            var restrictions = try self.dictionary(bounds.items);
            restrictions.source = self.span(start);
            value = try self.record("bounded", &.{ value, restrictions });
        }
        value.source = self.span(start);
        return value;
    }

    fn constructor(self: *Parser, name: []const u8, depth: usize) Error!Node {
        try self.expect("<");
        if (std.mem.eql(u8, name, "list") or std.mem.eql(u8, name, "promise")) {
            const element = try self.typeExpression(depth + 1);
            try self.expect(">");
            return self.record(name, &.{element});
        }
        const positional = std.mem.eql(u8, name, "record");
        const tagged = std.mem.eql(u8, name, "tagged");
        var tag: Node = undefined;
        if (positional or tagged) {
            const token = try self.next();
            if (token.kind != .string) return self.fail("expected quoted record tag");
            tag = self.atom(token.text, .string);
            if (tagged) {
                try self.expect(",");
                const payload = try self.typeExpression(depth + 1);
                try self.expect(">");
                return self.record("tagged", &.{ tag, payload });
            }
        }
        var fields: std.ArrayList(Node) = .empty;
        if (!try self.accept(">")) {
            if (positional) try self.expect(",");
            while (true) {
                try fields.append(self.a, try self.typeExpression(depth + 1));
                if (try self.accept(">")) break;
                try self.expect(",");
            }
        }
        const members = try self.list(fields.items);
        return if (positional) self.record("record", &.{ tag, members }) else self.record("tuple", &.{members});
    }
    fn interface(self: *Parser) Error!Node {
        try self.expect("{");
        var methods: std.ArrayList(Entry) = .empty;
        while (!try self.accept("}")) {
            if ((try self.peek()).kind == .end) return self.fail("unterminated interface");
            var effect: []const u8 = "call";
            if (try self.accept("@")) {
                if (!std.mem.eql(u8, try self.word(), "loam.receipt")) return self.unsupported();
                effect = "loam.receipt";
                self.receipt = true;
            } else if (try self.accept("tell")) effect = "tell";
            const token = try self.peek();
            const selector: Node = if (token.kind == .punctuation and std.mem.eql(u8, token.text, "(")) .{ .kind = .boolean, .source = self.span(self.start) } else selector: {
                const selected = try self.next();
                if (selected.kind != .word and selected.kind != .string) return self.fail("expected method selector");
                break :selector self.atom(selected.text, .string);
            };
            try self.expect("(");
            var parameters: std.ArrayList(Node) = .empty;
            if (!try self.accept(")")) while (true) {
                const rest = try self.accept(".");
                if (rest) {
                    try self.expect(".");
                    try self.expect(".");
                }
                const name = self.atom(try self.word(), .string);
                const optional = try self.accept("?");
                try self.expect(":");
                const kind = try self.typeExpression(0);
                if (rest and optional) return self.fail("rest parameters cannot be optional");
                try parameters.append(self.a, if (rest) try self.record("rest", &.{ name, kind }) else try self.record("parameter", &.{ name, kind, .{ .kind = .boolean, .boolean = optional } }));
                if (parameters.items.len > @import("model.zig").max_parameters) return error.ResourceLimit;
                if (try self.accept(")")) break;
                try self.expect(",");
            };
            const result = if (std.mem.eql(u8, effect, "tell")) self.atom("undefined", .symbol) else result: {
                try self.expect("->");
                break :result try self.typeExpression(0);
            };
            const following = try self.peek();
            if (following.kind == .word and std.mem.eql(u8, following.text, "throws")) {
                self.start = following.offset;
                return self.unsupported();
            }
            try methods.append(self.a, .{ .key = selector, .value = try self.record("method", &.{ try self.list(parameters.items), result, self.atom(effect, .symbol) }) });
        }
        return self.dictionary(methods.items);
    }
};
