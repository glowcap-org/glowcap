//! A named bot is a Compose project alongside the Rooms deployment. Only its
//! session joins the directory network. The project id stays with its private
//! host files so moving a deployment retains the same containers and volumes.
const std = @import("std");
const Config = @import("config.zig").Config;
const Docker = @import("docker.zig").Client;
const Parsed = @import("../../../cmd/types.zig").Parsed;
const log = @import("../../../operability/log.zig");
const stdout = @import("../../../argv.zig").writeStdout;

pub const Verb = enum { init, up, status, down, logs, session };

pub fn perform(state: Config, docker: Docker, parsed: *Parsed, verb: Verb) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const names = if (parsed.positionals.len == 0 and verb == .status) try inventory(state) else if (verb == .session) parsed.positionals[0..1] else parsed.positionals;
    for (names) |nick| {
        if (!validName(nick)) {
            log.err(state.io, "choose a bot nickname of 1 to 32 lowercase letters, digits or hyphens, beginning with a letter or digit. Room-wide mentions are reserved", .{});
            return error.InvalidBotName;
        }
        if ((try seen.getOrPut(state.gpa, nick)).found_existing) return error.DuplicateBotName;
    }
    if (verb == .status) return showStatus(state, docker, names);
    const rooms: []const []const u8 = if (parsed.repeated.get("room")) |values| values.items else &.{};
    for (rooms) |room| if (room.len == 0) return error.EmptyRoomName;
    const locator = parsed.flagString("locator");
    if (locator) |url| if (url.len == 0) return error.EmptyLocator;
    for (names) |nick| {
        handle(state, docker, nick, verb, rooms, locator, if (verb == .session) parsed.positionals[1..] else &.{}) catch |err| {
            log.err(state.io, "bot {s}: {s} failed ({s}). Previously processed members keep their state", .{ nick, @tagName(verb), @errorName(err) });
            return err;
        };
    }
}

fn alphabetical(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn inventory(state: Config) ![]const []const u8 {
    const dir = state.dir.openDir(state.io, "bots", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(state.io);
    var entries = dir.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try entries.next(state.io)) |entry| {
        if (entry.kind != .directory or !validName(entry.name)) continue;
        const id = try std.Io.Dir.path.join(state.gpa, &.{ "bots", entry.name, "project-id" });
        if (try exists(state, id)) try names.append(state.gpa, try state.gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, alphabetical);
    return names.items;
}

fn validName(nick: []const u8) bool {
    if (nick.len == 0 or nick.len > 32 or nick[0] == '-') return false;
    for (nick) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    for ([_][]const u8{ "room", "here", "all", "everyone", "channel" }) |name| if (std.mem.eql(u8, name, nick)) return false;
    return true;
}

fn handle(state: Config, docker: Docker, nick: []const u8, verb: Verb, rooms: []const []const u8, locator: ?[]const u8, command: []const []const u8) !void {
    const path = try std.Io.Dir.path.join(state.gpa, &.{ state.path, "bots", nick });
    const dir = if (verb == .init or verb == .up)
        try std.Io.Dir.cwd().createDirPathOpen(state.io, path, .{ .permissions = .fromMode(0o700) })
    else
        try std.Io.Dir.cwd().openDir(state.io, path, .{});
    defer dir.close(state.io);
    const member: Config = .{ .io = state.io, .gpa = state.gpa, .dir = dir, .path = path, .templates = state.templates };
    if (verb == .init or verb == .up) try prepare(member);
    const project = try projectName(state, nick);
    if (verb == .init and rooms.len == 0 and locator == null) {
        try stdout(state.io, try state.gpa.print("{s}: configure {s}/bot.env and {s}/agent-home\n", .{ nick, path, path }));
        return;
    }
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(state.gpa, &.{ "compose", "--project-name", project, "--project-directory", path, "-f", try std.Io.Dir.path.join(state.gpa, &.{ state.templates, "member.compose.yml" }) });
    for ([_]Config{ state, member }, [_][]const u8{ "bots.override.yml", "compose.override.yml" }) |owner, name| {
        if (try exists(owner, name)) try args.appendSlice(state.gpa, &.{ "-f", try std.Io.Dir.path.join(state.gpa, &.{ owner.path, name }) });
    }
    const compose: Compose = .{ .docker = docker, .base = args.items };
    if (verb != .session) try stdout(state.io, try state.gpa.print("{s}\n", .{nick}));
    switch (verb) {
        .init, .up => {
            try provision(member, compose, nick, rooms, locator);
            if (verb == .up) try compose.run(&.{ "up", "-d", "--wait", "--wait-timeout", "120", "bot" }, 150);
        },
        .status => unreachable,
        .session => {
            // Keep a nested command's positional arguments after its own --.
            // Session ready reads a file and takes no workspace flag.
            const end = for (command, 0..) |arg, index| {
                if (std.mem.eql(u8, arg, "--")) break index;
            } else command.len;
            const dir_flag: []const []const u8 = if (std.mem.eql(u8, command[0], "ready")) &.{} else &.{"--dir=/session-state"};
            const operands = try std.mem.concat(state.gpa, []const u8, &.{ command[0..end], dir_flag, command[end..] });
            return std.process.replace(state.io, .{ .argv = try docker.args(try compose.sessionArgs(operands)), .environ_map = docker.environ });
        },
        .logs => try compose.run(&.{ "logs", "--tail", "100" }, 30),
        .down => try compose.run(&.{"down"}, 120),
    }
}

fn projectName(state: Config, nick: []const u8) ![]const u8 {
    const path = try std.Io.Dir.path.join(state.gpa, &.{ "bots", nick, "project-id" });
    const id = try state.read(path) orelse return error.BotNotInitialized;
    if (id.len != 32 or !isHex(id)) return error.InvalidBotProject;
    return state.gpa.print("glowcap-member-{s}-{s}", .{ nick, id });
}

/// Docker reports all service states at one instant. Match its Compose
/// project labels against the selected deployment's saved identities.
fn showStatus(state: Config, docker: Docker, names: []const []const u8) !void {
    if (names.len == 0) return stdout(state.io, "No named bots initialized.\n");
    const Status = struct { bot: ?[]const u8 = null, session: ?[]const u8 = null };
    const statuses = try state.gpa.alloc(Status, names.len);
    @memset(statuses, .{});
    var projects: std.StringHashMapUnmanaged(usize) = .empty;
    for (names, 0..) |nick, index| try projects.put(state.gpa, try projectName(state, nick), index);
    const format = "{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Status}}";
    const result = try docker.query(&.{ "ps", "--all", "--filter", "label=org.glowcap.rooms.member=true", "--format", format });
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const index = projects.get(fields.first()) orelse continue;
        const service = fields.next() orelse continue;
        const status = fields.rest();
        if (std.mem.eql(u8, service, "bot")) statuses[index].bot = status;
        if (std.mem.eql(u8, service, "member-session")) statuses[index].session = status;
    }
    for (names, statuses) |nick, status| {
        try stdout(state.io, try state.gpa.print("{s}\n  bot: {s}\n  member-session: {s}\n", .{ nick, status.bot orelse "stopped", status.session orelse "stopped" }));
    }
}

fn isHex(bytes: []const u8) bool {
    for (bytes) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

fn exists(member: Config, name: []const u8) !bool {
    _ = member.dir.statFile(member.io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn prepare(member: Config) !void {
    const has_project = try exists(member, "project-id");
    if (!has_project and try exists(member, "bot-link")) {
        log.err(member.io, "restore the member's saved project-id before starting its session. The bot link belongs to the original project", .{});
        return error.BotProjectMissing;
    }
    const home = try member.dir.createDirPathOpen(member.io, "agent-home", .{ .permissions = .fromMode(0o700) });
    home.close(member.io);
    const instructions = try member.dir.createDirPathOpen(member.io, "instructions", .{ .permissions = .fromMode(0o700) });
    instructions.close(member.io);
    if (!try exists(member, "instructions/role.md")) try member.write("instructions/role.md", "", false);
    if (!try exists(member, "bot.env")) try member.write("bot.env", "GLOWCAP_ROOMS_BOT_HARNESS=claude\nGLOWCAP_ROOMS_BOT_PERMISSION=safe\n", false);
    if (!has_project) {
        var bytes: [16]u8 = undefined;
        try member.io.randomSecure(&bytes);
        try member.write("project-id", &std.fmt.bytesToHex(bytes, .lower), false);
    }
}

const Compose = struct {
    docker: Docker,
    base: []const []const u8,

    fn args(self: Compose, extra: []const []const u8) ![]const []const u8 {
        return std.mem.concat(self.docker.gpa, []const u8, &.{ self.base, extra });
    }

    fn run(self: Compose, extra: []const []const u8, seconds: i64) !void {
        try self.docker.run(try self.args(extra), seconds);
    }

    fn sessionArgs(self: Compose, extra: []const []const u8) ![]const []const u8 {
        const prefix: []const []const u8 = &.{ "exec", "-T", "member-session", "/runtime/bin/glowcap", "apps", "rooms", "session" };
        return std.mem.concat(self.docker.gpa, []const u8, &.{ self.base, prefix, extra });
    }

    fn session(self: Compose, extra: []const []const u8) ![]const u8 {
        return self.docker.sessionResult(try self.sessionArgs(extra));
    }
};

fn provision(member: Config, compose: Compose, nick: []const u8, rooms: []const []const u8, locator: ?[]const u8) !void {
    const has_link = try exists(member, "bot-link");
    try compose.run(&.{ "up", "-d", "--wait", "--wait-timeout", "120", "member-session" }, 150);
    var join: std.ArrayList([]const u8) = .empty;
    try join.appendSlice(member.gpa, &.{ "start", "--dir=/session-state", try member.gpa.print("--nick={s}", .{nick}), "--exact-nick" });
    // A lost host grant is recoverable. Only a session with no saved home
    // needs the deployment's default locator, even during first-setup retry.
    const bootstrap: ?[]const u8 = if (locator) |url| url else if (!has_link and !try hasHome(member, compose)) "http://directory:8080/locator" else null;
    if (bootstrap) |url| try join.append(member.gpa, try member.gpa.print("--locator={s}", .{url}));
    if (rooms.len != 0) {
        try join.append(member.gpa, "--existing-room");
        for (rooms) |room| try join.append(member.gpa, try member.gpa.print("--room={s}", .{room}));
    }
    _ = compose.session(join.items) catch |err| {
        log.err(member.io, "could not confirm {s}'s nickname and memberships. Check the locator, nickname availability and room admission. Inspect the session with deployment bots session {s} -- status", .{ nick, nick });
        return err;
    };
    if (!has_link) {
        const link = compose.session(&.{ "access", "issue", "--dir=/session-state", "--label=bot", "--id=deployment-bot", "--rights=collaborator" }) catch |err| {
            log.err(member.io, "inspect the saved grant with deployment bots session {s} -- access list. See Recover a missing member link in the deployment guide", .{nick});
            return err;
        };
        const Grant = struct { ok: bool, id: []const u8, link: []const u8 };
        const issued = try std.json.parseFromSlice(Grant, member.gpa, link, .{ .ignore_unknown_fields = true });
        if (!issued.value.ok or !std.mem.eql(u8, issued.value.id, "deployment-bot") or !std.mem.startsWith(u8, issued.value.link, "ocapn://")) return error.InvalidGrantResponse;
        try member.write("bot-link", issued.value.link, false);
    }
}

fn hasHome(member: Config, compose: Compose) !bool {
    const Directory = struct { home: bool };
    const Status = struct { ok: bool, workspace: struct { directories: []const Directory } };
    const result = try compose.session(&.{ "status", "--dir=/session-state" });
    const status = try std.json.parseFromSlice(Status, member.gpa, result, .{ .ignore_unknown_fields = true });
    if (!status.value.ok) return error.InvalidSessionStatus;
    for (status.value.workspace.directories) |directory| if (directory.home) return true;
    return false;
}
