//! Cross-language whitespace authority and the Deno scopes that consume it.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

const scopes = [_][]const u8{
    "deno.json",
    "bindings/ts/deno.json",
    "apps/ocapnviz/deno.json",
    "apps/rooms/web/deno.json",
};

const inherited_keys = [_][]const u8{
    "useTabs",
    "indentWidth",
};

/// `.editorconfig` owns whitespace across languages, including the space-only
/// grammar and formatter exceptions. Deno scopes keep their file inventories
/// and syntax choices, but must not shadow that cross-language authority.
pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const editorconfig_path = ".editorconfig";
    const editorconfig = root.readFileAlloc(io, editorconfig_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read formatting authority ({s})", .{ editorconfig_path, @errorName(err) });
        return;
    };
    defer gpa.free(editorconfig);
    const required = [_][]const u8{
        "indent_style = tab",
        "indent_size = 4",
        "tab_width = 4",
        "max_line_length = 120",
        "[*.{zig,zon}]",
        "[*.{yml,yaml}]",
        "[*.{json,jsonc}]",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, editorconfig, needle) == null) {
            try appendViolation(gpa, violations, "{s}: missing `{s}` from the shared whitespace policy", .{ editorconfig_path, needle });
        }
    }

    for (scopes) |path| {
        const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot read Deno formatter scope ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(source);

        for ([_][]const u8{ "\"lineWidth\": 120", "\"semiColons\": true", "\"singleQuote\": false" }) |needle| {
            if (std.mem.indexOf(u8, source, needle) == null) {
                try appendViolation(gpa, violations, "{s}: missing Deno syntax policy `{s}`", .{ path, needle });
            }
        }
        for (inherited_keys) |key| {
            const key_needle = try std.fmt.allocPrint(gpa, "\"{s}\"", .{key});
            defer gpa.free(key_needle);
            if (std.mem.indexOf(u8, source, key_needle) != null) {
                try appendViolation(gpa, violations, "{s}: `{s}` shadows .editorconfig; keep cross-language whitespace in one authority", .{ path, key });
            }
        }
    }
}
