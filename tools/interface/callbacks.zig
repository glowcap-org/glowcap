//! Rust ordinary-call projection for the independently hosted callback fixture.
const std = @import("std");
const calls = @import("calls.zig");
const bounds = @import("rust_bounds.zig");
const literal = @import("literal.zig").write;
const exports = @import("exports.zig");
const compounds = @import("rust_compounds.zig");

pub fn emit(a: std.mem.Allocator, methods: []const calls.Named, types: []const calls.TypeExport) ![]u8 {
    var projection = try compounds.Projection.init(a, methods, types);
    defer projection.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const needs = try requirements(methods, &projection);
    try needs.emit(&out, a);
    try emitMethods(&out, a, methods, &projection);
    const support = try projection.support(&needs.exports());
    defer a.free(support);
    return exports.rust(a, out.items, methods, support);
}

pub fn requirements(methods: []const calls.Named, projection: *const compounds.Projection) !@import("rust_support.zig").Needs {
    var needs: @import("rust_support.zig").Needs = .{ .replies = projection.graph.leaves };
    for (methods) |method| {
        const call = method.call;
        try bounds.supported(call.result);
        for (call.parameters) |parameter| {
            if (@import("compound_graph.zig").compound(parameter)) return error.UnsupportedProjection;
            try bounds.supported(parameter);
        }
        needs.ordinary = needs.ordinary or call.effect != .receipt;
        needs.receipt = needs.receipt or call.effect == .receipt;
        needs.optional = needs.optional or call.required_parameters < call.parameters.len;
        if (call.effect != .tell) needs.replies.insert(std.meta.activeTag(call.result));
        for (call.parameters) |parameter| {
            needs.arguments = needs.arguments or parameter == .value or parameter == .symbol or parameter == .error_value;
            needs.references = needs.references or parameter == .target or parameter == .pending_target;
        }
    }
    return needs;
}

pub fn emitMethods(out: *std.ArrayList(u8), a: std.mem.Allocator, methods: []const calls.Named, projection: *compounds.Projection) !void {
    if (projection.graph.nodes.items.len == 0) try bounds.replies(out, a, methods);
    try projection.emit(out);
    for (methods, 0..) |method, i| {
        var buffer: [32]u8 = undefined;
        const name = try exports.callName(&buffer, i);
        if (method.call.effect == .receipt) try emitPrepared(out, a, method.call, name) else try emitCall(out, a, method.call, name, projection);
    }
}

fn emitCall(out: *std.ArrayList(u8), a: std.mem.Allocator, call: calls.Call, api: []const u8, projection: *compounds.Projection) !void {
    const optional = call.required_parameters < call.parameters.len;
    var fallible = optional;
    for (call.parameters) |parameter| fallible = fallible or bounds.fallible(parameter);
    var has_references = false;
    for (call.parameters) |parameter| if (parameter == .target or parameter == .pending_target) {
        has_references = true;
    };
    try out.print(a, "\npub fn {s}{s}(", .{ api, if (has_references) "<'a>" else "" });
    try out.appendSlice(a, if (optional) "\n\tsession: &Session,\n\ttarget: impl AsSendTarget,\n" else "session: &Session, target: impl AsSendTarget");
    for (call.parameters, 0..) |parameter, i| {
        const omitted = i >= call.required_parameters;
        const kind = if (omitted and (parameter == .target or parameter == .pending_target)) "Reference<'a>" else parameterType(parameter);
        if (optional and i == call.required_parameters) try out.appendSlice(a, "\t// Omit only a trailing suffix of these arguments.\n");
        try out.print(a, "{s}arg{d}: {s}{s}{s}{s}", .{ if (optional) "\t" else ", ", i, if (omitted) "Option<" else "", kind, if (omitted) ">" else "", if (optional) ",\n" else "" });
    }
    if (call.effect == .tell) {
        try out.appendSlice(a, ") -> Result<(), Error> {\n");
    } else {
        try out.print(a, ") -> {s}Pending<", .{if (fallible) "Result<" else ""});
        try projection.typeName(out, call.result);
        try out.print(a, ">{s} {{\n", .{if (fallible) ", Error>" else ""});
    }
    for (call.parameters, 0..) |parameter, i| try bounds.argument(out, a, parameter, i, i >= call.required_parameters);
    if (optional) {
        try out.appendSlice(a, "\tlet count = ");
        if (call.required_parameters != 0) try out.print(a, "{d} + ", .{call.required_parameters});
        try out.appendSlice(a, "optional_argument_count(&[");
        for (call.parameters[call.required_parameters..], call.required_parameters..) |_, i| {
            if (i != call.required_parameters) try out.appendSlice(a, ", ");
            try out.print(a, "arg{d}.is_some()", .{i});
        }
        try out.appendSlice(a, "])?;\n\tlet arguments = [\n\t\t// Fixed stack scratch; omitted slots are outside the sent prefix.\n");
        try emitArguments(out, a, call);
        try out.appendSlice(a, "\t];\n");
    }
    try out.appendSlice(a, if (call.effect == .tell) "\tlet result = session.tell(target, " else "\tlet raw = session.send(target, ");
    if (call.wire_name) |name| try literal(out, a, name) else try out.appendSlice(a, "None::<&str>");
    if (optional) {
        try out.appendSlice(a, ", &arguments[..count]");
    } else {
        try out.appendSlice(a, ", &[");
        try emitArguments(out, a, call);
        try out.appendSlice(a, "]");
    }
    if (call.effect == .tell) {
        try out.appendSlice(a, ");\n\tresult.map_err(Error::Runtime)\n}\n");
    } else {
        try out.print(a, ");\n\t{s}Pending::new(raw, ", .{if (fallible) "Ok(" else ""});
        try projection.decoder(out, call.result);
        try out.print(a, "){s}\n}}\n", .{if (fallible) ")" else ""});
    }
}

// Scalar Vec/String inputs already own their snapshot. Packing moves those
// owners into Argument; local validation refusal drops them without copying.
fn emitArguments(out: *std.ArrayList(u8), a: std.mem.Allocator, call: calls.Call) !void {
    for (call.parameters, 0..) |parameter, i| {
        const optional = call.required_parameters < call.parameters.len;
        if (optional) try out.appendSlice(a, "\t\t") else if (i != 0) try out.appendSlice(a, ", ");
        if (i < call.required_parameters and (parameter == .symbol or parameter == .error_value)) {
            try out.print(a, "Argument::{s}(arg{d})", .{ if (parameter == .symbol) "Symbol" else "Error", i });
            if (optional) try out.appendSlice(a, ",\n");
            continue;
        }
        try out.print(a, "arg{d}{s}", .{ i, if (i >= call.required_parameters) switch (parameter) {
            .target, .pending_target => ".map(Reference::argument).unwrap_or(Argument::Void)",
            .text, .nothing, .integer, .boolean, .float64 => ".map(Argument::from).unwrap_or(Argument::Void)",
            .bytes => ".map(Argument::Bytes).unwrap_or(Argument::Void)",
            .symbol => ".map(Argument::Symbol).unwrap_or(Argument::Void)",
            .error_value => ".map(Argument::Error).unwrap_or(Argument::Void)",
            .value => ".unwrap_or(Argument::Void)",
            .pending_value, .list, .tuple, .record => return error.UnsupportedProjection,
        } else switch (parameter) {
            .target, .pending_target => ".into().argument()",
            .text, .nothing, .integer, .boolean, .float64, .bytes => ".into()",
            .symbol, .error_value => "",
            .value => "",
            .pending_value, .list, .tuple, .record => return error.UnsupportedProjection,
        } });
        if (optional) try out.appendSlice(a, ",\n");
    }
}

fn emitPrepared(out: *std.ArrayList(u8), a: std.mem.Allocator, call: calls.Call, api: []const u8) !void {
    // The retained-pending qualification is deliberately one owned promise
    // argument and a void result. Other receipt shapes need their own proof.
    if (call.required_parameters != 1 or call.parameters.len != 1 or call.parameters[0] != .pending_value or call.result != .nothing) return error.UnsupportedProjection;
    try out.print(a, "\npub fn {s}(\n\tsession: Rc<Session>,\n\ttarget: Ref,\n\tpending: &RemotePromise,\n) -> Result<impl Future<Output = Result<PreparedMutation<()>, Error>> + use<>, Error> {{\n", .{api});
    try out.appendSlice(a, "\tlet owned = pending.retain_for(&session.host())?;\n\tOk(prepare_mutation(\n\t\tsession,\n\t\ttarget,\n\t\tmove |number| vec![number.into(), ");
    try literal(out, a, call.wire_name orelse return error.UnsupportedProjection);
    try out.appendSlice(a, ".into(), owned.into()],\n\t\tnothing,\n\t))\n}\n");
}

fn parameterType(kind: calls.Type) []const u8 {
    return switch (kind) {
        .target, .pending_target => "impl Into<Reference<'a>>",
        .text => "&str",
        .integer => "i64",
        .boolean => "bool",
        .bytes => "Vec<u8>",
        .symbol, .error_value => "String",
        .float64 => "f64",
        .value => "Argument",
        .nothing => "()",
        .pending_value => "&RemotePromise",
        .list, .tuple, .record => unreachable,
    };
}
