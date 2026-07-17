//! Command-tree parse / help / completion goldens (ADR-0084 command tree).
const std = @import("std");
const cli = @import("cli");

const Command = cli.cmd_types.Command;
const Flag = cli.cmd_types.Flag;
const Positional = cli.cmd_types.Positional;
fn stubRun(ctx: *cli.ctx.Ctx, parsed: *cli.cmd_types.Parsed) anyerror!u8 {
    _ = ctx;
    _ = parsed;
    return cli.exit_codes.ok;
}

const fixture_listen_flags = [_]Flag{
    .{ .long = "bind", .help = "HOST:PORT", .kind = .string_flag },
    .{ .long = "once", .help = "once" },
};
const fixture_dial_flags = [_]Flag{
    .{ .long = "repl", .help = "attach REPL" },
};
const fixture_root_flags = [_]Flag{
    .{ .long = "json", .help = "JSON", .persistent = true },
    .{ .long = "identity", .help = "seed path", .kind = .string_flag, .persistent = true },
};

const fixture_ocapn_children = [_]Command{
    .{
        .name = "listen",
        .short_help = "Bind a listener",
        .flags = &fixture_listen_flags,
        .run = stubRun,
    },
    .{
        .name = "dial",
        .short_help = "Dial a locator",
        .flags = &fixture_dial_flags,
        .positionals = &[_]Positional{.{ .name = "locator", .help = "ocapn:// URI" }},
        .run = stubRun,
    },
};

const fixture_children = [_]Command{
    .{
        .name = "ocapn",
        .short_help = "CapTP verbs",
        .children = &fixture_ocapn_children,
    },
    .{
        .name = "app",
        .short_help = "Apps",
        .children = &[_]Command{.{
            .name = "rooms-peer",
            .short_help = "Rooms peer",
            .children = &[_]Command{.{
                .name = "start",
                .short_help = "Start peer",
                .flags = &[_]Flag{.{ .long = "dir", .help = "dir", .kind = .string_flag }},
                .run = stubRun,
            }},
        }},
    },
    .{
        .name = "completion",
        .short_help = "Shell completion",
        .positionals = &[_]Positional{.{ .name = "shell", .help = "bash|zsh|fish" }},
        .run = stubRun,
    },
};

const fixture_root: Command = .{
    .name = "pancake",
    .short_help = "fixture root",
    .flags = &fixture_root_flags,
    .children = &fixture_children,
};

fn testCtx(gpa: std.mem.Allocator, environ: *std.process.Environ.Map, threaded: *std.Io.Threaded) cli.ctx.Ctx {
    return .{
        .io = threaded.io(),
        .gpa = gpa,
        .environ = environ,
        .front = .argv,
    };
}

test "dial help excludes listen" {
    const dial = fixture_root.findChild("ocapn").?.findChild("dial").?;
    try std.testing.expectEqualStrings("dial", dial.name);
    try std.testing.expect(std.mem.indexOf(u8, dial.short_help, "listen") == null);
    for (dial.flags) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.long, "bind"));
    }
    try std.testing.expect(dial.findChild("listen") == null);
}

test "unknown flag on dial is usage" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial", "--nope" });
    try std.testing.expectEqual(cli.exit_codes.usage, code);
}

test "dispatch dial with locator succeeds" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial", "ocapn://tcp.localhost/x" });
    try std.testing.expectEqual(cli.exit_codes.ok, code);
}

test "surplus dial positional is usage" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial", "ocapn://x", "extra" });
    try std.testing.expectEqual(cli.exit_codes.usage, code);
}

test "persistent --json is accepted before subcommand" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "--json", "ocapn", "dial", "ocapn://tcp.localhost/x" });
    try std.testing.expectEqual(cli.exit_codes.ok, code);
    try std.testing.expect(c.json == .json);
}

test "completion emit lists ocapn dial app rooms-peer and --json" {
    try std.testing.expect(cli.cmd_completion.parseShell("bash") == .bash);
    try std.testing.expect(cli.cmd_completion.parseShell("zsh") == .zsh);
    try std.testing.expect(cli.cmd_completion.parseShell("fish") == .fish);
    try std.testing.expect(cli.cmd_completion.parseShell("powershell") == null);

    const gpa = std.testing.allocator;
    const bash = try cli.cmd_completion.emitAlloc(gpa, &fixture_root, .bash);
    defer gpa.free(bash);
    try std.testing.expect(std.mem.indexOf(u8, bash, "ocapn") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "dial") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "app rooms-peer") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "--json") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash, "--repl") != null);

    const zsh = try cli.cmd_completion.emitAlloc(gpa, &fixture_root, .zsh);
    defer gpa.free(zsh);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "ocapn") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "app rooms-peer") != null);
    try std.testing.expect(std.mem.indexOf(u8, zsh, "--repl") != null);

    const fish = try cli.cmd_completion.emitAlloc(gpa, &fixture_root, .fish);
    defer gpa.free(fish);
    try std.testing.expect(std.mem.indexOf(u8, fish, "ocapn") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "dial") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "rooms-peer") != null);
    try std.testing.expect(std.mem.indexOf(u8, fish, "--json") != null or std.mem.indexOf(u8, fish, "-l json") != null);
}

test "missing dial locator is usage" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial" });
    try std.testing.expectEqual(cli.exit_codes.usage, code);
}
