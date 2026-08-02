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

test "unknown flag on dial is usage, and diagnostics land in the test capture" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    // Both diagnostic routes — the `log.err` line and the usage block that
    // `argv.writeStderr` routes through the same seam — must land in
    // `log.test_capture`, never the process stderr, which the build runner
    // would echo under its `failed command:` label on a green run.
    cli.log.test_capture.reset();
    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial", "--nope" });
    try std.testing.expectEqual(cli.exit_codes.usage, code);
    const diags = cli.log.test_capture.captured();
    try std.testing.expect(std.mem.indexOf(u8, diags, "unknown flag \"--nope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, diags, "Usage:") != null);
}

test "a diagnostic longer than the line buffer truncates visibly, never vanishes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    cli.log.test_capture.reset();
    const long = "x" ** 600;
    cli.log.err(threaded.io(), "{s}", .{long});
    const diags = cli.log.test_capture.captured();
    try std.testing.expect(std.mem.startsWith(u8, diags, "pancake: error: xxx"));
    try std.testing.expect(std.mem.endsWith(u8, diags, " [truncated]\n"));
}

test "-h help is product stdout, not a diagnostic" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    // The Cobra-shaped stream split is a contract: asked-for help goes to
    // stdout, parse-error usage goes to stderr. The per-stream captures are
    // what make the split assertable in a test build at all.
    cli.log.test_capture.reset();
    cli.argv.test_stdout_capture.reset();
    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial", "-h" });
    try std.testing.expectEqual(cli.exit_codes.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, cli.argv.test_stdout_capture.captured(), "Usage:") != null);
    try std.testing.expectEqual(@as(usize, 0), cli.log.test_capture.captured().len);
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

fn lineContaining(hay: []const u8, marker: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, hay, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, marker) != null) return l;
    }
    return null;
}

test "every persistent root flag completes on child nodes in bash zsh fish" {
    const gpa = std.testing.allocator;
    const bash = try cli.cmd_completion.emitAlloc(gpa, &fixture_root, .bash);
    defer gpa.free(bash);
    const zsh = try cli.cmd_completion.emitAlloc(gpa, &fixture_root, .zsh);
    defer gpa.free(zsh);
    const fish = try cli.cmd_completion.emitAlloc(gpa, &fixture_root, .fish);
    defer gpa.free(fish);

    // A nested leaf node in each shell's output; the flags are derived from
    // the root's `.persistent` set, so a new persistent flag lands here too.
    const bash_dial = lineContaining(bash, "\"ocapn dial\") echo \"") orelse return error.MissingDialCase;
    const zsh_dial = lineContaining(zsh, "\"ocapn dial\") echo \"") orelse return error.MissingDialCase;
    const fish_dial = lineContaining(fish, "__fish_seen_subcommand_from dial") orelse return error.MissingDialCase;

    for (fixture_root_flags) |f| {
        if (!f.persistent) continue;
        var buf: [64]u8 = undefined;
        const long = try std.fmt.bufPrint(&buf, "--{s}", .{f.long});
        try std.testing.expect(std.mem.indexOf(u8, bash_dial, long) != null);
        try std.testing.expect(std.mem.indexOf(u8, zsh_dial, long) != null);
        // Fish carries persistent flags as one unguarded global line each
        // (offered in every context); per-node lines stay own-flags only.
        var fbuf: [80]u8 = undefined;
        const fish_global = try std.fmt.bufPrint(&fbuf, "complete -c pancake -l {s} ", .{f.long});
        try std.testing.expect(std.mem.indexOf(u8, fish, fish_global) != null);
        var nbuf: [64]u8 = undefined;
        const fish_node_flag = try std.fmt.bufPrint(&nbuf, "-l {s}", .{f.long});
        try std.testing.expect(std.mem.indexOf(u8, fish_dial, fish_node_flag) == null);
    }

    // A flagless leaf needs no per-node fish line at all: its name completes
    // from the parent's `-a` list and the persistent flags are global.
    try std.testing.expect(lineContaining(fish, "__fish_seen_subcommand_from completion") == null);
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

test "a flag does not swallow the next flag as its value" {
    // `pancake --identity --json init` used to read `--json` as the identity
    // path. It wrote a key to a file literally named `--json`, left a
    // `--json.lock` beside it, dropped the flag the user actually typed, and
    // exited zero. Nothing in that sequence told them anything was wrong.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "ocapn", "dial", "--identity", "--json" });
    try std.testing.expectEqual(cli.exit_codes.usage, code);
}

test "the same value flag given twice is usage, not last-wins" {
    // `--identity old.key --identity new.key` used to read one key file and
    // never mention the other. Persistent flags make this easy to hit by
    // accident, since the same flag is accepted at the root and again at the
    // subcommand.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{
        "--identity", "old.key", "ocapn", "--identity", "new.key", "dial", "ocapn://x",
    });
    try std.testing.expectEqual(cli.exit_codes.usage, code);
}

test "repeating an on/off flag is fine" {
    // It says the same thing twice, so there is nothing to disagree about.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "--json", "ocapn", "--json", "dial", "ocapn://x" });
    try std.testing.expectEqual(cli.exit_codes.ok, code);
}

test "the short-flag advice names a form the parser accepts" {
    // A short flag is matched as exactly two characters, so `-i=value` lands on
    // "unknown flag". Advising it sent the user from one error to another.
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var c = testCtx(gpa, &environ, &threaded);
    defer c.deinit();

    // The form the message recommends has to actually work.
    const code = try cli.cmd.dispatch(&fixture_root, &c, &.{ "--identity=--json", "ocapn", "dial", "ocapn://x" });
    try std.testing.expectEqual(cli.exit_codes.ok, code);
}
