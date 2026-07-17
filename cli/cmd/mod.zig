//! In-tree command tree: parse, scoped help, completion metadata (ADR-0084).
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const log = @import("../operability/log.zig");
const types = @import("types.zig");
const help_mod = @import("help.zig");

pub const help = help_mod;
pub const completion = @import("completion.zig");

pub const FlagKind = types.FlagKind;
pub const Flag = types.Flag;
pub const Positional = types.Positional;
pub const Parsed = types.Parsed;
pub const Command = types.Command;

fn isHelpFlag(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help");
}

fn looksLikeFlag(a: []const u8) bool {
    return std.mem.startsWith(u8, a, "-") and !std.mem.eql(u8, a, "-");
}

fn collectPersistent(path: []const *const Command, buf: *[48]Flag, n: *usize) void {
    n.* = 0;
    for (path) |cmd| {
        for (cmd.flags) |f| {
            if (!f.persistent) continue;
            if (n.* >= buf.len) return;
            buf[n.*] = f;
            n.* += 1;
        }
    }
}

fn matchFlag(flags: []const Flag, token: []const u8) ?Flag {
    if (std.mem.startsWith(u8, token, "--")) {
        const body = token[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const name = if (eq) |i| body[0..i] else body;
        for (flags) |f| {
            if (std.mem.eql(u8, f.long, name)) return f;
        }
        return null;
    }
    if (token.len == 2 and token[0] == '-') {
        const s = token[1];
        for (flags) |f| {
            if (f.short == s) return f;
        }
    }
    return null;
}

fn findFlagInScope(local: []const Flag, persistent: []const Flag, token: []const u8) ?Flag {
    return matchFlag(local, token) orelse matchFlag(persistent, token);
}

fn applyToCtx(ctx: *Ctx, flag: Flag, value: ?[]const u8) !void {
    if (std.mem.eql(u8, flag.long, "json")) {
        ctx.json = .json;
        return;
    }
    if (std.mem.eql(u8, flag.long, "plain")) {
        ctx.json = .human;
        return;
    }
    if (std.mem.eql(u8, flag.long, "identity")) {
        const path = value orelse {
            log.err(ctx.io, "--identity needs a path", .{});
            return error.Usage;
        };
        if (path.len == 0 or path.len >= ctx.identity_path_buf.len) {
            log.err(ctx.io, "--identity path is invalid", .{});
            return error.Usage;
        }
        @memcpy(ctx.identity_path_buf[0..path.len], path);
        ctx.identity_path = ctx.identity_path_buf[0..path.len];
        return;
    }
}

fn storeFlag(parsed: *Parsed, flag: Flag, value: ?[]const u8) !void {
    switch (flag.kind) {
        .bool_flag => try parsed.bools.put(parsed.gpa, flag.long, true),
        .string_flag => {
            const v = value orelse return error.Usage;
            try parsed.strings.put(parsed.gpa, flag.long, v);
        },
    }
}

fn consumeFlag(
    ctx: *Ctx,
    parsed: *Parsed,
    argv_in: []const []const u8,
    i_in: usize,
    flag: Flag,
    path: []const *const Command,
) !usize {
    var i = i_in;
    const a = argv_in[i];
    i += 1;
    switch (flag.kind) {
        .bool_flag => {
            if (std.mem.startsWith(u8, a, "--") and std.mem.indexOfScalar(u8, a, '=') != null) {
                log.err(ctx.io, "--{s} does not take a value", .{flag.long});
                try help_mod.writeNodeHelpErr(ctx.io, path);
                return error.Usage;
            }
            try storeFlag(parsed, flag, null);
            applyToCtx(ctx, flag, null) catch {
                try help_mod.writeNodeHelpErr(ctx.io, path);
                return error.Usage;
            };
            return i;
        },
        .string_flag => {
            var value: []const u8 = undefined;
            if (std.mem.startsWith(u8, a, "--")) {
                if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
                    value = a[eq + 1 ..];
                } else {
                    if (i >= argv_in.len) {
                        log.err(ctx.io, "--{s} needs a value", .{flag.long});
                        try help_mod.writeNodeHelpErr(ctx.io, path);
                        return error.Usage;
                    }
                    value = argv_in[i];
                    i += 1;
                }
            } else {
                if (i >= argv_in.len) {
                    log.err(ctx.io, "-{c} needs a value", .{flag.short.?});
                    try help_mod.writeNodeHelpErr(ctx.io, path);
                    return error.Usage;
                }
                value = argv_in[i];
                i += 1;
            }
            if (value.len == 0) {
                log.err(ctx.io, "--{s} needs a value", .{flag.long});
                try help_mod.writeNodeHelpErr(ctx.io, path);
                return error.Usage;
            }
            try storeFlag(parsed, flag, value);
            applyToCtx(ctx, flag, value) catch {
                try help_mod.writeNodeHelpErr(ctx.io, path);
                return error.Usage;
            };
            return i;
        },
    }
}

/// Dispatch `argv` (program name already consumed) against `root`.
pub fn dispatch(root: *const Command, ctx: *Ctx, argv_in: []const []const u8) !u8 {
    var path_buf: [12]*const Command = undefined;
    path_buf[0] = root;
    var path_len: usize = 1;

    var parsed = Parsed{ .gpa = ctx.gpa };
    defer parsed.deinit();

    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(ctx.gpa);

    var persist_buf: [48]Flag = undefined;
    var persist_n: usize = 0;

    var options_ended = false;
    var i: usize = 0;
    while (i < argv_in.len) {
        const a = argv_in[i];
        const path = path_buf[0..path_len];
        const cur = path_buf[path_len - 1];
        collectPersistent(path, &persist_buf, &persist_n);

        if (!options_ended and std.mem.eql(u8, a, "--")) {
            options_ended = true;
            i += 1;
            continue;
        }

        // Subcommands win over flag shape so aliases like `--version` / `-V` work.
        if (!cur.isLeaf()) {
            if (cur.findChild(a)) |child| {
                if (path_len >= path_buf.len) {
                    log.err(ctx.io, "command path too deep", .{});
                    return exit_codes.usage;
                }
                path_buf[path_len] = child;
                path_len += 1;
                i += 1;
                continue;
            }
        }

        if (!options_ended and isHelpFlag(a)) {
            try help_mod.writeNodeHelp(ctx.io, path);
            return exit_codes.ok;
        }

        if (!options_ended and looksLikeFlag(a)) {
            const flag = findFlagInScope(cur.flags, persist_buf[0..persist_n], a) orelse {
                log.err(ctx.io, "unknown flag \"{s}\"", .{a});
                try help_mod.writeNodeHelpErr(ctx.io, path);
                return exit_codes.usage;
            };
            i = consumeFlag(ctx, &parsed, argv_in, i, flag, path) catch |err| switch (err) {
                error.Usage => return exit_codes.usage,
                else => return err,
            };
            continue;
        }

        if (!cur.isLeaf()) {
            log.err(ctx.io, "unknown command \"{s}\"", .{a});
            try help_mod.writeNodeHelpErr(ctx.io, path);
            return exit_codes.usage;
        }

        try pos.append(ctx.gpa, a);
        i += 1;
    }

    const path = path_buf[0..path_len];
    const leaf = path_buf[path_len - 1];
    if (!leaf.isLeaf() or leaf.run == null) {
        try help_mod.writeNodeHelpErr(ctx.io, path);
        return exit_codes.usage;
    }

    parsed.positionals_owned = try pos.toOwnedSlice(ctx.gpa);
    parsed.positionals = parsed.positionals_owned.?;
    pos = .empty;

    var need: usize = 0;
    var max_pos: ?usize = 0;
    var variadic = false;
    for (leaf.positionals) |p| {
        if (p.variadic) {
            variadic = true;
            max_pos = null;
            if (p.required and parsed.positionals.len == 0) need = 1;
            break;
        }
        if (p.required) need += 1;
        max_pos = (max_pos orelse 0) + 1;
    }
    if (leaf.positionals.len == 0) max_pos = 0;
    if (!variadic and parsed.positionals.len < need) {
        log.err(ctx.io, "missing required argument", .{});
        try help_mod.writeNodeHelpErr(ctx.io, path);
        return exit_codes.usage;
    }
    if (variadic and need == 1 and parsed.positionals.len == 0) {
        log.err(ctx.io, "missing required argument", .{});
        try help_mod.writeNodeHelpErr(ctx.io, path);
        return exit_codes.usage;
    }
    if (max_pos) |max| {
        if (parsed.positionals.len > max) {
            log.err(ctx.io, "unexpected argument \"{s}\"", .{parsed.positionals[max]});
            try help_mod.writeNodeHelpErr(ctx.io, path);
            return exit_codes.usage;
        }
    }

    return leaf.run.?(ctx, &parsed) catch |err| switch (err) {
        error.Usage => blk: {
            try help_mod.writeNodeHelpErr(ctx.io, path);
            break :blk exit_codes.usage;
        },
        else => err,
    };
}

/// Collect CapTP leaves under `cmd` (depth-first).
pub fn walkLeaves(cmd: *const Command, out: *std.ArrayList(*const Command), gpa: std.mem.Allocator) !void {
    if (cmd.isLeaf() and cmd.run != null) {
        try out.append(gpa, @constCast(cmd));
        return;
    }
    for (cmd.children) |*c| try walkLeaves(c, out, gpa);
}

/// Render help for a topic path under root (e.g. `ocapn`, `ocapn` `dial`).
pub fn helpTopic(root: *const Command, ctx: *Ctx, topic_parts: []const []const u8) !u8 {
    var path_buf: [12]*const Command = undefined;
    path_buf[0] = root;
    var path_len: usize = 1;
    for (topic_parts) |part| {
        const cur = path_buf[path_len - 1];
        const child = cur.findChild(part) orelse {
            log.err(ctx.io, "unknown help topic \"{s}\"", .{part});
            try help_mod.writeNodeHelpErr(ctx.io, path_buf[0..path_len]);
            return exit_codes.usage;
        };
        path_buf[path_len] = child;
        path_len += 1;
    }
    try help_mod.writeNodeHelp(ctx.io, path_buf[0..path_len]);
    return exit_codes.ok;
}
