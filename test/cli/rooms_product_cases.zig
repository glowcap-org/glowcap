//! The installed product vocabulary follows jobs, not helper executable names.
const std = @import("std");
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
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &environ, .io = threaded.io(), .front = .argv };
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
