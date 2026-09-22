//! One Rooms argv catalog for product parsing, help, and completion.
const types = @import("../../cmd/types.zig");
const run = @import("session.zig").run;
const Flag = types.Flag;
fn value(comptime name: []const u8, comptime help: []const u8) Flag {
    return .{ .long = name, .help = help, .kind = .string_flag };
}
fn many(comptime name: []const u8, comptime help: []const u8) Flag {
    var flag = value(name, help);
    flag.repeatable = true;
    return flag;
}
const dir = value("dir", "Private workspace directory (required)");
const nick = value("nick", "Directory nickname");
const room = value("room", "Room name");
const rooms = many("room", "Room to join; repeat for multiple rooms");
const locator = value("locator", "Directory locator or HTTP(S) bootstrap URL");
const id = value("id", "Pending event identifier");
const conversation = value("conversation", "Exact conversation identifier from status");
const operation = value("operation", "Stable operation identifier for inspecting an uncertain result");
const join = [_]Flag{ dir, nick, locator, rooms };
const start = join ++ [_]Flag{
    value("transport", "iroh (default), tcp (cleartext tests), or onion"),
    value("relay-url", "Browser rendezvous relay URL"),
    value("reachability", "iroh discovery (default) or direct"),
};
const team_start = start ++ [_]Flag{
    value("lead", "Lead nickname"),
    many("member", "Member nickname; repeat for each member"),
    value("max", "Maximum roster size including lead (default 4)"),
};
pub const commands = [_]types.Command{
    .{ .name = "serve", .short_help = "Serve a foreground session for a host supervisor or attached browser", .flags = &(@import("commands.zig").transport ++ [_]Flag{ dir, value("checkpoint", "Adopt a session document for a new workspace"), value("readiness-file", "Write the session administrator capability here"), value("relay-url", "Browser rendezvous relay URL") }), .run = @import("mod.zig").run("rooms-session", .session_serve) },
    .{ .name = "ready", .short_help = "Read the foreground session's readiness capability", .flags = &.{value("file", "Readiness file (required)")}, .run = @import("mod.zig").run("rooms-session", .session_ready) },
    .{ .name = "start", .short_help = "Start or restore a durable Rooms workspace", .flags = &start, .run = run("start") },
    .{ .name = "join", .short_help = "Join rooms without leaving existing conversations", .flags = &join, .run = run("join") },
    .{ .name = "status", .short_help = "Show workspace, memberships, effects, and inbox health", .flags = &.{dir}, .run = run("status") },
    .{ .name = "tick", .short_help = "Read pending events without acknowledging them", .flags = &.{ dir, value("wait", "Wait 0..30 seconds (default 30)") }, .run = run("tick") },
    .{ .name = "listen", .short_help = "Stream unread events as JSONL without acknowledging them", .flags = &.{dir}, .run = run("listen") },
    .{ .name = "reply", .short_help = "Send to one event, room, DM, or conversation", .flags = &.{ dir, id, room, conversation, value("dm", "Directory nickname for a private message"), value("text", "Message text"), locator, operation }, .run = run("reply") },
    .{ .name = "dismiss", .short_help = "Acknowledge reviewed events without sending", .flags = &.{ dir, many("id", "Reviewed event identifier; repeat for a batch") }, .run = run("dismiss") },
    .{ .name = "leave", .short_help = "Leave one room or direct conversation", .flags = &.{ dir, room, conversation }, .run = run("leave") },
    .{ .name = "resume", .short_help = "Resume observation after accepting its reported gap", .flags = &.{ dir, .{ .long = "accept-gap", .help = "Acknowledge that events during the gap were not retained" } }, .run = run("resume") },
    .{ .name = "command", .short_help = "Invoke a shared Rooms application command", .flags = &.{ dir, operation }, .positionals = &.{.{ .name = "arguments", .help = "Command name followed by its arguments", .variadic = true }}, .run = run("command") },
    .{ .name = "stop", .short_help = "Stop the session and retain its workspace and unread events", .flags = &.{dir}, .run = run("stop") },
};
pub const team_commands = [_]types.Command{
    .{ .name = "start", .short_help = "Start a roster lead-first through the same session commands", .flags = &team_start, .run = run("team-start") },
    .{ .name = "status", .short_help = "Inspect the roster's session health without exposing messages", .flags = &.{dir}, .run = run("team-status") },
    .{ .name = "stop", .short_help = "Stop the roster; retain every member workspace", .flags = &.{dir}, .run = run("team-stop") },
};
