//! The installed product vocabulary follows jobs, not helper executable names.
const std = @import("std");
const Runtime = @import("runtime_fixture.zig").Runtime;
const cli = @import("cli");

test "Rooms exposes one product tree with one session and team lifecycle" {
    const root = &cli.tree.root;
    try std.testing.expect(root.findChild("install") != null);
    try std.testing.expect(root.findChild("app") == null);
    const rooms = root.findChild("apps").?.findChild("rooms").?;
    for ([_][]const u8{ "serve", "status", "locator", "revision", "trace", "chat", "skills" }) |name| {
        try std.testing.expect(rooms.findChild(name).?.run != null);
    }
    const session = rooms.findChild("session").?;
    for ([_][]const u8{ "start", "join", "status", "listen", "tick", "reply", "command", "dismiss", "leave", "resume", "stop", "serve", "ready" }) |name| {
        try std.testing.expect(session.findChild(name).?.run != null);
    }
    try std.testing.expect(session.findChild("team-start") == null);
    const team = rooms.findChild("team").?;
    for ([_][]const u8{ "start", "status", "stop" }) |name| try std.testing.expect(team.findChild(name).?.run != null);
    try std.testing.expect(rooms.findChild("peer") == null);
    try std.testing.expect(rooms.findChild("deployment") != null);
    for ([_][]const u8{ "up", "status", "logs", "trace", "down", "restart", "reset", "doctor" }) |name| {
        try std.testing.expect(rooms.findChild("deployment").?.findChild(name).?.run != null);
    }
    for ([_][]const u8{ "bridge", "serve" }) |name| try std.testing.expect(rooms.findChild("irc").?.findChild(name).?.run != null);
    try std.testing.expect(rooms.findChild("archive").?.findChild("serve").?.run != null);
    try std.testing.expect(rooms.findChild("directory").?.findChild("serve").?.run != null);
}

fn flagNamed(command: *const cli.cmd_types.Command, name: []const u8) ?cli.cmd_types.Flag {
    for (command.flags) |flag| if (std.mem.eql(u8, flag.long, name)) return flag;
    return null;
}
test "Rooms serve owns the options a page served elsewhere needs to reach it" {
    const serve = cli.tree.root.findChild("apps").?.findChild("rooms").?.findChild("serve").?;
    for ([_][]const u8{ "allow-origin", "session-state", "http-port", "http-public" }) |name| {
        try std.testing.expect(flagNamed(serve, name) != null);
    }
}
test "Rooms peers take every listener transport and its options" {
    const rooms = cli.tree.root.findChild("apps").?.findChild("rooms").?;
    const listeners = [_]*const cli.cmd_types.Command{
        rooms.findChild("serve").?,
        rooms.findChild("directory").?.findChild("serve").?,
        rooms.findChild("archive").?.findChild("serve").?,
        rooms.findChild("session").?.findChild("serve").?,
        rooms.findChild("session").?.findChild("start").?,
    };
    for (listeners) |command| {
        for ([_][]const u8{ "transport", "relay", "relay-public", "bind", "port", "announce-host", "onion-socks", "onion-control" }) |name| {
            try std.testing.expect(flagNamed(command, name) != null);
        }
        try std.testing.expectEqualStrings(cli.rooms_commands.transport_help, flagNamed(command, "transport").?.help);
    }
    // The directory fronts take more listeners, once per transport, and the
    // web front takes the shared workspace's listener options beside its own.
    for (listeners[0..2]) |command| try std.testing.expect(flagNamed(command, "listen").?.repeatable);
    try std.testing.expect(flagNamed(listeners[1], "session-transport") == null);
}

/// The names under `[front]` in the list the fronts' own tests read.
const Handed = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn to(front: []const u8) Handed {
        const list = @embedFile("rooms_front_options.txt");
        var heading: [64]u8 = undefined;
        const marker = std.fmt.bufPrint(&heading, "[{s}]\n", .{front}) catch unreachable;
        const start = (std.mem.indexOf(u8, list, marker) orelse return .{ .lines = std.mem.splitScalar(u8, "", '\n') }) + marker.len;
        const end = std.mem.indexOfPos(u8, list, start, "\n[") orelse list.len;
        return .{ .lines = std.mem.splitScalar(u8, list[start..end], '\n') };
    }

    fn next(handed: *Handed) ?[]const u8 {
        while (handed.lines.next()) |line| {
            if (line.len != 0 and line[0] != '#') return line;
        }
        return null;
    }

    fn names(front: []const u8, wanted: []const u8) bool {
        var handed = to(front);
        while (handed.next()) |name| {
            if (std.mem.eql(u8, name, wanted)) return true;
        }
        return false;
    }
};

test "every Rooms front is handed exactly the options the shared list names" {
    const rooms = cli.tree.root.findChild("apps").?.findChild("rooms").?;
    const fronts = [_]struct { front: []const u8, command: *const cli.cmd_types.Command, mode: cli.rooms.Mode }{
        .{ .front = "rooms-web", .command = rooms.findChild("serve").?, .mode = .serve },
        .{ .front = "rooms-server", .command = rooms.findChild("directory").?.findChild("serve").?, .mode = .service },
        .{ .front = "rooms-session", .command = rooms.findChild("session").?.findChild("serve").?, .mode = .session_serve },
        .{ .front = "rooms-irc-server", .command = rooms.findChild("irc").?.findChild("serve").?, .mode = .service },
        .{ .front = "rooms-irc-bridge", .command = rooms.findChild("irc").?.findChild("bridge").?, .mode = .service },
        .{ .front = "rooms-archive", .command = rooms.findChild("archive").?.findChild("serve").?, .mode = .service },
    };
    for (fronts) |entry| {
        var listed: usize = 0;
        var handed = Handed.to(entry.front);
        while (handed.next()) |name| {
            listed += 1;
            const offered = for (entry.command.flags) |flag| {
                if (std.mem.eql(u8, cli.rooms.handedName(entry.mode, flag.long), name)) break true;
            } else false;
            if (!offered) {
                std.debug.print("{s} reads --{s}, which the command does not offer\n", .{ entry.front, name });
                return error.OptionNotOffered;
            }
        }
        try std.testing.expect(listed != 0);
        for (entry.command.flags) |flag| {
            const name = cli.rooms.handedName(entry.mode, flag.long);
            if (!Handed.names(entry.front, name)) {
                std.debug.print("the command hands {s} --{s}, which the list does not name\n", .{ entry.front, name });
                return error.OptionNotListed;
            }
        }
    }
}

test "Rooms serve offers every served-session option under its session prefix" {
    const rooms = cli.tree.root.findChild("apps").?.findChild("rooms").?;
    const serve = rooms.findChild("serve").?;
    var offered: usize = 0;
    for (rooms.findChild("session").?.findChild("serve").?.flags) |flag| {
        // The web front names the session's directory `--session-state`.
        if (std.mem.eql(u8, flag.long, "dir")) continue;
        var name: [64]u8 = undefined;
        const prefixed = try std.fmt.bufPrint(&name, "session-{s}", .{flag.long});
        try std.testing.expect(flagNamed(serve, prefixed) != null);
        offered += 1;
    }
    try std.testing.expect(offered > 0);
    try std.testing.expect(flagNamed(serve, "session-dial-transports") != null);
    try std.testing.expect(flagNamed(serve, "session-admission-rates") != null);
}

test "Rooms completion follows the installed session and team grammar" {
    const gpa = std.testing.allocator;
    for ([_]cli.cmd_completion.Shell{ .bash, .zsh, .fish }) |shell| {
        const script = try cli.cmd_completion.emitAlloc(gpa, &cli.tree.root, shell);
        defer gpa.free(script);
        var lines = std.mem.splitScalar(u8, script, '\n');
        while (lines.next()) |line| {
            const owns_rooms = if (shell == .fish)
                std.mem.indexOf(u8, line, "and __fish_seen_subcommand_from rooms") != null
            else
                std.mem.startsWith(u8, line, "    \"apps rooms");
            if (!owns_rooms) continue;
            const owns_trace = if (shell == .fish)
                std.mem.indexOf(u8, line, "and __fish_seen_subcommand_from trace") != null
            else
                std.mem.startsWith(u8, line, "    \"apps rooms trace\"") or
                    std.mem.startsWith(u8, line, "    \"apps rooms deployment trace\"");
            for ([_][]const u8{ "identity", "plain", "json" }) |flag| {
                if (owns_trace and std.mem.eql(u8, flag, "json")) continue;
                const token = try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (shell == .fish) "-l " else "--", flag });
                defer gpa.free(token);
                try std.testing.expect(std.mem.indexOf(u8, line, token) == null);
            }
        }
        for ([_][]const u8{ "session", "team" }) |resource| {
            const path = if (shell == .fish)
                try std.fmt.allocPrint(gpa, "__fish_seen_subcommand_from apps; and __fish_seen_subcommand_from rooms; and __fish_seen_subcommand_from {s}", .{resource})
            else
                try std.fmt.allocPrint(gpa, "apps rooms {s}", .{resource});
            defer gpa.free(path);
            try std.testing.expect(std.mem.indexOf(u8, script, path) != null);
        }
    }
}

test "Rooms help refuses CapTP flags instead of advertising ignored output and identity choices" {
    const root = &cli.tree.root;
    const apps = root.findChild("apps").?;
    const rooms = apps.findChild("rooms").?;
    const session = rooms.findChild("session").?;
    for ([_][]const *const cli.cmd_types.Command{
        &.{ root, apps, rooms },
        &.{ root, apps, rooms, rooms.findChild("serve").? },
        &.{ root, apps, rooms, session, session.findChild("listen").? },
    }) |path| {
        const help = try cli.cmd.help.writeNodeHelpAlloc(std.testing.allocator, path);
        defer std.testing.allocator.free(help);
        for ([_][]const u8{ "--identity", "--plain", "--json" }) |flag| {
            try std.testing.expect(std.mem.indexOf(u8, help, flag) == null);
        }
    }
}

test "Rooms refuses root flags on either side of the command boundary before executing" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &runtime.environ, .io = runtime.io(), .front = .argv };
    defer ctx.deinit();
    for ([_][]const []const u8{
        &.{ "--plain", "apps", "rooms", "skills" },
        &.{ "--json", "apps", "rooms", "skills" },
        &.{ "--identity=unused", "apps", "rooms", "skills" },
        &.{ "apps", "rooms", "skills", "--plain" },
        &.{ "apps", "rooms", "session", "listen", "--dir=unused", "--json" },
        &.{ "apps", "rooms", "team", "status", "--dir=unused", "--identity=unused" },
    }) |args| {
        cli.log.test_capture.reset();
        try std.testing.expectEqual(cli.exit_codes.usage, try cli.cmd.dispatch(&cli.tree.root, &ctx, args));
        try std.testing.expect(ctx.secret == null and ctx.state_guard == null);
    }
}

test "an installed component this user cannot reach is a reported cause, not a missing install" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    var c = cli.ctx.Ctx{ .io = runtime.io(), .gpa = gpa, .environ = &runtime.environ };
    defer c.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, runtime.io(), ".", gpa);
    defer gpa.free(root);
    const missing = try std.fs.path.join(gpa, &.{ root, "absent" });
    defer gpa.free(missing);
    try std.testing.expect(!try cli.installation.exists(&c, missing));
    // A name longer than any filesystem component is refused before lookup.
    const long_name: [300]u8 = @splat('a');
    const unreachable_path = try std.fs.path.join(gpa, &.{ root, &long_name });
    defer gpa.free(unreachable_path);
    try std.testing.expectError(error.NameTooLong, cli.installation.exists(&c, unreachable_path));
}
