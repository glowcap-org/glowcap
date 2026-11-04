//! Rust ordinary-call projection for the independently hosted callback fixture.
const std = @import("std");
const calls = @import("calls.zig");
const literal = @import("literal.zig").write;

pub fn emit(a: std.mem.Allocator, methods: []const calls.Named) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "// Generated from checked interface descriptions.\n");
    var needs: @import("rust_support.zig").Needs = .{};
    for (methods) |method| {
        const call = method.call;
        needs.ordinary = needs.ordinary or call.effect != .receipt;
        needs.receipt = needs.receipt or call.effect == .receipt;
        needs.optional = needs.optional or call.required_parameters < call.parameters.len;
        if (call.effect != .tell) needs.replies.insert(call.result);
        for (call.parameters) |parameter| {
            needs.arguments = needs.arguments or parameter == .value;
            needs.references = needs.references or parameter == .target or parameter == .pending_target;
        }
    }
    try needs.emit(&out, a);
    for (methods) |method| {
        if (method.call.effect == .receipt) try emitPrepared(&out, a, method.call, method.api) else try emitCall(&out, a, method.call, method.api);
    }
    return out.toOwnedSlice(a);
}

fn emitCall(out: *std.ArrayList(u8), a: std.mem.Allocator, call: calls.Call, api: []const u8) !void {
    const optional = call.required_parameters < call.parameters.len;
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
        try out.print(a, ") -> {s}Pending<{s}>{s} {{\n", .{ if (optional) "Result<" else "", resultType(call.result), if (optional) ", Error>" else "" });
    }
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
    try out.appendSlice(a, if (call.effect == .tell) (if (optional) "\tsession\n\t\t.tell(target, " else "\tsession.tell(target, ") else "\tlet raw = session.send(target, ");
    if (call.wire_name) |name| try literal(out, a, name) else try out.appendSlice(a, "None::<&str>");
    if (optional) {
        try out.appendSlice(a, ", &arguments[..count]");
    } else {
        try out.appendSlice(a, ", &[");
        try emitArguments(out, a, call);
        try out.appendSlice(a, "]");
    }
    if (call.effect == .tell) {
        try out.appendSlice(a, if (optional) ")\n\t\t.map_err(Error::Runtime)\n}\n" else ").map_err(Error::Runtime)\n}\n");
    } else {
        try out.print(a, ");\n\t{s}Pending::new(raw, {s}){s}\n}}\n", .{ if (optional) "Ok(" else "", switch (call.result) {
            .target => "capability",
            .text => "text",
            .nothing => "nothing",
            .value => "Ok",
            .pending_target, .pending_value => return error.UnsupportedProjection,
        }, if (optional) ")" else "" });
    }
}

fn emitArguments(out: *std.ArrayList(u8), a: std.mem.Allocator, call: calls.Call) !void {
    for (call.parameters, 0..) |parameter, i| {
        const optional = call.required_parameters < call.parameters.len;
        if (optional) try out.appendSlice(a, "\t\t") else if (i != 0) try out.appendSlice(a, ", ");
        try out.print(a, "arg{d}{s}", .{ i, if (i >= call.required_parameters) switch (parameter) {
            .target, .pending_target => ".map(Reference::argument).unwrap_or(Argument::Void)",
            .text, .nothing => ".map(Argument::from).unwrap_or(Argument::Void)",
            .value => ".unwrap_or(Argument::Void)",
            .pending_value => return error.UnsupportedProjection,
        } else switch (parameter) {
            .target, .pending_target => ".into().argument()",
            .text, .nothing => ".into()",
            .value => "",
            .pending_value => return error.UnsupportedProjection,
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

fn parameterType(kind: calls.Kind) []const u8 {
    return switch (kind) {
        .target, .pending_target => "impl Into<Reference<'a>>",
        .text => "&str",
        .value => "Argument",
        .nothing => "()",
        .pending_value => "&RemotePromise",
    };
}

fn resultType(kind: calls.Kind) []const u8 {
    return switch (kind) {
        .target, .pending_target => "Ref",
        .pending_value => "Argument",
        .text => "String",
        .value => "Argument",
        .nothing => "()",
    };
}
