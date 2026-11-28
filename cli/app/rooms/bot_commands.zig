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
/// A setting `serve` also reads from `GLOWCAP_ROOMS_BOT_<NAME>`.
fn setting(comptime name: []const u8, comptime variable: []const u8, comptime help: []const u8) Flag {
    return value(name, help ++ " (or GLOWCAP_ROOMS_BOT_" ++ variable ++ ")");
}
const dir = value("dir", "The bot's own directory, where it keeps its settings and state (required)");
const text = value("text", "The text to post, or - to read it from standard input");
const conversation = value("conversation", "Another conversation to post in, by its identifier from workspace (the turn's own when left out)");
const operation = @import("session_commands.zig").operation;
const base = @import("session_commands.zig").base;
const dm = value("dm", "The nickname of a member of the turn's directory, to post to directly: the session reuses the open direct conversation with them, or reopens or opens one");
const dm_operation = value("operation", "With --dm and --base, the operation of an earlier open from this conversation whose outcome was uncertain, to look at it again without opening twice");
const dm_base = value("base", "With --dm and --operation, the revision of an earlier open whose outcome was uncertain");
const schedule_control = [_]Flag{
    value("dir", "Outside a turn, the bot directory holding the session link and schedule"),
    value("conversation", "Outside a turn, the exact room or DM identifier to manage"),
};
const schedule = [_]Flag{
    value("id", "A name for this schedule in the current conversation"),
    value("in", "Time until the first occurrence, such as 5m"),
    value("at", "UTC time of the first occurrence, such as 2027-01-15T14:00:00Z"),
    value("every", "Interval between occurrences, at least one minute. Use with --count"),
    value("count", "Total occurrences including the first, from 2 through 32"),
};
pub const commands = [_]types.Command{
    .{ .name = "serve", .short_help = "Keep a coding agent present in Rooms, answering in the foreground until stopped", .flags = &.{
        dir,
        setting("link", "LINK", "Where the session link is, needed the first time: - reads it from standard input, or give the path of a file holding it. Pipe it from glowcap apps rooms session access issue --dir <session directory> --label bot --rights collaborator"),
        .{ .long = "replace-link", .help = "Replace the stored link with --link. The new link is stored only after the session answers it, and serve exits with a failure if it refuses it. The old access stays active until you revoke it. A link to a different session is refused, so serve another session from a new --dir" },
        setting("harness", "HARNESS", "The coding agent to run, installed and signed in on this machine: claude, codex, or pi (required the first time)"),
        setting("model", "MODEL", "The model the agent uses (the agent's own default when left out)"),
        setting("permission", "PERMISSION", "What the agent may do: safe keeps it to its own working directory and the bot's actions, full lets it do anything you can (safe unless set, and codex and pi need full)"),
        setting("deadline", "DEADLINE", "Seconds one reply may take before it is stopped, from 1 up to a day (600 unless set)"),
        setting("glowcap", "GLOWCAP", "Path of the glowcap program the agent runs, when this one was not installed as a package"),
        setting("conversation-limit", "CONVERSATION_LIMIT", "Messages in one conversation the bot answers in an hour (60 unless set)"),
        setting("instructions", "INSTRUCTIONS", "A text file of up to 16,384 bytes of your own instructions for the agent, read for every reply"),
        .{ .long = "no-instructions", .help = "Drop the stored instructions file" },
    }, .run = run("serve") },
    .{ .name = "status", .short_help = "Show whether the bot is running and what it last did", .flags = &.{dir}, .run = run("status") },
    .{ .name = "ready", .short_help = "Exit 0 only while a serve holds the bot directory, its access is active, its session answers, and its agent is not refused its sign-in, for a container health check", .flags = &.{dir}, .run = run("ready") },
    .{ .name = "say", .short_help = "During a turn, post a message as the bot in its conversation, another, or directly to a member", .flags = &.{
        text,
        conversation,
        dm,
        dm_operation,
        dm_base,
    }, .run = during_turn("say") },
    .{ .name = "send", .short_help = "During a turn, send files from the agent's working directory to its conversation, another, or directly to a member", .flags = &.{
        text,
        .{ .long = "file", .help = "A file in the agent's working directory to send (repeat for several)", .kind = .string_flag, .repeatable = true },
        conversation,
        dm,
        dm_operation,
        dm_base,
    }, .run = during_turn("send") },
    .{ .name = "command", .short_help = "During a turn, run a Rooms application command as the bot", .flags = &.{ operation, base }, .positionals = &.{.{ .name = "arguments", .help = "Command name followed by its arguments", .variadic = true }}, .run = during_turn("command") },
    .{ .name = "join", .short_help = "During a turn, join an existing listed room in this conversation's directory", .flags = &.{value("room", "Exact listed room name")}, .run = during_turn("join") },
    .{ .name = "workspace", .short_help = "During a turn, show the workspace the bot sees", .flags = &.{}, .run = during_turn("workspace") },
    .{ .name = "members", .short_help = "During a turn, show the current room’s members and introductions", .flags = &.{}, .run = during_turn("members") },
    .{ .name = "remind", .short_help = "Post a saved message in this conversation when due", .flags = &(schedule ++ [_]Flag{value("text", "The message to post")}), .run = during_turn("remind") },
    .{ .name = "schedule", .short_help = "Run an agent turn in this conversation when due, using the model budget", .flags = &(schedule ++ [_]Flag{value("task", "What the agent should do when the turn starts")}), .run = during_turn("schedule") },
    .{ .name = "reminders", .short_help = "List reminders and scheduled tasks for this conversation", .flags = &schedule_control, .run = front("rooms-bot", null, "reminders") },
    .{ .name = "cancel-reminder", .short_help = "Cancel a reminder or scheduled task in this conversation", .flags = &(schedule_control ++ [_]Flag{value("id", "The schedule to cancel")}), .run = front("rooms-bot", null, "cancel-reminder") },
    .{ .name = "actions", .short_help = "During a turn, list the bot's actions and their outcomes from its own record", .run = during_turn("actions") },
};
