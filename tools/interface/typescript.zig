//! Narrow TypeScript promise-shape probe over the shared checked call model.
const std = @import("std");
const calls = @import("calls.zig");
const literal = @import("literal.zig").write;

pub fn emit(a: std.mem.Allocator, methods: []const calls.Named) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "// Generated from checked interface descriptions.\n");
    try out.appendSlice(a, @embedFile("templates/pending.ts.in"));
    for (methods) |method| {
        const call = method.call;
        if (call.effect == .receipt) return error.UnsupportedProjection;
        try out.print(a, "\nexport function {s}(\n\tsession: Session,\n\ttarget: Ref | RemotePromise,\n", .{method.api});
        for (call.parameters, 0..) |kind, i| {
            if (kind == .pending_value) return error.UnsupportedProjection;
            try out.print(a, "\targ{d}{s}: {s},\n", .{ i, if (i >= call.required_parameters) "?" else "", switch (kind) {
                .nothing => "undefined",
                .target, .pending_target => "Ref | RemotePromise",
                else => typeName(kind),
            } });
        }
        if (call.effect == .tell) {
            try out.appendSlice(a, "): Promise<void> {\n");
        } else {
            try out.print(a, "): Pending<{s}> {{\n", .{typeName(call.result)});
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
                .pending_value => return error.UnsupportedProjection,
            }
            try out.print(a, ") throw new TypeError(\"invalid argument {d}\");\n{s}args[{d}] = ", .{ i, indent, i });
            if (kind == .nothing) try out.appendSlice(a, "null") else try out.print(a, "arg{d}", .{i});
            try out.appendSlice(a, ";\n");
            if (optional) try out.appendSlice(a, "\t}\n");
        }
        try out.appendSlice(a, if (call.effect == .tell) "\treturn session.tell(target, " else "\tconst raw = session.send(target, ");
        if (call.wire_name) |name| try literal(&out, a, name) else try out.appendSlice(a, "null");
        try out.appendSlice(a, ", args);\n");
        if (call.effect != .tell) try out.print(a, "\treturn new Pending(raw, {s});\n", .{switch (call.result) {
            .target => "capability",
            .text => "text",
            .nothing => "nothing",
            else => return error.UnsupportedProjection,
        }});
        try out.appendSlice(a, "}\n");
    }
    return out.toOwnedSlice(a);
}

fn typeName(kind: calls.Kind) []const u8 {
    return switch (kind) {
        .target => "Ref",
        .pending_target => "Ref | RemotePromise",
        .text => "string",
        .nothing => "void",
        .value => "Argument",
        .pending_value => "RemotePromise",
    };
}
