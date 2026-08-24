//! Root `pancake` command tree — argv parse, help, and completion.
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
const rooms_peer = @import("../app/rooms_peer.zig");
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

const rp_dir = Flag{ .long = "dir", .help = "Harness directory", .kind = .string_flag };
const rp_nick = Flag{ .long = "nick", .help = "Room nickname", .kind = .string_flag };
const rp_room = Flag{ .long = "room", .help = "Room name (default general)", .kind = .string_flag };
const rp_locator = Flag{ .long = "locator", .help = "Room locator URL or ocapn://", .kind = .string_flag };
const rp_identity = Flag{ .long = "identity", .help = "Identity seed path (default DIR/identity)", .kind = .string_flag };
const rp_text = Flag{ .long = "text", .help = "Reply text", .kind = .string_flag };
const rp_dm = Flag{ .long = "dm", .help = "Peer nick for a direct-message reply", .kind = .string_flag };
const rp_id = Flag{ .long = "id", .help = "Message id", .kind = .string_flag };
const rp_wait = Flag{ .long = "wait", .help = "Seconds to wait (tick)", .kind = .string_flag };
const rp_all = Flag{ .long = "all", .help = "Dismiss all pending" };

// `start` and `peer` take the same full dial flag set (`stop`/`status` take only
// `--dir`). One array; if the two verbs ever diverge, split then.
const rp_full_flags = [_]Flag{ rp_dir, rp_nick, rp_room, rp_locator, rp_identity };
const rp_tick_flags = [_]Flag{ rp_dir, rp_wait };
const rp_reply_flags = [_]Flag{ rp_dir, rp_text, rp_dm, rp_id };
const rp_dismiss_flags = [_]Flag{ rp_dir, rp_id, rp_all };
const rp_dir_only_flags = [_]Flag{rp_dir};

fn runRoomsPeerVerb(comptime verb: []const u8) *const fn (*Ctx, *Parsed) anyerror!u8 {
    return struct {
        fn run(ctx: *Ctx, parsed: *Parsed) anyerror!u8 {
            const init = ctx.argv_init orelse {
                log.err(ctx.io, "rooms-peer requires argv process init", .{});
                return exit_codes.internal;
            };
            const flags = rooms_peer.Flags{
                .dir = parsed.flagString("dir") orelse "",
                .nick = parsed.flagString("nick") orelse "",
                .room = parsed.flagString("room") orelse "general",
                .locator = parsed.flagString("locator") orelse "",
                .text = parsed.flagString("text") orelse "",
                .dm = parsed.flagString("dm") orelse "",
                .id = parsed.flagString("id") orelse "",
                .wait = if (parsed.flagString("wait")) |w| std.fmt.parseInt(u64, w, 10) catch 0 else 0,
                .all = parsed.flagBool("all"),
                .identity = parsed.flagString("identity") orelse "",
            };
            return rooms_peer.runVerb(init.*, verb, flags);
        }
    }.run;
}

const rooms_peer_children = [_]Command{
    .{ .name = "start", .short_help = "Start a background room peer", .flags = &rp_full_flags, .run = runRoomsPeerVerb("start") },
    .{ .name = "peer", .short_help = "Internal daemon (supervised only)", .flags = &rp_full_flags, .hidden_from_help = true, .run = runRoomsPeerVerb("peer") },
    .{ .name = "tick", .short_help = "Drain unanswered room and DM messages", .flags = &rp_tick_flags, .run = runRoomsPeerVerb("tick") },
    .{ .name = "reply", .short_help = "Answer one message (room or --dm)", .flags = &rp_reply_flags, .run = runRoomsPeerVerb("reply") },
    .{ .name = "dismiss", .short_help = "Clear message(s) without posting", .flags = &rp_dismiss_flags, .run = runRoomsPeerVerb("dismiss") },
    .{ .name = "stop", .short_help = "Leave the room and stop the peer", .flags = &rp_dir_only_flags, .run = runRoomsPeerVerb("stop") },
    .{ .name = "status", .short_help = "Show harness state", .flags = &rp_dir_only_flags, .run = runRoomsPeerVerb("status") },
};

const app_children = [_]Command{
    .{
        .name = "rooms-peer",
        .short_help = "Join a rooms app as a background peer",
        .children = &rooms_peer_children,
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
    const msg = try std.fmt.bufPrint(&buf, "pancake {d}.{d}.{d}\ncaptp-profile {s}\n", .{
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
        .name = "app",
        .short_help = "Application harnesses (rooms-peer)",
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
        .short_help = "Print pancake version",
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
    .name = "pancake",
    .short_help = "CapTP for humans and agents",
    .flags = &root_flags,
    .children = &root_children,
};

/// CapTP ocapn leaves projected from `registry.commands` (for parity tests).
pub fn ocapnLeaves() []const Command {
    return &ocapn_children;
}
