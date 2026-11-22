//! The Rooms bot's argv catalog: one command group for product parsing, help,
//! and completion. Zig owns the grammar and the private `rooms-bot` executable
//! owns the behavior, so every verb is handed over as a parsed request.
const types = @import("../../cmd/types.zig");
const front = @import("session.zig").front;
const Flag = types.Flag;
fn value(comptime name: []const u8, comptime help: []const u8) Flag {
    return .{ .long = name, .help = help, .kind = .string_flag };
}
fn run(comptime verb: []const u8) *const fn (*@import("../../ctx.zig").Ctx, *types.Parsed) anyerror!u8 {
    return front("rooms-bot", "--dir is required. Name the same bot directory on every bot command", verb);
}
/// A command the agent runs during a turn. The bot names its directory and
/// conversation for the turn, so the command takes no --dir.
fn during_turn(comptime verb: []const u8) *const fn (*@import("../../ctx.zig").Ctx, *types.Parsed) anyerror!u8 {
    return front("rooms-bot", null, verb);
}
fn many(comptime flag: Flag) Flag {
    var repeated = flag;
    repeated.repeatable = true;
    return repeated;
}
/// A setting `serve` also reads from `GLOWCAP_ROOMS_BOT_<NAME>`.
fn setting(comptime name: []const u8, comptime variable: []const u8, comptime help: []const u8) Flag {
    return value(name, help ++ " (or GLOWCAP_ROOMS_BOT_" ++ variable ++ ")");
}
const dir = value("dir", "The bot's own directory, where it keeps its settings and state (required)");
const text = value("text", "The text to post, or - to read it from standard input");
const operation = @import("session_commands.zig").operation;
const base = @import("session_commands.zig").base;
const dm = value("dm", "A member's nickname, as the directory of the turn's conversation registers it, to post to directly: opens a direct conversation with them or reuses the open one");
const dm_operation = value("operation", "With --dm and --base, the operation of an earlier open whose outcome was uncertain, to open again at most once");
const dm_base = value("base", "With --dm and --operation, the revision of an earlier open whose outcome was uncertain");
pub const commands = [_]types.Command{
    .{ .name = "serve", .short_help = "Keep a coding agent present in Rooms, answering in the foreground until stopped", .flags = &.{
        dir,
        setting("link", "LINK", "Where the session link is, needed the first time: - reads it from standard input, or give the path of a file holding it. Pipe it from glowcap apps rooms session access issue --dir <session directory> --label bot --rights collaborator"),
        .{ .long = "replace-link", .help = "Accept a different --link than the one stored, and revoke the old access once the bot serves" },
        setting("harness", "HARNESS", "The coding agent to run, installed and signed in on this machine: claude, codex, or pi (required the first time)"),
        setting("model", "MODEL", "The model the agent uses (the agent's own default when left out)"),
        setting("permission", "PERMISSION", "What the agent may do: safe keeps it to its own working directory and the bot's actions, full lets it do anything you can (default safe, and codex and pi need full)"),
        setting("deadline", "DEADLINE", "Seconds one reply may take before it is stopped (default 600)"),
        setting("glowcap", "GLOWCAP", "Path of the glowcap program the agent runs, when this one was not installed as a package"),
        many(setting("allow", "ALLOW", "A nickname whose messages the bot answers (repeat for each, or separate with commas). Without it the bot answers everyone, and --allow '' answers everyone again")),
        setting("sender-limit", "SENDER_LIMIT", "Messages from one person the bot answers in an hour (default 30)"),
        setting("conversation-limit", "CONVERSATION_LIMIT", "Messages in one conversation the bot answers in an hour (default 60)"),
        setting("streak-limit", "STREAK_LIMIT", "Replies in a row to one person in one conversation, until they are quiet for ten minutes, which stops bots answering each other (default 10)"),
        setting("instructions", "INSTRUCTIONS", "A text file of your own instructions for the agent, read for every reply (at most 16 KiB, and --instructions '' drops it)"),
    }, .run = run("serve") },
    .{ .name = "status", .short_help = "Show whether the bot is running and what it last did", .flags = &.{dir}, .run = run("status") },
    .{ .name = "ready", .short_help = "Exit 0 only while a serve holds the bot directory, its access is active, and its session answers, for a container health check", .flags = &.{dir}, .run = run("ready") },
    .{ .name = "say", .short_help = "During a turn, post a message as the bot in its conversation, another, or directly to a member", .flags = &.{
        text,
        value("conversation", "Another conversation to post in, by its identifier from workspace (default: the turn's own)"),
        dm,
        dm_operation,
        dm_base,
    }, .run = during_turn("say") },
    .{ .name = "send", .short_help = "During a turn, send files from the agent's working directory to its conversation or directly to a member", .flags = &.{
        text,
        .{ .long = "file", .help = "A file in the agent's working directory to send (repeat for several)", .kind = .string_flag, .repeatable = true },
        dm,
        dm_operation,
        dm_base,
    }, .run = during_turn("send") },
    .{ .name = "command", .short_help = "During a turn, run a Rooms application command as the bot", .flags = &.{ operation, base }, .positionals = &.{.{ .name = "arguments", .help = "Command name followed by its arguments", .variadic = true }}, .run = during_turn("command") },
    .{ .name = "workspace", .short_help = "During a turn, show the workspace the bot sees", .flags = &.{}, .run = during_turn("workspace") },
};
