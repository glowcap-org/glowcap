//! Root `glowcap` command tree — argv parse, help, and completion.
//! CapTP leaves project from `cli/registry.zig` (sole verb table).
const std = @import("std");
const types = @import("types.zig");
const cmd = @import("mod.zig");
const completion_mod = @import("completion.zig");
const Ctx = @import("../ctx.zig").Ctx;
const exit_codes = @import("../exit_codes.zig");
const argv = @import("../argv.zig");
const identity_mod = @import("../operability/identity.zig");
const log = @import("../operability/log.zig");
const registry = @import("../registry.zig");
const repl = @import("../repl/mod.zig");
const mcp = @import("../mcp/mod.zig");
const rooms = @import("../app/rooms/mod.zig");
const griddle = @import("../griddle/mod.zig");

const Command = types.Command;
const Flag = types.Flag;
const Positional = types.Positional;
const Parsed = types.Parsed;

const build_options = @import("build_options");

pub const root_flags = [_]Flag{
    .{ .long = "json", .help = "Emit JSON on stdout", .persistent = true },
    .{ .long = "plain", .help = "Emit human text on stdout (default)", .persistent = true },
    .{ .long = "identity", .help = "Path to CapTP identity seed", .kind = .string_flag, .persistent = true },
};

/// CapTP leaves — projection of `registry.commands` (sole verb table).
const ocapn_children = blk: {
    var out: [registry.commands.len]Command = undefined;
    for (registry.commands, 0..) |c, i| {
        out[i] = .{
            .name = c.name,
            .short_help = c.help,
            .flags = c.flags,
            .positionals = c.positionals,
            .run = c.run,
        };
    }
    break :blk out;
};

const mcp_flags = [_]Flag{
    .{ .long = "tools", .help = "MCP catalog: default|full|readonly", .kind = .string_flag },
    .{ .long = "idle-ms", .help = "Idle timeout milliseconds (0 disables)", .kind = .string_flag },
    .{ .long = "max-session-ms", .help = "Max session milliseconds (0 disables)", .kind = .string_flag },
};

const app_children = [_]Command{
    .{
        .name = "rooms",
        .short_help = "Browser app, directory, durable sessions, and IRC",
        .inherit_flags = false,
        .children = &rooms.commands,
    },
};

fn runInit(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    _ = parsed;
    if (ctx.identity_path.len == 0) try ctx.resolveIdentityPath();
    ctx.ensureStateLock() catch |err| {
        return @import("../operability/state_lock.zig").refuseLockFailure(ctx.io, err, ctx.identity_path);
    };
    const secret = identity_mod.mint(ctx.io, ctx.identity_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            log.err(ctx.io, "identity already exists at {s}", .{ctx.identity_path});
            return exit_codes.identity;
        },
        else => {
            log.err(ctx.io, "init failed: {s}", .{@errorName(err)});
            return identity_mod.mapLoadError(err);
        },
    };
    const designator = secret.publicKey().toDesignator();
    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"path\":");
        try argv.writeJsonString(&out, ctx.gpa, ctx.identity_path);
        try out.appendSlice(ctx.gpa, ",\"identity\":");
        try argv.writeJsonString(&out, ctx.gpa, designator[0..]);
        try out.appendSlice(ctx.gpa, "}\n");
        try argv.writeStdout(ctx.io, out.items);
    } else {
        log.info(ctx.io, "wrote identity {s}", .{ctx.identity_path});
        try argv.writeStdout(ctx.io, designator[0..]);
        try argv.writeStdout(ctx.io, "\n");
    }
    return exit_codes.ok;
}

fn runIdentity(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    _ = parsed;
    if (ctx.identity_path.len == 0) try ctx.resolveIdentityPath();
    ctx.ensureStateLock() catch |err| {
        return @import("../operability/state_lock.zig").refuseLockFailure(ctx.io, err, ctx.identity_path);
    };
    const secret = identity_mod.load(ctx.io, ctx.identity_path) catch |err| {
        return identity_mod.mapLoadError(err);
    };
    const designator = secret.publicKey().toDesignator();
    if (ctx.json == .json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "{\"ok\":true,\"identity\":");
        try argv.writeJsonString(&out, ctx.gpa, designator[0..]);
        try out.appendSlice(ctx.gpa, ",\"path\":");
        try argv.writeJsonString(&out, ctx.gpa, ctx.identity_path);
        try out.appendSlice(ctx.gpa, "}\n");
        try argv.writeStdout(ctx.io, out.items);
    } else {
        try argv.writeStdout(ctx.io, designator[0..]);
        try argv.writeStdout(ctx.io, "\n");
    }
    return exit_codes.ok;
}

fn runVersion(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    _ = parsed;
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "glowcap {d}.{d}.{d}\ncaptp-profile {s}\n", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
        build_options.captp_profile,
    });
    try argv.writeStdout(ctx.io, msg);
    return exit_codes.ok;
}

fn runHelp(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    return cmd.helpTopic(&root, ctx, parsed.positionals);
}

fn runCompletion(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    if (parsed.positionals.len != 1) {
        log.err(ctx.io, "completion needs bash|zsh|fish", .{});
        return error.Usage;
    }
    const shell = completion_mod.parseShell(parsed.positionals[0]) orelse {
        log.err(ctx.io, "unknown shell \"{s}\" (want bash|zsh|fish)", .{parsed.positionals[0]});
        return error.Usage;
    };
    try completion_mod.emit(ctx.io, &root, shell);
    return exit_codes.ok;
}

fn runRepl(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    return repl.runParsed(ctx, parsed);
}

fn runMcp(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
    return mcp.runParsed(ctx, parsed);
}

const root_children = [_]Command{
    @import("../installation/mod.zig").command,
    .{
        .name = "init",
        .short_help = "Mint a CapTP identity seed",
        .run = runInit,
    },
    .{
        .name = "identity",
        .short_help = "Print the CapTP identity designator",
        .run = runIdentity,
    },
    .{
        .name = "ocapn",
        .short_help = "CapTP verbs (listen, dial, call, …)",
        .children = &ocapn_children,
    },
    .{
        .name = "repl",
        .short_help = "Interactive CapTP lab (optional locator)",
        .positionals = &[_]Positional{.{ .name = "locator", .help = "ocapn:// URI to dial first (optional)", .required = false }},
        .run = runRepl,
    },
    .{
        .name = "mcp",
        .short_help = "MCP stdio server over CapTP verbs",
        .flags = &mcp_flags,
        .run = runMcp,
    },
    .{
        .name = "apps",
        .short_help = "Applications built on glowcap",
        .children = &app_children,
    },
    griddle.command,
    .{
        .name = "completion",
        .short_help = "Print shell completion script",
        .positionals = &[_]Positional{.{ .name = "shell", .help = "bash | zsh | fish" }},
        .run = runCompletion,
    },
    .{
        .name = "version",
        .short_help = "Print glowcap version",
        .aliases = &[_][]const u8{ "--version", "-V" },
        .run = runVersion,
    },
    .{
        .name = "help",
        .short_help = "Help for a command (or root)",
        .positionals = &[_]Positional{.{ .name = "topic", .help = "command path", .required = false, .variadic = true }},
        .run = runHelp,
    },
};

pub const root: Command = .{
    .name = "glowcap",
    .short_help = "CapTP for humans and agents",
    .flags = &root_flags,
    .children = &root_children,
};

/// CapTP ocapn leaves projected from `registry.commands` (for parity tests).
pub fn ocapnLeaves() []const Command {
    return &ocapn_children;
}
