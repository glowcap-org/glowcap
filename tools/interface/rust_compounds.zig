//! Owned compound reply projection. The checked graph never contains raw ASTs.
const std = @import("std");
const calls = @import("calls.zig");
const bounds = @import("rust_bounds.zig");
const literal = @import("literal.zig").write;

pub fn compound(kind: calls.Type) bool {
    return kind == .list or kind == .tuple or kind == .record;
}

/// Compiler admission counts tuple/record containers and their inline fields.
/// Scalar and list slots count once. This is not a byte or schema cardinality limit.
pub const max_inline_structure: usize = 256;
pub const max_reply_work: usize = 65536;
pub const max_reply_depth: usize = 64;
const Node = struct { kind: calls.Type, minimum_work: usize = 0 };

pub const Projection = struct {
    a: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    exports: []const calls.TypeExport,
    methods: []const calls.Named,
    type_names: std.ArrayList([]u8) = .empty,
    bounded: std.ArrayList(calls.Type) = .empty,
    leaves: std.EnumSet(calls.Kind) = .{},
    remaining: usize = 65536,

    pub fn init(a: std.mem.Allocator, methods: []const calls.Named, types: []const calls.TypeExport) !Projection {
        var self: Projection = .{ .a = a, .exports = types, .methods = methods };
        errdefer self.deinit();
        for (methods) |method| if (method.call.effect != .tell) try self.collect(method.call.result);
        // List indirection does not excuse an oversized emitted element helper.
        for (self.nodes.items) |node| {
            if (try self.minimumWork(node.kind) > max_inline_structure) return error.ResourceLimit;
        }
        for (types, 0..) |item, i| {
            if (item.kind != .record and item.kind != .tuple) return error.UnsupportedProjection;
            if (try self.index(item.kind) == null) return error.UnsupportedProjection;
            for (types[0..i]) |previous| if (std.meta.eql(previous.kind, item.kind)) return error.ExportCollision;
        }
        for (types, 0..) |_, i| {
            const name = try std.fmt.allocPrint(a, "ProjectedType{d}", .{i});
            errdefer a.free(name);
            try self.type_names.append(a, name);
        }
        return self;
    }

    pub fn deinit(self: *Projection) void {
        for (self.type_names.items) |name| self.a.free(name);
        self.type_names.deinit(self.a);
        self.nodes.deinit(self.a);
        self.bounded.deinit(self.a);
    }

    fn spend(self: *Projection) !void {
        try self.spendWork(1);
    }

    fn spendWork(self: *Projection, work: usize) !void {
        if (work > self.remaining) return error.ResourceLimit;
        self.remaining -= work;
    }

    fn index(self: *Projection, kind: calls.Type) !?usize {
        try self.spendWork(self.nodes.items.len);
        for (self.nodes.items, 0..) |node, i| if (std.meta.eql(node.kind, kind)) return i;
        return null;
    }

    fn collect(self: *Projection, kind: calls.Type) !void {
        try self.spend();
        if (!compound(kind)) {
            try bounds.supported(kind);
            if (kind == .pending_target or kind == .pending_value) return error.UnsupportedProjection;
            if (bounds.fallible(kind)) {
                var seen = false;
                for (self.bounded.items) |previous| if (std.meta.eql(previous, kind)) {
                    seen = true;
                };
                if (!seen) try self.bounded.append(self.a, kind);
            }
            self.leaves.insert(std.meta.activeTag(kind));
            return;
        }
        if (try self.index(kind) != null) return;
        try self.nodes.append(self.a, .{ .kind = kind });
        switch (kind) {
            .list => |list| try self.collect(list.element),
            .tuple => |tuple| for (tuple.fields) |field| try self.collect(field),
            .record => |record| for (record.fields) |field| try self.collect(field),
            else => unreachable,
        }
    }

    fn exported(self: *Projection, kind: calls.Type) !?[]const u8 {
        try self.spendWork(self.exports.len);
        for (self.exports, 0..) |item, i| if (std.meta.eql(item.kind, kind)) return self.type_names.items[i];
        return null;
    }

    pub fn typeName(self: *Projection, out: *std.ArrayList(u8), kind: calls.Type) !void {
        try self.spend();
        if (try self.exported(kind)) |name| return out.appendSlice(self.a, name);
        if (try self.index(kind)) |i| return out.print(self.a, "Compound{d}", .{i});
        try out.appendSlice(self.a, switch (kind) {
            .text, .symbol, .error_value => "String",
            .integer => "i64",
            .boolean => "bool",
            .bytes => "Vec<u8>",
            .float64 => "f64",
            .target => "Ref",
            .nothing => "()",
            .value => "Argument",
            else => return error.UnsupportedProjection,
        });
    }

    fn bodyName(self: *Projection, out: *std.ArrayList(u8), kind: calls.Type) !void {
        switch (kind) {
            .list => |list| {
                try out.appendSlice(self.a, "Vec<");
                try self.typeName(out, list.element);
                try out.appendSlice(self.a, ">");
            },
            .tuple => |tuple| try self.tupleName(out, tuple.fields),
            .record => |record| try self.tupleName(out, record.fields),
            else => unreachable,
        }
    }

    fn tupleName(self: *Projection, out: *std.ArrayList(u8), fields: []const calls.Type) !void {
        try out.appendSlice(self.a, "(");
        for (fields, 0..) |field, i| {
            if (i != 0) try out.appendSlice(self.a, ", ");
            try self.typeName(out, field);
        }
        if (fields.len == 1) try out.appendSlice(self.a, ",");
        try out.appendSlice(self.a, ")");
    }

    pub fn decoder(self: *Projection, out: *std.ArrayList(u8), kind: calls.Type) !void {
        if (try self.index(kind)) |i| return out.print(self.a, "compound_{d}", .{i});
        return bounds.decoder(out, self.a, kind);
    }

    pub fn support(self: *const Projection, base: []const @import("exports.zig").Support) ![]@import("exports.zig").Support {
        const rows = try self.a.alloc(@import("exports.zig").Support, base.len + self.exports.len);
        @memcpy(rows[0..base.len], base);
        for (self.exports, rows[base.len..], 0..) |item, *row, i| row.* = .{ .name = item.api, .implementation = self.type_names.items[i] };
        return rows;
    }

    pub fn emit(self: *Projection, out: *std.ArrayList(u8)) !void {
        if (self.nodes.items.len == 0) return;
        for (self.exports, 0..) |item, i| {
            const fields = if (item.kind == .record) item.kind.record.fields else item.kind.tuple.fields;
            try out.print(self.a, "pub struct {s}(", .{self.type_names.items[i]});
            for (fields, 0..) |field, field_index| {
                if (field_index != 0) try out.appendSlice(self.a, ", ");
                try out.appendSlice(self.a, "pub ");
                try self.typeName(out, field);
            }
            try out.appendSlice(self.a, ");\n");
        }
        // Private aliases keep shared graphs linear in generated source and
        // avoid repeating complex tuple types in every helper signature.
        for (self.nodes.items, 0..) |node, i| if (try self.exported(node.kind) == null) {
            const kind = node.kind;
            try out.print(self.a, "pub type Compound{d} = ", .{i});
            try self.bodyName(out, kind);
            try out.appendSlice(self.a, ";\n");
        };
        for (self.bounded.items) |kind| try bounds.reply(out, self.a, kind);
        try out.print(self.a, "const MAX_REPLY_DEPTH: usize = {d};\nconst MAX_REPLY_WORK: usize = {d};\n", .{ max_reply_depth, max_reply_work });
        try out.appendSlice(self.a, @embedFile("templates/compound.rs"));
        for (self.nodes.items, 0..) |node, i| {
            const kind = node.kind;
            var root = false;
            for (self.methods) |method| if (method.call.effect != .tell and std.meta.eql(method.call.result, kind)) {
                root = true;
            };
            if (root) {
                try out.print(self.a, "fn compound_{d}(value: Argument) -> Result<", .{i});
                try self.typeName(out, kind);
                try out.print(self.a, ", Error> {{\n\tcompound_{d}_at(\n\t\tvalue,\n\t\t&mut DecodeBudget {{\n\t\t\tremaining: MAX_REPLY_WORK,\n\t\t}},\n\t\t0,\n\t)\n}}\n", .{i});
            }
            try out.print(self.a, "fn compound_{d}_at(value: Argument, budget: &mut DecodeBudget, depth: usize) -> Result<", .{i});
            try self.typeName(out, kind);
            try out.appendSlice(self.a, ", Error> {\n\tbudget.step(depth)?;\n");
            if (kind == .list) {
                try out.appendSlice(self.a, "\tlet Argument::List(values) = value else {\n\t\treturn Err(Error::InvalidReply);\n\t};\n");
                if (kind.list.max_items) |max| try out.print(self.a, "\tif values.len() as u128 > {d}u128 {{\n\t\treturn Err(Error::InvalidReply);\n\t}}\n", .{max});
                // Typed lists cannot reuse Vec<Argument>'s layout. Reserve once,
                // after schema/work checks, and move each owned child into it.
                const work = try self.minimumWork(kind.list.element);
                try out.appendSlice(self.a, "\tif values.len() > budget.remaining");
                if (work != 1) try out.print(self.a, " / {d}", .{work});
                try out.appendSlice(self.a, " {\n\t\treturn Err(Error::ResourceLimit);\n\t}\n\tlet mut result = Vec::with_capacity(values.len());\n\tfor value in values {\n\t\tresult.push(");
                try self.child(out, kind.list.element, "value");
                try out.appendSlice(self.a, "?);\n\t}\n\tOk(result)\n}\n");
            } else {
                const fields = if (kind == .record) kind.record.fields else kind.tuple.fields;
                if (kind == .record) {
                    try out.appendSlice(self.a, "\tlet Argument::Tagged { tag, value: values } = value else {\n\t\treturn Err(Error::InvalidReply);\n\t};\n\tif tag != ");
                    try literal(out, self.a, kind.record.tag);
                    try out.appendSlice(self.a, " {\n\t\treturn Err(Error::InvalidReply);\n\t}\n");
                } else try out.appendSlice(self.a, "\tlet Argument::List(values) = value else {\n\t\treturn Err(Error::InvalidReply);\n\t};\n");
                if (fields.len == 0) try out.appendSlice(self.a, "\tif !values.is_empty() {\n\t\treturn Err(Error::InvalidReply);\n\t}\n") else try out.print(self.a, "\tif values.len() != {d} {{\n\t\treturn Err(Error::InvalidReply);\n\t}}\n", .{fields.len});
                if (fields.len != 0) try out.appendSlice(self.a, "\tlet mut fields = values.into_iter();\n");
                try out.appendSlice(self.a, "\tOk(");
                if (try self.exported(kind)) |name| try out.appendSlice(self.a, name);
                try out.appendSlice(self.a, if (fields.len == 0) "(" else "(\n");
                for (fields) |field| {
                    try out.appendSlice(self.a, "\t\t");
                    try self.child(out, field, "fields.next().ok_or(Error::InvalidReply)?");
                    try out.appendSlice(self.a, "?,\n");
                }
                try out.appendSlice(self.a, if (fields.len == 0) "))\n}\n" else "\t))\n}\n");
            }
        }
    }

    // This shared score counts inline structure and mandatory decoding work.
    // Admission refuses saturation before output, so admitted scores stay exact
    // when reused to bound typed-list reservation against the runtime budget.
    fn minimumWork(self: *Projection, kind: calls.Type) !usize {
        try self.spend();
        const index_value = try self.index(kind) orelse return 1;
        if (self.nodes.items[index_value].minimum_work != 0) return self.nodes.items[index_value].minimum_work;
        var work: usize = 1;
        const fields = switch (kind) {
            .tuple => |tuple| tuple.fields,
            .record => |record| record.fields,
            .list => &.{},
            else => unreachable,
        };
        for (fields) |field| {
            work += try self.minimumWork(field);
            if (work > max_inline_structure) {
                work = max_inline_structure + 1;
                break;
            }
        }
        self.nodes.items[index_value].minimum_work = work;
        return work;
    }

    fn child(self: *Projection, out: *std.ArrayList(u8), kind: calls.Type, value: []const u8) !void {
        if (try self.index(kind)) |i| {
            try out.print(self.a, "compound_{d}_at({s}, budget, depth + 1)", .{ i, value });
        } else {
            // value is opaque: charge one leaf without traversing its contents.
            try out.appendSlice(self.a, "{\n\t\t\tbudget.step(depth + 1)?;\n\t\t\t");
            if (kind == .value) try out.appendSlice(self.a, "Ok::<_, Error>") else try bounds.decoder(out, self.a, kind);
            try out.print(self.a, "({s})\n\t\t}}", .{value});
        }
    }
};
