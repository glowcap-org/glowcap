//! Conservative lexical detection of standard-library effects. Recognizes
//! direct imports, namespace aliases, and field access across whitespace.
//! It does not evaluate arbitrary compile-time expressions or resolve shadowing.

const std = @import("std");

pub const Usage = struct {
    io: bool = false,
    net: bool = false,
    file: bool = false,
    thread: bool = false,
    atomic: bool = false,
    linux: bool = false,
    windows: bool = false,
};

const Path = enum { root, fs, os, io, net, file, thread, atomic, linux, windows };
const Aliases = std.StringHashMap(Path);

pub fn inspect(allocator: std.mem.Allocator, source: []const u8) !Usage {
    const terminated = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(terminated);
    var aliases = Aliases.init(allocator);
    defer aliases.deinit();
    try aliases.put("std", .root);
    var usage: Usage = .{};
    // Zig declarations are order-independent. Each repeated pass must discover
    // a new alias; no progress ends the search, including alias cycles.
    var changed = true;
    while (changed) {
        changed = false;
        var tokens = std.zig.Tokenizer.init(terminated);
        while (true) {
            const token = tokens.next();
            if (token.tag == .eof) break;
            var expression = tokens;
            _ = resolve(terminated, token, &expression, &aliases, &usage);
            if (token.tag != .keyword_const and token.tag != .keyword_var) continue;
            var declaration = tokens;
            const name = declaration.next();
            if (name.tag != .identifier or declaration.next().tag != .equal) continue;
            const first = declaration.next();
            const path = resolve(terminated, first, &declaration, &aliases, &usage) orelse continue;
            const key = identifier(terminated, name);
            if (!aliases.contains(key)) {
                try aliases.put(key, path);
                changed = true;
            }
        }
    }
    return usage;
}

fn resolve(
    source: []const u8,
    first: std.zig.Token,
    tokens: *std.zig.Tokenizer,
    aliases: *const Aliases,
    usage: *Usage,
) ?Path {
    var path: Path = if (first.tag == .identifier)
        aliases.get(identifier(source, first)) orelse return null
    else if (first.tag == .builtin and std.mem.eql(u8, source[first.loc.start..first.loc.end], "@import")) blk: {
        if (tokens.next().tag != .l_paren) return null;
        const package = tokens.next();
        if (package.tag != .string_literal or !std.mem.eql(u8, source[package.loc.start..package.loc.end], "\"std\"")) return null;
        if (tokens.next().tag != .r_paren) return null;
        break :blk .root;
    } else return null;
    while (true) {
        record(usage, path);
        if (tokens.next().tag != .period) return path;
        const field = tokens.next();
        if (field.tag != .identifier) return null;
        const name = identifier(source, field);
        path = child(path, name) orelse return null;
    }
}

fn identifier(source: []const u8, token: std.zig.Token) []const u8 {
    const text = source[token.loc.start..token.loc.end];
    return if (std.mem.startsWith(u8, text, "@\"") and text.len >= 3) text[2 .. text.len - 1] else text;
}

fn child(parent: Path, name: []const u8) ?Path {
    if (parent == .root) {
        const names = .{ "fs", "os", "Io", "net", "Thread", "atomic" };
        const paths = .{ Path.fs, Path.os, Path.io, Path.net, Path.thread, Path.atomic };
        inline for (names, paths) |field, path| if (std.mem.eql(u8, name, field)) return path;
    } else if (parent == .fs and std.mem.eql(u8, name, "File")) {
        return .file;
    } else if (parent == .os) {
        if (std.mem.eql(u8, name, "linux")) return .linux;
        if (std.mem.eql(u8, name, "windows")) return .windows;
    }
    return null;
}

fn record(usage: *Usage, path: Path) void {
    switch (path) {
        .root, .fs, .os => {},
        inline else => |member| @field(usage, @tagName(member)) = true,
    }
}

test "standard effect detection includes direct imports and namespace aliases" {
    const usage = try inspect(std.testing.allocator,
        \\const files = system.fs;
        \\const system = @import("std");
        \\const f: files.File = undefined;
        \\const io = @import ( "std" )
        \\    . @"Io";
        \\const socket = system.net;
        \\const thread = @import("std").Thread;
        \\const atom = system.atomic.Value(bool);
        \\const platform = system.os;
        \\const linux = platform.linux;
        \\const windows = @import("std").os.windows;
    );
    inline for (comptime std.meta.fieldNames(Usage)) |field| try std.testing.expect(@field(usage, field));
}

test "standard effect detection ignores strings comments and unrelated members" {
    const usage = try inspect(std.testing.allocator,
        \\// std.Io is named in documentation.
        \\const text = "std.Thread and @import(\"std\").Io";
        \\const std = @import("std");
        \\const allocator = std.mem.Allocator;
        \\const unrelated = object.Io;
        \\const a = b;
        \\const b = a;
    );
    inline for (comptime std.meta.fieldNames(Usage)) |field| try std.testing.expect(!@field(usage, field));
}
