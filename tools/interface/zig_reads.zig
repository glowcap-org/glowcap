//! Narrow Tasks read checks over normalized calls. Only the six named roles below
//! are projected. Disclosure and host-width storage conversions remain with callers.
const std = @import("std");
const calls = @import("calls.zig");
const literal = @import("literal.zig").write;
const Role = enum { board_lists, board_list, list_name, list_count, list_task, task_text };

pub fn emit(out: *std.ArrayList(u8), a: std.mem.Allocator, reads: []const calls.Named) !void {
    var index: ?calls.Type = null;
    var seen: std.EnumSet(Role) = .{};
    for (reads) |method| {
        const role = std.meta.stringToEnum(Role, method.api) orelse return error.UnsupportedProjection;
        if (seen.contains(role)) return error.UnsupportedProjection;
        seen.insert(role);
        const call = method.call;
        if (call.effect != .call or call.required_parameters > call.parameters.len) return error.UnsupportedProjection;
        switch (role) {
            .board_list, .list_task => if (call.result != .target) return error.UnsupportedProjection,
            .list_name, .task_text => if (call.result != .text) return error.UnsupportedProjection,
            .board_lists, .list_count => if (call.result != .integer) return error.UnsupportedProjection,
        }
        try out.print(a, "\npub const {s}_verb = ", .{method.api});
        try literal(out, a, call.wire_name orelse return error.UnsupportedProjection);
        try out.appendSlice(a, ";\n");
        if (call.parameters.len == 1 and call.required_parameters == 1 and call.parameters[0] == .integer and call.result == .target) {
            if (index) |previous| {
                if (!std.meta.eql(previous, call.parameters[0])) return error.UnsupportedProjection;
            } else index = call.parameters[0];
        } else if (call.parameters.len != 0 or (call.result != .text and call.result != .integer)) return error.UnsupportedProjection;
        if (call.result == .text) {
            if (role == .list_name) {
                try out.print(a, "pub const max_name_bytes: u64 = {d};\n", .{call.result.text.max orelse return error.UnsupportedProjection});
            }
            try textReply(out, a, method.api, call.result.text);
        } else if (call.result == .integer) {
            const limits = call.result.integer;
            const min = limits.min orelse return error.UnsupportedProjection;
            const max = limits.max orelse return error.UnsupportedProjection;
            if (min < 0 or max < min) return error.UnsupportedProjection;
            const capacity = switch (role) {
                .board_lists => "max_lists",
                .list_count => "max_tasks",
                else => return error.UnsupportedProjection,
            };
            try out.print(a, "pub const {s}: u64 = {d};\npub fn ", .{ capacity, max });
            try functionName(out, a, method.api);
            try out.print(a, "Reply(count: usize) error{{InvalidReply}}!i64 {{\n    if (@as(u128, count) < {d} or @as(u128, count) > {d}) return error.InvalidReply;\n    return @intCast(count);\n}}\n", .{ min, max });
        }
    }
    if (seen.count() != @typeInfo(Role).@"enum".field_names.len) return error.UnsupportedProjection;
    const limits = (index orelse return error.UnsupportedProjection).integer;
    const min = limits.min orelse return error.UnsupportedProjection;
    const max = limits.max orelse return error.UnsupportedProjection;
    if (max < min) return error.UnsupportedProjection;
    try out.print(a,
        \\/// Validate the schema's integer domain. The caller converts to its storage index.
        \\pub fn indexArguments(args: anytype) error{{InvalidArguments}}!i64 {{
        \\    if (args.len != 1 or args[0] != .integer) return error.InvalidArguments;
        \\    const index = args[0].integer;
        \\    if (index < {d} or index > {d}) return error.InvalidArguments;
        \\    return index;
        \\}}
        \\
    , .{ min, max });
    try out.appendSlice(a,
        \\pub fn readArguments(args: anytype) error{InvalidArguments}!void {
        \\    if (args.len != 0) return error.InvalidArguments;
        \\}
        \\
    );
}

fn textReply(out: *std.ArrayList(u8), a: std.mem.Allocator, api: []const u8, limits: @import("call_type.zig").ByteBounds) !void {
    const max = limits.max orelse return error.UnsupportedProjection;
    if (max < limits.min) return error.UnsupportedProjection;
    try out.print(a, "/// Borrows stored payload through the hosting turn. Checks UTF-8 once after enforcing a {d}-byte maximum. No copy or allocation.\npub fn ", .{max});
    try functionName(out, a, api);
    try out.print(a,
        \\Reply(bytes: []const u8) error{{InvalidReply}}![]const u8 {{
        \\    if (@as(u128, bytes.len) < {d} or @as(u128, bytes.len) > {d}) return error.InvalidReply;
        \\    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidReply;
        \\    return bytes;
        \\}}
        \\
    , .{ limits.min, max });
}

fn functionName(out: *std.ArrayList(u8), a: std.mem.Allocator, api: []const u8) !void {
    var uppercase = false;
    for (api) |byte| {
        if (byte == '_') {
            uppercase = true;
        } else {
            try out.append(a, if (uppercase) std.ascii.toUpper(byte) else byte);
            uppercase = false;
        }
    }
}
