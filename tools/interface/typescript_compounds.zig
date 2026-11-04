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
        .text => try out.appendSlice(a, "text"),
        .nothing => try out.appendSlice(a, "nothing"),
        else => try scalars.decoder(out, a, kind),
    }
}

pub fn emit(out: *std.ArrayList(u8), a: std.mem.Allocator, projection: *graph.Graph, methods: []const calls.Named) !void {
    if (projection.nodes.items.len == 0) return;
    for (projection.nodes.items, 0..) |node, i| {
        try out.print(a, "type Compound{d} = ", .{i});
        switch (node.kind) {
            .list => |list| {
                try out.appendSlice(a, "Array<");
                try typeName(out, a, projection, list.element);
                try out.appendSlice(a, ">");
            },
            .tuple, .record => {
                if (node.kind == .record) {
                    try out.appendSlice(a, "Tagged & {\n\treadonly tag: ");
                    try literal(out, a, node.kind.record.tag);
                    try out.appendSlice(a, ";\n\treadonly value: ");
                }
                try out.appendSlice(a, "[");
                const fields = if (node.kind == .record) node.kind.record.fields else node.kind.tuple.fields;
                for (fields, 0..) |field, j| {
                    if (j != 0) try out.appendSlice(a, ", ");
                    try typeName(out, a, projection, field);
                }
                try out.appendSlice(a, if (node.kind == .record) "];\n}" else "]");
            },
            else => unreachable,
        }
        try out.appendSlice(a, ";\n");
    }
    try out.print(a, "const MAX_REPLY_DEPTH = {d};\nconst MAX_REPLY_WORK = {d};\n", .{ graph.max_reply_depth, graph.max_reply_work });
    try out.appendSlice(a, @embedFile("templates/compound.ts.in"));
    for (projection.nodes.items, 0..) |node, i| {
        var root = false;
        for (methods) |method| if (method.call.effect == .call and std.meta.eql(method.call.result, node.kind)) {
            root = true;
        };
        if (root) try out.print(a, "function compound_{d}(value: Argument): Compound{d} {{\n\treturn compound_{d}_at(value, {{ remaining: MAX_REPLY_WORK }}, 0);\n}}\n", .{ i, i, i });
        try out.print(a, "function compound_{d}_at(value: Argument, budget: DecodeBudget, depth: number): Compound{d} {{\n\tstep(budget, depth);\n", .{ i, i });
        const kind = node.kind;
        if (kind == .record) {
            try out.appendSlice(a, "\tif (!(value instanceof Tagged) || value.tag !== ");
            try literal(out, a, kind.record.tag);
            try out.appendSlice(a, ") throw new TypeError(\"wrong record reply\");\n\tconst values = value.value;\n");
        } else try out.appendSlice(a, "\tconst values = value;\n");
        try out.appendSlice(a, "\tif (!Array.isArray(values)) throw new TypeError(\"expected list reply\");\n");
        if (kind == .list) {
            if (kind.list.max_items) |max| try out.print(a, "\tif (values.length > {d}n) throw new TypeError(\"list reply outside bounds\");\n", .{max});
            const work = try projection.minimumWork(kind.list.element);
            try out.print(a, "\tif (values.length > budget.remaining / {d}) throw new ResourceLimit(\"reply work limit\");\n\tfor (let index = 0; index < values.length; index++) {{\n", .{work});
            try child(out, a, projection, kind.list.element, "values[index]", "\t\t");
            try out.appendSlice(a, "\t}\n");
        } else {
            const fields = if (kind == .record) kind.record.fields else kind.tuple.fields;
            try out.print(a, "\tif (values.length !== {d}) throw new TypeError(\"wrong reply arity\");\n", .{fields.len});
            for (fields, 0..) |field, j| {
                var buffer: [32]u8 = undefined;
                try child(out, a, projection, field, try std.fmt.bufPrint(&buffer, "values[{d}]", .{j}), "\t");
            }
        }
        try out.print(a, "\treturn value as Compound{d};\n}}\n", .{i});
    }
}

fn child(out: *std.ArrayList(u8), a: std.mem.Allocator, projection: *graph.Graph, kind: calls.Type, value: []const u8, indent: []const u8) !void {
    if (try projection.index(kind)) |i| {
        try out.print(a, "{s}compound_{d}_at({s}, budget, depth + 1);\n", .{ indent, i, value });
    } else {
        try out.print(a, "{s}step(budget, depth + 1);\n", .{indent});
        // Opaque value is one leaf. Never traverse or rematerialize its contents.
        if (kind == .value) {
            try out.print(a, "{s}if ({s} === undefined) throw new TypeError(\"expected opaque value reply\");\n", .{ indent, value });
            return;
        }
        try out.appendSlice(a, indent);
        try decoder(out, a, projection, kind);
        try out.print(a, "({s});\n", .{value});
    }
}
