//! Sole CapTP leaf table for argv (projected into the command tree), REPL, and MCP.
//!
//! ADR-0084: one CapTP verb registry. Argv help/completion/parse share this table
//! through `cli/cmd/tree.zig`'s projection — do not duplicate name/help/mcp/run.
//! Front-applicable leaves/flags use `leafVisible` / `flagVisible` so help, Tab,
//! and MCP schemas cannot disagree.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const Front = @import("ctx.zig").Front;
const ocapn = @import("ocapn/mod.zig");
const types = @import("cmd/types.zig");

pub const Parsed = types.Parsed;
pub const Flag = types.Flag;
pub const Positional = types.Positional;

/// The commands the REPL routes through its cooperative CapTP queue (`exec`
/// also remembers their name argument for Tab). The queue dispatches with an
/// exhaustive switch on this enum, so adding a member is a compile error
/// there, never a runtime usage failure.
pub const SessionVerb = enum { call, tell, fetch, publish };

pub const Command = struct {
    name: []const u8,
    help: []const u8,
    /// Argv-only (blocking accept / listen-locator). Hidden from REPL help/Tab and MCP.
    argv_only: bool = false,
    /// Omitted from every MCP catalog (accept loops starve stdio).
    mcp_never: bool = false,
    /// Included in `pancake mcp --tools default`.
    mcp_default: bool = false,
    /// Included in `pancake mcp --tools readonly`.
    mcp_readonly: bool = false,
    /// Non-null routes the command through the REPL's cooperative CapTP queue.
    session_verb: ?SessionVerb = null,
    flags: []const Flag = &.{},
    positionals: []const Positional = &.{},
    run: *const fn (*Ctx, *Parsed) anyerror!u8,
};

const listen_flags = [_]Flag{
    .{ .long = "bind", .help = "HOST:PORT to bind (default 127.0.0.1:0)", .kind = .string_flag },
    .{ .long = "publish", .help = "Publish built-in NAME on first accept then exit (greeter|echo; implies --once)", .kind = .string_flag },
    .{ .long = "once", .help = "Accept one partner then exit" },
};

const dial_flags = [_]Flag{
    .{ .long = "repl", .help = "Attach the interactive REPL after dial", .mcp_hide = true },
};

pub const commands = [_]Command{
    .{
        .name = "listen",
        .help = "Bind a listener, print its ocapn:// locator, accept partners",
        .argv_only = true,
        .mcp_never = true,
        .flags = &listen_flags,
        .run = ocapn.cmdListen,
    },
    .{
        .name = "dial",
        .help = "Dial an ocapn:// locator (optionally --repl)",
        .mcp_default = true,
        .flags = &dial_flags,
        .positionals = &[_]Positional{.{ .name = "locator", .help = "ocapn:// URI" }},
        .run = ocapn.cmdDial,
    },
    .{
        .name = "probe",
        .help = "Dial, handshake, report ok, close",
        .mcp_default = true,
        .positionals = &[_]Positional{.{ .name = "locator", .help = "ocapn:// URI" }},
        .run = ocapn.cmdProbe,
    },
    .{
        .name = "call",
        .session_verb = .call,
        .help = "Call a published name or #<import>",
        .mcp_default = true,
        .positionals = &[_]Positional{
            .{ .name = "locator", .help = "ocapn:// URI when no session is open", .required = false },
            .{ .name = "name", .help = "published name or #<import>" },
            .{ .name = "verb", .help = "method name" },
            .{ .name = "args", .help = "method arguments", .variadic = true, .required = false },
        },
        .run = ocapn.cmdCall,
    },
    .{
        .name = "tell",
        .session_verb = .tell,
        .help = "Fire-and-forget to a published name or #<import>",
        .mcp_default = true,
        .positionals = &[_]Positional{
            .{ .name = "locator", .help = "ocapn:// URI when no session is open", .required = false },
            .{ .name = "name", .help = "published name or #<import>" },
            .{ .name = "verb", .help = "method name" },
            .{ .name = "args", .help = "method arguments", .variadic = true, .required = false },
        },
        .run = ocapn.cmdTell,
    },
    .{
        .name = "fetch",
        .session_verb = .fetch,
        .help = "Fetch a published capability by name",
        .mcp_default = true,
        .positionals = &[_]Positional{
            .{ .name = "locator", .help = "ocapn:// URI when no session is open", .required = false },
            .{ .name = "name", .help = "published name" },
        },
        .run = ocapn.cmdFetch,
    },
    .{
        .name = "publish",
        .session_verb = .publish,
        .help = "Publish a built-in actor on the open session (greeter|echo)",
        .mcp_default = true,
        .positionals = &[_]Positional{.{ .name = "name", .help = "greeter (default) or echo", .required = false }},
        .run = ocapn.cmdPublish,
    },
    .{
        .name = "close",
        .help = "Close the open session",
        .mcp_default = true,
        .run = ocapn.cmdClose,
    },
    .{
        .name = "info",
        .help = "Show identity / session summary",
        .mcp_default = true,
        .mcp_readonly = true,
        .run = ocapn.cmdInfo,
    },
    .{
        .name = "locator",
        .help = "Print the last listen locator (if any)",
        .argv_only = true,
        .mcp_never = true,
        .run = ocapn.cmdLocator,
    },
};

pub fn find(name: []const u8) ?*const Command {
    for (&commands) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

pub fn dispatchParsed(ctx: *Ctx, name: []const u8, parsed: *Parsed) !u8 {
    const cmd = find(name) orelse {
        ctx.logErr("unknown ocapn command \"{s}\"", .{name});
        return @import("exit_codes.zig").usage;
    };
    return cmd.run(ctx, parsed);
}

/// REPL / tests: positionals only (no CapTP leaf flags).
pub fn dispatch(ctx: *Ctx, name: []const u8, positionals: []const []const u8) !u8 {
    var parsed = Parsed{ .gpa = ctx.gpa, .positionals = positionals };
    return dispatchParsed(ctx, name, &parsed);
}

pub const McpCatalog = enum { default, full, readonly };

/// Whether a CapTP leaf is honest on this front (help / Tab / MCP catalogs).
pub fn leafVisible(cmd: *const Command, front: Front) bool {
    return switch (front) {
        .argv => true,
        .repl => !cmd.argv_only,
        .mcp => !cmd.mcp_never and !cmd.argv_only,
    };
}

pub fn mcpVisible(cmd: *const Command, catalog: McpCatalog) bool {
    if (!leafVisible(cmd, .mcp)) return false;
    return switch (catalog) {
        .default => cmd.mcp_default,
        .readonly => cmd.mcp_readonly,
        .full => true,
    };
}

/// Whether a flag appears in MCP `inputSchema` / `fillParsed`.
pub fn flagVisibleMcp(flag: Flag) bool {
    return !flag.mcp_hide;
}

pub fn helpEveryday(writer: anytype, front: Front) !void {
    try writer.writeAll("Everyday ocapn commands:\n");
    for (commands) |cmd| {
        if (!leafVisible(&cmd, front)) continue;
        try writer.print("  {s:<10}  {s}\n", .{ cmd.name, cmd.help });
    }
    try writer.writeAll("\nFull verb list: `pancake help ocapn`.\n");
}
