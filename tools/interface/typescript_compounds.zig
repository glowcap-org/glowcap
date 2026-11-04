//! Validated views of existing runtime arrays and string-tagged records.
const std = @import("std");
const calls = @import("calls.zig");
const graph = @import("compound_graph.zig");
const scalars = @import("typescript_scalars.zig");
const literal = @import("literal.zig").write;

pub fn typeName(out: *std.ArrayList(u8), a: std.mem.Allocator, projection: *graph.Graph, kind: calls.Type) !void {
    if (try projection.index(kind)) |i| return out.print(a, "Compound{d}", .{i});
    try out.appendSlice(a, if (kind == .nothing) "null" else scalars.typeName(kind));
}

pub fn decoder(out: *std.ArrayList(u8), a: std.mem.Allocator, projection: *graph.Graph, kind: calls.Type) !void {
    if (try projection.index(kind)) |i| return out.print(a, "compound_{d}", .{i});
    switch (kind) {
        .target => try out.appendSlice(a, "capability"),
        .text => try scalars.decoder(out, a, kind),
        .nothing => try out.appendSlice(a, "nothing"),
        else => try scalars.decoder(out, a, kind),
    }
}

pub fn emit(out: *std.ArrayList(u8), a: std.mem.Allocator, projection: *graph.Graph, methods: []const calls.Named) !void {
    if (projection.nodes.items.len == 0) return;
    var sequences = false;
    for (projection.nodes.items) |node| {
        sequences = sequences or node.kind != .record;
    }
    if (sequences) try out.appendSlice(a, "type Sequence<T> = Argument & object & ArrayLike<T> & Iterable<T>;\n");
    for (projection.nodes.items, 0..) |node, i| {
        try out.print(a, "type Compound{d} = ", .{i});
        switch (node.kind) {
            .list => |list| {
                try out.appendSlice(a, "Sequence<");
                try typeName(out, a, projection, list.element);
                try out.appendSlice(a, ">");
            },
            .tuple => |tuple| {
                try out.appendSlice(a, "Sequence<");
                if (tuple.fields.len == 0) try out.appendSlice(a, "never");
                for (tuple.fields, 0..) |field, j| {
                    if (j != 0) try out.appendSlice(a, " | ");
                    try typeName(out, a, projection, field);
                }
                try out.print(a, "> & {{\n\treadonly length: {d};\n", .{tuple.fields.len});
                for (tuple.fields, 0..) |field, j| {
                    try out.print(a, "\treadonly {d}: ", .{j});
                    try typeName(out, a, projection, field);
                    try out.appendSlice(a, ";\n");
                }
                try out.appendSlice(a, "}");
            },
            .record => |record| {
                try out.appendSlice(a, "Tagged & {\n\treadonly tag: ");
                try literal(out, a, record.tag);
                try out.appendSlice(a, ";\n\treadonly value: [");
                for (record.fields, 0..) |field, j| {
                    if (j != 0) try out.appendSlice(a, ", ");
                    try typeName(out, a, projection, field);
                }
                try out.appendSlice(a, "];\n}");
            },
            else => unreachable,
        }
        try out.appendSlice(a, ";\n");
    }
    try out.print(a, "const MAX_REPLY_WORK = {d};\n", .{graph.max_reply_work});
    try out.appendSlice(a, @embedFile("templates/compound.ts.in"));
    for (projection.nodes.items, 0..) |node, i| {
        var root = false;
        for (methods) |method| if (method.call.effect == .call and std.meta.eql(method.call.result, node.kind)) {
            root = true;
        };
        if (root) try out.print(a, "function compound_{d}(value: Argument): Compound{d} {{\n\treturn compound_{d}_at(value, {{ remaining: MAX_REPLY_WORK }});\n}}\n", .{ i, i, i });
        try out.print(a, "function compound_{d}_at(value: Argument, budget: DecodeBudget): Compound{d} {{\n", .{ i, i });
        try out.appendSlice(a, "\tstep(budget);\n");
        const kind = node.kind;
        if (kind == .record) {
            try out.appendSlice(a, "\tif (!(value instanceof Tagged) || value.tag !== ");
            try literal(out, a, kind.record.tag);
            try out.appendSlice(a, ") throw new TypeError(\"wrong record reply\");\n\tconst values = value.value;\n");
        } else try out.appendSlice(a, "\tconst values = value;\n");
        if (kind != .record) try out.appendSlice(a, "\tif (!Array.isArray(values) && !(values instanceof BigInt64Array)) throw new TypeError(\"expected list reply\");\n");
        if (kind == .list) {
            if (kind.list.max_items) |max| try out.print(a, "\tif (values.length > {d}n) throw new TypeError(\"list reply outside bounds\");\n", .{max});
            if (kind.list.element != .value) {
                if (kind.list.element == .integer and scalars.packedInteger(kind.list.element.integer)) {
                    try out.appendSlice(a, "\tif (!(values instanceof BigInt64Array)) {\n");
                } else {
                    try out.appendSlice(a, "\tif (values instanceof BigInt64Array) {\n");
                    if (kind.list.element == .integer) {
                        try out.appendSlice(a, "\t\tfor (let index = 0; index < values.length; index++) {\n");
                        try packedBounds(out, a, kind.list.element.integer, "values[index]", "\t\t\t");
                        try out.appendSlice(a, "\t\t}\n");
                    } else try out.appendSlice(a, "\t\tif (values.length !== 0) throw new TypeError(\"integer list has incompatible elements\");\n");
                    try out.appendSlice(a, "\t} else {\n");
                }
                try out.appendSlice(a, "\t\tfor (let index = 0; index < values.length; index++) {\n");
                try child(out, a, projection, kind.list.element, "values[index]", "\t\t\t");
                try out.appendSlice(a, "\t\t}\n\t}\n");
            }
        } else {
            const fields = if (kind == .record) kind.record.fields else kind.tuple.fields;
            try out.print(a, "\tif (values.length !== {d}) throw new TypeError(\"wrong reply arity\");\n", .{fields.len});
            var branch = false;
            if (kind == .tuple) {
                var compatible = true;
                var array_checks = false;
                var packed_checks = false;
                for (fields) |field| {
                    compatible = compatible and (field == .integer or field == .value);
                    array_checks = array_checks or field != .value;
                    packed_checks = packed_checks or (field == .integer and !scalars.packedInteger(field.integer));
                }
                branch = array_checks;
                if (branch) {
                    if (compatible and !packed_checks) {
                        try out.appendSlice(a, "\tif (!(values instanceof BigInt64Array)) {\n");
                    } else {
                        try out.appendSlice(a, "\tif (values instanceof BigInt64Array) {\n");
                        if (compatible) {
                            for (fields, 0..) |field, j| {
                                var buffer: [32]u8 = undefined;
                                if (field == .integer and !scalars.packedInteger(field.integer)) try packedBounds(out, a, field.integer, try std.fmt.bufPrint(&buffer, "values[{d}]", .{j}), "\t\t");
                            }
                        } else try out.appendSlice(a, "\t\tthrow new TypeError(\"integer tuple has incompatible fields\");\n");
                        try out.appendSlice(a, "\t} else {\n");
                    }
                }
            }
            for (fields, 0..) |field, j| {
                var buffer: [32]u8 = undefined;
                try child(out, a, projection, field, try std.fmt.bufPrint(&buffer, "values[{d}]", .{j}), if (branch) "\t\t" else "\t");
            }
            if (branch) try out.appendSlice(a, "\t}\n");
        }
        try out.print(a, "\treturn value as Compound{d};\n}}\n", .{i});
    }
}

fn child(out: *std.ArrayList(u8), a: std.mem.Allocator, projection: *graph.Graph, kind: calls.Type, value: []const u8, indent: []const u8) !void {
    if (try projection.index(kind)) |i| {
        try out.print(a, "{s}compound_{d}_at({s}, budget);\n", .{ indent, i, value });
    } else {
        // Opaque values need no projection, element read, or schema-work charge.
        if (kind == .value) return;
        try out.print(a, "{s}step(budget);\n", .{indent});
        try out.appendSlice(a, indent);
        try decoder(out, a, projection, kind);
        try out.print(a, "({s});\n", .{value});
    }
}

fn packedBounds(out: *std.ArrayList(u8), a: std.mem.Allocator, limits: @import("call_type.zig").IntegerBounds, value: []const u8, indent: []const u8) !void {
    try out.print(a, "{s}step(budget);\n{s}if (", .{ indent, indent });
    try scalars.integerBounds(out, a, scalars.packedBounds(limits), value);
    try out.appendSlice(a, ") throw new TypeError(\"integer outside bounds\");\n");
}
