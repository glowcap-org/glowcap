//! The product grammar owns Rooms parsing, help, and the application handoff.
const std = @import("std");
const Runtime = @import("runtime_fixture.zig").Runtime;
const cli = @import("cli");
const types = cli.cmd_types;
var last: ?[]u8 = null;

fn capture(comptime verb: []const u8) *const fn (*cli.ctx.Ctx, *types.Parsed) anyerror!u8 {
    return struct {
        fn run(ctx: *cli.ctx.Ctx, parsed: *types.Parsed) anyerror!u8 {
            last = try cli.rooms_session.envelope(ctx.gpa, verb, parsed);
            return 0;
        }
    }.run;
}
const commands = blk: {
    var result = cli.rooms_session.commands;
    for (&result) |*command| command.run = capture(command.name);
    break :blk result;
};
const root: types.Command = .{ .name = "session", .short_help = "Rooms", .children = &commands };
const team_commands = blk: {
    var result = cli.rooms_session.team_commands;
    for (&result) |*command| command.run = capture("team-" ++ command.name);
    break :blk result;
};
const team_root: types.Command = .{ .name = "team", .short_help = "Team", .children = &team_commands };
const bot_commands = blk: {
    var result = cli.rooms_bot.commands;
    for (&result) |*command| command.run = capture(command.name);
    break :blk result;
};
const bot_root: types.Command = .{ .name = "bot", .short_help = "Bot", .children = &bot_commands };
/// The `session access` verbs, handed over as `access-<verb>`.
const access_commands = blk: {
    const group = for (cli.rooms_session.commands) |command| {
        if (std.mem.eql(u8, command.name, "access")) break command;
    } else @compileError("session has no access group");
    var result: [group.children.len]types.Command = undefined;
    for (group.children, &result) |child, *slot| {
        slot.* = child;
        slot.run = capture("access-" ++ child.name);
    }
    break :blk result;
};
const access_root: types.Command = .{ .name = "access", .short_help = "Access", .children = &access_commands };

test "Rooms grammar retains ordered rooms, members, acknowledgements, and positional arguments" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &runtime.environ, .io = runtime.io(), .front = .argv };
    defer ctx.deinit();
    const cases = [_]struct { args: []const []const u8, key: []const u8, expected: []const []const u8 }{
        .{ .args = &.{ "start", "--dir", "/tmp/peer", "--room", "garden", "--room=workshop" }, .key = "room", .expected = &.{ "garden", "workshop" } },
        .{ .args = &.{ "team-start", "--dir", "/tmp/team", "--member", "Bob", "--member=Carol" }, .key = "member", .expected = &.{ "Bob", "Carol" } },
        .{ .args = &.{ "dismiss", "--dir", "/tmp/peer", "--id", "2", "--id=4" }, .key = "id", .expected = &.{ "2", "4" } },
    };
    for (cases) |case| {
        last = null;
        defer if (last) |body| gpa.free(body);
        if (std.mem.eql(u8, case.args[0], "team-start")) {
            const args = try gpa.dupe([]const u8, case.args);
            defer gpa.free(args);
            args[0] = "start";
            try std.testing.expectEqual(@as(u8, 0), try cli.cmd.dispatch(&team_root, &ctx, args));
        } else {
            try std.testing.expectEqual(@as(u8, 0), try cli.cmd.dispatch(&root, &ctx, case.args));
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, last.?, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.args[0], parsed.value.object.get("verb").?.string);
        const values = parsed.value.object.get("named").?.object.get(case.key).?.array.items;
        try std.testing.expectEqual(case.expected.len, values.len);
        for (case.expected, values) |want, actual| try std.testing.expectEqualStrings(want, actual.string);
    }
    last = null;
    defer if (last) |body| gpa.free(body);
    try std.testing.expectEqual(@as(u8, 0), try cli.cmd.dispatch(&root, &ctx, &.{ "command", "--dir", "/tmp/peer", "say", "conversation", "hello world" }));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, last.?, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("hello world", args[2].string);
}

test "Rooms grammar rejects repeated single values and unknown flags before handoff" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &runtime.environ, .io = runtime.io(), .front = .argv };
    defer ctx.deinit();
    for ([_][]const []const u8{
        &.{ "start", "--dir", "/tmp/one", "--dir", "/tmp/two" },
        &.{ "start", "--dir", "/tmp/one", "--unknown" },
        &.{ "status", "--dir", "/tmp/one", "--room", "garden" },
    }) |args| {
        last = null;
        cli.log.test_capture.reset();
        try std.testing.expectEqual(cli.exit_codes.usage, try cli.cmd.dispatch(&root, &ctx, args));
        try std.testing.expect(last == null);
    }
    cli.argv.test_stdout_capture.reset();
    try std.testing.expectEqual(@as(u8, 0), try cli.cmd.dispatch(&team_root, &ctx, &.{ "start", "--help" }));
    const help = cli.argv.test_stdout_capture.captured();
    try std.testing.expect(std.mem.find(u8, help, "--member") != null);
    try std.testing.expect(std.mem.find(u8, help, "--room") != null);
    try std.testing.expect(last == null);
}

fn handed(gpa: std.mem.Allocator, root_command: *const types.Command, ctx: *cli.ctx.Ctx, args: []const []const u8) !std.json.Parsed(std.json.Value) {
    last = null;
    try std.testing.expectEqual(@as(u8, 0), try cli.cmd.dispatch(root_command, ctx, args));
    return std.json.parseFromSlice(std.json.Value, gpa, last.?, .{});
}

test "Rooms bot and access commands hand their flags and arguments to the private front" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &runtime.environ, .io = runtime.io(), .front = .argv };
    defer ctx.deinit();
    {
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "serve", "--dir", "/b", "--link", "ocapn://x", "--harness", "claude", "--deadline", "90" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("serve", parsed.value.object.get("verb").?.string);
        try std.testing.expectEqualStrings("/b", parsed.value.object.get("state").?.string);
        const named = parsed.value.object.get("named").?.object;
        try std.testing.expectEqualStrings("ocapn://x", named.get("link").?.array.items[0].string);
        try std.testing.expectEqualStrings("90", named.get("deadline").?.array.items[0].string);
        try std.testing.expect(named.get("dir") == null);
    }
    {
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "serve", "--dir", "/b", "--link", "ocapn://y", "--replace-link" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        const named = parsed.value.object.get("named").?.object;
        try std.testing.expectEqualStrings("true", named.get("replace-link").?.array.items[0].string);
    }
    {
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "serve", "--dir", "/b", "--conversation-limit", "4", "--instructions", "/i.md" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        const named = parsed.value.object.get("named").?.object;
        try std.testing.expectEqualStrings("4", named.get("conversation-limit").?.array.items[0].string);
        try std.testing.expectEqualStrings("/i.md", named.get("instructions").?.array.items[0].string);
    }
    {
        // Clearing the instructions is its own flag: an empty value is refused.
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "serve", "--dir", "/b", "--no-instructions" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("true", parsed.value.object.get("named").?.object.get("no-instructions").?.array.items[0].string);
    }
    {
        // A conversation names where send posts, as say does.
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "send", "--conversation", "c1", "--file", "a.png" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("c1", parsed.value.object.get("named").?.object.get("conversation").?.array.items[0].string);
    }
    {
        // A turn's command names no bot directory: the turn does.
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "send", "--file", "a.png", "--file=b.txt", "--text", "two files" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("", parsed.value.object.get("state").?.string);
        const files = parsed.value.object.get("named").?.object.get("file").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), files.len);
        try std.testing.expectEqualStrings("b.txt", files[1].string);
    }
    {
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "command", "--operation", "o1", "--base", "3", "say", "room", "hello world" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        const args = parsed.value.object.get("arguments").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("hello world", args[2].string);
    }
    for ([_][]const u8{ "status", "ready" }) |verb| {
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ verb, "--dir", "/b" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings(verb, parsed.value.object.get("verb").?.string);
    }
    {
        const parsed = try handed(gpa, &bot_root, &ctx, &.{ "say", "--text", "-" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("-", parsed.value.object.get("named").?.object.get("text").?.array.items[0].string);
    }
    {
        const parsed = try handed(gpa, &access_root, &ctx, &.{ "issue", "--dir", "/s", "--label", "the bot", "--rights", "collaborator" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("access-issue", parsed.value.object.get("verb").?.string);
        const named = parsed.value.object.get("named").?.object;
        try std.testing.expectEqualStrings("collaborator", named.get("rights").?.array.items[0].string);
    }
    for ([_][]const u8{ "pause", "resume", "revoke", "forget" }) |verb| {
        const parsed = try handed(gpa, &access_root, &ctx, &.{ verb, "--dir", "/s", "--id", "abc" });
        defer parsed.deinit();
        defer gpa.free(last.?);
        try std.testing.expectEqualStrings("abc", parsed.value.object.get("named").?.object.get("id").?.array.items[0].string);
    }
}

test "Rooms bot and access commands refuse what they do not take before handoff" {
    const gpa = std.testing.allocator;
    var runtime: Runtime = undefined;
    runtime.init(gpa);
    defer runtime.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &runtime.environ, .io = runtime.io(), .front = .argv };
    defer ctx.deinit();
    const cases = [_]struct { root: *const types.Command, args: []const []const u8 }{
        .{ .root = &bot_root, .args = &.{ "status", "--dir", "/b", "--harness", "claude" } },
        .{ .root = &bot_root, .args = &.{ "status", "--dir", "/b", "--dir", "/c" } },
        .{ .root = &bot_root, .args = &.{ "ready", "--dir", "/b", "--harness", "claude" } },
        .{ .root = &bot_root, .args = &.{ "say", "--dir", "/b", "--text", "hi" } },
        .{ .root = &bot_root, .args = &.{ "send", "--dir", "/b", "--file", "a" } },
        .{ .root = &bot_root, .args = &.{ "serve", "--dir", "/b", "--instructions", "" } },
        .{ .root = &bot_root, .args = &.{ "serve", "--dir", "/b", "--frobnicate", "ann" } },
        .{ .root = &bot_root, .args = &.{ "workspace", "--dir", "/b" } },
        .{ .root = &bot_root, .args = &.{ "ready", "--dir", "/b", "--link", "ocapn://x" } },
        .{ .root = &access_root, .args = &.{ "pause", "--dir", "/s", "--label", "x" } },
        .{ .root = &access_root, .args = &.{ "list", "--dir", "/s", "--rights", "observer" } },
    };
    for (cases) |case| {
        last = null;
        cli.log.test_capture.reset();
        try std.testing.expectEqual(cli.exit_codes.usage, try cli.cmd.dispatch(case.root, &ctx, case.args));
        try std.testing.expect(last == null);
    }
    // A bot command without its directory is refused by the command itself.
    cli.log.test_capture.reset();
    var empty: types.Parsed = .{ .gpa = gpa };
    defer empty.deinit();
    try std.testing.expectError(error.Usage, cli.rooms_bot.commands[1].run.?(&ctx, &empty));
}

test "Rooms bot rows offer exactly the flags rooms-bot reads" {
    // The Rust side reads these per verb: `config::FLAGS` plus the link flags
    // for serve, and `act::flags` for the harness verbs. Change both together.
    const expected = [_]struct { verb: []const u8, flags: []const []const u8, positionals: usize }{
        .{ .verb = "serve", .flags = &.{ "dir", "link", "replace-link", "harness", "model", "permission", "deadline", "glowcap", "conversation-limit", "instructions", "no-instructions" }, .positionals = 0 },
        .{ .verb = "status", .flags = &.{"dir"}, .positionals = 0 },
        .{ .verb = "ready", .flags = &.{"dir"}, .positionals = 0 },
        .{ .verb = "say", .flags = &.{ "text", "conversation", "dm", "operation", "base" }, .positionals = 0 },
        .{ .verb = "send", .flags = &.{ "text", "file", "conversation", "dm", "operation", "base" }, .positionals = 0 },
        .{ .verb = "command", .flags = &.{ "operation", "base" }, .positionals = 1 },
        .{ .verb = "workspace", .flags = &.{}, .positionals = 0 },
    };
    try std.testing.expectEqual(expected.len, cli.rooms_bot.commands.len);
    for (expected) |want| {
        const row = for (cli.rooms_bot.commands) |command| {
            if (std.mem.eql(u8, command.name, want.verb)) break command;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(want.flags.len, row.flags.len);
        for (want.flags) |name| {
            const found = for (row.flags) |flag| {
                if (std.mem.eql(u8, flag.long, name)) break true;
            } else false;
            try std.testing.expect(found);
        }
        try std.testing.expectEqual(want.positionals, row.positionals.len);
    }
}
