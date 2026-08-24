//! MCP `inputSchema` + `tools/call` argument mapping from the CapTP registry leaf.
//! One emitter: argv help and MCP cannot invent different shapes.
const std = @import("std");
const registry = @import("../registry.zig");
const types = @import("../cmd/types.zig");
const argv = @import("../argv.zig");

const Parsed = types.Parsed;

/// Append the JSON Schema object for one CapTP leaf (no surrounding commas).
pub fn appendInputSchema(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cmd: *const registry.Command) !void {
    try out.appendSlice(gpa, "{\"type\":\"object\",\"properties\":{");
    var first = true;
    for (cmd.flags) |f| {
        if (!registry.flagVisibleMcp(f)) continue;
        if (!first) try out.append(gpa, ',');
        first = false;
        try argv.writeJsonString(out, gpa, f.long);
        try out.appendSlice(gpa, ":{\"type\":\"");
        try out.appendSlice(gpa, switch (f.kind) {
            .bool_flag => "boolean",
            .string_flag => "string",
        });
        try out.appendSlice(gpa, "\",\"description\":");
        try argv.writeJsonString(out, gpa, f.help);
        try out.append(gpa, '}');
    }
    for (cmd.positionals) |p| {
        if (!first) try out.append(gpa, ',');
        first = false;
        try argv.writeJsonString(out, gpa, p.name);
        if (p.variadic) {
            try out.appendSlice(gpa, ":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":");
            try argv.writeJsonString(out, gpa, p.help);
            try out.append(gpa, '}');
        } else {
            try out.appendSlice(gpa, ":{\"type\":\"string\",\"description\":");
            try argv.writeJsonString(out, gpa, p.help);
            try out.append(gpa, '}');
        }
    }
    try out.appendSlice(gpa, "},\"required\":[");
    var req_first = true;
    for (cmd.positionals) |p| {
        if (!p.required) continue;
        if (!req_first) try out.append(gpa, ',');
        req_first = false;
        try argv.writeJsonString(out, gpa, p.name);
    }
    try out.appendSlice(gpa, "],\"additionalProperties\":false}");
}

fn jsonGet(obj: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (obj) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn propertyKnown(cmd: *const registry.Command, name: []const u8) bool {
    for (cmd.flags) |flag| {
        if (registry.flagVisibleMcp(flag) and std.mem.eql(u8, flag.long, name)) return true;
    }
    for (cmd.positionals) |positional| {
        if (std.mem.eql(u8, positional.name, name)) return true;
    }
    return false;
}

/// Map MCP `arguments` object into `Parsed` using the leaf's flags/positionals.
/// Owns flag map entries and `positionals_owned` on success; caller must `deinit`.
pub fn fillParsed(
    gpa: std.mem.Allocator,
    cmd: *const registry.Command,
    arguments: ?std.json.Value,
    parsed: *Parsed,
) !void {
    parsed.* = .{ .gpa = gpa };
    errdefer parsed.deinit();

    const args_obj: ?std.json.Value = if (arguments) |value| switch (value) {
        .object => value,
        else => return error.InvalidArguments,
    } else null;

    if (args_obj) |value| {
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            if (!propertyKnown(cmd, field.key_ptr.*)) return error.InvalidArguments;
        }
    }

    for (cmd.flags) |f| {
        if (!registry.flagVisibleMcp(f)) continue;
        const v = if (args_obj) |obj| jsonGet(obj, f.long) else null;
        switch (f.kind) {
            .bool_flag => {
                if (v) |val| switch (val) {
                    .bool => |b| if (b) try parsed.setBool(f.long, true),
                    else => return error.InvalidArguments,
                };
            },
            .string_flag => {
                if (v) |val| switch (val) {
                    .string => |s| try parsed.setString(f.long, s),
                    else => return error.InvalidArguments,
                };
            },
        }
    }

    var pos: std.ArrayList([]const u8) = .empty;
    errdefer pos.deinit(gpa);

    for (cmd.positionals) |p| {
        const v = if (args_obj) |obj| jsonGet(obj, p.name) else null;
        if (v == null) {
            if (p.required) return error.InvalidArguments;
            continue;
        }
        if (p.variadic) {
            switch (v.?) {
                .array => |arr| {
                    for (arr.items) |item| switch (item) {
                        .string => |s| try pos.append(gpa, s),
                        else => return error.InvalidArguments,
                    };
                },
                else => return error.InvalidArguments,
            }
        } else switch (v.?) {
            .string => |s| try pos.append(gpa, s),
            else => return error.InvalidArguments,
        }
    }

    const owned = try pos.toOwnedSlice(gpa);
    parsed.positionals_owned = owned;
    parsed.positionals = owned;
}
