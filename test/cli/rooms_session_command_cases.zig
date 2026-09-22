//! The product grammar owns Rooms parsing, help, and the application handoff.
const std = @import("std");
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

test "Rooms grammar retains ordered rooms, members, acknowledgements, and positional arguments" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &environ, .io = threaded.io(), .front = .argv };
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
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var ctx: cli.ctx.Ctx = .{ .gpa = gpa, .environ = &environ, .io = threaded.io(), .front = .argv };
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
    try std.testing.expect(std.mem.indexOf(u8, help, "--member") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--room") != null);
    try std.testing.expect(last == null);
}
