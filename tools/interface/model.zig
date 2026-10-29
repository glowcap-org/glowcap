//! Checked description graph shared by emitters. The first projection selects
//! one receipt method with a bounded string argument and a capability result.
const std = @import("std");
const description = @import("description.zig");
const Node = description.Node;
const Error = description.Error;

pub const max_definitions: usize = 4096;
pub const max_parameters: usize = 256;

/// The creation templates spell this method's names and Loam's receipt verbs,
/// so their emitters refuse a creation projected from any other method.
pub const creation_method = "add";

pub const Creation = struct {
    wire_name: []const u8,
    minimum: usize,
    maximum: usize,
};

pub const Model = struct {
    definitions: Node,
    remaining: usize = 1 << 20,

    pub fn init(root: Node) Error!Model {
        const fields = try root.fields("glowcap:interface", 3);
        if (try fields[0].number() != 1 or fields[1].kind != .dictionary or fields[2].kind != .dictionary) return error.InvalidDescription;
        if (fields[2].children.len > 2 * max_definitions) return error.ResourceLimit;
        if (fields[1].children.len != 4 or try (try fields[1].get("glowcap.values")).number() != 1 or try (try fields[1].get("loam.receipt")).number() != 1) return error.InvalidDescription;
        var self: Model = .{ .definitions = fields[2] };
        var i: usize = 0;
        while (i < self.definitions.children.len) : (i += 2) {
            try identifier(try self.definitions.children[i].string());
            const declaration = self.definitions.children[i + 1];
            if (declaration.kind != .record or declaration.children.len != 1) return error.InvalidDescription;
            if (std.mem.eql(u8, declaration.bytes, "type")) {
                try self.checkType(declaration.children[0], 0);
                _ = try self.resolve(declaration.children[0]);
            } else if (std.mem.eql(u8, declaration.bytes, "interface")) {
                try self.checkInterface(declaration.children[0]);
            } else return error.InvalidDescription;
        }
        return self;
    }

    fn definition(self: *Model, name: []const u8) Error!Node {
        try self.spend(self.definitions.children.len / 2);
        return self.definitions.get(name);
    }

    fn spend(self: *Model, work: usize) Error!void {
        if (work > self.remaining) return error.ResourceLimit;
        self.remaining -= work;
    }

    pub fn resolve(self: *Model, input: Node) Error!Node {
        var value = input;
        var hops: usize = 0;
        while (value.kind == .record and std.mem.eql(u8, value.bytes, "ref")) {
            if (hops >= self.definitions.children.len / 2) return error.InvalidDescription;
            hops += 1;
            const reference = try value.fields("ref", 1);
            const declaration = try self.definition(try reference[0].string());
            if (std.mem.eql(u8, declaration.bytes, "interface")) return declaration;
            value = (try declaration.fields("type", 1))[0];
        }
        return value;
    }

    fn checkInterface(self: *Model, methods: Node) Error!void {
        if (methods.kind != .dictionary) return error.InvalidDescription;
        var i: usize = 0;
        while (i < methods.children.len) : (i += 2) {
            const name = methods.children[i];
            if (name.kind != .string and !(name.kind == .boolean and !name.boolean)) return error.InvalidDescription;
            const method = try methods.children[i + 1].fields("method", 3);
            const params = method[0];
            if (params.kind != .list or params.children.len > max_parameters) return error.InvalidDescription;
            if (!method[2].is("call") and !method[2].is("tell") and !method[2].is("loam.receipt")) return error.InvalidDescription;
            if (method[2].is("loam.receipt") and name.kind != .string) return error.InvalidDescription;
            if (method[2].is("tell") and !method[1].is("undefined")) return error.InvalidDescription;
            var optional = false;
            for (params.children, 0..) |param, at| {
                if (param.kind != .record) return error.InvalidDescription;
                const rest = std.mem.eql(u8, param.bytes, "rest");
                const fields = try param.fields(if (rest) "rest" else "parameter", if (rest) 2 else 3);
                try identifier(try fields[0].string());
                for (params.children[0..at]) |previous| {
                    if (std.mem.eql(u8, previous.children[0].bytes, fields[0].bytes)) return error.InvalidDescription;
                }
                if (rest) {
                    if (optional or at + 1 != params.children.len) return error.InvalidDescription;
                } else {
                    if (fields[2].kind != .boolean or (optional and !fields[2].boolean)) return error.InvalidDescription;
                    optional = fields[2].boolean;
                }
                try self.checkType(fields[1], 0);
            }
            try self.checkType(method[1], 0);
        }
    }

    fn checkType(self: *Model, value: Node, depth: usize) Error!void {
        try self.spend(1);
        if (depth > description.max_depth) return error.ResourceLimit;
        if (value.kind == .symbol) {
            for ([_][]const u8{ "undefined", "null", "bool", "integer", "float64", "string", "bytes", "symbol", "target", "value", "error", "keyword", "float32" }) |name| {
                if (value.is(name)) return;
            }
            return error.InvalidDescription;
        }
        if (value.kind != .record) return error.InvalidDescription;
        const label = value.bytes;
        if (std.mem.eql(u8, label, "ref")) {
            const fields = try value.fields("ref", 1);
            _ = try self.definition(try fields[0].string());
        } else if (std.mem.eql(u8, label, "bounded")) {
            const fields = try value.fields("bounded", 2);
            try self.checkType(fields[0], depth + 1);
            if (fields[1].kind != .dictionary) return error.InvalidDescription;
            const base = try self.resolve(fields[0]);
            const integers = base.is("integer");
            const bytes = base.is("string") or base.is("bytes");
            const container = base.kind == .record and (std.mem.eql(u8, base.bytes, "list") or std.mem.eql(u8, base.bytes, "map") or std.mem.eql(u8, base.bytes, "set"));
            if (!integers and !bytes and !container) return error.InvalidDescription;
            var minimum: i64 = if (base.is("integer")) std.math.minInt(i64) else 0;
            var maximum: i64 = std.math.maxInt(i64);
            var i: usize = 0;
            while (i < fields[1].children.len) : (i += 2) {
                const key = try fields[1].children[i].string();
                const number = try fields[1].children[i + 1].number();
                const lower = std.mem.eql(u8, key, if (integers) "min" else "min_bytes");
                const upper = std.mem.eql(u8, key, if (integers) "max" else if (bytes) "max_bytes" else "max_items");
                if ((!lower and !upper) or (container and lower) or (!integers and number < 0)) return error.InvalidDescription;
                if (lower) minimum = number else maximum = number;
            }
            if (minimum > maximum) return error.InvalidDescription;
        } else if (std.mem.eql(u8, label, "list") or std.mem.eql(u8, label, "set") or std.mem.eql(u8, label, "promise")) {
            try self.checkType((try value.fields(label, 1))[0], depth + 1);
        } else if (std.mem.eql(u8, label, "tuple") or std.mem.eql(u8, label, "union")) {
            const members = (try value.fields(label, 1))[0];
            if (members.kind != .list) return error.InvalidDescription;
            if (std.mem.eql(u8, label, "union")) return error.UnsupportedProjection;
            for (members.children) |member| try self.checkType(member, depth + 1);
        } else if (std.mem.eql(u8, label, "record")) {
            const fields = try value.fields(label, 2);
            _ = try fields[0].string();
            if (fields[1].kind != .list) return error.InvalidDescription;
            for (fields[1].children) |field| try self.checkType(field, depth + 1);
        } else return error.UnsupportedProjection;
    }

    pub fn creation(self: *Model, interface_name: []const u8, method_name: []const u8) Error!Creation {
        const interface = try (try self.definition(interface_name)).fields("interface", 1);
        const method = try (try interface[0].get(method_name)).fields("method", 3);
        if (!method[2].is("loam.receipt") or method[0].children.len != 1) return error.UnsupportedProjection;
        const param = try method[0].children[0].fields("parameter", 3);
        if (param[2].boolean) return error.UnsupportedProjection;
        const input = try self.resolve(param[1]);
        if (input.kind != .record or !std.mem.eql(u8, input.bytes, "bounded")) return error.UnsupportedProjection;
        const bounded = try input.fields("bounded", 2);
        if (!bounded[0].is("string")) return error.UnsupportedProjection;
        const min = try (try bounded[1].get("min_bytes")).number();
        const max = try (try bounded[1].get("max_bytes")).number();
        if (min < 0 or max < min) return error.InvalidDescription;
        const result = try self.resolve(method[1]);
        if (result.kind != .record or !std.mem.eql(u8, result.bytes, "interface")) return error.UnsupportedProjection;
        return .{ .wire_name = method_name, .minimum = std.math.cast(usize, min) orelse return error.UnsupportedProjection, .maximum = std.math.cast(usize, max) orelse return error.UnsupportedProjection };
    }
};

fn identifier(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidDescription;
    var first = true;
    for (name) |c| {
        if (c == '.') {
            if (first) return error.InvalidDescription;
            first = true;
        } else {
            if (!(std.ascii.isAlphabetic(c) or c == '_' or (!first and std.ascii.isDigit(c)))) return error.InvalidDescription;
            first = false;
        }
    }
    if (first) return error.InvalidDescription;
}
