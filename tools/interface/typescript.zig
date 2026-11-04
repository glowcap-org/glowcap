//! Narrow TypeScript promise-shape probe over the shared checked call model.
const std = @import("std");
const calls = @import("calls.zig");
const literal = @import("literal.zig").write;
const exports = @import("exports.zig");
const compounds = @import("typescript_compounds.zig");
const graph = @import("compound_graph.zig");
const scalars = @import("typescript_scalars.zig");

pub fn emit(a: std.mem.Allocator, methods: []const calls.Named) ![]u8 {
    var projection = try graph.Graph.init(a, methods);
    defer projection.deinit();
    for (projection.scalar_types.items) |kind| {
        try scalars.supported(kind);
        if (kind == .pending_target or kind == .pending_value) return error.UnsupportedProjection;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "// Generated from checked interface descriptions.\n");
    try out.appendSlice(a, "import { type Argument, Ref, RemotePromise } from \"@glowcap/runtime\";\nimport type { Session } from \"@glowcap/runtime\";\n");
    var pending = false;
    for (methods) |method| pending = pending or method.call.effect == .call;
    const support = [_]exports.Support{
        .{ .name = "Pending", .enabled = pending },
        .{ .name = "ResourceLimit", .enabled = projection.nodes.items.len != 0 },
    };
    var symbols = projection.leaves.contains(.symbol);
    for (methods) |method| for (method.call.parameters) |parameter| {
        symbols = symbols or parameter == .symbol;
    };
    if (symbols) try out.appendSlice(a, "import { Sym } from \"@glowcap/runtime\";\n");
    if (projection.nodes.items.len != 0) {
        var records = false;
        for (projection.nodes.items) |node| {
            records = records or node.kind == .record;
        }
        if (records) try out.appendSlice(a, "import { Tagged } from \"@glowcap/runtime\";\n");
    }
    if (pending) try out.appendSlice(a, @embedFile("templates/pending.ts.in") ++ "\n");
    try scalars.replies(&out, a, projection.scalar_types.items);
    const replies = projection.leaves;
    for ([_]calls.Kind{ .target, .text, .nothing }) |kind| if (replies.contains(kind)) {
        try out.appendSlice(a, switch (kind) {
            .target => "function capability(value: Argument): Ref {\n" ++
                "\tif (!(value instanceof Ref)) throw new TypeError(\"expected capability reply\");\n" ++
                "\treturn value;\n}\n",
            .text => "function text(value: Argument): string {\n" ++
                "\tif (typeof value !== \"string\") throw new TypeError(\"expected string reply\");\n" ++
                "\treturn value;\n}\n",
            .nothing => "function nothing(value: Argument): void {\n" ++
                "\t// The existing TypeScript binding represents the profile's void value as null.\n" ++
                "\tif (value !== null) throw new TypeError(\"expected void reply\");\n}\n",
            else => unreachable,
        });
    };
    try compounds.emit(&out, a, &projection, methods);
    for (methods, 0..) |method, index| {
        const call = method.call;
        for (call.parameters) |parameter| try scalars.supported(parameter);
        if (call.effect == .receipt) return error.UnsupportedProjection;
        var buffer: [32]u8 = undefined;
        try out.print(a, "\nfunction {s}(\n\tsession: Session,\n\ttarget: Ref | RemotePromise,\n", .{try exports.callName(&buffer, index)});
        for (call.parameters, 0..) |kind, i| {
            if (kind == .pending_value) return error.UnsupportedProjection;
            try out.print(a, "\targ{d}{s}: {s},\n", .{ i, if (i >= call.required_parameters) "?" else "", switch (kind) {
                .nothing => "undefined",
                .target, .pending_target => "Ref | RemotePromise",
                else => scalars.typeName(kind),
            } });
        }
        if (call.effect == .tell) {
            try out.appendSlice(a, "): Promise<void> {\n");
        } else {
            try out.appendSlice(a, "): Pending<");
            if (graph.compound(call.result)) try compounds.typeName(&out, a, &projection, call.result) else try out.appendSlice(a, scalars.typeName(call.result));
            try out.appendSlice(a, "> {\n");
        }
        try out.print(a, "\tconst supplied = arguments.length - 2;\n\tif (supplied < {d} || supplied > {d}) throw new TypeError(\"wrong argument count\");\n", .{ call.required_parameters, call.parameters.len });
        try out.appendSlice(a, "\t// One array is allocated at supplied arity; packing adds no payload snapshot.\n\tconst args = new Array<Argument>(supplied);\n");
        for (call.parameters, 0..) |kind, i| {
            const optional = i >= call.required_parameters;
            if (optional) try out.print(a, "\tif (supplied > {d}) {{\n", .{i});
            const indent = if (optional) "\t\t" else "\t";
            try out.print(a, "{s}if (", .{indent});
            switch (kind) {
                .nothing => try out.print(a, "arg{d} !== undefined", .{i}),
                .text => try out.print(a, "typeof arg{d} !== \"string\"", .{i}),
                .target, .pending_target => try out.print(a, "!(arg{d} instanceof Ref) && !(arg{d} instanceof RemotePromise)", .{ i, i }),
                .value => try out.print(a, "arg{d} === undefined", .{i}),
                .pending_value, .list, .tuple, .record => return error.UnsupportedProjection,
                .boolean, .bytes, .symbol, .float64, .error_value => {
                    var name: [32]u8 = undefined;
                    try scalars.invalid(&out, a, kind, try std.fmt.bufPrint(&name, "arg{d}", .{i}));
                },
                .integer => unreachable,
            }
            try out.print(a, ") throw new TypeError(\"invalid argument {d}\");\n{s}args[{d}] = ", .{ i, indent, i });
            if (kind == .nothing) try out.appendSlice(a, "null") else try out.print(a, "arg{d}", .{i});
            try out.appendSlice(a, ";\n");
            if (kind == .bytes and scalars.bounded(kind.bytes)) {
                var name: [32]u8 = undefined;
                try out.print(a, "{s}if (", .{indent});
                try scalars.byteBounds(&out, a, kind.bytes, try std.fmt.bufPrint(&name, "arg{d}", .{i}));
                try out.appendSlice(a, ") throw new TypeError(\"byte argument outside bounds\");\n");
            }
            if (optional) try out.appendSlice(a, "\t}\n");
        }
        try out.appendSlice(a, if (call.effect == .tell) "\treturn session.tell(target, " else "\tconst raw = session.send(target, ");
        if (call.wire_name) |name| try literal(&out, a, name) else try out.appendSlice(a, "null");
        try out.appendSlice(a, ", args);\n");
        if (call.effect != .tell) {
            try out.appendSlice(a, "\treturn new Pending(raw, ");
            switch (call.result) {
                .target => try out.appendSlice(a, "capability"),
                .text => try out.appendSlice(a, "text"),
                .nothing => try out.appendSlice(a, "nothing"),
                .boolean, .bytes, .symbol, .float64, .error_value => try scalars.decoder(&out, a, call.result),
                .list, .tuple, .record => try compounds.decoder(&out, a, &projection, call.result),
                else => return error.UnsupportedProjection,
            }
            try out.appendSlice(a, ");\n");
        }
        try out.appendSlice(a, "}\n");
    }
    try exports.typescript(&out, a, methods, &support);
    return out.toOwnedSlice(a);
}
